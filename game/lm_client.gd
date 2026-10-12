extends Node3D

## One player in the dark: the camera (first person or behind), the flashlight, the witches
## drawn where the clock says they are, and the HUD — the step you are on, what you hold, what
## you are looking at, and the meter.
##
## [b]Offline today, built to be a mirror later[/b], as mg-dangerous-delivery's was: everything
## the player does goes through [method _act]; everything they see comes from [member game].

const LmBindings := preload("lm_bindings.gd")
const LmGame := preload("lm_game.gd")
const LmSettings := preload("lm_settings.gd")
const LmPlayer := preload("lm_player.gd")
const LmLevel := preload("lm_level.gd")
const LmNetBridge := preload("net/lm_net_bridge.gd")
const LmServices := preload("lm_services.gd")
const LmAudio := preload("lm_audio.gd")

## Where dot-server's client publishes its link before the game scene loads.
const LINK_SERVICE := &"dot_client_link"

const CHANNEL := "lookatme.client"

## The use key's action, and what it is bound to when nothing else has bound it. The prompt
## and the key line draw the action's binding, never a letter written here, so a project or a
## player that binds it elsewhere is told the key that works.
const USE_ACTION := LmBindings.USE
const USE_DEFAULT := "E"

## The lamp's amber, which is also the glance pieces' highlight.
const LAMP_COLOUR := Color(1.0, 0.80, 0.48)

## The key line along the bottom ([method _refresh_key_line]).
var _key_line: Label = null

@export var local_key: StringName = &"you"
@export var local_name: String = "You"

## Level to start on instead of the lobby, for a screenshot.
@export var start_level: int = 1

var game: LmGame = null
var player: LmPlayer = null
var camera: Camera3D = null
var flashlight: SpotLight3D = null
var third_person: bool = false

var _env: Environment = null
var _witch_views: Dictionary = {}
var _hud: Control = null
var _step: Label = null
var _holds: Label = null
## "Take the red key" with the use key drawn as a key, while something is in reach. dot-ui's
## [DotKeyPrompt]; it was a Label writing "[E] …" with the letter fixed. Decided 2026-10-11
## (hud-pieces).
var prompt: DotKeyPrompt = null
var _message: Label = null
var _meter_bar: ProgressBar = null
var _vignette: ColorRect = null
var _command: LineEdit = null
var _message_left := 0.0
var _held_sampler: DotFpsSampler = null

var net: DotNetManager = null
var bridge: LmNetBridge = null
var link: Node = null

## The Tab board, the menu's. See [method _wire_board].
var board: DotMenuScoreboard = null

## When this client started, for an offline board's "time".
var _started_msec: int = Time.get_ticks_msec()
var _offline: bool = true
## Connected, the keys are sampled here and sent; the local player is predicted from them.
var _sampler: DotFpsSampler = null
var chat: DotGameChatClient = null
## The house's sounds, through dot-audio. See [LmAudio].
var audio: LmAudio = null
## The catch, felt: a red flash and a jolt through dot-fx, so the settings' "allow flashes" and
## "shake" reach them. See [method _build_effects].
var effects: DotFxManager = null
var _flash_rect: ColorRect = null
## The catch already shown, so a catch is flashed once and not every frame it lasts.
var _was_caught := false

## The player's own settings and the screen Escape opens. See [LmSettings].
var settings: LmSettings = null

## The player's console. See [method DotConsoleKit.build].
var console: DotConsoleController = null


