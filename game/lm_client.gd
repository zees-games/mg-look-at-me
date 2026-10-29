extends "lm_client_frame.gd"

## One player in the dark: the camera, the flashlight, the witches drawn where the clock says they are,
## and the HUD. Offline it owns the house; everything the player does goes through [method _act]
## and everything they see comes from [member game], so connected it can mirror a server.


func _ready() -> void:
	# First, so the cover is up before anything of the house is drawn.
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.spawned_fn = func() -> bool: return player != null and camera != null and camera.current
	platform.scoreboard_action = LmBindings.SCOREBOARD
	add_child(platform)
	link = platform.link as Node
	_offline = platform.offline
	_hold_gate()
	_build_environment()
	game = LmGame.new()
	game.name = "World"
	game.authoritative = _offline
	game.register_service = _offline
	game.self_tick = _offline
	# Before the world is added: a world that ticks itself must not run in front of a picture.
	game.hold_clock = _covered
	add_child(game)
	_env.ambient_light_energy = game.config.darkness_ambient

	if _offline:
		_adopt_player(game.join(local_key, local_name))
		game.house_changed.connect(func(_id: StringName) -> void:
			_apply_mood()
			_forget_witches()
			_hold_rebuild()
			_say(game.house_name().to_upper(), 3.0))

		if start_level > 1 and game.levels.has(start_level):
			player.best = start_level
			game.send_to(player, start_level)

	_build_view()

	_build_hud()
	_apply_mood()
	_build_effects()
	chat = new_chat()
	add_child(chat)
	_build_settings()
	_build_scares()

	if not _offline:
		var netted := _build_netcode()
		DotLog.result(CHANNEL, "the netcode", netted)
		if netted.ok:
			_start_remote_workbench()
		DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))
		return

	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))
	# The house is built and the player stands in it; the gate now settles the body and lifts.
	_release_map()

	game.said.connect(func(key: StringName, text: String) -> void:
		if key == local_key:
			_say(text))
	game.caught.connect(func(key: StringName) -> void:
		if key == local_key:
			_say("SHE SEES YOU", 2.0))


## The camera, the flashlight and the spill round it, and the other players' beams.
func _build_view() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 75.0
	camera.near = 0.05
	# Nothing in a dark house is seen from further, and every lamp past it is one fewer lamp
	# competing for the renderer's few lights (see _process).
	camera.far = 90.0
	add_child(camera)
	camera.current = true

	# The flashlight (dot-flashlight): a hard bright middle with a soft edge, so it reads as a
	# torch in a dark house and not a flat disc. The house owns on/off (LmPlayer.flashlight), so
	# this node only draws it; a witch sees you by it, which is the game's trade.
	fl_config = DotFlashlightConfig.new()
	fl_config.energy = FLASH_ENERGY
	fl_config.shadows_on_web = true
	fl_config.range_m = game.config.flashlight_range
	fl_config.angle = game.config.flashlight_angle
	# Audio first: the light resolves its sound manager when it enters the tree.
	_build_audio()
	var flash_audio: DotNodeRef = DotNodeRef.of_path(audio.manager.get_path()) if audio != null and audio.manager != null else null
	fl = DotFlashlight.new()
	fl.audio = flash_audio
	fl.name = "Flashlight"
	fl.config = fl_config
	fl.handle_input = false
	fl.authoritative = false
	camera.add_child(fl)
	flashlight = fl.beam
	crowd = DotFlashlightCrowd.new()
	crowd.name = "OtherBeams"
	crowd.config = fl_config
	crowd.audio = flash_audio
	add_child(crowd)

	# The spill round the beam: your hands and the floor at your feet, never the far wall, so
	# with the light off you can still step through a room you cannot see across.
	var spill := OmniLight3D.new()
	spill.name = "Spill"
	spill.omni_range = 3.2
	spill.omni_attenuation = 1.4
	spill.light_energy = 0.22
	spill.light_color = Color(0.75, 0.8, 1.0)
	spill.shadow_enabled = false
	camera.add_child(spill)


## The load gate is dot-game's ([member DotGameClient.gate]); this holds the house on it. Released
## by [method _release_map] when the house stands.
func _hold_gate() -> void:
	var gate := platform.gate if platform != null else null

	if gate != null:
		gate.hold(&"map", "Loading the house")


