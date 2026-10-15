extends Node

## The house, headless: every level built and finished, doors that are open for one player and
## shut for another, what a witch can see, being caught, the commands, and winning.
##
##   godot --headless --path . res://examples/headless_run.tscn

const LmGame := preload("res://game/lm_game.gd")
const LmLevel := preload("res://game/lm_level.gd")
const LmPlayer := preload("res://game/lm_player.gd")
const LmProgress := preload("res://game/lm_progress.gd")
const LmSettings := preload("res://game/lm_settings.gd")
const LmServices := preload("res://game/lm_services.gd")
const LmScares := preload("res://game/lm_scares.gd")
const LmConfig := preload("res://game/lm_config.gd")

const SECTIONS := 20
const CHECKS := 149

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _finished := 0
var game: LmGame = null
var _earned: Array = []


func _ready() -> void:
	print("look at me, headless")
	game = LmGame.new()
	game.draws = false
	game.self_tick = false
	game.config.winners_file = "user://test_lookatme_winners.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(game.config.winners_file))
	add_child(game)
	await get_tree().physics_frame
	var progress := LmProgress.new()
	add_child(progress)
	var _p := progress.setup(game, "", false)
	progress.earned.connect(func(key: StringName, title: String, _points: int) -> void: _earned.append([String(key), title]))

	_test_levels()
	_test_every_level_finishes()
	await _test_doors_are_per_player()
	_test_sight()
	await _test_caught()
	_test_commands()
	await _test_winning()
	_test_shared()
	_test_events()
	_test_houses()
	await _test_the_client_settings()
	await _test_sound_and_effects()
	await _test_the_mouse_turns_the_view()
	await _test_the_witch_and_the_house()
	await _test_the_events_seen_and_heard()
	await _test_upstairs()
	await _test_the_hud_fits()
	_test_witch_senses()
	await _test_voice()
	await _test_scares()

	print("")
	print("%d sections entered, %d finished" % [_entered, _finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _entered != SECTIONS or _finished != SECTIONS:
		push_error("%d of %d sections finished, %d declared." % [_finished, _entered, SECTIONS])
		code = 1

	if _passed + _failed != CHECKS:
		push_error("%d checks ran, %d declared." % [_passed + _failed, CHECKS])
		code = 1

	get_tree().quit(code)


func _test_levels() -> void:
	_section("thirty-two levels")
	_check(game.levels.size() == 32 and game.refused.is_empty(), "every document is a level, and none is refused", str(game.refused))
	var doors_placed := true

	for n: int in game.levels:
		var level: LmLevel = game.levels[n]
		if level.doors.size() != (level.doc["doors"] as Array).size():
			doors_placed = false

	_check(doors_placed, "every door sits on a wall its rooms share")
	_check((game.levels[1] as LmLevel).witches.size() == 2 and (game.levels[32] as LmLevel).witches.size() == 12, "two witches on level 1, twelve on level 32")
	# The second build of the levels (2026-10-12, "bigger and longer with more to do"): about
	# three times the floor of the first, which ran from 960 m2 and 4 rooms to 2,300 m2 and 20;
	# rooms were then cut to 8 to 16 m (fgr-props-1), which took level 1 from 3,600 m2 to 1,900.
	var small := PackedStringArray()
	var flat := PackedStringArray()
	var low := []
	var quiet := PackedStringArray()

	for n: int in game.levels:
		var level: LmLevel = game.levels[n]
		if level.floor_area() < 1800.0 or level.rooms.size() < 14 + n:
			small.append("%d (%d m2, %d rooms)" % [n, int(level.floor_area()), level.rooms.size()])
		if n >= 2 and level.floor_count() < 2:
			flat.append(str(n))
		# A third floor from level 16: three rooms at least, up a stairwell from the first.
		var top := 0
		for id: String in level.rooms:
			if int(level.rooms[id]["floor"]) == 2 and str(level.rooms[id]["kind"]) != "stair":
				top += 1
		if n >= 16 and top < 3:
			low.append("%d (%d rooms on floor 2)" % [n, top])
		var kinds := {}
		for id: String in level.events:
			kinds[str(level.events[id].get("do", ""))] = true
		if not (kinds.has("lights") and kinds.has("slam") and kinds.has("glimpse")):
			quiet.append("%d %s" % [n, kinds.keys()])

	_check(small.is_empty() and (game.levels[32] as LmLevel).floor_area() > 5000.0,
		"every level is big enough: 14 + n rooms, over 1,800 m2, level 32 over 5,000 m2 (the rooms are 8 to 16 m, not 12 to 20)", ", ".join(small))
	_check(flat.is_empty(), "every level from 2 has an upstairs", ", ".join(flat))
	_check(low.is_empty(), "and every level from 16 a third floor of three rooms or more", ", ".join(low))
	_check(quiet.is_empty(), "and every level has its events: lights that die, a door that slams, her down a corridor", ", ".join(quiet))

	# A witch on her walk is on the floor where she is, up a stairwell's ramp as well.
	var floating := PackedStringArray()
	var on_stairs := 0

	for n: int in game.levels:
		var level: LmLevel = game.levels[n]
		for i in level.witches.size():
			var loop: Dictionary = level.witches[i]
			var seconds_round := float(loop["total"]) / float(loop["speed"])
			for k in 200:
				var at: Vector3 = level.witch_pose(i, seconds_round * float(k) / 200.0)["at"]
				var room := level.room_at(at)
				if room == "":
					continue
				if str(level.rooms[room]["kind"]) == "stair":
					on_stairs += 1
				if absf(at.y - level.floor_at(room, at)) > 0.05:
					floating.append("%d/%d %s" % [n, i, at])
					break

	_check(floating.is_empty() and on_stairs > 0, "a witch walks on the floor, up the stairs as well (%d poses on a ramp)" % on_stairs, ", ".join(floating.slice(0, 4)))
	var lobby: Rect2 = (game.levels[1] as LmLevel).rooms[(game.levels[1] as LmLevel).spawn_room()]["rect"]
	var biggest := true

	for n: int in game.levels:
		var level: LmLevel = game.levels[n]
		for id: String in level.rooms:
			if (level.rooms[id]["rect"] as Rect2).get_area() > lobby.get_area():
				biggest = false

	_check(biggest, "the lobby is the biggest room in the game")
	var furniture := (game.levels[16] as Node).find_children("Furniture_*", "StaticBody3D", true, false).size()
	_check(furniture > 5, "and the house is furnished, solid even on a server that draws nothing (%d pieces on level 16)" % furniture)
	_finished_section()


## Plays every level's logic in the engine, standing in front of each thing and pressing E:
## the documents' puzzles are only as finishable as the game's own interact makes them.
func _test_every_level_finishes() -> void:
	_section("every level can be finished")
	var solver := game.join(&"solver", "Solver")
	var stuck := PackedStringArray()

	for n in range(1, 33):
		game.send_to(solver, n)
		var level: LmLevel = game.levels[n]
		var progress := true

		while progress and not solver.opened.has("exit"):
			progress = false

			for kind in ["item", "station", "door"]:
				for id: String in (level.items if kind == "item" else (level.stations if kind == "station" else level.doors)):
					var at: Vector3 = (level.items[id]["at"] if kind == "item" else (level.stations[id]["at"] if kind == "station" else level.doors[id]["centre"])) as Vector3
					var lift := 0.9 if kind == "item" else (0.8 if kind == "station" else 1.2)
					# What it has done, events included: a slam shuts a door it opened, and the
					# events only ever add up, so a pass that only reopened one still counts.
					var before := solver.holds.size() + solver.opened.size() + solver.used.size() + solver.taken.size() + solver.fired.size()
					_stand_before(solver, level, at + Vector3(0, lift, 0))
					var _said := game.interact(&"solver")
					if solver.holds.size() + solver.opened.size() + solver.used.size() + solver.taken.size() + solver.fired.size() > before:
						progress = true

		if not solver.opened.has("exit"):
			stuck.append("%d (%s)" % [n, game.step_of(solver)])

	_check(stuck.is_empty(), "the solver opens the way out of all 32", ", ".join(stuck))
	game.leave(&"solver")
	_finished_section()


## Puts [param player] 1.2 m back from [param at] (level-local), looking straight at it.
## Until the client has drawn a frame after now. One `process_frame` is not that when the
## last wait was a `physics_frame`: it resumes in the same frame, before the client's
## `_process`, and a prompt read there is the frame before the player moved. That read as
## "the prompt is gone after a house change" (2026-10-12), which it never was.
func _drawn() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _stand_before(player: LmPlayer, level: LmLevel, at: Vector3) -> void:
	var world_at := level.position + at
	var back := Vector3(0, 0, 1.2)
	var eye := world_at + back
	player.place_at(eye - Vector3(0, player.EYE_HEIGHT, 0), 0.0)
	var to := (world_at - eye).normalized()
	player.controller.state.pitch = rad_to_deg(asin(clampf(to.y, -1.0, 1.0)))
	player.controller.state.yaw = 0.0


func _test_doors_are_per_player() -> void:
	_section("a door is open for whoever opened it")
	var a := game.join(&"a", "A")
	var b := game.join(&"b", "B")
	var level: LmLevel = game.levels[1]
	var door: Dictionary = level.doors["d0"]
	_unlock(a, "d0")
	_check(a.opened.has("d0") and not b.opened.has("d0"), "A opened it; B did not")
	# Both walk at it from the same side for two seconds.
	var normal: Vector3 = door["normal"]
	var start: Vector3 = level.position + (door["centre"] as Vector3) - normal * 2.0
	var yaw := rad_to_deg(atan2(-normal.x, -normal.z))
	a.place_at(start + Vector3(0.0, 0.1, 0.0), yaw)
	b.place_at(start + Vector3(0.0, 0.1, 0.0), yaw)
	var go := DotFpsCommand.new()
	go.yaw = yaw
	go.move = Vector2(0, 1)

	for _i in 120:
		a.controller.apply_command(go)
		b.controller.apply_command(go)
		game.step(1.0 / 60.0)
		await get_tree().physics_frame

	var past_a: float = (a.global_position - level.position - (door["centre"] as Vector3)).dot(normal)
	var past_b: float = (b.global_position - level.position - (door["centre"] as Vector3)).dot(normal)
	_check(past_a > 1.0, "A walks through it", "%.2f m past" % past_a)
	_check(past_b < 0.0, "B walks into it", "%.2f m past" % past_b)
	game.leave(&"b")
	_finished_section()


func _unlock(player: LmPlayer, door_id: String) -> void:
	player.opened[door_id] = true
	game._apply_doors(player)


func _test_sight() -> void:
	_section("what a witch can see")
	var p: LmPlayer = game.players[&"a"]
	game.send_to(p, 8)
	var level: LmLevel = game.levels[8]
	# A moment she is well inside a room, so 2.5 m in front of her is the same room: her walk
	# is the level document's, which the builder may rewrite.
	var seconds := 3.0
	var pose := {}
	var facing := 0.0
	var ahead := Vector3.ZERO
	var witch_at := Vector3.ZERO
	var room := ""
	p.flashlight = false
	for tenth in 600:
		seconds = 3.0 + float(tenth) * 0.1
		pose = level.witch_pose(0, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep, game.config.witch_door_seconds)
		facing = float(pose["facing"]) + float(pose["head"])
		ahead = Vector3(-sin(facing), 0, -cos(facing))
		witch_at = level.position + (pose["at"] as Vector3)
		room = level.room_at(pose["at"])
		p.place_at(witch_at + ahead * 2.5, 0.0)
		if room != "" and level.room_at((pose["at"] as Vector3) + ahead * 2.5) == room and game.exposure(p, level, 0, seconds) > 0.0:
			break
	_check(game.exposure(p, level, 0, seconds) > 0.0, "in front of her, near, in the same room: seen", room)
	p.place_at(witch_at - ahead * 2.5, 0.0)
	_check(game.exposure(p, level, 0, seconds) == 0.0, "behind her: not")
	p.place_at(witch_at + ahead * 2.5, 0.0)
	p.flashlight = true
	var lit := game.exposure(p, level, 0, seconds)
	p.flashlight = false
	var dark := game.exposure(p, level, 0, seconds)
	_check(lit > dark and dark > 0.0, "a lit flashlight is seen faster", "%.2f vs %.2f" % [lit, dark])
	p.place_at(witch_at + ahead * (float(level.witches[0]["sight"]) * game.config.witch_sight_scale + 3.0), 0.0)
	_check(game.exposure(p, level, 0, seconds) == 0.0, "beyond her sight: not")
	_check(level.witch_pose(0, 12.5) == level.witch_pose(0, 12.5), "her walk is a pure function of time")
	var again := LmLevel.new()
	add_child(again)
	var _b := again.build(level.doc, false)
	_check(again.witch_pose(1, 40.0)["at"] == level.witch_pose(1, 40.0)["at"], "and every machine that builds the level puts her in the same place")
	again.queue_free()
	_finished_section()


func _test_caught() -> void:
	_section("being caught")
	var p: LmPlayer = game.players[&"a"]
	game.send_to(p, 8)
	var level: LmLevel = game.levels[8]
	p.holds.append("something")
	p.meter = 0.99
	game.config.caught_seconds = 0.2
	# In front of her, re-placed every tick at her own time, until the meter fills: one tick of
	# exposure from 0.99 is not enough on its own, which is the point of a meter.
	var caught := [false]
	game.caught.connect(func(key: StringName) -> void:
		if key == &"a":
			caught[0] = true)

	for _i in 120:
		var seconds := game.seconds_now() + 1.0 / 60.0
		var pose := level.witch_pose(0, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep, game.config.witch_door_seconds)
		var facing := float(pose["facing"]) + float(pose["head"])
		p.place_at(level.position + (pose["at"] as Vector3) + Vector3(-sin(facing), 0, -cos(facing)) * 2.0, 0.0)
		game.step(1.0 / 60.0)

		if caught[0]:
			break

	_check(caught[0] and p.caught_left > 0.0, "a full meter is a catch")

	for _i in 20:
		game.step(1.0 / 60.0)

	var home := level.room_at(p.global_position - level.position)
	_check(home == level.spawn_room() and p.meter == 0.0, "and they are put back in the level's start room", home)
	_check(p.holds.is_empty(), "with the level's progress lost, as the server is set")
	p.meter = 0.5
	p.unseen_for = 10.0
	p.place_at(level.position + level.spawn_point(0), 0.0)
	game.step(1.0)
	_check(p.meter < 0.5, "out of sight, the meter drains")
	_finished_section()


func _test_commands() -> void:
	_section("commands")
	var p: LmPlayer = game.players[&"a"]
	p.best = 2
	_check(game.command(&"a", "/l5").begins_with("You have not"), "/l5 before reaching level 5 is refused")
	_check(game.command(&"a", "/l2") == "Level 2" and p.level == 2, "/l2 after reaching it goes there")
	_check(game.command(&"a", "/r") == "Back to the lobby" and p.level == 1, "/r goes back to the lobby")
	_check(game.command(&"a", "/l 2") == "Level 2", "and /l 2 with a space")
	_finished_section()


func _test_winning() -> void:
	_section("getting out")
	var p: LmPlayer = game.players[&"a"]
	game.send_to(p, 1)
	var level: LmLevel = game.levels[1]
	_unlock(p, "exit")
	var exit: Dictionary = level.doors["exit"]
	p.place_at(level.position + (exit["centre"] as Vector3) + (exit["normal"] as Vector3) * 2.0, 0.0)
	game.step(1.0 / 60.0)
	_check(p.level == 2 and p.best == 2, "through the way out is the next level")
	game.send_to(p, 32)
	var last: LmLevel = game.levels[32]
	_unlock(p, "exit")
	var way: Dictionary = last.doors["exit"]
	var winner := [false]
	game.won.connect(func(key: StringName) -> void:
		if key == &"a":
			winner[0] = true)
	p.place_at(last.position + (way["centre"] as Vector3) + (way["normal"] as Vector3) * 2.0, 0.0)
	game.step(1.0 / 60.0)
	_check(winner[0] and p.won and p.level == 1, "out of the last one is a win, and back to the lobby")
	_check(FileAccess.file_exists(game.config.winners_file) and game.winners.has("a"), "kept, so it outlives the server")
	await get_tree().process_frame
	_check(_earned.has(["a", "Through the Front Door"]), "getting through level 1 is an achievement", str(_earned))
	_check(_earned.has(["a", "Out"]), "and getting out of the house is the brief's", str(_earned))
	p.present_body(false)
	_check(p.get_node_or_null("Crown") != null and (p.get_node("Crown") as Node3D).visible, "with a crown everybody else sees")
	var _asylum := game.change_house(&"asylum")
	var crown_away := p.won
	var _back := game.change_house(&"house")
	_check(not crown_away and p.won and (game.all_winners()["house"] as Dictionary).has("a") and (game.all_winners()["asylum"] as Dictionary).is_empty(),
		"the crown is this house's: none in the Asylum, back on coming home", str(game.all_winners()))
	# The file from before houses kept winners: one flat {key: when}, read as the built-in house's.
	var legacy := FileAccess.open(game.config.winners_file, FileAccess.WRITE)
	legacy.store_string(JSON.stringify({"old": "2026-10-01T00:00:00"}))
	legacy.close()
	game._read_winners()
	_check(game.winners.has("old") and String(game.house_id) == "house", "and a winners file from before houses is the built-in house's", str(game.all_winners()))
	_finished_section()


func _test_shared() -> void:
	_section("shared progress, when a server wants it")
	var a: LmPlayer = game.players[&"a"]
	var c := game.join(&"c", "C")
	game.send_to(a, 3)
	game.send_to(c, 3)
	game.config.shared_progress = true
	var level: LmLevel = game.levels[3]
	var item_id: String = level.items.keys()[0]
	_stand_before(a, level, (level.items[item_id]["at"] as Vector3) + Vector3(0, 0.9, 0))
	var _said := game.interact(&"a")
	_check(not (a.taken.is_empty() and a.opened.is_empty() and a.used.is_empty()) and c.taken == a.taken and c.opened == a.opened and c.used == a.used,
		"what one does, everybody on the level has", "%s / %s" % [a.describe(), c.describe()])
	game.config.shared_progress = false
	_finished_section()


## What the house does to a player on the way, the server's half: each event fires once a go,
## when its condition comes true for that player alone.
func _test_events() -> void:
	_section("what the house does on the way")
	var p: LmPlayer = game.players[&"a"]
	var level: LmLevel = game.levels[8]
	var of_kind := {}
	for id: String in level.events:
		var kind := str(level.events[id].get("do", ""))
		if not of_kind.has(kind):
			of_kind[kind] = level.events[id]
	var heard: Array = []
	var listen := func(key: StringName, id: String) -> void:
		if key == &"a":
			heard.append(id)
	game.event_fired.connect(listen)

	# The lights: taking what was in the room puts them out.
	game.send_to(p, 8)
	var lights: Dictionary = of_kind["lights"]
	var item_id := str(lights["when"]["holds"])
	_stand_before(p, level, (level.items[item_id]["at"] as Vector3) + Vector3(0, 0.9, 0))
	var _took := game.interact(&"a")
	_check(p.fired.has(str(lights["id"])) and heard.has(str(lights["id"])), "taking what was in a lit room puts its lights out", str(p.fired.keys()))

	# The slam: into the room past the door, and once clear of the doorway it shuts.
	game.send_to(p, 8)
	var slam: Dictionary = of_kind["slam"]
	var door_id := str(slam["door"])
	var door: Dictionary = level.doors[door_id]
	var lock := str(door["doc"].get("lock", ""))
	if lock != "":
		p.holds.append(lock)
	_unlock(p, door_id)
	p.place_at(level.position + (door["centre"] as Vector3) + (door["normal"] as Vector3) * 1.0 + Vector3(0, 0.1, 0), 0.0)
	game.fire_events(p)
	var waited := p.opened.has(door_id) and not p.fired.has(str(slam["id"]))
	p.place_at(level.position + _furthest_from(level, str(door["doc"]["b"]), door["centre"]) + Vector3(0, 0.1, 0), 0.0)
	game.fire_events(p)
	_check(waited and not p.opened.has(door_id) and p.fired.has(str(slam["id"])),
		"a door slams behind you, once you are clear of the doorway", "waited %s, %s" % [waited, p.describe()])
	_stand_before(p, level, (door["centre"] as Vector3) + Vector3(0, 1.2, 0))
	var _reopened := game.interact(&"a")
	_check(p.opened.has(door_id), "and opens again, with what opened it the first time")

	# Her, at the end of a long corridor.
	game.send_to(p, 8)
	var glimpse: Dictionary = of_kind["glimpse"]
	p.place_at(level.position + level.room_centre(str(glimpse["room"])) + Vector3(0, 0.1, 0), 0.0)
	game.fire_events(p)
	_check(p.fired.has(str(glimpse["id"])), "walking into a long corridor is when she stands at the end of it")
	var count := heard.size()
	game.fire_events(p)
	_check(heard.size() == count, "each happens once")
	game.send_to(p, 8)
	_check(p.fired.is_empty() and p.slams_waiting.is_empty(), "and again on the next go at the level")
	game.event_fired.disconnect(listen)
	_finished_section()


## The point in [param room_id] furthest from [param from] (level-local), on its floor.
func _furthest_from(level: LmLevel, room_id: String, from: Vector3) -> Vector3:
	var best := Vector3.ZERO
	var far := -1.0
	for fx in [0.15, 0.5, 0.85]:
		for fz in [0.15, 0.5, 0.85]:
			var at := level._room_point(room_id, [fx, fz])
			if at.distance_to(from) > far:
				far = at.distance_to(from)
				best = at
	return best


func _test_houses() -> void:
	_section("houses")
	_check(game.houses.size() == 2 and game.houses.has(&"asylum") and game.house_id == &"house", "two houses, playing the House (%s)" % [game.houses.keys()])
	var a: LmPlayer = game.players[&"a"]
	a.best = 9
	game.send_to(a, 9)
	var told := [&""]
	game.house_changed.connect(func(id: StringName) -> void: told[0] = id)
	var changed := game.change_house(&"asylum")
	_check(changed.ok and told[0] == &"asylum" and game.levels.size() == 16 and game.house_name() == "The Asylum", "the Asylum opens: sixteen levels")
	_check(a.level == 1 and a.best == 1, "and everybody starts again in its lobby")
	_check(not game.change_house(&"nowhere").ok, "a house that does not exist is refused")
	var _back := game.change_house(&"house")
	_check(game.levels.size() == 32, "and the House comes back")
	_finished_section()


# --- Harness -----------------------------------------------------------------

## A real offline client, booted: its settings are read by the camera and the look, and
## Escape opens the screen. Escape used to let go of the mouse and offer nothing to click.
func _test_the_client_settings() -> void:
	_section("the client's settings are read, and Escape opens them")
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	add_child(client)

	for i in 6:
		await get_tree().process_frame

	var settings: Variant = client.get("settings")
	var camera: Camera3D = client.get("camera")
	_check(
		settings != null and int(settings.describe().get("look_bound", 0)) > 0 \
			and camera != null and bool(settings.describe().get("camera_bound", false)) \
			and is_equal_approx(camera.fov, float(settings.settings.get_int(&"field_of_view", 0))),
		"the client's settings are read by its look and its camera",
		str(settings.describe()) if settings != null else "no settings"
	)
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	client.call("_unhandled_input", escape)
	_check(settings != null and settings.is_open(), "and Escape opens them")
	settings.close()

	# The Tab board, held: the menu's, drawn from the local world offline.
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	client.call("_unhandled_input", tab)
	var board: DotMenuScoreboard = client.get("board")
	_check(board != null and board.is_open() and board.rows().any(func(r: Dictionary) -> bool:
			return bool(r.get("you", false)) and int(r.get("level", 0)) >= 1),
		"Tab holds the board up, with this player and the level they are on",
		str(board.rows()) if board != null else "no board")
	tab.pressed = false
	client.call("_unhandled_input", tab)
	_check(board != null and not board.is_open(), "and letting go puts it away")

	# The family's rule since the first play test: H opens help, nothing else in the table is
	# on H, the Escape menu has Help and Leave, and the flashlight is read through its row.
	var keys: DotMenuBindings = settings.bindings
	var menu: DotMenu = settings.menu
	_check(keys.key_for(DotMenuBindings.HELP_ACTION) == "H" and keys.defaults_on("H").size() == 1,
		"help is on H, and nothing else in the table is")
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(menu.handle_event(h) and menu.help.is_open(), "H opens the help screen")
	_check(menu.help.about != "" and menu.help.heading() == "How to play Look at Me",
		"which says what the game is before the keys")
	menu.help.close()
	settings.open()
	var leave := menu.screen.find_child("Action_leave", true, false) as Button
	_check(menu.screen.find_child("Action_help", true, false) != null and leave != null and leave.visible,
		"the Escape menu has Help & commands and Leave")

	settings.close()
	var f := InputEventKey.new()
	f.physical_keycode = KEY_F
	_check(f.is_action(&"lm_flashlight") and not f.is_action(DotMenuBindings.HELP_ACTION),
		"the flashlight is its table row's action, on F")

	# Something in reach: dot-ui's DotKeyPrompt says what, with the use action's binding drawn
	# as the key, and that key does it.
	var LmClientScript: GDScript = load("res://game/lm_client.gd")
	var me: LmPlayer = client.get("player")
	var here: LmLevel = client.get("game").level_of(me)
	var item_id: String = here.items.keys()[0]
	_stand_before(me, here, (here.items[item_id]["at"] as Vector3) + Vector3(0, 0.9, 0))
	await _drawn()
	var prompt: DotKeyPrompt = client.get("prompt")
	var use_key := DotInputBinding.describe_action(LmClientScript.get("USE_ACTION"))
	_check(
		prompt != null and prompt.visible and prompt.words.begins_with("Take the ") and use_key != "" and prompt.key == use_key,
		"an item in reach is a DotKeyPrompt with the use action's binding as its key",
		str(prompt.describe()) if prompt != null else "no prompt"
	)
	var use := InputEventKey.new()
	use.physical_keycode = OS.find_keycode_from_string(use_key) as Key
	use.pressed = true
	client.call("_unhandled_input", use)
	_check(me.holds.size() + me.taken.size() > 0, "and that key takes it", "%s %s" % [me.holds, me.taken])

	# Rebound on the Controls page (its setting), the prompt and the key line say the new key.
	var _rebound: Variant = settings.settings.set_value(&"bind_use", "R")
	_stand_before(me, here, (here.items[here.items.keys()[-1]]["at"] as Vector3) + Vector3(0, 0.9, 0))
	client.call("_refresh_key_line")
	await _drawn()
	var key_line: Label = client.get("_key_line")
	_check(DotInputBinding.describe_action(LmClientScript.get("USE_ACTION")) == "R" and key_line.text.begins_with("R use")
		and (not prompt.visible or prompt.key == "R"),
		"use rebound to R: the action, the prompt and the key line all say R", "%s | %s" % [key_line.text, prompt.describe()])
	_rebound = settings.settings.set_value(&"bind_use", "E")
	client.call("_refresh_key_line")

	# At 1280 x 720: the prompt under the crosshair, the chat box's full log bottom left and a
	# ballot where the client shell draws one (a column down the right from 110 px) never meet.
	var box: DotGameChatClient = LmClientScript.call("new_chat")
	add_child(box)
	var w: DotChatWindow = box.window
	var log_top := w.margin_bottom + w.entry_height + float(w.max_lines) * (w.line_height + w.line_gap)
	var chat_rect := Rect2(w.margin_left, 720.0 - log_top, w.width, log_top - w.margin_bottom)
	box.queue_free()
	prompt.show_prompt("Take the brass candlestick from the mantelpiece", use_key)
	var shown := prompt.footprint()
	var prompt_rect := Rect2(Vector2(640.0 + prompt.offset_left, 360.0 + prompt.offset_top) + shown.position, shown.size)
	var ballot_rect := Rect2(904.0, 110.0, 360.0, 250.0)
	_check(
		not chat_rect.intersects(prompt_rect) and not chat_rect.intersects(ballot_rect) and not prompt_rect.intersects(ballot_rect),
		"the prompt, the chat box and a ballot do not meet",
		"prompt %s, chat %s, ballot %s" % [prompt_rect, chat_rect, ballot_rect]
	)

	# Christian's first play test: a darker HUD by default, restyled live by the menu's theme.
	var plate := prompt.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7 and prompt.colour(&"highlight") == LmClientScript.get("LAMP_COLOUR"),
		"the HUD is dark by default, in the menu's theme, with the lamp's amber as its accent", str(plate))
	var _t: Variant = settings.settings.set_value(&"ui_theme", &"contrast")
	var step_label: Label = client.get("_step")
	_check(prompt.colour(&"plate") == menu.palette().hud_plate and step_label.get_theme_color(&"font_color") == menu.palette().hud_text
		and prompt.colour(&"highlight") == LmClientScript.get("LAMP_COLOUR"),
		"a theme picked in the menu reaches the prompt and the HUD's lines at once, the accent kept")
	_t = settings.settings.set_value(&"ui_theme", &"midnight")

	# M, the family's rule since the first play test: the house list, and solo a choice
	# changes it now. The server's half (the owner's flag, the vote) is in `dedicated`.
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table is",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	# Closed right before the key: an offline client with no captured pointer (headless) may
	# have put its menu back up, and while anything is open every key is the menu's.
	menu.close_all()
	var map_before: StringName = (client.get("game") as LmGame).house_id
	var m_key := InputEventKey.new()
	m_key.physical_keycode = KEY_M
	m_key.keycode = KEY_M
	m_key.pressed = true
	_check(menu.handle_event(m_key) and menu.picker.is_open() and menu.picker.items.size() > 1,
		"M opens the house list, more than one to choose", str(menu.picker.items.size()))
	var wanted_map: StringName = &""
	var map_key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted_map = StringName(str((it as Dictionary)["id"]))
			map_key = KEY_0 + row
			break
	var digit_key := InputEventKey.new()
	digit_key.physical_keycode = map_key
	digit_key.keycode = map_key
	digit_key.pressed = true
	var _picked := menu.handle_event(digit_key)
	for _i in 4:
		await get_tree().physics_frame
	_check(wanted_map != &"" and (client.get("game") as LmGame).house_id == wanted_map and not menu.picker.is_open(),
		"choosing one changes the house now", "%s, now %s" % [wanted_map, (client.get("game") as LmGame).house_id])
	# Back where it was, for the checks after this one.
	var _back: Variant = await menu.maps.change_fn.call(map_before)
	for _i in 4:
		await get_tree().physics_frame
	# And the prompt still says what is in reach in the house it came back to.
	var home: LmLevel = client.get("game").level_of(me)
	var home_item: String = home.items.keys()[0]
	_stand_before(me, home, (home.items[home_item]["at"] as Vector3) + Vector3(0, 0.9, 0))
	await _drawn()
	_check(prompt.visible and prompt.words.begins_with("Take the "),
		"after a house change and back, an item in reach is still prompted", str(prompt.describe()))

	# A pack naming these classes does not parse on a shell whose dot-ui predates them, so the
	# requires.json dot-ci derives must ask for dot-ui 4, and nothing may lower it.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 4 and not FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 4, the glance pieces",
		str(asks.get("dot_ui"))
	)

	remove_child(client)
	client.free()
	await get_tree().process_frame

	# A document saved when the view was on C: it follows to F5, and a key the player chose
	# stays where they put it.
	var old_doc := DotSettingsStoreMemory.new()
	var _saved_old := old_doc.save_document(LmSettings.APP_NAMESPACE, &"local", {"version": 1, "values": {
		"bind_view": "C", "bind_flashlight": "J",
	}})
	var returning := LmSettings.new()
	add_child(returning)
	var _set_up := returning.setup(old_doc, false)
	var rk: DotMenuBindings = returning.bindings
	_check(rk.key_for(&"lm_view") == "F5", "an old settings file with the view on C: it moves to F5", rk.key_for(&"lm_view"))
	_check(rk.key_for(&"lm_flashlight") == "J", "and a key the player chose is kept", rk.key_for(&"lm_flashlight"))
	returning.queue_free()
	await get_tree().process_frame
	_finished_section()