func _ready() -> void:
	_build_environment()
	link = DotRegistry.get_node_service(LINK_SERVICE)
	_offline = link == null or OS.get_cmdline_user_args().has("--offline")
	game = LmGame.new()
	game.name = "World"
	game.authoritative = _offline
	game.register_service = _offline
	game.self_tick = _offline
	add_child(game)

	if _offline:
		_adopt_player(game.join(local_key, local_name))
		game.house_changed.connect(func(_id: StringName) -> void:
			_forget_witches()
			_say(game.house_name().to_upper(), 3.0))

		if start_level > 1 and game.levels.has(start_level):
			player.best = start_level
			game.send_to(player, start_level)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 75.0
	camera.near = 0.05
	add_child(camera)
	camera.current = true

	flashlight = SpotLight3D.new()
	flashlight.name = "Flashlight"
	flashlight.spot_range = 18.0
	flashlight.spot_angle = 32.0
	flashlight.light_energy = 2.2
	flashlight.light_color = Color(1.0, 0.95, 0.85)
	flashlight.shadow_enabled = true
	camera.add_child(flashlight)
	flashlight.position = Vector3(0.2, -0.15, 0.0)

	_build_hud()
	_build_audio()
	_build_effects()
	_build_settings()
	chat = new_chat()
	add_child(chat)

	if not _offline:
		DotLog.result(CHANNEL, "the netcode", _build_netcode())
		DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))
		return

	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))

	game.said.connect(func(key: StringName, text: String) -> void:
		if key == local_key:
			_say(text))
	game.caught.connect(func(key: StringName) -> void:
		if key == local_key:
			_say("SHE SEES YOU", 2.0))

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if not DotPlatform.is_web() else Input.MOUSE_MODE_VISIBLE


## The player's settings, bound to the camera and the sampler's tunables. See [LmSettings].
##
## The look is bound to the controller's own tunables, which both samplers read (offline the
## player's, connected the client's); [method _adopt_player] binds them for a later player.
func _build_settings() -> void:
	settings = LmSettings.new()
	settings.name = "Settings"
	add_child(settings)

	var built: DotResult = settings.setup()

	if not built.ok:
		DotLog.warn(CHANNEL, "no settings; everything is at its default", {"why": built.error.message})
		remove_child(settings)
		settings.free()
		settings = null
		return

	settings.bind_camera(camera)

	if audio != null:
		settings.bind_audio(audio.manager)

	if effects != null:
		settings.bind_fx(effects)

	if player != null and player.controller != null:
		settings.bind_look(player.controller.tunables)

	if settings.menu != null:
		# Walking is off while the menu is up, as it is while typing a command; the menu takes
		# Escape itself now, so the pointer is freed here.
		settings.menu_state_changed.connect(func(any_open: bool) -> void:
			for sampler: DotFpsSampler in [_sampler, player.sampler if player != null else null, _held_sampler]:
				if sampler != null:
					sampler.suspended = any_open
			if any_open:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			elif not DotPlatform.is_web() and not _command.visible:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			# A key may have moved on the Controls page.
			if not any_open:
				_refresh_key_line()
		)
		# The command line has the keyboard while it is open: its Escape is its own.
		settings.menu.busy = func() -> bool:
			return (_command != null and _command.visible) or (chat != null and chat.is_typing())
		# The console (the key under Escape): net_stat and every other setting by name, and
		# the server's console when one runs in this process. One of the menu's overlays, so
		# opening it stops the player and frees the pointer exactly as the menu does.
		console = DotConsoleKit.build(self, settings.settings, settings.menu)
		_wire_board()
		_wire_maps()
	_refresh_key_line()


## The Tab board: everybody in the house, the level they are on, the furthest they have got
## and whether they got out, beside how long they have been on and their ping. Online the
## levels are the server's (see [LmModule]'s `_game_board_fields`); offline, this world's.
## M: the house list (dot-menu's map menu). Solo a choice opens that house here at once;
## connected the server decides, by the owner's `sv_map_menu_flag`, and anybody without it
## gets a vote instead (dot-vote's map menu, wired in [LmModule]). By name, so a client shell
## older than the map menu still runs the game without it.
func _wire_maps() -> void:
	if not settings.has_method(&"use_maps"):
		return
	var maps: Variant = settings.call(&"use_maps",
		func() -> Array: return game.house_rows() if game != null else [],
		func(id: StringName) -> DotResult: return game.change_house(id))
	if maps is Object:
		(maps as Object).set(&"title", "Change house")
		(maps as Object).set(&"noun", "houses")


