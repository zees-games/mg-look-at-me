extends Node

## The house, headless: every level built and finished, doors that are open for one player and
## shut for another, what a witch can see, being caught, the commands, and winning.
##
##   godot --headless --path . res://examples/headless_run.tscn

const LmGame := preload("res://game/lm_game.gd")
const LmLevel := preload("res://game/lm_level.gd")
const LmPlayer := preload("res://game/lm_player.gd")
const LmProgress := preload("res://game/lm_progress.gd")

const SECTIONS := 12
const CHECKS := 64

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
	_test_houses()
	await _test_the_client_settings()
	await _test_sound_and_effects()
	await _test_the_mouse_turns_the_view()

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
	_check((game.levels[1] as LmLevel).witches.size() == 1 and (game.levels[32] as LmLevel).witches.size() == 6, "one witch on level 1, six on level 32")
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
					var before := solver.holds.size() + solver.opened.size() + solver.used.size() + solver.taken.size()
					_stand_before(solver, level, at + Vector3(0, lift, 0))
					var _said := game.interact(&"solver")
					if solver.holds.size() + solver.opened.size() + solver.used.size() + solver.taken.size() > before:
						progress = true

		if not solver.opened.has("exit"):
			stuck.append("%d (%s)" % [n, game.step_of(solver)])

	_check(stuck.is_empty(), "the solver opens the way out of all 32", ", ".join(stuck))
	game.leave(&"solver")
	_finished_section()


## Puts [param player] 1.2 m back from [param at] (level-local), looking straight at it.
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
	var seconds := 3.0
	var pose := level.witch_pose(0, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep)
	var facing := float(pose["facing"]) + float(pose["head"])
	var ahead := Vector3(-sin(facing), 0, -cos(facing))
	var witch_at: Vector3 = level.position + (pose["at"] as Vector3)
	var room := level.room_at(pose["at"])
	p.place_at(witch_at + ahead * 2.5, 0.0)
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
		var pose := level.witch_pose(0, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep)
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
	await get_tree().process_frame
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
	_finished_section()


## The client's sounds and the catch's effects, through dot-audio and dot-fx. Headless has no
## sound device, so the manager runs its null sink, which is the real limits and catalogue
## with a log in place of a speaker; tools/audio_probe (xvfb) is what says a sound is heard.
func _test_sound_and_effects() -> void:
	_section("the house's sounds and the catch, through dot-audio and dot-fx")
	var LmAudio: GDScript = load("res://game/lm_audio.gd")
	var catalogue: DotAudioCatalogue = LmAudio.call("sound_catalogue")
	var stand_ins: Dictionary = LmAudio.call("stand_ins")
	var ids: Array = LmAudio.call("ids")
	_check(
		catalogue.validate().ok and ids.all(func(id: StringName) -> bool:
			return catalogue.find(id) != null and stand_ins.has(id)),
		"every sound the game names is in its catalogue, with a stand-in",
		str(ids)
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

	for i in 90:
		player.meter = 0.9
		await get_tree().process_frame

	var _clicked: bool = audio.call("click")
	_check(
		sink != null and sink.count_of(&"heartbeat") >= 1 and sink.count_of(&"click") == 1 \
			and int(audio.call("droning")) > 0,
		"a heartbeat at a high meter, a click, and the drone of a witch nearby",
		str(sink.played_ids()) if sink != null else "no sink"
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
