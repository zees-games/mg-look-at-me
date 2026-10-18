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
const LmWitch := preload("lm_witch.gd")
const LmScares := preload("lm_scares.gd")
const LmScareView := preload("lm_scare_view.gd")

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

var _probe: DotCameraProbe = null
var _fade: DotCameraFade = null
var _focus: Marker3D = null

var _env: Environment = null
var _witch_views: Dictionary = {}

## The events this client has shown, for the level it showed them on ([method _show_events]).
var _events_shown: Dictionary = {}
var _events_level := -1
## Room id -> seconds into its lamps' dying flicker.
var _dying: Dictionary = {}
## Her, at the far end of a corridor, for a moment (a "glimpse" event); and for how long.
var _glimpse: Node3D = null
var _glimpse_left := 0.0
var _hud: Control = null
var _step: Label = null
var _objective: VBoxContainer = null
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

## The Tab board, the menu's ([member DotGameClient.board]). See [method _dress_board].
var board: DotMenuScoreboard = null

## When this client started, for an offline board's "time".
var _started_msec: int = Time.get_ticks_msec()
var _offline: bool = true
## Connected, the keys are sampled here and sent; the local player is predicted from them.
var _sampler: DotFpsSampler = null
var chat: DotGameChatClient = null
## Look at a player and press G to stop hearing them, K to mute them; connected games only.
var look_mute: DotVoiceLookMute = null
## The house's sounds, through dot-audio. See [LmAudio].
var audio: LmAudio = null
## The catch, felt: a red flash and a jolt through dot-fx, so the settings' "allow flashes" and
## "shake" reach them. See [method _build_effects].
var effects: DotFxManager = null
var _flash_rect: ColorRect = null
## The catch already shown, so a catch is flashed once and not every frame it lasts.
var _was_caught := false
## Whether any witch saw the local player last frame, for the stinger on the first sight.
var _was_seen := false
## How long the witch that has you is in your face.
const SCARE_SECONDS := 0.9
## The witch that lunges at a caught player: in front of the camera for the first moment of a
## catch. See [method _scare_at].
var _scare: Node3D = null
var _scare_left := 0.0
## Sanity scares, demons and the look-behind whisper (see [LmScares]): the client's own, drawn
## by the view.
var scares: LmScares = null
var scare_view: LmScareView = null
## Metres the local player has walked since their last footfall, and where they were.
var _stride := 0.0
var _stride_from := Vector3.INF
## Doors the local player had open last frame, to hear the ones they open (offline and
## connected alike: the owner's progress is theirs either way).
var _doors_heard: Dictionary = {}
var _doors_level := -1

## The player's own settings and the screen Escape opens. See [LmSettings].
var settings: LmSettings = null

## The player's console ([member DotGameClient.console]).
var console: DotConsoleController = null

## dot-game's client platform: the loading cover (held until this player exists and the camera
## is current), the settings' menu, the console, the HUD's theme, Tab, M, the pointer and the
## input block the samplers follow. See [DotGameClient].
var platform: DotGameClient = null


