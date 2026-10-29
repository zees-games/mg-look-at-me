extends "headless_run_base.gd"

## The client, sound, listening and the mouse sections of headless_run.gd.


## A real offline client, booted: its settings are read by the camera and the look, and
## Escape opens the screen.
func _test_the_client_settings() -> void:
	_section("the client's settings are read, and Escape opens them")
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	add_child(client)
	# The house is neither drawn nor steered while it is still being built.
	var platform: DotGameClient = client.get("platform")
	var covered := platform != null and platform.gate != null and not platform.is_shown() \
		and platform.is_input_blocked()
	await _shown(client)
	_check(covered and platform.is_shown() and not platform.is_input_blocked() and platform.console != null,
		"the loading cover is up at the start and lifts once the player is in, with the console built",
		str(platform.describe()) if platform != null else "no platform")

	var settings: Variant = client.get("settings")
	var camera: Camera3D = client.get("camera")
	_check(
		settings != null and int(settings.describe().get("look_bound", 0)) > 0 \
			and camera != null and bool(settings.describe().get("camera_bound", false)) \
			and is_equal_approx(camera.fov, float(settings.settings.get_int(&"field_of_view", 0))),
		"the client's settings are read by its look and its camera",
		str(settings.describe()) if settings != null else "no settings"
	)
	var lamp: DotFlashlight = client.get("fl")
	var lit_player: LmPlayer = client.get("player")
	_check(lamp != null and lamp.beam != null and lamp.beam.spot_range == lit_player.get_parent().get("config").flashlight_range
		and lamp.on == lit_player.flashlight, "the flashlight is dot-flashlight's beam, in the house's range and state")
	lit_player.flashlight = false
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not lamp.on and not lamp.beam.visible, "and it follows the player's switch")
	lit_player.flashlight = true
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	client.call("_unhandled_input", escape)
	_check(settings != null and settings.is_open(), "and Escape opens them")
	settings.close()
	var self_player: Object = client.get("player")
	# Your own view is first person, so no figure is drawn yet: give it one as the third-person view does.
	if self_player != null and self_player.figure == null:
		self_player.figure = (load("res://game/lm_figure.gd") as GDScript).new()
		self_player.figure.person = DotHumanoidFigure.new()
		self_player.figure.add_child(self_player.figure.person)
		client.add_child(self_player.figure)
	var action_fig: Object = client.call("_avatar_figure", 0)
	_check(self_player != null and self_player.figure != null and action_fig == self_player.figure.person and action_fig.has_method(&"skeleton"),
		"an avatar action and a wearable go on the player's own person, which can hang a wearable")
	# The figure steps its clip by game time (DotHumanoidFigure.frame_delta), which stamps the frame it ran in.
	if self_player != null and self_player.figure != null and DotAddonApi.build_level("dot_player_char") >= 11:
		self_player.figure.pose(self_player.global_position, 0.0, 3.0)
		_check(int(self_player.figure.person.get("_posed_frame")) == Engine.get_process_frames(),
			"a posed figure animates by game time, not the wall clock")
	await _the_client_settings_2(client, settings)


func _the_client_settings_2(client: Node, settings: Variant) -> void:
	# The Tab board, held: the menu's, drawn from the local world offline. The platform makes
	# the menu hold it on this game's own row (DotGameClient.scoreboard_action).
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	settings.menu.handle_event(tab)
	var board: DotMenuScoreboard = client.get("board")
	_check(board != null and board.is_open() and board.rows().any(func(r: Dictionary) -> bool:
			return bool(r.get("you", false)) and int(r.get("level", 0)) >= 1),
		"Tab holds the board up, with this player and the level they are on",
		str(board.rows()) if board != null else "no board")
	tab.pressed = false
	settings.menu.handle_event(tab)
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
	await _the_client_settings_3(client, settings, keys, menu, LmClientScript, me, prompt, use_key)


func _the_client_settings_3(client: Node, settings: Variant, keys: DotMenuBindings, menu: DotMenu, LmClientScript: GDScript, me: LmPlayer, prompt: DotKeyPrompt, use_key: String) -> void:
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
	await _the_client_settings_4(client)


