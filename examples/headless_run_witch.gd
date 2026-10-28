extends "headless_run_client.gd"

## The witch, events, upstairs, HUD and senses sections of headless_run.gd.


## The witch a player meets, and the house around her, as the client draws and plays them
## (a play test saw no witch in 36 s and heard nearly nothing). The null
## sink counts what was asked for; tools/audio_probe (xvfb) is what says it is heard.
func _test_the_witch_and_the_house() -> void:
	_section("the witch shows herself, and the house is heard")
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://levels/lm_01.json"))
	var spawn := ""
	for room: Dictionary in doc["rooms"]:
		if bool(room["spawn"]):
			spawn = str(room["id"])
	var needed := {}
	for thing: Dictionary in (doc["items"] as Array) + (doc["stations"] as Array):
		if thing.has("room"):
			needed[str(thing["room"])] = true
	var walking := true
	var meets := false
	var walked := []
	for witch: Dictionary in doc["witches"]:
		var rooms := {}
		for point: Array in witch["path"]:
			if str(point[0]) == "room":
				rooms[str(point[1])] = true
		walking = walking and rooms.size() >= 2 and not rooms.has(spawn)
		meets = meets or rooms.keys().any(func(r: String) -> bool: return needed.has(r))
		walked.append(rooms.keys())
	_check(walking and meets,
		"level 1's witches walk between rooms, never the lobby, and through a room with something the level needs in it",
		"%s, needed in %s" % [walked, needed.keys()])

	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	client.set("start_level", 8)
	add_child(client)
	for i in 6:
		await get_tree().process_frame

	var game: LmGame = client.get("game")
	var me: LmPlayer = client.get("player")
	var level := game.level_of(me)
	var sink := client.get("audio").get("manager").get("sink") as DotAudioSinkNull
	var views: Dictionary = client.get("_witch_views")
	var witch: Node3D = views.values()[0] if not views.is_empty() else null
	_check(witch != null and bool(witch.describe().get("art", false)) and witch.find_child("Sight", true, false) != null,
		"a witch is her model, animated, with her sight on the floor", str(witch.describe()) if witch != null else "none drawn")

	# In her face, in her cone: she sees you, she flares, and the stinger says so once.
	var pose := level.witch_pose(0, game.seconds_now(), game.config.witch_speed_scale, game.config.witch_head_sweep, game.config.witch_door_seconds)
	var facing := float(pose["facing"]) + float(pose["head"])
	var ahead := Vector3(-sin(facing), 0.0, -cos(facing))
	me.meter = 0.0
	for i in 60:
		pose = level.witch_pose(0, game.seconds_now(), game.config.witch_speed_scale, game.config.witch_head_sweep, game.config.witch_door_seconds)
		facing = float(pose["facing"]) + float(pose["head"])
		ahead = Vector3(-sin(facing), 0.0, -cos(facing))
		me.place_at(level.position + (pose["at"] as Vector3) + ahead * 2.5 + Vector3(0, 0.1, 0), 0.0)
		me.meter = minf(me.meter, 0.3)
		await get_tree().physics_frame
		await get_tree().process_frame
	_check(witch != null and float(witch.get("seeing")) > 0.5 and sink.count_of(&"stinger") == 1,
		"in her sight she flares, and a stinger plays once", "seeing %.2f, stingers %d" % [float(witch.get("seeing")) if witch != null else -1.0, sink.count_of(&"stinger")])
	_check(witch != null and String(witch.get("clip")) == "attack_idle", "and she reaches for you", String(witch.get("clip")) if witch != null else "")
	_check(sink.count_of(&"witch_step") >= 1 and int(client.get("audio").call("droning")) >= 1,
		"her steps and her hum are heard", str(sink.played_ids()))
	_check(sink.count_of(&"ambience") >= 1 or Array(sink.played_ids()).any(func(i: Variant) -> bool: return String(i).begins_with("ambience/")), "the house's ambience plays under it all")
	await _the_witch_and_the_house_2(client, me, level, sink)