func _ready() -> void:
	# First, so the cover is up before anything of the house is drawn: the house used to show
	# itself, and the player, while it was still being built.
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.spawned_fn = func() -> bool: return player != null and camera != null and camera.current
	platform.scoreboard_action = LmBindings.SCOREBOARD
	add_child(platform)
	link = platform.link as Node
	_offline = platform.offline
	_build_environment()
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
	# Nothing in a dark house is seen from further, and every lamp past it is one fewer lamp
	# competing for the renderer's few lights (see _process).
	camera.far = 90.0
	add_child(camera)
	camera.current = true

	# The flashlight: a hard bright middle with a soft edge, so it reads as a torch in a dark
	# house and not a flat disc pasted on the wall (the first play test's "flat circular
	# flashlight"). It is also what a witch sees you by, which is the game's trade.
	flashlight = SpotLight3D.new()
	flashlight.name = "Flashlight"
	flashlight.spot_range = 20.0
	flashlight.spot_angle = 36.0
	# Under 1 the light falls away from the middle at once: a hot centre fading out, where 1
	# and over is an even disc with a hard rim.
	flashlight.spot_angle_attenuation = 0.55
	flashlight.spot_attenuation = 0.6
	flashlight.light_energy = 3.2
	flashlight.light_color = Color(1.0, 0.93, 0.8)
	flashlight.shadow_enabled = true
	flashlight.light_volumetric_fog_energy = 0.0
	camera.add_child(flashlight)
	flashlight.position = Vector3(0.2, -0.15, 0.0)
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

	_build_hud()
	_build_audio()
	_build_effects()
	chat = new_chat()
	add_child(chat)
	_build_settings()
	_build_scares()

	if not _offline:
		DotLog.result(CHANNEL, "the netcode", _build_netcode())
		DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))
		_build_look_mute()
		return

	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))

	game.said.connect(func(key: StringName, text: String) -> void:
		if key == local_key:
			_say(text))
	game.caught.connect(func(key: StringName) -> void:
		if key == local_key:
			_say("SHE SEES YOU", 2.0))


## The player's settings, bound to the camera and the sampler's tunables. See [LmSettings].
##
## The look is bound to the controller's own tunables, which both samplers read (offline the
## player's, connected the client's); [method _adopt_player] binds them for a later player.
func _build_settings() -> void:
	settings = LmSettings.new()
	add_child(settings)
	platform.settings = settings
	platform.hud = _hud
	# The lamp's amber over the menu's theme: Christian's first play test asked for a darker HUD
	# a player can restyle in the menu.
	platform.hud_accent = piece_theme()
	platform.chat = chat
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


## The Tab board: everybody in the house, the level they are on, the furthest they have got
## and whether they got out, beside how long they have been on and their ping. Online the
## levels are the server's (see [LmModule]'s `_game_board_fields`); offline, this world's
## ([method board_snapshot]). The platform feeds it and holds it on Tab.
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
	_env.ambient_light_color = Color(0.45, 0.5, 0.68)
	_env.ambient_light_energy = 0.05
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.015, 0.015, 0.025)
	_env.fog_density = 0.05
	_env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_env.tonemap_exposure = 1.1
	# A little glow, so a lamp, a fire and a witch's eyes bloom out of the dark.
	_env.glow_enabled = true
	_env.glow_intensity = 0.6
	_env.glow_bloom = 0.05
	_env.glow_hdr_threshold = 1.2
	_env.adjustment_enabled = true
	_env.adjustment_saturation = 0.8
	_env.adjustment_contrast = 1.08
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
	_key_line.text = "%s use   %s flashlight   %s camera   %s crouch   %s command   %s house   %s help" % [
		k.call(LmBindings.USE, "E"), k.call(LmBindings.FLASHLIGHT, "F"), k.call(LmBindings.VIEW, "F5"),
		k.call(&"dot_fps_crouch", "Ctrl"), k.call(LmBindings.COMMAND, "/"), k.call(&"dot_menu_maps", "M"),
		k.call(DotMenuBindings.HELP_ACTION, "H")]


## Dithers the screen so a smooth dark gradient is not drawn as stripes (see _build_hud).
const DITHER_SHADER := "shader_type canvas_item;
uniform sampler2D screen : hint_screen_texture, filter_nearest;
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}
void fragment() {
	vec2 p = FRAGCOORD.xy;
	float noise = hash(p) + hash(p + 17.31) - 1.0;
	COLOR = vec4(texture(screen, SCREEN_UV).rgb + vec3(noise * 2.0 / 255.0), 1.0);
}
"

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Control.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud)

	# The dark house is mostly very low, very smooth gradients (a lamp's falloff across a far wall),
	# and an 8-bit framebuffer steps them into concentric stripes. The compatibility renderer has no
	# debanding (the viewport and project switches are ignored there), so the frame is dithered here:
	# triangular noise of about two levels, added after the world is drawn and before the HUD is.
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