## The client's sounds and the catch's effects, through dot-audio and dot-fx. Headless has no
## sound device, so the manager runs its null sink, which is the real limits and catalogue
## with a log in place of a speaker; tools/audio_probe (xvfb) is what says a sound is heard.
func _test_sound_and_effects() -> void:
	_section("the house's sounds and the catch, through dot-audio and dot-fx")
	var LmAudio: GDScript = load("res://game/lm_audio.gd")
	var catalogue: DotAudioCatalogue = LmAudio.call("sound_catalogue")
	var ids: Array = LmAudio.call("ids")
	_check(
		catalogue.validate().ok and ids.all(func(id: StringName) -> bool: return catalogue.find(id) != null)
			and catalogue.missing_files().is_empty(),
		"every sound the game names is in its catalogue, and every file it names is there",
		str(catalogue.missing_files())
	)

	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	client.set("start_level", 8)
	add_child(client)

	for i in 6:
		await get_tree().process_frame

	var audio: Node = client.get("audio")
	var player: LmPlayer = client.get("player")
	var sink := audio.get("manager").get("sink") as DotAudioSinkNull if audio != null else null
	var settings: Variant = client.get("settings")
	_check(
		sink != null and settings != null and bool(settings.describe().get("audio_bound", false)),
		"the sounds are dot-audio's, and the volume settings reach its mixer",
		str(settings.describe()) if settings != null else "no settings"
	)

	# Stand where her round starts: how far the nearest witch is from the start room depends on
	# the house's layout, and her hum is only heard within the mixer's range.
	var heard_level := (client.get("game") as LmGame).levels[8] as LmLevel
	var round_start: Array = (heard_level.doc["witches"][0]["path"] as Array)[0]
	player.place_at(heard_level.position + heard_level.room_centre(str(round_start[1])), 0.0)

	for i in 90:
		player.meter = 0.9
		await get_tree().process_frame

	var _clicked: bool = audio.call("click")
	_check(
		sink != null and sink.count_of(&"heartbeat") >= 1 and sink.count_of(&"click") == 1 \
			and int(audio.call("droning")) > 0,
		"a heartbeat at a high meter, a click, and the drone of a witch nearby",
		"%s player %s views %s" % [str(sink.played_ids()) if sink != null else "no sink", str(player.global_position), str((client.get("_witch_views") as Dictionary).values().map(func(v: Node3D) -> Vector3: return v.global_position))]
	)
	var unknown := PackedStringArray()

	if sink != null:
		for id in sink.played_ids():
			if catalogue.find(StringName(id)) == null:
				unknown.append(id)

	_check(sink != null and sink.played().size() > 0 and unknown.is_empty(),
		"every id the client played is in the catalogue", str(unknown))

	var effects: DotFxManager = client.get("effects")
	player.meter = 0.0
	player.caught_left = 1.0
	await get_tree().process_frame
	var flashed := effects != null and effects.flash_colour.a > 0.0 and effects.shake.trauma() > 0.0
	_check(flashed, "being caught flashes red and jolts the view, through dot-fx",
		str(effects.describe()) if effects != null else "no effects")

	# "Allow flashes" off: the settings reach dot-fx, and the next catch is not flashed.
	player.caught_left = 0.0
	await get_tree().process_frame
	effects.flash_colour.a = 0.0
	settings.settings.set_value(&"allow_flashes", false)
	player.caught_left = 1.0
	await get_tree().process_frame
	_check(effects != null and is_zero_approx(effects.flash_colour.a),
		"and not when the player has turned flashes off")
	settings.settings.set_value(&"allow_flashes", true)

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished_section()