func _the_client_settings_4(client: Node) -> void:
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
			# The mood director registers its own beds ("ambience/<mood>/..."), not the house catalogue.
			if catalogue.find(StringName(id)) == null and not String(id).begins_with("ambience/"):
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
	await _sound_and_effects_2(client, audio, player, sink, settings, effects)


func _sound_and_effects_2(client: Node, audio: Node, player: LmPlayer, sink: DotAudioSinkNull, settings: Variant, effects: DotFxManager) -> void:
	await get_tree().process_frame
	effects.flash_colour.a = 0.0
	settings.settings.set_value(&"allow_flashes", false)
	player.caught_left = 1.0
	await get_tree().process_frame
	_check(effects != null and is_zero_approx(effects.flash_colour.a),
		"and not when the player has turned flashes off")
	settings.settings.set_value(&"allow_flashes", true)

	# Driven insane, then dying: the meter, the madness's audio and a pending jump scare are at
	# rest, and so are the post-effects once the player is back. (The soundtrack of a death is
	# the scream; the heartbeat and whispers are not part of it.)
	player.caught_left = 0.0
	await get_tree().process_frame
	var view: Node = client.get("scare_view")
	player.meter = 0.9

	for i in 60:
		await get_tree().process_frame

	var beats := sink.count_of(&"heartbeat")
	view.call("_startle", "demon", 0.0, 2.0, player.global_position)
	view.get("director").demons.append({"id": 99, "at": Vector3(3, 0, 3), "age": 0.0, "looked": false, "whisper": 5.0})
	var _w: bool = audio.call("whisper", Vector3(2, 1, 2))
	player.meter = 1.0
	player.caught_left = 1.0

	for i in 40:
		await get_tree().process_frame

	_check(
		float(audio.get("meter")) == 0.0 and sink.count_of(&"heartbeat") == beats
			and float(view.get("_scare_left")) == 0.0 and view.get("director").demons.is_empty()
			and not (sink.get("_playing") as Dictionary).values().any(func(r: Dictionary) -> bool:
				return str(r.get("id", "")) in ["scare_hit", "whisper", "whisper_behind", "heartbeat"]),
		"dying puts the insane audio, the demons and a pending jump scare to rest",
		"meter %s beats %d/%d scare %s" % [str(audio.get("meter")), sink.count_of(&"heartbeat"), beats, str(view.get("_scare_left"))]
	)
	player.caught_left = 0.0
	player.meter = 0.0

	for i in 3:
		await get_tree().process_frame

	_check(effects.flash_colour.a == 0.0 and effects.shake.trauma() == 0.0 and float(audio.get("meter")) == 0.0,
		"and back in the house the flash and the shake are gone and the meter is at rest")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished_section()