## This house's accent over whichever theme the player picked in the menu: the lamp's amber
## as the glance pieces' highlight and their plates' edge. The plates, the words, the key cap
## and the outline are the theme's (dark by default), so a light or high-contrast theme can
## change them. Static so a render tool can use it.
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
	# A click taking the pointer back, Tab and M are the platform's (DotGameClient).
	var key := event as InputEventKey

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
		var wanted := game.view_rules.toggled(third_person)
		if wanted == third_person and game.view_rules.refusal() != "":
			_say(game.view_rules.refusal())
		third_person = wanted
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

	if caught and not _was_caught:
		if effects != null:
			var _flashed := effects.flash(&"caught")
			effects.shake_at(&"caught_jolt", camera.global_position)
		if audio != null:
			var _screamed := audio.scream()
		_scare_left = SCARE_SECONDS
		if _scare != null:
			_scare.call(&"lunge")

	_was_caught = caught
	_scare_at(delta)

	if scare_view != null:
		var _told := scare_view.present(delta, scare_view_state())

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

	if action == "flashlight" and audio != null:
		# Heard at once, on the key: the click is the player's own, the same offline and on a server.
		var _clicked := audio.torch(not player.flashlight)

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

	# Only the level you are on is drawn. Every level is built at once, and the compatibility
	# renderer draws a capped number of lights: with the lamps of three-times-bigger levels in
	# view, the nearest lights were the ones dropped, and she stood unlit at the end of her
	# corridor (2026-10-12). Bodies stay where they are; only the drawing goes.
	for n: int in game.levels:
		(game.levels[n] as Node3D).visible = n == player.level

	_draw_witches()
	_swing_doors(get_process_delta_time())
	_show_events(get_process_delta_time())

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
	_hear_player(level)
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
					named = str(station["gives_name"]) if station.has("gives_name") else ("bucket of water" if str(station.get("kind", "")) == "tap" else "a key from the vent")

		out.append(named)

	return out


## The camera on the drawn eye, or swept back from it in third person.
##
## [b]Swept, not set.[/b] Set 3.2 m back, the camera spent every corridor of the house inside
## a wall; dot-core's [DotCameraProbe] sweeps a sphere from the eye and eases in ahead of the
## wall. The server's `mp_forceview` is applied here every frame, so a change to it lands on
## the next frame whatever the view key last did.
func _place_camera() -> void:
	third_person = game.view_rules.resolve(third_person)
	var eye := player.drawn_eye_position()
	var basis := Basis.from_euler(Vector3(deg_to_rad(player.controller.state.pitch), deg_to_rad(player.controller.state.yaw), 0.0))

	if _fade == null:
		_fade = DotCameraFade.new()
		_fade.name = "Fade"
		_fade.bodies_fn = _other_players
		camera.add_child(_fade)

	if third_person:
		if _probe == null:
			_probe = DotCameraProbe.new(camera.get_world_3d(), LmGame.LAYER_WORLD)
		var back := basis.z * 3.2 + Vector3(0, 0.6, 0)
		camera.global_transform = Transform3D(basis, _probe.resolve(eye, eye + back, get_process_delta_time()))
		if _focus == null or _focus.get_parent() != player:
			_focus = Marker3D.new()
			_focus.name = "CameraFocus"
			_focus.position = Vector3(0.0, 1.5, 0.0)
			player.add_child(_focus)
		_fade.focus = _focus
	else:
		if _probe != null:
			_probe.reset()
		camera.global_transform = Transform3D(basis, eye)
		_fade.focus = null


## Everybody else in the house, for the camera fade: hidden at the lens, faded between the
## third-person camera and you.
func _other_players() -> Array:
	var out: Array = []
	for key in game.players:
		var other: Node3D = game.players[key]
		if other != player and is_instance_valid(other):
			out.append(other)
	return out


