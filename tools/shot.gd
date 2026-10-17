extends Node

## Renders one frame for a person to look at. See shot.sh.

const LmClient := preload("res://game/lm_client.gd")
const LmLevel := preload("res://game/lm_level.gd")

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
	# A house change puts everybody in the new lobby: --level then means that house's level.
	if _args.has("houses") and client.start_level > 1:
		client.game.send_to(client.player, client.start_level)
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
	elif view == "glimpse":
		# --view=glimpse: a step into the level's first long corridor with a glimpse, looking
		# down it, as she appears at the far end.
		for id: String in level.events:
			var event: Dictionary = level.events[id]
			if str(event.get("do", "")) != "glimpse":
				continue
			for door_id: String in level.doors:
				var door: Dictionary = level.doors[door_id]
				if str(door["doc"].get("b", "")) == str(event["room"]):
					player.opened[door_id] = true
					client.game._apply_doors(player)
					var from: Vector3 = level.position + (door["centre"] as Vector3) + (door["normal"] as Vector3) * 1.2
					var to: Vector3 = level.position + level._room_point(str(event["room"]), event["at"])
					var dir := to - from
					player.place_at(from + Vector3(0, 0.1, 0), rad_to_deg(atan2(-dir.x, -dir.z)))
					break
			break
		client.game.set_flashlight(player.player_key, false)
	elif view == "witch" and not level.witches.is_empty():
		var pose: Dictionary = level.witch_pose(0, client.game.seconds_now())
		var at: Vector3 = level.position + (pose["at"] as Vector3)
		var from := at + Vector3(sin(float(pose["facing"])), 0, cos(float(pose["facing"]))) * -5.0
		player.place_at(from + Vector3(0, 0.1, 0), rad_to_deg(atan2(-(at - from).x, -(at - from).z)))

	# --view=demon: the meter says a witch has seen you, and a demon shows in the corner of the view.
	# --view=scare: a sanity scare caught at its peak (--style=witch|demon|flash).
	if view == "demon" or view == "scare":
		var cfg = client.scares.config
		cfg.demon_spawn_min = 0.2
		cfg.demon_spawn_max = 0.3
		cfg.demon_corner_min = 34.0
		cfg.demon_corner_max = 36.0
		cfg.demon_distance_min = 4.0
		cfg.demon_distance_max = 4.5
		cfg.scare_seconds = 4.0
		cfg.scares_enabled = false
		cfg.look_behind_enabled = false
		cfg.demons_enabled = view == "demon"
		player.meter = 0.3
		if view == "demon":
			player.place_at(player.global_position, 0.0)

	if view != "glimpse":
		client.game.set_flashlight(player.player_key, str(_args.get("light", "on")) != "off")
	await get_tree().create_timer(float(_args.get("seconds", "1"))).timeout

	# --caught=1: the moment of being caught, a tenth of a second in (dot-fx's flash and jolt).
	if _args.has("caught"):
		player.caught_left = 2.0
		await get_tree().create_timer(0.1).timeout

	if view == "scare":
		client.scare_view.call("_startle", str(_args.get("style", "demon")), 1.0, 4.0, client.camera.global_position)
		await get_tree().process_frame

	if view == "above":
		_plan(client, level, int(_args.get("floor", "0")))

	for _i in 3:
		await RenderingServer.frame_post_draw

	if view == "glimpse":
		var her: Node3D = client.get("_glimpse")
		print("glimpse: fired %s, drawn %s at %s, player at %s" % [player.fired.keys(), her != null and her.visible,
			her.global_position if her != null else Vector3.ZERO, player.global_position])

	var path := ProjectSettings.globalize_path(str(_args.get("out", "res://screenshots/shot.png")))
	var saved := get_viewport().get_texture().get_image().save_png(path)
	print("saved %s (%s)" % [path, error_string(saved)])
	get_tree().quit()