func _release_map() -> void:
	if platform != null and platform.gate != null:
		platform.gate.release(&"map")


## The house was rebuilt (a new house offline or from a HELLO): covered again until the end of
## this frame, when the new levels' collision is in.
func _hold_rebuild() -> void:
	var gate := platform.gate if platform != null else null

	if gate != null:
		gate.hold(&"map", "Loading the house")
		gate.release.call_deferred(&"map")


## dot-team's block rules followed from the server, and the F9 tuning panel where this process hosts the house.
func _add_noblock_and_workbench() -> void:
	if link != null and not _offline:
		DotLog.result(CHANNEL, "noblock", platform.add_noblock(game, Callable(game, "team_of_side")))
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.listen_host_fn = func() -> bool: return true
	wb.config = {"enabled": false}
	for set: DotProfileSet in game.config_binder.profile_sets():
		wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	add_child(wb)
	var started := wb.start()
	DotLog.result(CHANNEL, "the workbench", started)
	if started.ok:
		game.config_binder.attach(wb.api.runtime)
	platform.add_workbench(wb)


## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote). The rows are the server's, through the bridge's profile link.
func _start_remote_workbench() -> void:
	if workbench_remote == null:
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = workbench_remote
	wb.remote_fn = func() -> bool: return true
	wb.config = {"enabled": false}
	for set: DotProfileSet in game.config_binder.profile_sets():
		wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	add_child(wb)
	var started := wb.start(game.ensure_runtime())
	DotLog.result(CHANNEL, "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	workbench = wb
	platform.add_workbench(wb)


## The player's settings, bound to the camera and the sampler's tunables. See [LmSettings].
## [method _adopt_player] binds the controller's tunables for a later player.
func _build_settings() -> void:
	settings = LmSettings.new()
	add_child(settings)
	platform.settings = settings
	platform.hud = _hud
	# The lamp's amber over the menu's theme: Christian's first play test asked for a darker HUD
	# a player can restyle in the menu.
	platform.hud_accent = piece_theme()
	platform.chat = chat
	# dot-game's look-to-gag on the keys LmBindings binds (G, K: H is help); this game aims with a ray.
	platform.look_target_fn = voice_target
	platform.look_chat_mute_fn = _chat_mute
	# The command line has the keyboard while it is open: its Escape is its own.
	platform.busy_fn = func() -> bool: return _command != null and _command.visible
	platform.board_snapshot_fn = board_snapshot
	# M: the house list. Solo a choice opens that house here at once; connected the server
	# decides, by the owner's `sv_map_menu_flag`, and anybody without it gets a vote instead
	# (dot-vote's map menu, wired in [LmModule]).
	platform.maps_rows_fn = func() -> Array: return game.house_rows() if game != null else []
	platform.maps_change_fn = func(id: StringName) -> DotResult: return game.change_house(id)
	platform.maps_title = "Change house"
	platform.maps_noun = "houses"
	DotLog.result(CHANNEL, "the platform", platform.setup())
	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	DotLog.result(CHANNEL, "avatar actions", platform.add_avatar_actions(net, _avatar_figure))
	_add_noblock_and_workbench()
	look_mute = platform.look_mute as DotVoiceLookMute
	# Walking and looking are off while the cover is up, a menu is open or a line is typed. Chat
	# typing never held them before, so a sentence walked the player into the dark.
	platform.input_blocked_changed.connect(_suspend_input)
	_suspend_input(platform.is_input_blocked())
	# A key may have moved on the Controls page.
	platform.menu_state_changed.connect(func(any_open: bool) -> void:
		if not any_open:
			_refresh_key_line())

	settings = platform.settings as LmSettings
	console = platform.console as DotConsoleController
	if settings == null:
		_refresh_key_line()
		return

	settings.bind_camera(camera)

	if audio != null:
		settings.bind_audio(audio.manager)
		# The server's lm_ambient* drive the quiet layer; the player's sliders multiply on top.
		if audio.ambient != null:
			audio.ambient.follow_settings(settings.settings, game.ambient_rules)

	if effects != null:
		settings.bind_fx(effects)

	if player != null and player.controller != null:
		settings.bind_look(player.controller.tunables)

	board = platform.board as DotMenuScoreboard
	_dress_board()
	_refresh_key_line()


## Every sampler this client has, held while [method DotGameClient.is_input_blocked].
func _suspend_input(blocked: bool) -> void:
	for sampler: DotFpsSampler in [_sampler, player.sampler if player != null else null, _held_sampler]:
		if sampler != null:
			sampler.suspended = blocked


## The Tab board: everybody in the house, their level, furthest level and ping. Online the levels
## are the server's (see [LmModule]'s `_game_board_fields`); offline, [method board_snapshot]'s.
func _dress_board() -> void:
	if board == null:
		return
	board.title_text = "Look at Me"
	board.columns = [
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"level", "title": "Level", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"best", "title": "Furthest", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"won", "title": "", "width": 1.0, "align": HORIZONTAL_ALIGNMENT_RIGHT,
			"format": func(v: Variant, _row: Dictionary) -> String: return "out" if bool(v) else ""},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_by = &"best"


## The board from this client's own world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var rows: Array = []
	if game != null:
		for key: StringName in game.players:
			var who: LmPlayer = game.players[key]
			rows.append({"id": String(key), "name": who.display_name, "level": who.level, "best": who.best,
				"won": who.won, "seconds": int((Time.get_ticks_msec() - _started_msec) / 1000) if who == player else -1,
				"ping": -1, "you": who == player})
	return {"server": {"name": "Look at Me", "game": "offline"}, "players": rows}


func _adopt_player(p: LmPlayer) -> void:
	player = p

	# Stopped while the gate is closed; settles under the cover with its input off, then opens.
	if platform != null and platform.gate != null:
		platform.gate.freeze(player)

	if _offline:
		player.sampler = DotFpsSampler.new(player.controller.tunables)
		DotFpsSampler.register_default_actions(player.sampler)
	else:
		_sampler = DotFpsSampler.new(player.controller.tunables)
		DotFpsSampler.register_default_actions(_sampler)

	if settings != null:
		settings.bind_look(player.controller.tunables)

	if platform != null:
		_suspend_input(platform.is_input_blocked())


## The netcode, built inside `_ready` (inside the shell's scene load), as every game here does.
func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""
	var config := DotNetConfig.new()
	config.tick_rate = Engine.physics_ticks_per_second
	config.snapshot_rate = LmGame.NET_SNAPSHOT_RATE
	config.world_extent = LmGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
	net.config = config
	add_child(net)
	var started := net.setup()

	if not started.ok:
		return started

	bridge = LmNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)
	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	bridge.open_link(link)
	# The server's mp_forceview and mp_solidplayers: this end places its own camera and
	# predicts its own player.
	var _view := game.view_rules.follow_cvars(link)
	var _solid := game.body_rules.follow_cvars(link)
	var _ambient := game.ambient_rules.follow_cvars(link)
	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	DotLog.result(CHANNEL, "avatar action message", DotGameAvatarActionMessage.register(net))
	# The server's order again (after the avatar frame): the remote workbench's frame.
	workbench_remote = DotGameWorkbenchRemoteClient.attach(net)
	net.messages.seal()
	game.player_joined.connect(func(key: StringName) -> void:
		if key == bridge.local_key:
			_adopt_player(game.players[key]))
	# A new house (or the first): the witches drawn for the old one go with it.
	bridge.hello_received.connect(func(_key: StringName) -> void:
		_apply_light_config()
		_apply_mood()
		_forget_witches()
		# The levels were built just now (the first house or a new one): covered until the end
		# of this frame, by which time their collision is in.
		_hold_rebuild()
		_say(game.house_name().to_upper(), 3.0))
	bridge.said.connect(func(text: String) -> void: _say(text))
	bridge.notice_received.connect(func(text: String) -> void: _say(text))
	_listen_for_sounds()

	if link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float: return float(maxi(0, int(link.call("ping_ms"))))

	if link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