## Metres between a witch's footfalls: a long, slow stride.
const WITCH_STRIDE := 1.35
## And the player's, walking; crouched it is shorter and quieter.
const STRIDE := 2.0
const STRIDE_CROUCHED := 1.4


## Each witch where the clock puts her, her sight on the floor, flaring while she sees you; her
## footfalls and her hum where she is; the stinger the moment one starts seeing you.
##
## [b]Whether she sees you is the server's own question[/b] ([method LmGame.exposure]), asked
## here for the local player alone: the witches are posed from the clock on both ends
## (Decision 2), so the answer here is the answer there, and what a player sees her do is
## what is filling the meter.
func _draw_witches() -> void:
	var seconds := game.seconds_now()
	# Drawn between ticks, as the player is: posed only at the tick, she stepped at the tick
	# rate on any faster display. Whether she sees you is still asked at the tick's time.
	var drawn_seconds := seconds + Engine.get_physics_interpolation_fraction() / float(maxi(game.tick_rate, 1))
	var delta := get_process_delta_time()
	var seen := false
	var level := game.level_of(player)

	if level != null:
		var n := player.level

		for i in level.witches.size():
			var key := "%d|%d" % [n, i]
			var view: Node3D = _witch_views.get(key, null)

			if view == null:
				view = LmWitch.new()
				# In the tree first: her hat and eyes are placed from where her head is.
				add_child(view)
				view.call(&"build", float(level.witches[i]["sight"]) * game.config.witch_sight_scale, float(level.witches[i]["cone"]) * game.config.witch_cone_scale)
				_witch_views[key] = view

			var pose := game.witch_pose_for(player, level, i, drawn_seconds)
			var walking := float(level.witches[i]["speed"]) * game.config.witch_speed_scale
			var _moved: float = view.call(&"place", level.position + (pose["at"] as Vector3), float(pose["facing"]), float(pose["head"]), delta, walking)
			var sees := player.caught_left <= 0.0 and game.exposure(player, level, i, seconds) > 0.0
			view.call(&"set_seeing", sees, delta)
			seen = seen or sees

			if float(view.get(&"stride")) >= WITCH_STRIDE:
				view.set(&"stride", fmod(float(view.get(&"stride")), WITCH_STRIDE))
				if audio != null:
					var _stepped := audio.witch_step(view.global_position)

	# The first moment of being seen is the one to hear: a stab, once, then the heartbeat.
	if seen and not _was_seen and player.meter < 0.5 and audio != null:
		var _stung := audio.stinger()

	_was_seen = seen
	var heard := {}

	for key: String in _witch_views.keys():
		var n := int(key.split("|")[0])
		var view := _witch_views[key] as Node3D
		view.visible = n == player.level

		if view.visible and audio != null:
			# Her hum is hung where she is, at her head.
			audio.witch(key, view.global_position + Vector3(0, 1.9, 0))
			heard[key] = true

	# The drones of a level left behind stop: a hidden node's player kept humming, from where
	# the witch last stood, on a level nobody here was on any more.
	if audio != null:
		audio.keep_witches(heard)


## How far an opened door stands open, in radians, and how fast it swings there.
const DOOR_OPEN := 1.75
const DOOR_SWING := 2.5


