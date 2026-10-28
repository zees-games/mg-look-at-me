extends DotGameCheckSuite

## The house, headless: shared state and helpers, then the first sections (see headless_run.gd).

const LmGame := preload("res://game/lm_game.gd")
const LmLevel := preload("res://game/lm_level.gd")
const LmPlayer := preload("res://game/lm_player.gd")
const LmProgress := preload("res://game/lm_progress.gd")
const LmSettings := preload("res://game/lm_settings.gd")
const LmServices := preload("res://game/lm_services.gd")
const LmScares := preload("res://game/lm_scares.gd")
const LmConfig := preload("res://game/lm_config.gd")
const LmBindings := preload("res://game/lm_bindings.gd")
const LmBot := preload("res://game/lm_bot.gd")

var _entered := 0
var _finished := 0
var game: LmGame = null
var _earned: Array = []


## Plays every level of the current house; returns the levels it could not get out of.
func _solve_house(solver: LmPlayer) -> PackedStringArray:
	var stuck := PackedStringArray()
	for n in range(1, game.levels.size() + 1):
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
	return stuck


## Puts [param player] 1.2 m back from [param at] (level-local), looking straight at it.
## Until the client has drawn a frame after now. One `process_frame` can resume in the same frame,
## before the client's `_process`, so a prompt read there is the frame before the player moved.
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


func _unlock(player: LmPlayer, door_id: String) -> void:
	player.opened[door_id] = true
	game._apply_doors(player)


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


## Waits for a booted client's loading cover to lift (dot-game's DotGameClient holds it until
## the player exists and the camera is current); everything is held under it.
func _shown(client: Node) -> void:
	for i in 240:
		await get_tree().process_frame
		var platform: Variant = client.get("platform")
		if platform != null and (platform as DotGameClient).is_shown():
			break
	for i in 2:
		await get_tree().process_frame


func _along(level: LmLevel, stair: String, at: Vector3) -> float:
	return level._along_stair(level.rooms[stair], at)


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


## A clown-only night: the player walks straight at whatever shows, every 0.1 s; returns the events.
func _scare_clown_night(who: int, meter: float, seconds: float, cfg: LmConfig) -> Array[Dictionary]:
	cfg.demons_enabled = false
	cfg.look_behind_enabled = false
	cfg.scares_enabled = false
	var d := LmScares.new(cfg)
	d.reseed(1, 1, who)
	var eye := Vector3(0, 1.6, 0)
	var out: Array[Dictionary] = []
	var t := 0.0
	while t < seconds:
		var view := {"meter": meter, "level": 1, "who": who, "eye": eye, "feet": Vector3.ZERO, "forward": Vector3.FORWARD, "caught": false}
		for e in d.tick(0.25, view):
			out.append(e)
		if not d.clown.is_empty():
			var at: Vector3 = d.clown["at"]
			eye = eye.move_toward(Vector3(at.x, 1.6, at.z), 1.0)
		else:
			eye = Vector3(0, 1.6, 0)
		t += 0.25
	return out


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
	# The second build of the levels (bigger and longer with more to do): about
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
	_levels_2()
	_levels_3()


func _levels_2() -> void:
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


func _levels_3() -> void:
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
	var stuck := _solve_house(solver)
	_check(stuck.is_empty(), "the solver opens the way out of all 32", ", ".join(stuck))

	# The Asylum's 17 as well, the last of them (Discharge) included.
	var _asylum := game.change_house(&"asylum")
	var asylum_stuck := _solve_house(solver)
	_check(game.levels.size() == 18 and asylum_stuck.is_empty(), "and out of all 18 of the Asylum's", ", ".join(asylum_stuck))
	# The Forgotten Wing: one big level laid out over a Workshop map's plan (51 rooms, about 10,800 m2).
	var _forgotten := game.change_house(&"forgotten")
	var forgotten_stuck := _solve_house(solver)
	_check(game.levels.size() == 1 and forgotten_stuck.is_empty(), "and out of the Forgotten Wing", ", ".join(forgotten_stuck))
	var wing: LmLevel = game.levels[1]
	# Much larger than any level of the other houses (level 32 is about 5,200 m2), nine witches walking
	# rounds that stay on the floor, and a long straight run she can be seen down.
	var wing_floating := 0
	for i in wing.witches.size():
		var round_s := float(wing.witches[i]["total"]) / float(wing.witches[i]["speed"])
		for k in 120:
			var at: Vector3 = wing.witch_pose(i, round_s * float(k) / 120.0)["at"]
			var room := wing.room_at(at)
			if room != "" and absf(at.y - wing.floor_at(room, at)) > 0.05:
				wing_floating += 1
	_check(wing.floor_area() > 10000.0 and wing.rooms.size() >= 50 and wing.witches.size() >= 9 and wing_floating == 0,
		"the Forgotten Wing is much larger: %d rooms, %d m2, %d witches" % [wing.rooms.size(), int(wing.floor_area()), wing.witches.size()])
	var _home := game.change_house(&"house")
	game.leave(&"solver")
	_finished_section()


## The stand-in (LmBot) walks level 1 with real movement and E, through doors, and gets out.
func _test_a_stand_in_plays() -> void:
	_section("a stand-in plays a level")
	var body := game.join(&"stand_in", "Stand-in")
	var bot := LmBot.new(game, &"stand_in")
	game.send_to(body, 1)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var delta := 1.0 / float(game.tick_rate)
	var ticks := 0

	while body.level == 1 and ticks < game.tick_rate * 240:
		bot.drive(delta)
		game.step(delta)
		ticks += 1

	_check(body.level == 2 and bot.levels_done == 1, "it gets out of level 1 on its own legs", "level %d after %d s" % [body.level, ticks / game.tick_rate])
	_check(bot.interacted > 5, "pressing E on the way (%d times)" % bot.interacted)
	_check(bot.gave_up == 0, "and never gives up on a thing it set out for", "%d given up" % bot.gave_up)
	game.leave(&"stand_in")
	_finished_section()


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


func _test_houses() -> void:
	_section("houses")
	_check(game.houses.size() == 3 and game.houses.has(&"asylum") and game.houses.has(&"forgotten") and game.house_id == &"house", "three houses, playing the House (%s)" % [game.houses.keys()])
	var a: LmPlayer = game.players[&"a"]
	a.best = 9
	game.send_to(a, 9)
	var told := [&""]
	game.house_changed.connect(func(id: StringName) -> void: told[0] = id)
	var changed := game.change_house(&"asylum")
	_check(changed.ok and told[0] == &"asylum" and game.levels.size() == 18 and game.house_name() == "The Asylum", "the Asylum opens: eighteen levels")
	_check(a.level == 1 and a.best == 1, "and everybody starts again in its lobby")
	_check(not game.change_house(&"nowhere").ok, "a house that does not exist is refused")
	var _back := game.change_house(&"house")
	_check(game.levels.size() == 32, "and the House comes back")
	_finished_section()


