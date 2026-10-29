extends "lm_client_world.gd"

## The client's frame: input, the per-frame update, the environment, effects and sounds.


func _say_ready() -> void:
	if workbench_remote != null:
		workbench_remote.ask()
	if bridge != null:
		bridge.ask_ready()


const STEP_FORMAT := "Level %d of %d — %s"
const HOLDS_FORMAT := "Holding: %s"

var _hud_level := -1
var _hud_last := -1
var _hud_step := ""
var _hud_holds := 0
var _hud_holds_level: LmLevel = null


func _physics_process(delta: float) -> void:
	if _offline or net == null or not net.is_running() or bridge == null:
		return

	if link != null and link.has_method("is_playing") and not bool(link.call("is_playing")):
		return

	var typing := _command.visible or (chat != null and chat.is_typing())
	# Under the cover the keys are not read (the sampler is suspended too), so the server and the
	# prediction see an idle body: the clock still runs and the predicted body settles.
	var move := _sampler.sample(delta) if _sampler != null and not typing and not _covered() else DotFpsCommand.new()

	if command_override != null:
		move = command_override

	var ticks := net.clock.advance(delta)

	for i in range(ticks):
		if net.clock.is_synced():
			bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move)


## The server's flashlight and darkness numbers, once its HELLO has set the config.
func _apply_light_config() -> void:
	_env.ambient_light_energy = game.config.darkness_ambient
	if fl_config != null:
		fl_config.range_m = game.config.flashlight_range
		fl_config.angle = game.config.flashlight_angle
		if fl != null:
			fl.refresh()
		if crowd != null:
			crowd.refresh()


func _build_environment() -> void:
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.0, 0.0, 0.0)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.45, 0.5, 0.68)
	_env.ambient_light_energy = 0.05
	_env.fog_enabled = true
	_env.fog_light_color = Color(0.015, 0.015, 0.025)
	_env.fog_density = FOG_CALM
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


func _say(text: String, seconds: float = 2.5) -> void:
	_message.text = text
	_message_left = seconds




## Whether mouse motion turns the view now: only while the pointer is captured, so a pointer
## freed for the menu, the command line or a browser tab not yet clicked moves a cursor and
## not the head.
func mouse_drives_view() -> bool:
	if mouse_capture_override != null:
		return bool(mouse_capture_override)
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


## The mouse turns the view: a [DotFpsSampler] is handed mouse motion by the client, in `_input` so
## no Control can swallow it. While the command line is open the player's sampler is held aside.
func _input(event: InputEvent) -> void:
	var motion := event is InputEventMouseMotion
	# A wheel tick is a press and a release in one frame, so polling misses it; the sampler
	# latches it (it can be bound to jump), but only if it is handed mouse buttons too.
	if not (motion or event is InputEventMouseButton) or _covered():
		return

	if motion and not mouse_drives_view():
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

	# Nothing below acts while the cover is up: no use, flashlight or command.
	if _covered():
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
		# Held, not just freed: a click outside or a menu closing must not recapture it mid-word.
		platform.hold_pointer(&"command")
	elif key.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		# And the settings: a released pointer with nothing to click was half a key. The
		# menu sits deeper in the tree and normally hears Escape first; this is for an
		# Escape it left alone.
		if settings != null:
			settings.open()


## The house's sounds. Without one (a broken catalogue) the house is silent, which is all.
## What the server says to play: connected, the click of a use is the server's to call, since
## only it knows whether E landed on something (offline `_act` clicks itself).
func _listen_for_sounds() -> void:
	bridge.sound_received.connect(func(id: StringName) -> void:
		var _heard := audio.play(id) if audio != null else false)


## The house just opened picks the quiet mood under it.
func _apply_mood() -> void:
	if audio != null and audio.ambient != null and game != null:
		audio.ambient.on_map(game.house_id, game.houses.get(game.house_id, {}))


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




func _process(delta: float) -> void:
	if net != null and net.is_running():
		net.interpolate_frame(-1.0)

	if player == null:
		return

	# Your own player is drawn at the clock's render alpha, not the engine's fraction, which stood the
	# eye still one frame and doubled it the next. Read by name both ways (older shells draw as before);
	# null offline.
	if player.controller != null:
		player.controller.set(&"render_clock", net.clock if net != null and net.is_running() else null)

	_place_camera()
	fl.apply_state({"on": player.flashlight})
	crowd.set_viewer(camera.global_position)

	# Only the level you are on is drawn: the compatibility renderer caps lights, and the nearest were
	# dropped with three levels' lamps in view. Bodies stay; only the drawing goes.
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
		# Everybody else's beam, from their eye along their look: nearest few cast shadows.
		crowd.set_lit(key, other != player and other.flashlight and other.level == player.level)
		crowd.place(key, other.eye_position(), other.look_direction())

	crowd.retain(game.players.keys())

	var level := game.level_of(player)

	if level == null:
		_step.text = "Joining…"
		return

	# The labels are rebuilt only when what they show changed, not every frame.
	var step := game.step_of(player)
	var last := game.last_level()
	if player.level != _hud_level or last != _hud_last or step != _hud_step:
		_hud_level = player.level
		_hud_last = last
		_hud_step = step
		_step.text = STEP_FORMAT % [_hud_level, last, step]
	var held_hash := player.holds.hash()
	if held_hash != _hud_holds or level != _hud_holds_level:
		_hud_holds = held_hash
		_hud_holds_level = level
		_holds.text = HOLDS_FORMAT % (", ".join(_hold_names(level)) if not player.holds.is_empty() else "nothing")
	var target := game.target_of(player.player_key)
	if target.is_empty():
		prompt.clear()
	else:
		prompt.show_prompt(String(target["text"]), DotInputBinding.describe_action(USE_ACTION))
	_meter_bar.value = player.meter
	_hear_player(level)
	_present(delta)
	_meter_bar.visible = player.meter > 0.01
	(_vignette.material as ShaderMaterial).set_shader_parameter("amount", player.meter * 0.85 if player.caught_left <= 0.0 else 1.0)

	if _message_left > 0.0:
		_message_left -= delta

		if _message_left <= 0.0:
			_message.text = ""