## The key line along the bottom, from [LmBindings] as bound now (the defaults until the
## settings have loaded), with H for help.
func _refresh_key_line() -> void:
	if _key_line == null:
		return
	var k := func(action: StringName, fallback: String) -> String:
		var text := DotInputBinding.describe_action(action) if InputMap.has_action(action) else fallback
		return fallback if text == DotInputBinding.UNBOUND else text
	_key_line.text = "%s use   %s flashlight   %s camera   %s crouch   %s command   %s house   %s help" % [
		k.call(LmBindings.USE, "E"), k.call(LmBindings.FLASHLIGHT, "F"), k.call(LmBindings.VIEW, "F5"),
		k.call(&"dot_fps_crouch", "Ctrl"), k.call(LmBindings.COMMAND, "/"), k.call(&"dot_menu_maps", "M"),
		k.call(DotMenuBindings.HELP_ACTION, "H")]


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Control.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud)

	# Dithered here: the compatibility renderer ignores debanding, and 8 bits step a lamp's falloff
	# into stripes. Triangular noise of about two levels, after the world and before the HUD.
	var dither := ColorRect.new()
	dither.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dither.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var dither_shader := Shader.new()
	dither_shader.code = DITHER_SHADER
	var dither_material := ShaderMaterial.new()
	dither_material.shader = dither_shader
	dither.material = dither_material
	_hud.add_child(dither)

	# The meter's own colour, over everything: the closer she is to seeing you, the redder the
	# edges. A bar is read; a screen going red is felt.
	_vignette = ColorRect.new()
	_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = "shader_type canvas_item;\nuniform float amount = 0.0;\nvoid fragment() {\n\tfloat d = distance(UV, vec2(0.5));\n\tCOLOR = vec4(0.6, 0.0, 0.0, smoothstep(0.25, 0.75, d) * amount + amount * 0.15);\n}\n"
	var material := ShaderMaterial.new()
	material.shader = shader
	_vignette.material = material
	_hud.add_child(_vignette)

	# The step and what you hold, top left, as wide as the window and wrapping inside it. They
	# were Labels with no width, and at some window sizes the step ran off the edge ("…d key",
	# the first play test); a long step now takes a second line instead.
	_objective = VBoxContainer.new()
	_objective.name = "Objective"
	_objective.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_objective.offset_left = 20.0
	_objective.offset_top = 14.0
	_objective.offset_right = -20.0
	_objective.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_objective.add_theme_constant_override(&"separation", 2)
	_hud.add_child(_objective)
	_step = _wrapping(_label("", 22, Vector2.ZERO), _objective)
	_step.name = "Step"
	_holds = _wrapping(_label("", 16, Vector2.ZERO), _objective)
	_holds.name = "Holds"
	_holds.modulate = Color(0.8, 0.85, 0.9)

	_meter_bar = ProgressBar.new()
	_meter_bar.name = "Meter"
	_meter_bar.max_value = 1.0
	_meter_bar.show_percentage = false
	_meter_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_meter_bar.offset_left = -180
	_meter_bar.offset_right = 180
	# Over the key line, which may take two lines in a narrow window.
	_meter_bar.offset_top = -66
	_meter_bar.offset_bottom = -52
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.75, 0.05, 0.05)
	_meter_bar.add_theme_stylebox_override("fill", fill)
	_hud.add_child(_meter_bar)

	# Under the crosshair: what the use key does right now. Its colours are the menu's theme
	# (set on the HUD's root, see [method _build_settings]) with [method piece_theme]'s accent.
	prompt = DotKeyPrompt.new()
	prompt.name = "Prompt"
	prompt.theme = piece_theme()
	prompt.font_size = 19
	prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	prompt.offset_left = -300.0
	prompt.offset_right = 300.0
	prompt.offset_top = 32.0
	prompt.offset_bottom = 68.0
	prompt.visible = false
	_hud.add_child(prompt)

	_message = _label("", 34, Vector2.ZERO)
	_message.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_message.offset_top = 120
	_message.offset_left = 20
	_message.offset_right = -20
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# Bottom, the window's width, growing upward if it has to wrap.
	_key_line = _label("", 13, Vector2.ZERO)
	_key_line.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_key_line.offset_top = -24
	_key_line.offset_bottom = -6
	_key_line.offset_left = 16
	_key_line.offset_right = -16
	_key_line.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_key_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_key_line.modulate = Color(1, 1, 1, 0.5)
	_key_line.name = "Keys"
	_refresh_key_line()

	_command = LineEdit.new()
	_command.placeholder_text = "/r  /l3"
	_command.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_command.offset_top = -70
	_command.offset_bottom = -40
	_command.offset_left = 16
	_command.offset_right = 320
	_command.visible = false
	_command.text_submitted.connect(_on_command)
	_hud.add_child(_command)