## Real mouse motion, through Input the way a mouse delivers it, turns the camera. Nothing fed
## the samplers a mouse event, so the view only ever turned when the player walked; every other
## check set angles directly and passed. Found by Christian's first play test (2026-10-11).
func _test_the_mouse_turns_the_view() -> void:
	_section("the mouse turns the view")
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	add_child(client)

	for i in 6:
		await get_tree().process_frame

	# Headless has no pointer to capture; this says "the pointer is ours" as a window would.
	client.set("mouse_capture_override", true)
	var camera: Camera3D = client.get("camera")
	var start := camera.global_basis.get_euler()
	await _move_mouse(Vector2(120, 0))
	var turned := camera.global_basis.get_euler()
	_check(absf(angle_difference(start.y, turned.y)) > deg_to_rad(2.0),
		"mouse motion sideways turns the camera",
		"yaw %.1f -> %.1f" % [rad_to_deg(start.y), rad_to_deg(turned.y)])
	await _move_mouse(Vector2(0, 80))
	var tilted := camera.global_basis.get_euler()
	_check(absf(tilted.x - turned.x) > deg_to_rad(2.0),
		"and up and down tilts it",
		"pitch %.1f -> %.1f" % [rad_to_deg(turned.x), rad_to_deg(tilted.x)])

	# The menu stops the look while it is up and gives it back when it closes.
	var settings: Variant = client.get("settings")
	settings.open()
	await get_tree().process_frame
	var held := camera.global_basis.get_euler()
	await _move_mouse(Vector2(120, 0))
	_check(absf(angle_difference(held.y, camera.global_basis.get_euler().y)) < deg_to_rad(0.1),
		"the menu up, the mouse does not turn the view")
	settings.close()
	await get_tree().process_frame
	var back := camera.global_basis.get_euler()
	await _move_mouse(Vector2(-120, 0))
	_check(absf(angle_difference(back.y, camera.global_basis.get_euler().y)) > deg_to_rad(2.0),
		"and closed, it turns it again",
		"yaw %.1f -> %.1f" % [rad_to_deg(back.y), rad_to_deg(camera.global_basis.get_euler().y)])

	remove_child(client)
	client.free()
	await get_tree().process_frame

	# Connected, the sampler that is sent is the client's own, not the player's: the same
	# event must reach that one. Not put in the tree, which would build a house of its own.
	var connected: Node = (load("res://game/lm_client.gd") as GDScript).new()
	var sampler := DotFpsSampler.new(DotFpsTunables.new())
	connected.set("_offline", false)
	connected.set("_sampler", sampler)
	connected.set("mouse_capture_override", true)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(100, 0)
	connected.call("_input", motion)
	_check(absf(sampler.look_now().x) > 1.0, "connected, the client's own sampler takes the mouse",
		"yaw %.1f" % sampler.yaw)
	connected.free()
	_finished_section()