func _wire_board() -> void:
	board = settings.menu.scoreboard
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
	if not _offline and link != null and link.has_signal(&"scoreboard_received"):
		board.feed_from(link)
	else:
		board.source = board_snapshot


func _show_board(on: bool) -> void:
	if board == null:
		return
	if on:
		board.open()
	else:
		board.close()


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

	if _offline:
		player.sampler = DotFpsSampler.new(player.controller.tunables)
		DotFpsSampler.register_default_actions(player.sampler)
	else:
		_sampler = DotFpsSampler.new(player.controller.tunables)
		DotFpsSampler.register_default_actions(_sampler)

	if settings != null:
		settings.bind_look(player.controller.tunables)


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
	net.messages.seal()
	game.player_joined.connect(func(key: StringName) -> void:
		if key == bridge.local_key:
			_adopt_player(game.players[key]))
	# A new house (or the first): the witches drawn for the old one go with it.
	bridge.hello_received.connect(func(_key: StringName) -> void:
		_forget_witches()
		_say(game.house_name().to_upper(), 3.0))
	bridge.said.connect(func(text: String) -> void: _say(text))
	bridge.notice_received.connect(func(text: String) -> void: _say(text))
	_listen_for_sounds()

	if link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float: return float(maxi(0, int(link.call("ping_ms"))))

	if link.has_method("is_playing") and bool(link.call("is_playing")):
		bridge.ask_ready()
	elif link.has_signal("spawned"):
		link.connect("spawned", func() -> void: bridge.ask_ready(), CONNECT_ONE_SHOT)

	return net.start()


func _physics_process(delta: float) -> void:
	if _offline or net == null or not net.is_running() or bridge == null:
		return

	if link != null and link.has_method("is_playing") and not bool(link.call("is_playing")):
		return

	var typing := _command.visible or (chat != null and chat.is_typing())
	var move := _sampler.sample(delta) if _sampler != null and not typing else DotFpsCommand.new()

	if command_override != null:
		move = command_override

	var ticks := net.clock.advance(delta)

	for i in range(ticks):
		if net.clock.is_synced():
			bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move)


## A command to walk with instead of the keys: what a headless client in a suite has.
var command_override: DotFpsCommand = null


func _build_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.0, 0.0, 0.0)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.5, 0.55, 0.7)
	_env.ambient_light_energy = 0.04
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.02, 0.02, 0.03)
	_env.fog_density = 0.04
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world := WorldEnvironment.new()
	world.environment = _env
	add_child(world)


## The key line along the bottom, from [LmBindings] as bound now (the defaults until the
## settings have loaded), with H for help.
func _refresh_key_line() -> void:
	if _key_line == null:
		return
	var k := func(action: StringName, fallback: String) -> String:
		var text := DotInputBinding.describe_action(action) if InputMap.has_action(action) else fallback
		return fallback if text == DotInputBinding.UNBOUND else text
	_key_line.text = "%s use   %s flashlight   %s camera   %s crouch   %s command (/r lobby, /l2 a level)   %s house   %s help" % [
		k.call(LmBindings.USE, "E"), k.call(LmBindings.FLASHLIGHT, "F"), k.call(LmBindings.VIEW, "C"),
		k.call(&"dot_fps_crouch", "Ctrl"), k.call(LmBindings.COMMAND, "/"), k.call(&"dot_menu_maps", "M"),
		k.call(DotMenuBindings.HELP_ACTION, "H")]


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Control.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud)

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

	_step = _label("", 22, Vector2(20, 16))
	_holds = _label("", 16, Vector2(20, 52))
	_holds.modulate = Color(0.8, 0.85, 0.9)

	_meter_bar = ProgressBar.new()
	_meter_bar.max_value = 1.0
	_meter_bar.show_percentage = false
	_meter_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_meter_bar.offset_left = -180
	_meter_bar.offset_right = 180
	_meter_bar.offset_top = -40
	_meter_bar.offset_bottom = -26
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.75, 0.05, 0.05)
	_meter_bar.add_theme_stylebox_override("fill", fill)
	_hud.add_child(_meter_bar)

	# Under the crosshair: what the use key does right now. Its colours are [method
	# piece_theme]'s, set on the piece so the Labels here keep their own.
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
	_message.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_message.offset_top = 120
	_message.offset_left = -400
	_message.offset_right = 400
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_key_line = _label("", 13, Vector2.ZERO)
	_key_line.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_key_line.offset_top = -26
	_key_line.offset_left = 16
	_key_line.offset_right = 900
	_key_line.modulate = Color(1, 1, 1, 0.5)
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