## --view=above: the level as a plan, one floor at a time (--floor=N): every ceiling and every
## room above that floor hidden, an orthographic camera straight down, light everywhere, and
## each room, item, station and event written on the floor where it is.
func _plan(client: Node, level: LmLevel, floor_index: int) -> void:
	var storey := level.storey()
	var cut := float(floor_index) * storey + storey - 0.9

	for room in level.get_children():
		if not room.has_meta(&"floor"):
			continue
		(room as Node3D).visible = int(room.get_meta(&"floor")) <= floor_index and int(room.get_meta(&"top_floor")) >= floor_index
		for piece in room.get_children():
			if piece.name == "Ceiling" or (piece is Node3D and (piece as Node3D).position.y > cut):
				(piece as Node3D).visible = false

	for child in level.get_children():
		if child is Node3D and not child.has_meta(&"floor") and ((child as Node3D).position.y > cut or (child as Node3D).position.y < cut - storey):
			(child as Node3D).visible = false

	# The witches drawn on other floors, and the player, are not on this plan; the client stops
	# drawing, or the next frame shows them again.
	client.set_process(false)
	for view: Node3D in (client.get("_witch_views") as Dictionary).values():
		view.visible = view.visible and absf(view.global_position.y - level.position.y - float(floor_index) * storey) < 1.5
	client.player.visible = false

	var rect := Rect2()
	var first := true
	for id: String in level.rooms:
		rect = level.rooms[id]["rect"] if first else rect.merge(level.rooms[id]["rect"])
		first = false

	var cam := Camera3D.new()
	add_child(cam)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	var view := get_viewport().get_visible_rect().size
	cam.size = maxf(rect.size.y, rect.size.x * view.y / view.x) * 1.06
	var centre: Vector3 = level.position + Vector3(rect.get_center().x, 0, rect.get_center().y)
	cam.global_position = centre + Vector3(0, 200, 0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	cam.far = 400.0
	cam.current = true
	client._env.ambient_light_energy = 1.4
	client._env.fog_enabled = false
	client._hud.visible = false
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-70, 30, 0)
	sun.light_energy = 0.9
	add_child(sun)

	var base := float(floor_index) * storey
	for id: String in level.rooms:
		var room: Dictionary = level.rooms[id]
		if int(room["floor"]) > floor_index or int(room["floor"]) + int(room["floors"]) - 1 < floor_index:
			continue
		var r: Rect2 = room["rect"]
		var name_text := "%s %s" % [id, str(room["doc"]["name"])]
		if str(room["kind"]) == "stair":
			name_text += " (up %s)" % str(room["doc"]["up"]) if int(room["floor"]) == floor_index else " (head)"
		_mark(level, Vector3(r.get_center().x, base + 3.0, r.get_center().y), name_text, Color(1, 1, 1), 64)

	for id: String in level.items:
		var at: Vector3 = level.items[id]["at"]
		if absf(at.y - base) < 1.0:
			_mark(level, at + Vector3(0, 2.0, 1.2), str(level.items[id]["doc"]["name"]), Color(1, 0.9, 0.3), 40)
	for id: String in level.stations:
		var at: Vector3 = level.stations[id]["at"]
		if absf(at.y - base) < 1.0:
			_mark(level, at + Vector3(0, 2.0, 1.2), str(level.stations[id]["doc"]["name"]), Color(0.5, 0.9, 1.0), 40)
	for id: String in level.events:
		var event: Dictionary = level.events[id]
		var where := ""
		match str(event.get("do", "")):
			"glimpse":
				where = str(event["room"])
			"lights":
				where = str(event["rooms"][0])
			"slam":
				where = str(level.doors[str(event["door"])]["doc"]["b"])
		if where != "" and int(level.rooms[where]["floor"]) == floor_index:
			var at: Vector3 = level._room_point(where, event.get("at", [0.5, 0.75]))
			_mark(level, at + Vector3(0, 2.5, 0), "! %s" % str(event["do"]), Color(1.0, 0.35, 0.3), 48)
	# The doors, in their colours, over the walls: a plan with no doors in it is a set of boxes.
	for id: String in level.doors:
		var door: Dictionary = level.doors[id]
		var middle: Vector3 = door["centre"]
		if absf(middle.y - base) > 1.0:
			continue
		var mark := MeshInstance3D.new()
		var box := BoxMesh.new()
		var normal: Vector3 = door["normal"]
		box.size = Vector3(LmLevel.DOOR_WIDTH, 0.1, 0.7) if absf(normal.z) > 0.5 else Vector3(0.7, 0.1, LmLevel.DOOR_WIDTH)
		mark.mesh = box
		var paint := StandardMaterial3D.new()
		paint.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		paint.no_depth_test = true
		paint.albedo_color = LmLevel.DOOR_COLOURS.get(str(door["doc"].get("colour", "brown")), Color(0.5, 0.35, 0.2)).lightened(0.25)
		mark.material_override = paint
		level.add_child(mark)
		mark.position = middle + Vector3(0, 4.0, 0)

	for i in level.witches.size():
		for point: Vector3 in level.witches[i]["points"]:
			if absf(point.y - base) < 1.0:
				_mark(level, point + Vector3(0, 2.6, 0), "w%d" % i, Color(0.9, 0.4, 1.0), 32)


func _mark(level: Node3D, at: Vector3, text: String, colour: Color, size: int) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = size
	label.pixel_size = 0.02
	label.modulate = colour
	label.outline_size = 12
	label.outline_modulate = Color(0, 0, 0)
	label.no_depth_test = true
	label.rotation_degrees = Vector3(-90, 0, 0)
	level.add_child(label)
	label.position = at