## Doors the local player has opened swing open on their hinge, for them. A door is open per
## player (Decision 1), and until 2026-10-12 one you had opened still stood there shut, and you
## walked through it. Only the drawing turns: the body stays where it is for everybody else,
## and the player's own collision already ignores it.
func _swing_doors(delta: float) -> void:
	var level := game.level_of(player)
	if level == null:
		return
	# The predicting controller passes the doors a witch has open, as the server's does.
	game._apply_doors(player)
	# A door a witch is opening swings open for everybody, the clock's doing like her walk.
	var witch_open: Dictionary = {}
	var seconds := game.seconds_now()

	for i in level.witches.size():
		var pose := level.witch_pose(i, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep, game.config.witch_door_seconds)

		if str(pose["door"]) != "":
			witch_open[str(pose["door"])] = maxf(float(witch_open.get(str(pose["door"]), 0.0)), float(pose["open"]))

	for door_id: String in level.doors:
		var door: Dictionary = level.doors[door_id]
		var body := door.get("body") as Node3D
		if body == null:
			continue
		var want := DOOR_OPEN if player.opened.has(door_id) else DOOR_OPEN * float(witch_open.get(door_id, 0.0))

		if want > 0.0 and not player.opened.has(door_id) and float(body.get_meta(&"swing", 0.0)) <= 0.0 and audio != null:
			var _creaked := audio.door(level.position + (door["centre"] as Vector3))

		var now := float(body.get_meta(&"swing", 0.0))
		if is_equal_approx(now, want):
			continue
		now = move_toward(now, want, delta * DOOR_SWING) if delta > 0.0 else want
		body.set_meta(&"swing", now)
		var normal: Vector3 = door["normal"]
		# The hinge is one edge of the door; it swings into the room it opens into.
		var hinge := Vector3(-LmLevel.DOOR_WIDTH * 0.5, 0, 0) if absf(normal.z) > 0.5 else Vector3(0, 0, -LmLevel.DOOR_WIDTH * 0.5)
		var turn := Basis(Vector3.UP, now * (1.0 if normal.z + normal.x > 0.0 else -1.0))
		for child in body.get_children():
			if child is VisualInstance3D:
				var rest: Transform3D = child.get_meta(&"rest", (child as Node3D).transform)
				child.set_meta(&"rest", rest)
				(child as Node3D).transform = Transform3D(turn, hinge - turn * hinge) * rest


## How the lamps of a dying room go: on and off over 1.25 s, then out, in step with the
## stutter in `lights_out.ogg` (tools/make_sounds.py).
const DYING := [[0.0, 0.18], [0.26, 0.34], [0.45, 0.72], [0.8, 0.86], [0.98, 1.25]]
const DYING_SECONDS := 1.25
## Metres from her a glimpse ends early: she is something seen down a corridor, never met.
const GLIMPSE_NEAR := 6.0


## The level's events as they happen to the local player ([member LmPlayer.fired], the server's
## to decide): a room's lamps flicker and die, a door slams where it is, and she stands at the
## end of a corridor looking back at you and is gone. Offline and connected alike, from
## progress. A new level, or a catch that reset this one, lights every lamp again.
func _show_events(delta: float) -> void:
	var level := game.level_of(player)

	if level == null:
		return

	if _events_level != player.level or player.fired.size() < _events_shown.size():
		for room_id: String in level.lamps:
			level.set_room_light(room_id, 1.0)
		if _events_level != player.level and _events_level != -1 and game.levels.has(_events_level):
			var before: LmLevel = game.levels[_events_level]
			for room_id: String in before.lamps:
				before.set_room_light(room_id, 1.0)
		_events_shown.clear()
		_dying.clear()
		_glimpse_left = 0.0
		_events_level = player.level

	# Heard from where the camera is now: the listener is otherwise moved after this, and a
	# sound placed from where it was last frame (before a warp) is refused as out of earshot.
	if audio != null:
		audio.listen_from(camera.global_position)

	for event_id: String in player.fired:
		if _events_shown.has(event_id):
			continue
		_events_shown[event_id] = true
		var event: Dictionary = level.events.get(event_id, {})
		match str(event.get("do", "")):
			"lights":
				for room_id in event.get("rooms", []):
					_dying[str(room_id)] = 0.0
					if audio != null and level.rooms.has(str(room_id)):
						var _buzzed := audio.lights_out(level.position + level.room_centre(str(room_id)) + Vector3(0, 2.6, 0))
			"slam":
				var door: Dictionary = level.doors.get(str(event.get("door", "")), {})
				if audio != null and not door.is_empty():
					var _slammed := audio.slam(level.position + (door["centre"] as Vector3) + Vector3(0, 1.2, 0))
			"glimpse":
				_glimpse_at(level, event)

	for room_id: String in _dying.keys():
		var t: float = _dying[room_id] + delta
		_dying[room_id] = t
		var on := false
		for span: Array in DYING:
			on = on or (t >= float(span[0]) and t < float(span[1]))
		level.set_room_light(room_id, 1.0 if on and t < DYING_SECONDS else 0.0)
		if t >= DYING_SECONDS:
			_dying.erase(room_id)

	# Lights that died before this client saw them (a reconnect) are simply out.
	for event_id: String in player.fired:
		var event: Dictionary = level.events.get(event_id, {})
		if str(event.get("do", "")) == "lights":
			for room_id in event.get("rooms", []):
				if not _dying.has(str(room_id)):
					level.set_room_light(str(room_id), 0.0)

	if _glimpse != null:
		_glimpse_left -= delta
		var near := (_glimpse.get_meta(&"at", Vector3.INF) as Vector3).distance_to(player.global_position) < GLIMPSE_NEAR
		_glimpse.visible = _glimpse_left > 0.0 and not near
		if near:
			_glimpse_left = 0.0
		if _glimpse.visible:
			# Standing, breathing, looking back down the corridor at you.
			var _moved: float = _glimpse.call(&"place", _glimpse.get_meta(&"at"), float(_glimpse.get_meta(&"facing")), 0.0, delta, 0.0)