func _the_witch_and_the_house_2(client: Node, me: LmPlayer, level: LmLevel, sink: DotAudioSinkNull) -> void:
	# Caught: she is in your face with a shriek.
	me.caught_left = 2.0
	await get_tree().process_frame
	await get_tree().process_frame
	var scare: Node3D = client.get("_scare")
	_check(scare != null and scare.visible and sink.count_of(&"scream") == 1,
		"caught, she is in your face, and you hear her", "scare %s, screams %d" % [scare != null and scare.visible, sink.count_of(&"scream")])
	me.caught_left = 0.0
	me.meter = 0.0

	# Walking makes footfalls; opening a door makes a door.
	me.place_at(level.position + level.room_centre(level.spawn_room()) + Vector3(0, 0.1, 0), 0.0)
	await get_tree().physics_frame
	var steps_before := sink.count_of(&"step")
	# The forward key held, through the player's own sampler, for two seconds.
	Input.action_press(&"dot_fps_forward")
	for i in 120:
		await get_tree().physics_frame
	Input.action_release(&"dot_fps_forward")
	_check(sink.count_of(&"step") > steps_before, "walking, you hear your own steps", "%d -> %d" % [steps_before, sink.count_of(&"step")])
	var door_id: String = level.doors.keys()[0]
	me.opened[door_id] = true
	await _drawn()
	_check(sink.count_of(&"door") == 1, "a door you open is heard opening", str(sink.count_of(&"door")))

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished_section()


## The events as a player meets them, in a real client: the lamps flicker and go out with a
## buzz, a slam is heard where the door is, and she is drawn at the far end of the corridor.
func _test_the_events_seen_and_heard() -> void:
	_section("the house's events, seen and heard")
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	client.set("start_level", 8)
	add_child(client)
	for i in 6:
		await get_tree().process_frame
	var game: LmGame = client.get("game")
	# Nobody is caught by accident in the middle of this.
	game.config.witch_sight_scale = 0.0
	var me: LmPlayer = client.get("player")
	var level := game.level_of(me)
	var sink := client.get("audio").get("manager").get("sink") as DotAudioSinkNull
	var of_kind := {}
	for id: String in level.events:
		var kind := str(level.events[id].get("do", ""))
		if not of_kind.has(kind):
			of_kind[kind] = level.events[id]

	var lights: Dictionary = of_kind["lights"]
	var room_id := str(lights["rooms"][0])
	var lamps: Array = level.lamps.get(room_id, [])
	var lit_before := lamps.size() > 0 and lamps.all(func(l: Dictionary) -> bool: return (l["light"] as OmniLight3D).light_energy > 0.0)
	var item_id := str(lights["when"]["holds"])
	_stand_before(me, level, (level.items[item_id]["at"] as Vector3) + Vector3(0, 0.9, 0))
	var _took := game.interact(me.player_key)
	await get_tree().create_timer(1.6).timeout
	var dark := lamps.all(func(l: Dictionary) -> bool: return is_zero_approx((l["light"] as OmniLight3D).light_energy) and not (l["bulb"] as Node3D).visible)
	_check(lit_before and dark and sink.count_of(&"lights_out") == 1,
		"the lamps of the room go out, with a buzz", "lit %s, dark %s, %d lamps, buzzes %d" % [lit_before, dark, lamps.size(), sink.count_of(&"lights_out")])

	var slam: Dictionary = of_kind["slam"]
	var door: Dictionary = level.doors[str(slam["door"])]
	me.opened[str(slam["door"])] = true
	game._apply_doors(me)
	me.place_at(level.position + _furthest_from(level, str(door["doc"]["b"]), door["centre"]) + Vector3(0, 0.1, 0), 0.0)
	for i in 10:
		await get_tree().physics_frame
	await _drawn()
	_check(sink.count_of(&"slam") == 1 and not me.opened.has(str(slam["door"])), "a slam is heard, and the door is shut", str(sink.count_of(&"slam")))

	var glimpse: Dictionary = of_kind["glimpse"]
	var corridor := str(glimpse["room"])
	var into: Dictionary = {}
	for id: String in level.doors:
		if str(level.doors[id]["doc"].get("b", "")) == corridor:
			into = level.doors[id]
	me.opened[str(into["doc"]["id"])] = true
	game._apply_doors(me)
	var stingers := sink.count_of(&"stinger")
	me.place_at(level.position + (into["centre"] as Vector3) + (into["normal"] as Vector3) * 1.0 + Vector3(0, 0.1, 0), 0.0)
	for i in 4:
		await get_tree().physics_frame
	await _drawn()
	var her: Node3D = client.get("_glimpse")
	_check(her != null and her.visible and her.global_position.distance_to(me.global_position) > 6.0 and sink.count_of(&"stinger") > stingers,
		"she stands at the far end of the corridor, and you hear it", "%s, %s" % [her.visible if her != null else "none", her.global_position.distance_to(me.global_position) if her != null else -1.0])
	await get_tree().create_timer(float(glimpse.get("seconds", 2.5)) + 0.3).timeout
	_check(her != null and not her.visible, "and then she is gone")

	game.send_to(me, 8)
	await _drawn()
	_check(lamps.all(func(l: Dictionary) -> bool: return (l["light"] as OmniLight3D).light_energy > 0.0), "a new go at the level lights the lamps again")
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished_section()