## The glance pieces' colours in this house's palette: a near-black plate warm enough to sit
## in lamplight, pale text, the lamp's amber as highlight. Static so a render tool can use it.
static func piece_theme() -> Theme:
	var t := Theme.new()
	var type := DotHudPiece.THEME_TYPE
	t.set_color(&"plate", type, Color(0.05, 0.04, 0.035, 0.66))
	t.set_color(&"plate_edge", type, Color(LAMP_COLOUR, 0.28))
	t.set_color(&"highlight", type, LAMP_COLOUR)
	t.set_color(&"keycap", type, Color(0.96, 0.92, 0.84, 0.95))
	t.set_color(&"low", type, Color(1.0, 0.3, 0.26))
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


func _say(text: String, seconds: float = 2.5) -> void:
	_message.text = text
	_message_left = seconds


# --- Controls ----------------------------------------------------------------

## Whether the pointer counts as captured: null asks the window, a bool decides. For a suite,
## since a headless run has no pointer to capture.
var mouse_capture_override: Variant = null


## Whether mouse motion turns the view now: only while the pointer is captured, so a pointer
## freed for the menu, the command line or a browser tab not yet clicked moves a cursor and
## not the head.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


## The mouse turns the view. [b]Nothing fed the samplers a mouse event until 2026-10-11[/b]: a
## [DotFpsSampler] reads the keys itself but is handed mouse motion, and this client never
## handed it any, so the view turned only as the player walked. In [code]_input[/code], not
## [code]_unhandled_input[/code], so no Control under the captured pointer can swallow it.
## Offline the player's sampler takes it, connected the client's; while the command line is
## open the player's is held aside, so typing never turns the head.
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion) or not mouse_drives_view():
		return

	var sampler: DotFpsSampler = _sampler if not _offline else (player.sampler if player != null else null)

	if sampler != null:
		sampler.handle_event(event)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not _command.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	var key := event as InputEventKey

	# The Tab board, held: shown while the key is down, released when it comes up.
	if key != null and key.is_action(LmBindings.SCOREBOARD) and not key.echo and not _command.visible:
		_show_board(key.pressed)
		return

	if key == null or not key.pressed or key.echo or _command.visible:
		return

	if chat != null and chat.is_typing():
		return

	if key.is_action_pressed(USE_ACTION):
		_act("use")
		return

	# Each a row of [LmBindings], matched by its action so a key moved on the Controls page
	# moves what it does here. Enter is the command line's fixed second key; Escape no row holds.
	if key.is_action(LmBindings.FLASHLIGHT):
		_act("flashlight")
	elif key.is_action(LmBindings.VIEW):
		if game.config.allow_third_person:
			third_person = not third_person
	elif key.is_action(LmBindings.COMMAND) or key.keycode == KEY_ENTER:
		_command.visible = true
		# Typing is not walking: the sampler is detached until the line is sent.
		_held_sampler = player.sampler
		player.sampler = null
		_command.text = "/"
		_command.grab_focus()
		_command.caret_column = 1
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif key.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		# And the settings: a released pointer with nothing to click was half a key. The
		# menu sits deeper in the tree and normally hears Escape first; this is for an
		# Escape it left alone.
		if settings != null:
			settings.open()