func _glimpse_at(level: LmLevel, event: Dictionary) -> void:
	var room_id := str(event.get("room", ""))

	if not level.rooms.has(room_id):
		return

	if _glimpse == null:
		_glimpse = LmWitch.new()
		_glimpse.name = "Glimpse"
		add_child(_glimpse)
		_glimpse.call(&"build", 0.0, 0.0)
		# A cold light on her from nowhere: down a dark corridor, with the torch off, two eyes
		# alone read as a lamp; she has to be a shape standing there.
		var pale := OmniLight3D.new()
		pale.name = "Pale"
		pale.light_color = Color(0.62, 0.75, 0.85)
		pale.light_energy = 3.0
		pale.omni_range = 7.0
		pale.position = Vector3(0.0, 2.4, -0.8)
		_glimpse.add_child(pale)

	var at := level.position + level._room_point(room_id, event.get("at", [0.5, 0.5]))
	var cell := float(level.doc.get("cell", 8.0))
	var look: Array = event.get("look", [])
	var toward := Vector3(float(look[0]) * cell, 0.0, float(look[1]) * cell) + level.position if look.size() == 2 else player.global_position
	var dir := toward - at
	_glimpse.set_meta(&"at", at)
	_glimpse.set_meta(&"facing", atan2(-dir.x, -dir.z))
	_glimpse.call(&"set_seeing", false, 0.0)
	_glimpse_left = float(event.get("seconds", 2.5))
	_glimpse.visible = true
	if audio != null:
		var _stung := audio.stinger()


## The player's own footfalls, and the doors they open, heard. Both from what the world already
## says (where the player is drawn, what they have opened), so offline and connected alike.
func _hear_player(level: LmLevel) -> void:
	if audio == null:
		return

	var at := player.drawn_eye_position()

	if _stride_from != Vector3.INF:
		var moved := Vector2(at.x - _stride_from.x, at.z - _stride_from.z).length()
		# A warp (a catch, a level change) is not a step.
		if moved < 1.0 and player.controller != null and player.controller.state.is_grounded():
			_stride += moved

	_stride_from = at
	var crouched := player.is_crouching()

	if _stride >= (STRIDE_CROUCHED if crouched else STRIDE):
		_stride = 0.0
		var _stepped := audio.step(crouched)

	# A new level (or a catch that reset this one) is a new set of doors: nothing to hear.
	if _doors_level != player.level or player.opened.size() < _doors_heard.size():
		_doors_heard = player.opened.duplicate()
		_doors_level = player.level
		return

	for door_id: String in player.opened:
		if not _doors_heard.has(door_id):
			_doors_heard[door_id] = true
			var door: Dictionary = level.doors.get(door_id, {})
			if not door.is_empty():
				var _creaked := audio.door(level.position + (door["centre"] as Vector3) + Vector3(0, 1.2, 0))