## A player walks up a stairwell to the floor above, and back down, through the controller.
func _test_upstairs() -> void:
	_section("upstairs, by the stairs")
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	client.set("start_level", 2)
	add_child(client)
	for i in 6:
		await get_tree().process_frame
	var game: LmGame = client.get("game")
	game.config.witch_sight_scale = 0.0
	var me: LmPlayer = client.get("player")
	var level := game.level_of(me)
	var stair := ""
	for id: String in level.rooms:
		if str(level.rooms[id]["kind"]) == "stair":
			stair = id
			break
	var up := str(level.rooms[stair]["doc"]["up"])
	var dir: Vector3 = {"e": Vector3(1, 0, 0), "w": Vector3(-1, 0, 0), "s": Vector3(0, 0, 1), "n": Vector3(0, 0, -1)}[up]
	var cell := float(level.doc["cell"])
	var foot := level.stair_point(stair, false) - dir * cell * 0.5
	var yaw := rad_to_deg(atan2(-dir.x, -dir.z))
	me.place_at(level.position + foot + Vector3(0, 0.1, 0), yaw)
	me.controller.state.yaw = yaw
	await get_tree().physics_frame
	Input.action_press(&"dot_fps_forward")
	for i in 300:
		await get_tree().physics_frame
	Input.action_release(&"dot_fps_forward")
	var top := me.global_position - level.position
	var upstairs := level.room_at(top)
	_check(top.y > level.storey() - 0.2 and upstairs == stair and _along(level, stair, top) > level._stair_length(level.rooms[stair]) - cell,
		"a player walks up the stairs to the landing at the head, a floor up", "%s in %s" % [top, upstairs])
	me.place_at(me.global_position, yaw + 180.0)
	Input.action_press(&"dot_fps_forward")
	for i in 300:
		await get_tree().physics_frame
	Input.action_release(&"dot_fps_forward")
	var bottom := me.global_position - level.position
	_check(bottom.y < 0.3 and level.room_at(bottom) == stair, "and back down again", str(bottom))
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished_section()


## The HUD at the window sizes a player has: the step wraps rather than runs off the edge
## (the first play test's "…d key"), and every line stays inside the window.
func _test_the_hud_fits() -> void:
	_section("the HUD fits the window")
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	add_child(client)
	for i in 4:
		await get_tree().process_frame
	var step: Label = client.get("_step")
	var hud: Control = client.get("_hud")
	var long_step := "Level 32 of 32 — Take the bucket to the tap in the Servants' Hall and fill it with water"
	for size: Vector2 in [Vector2(1280, 720), Vector2(800, 600), Vector2(640, 360)]:
		# A window this size, as the HUD's root would be laid out in it.
		hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
		hud.position = Vector2.ZERO
		hud.size = size
		# Held still, so the long step written here is the one laid out (the client writes
		# the step every frame).
		client.set_process(false)
		step.text = long_step
		await get_tree().process_frame
		await get_tree().process_frame
		var fits: Dictionary = client.call("hud_fits", size)
		_check(bool(fits["fits"]), "at %dx%d the step, the holds, the keys and the meter are inside the window" % [size.x, size.y], str(fits))
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished_section()