## The witch a player meets, and the house around her, as the client draws and plays them
## (2026-10-12: the first play test saw no witch in 36 s and heard nearly nothing). The null
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
	_check(sink.count_of(&"ambience") >= 1, "the house's ambience plays under it all")

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


func _along(level: LmLevel, stair: String, at: Vector3) -> float:
	return level._along_stair(level.rooms[stair], at)


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


## A mouse movement in a few events, as a device sends them, then frames for ticks to run.
func _move_mouse(by: Vector2) -> void:
	for i in 4:
		var motion := InputEventMouseMotion.new()
		motion.relative = by / 4.0
		motion.screen_relative = by / 4.0
		Input.parse_input_event(motion)
		await get_tree().process_frame

	for i in 4:
		await get_tree().physics_frame
	await get_tree().process_frame


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

	for _i in 240:
		var seconds := game.seconds_now() + delta
		var pose := level.witch_pose(0, seconds, config.witch_speed_scale, config.witch_head_sweep, dwell)
		var facing := float(pose["facing"])
		p.place_at(level.position + (pose["at"] as Vector3) + Vector3(sin(facing), 0, cos(facing)) * 4.0, 0.0)
		p.noise_left = 1.0
		game.tick += 1
		game._listen(p, level, seconds, delta)
		steps += 1
		var state: Dictionary = p.gaze.get(0, {})

		if state.is_empty():
			continue

		if not first:
			worst_turn = maxf(worst_turn, absf(wrapf(float(state["head"]) - last_head, -PI, PI)))

		first = false
		last_head = float(state["head"])

		if alerted_at < 0 and bool(state["alert"]):
			alerted_at = steps

	_check(alerted_at > 0, "a noise behind her is heard", str(alerted_at))
	_check(float(alerted_at) * delta >= config.witch_reaction_seconds - 0.02, "but not at once: she takes her reaction time", "%.2f s" % (float(alerted_at) * delta))
	_check(worst_turn <= deg_to_rad(config.witch_turn_rate) * delta * 1.02, "and her head never turns faster than the turn rate", "%.2f deg a tick" % rad_to_deg(worst_turn))
	_check(absf(last_head) > deg_to_rad(90.0), "she ends up looking round at where it came from", "%.0f deg" % rad_to_deg(last_head))

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