## A witch that suspects somebody behind her stops and listens. A player who goes quiet then is not
## found; one who keeps making a noise is looked back at and run down.
func _test_listening(level: LmLevel, delta: float) -> void:
	var p: LmPlayer = game.players[&"a"]
	var config := game.config
	var t0 := 41.0
	var results: Array = []

	p.gaze.clear()
	# A moment when somebody four metres behind her has a clear line to her, and keeps it for the
	# seconds she walks on before she stops (she must not walk past them or round a wall).
	for tenth in 2400:
		var candidate := 5.0 + float(tenth) * 0.5
		var there := game.witch_pose_for(p, level, 0, candidate)
		var back := float(there["facing"])
		var behind: Vector3 = level.position + (there["at"] as Vector3) + Vector3(sin(back), 0, cos(back)) * 4.0
		p.place_at(behind, 0.0)
		var ok := level.room_at(behind - level.position) != ""

		for step in 8:
			var later := game.witch_pose_for(p, level, 0, candidate + float(step) * 0.25)
			var gap := (level.position + (later["at"] as Vector3)).distance_to(behind)
			ok = ok and gap > 2.0 and gap < 9.0 \
				and game._clear_between(level.position + (later["at"] as Vector3) + Vector3(0, 2.0, 0), p.eye_position(), p)

		if ok:
			t0 = candidate
			break

	for noisy in [false, true]:
		p.gaze.clear()
		p.meter = 0.0
		p.caught_left = 0.0
		var start := game.witch_pose_for(p, level, 0, t0)
		var facing := float(start["facing"])
		var spot: Vector3 = level.position + (start["at"] as Vector3) + Vector3(sin(facing), 0, cos(facing)) * 4.0
		var seen_modes := {}
		var closest := 99.0
		var stopped := false
		var moved_while_listening := 0.0
		var held_at := Vector3.INF
		var seconds := t0

		for tick in 900:
			seconds += delta
			p.place_at(spot, 0.0)
			# Noise to start the suspicion; the quiet player then keeps still, the other does not.
			p.noise_left = 1.0 if (noisy or float(tick) * delta < config.witch_reaction_seconds + 0.3) else 0.0
			game.tick += 1
			game._listen(p, level, seconds, delta)
			var state: Dictionary = p.gaze[0]
			seen_modes[int(state["mode"])] = true
			var pose := game.witch_pose_for(p, level, 0, seconds)
			closest = minf(closest, (level.position + (pose["at"] as Vector3)).distance_to(spot))

			if int(state["mode"]) == LmGame.MODE_LISTEN:
				if held_at == Vector3.INF:
					held_at = pose["at"]

				moved_while_listening = maxf(moved_while_listening, (pose["at"] as Vector3).distance_to(held_at))
				stopped = true

		results.append({"modes": seen_modes, "closest": closest, "stopped": stopped, "last": p.gaze[0].duplicate(), "t0": t0, "spot": spot, "slid": moved_while_listening, "mode": int(p.gaze[0]["mode"])})

	var quiet: Dictionary = results[0]
	var loud: Dictionary = results[1]
	_check(quiet["stopped"] and float(quiet["slid"]) < 0.01, "a witch that suspects somebody behind her stops dead to listen", str(quiet["slid"]))
	_check(not quiet["modes"].has(LmGame.MODE_CHASE) and not quiet["modes"].has(LmGame.MODE_TURN), "a quiet player behind her survives the listen: she hears nothing and walks on", str(quiet["modes"].keys()))
	_check(loud["modes"].has(LmGame.MODE_TURN) and loud["modes"].has(LmGame.MODE_CHASE) and float(loud["closest"]) < 2.0, "a noisy one is looked back at and run down", "%s, closest %.1f m, %s" % [str(loud["modes"].keys()), float(loud["closest"]), str(loud["last"]) + str(loud["t0"])])
	_check(float(quiet["closest"]) > 3.0, "and the quiet one is never approached", "%.1f m" % float(quiet["closest"]))


## Real mouse motion, through Input the way a mouse delivers it, turns the camera. Nothing fed
## the samplers a mouse event, so the view only ever turned when the player walked; every other
## check set angles directly and passed.
func _test_the_mouse_turns_the_view() -> void:
	_section("the mouse turns the view")
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	add_child(client)
	await _shown(client)

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
	await _the_mouse_turns_the_view_2(client, settings)


func _the_mouse_turns_the_view_2(client: Node, settings: Variant) -> void:
	# The command line holds the pointer: nothing recaptures it until the line is sent.
	var platform: DotGameClient = client.get("platform")
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_ENTER
	client._unhandled_input(key)
	await get_tree().process_frame
	_check(client.get("_command").visible and platform.is_input_blocked(),
		"the command line open blocks input")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	platform._unhandled_input(click)
	_check(platform._pointer_holds.has(&"command"), "and holds the pointer against a click")
	settings.open()
	settings.close()
	await get_tree().process_frame
	_check(platform._pointer_holds.has(&"command") and platform.is_input_blocked(),
		"and a menu closing does not release it")
	client.call("_on_command", "")
	await get_tree().process_frame
	_check(not platform._pointer_holds.has(&"command"), "sending the line releases the hold")
	_check(not platform.is_input_blocked(), "and input is back")

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