func _test_witch_senses() -> void:
	_section("witches open doors, hear, see the light, and take time to react")
	var config := game.config
	_check(config.decay_rate <= 0.06 and config.decay_delay >= 2.0, "the meter drains slowly by default", "%.2f/s after %.1f s" % [config.decay_rate, config.decay_delay])
	_check(config.witch_reaction_seconds >= 0.3 and config.witch_turn_rate <= 200.0, "she reacts in a person's time and turns at a person's speed", "%.2f s, %.0f deg/s" % [config.witch_reaction_seconds, config.witch_turn_rate])

	# Doors: find a witch whose walk goes through a doorway.
	var p: LmPlayer = game.players[&"a"]
	game.send_to(p, 8)
	var level: LmLevel = game.levels[8]
	var witch := -1

	for i in level.witches.size():
		for id: String in level.witches[i]["door_ids"]:
			if id != "":
				witch = i

	_check(witch >= 0, "a witch of level 8 walks through a doorway", str(level.witches.size()))
	var dwell := config.witch_door_seconds
	var standing := 0
	var still := true
	var opened := 0.0
	var walked_through := false
	var previous := {}

	for tenth in 3000:
		var seconds := float(tenth) * 0.1
		var pose := level.witch_pose(witch, seconds, config.witch_speed_scale, config.witch_head_sweep, dwell)
		var old := level.witch_pose(witch, seconds, config.witch_speed_scale, config.witch_head_sweep, 0.0)

		if str(old["door"]) != "":
			walked_through = true

		if str(pose["door"]) != "" and float(pose["open"]) >= 1.0:
			opened = 1.0

		if not previous.is_empty() and float(previous["open"]) > 0.0 and float(pose["open"]) > float(previous["open"]) and float(pose["open"]) < 1.0:
			standing += 1

			if not (pose["at"] as Vector3).is_equal_approx(previous["at"]):
				still = false

		previous = pose

	_check(not walked_through, "with no door time she opens nothing (the old walk)")
	_check(opened == 1.0, "she opens a door fully on her way through")
	_check(standing > 0 and still, "and stands still at the doorway while it opens", str(standing))
	var doorway := ""
	var at_door := Vector3.ZERO

	for tenth in 3000:
		var pose := level.witch_pose(witch, float(tenth) * 0.1, config.witch_speed_scale, config.witch_head_sweep, dwell)

		if str(pose["door"]) != "" and float(pose["open"]) > 0.0:
			doorway = str(pose["door"])
			at_door = pose["at"]
			break

	_check(doorway != "" and (level.doors[doorway]["centre"] as Vector3).distance_to(at_door) < 0.3, "she is at the door she is opening", doorway)
	_witch_senses_2(config, p, level, witch, dwell)


func _witch_senses_2(config: LmConfig, p: LmPlayer, level: LmLevel, witch: int, dwell: float) -> void:
	# Hearing: stand behind her, outside her cone and her sight, and make a noise.
	game.send_to(p, 8)
	p.flashlight = false
	p.gaze.clear()
	var steps := 0
	var alerted_at := -1
	var worst_turn := 0.0
	var last_head := 0.0
	var first := true
	var delta := 1.0 / 60.0

	var widest := 0.0

	for _i in 480:
		var seconds := game.seconds_now() + delta
		var pose := game.witch_pose_for(p, level, 0, seconds)
		var facing := float(pose["facing"])
		p.place_at(level.position + (pose["at"] as Vector3) + Vector3(sin(facing), 0, cos(facing)) * 4.0, 0.0)
		p.noise_left = 1.0
		game.tick += 1
		game._listen(p, level, seconds, delta)
		steps += 1
		var state: Dictionary = p.gaze.get(0, {})

		if state.is_empty():
			continue

		if int(state["mode"]) >= LmGame.MODE_CHASE:
			break

		if not first:
			worst_turn = maxf(worst_turn, absf(wrapf(float(state["head"]) - last_head, -PI, PI)))

		first = false
		last_head = float(state["head"])
		widest = maxf(widest, absf(last_head))

		if alerted_at < 0 and bool(state["alert"]):
			alerted_at = steps

	_check(alerted_at > 0, "a noise behind her is heard", str(alerted_at))
	_check(float(alerted_at) * delta >= config.witch_reaction_seconds - 0.02, "but not at once: she takes her reaction time", "%.2f s" % (float(alerted_at) * delta))
	_check(worst_turn <= deg_to_rad(config.witch_turn_rate) * delta * 1.02, "and her head never turns faster than the turn rate", "%.2f deg a tick" % rad_to_deg(worst_turn))
	_check(widest > deg_to_rad(90.0), "she looks round at where it came from", "%.0f deg" % rad_to_deg(widest))
	_test_listening(level, delta)

	# Silence is not heard: standing still, light off, in the same place.
	p.gaze.clear()
	p.noise_left = 0.0
	var quiet := true

	for _i in 120:
		var seconds := game.seconds_now() + delta
		var pose := level.witch_pose(0, seconds, config.witch_speed_scale, config.witch_head_sweep, dwell)
		var facing := float(pose["facing"])
		p.place_at(level.position + (pose["at"] as Vector3) + Vector3(sin(facing), 0, cos(facing)) * 4.0, 0.0)
		game._listen(p, level, seconds, delta)
		quiet = quiet and not bool((p.gaze[0] as Dictionary)["alert"])

	_check(quiet, "standing still in the dark, nobody turns")
	_witch_senses_3(config, p, level, witch, dwell)