## Proximity voice as this game configures it: the gain a listener gets at distance, a wall
## turning it down, nothing past the radius, and a witch hearing a talker.
func _test_voice() -> void:
	_section("voice: proximity with a short radius, a wall turns it down, witches hear it")
	var services := LmServices.new()
	services.game = game
	var router := DotVoiceRouter.new()
	var format := LmServices.voice_format()
	router.config = format
	router.default_channel = LmServices.new()._voice_default_channel()
	services.configure_voice(router)
	_check(router.default_channel == DotVoiceRouter.Channel.PROXIMITY, "voice is proximity by default")
	_check(router.proximity_range == LmServices.PROXIMITY_RANGE and router.proximity_range <= 20.0, "with a short radius", str(router.proximity_range))
	_check(router.proximity_occlusion and router.occlusion_fn.is_valid(), "and a wall in the way is on")
	var specs := {}

	for spec in router.cvar_specs():
		specs[String(spec["name"])] = String(spec["value"])

	_check(specs.get("sv_voice_proximity_occlusion", "") == "1" and specs.get("sv_voice_proximity_range", "") == str(LmServices.PROXIMITY_RANGE), "the sv_voice_* cvars default to those", str(specs))

	var level: LmLevel = game.levels[1]
	var centre: Vector3 = level.position + level.room_centre(level.spawn_room())
	var space := game.get_world_3d().direct_space_state
	var head := Vector3.UP * 1.6
	var clear_at := Vector3.ZERO
	var wall_at := Vector3.ZERO
	var dirs: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]

	for dir in dirs:
		for step in range(6, 25):
			var d := float(step) * 0.5
			var at := centre + dir * d
			var hit := not space.intersect_ray(PhysicsRayQueryParameters3D.create(centre + head, at + head, LmGame.LAYER_WORLD)).is_empty()

			if not hit and d >= 3.0 and clear_at == Vector3.ZERO:
				clear_at = at
			if hit and wall_at == Vector3.ZERO and d >= 4.0:
				wall_at = at

	_check(clear_at != Vector3.ZERO and wall_at != Vector3.ZERO, "the first room has open floor and a wall to test through", "%s %s" % [clear_at, wall_at])

	var places := {1: centre, 2: clear_at, 3: wall_at, 4: centre + Vector3(0.5, 0, 0), 5: centre + Vector3(60, 0, 0)}
	router.position_fn = func(peer: int) -> Vector3: return places.get(peer, Vector3.ZERO)
	var heard := {}
	router.send_fn = func(peer: int, bytes: PackedByteArray) -> void:
		var parsed := DotVoicePacket.from_bytes(bytes)
		heard[peer] = parsed.value.gain if parsed.ok else -1.0

	for peer in places:
		router.add_peer(peer)

	var packet := DotVoicePacket.new()
	packet.speaker = 1
	packet.sample_count = format.frame_samples()
	packet.channel = DotVoiceRouter.Channel.PROXIMITY
	packet.codec_id = &"adpcm"
	packet.payload = DotVoiceCodec.instance_for(&"adpcm").encode(DotVoiceSourceBuffer.tone(300.0, 0.02, format.sample_rate, 0.4))
	var relayed := router.relay(1, packet.to_bytes())
	_check(relayed.ok, "a frame relays", str(relayed.error))

	var expected_clear := DotVoiceProximity.gain(centre.distance_to(clear_at), router.proximity_range, router.proximity_min_distance, router.proximity_falloff)
	var expected_wall := DotVoiceProximity.gain(centre.distance_to(wall_at), router.proximity_range, router.proximity_min_distance, router.proximity_falloff) * router.occlusion_gain
	_check(heard.has(4) and is_equal_approx(heard[4], 1.0), "a player 0.5 m away hears full volume", str(heard.get(4)))
	_check(heard.has(2) and absf(heard[2] - expected_clear) < 0.02 and heard[2] < 1.0, "a player in the open at distance hears the falloff's gain", "%.3f expected %.3f" % [heard.get(2, -1.0), expected_clear])
	_check(heard.has(3) and absf(heard[3] - expected_wall) < 0.02, "through a wall it is turned down by the occlusion gain", "%.3f expected %.3f" % [heard.get(3, -1.0), expected_wall])
	_check(heard.has(3) and heard.has(2) and expected_wall < expected_clear and not heard.has(5), "a wall is quieter than open floor, and past the radius nothing is sent")

	# Witches: a relayed frame is a sound for a moment, and the cvar's field turns it off.
	var p: LmPlayer = game.players[&"a"]
	p.voice_left = 0.0
	var quiet := game.noise_radius(p)
	game.hear_voice(&"a")
	var loud := game.noise_radius(p)
	_check(quiet == 0.0 and absf(loud - game.config.witch_hear_range) < 0.001, "a talker is heard by witches as far as a run", "%.1f then %.1f m" % [quiet, loud])
	game.config.witch_hear_voice = false
	p.voice_left = 0.0
	game.hear_voice(&"a")
	_check(game.noise_radius(p) == 0.0, "and not when the switch is off")
	game.config.witch_hear_voice = true
	p.voice_left = 0.0

	services.free()
	router.free()
	await get_tree().process_frame
	_finished_section()