func _on_command(text: String) -> void:
	_command.visible = false
	_command.release_focus()

	if _held_sampler != null:
		player.sampler = _held_sampler
		_held_sampler = null

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_act("command", {"text": text})


## The house's sounds. Without one (a broken catalogue) the house is silent, which is all.
## What the server says to play: connected, the click of a use is the server's to call, since
## only it knows whether E landed on something (offline `_act` clicks itself).
func _listen_for_sounds() -> void:
	bridge.sound_received.connect(func(id: StringName) -> void:
		var _heard := audio.play(id) if audio != null else false)


func _build_audio() -> void:
	audio = LmAudio.new()
	audio.name = "Sound"
	add_child(audio)
	var ready_now := audio.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "no sound", {"why": ready_now.error.message})
		remove_child(audio)
		audio.free()
		audio = null


## The catch, felt. The red screen while caught is the meter's vignette and stays the HUD's;
## the MOMENT of being caught is an effect, and an effect belongs to dot-fx, whose manager is
## where "allow flashes", the three-a-second limit and "shake" are enforced.
func _build_effects() -> void:
	var catalogue := DotFxCatalogue.new()

	var flash := DotFxDef.new()
	flash.id = &"caught"
	flash.kind = DotFxDef.Kind.SCREEN
	flash.flash_peak = 0.55
	flash.flash_colour = Color(0.75, 0.0, 0.0, 1.0)
	flash.flash_decay_ms = 700
	catalogue.add(flash)

	var jolt := DotFxDef.new()
	jolt.id = &"caught_jolt"
	jolt.kind = DotFxDef.Kind.SHAKE
	jolt.shake_trauma = 0.5
	catalogue.add(jolt)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = catalogue
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)
	var built := effects.setup()

	if not built.ok:
		DotLog.warn(CHANNEL, "no effects", {"why": built.error.message})
		remove_child(effects)
		effects.free()
		effects = null
		return

	_flash_rect = ColorRect.new()
	_flash_rect.name = "Flash"
	_flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.color = Color(0, 0, 0, 0)
	_hud.add_child(_flash_rect)
	# Over the world and the vignette, under the words: a flash that dims "SHE SEES YOU" is
	# hiding the one line that says what happened.
	_hud.move_child(_flash_rect, _vignette.get_index() + 1)


## Sound and effects, once a frame, after the camera is placed.
func _present(delta: float) -> void:
	var caught := player.caught_left > 0.0

	if caught and not _was_caught and effects != null:
		var _flashed := effects.flash(&"caught")
		effects.shake_at(&"caught_jolt", camera.global_position)

	_was_caught = caught

	if audio != null:
		audio.meter = player.meter
		audio.listen_from(camera.global_position)

	if effects != null:
		effects.viewer_position = camera.global_position
		effects.viewer_forward = -camera.global_basis.z
		effects.advance(delta)
		# dot-fx computes the jolt and touches no camera; it is added here, after the camera
		# is placed from the player, so it never feeds back into where the player looks.
		camera.global_position += camera.global_basis * effects.shake.offset()
		_flash_rect.color = effects.flash_colour


func _act(action: String, args: Dictionary = {}) -> void:
	if player == null:
		return

	if not _offline:
		var body := args.duplicate()

		if action == "flashlight":
			body["on"] = not player.flashlight
			# Shown at once: the light is the player's own, and waiting a round trip for it
			# to come on is a switch that feels broken.
			player.flashlight = not player.flashlight

		bridge.ask_act(action, body)
		return

	match action:
		"use":
			if game.interact(local_key) != "":
				var _heard := audio.click() if audio != null else false
		"flashlight":
			game.set_flashlight(local_key, not player.flashlight)
		"command":
			var reply := game.command(local_key, str(args.get("text", "")))
			_say(reply if reply != "" else "Nothing called that")
		"say":
			if chat != null:
				chat.say_locally(str(args.get("text", "")))


