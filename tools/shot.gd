extends Node

## Renders one frame for a person to look at. See shot.sh.

const LmClient := preload("res://game/lm_client.gd")

var _args: Dictionary = {}


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			_args[arg.substr(2, arg.find("=") - 2)] = arg.substr(arg.find("=") + 1)

	var client := LmClient.new()
	client.start_level = int(_args.get("level", "1"))
	add_child(client)
	var view := str(_args.get("view", "eyes"))
	client.third_person = view == "third"
	await get_tree().physics_frame

	# --houses=asylum,house: change house through each, solo, before looking (the map menu's
	# path), to see what a house change leaves on screen.
	for id in str(_args.get("houses", "")).split(",", false):
		var _changed = client.game.change_house(StringName(id))
		await get_tree().physics_frame

	# Somewhere worth looking: facing the nearest witch, a few metres away, or a room by id.
	var player = client.player
	var level = client.game.level_of(player)
	var room := str(_args.get("room", ""))

	if room != "" and level.rooms.has(room):
		player.place_at(level.position + level.room_centre(room) + Vector3(0, 0.1, 0), float(_args.get("yaw", "0")))
	elif view == "prompt" and not level.items.is_empty():
		# --view=prompt: 1.2 m from the level's first item, looking at it, so the HUD's
		# "Take the …" prompt is up with the use key drawn as a key.
		var item_at: Vector3 = level.position + (level.items[level.items.keys()[0]]["at"] as Vector3) + Vector3(0, 0.9, 0)
		var eye := item_at + Vector3(0, 0, 1.2)
		player.place_at(eye - Vector3(0, player.EYE_HEIGHT, 0), 0.0)
		player.controller.state.pitch = rad_to_deg(asin(clampf((item_at - eye).normalized().y, -1.0, 1.0)))
		player.controller.state.yaw = 0.0
	elif view == "door" and not level.doors.is_empty():
		# --view=door --near=0.6: that far from the level's first door, eyes level, facing it,
		# so its painted label can be looked at up close.
		var door: Dictionary = level.doors[level.doors.keys()[0]]
		var normal: Vector3 = door["normal"]
		var centre: Vector3 = door["centre"]
		var side := 1.0 if level.room_at(centre + normal) == level.spawn_room() else -1.0
		var from: Vector3 = level.position + centre + normal * side * float(_args.get("near", "0.6"))
		player.place_at(from + Vector3(0, 0.1, 0), rad_to_deg(atan2(normal.x * side, normal.z * side)))
	elif view == "witch" and not level.witches.is_empty():
		var pose: Dictionary = level.witch_pose(0, client.game.seconds_now())
		var at: Vector3 = level.position + (pose["at"] as Vector3)
		var from := at + Vector3(sin(float(pose["facing"])), 0, cos(float(pose["facing"]))) * -5.0
		player.place_at(from + Vector3(0, 0.1, 0), rad_to_deg(atan2(-(at - from).x, -(at - from).z)))

	client.game.set_flashlight(player.player_key, str(_args.get("light", "on")) != "off")
	await get_tree().create_timer(float(_args.get("seconds", "1"))).timeout

	# --caught=1: the moment of being caught, a tenth of a second in (dot-fx's flash and jolt).
	if _args.has("caught"):
		player.caught_left = 2.0
		await get_tree().create_timer(0.1).timeout

	if view == "above":
		var cam := Camera3D.new()
		add_child(cam)
		var rect := Rect2()
		var first := true
		for id: String in level.rooms:
			rect = level.rooms[id]["rect"] if first else rect.merge(level.rooms[id]["rect"])
			first = false
		var centre: Vector3 = level.position + Vector3(rect.get_center().x, 0, rect.get_center().y)
		cam.global_position = centre + Vector3(0, maxf(rect.size.x, rect.size.y) * 1.1, 0.1)
		cam.look_at(centre)
		cam.current = true
		client._env.ambient_light_energy = 1.2
		client._env.fog_enabled = false
		for id in level.rooms:
			pass

	for _i in 3:
		await RenderingServer.frame_post_draw

	var path := ProjectSettings.globalize_path(str(_args.get("out", "res://screenshots/shot.png")))
	var saved := get_viewport().get_texture().get_image().save_png(path)
	print("saved %s (%s)" % [path, error_string(saved)])
	get_tree().quit()