## The key the use action is on now, as its name ("E"). Binds the default first if nothing has.
static func use_key() -> String:
	return DotInputBinding.ensure_action(USE_ACTION, USE_DEFAULT)


## This house's accent (the lamp's amber) over the player's menu theme; the theme owns the plates,
## words and outline. Static so a render tool can use it.
static func piece_theme() -> Theme:
	var t := Theme.new()
	var type := DotHudPiece.THEME_TYPE
	t.set_color(&"plate_edge", type, Color(LAMP_COLOUR, 0.28))
	t.set_color(&"highlight", type, LAMP_COLOUR)
	return t


func _label(text: String, size: int, at: Vector2) -> Label:
	var label := Label.new()
	label.text = text
	label.position = at
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	label.add_theme_constant_override("outline_size", 6)
	_hud.add_child(label)
	return label


## [param label] moved into [param box], wrapping at the box's width.
func _wrapping(label: Label, box: Container) -> Label:
	_hud.remove_child(label)
	box.add_child(label)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


## Whether every line of the HUD that says something is inside a window of [param size]:
## the step, what you hold, the key line and the meter. For the suite, which cannot open a
## window that small; read after the HUD has been laid out at that size.
func hud_fits(size: Vector2) -> Dictionary:
	var window := Rect2(Vector2.ZERO, size)
	var out := {"fits": true}
	for piece: Control in {"step": _step, "holds": _holds, "keys": _key_line, "meter": _meter_bar}.values():
		var rect := piece.get_global_rect()
		# A Label's words are never wider than its rect while it wraps; one that does not wrap
		# says so by a minimum width past it.
		var inside := window.encloses(rect.grow(-0.5)) and piece.get_combined_minimum_size().x <= rect.size.x + 0.5
		out[str(piece.name)] = "%s%s" % [rect, "" if inside else " OUTSIDE"]
		out["fits"] = bool(out["fits"]) and inside
	return out