# --- Every frame -------------------------------------------------------------

func _process(delta: float) -> void:
	if net != null and net.is_running():
		net.interpolate_frame(-1.0)

	if player == null:
		return

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the
	# clock stretches and shrinks its ticks while it settles on the server, so a physics frame
	# now and then runs no tick or two, and drawn at the engine's fraction the eye stood still
	# on one frame and moved double on the next. `DotFpsController.render_state` reads it from
	# `render_clock` (dot-player-controller); by name both ways, so a shell older than either
	# draws as before. Null offline, where every physics frame is one tick.
	if player.controller != null:
		player.controller.set(&"render_clock", net.clock if net != null and net.is_running() else null)

	_place_camera()
	flashlight.visible = player.flashlight
	_draw_witches()

	for key: StringName in game.players:
		var other: LmPlayer = game.players[key]
		# Only the people in the same house: the others are on another level, out of sight.
		other.visible = other.level == player.level
		other.present_body(other == player and not third_person, other == player)

	var level := game.level_of(player)

	if level == null:
		_step.text = "Joining…"
		return

	_step.text = "Level %d of %d — %s" % [player.level, game.last_level(), game.step_of(player)]
	_holds.text = "Holding: %s" % (", ".join(_hold_names(level)) if not player.holds.is_empty() else "nothing")
	var target := game.target_of(player.player_key)
	if target.is_empty():
		prompt.clear()
	else:
		prompt.show_prompt(str(target["text"]), DotInputBinding.describe_action(USE_ACTION))
	_meter_bar.value = player.meter
	_present(delta)
	_meter_bar.visible = player.meter > 0.01
	(_vignette.material as ShaderMaterial).set_shader_parameter("amount", player.meter * 0.85 if player.caught_left <= 0.0 else 1.0)

	if _message_left > 0.0:
		_message_left -= delta

		if _message_left <= 0.0:
			_message.text = ""


func _hold_names(level: LmLevel) -> PackedStringArray:
	var out := PackedStringArray()

	for item_id in player.holds:
		var named := item_id

		if level != null:
			for item: Dictionary in level.doc.get("items", []):
				if str(item["id"]) == item_id:
					named = str(item["name"])

			for station: Dictionary in level.doc.get("stations", []):
				if str(station.get("gives", "")) == item_id:
					named = "bucket of water" if str(station.get("kind", "")) == "tap" else "a key from the vent"

		out.append(named)

	return out


func _place_camera() -> void:
	var eye := player.drawn_eye_position()
	var basis := Basis.from_euler(Vector3(deg_to_rad(player.controller.state.pitch), deg_to_rad(player.controller.state.yaw), 0.0))

	if third_person:
		var back := basis.z * 3.2 + Vector3(0, 0.6, 0)
		camera.global_transform = Transform3D(basis, eye + back)
	else:
		camera.global_transform = Transform3D(basis, eye)


## Each witch where the clock puts her, with her sight drawn faintly on the floor.
func _draw_witches() -> void:
	var seconds := game.seconds_now()

	for n: int in game.levels:
		var level: LmLevel = game.levels[n]

		# Only the level this player is on: thirty-two houses of witches is a lot of nodes
		# for nobody to see.
		if n != player.level:
			continue

		for i in level.witches.size():
			var key := "%d|%d" % [n, i]
			var view: Node3D = _witch_views.get(key, null)

			if view == null:
				view = _witch_view(float(level.witches[i]["sight"]) * game.config.witch_sight_scale, float(level.witches[i]["cone"]) * game.config.witch_cone_scale)
				add_child(view)
				_witch_views[key] = view

			var pose := level.witch_pose(i, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep)
			view.global_position = level.position + (pose["at"] as Vector3)
			view.rotation.y = float(pose["facing"])
			(view.get_node("Head") as Node3D).rotation.y = float(pose["head"])

	var heard := {}

	for key: String in _witch_views.keys():
		var n := int(key.split("|")[0])
		var view := _witch_views[key] as Node3D
		view.visible = n == player.level

		if view.visible and audio != null:
			# Her drone is hung at her head height, where the old player sat in her view.
			audio.witch(key, view.global_position)
			heard[key] = true

	# The drones of a level left behind stop: a hidden node's player kept humming, from where
	# the witch last stood, on a level nobody here was on any more.
	if audio != null:
		audio.keep_witches(heard)