func _witch_senses_3(config: LmConfig, p: LmPlayer, level: LmLevel, witch: int, dwell: float) -> void:
	# The flashlight: in front of her, beyond her sight but inside the range a light is seen at.
	var seen_light := false
	var far_from_sight := false

	for number in [8, 12, 16, 20, 24, 28, 32]:
		if far_from_sight:
			break

		game.send_to(p, number)
		level = game.levels[number]

		for w in level.witches.size():
			for tenth in 600:
				var seconds := float(tenth) * 0.5
				var pose := level.witch_pose(w, seconds, config.witch_speed_scale, config.witch_head_sweep, dwell)
				var facing := float(pose["facing"]) + float(pose["head"])
				var ahead := Vector3(-sin(facing), 0, -cos(facing))
				var sight := float(level.witches[w]["sight"]) * config.witch_sight_scale
				var eye := level.position + (pose["at"] as Vector3) + Vector3(0, 2.0, 0)
				p.place_at(level.position + (pose["at"] as Vector3) + ahead * (sight * config.flashlight_sight + 3.0), 0.0)
				p.flashlight = true
				p.noise_left = 0.0

				if game._clear_between(eye, p.eye_position(), p):
					far_from_sight = true
					p.gaze.clear()
					game._listen(p, level, seconds, config.witch_reaction_seconds + 0.01)
					game._listen(p, level, seconds, 0.01)
					seen_light = bool((p.gaze[w] as Dictionary)["alert"])
					_check(game.exposure(p, level, w, seconds) == 0.0, "the light is seen from beyond where she would see the player")
					break

			if far_from_sight:
				break

	_check(far_from_sight and seen_light, "a lit flashlight in the open is seen from far off, in her view")
	p.flashlight = false

	# A doorway a witch has open is one a player walks through: the collider follows the door.
	game.send_to(p, 8)
	level = game.levels[8]
	var found := false

	for tenth in 3000:
		var seconds := float(tenth) * 0.1
		var pose := level.witch_pose(witch, seconds, config.witch_speed_scale, config.witch_head_sweep, dwell)

		if str(pose["door"]) != "" and float(pose["open"]) >= 1.0:
			var door: Dictionary = level.doors[str(pose["door"])]
			var normal: Vector3 = door["normal"]
			var centre: Vector3 = level.position + (door["centre"] as Vector3)
			game.tick = int(seconds * float(game.tick_rate))
			p.opened.clear()
			p.place_at(centre - normal * 1.2 + Vector3(0, 0.1, 0), rad_to_deg(atan2(-normal.x, -normal.z)) + 180.0)
			game._apply_doors(p)
			found = true
			var shut := PhysicsRayQueryParameters3D.create(centre - normal * 1.0 + Vector3(0, 1.0, 0), centre + normal * 1.0 + Vector3(0, 1.0, 0), 1)
			shut.exclude = p.controller.body.exclude
			_check(game.get_world_3d().direct_space_state.intersect_ray(shut).is_empty(), "the door she has open does not stop the player", str(pose["door"]))
			game.tick = int((seconds + dwell + 6.0) * float(game.tick_rate))
			game._apply_doors(p)
			break

	_check(found, "found a moment a witch has a door open")
	game.send_to(p, 1)
	_finished_section()