func _on_command(text: String) -> void:
	_command.visible = false
	_command.release_focus()

	if _held_sampler != null:
		player.sampler = _held_sampler
		_held_sampler = null

	# The platform takes the pointer back only if no menu or other hold remains.
	platform.release_pointer(&"command")
	_act("command", {"text": text})


## The peer under the crosshair, 0 for nobody: the player whose head is nearest the view axis
## ([method DotVoiceLookMute.pick_by_angle]) on this level, within a few metres and with no
## wall between. The voice manager names speakers by the server's peer id, which a JOIN carries.
func voice_target() -> int:
	if bridge == null or player == null or camera == null:
		return 0

	var heads := {}
	var space := camera.get_world_3d().direct_space_state

	for peer: int in bridge.speaker_keys:
		var other: LmPlayer = game.players.get(bridge.speaker_keys[peer], null)

		if other == null or other == player or other.level != player.level:
			continue

		var head := other.global_position + Vector3.UP * 1.5
		var query := PhysicsRayQueryParameters3D.create(camera.global_position, head, LmGame.LAYER_WORLD)

		if space.intersect_ray(query).is_empty():
			heads[peer] = head

	return DotVoiceLookMute.pick_by_angle(camera.global_transform, heads, 20.0, 8.0)


func _chat_mute(peer: int, muted: bool) -> void:
	var other: LmPlayer = game.players.get(bridge.speaker_keys.get(peer, &""), null) if bridge != null else null

	if other != null and chat != null and chat.self_mute != null and chat.self_mute.has_method(&"set_muted"):
		chat.self_mute.call(&"set_muted", {"key": "", "name": other.display_name}, muted)


## dot-game's chat box and microphone with this game's channels and voice format; it also draws
## dot-server's own lines, which arrive on the shell's client link. Static so a suite can build it.
static func new_chat() -> DotGameChatClient:
	var box := DotGameChatClient.new()
	box.name = "Chat"
	box.channels = [
		{"id": LmServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
	]
	box.max_length = LmServices.MAX_LINE
	box.voice_config = LmServices.voice_format()
	# This bridge's `send_voice` is the server's `(peer_id, bytes)`; the client half is this.
	box.voice_method = &"send_voice_up"
	return box