func _forget_witches() -> void:
	if audio != null:
		audio.forget_witches()

	for view: Node in _witch_views.values():
		if is_instance_valid(view):
			view.queue_free()

	_witch_views.clear()


## A witch: a tall black robe, a pale face, a hat, two red eyes, and the cone of her sight as a
## faint red fan on the floor — being seen should be something a careful player can avoid.
static func _witch_view(sight: float, cone: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Witch"
	var robe := MeshInstance3D.new()
	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 0.18
	cone_mesh.bottom_radius = 0.6
	cone_mesh.height = 1.9
	robe.mesh = cone_mesh
	robe.position = Vector3(0, 0.95, 0)
	var black := StandardMaterial3D.new()
	black.albedo_color = Color(0.03, 0.03, 0.04)
	robe.material_override = black
	root.add_child(robe)
	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 2.05, 0)
	root.add_child(head)
	var face := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.2
	sphere.height = 0.42
	face.mesh = sphere
	var pale := StandardMaterial3D.new()
	pale.albedo_color = Color(0.72, 0.75, 0.68)
	face.material_override = pale
	head.add_child(face)
	var hat := MeshInstance3D.new()
	var hat_mesh := CylinderMesh.new()
	hat_mesh.top_radius = 0.0
	hat_mesh.bottom_radius = 0.32
	hat_mesh.height = 0.7
	hat.mesh = hat_mesh
	hat.position = Vector3(0, 0.45, 0)
	hat.material_override = black
	head.add_child(hat)
	var eyes := StandardMaterial3D.new()
	eyes.albedo_color = Color(1.0, 0.1, 0.05)
	eyes.emission_enabled = true
	eyes.emission = Color(1.0, 0.1, 0.05)
	eyes.emission_energy_multiplier = 4.0

	for side in [-0.07, 0.07]:
		var eye := MeshInstance3D.new()
		var dot := SphereMesh.new()
		dot.radius = 0.035
		dot.height = 0.07
		eye.mesh = dot
		eye.material_override = eyes
		eye.position = Vector3(side, 0.03, -0.18)
		head.add_child(eye)

	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.15, 0.1)
	glow.light_energy = 0.6
	glow.omni_range = 3.0
	glow.position = Vector3(0, 0.0, -0.3)
	head.add_child(glow)

	# The sight: a fan on the floor, turning with her head.
	var fan := MeshInstance3D.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := 16
	var half := deg_to_rad(cone * 0.5)

	for k in steps:
		var a0 := -half + 2.0 * half * float(k) / float(steps)
		var a1 := -half + 2.0 * half * float(k + 1) / float(steps)
		st.add_vertex(Vector3.ZERO)
		st.add_vertex(Vector3(-sin(a1), 0, -cos(a1)) * sight)
		st.add_vertex(Vector3(-sin(a0), 0, -cos(a0)) * sight)

	fan.mesh = st.commit()
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.8, 0.0, 0.0, 0.07)
	red.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.cull_mode = BaseMaterial3D.CULL_DISABLED
	fan.material_override = red
	fan.position = Vector3(0, -2.0, 0)
	head.add_child(fan)
	return root


## dot-game's chat box and microphone, with this game's channels and voice format. It also
## draws dot-server's own lines (the vote between games, joins, an admin's `say`), which arrive
## on the shell's client link rather than on this game's bridge. Static so a suite can build
## the same box the client does.
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