## Sanity scares, demons and the look-behind whisper: the director's schedule against the meter,
## what a sighting starts, an approach, a stare, a turn; then the same drawn and heard by a client.
func _test_scares() -> void:
	_section("scares: sanity scares by the meter, demons after a sighting, approach, look behind")
	var config := LmConfig.new()
	_check(LmScares.interval_for(config, 0.0) > LmScares.interval_for(config, 0.5) and LmScares.interval_for(config, 0.5) > LmScares.interval_for(config, 1.0),
		"a sanity scare comes sooner as the meter climbs", "%.0f, %.0f, %.0f s" % [LmScares.interval_for(config, 0.0), LmScares.interval_for(config, 0.5), LmScares.interval_for(config, 1.0)])

	var calm := _scare_night(1, 0.0, 1800.0)
	var haunted := _scare_night(1, 0.9, 1800.0)
	var calm_scares := calm.filter(func(e: Dictionary) -> bool: return e["kind"] == LmScares.SCARE)
	var haunted_scares := haunted.filter(func(e: Dictionary) -> bool: return e["kind"] == LmScares.SCARE)
	_check(haunted_scares.size() >= calm_scares.size() * 3 and calm_scares.size() >= 1,
		"half an hour at a high meter has several times the scares of an empty one", "%d against %d" % [haunted_scares.size(), calm_scares.size()])
	_check(JSON.stringify(_scare_night(1, 0.9, 600.0)) == JSON.stringify(_scare_night(1, 0.9, 600.0)) and JSON.stringify(_scare_night(1, 0.9, 600.0)) != JSON.stringify(_scare_night(2, 0.9, 600.0)),
		"the same seed is the same night, another seed another")

	var gaps_ok := true
	var last := -1000.0
	for e: Dictionary in haunted:
		if e["kind"] == LmScares.SCARE:
			gaps_ok = gaps_ok and float(e["t"]) - last >= config.scare_cooldown - 0.01
			last = float(e["t"])
	_check(gaps_ok, "no two scares closer than the cooldown", "%.0f s" % config.scare_cooldown)

	var off := LmConfig.new()
	off.scares_enabled = false
	_check(_scare_night(1, 0.9, 600.0, off).filter(func(e: Dictionary) -> bool: return e["kind"] == LmScares.SCARE).is_empty(),
		"lm_scares_enabled off is no scares")

	# Demons: none before a witch has seen you; after, one in the corner of the view.
	var dir := LmScares.new(LmConfig.new())
	var view := {"meter": 0.0, "level": 1, "eye": Vector3(0, 1.6, 0), "feet": Vector3.ZERO, "forward": Vector3.FORWARD, "caught": false}
	var shown_before := 0
	for i in 600:
		for e in dir.tick(0.5, view):
			if e["kind"] == LmScares.DEMON_SHOWS:
				shown_before += 1
	_check(shown_before == 0 and dir.demons.is_empty(), "no demon while no witch has seen you", str(shown_before))

	view["meter"] = 0.3
	var spawned: Dictionary = {}
	var whispered := false
	for i in 200:
		for e in dir.tick(0.25, view):
			if e["kind"] == LmScares.DEMON_SHOWS and spawned.is_empty():
				spawned = e
			whispered = whispered or e["kind"] == LmScares.WHISPER
		if not spawned.is_empty():
			break
	_check(not spawned.is_empty() and dir.sighted, "after a sighting a demon shows within its spawn window", "%.0f s" % (float(dir.told.size())))
	var at: Vector3 = spawned.get("at", Vector3.ZERO)
	var off_axis := rad_to_deg(Vector3.FORWARD.angle_to(Vector3(at.x, 0.0, at.z).normalized())) if not spawned.is_empty() else 0.0
	var away := Vector2(at.x, at.z).length()
	_check(off_axis >= config.demon_corner_min - 0.5 and off_axis <= config.demon_corner_max + 0.5 and away >= config.demon_distance_min - 0.01 and away <= config.demon_distance_max + 0.01,
		"in the corner of the view, at its distance", "%.0f degrees, %.1f m" % [off_axis, away])
	_check(whispered, "and it whispers from where it stands")

	# Approach: walk at it, it jumps, with a spike for the meter, and is gone.
	var spiked := 0.0
	var gone := false
	for i in 80:
		view["eye"] = (view["eye"] as Vector3).move_toward(Vector3(at.x, 1.6, at.z), 0.25)
		for e in dir.tick(0.1, view):
			if e["kind"] == LmScares.DEMON_JUMPS:
				spiked = float(e["spike"])
	gone = dir.demons.is_empty() or not dir.demons.any(func(d: Dictionary) -> bool: return int(d["id"]) == int(spawned["id"]))
	_check(spiked == config.demon_meter_spike and gone, "walking up to it makes it jump you, then it vanishes", "spike %.2f" % spiked)

	# The server's side of the spike: it raises the meter, to the cap and no further, and not twice at once.
	game.config.scare_cooldown = 10.0
	var key := &"scare_test"
	var guest := game.join(key, "Scare")
	guest.meter = 0.2
	game.tick += 600
	_check(game.spook(key, 0.25) and absf(guest.meter - 0.45) < 0.001, "the house applies the spike to the meter", "%.2f" % guest.meter)
	_check(not game.spook(key, 0.25) and absf(guest.meter - 0.45) < 0.001, "and refuses a second inside the cooldown")
	game.tick += 600
	guest.meter = 0.8
	var _again := game.spook(key, 0.25)
	_check(guest.meter <= game.config.scare_meter_cap + 0.001 and guest.meter > 0.8 - 0.001, "and never past the cap, so a fright is never a catch", "%.2f" % guest.meter)
	game.leave(key)

	# A stare sends it away, no jump.
	var stare := LmScares.new(LmConfig.new())
	view["eye"] = Vector3(0, 1.6, 0)
	view["meter"] = 0.4
	var target := {}
	for i in 400:
		for e in stare.tick(0.25, view):
			if e["kind"] == LmScares.DEMON_SHOWS and target.is_empty():
				target = e
		if not target.is_empty():
			break
	var look := (target["at"] as Vector3) - Vector3(0, 0, 0)
	view["forward"] = Vector3(look.x, 0.0, look.z).normalized()
	var seen_off := false
	var jumped := false
	for i in 60:
		for e in stare.tick(0.1, view):
			seen_off = seen_off or (e["kind"] == LmScares.DEMON_GONE and e["why"] == "seen")
			jumped = jumped or e["kind"] == LmScares.DEMON_JUMPS
	_check(seen_off and not jumped, "looking straight at it long enough sends it away without a jump")

	# Look behind: the whisper, then turning round inside the window.
	var back_config := LmConfig.new()
	back_config.look_behind_min = 5.0
	back_config.look_behind_max = 6.0
	back_config.scares_enabled = false
	var turn := LmScares.new(back_config)
	view = {"meter": 0.0, "level": 1, "eye": Vector3(0, 1.6, 0), "feet": Vector3.ZERO, "forward": Vector3.FORWARD, "caught": false}
	var whisper_at := Vector3.INF
	for i in 200:
		for e in turn.tick(0.1, view):
			if e["kind"] == LmScares.BEHIND_WHISPER:
				whisper_at = e["at"]
		if whisper_at != Vector3.INF:
			break
	_check(whisper_at != Vector3.INF and whisper_at.z > 0.5, "a whisper \"look behind you\" comes from behind the player", str(whisper_at))
	view["forward"] = Vector3.BACK
	var scare_at := Vector3.INF
	var behind_spike := -1.0
	for i in 10:
		for e in turn.tick(0.1, view):
			if e["kind"] == LmScares.BEHIND_SCARE:
				scare_at = e["at"]
				behind_spike = float(e["spike"])
	_check(scare_at != Vector3.INF and scare_at.z > 1.0 and behind_spike == back_config.look_behind_spike,
		"turning round inside the window puts a scare where they look, behind where they were", str(scare_at))

	var slow := LmScares.new(back_config)
	view["forward"] = Vector3.FORWARD
	var whispers := 0
	var scares_seen := 0
	for i in 140:
		for e in slow.tick(0.1, view):
			whispers += 1 if e["kind"] == LmScares.BEHIND_WHISPER else 0
			scares_seen += 1 if e["kind"] == LmScares.BEHIND_SCARE else 0
	_check(whispers >= 1 and scares_seen == 0 and slow.behind.size() <= 3, "a player who never turns round is not scared by it", "%d whispers" % whispers)

	# Drawn and heard: a client with a sighting shows a demon and whispers; a jump flashes.
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	client.set("start_level", 3)
	add_child(client)
	for i in 6:
		await get_tree().process_frame
	var me: LmPlayer = client.get("player")
	var sink := client.get("audio").get("manager").get("sink") as DotAudioSinkNull
	var view_node: Node3D = client.get("scare_view")
	var director: LmScares = client.get("scares")
	director.config.demon_spawn_min = 1.0
	director.config.demon_spawn_max = 1.5
	director.config.demon_corner_min = 25.0
	director.config.look_behind_enabled = false
	director.config.scares_enabled = false
	me.meter = 0.3
	for i in 400:
		me.meter = 0.3
		await get_tree().process_frame
		if not director.demons.is_empty():
			break
	_check(not director.demons.is_empty() and view_node.find_child("Demon1", true, false) != null, "the client draws a demon once the meter says a witch saw it", str(view_node.describe()))
	_check(sink.count_of(&"whisper") >= 1, "and the whisper is heard", str(sink.count_of(&"whisper")))
	var jolts := sink.count_of(&"scare_hit")
	var meter_before := me.meter
	var demon: Dictionary = director.demons[0]
	var drawn_at: Vector3 = (view_node.get("_figures") as Dictionary)[int(demon["id"])].global_position if (view_node.get("_figures") as Dictionary).has(int(demon["id"])) else Vector3.INF
	_check(drawn_at.distance_to(demon["at"] as Vector3) < 0.01, "at the spot the director chose", str(drawn_at))
	me.global_position = demon["at"] as Vector3
	me.controller.state.position = demon["at"] as Vector3
	for i in 8:
		await get_tree().process_frame
	_check(sink.count_of(&"scare_hit") > jolts and me.meter > meter_before and director.demons.is_empty(),
		"walking into it: a sound, the meter up, the demon gone", "%d to %d, %.2f to %.2f" % [jolts, sink.count_of(&"scare_hit"), meter_before, me.meter])
	client.queue_free()
	_finished_section()


## The events of [param seconds] of a night at a steady [param meter], each stamped "t".
func _scare_night(seed_value: int, meter: float, seconds: float, config: LmConfig = null) -> Array:
	var cfg := config if config != null else LmConfig.new()
	cfg.seed_value = seed_value
	var dir := LmScares.new(cfg)
	dir.reseed(seed_value, 1, 7)
	var view := {"meter": meter, "level": 1, "eye": Vector3(0, 1.6, 0), "feet": Vector3.ZERO, "forward": Vector3.FORWARD, "caught": false}
	var out: Array = []
	var t := 0.0

	while t < seconds:
		t += 0.5

		for e in dir.tick(0.5, view):
			var stamped := e.duplicate()
			stamped["t"] = t
			out.append(stamped)

	return out


func _section(name: String) -> void:
	_entered += 1
	print("")
	print(name)


func _finished_section() -> void:
	_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	else:
		_failed += 1
		var line := what if detail == "" else "%s  (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)