## The first moment of a catch: the witch that has you, in your face, arms up, with a shriek.
## Drawn and heard here only; the catch itself is the server's.
func _scare_at(delta: float) -> void:
	if _scare == null:
		_scare = LmWitch.new()
		add_child(_scare)
		_scare.call(&"build", 0.0, 0.0)
		_scare.name = "Scare"
		_scare.visible = false

	if _scare_left <= 0.0:
		_scare.visible = false
		return

	_scare_left -= delta
	_scare.visible = true
	# Close enough to fill the view from the chest up, facing the lens, lit by her own eyes.
	var forward := -camera.global_basis.z
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.001 else Vector3.FORWARD
	var feet := camera.global_position + forward * 1.15 - Vector3(0, 1.85, 0)
	var _moved: float = _scare.call(&"place", feet, atan2(forward.x, forward.z), 0.0, delta)
	_scare.call(&"set_seeing", true, delta)


func _build_scares() -> void:
	scares = LmScares.new(game.config)
	scare_view = LmScareView.new()
	scare_view.name = "Scares"
	scare_view.director = scares
	scare_view.audio = audio
	scare_view.camera = camera
	scare_view.spook = _spook
	add_child(scare_view)
	# Under the vignette and the words, over the world: its own rect, so a flash never has to
	# share one with the catch's.
	var rect := ColorRect.new()
	rect.name = "ScareFlash"
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.color = Color(0, 0, 0, 0)
	_hud.add_child(rect)
	_hud.move_child(rect, _vignette.get_index() + 1)
	scare_view.flash = rect


## A fright moves the meter, and the meter is the server's: offline it is the house's own call,
## connected it is a request (which the server caps, and may refuse).
func _spook(amount: float) -> void:
	if player == null:
		return

	if _offline:
		var _applied := game.spook(local_key, amount)
	elif bridge != null:
		bridge.ask_act("spook", {"amount": amount})


## What the scare director is told each frame: the eye, the view, the meter, and a ray for room.
func scare_view_state() -> Dictionary:
	return {
		"meter": player.meter, "level": player.level, "who": hash(String(local_key)),
		"eye": camera.global_position, "feet": player.global_position, "forward": -camera.global_basis.z,
		"caught": player.caught_left > 0.0, "clear": _open_ahead,
	}


## How far from [param from] along [param dir] is open, up to [param reach]: a wall or a shut door ends it.
func _open_ahead(from: Vector3, dir: Vector3, reach: float) -> float:
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * reach, LmGame.LAYER_WORLD)
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	return reach if hit.is_empty() else from.distance_to(hit["position"] as Vector3)


func _forget_witches() -> void:
	if audio != null:
		audio.forget_witches()

	for view: Node in _witch_views.values():
		if is_instance_valid(view):
			view.queue_free()

	_witch_views.clear()


## dot-voice's look-to-gag and look-to-mute on the keys [LmBindings] binds. The server's
## sv_voice_gag_* and sv_voice_mute_allowed are followed from the shell's link, so an owner can
## switch them off. A mute also drops that player's chat through the box's block list.
func _build_look_mute() -> void:
	if chat == null or chat.voice == null:
		return

	look_mute = DotVoiceLookMute.new()
	look_mute.name = "LookMute"
	look_mute.manager = chat.voice as DotVoiceManager
	look_mute.separate_keys = true
	look_mute.gag_action = LmBindings.VOICE_GAG
	look_mute.mute_action = LmBindings.VOICE_MUTE
	look_mute.target_fn = voice_target
	look_mute.chat_mute_fn = _chat_mute
	add_child(look_mute)

	var source: Object = link if link != null else DotRegistry.get_service(LINK_SERVICE)
	var _following := look_mute.follow_cvars(source) if source != null else false


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
