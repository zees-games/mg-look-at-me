extends Node3D

## The client's state and what it draws of the house: the witches, doors, events and scares.

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
## The dot-flashlight node and the beams of the other players, shown from their `flashlight` flag.
var fl: DotFlashlight = null
var fl_config: DotFlashlightConfig = null
var crowd: DotFlashlightCrowd = null
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
## [DotKeyPrompt]; Not a Label with the letter fixed.
var prompt: DotKeyPrompt = null
var _message: Label = null
var _meter_bar: ProgressBar = null
var _vignette: ColorRect = null
var _command: LineEdit = null
var _message_left := 0.0
var _held_sampler: DotFpsSampler = null

var net: DotNetManager = null
## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var workbench_remote: DotGameWorkbenchRemoteClient = null
## The tuning panel's host: F9 solo, the admin's remote panel on a server that allows it.
var workbench: DotGameWorkbench = null
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
var _dread_level := 0.0
var _flicker_left := 0.0
var _flicker_rng := RandomNumberGenerator.new()
const FOG_CALM := 0.05
const FOG_AFRAID := 0.085
const FLASH_ENERGY := 3.2
## Witch views (by key) that are standing listening this frame: their hum stops, which is the tell.
var _witch_listening: Dictionary = {}
var _rest_level := -1
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


## A command to walk with instead of the keys: what a headless client in a suite has.
var command_override: DotFpsCommand = null


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


## Whether the pointer counts as captured: null asks the window, a bool decides. For a suite,
## since a headless run has no pointer to capture.
var mouse_capture_override: Variant = null


## Metres between a witch's footfalls: a long, slow stride.
const WITCH_STRIDE := 1.35


## And the player's, walking; crouched it is shorter and quieter.
const STRIDE := 2.0


const STRIDE_CROUCHED := 1.4


## How far an opened door stands open, in radians, and how fast it swings there.
const DOOR_OPEN := 1.75


const DOOR_SWING := 2.5


## How the lamps of a dying room go: on and off over 1.25 s, then out, in step with the
## stutter in `lights_out.ogg` (tools/make_sounds.py).
const DYING := [[0.0, 0.18], [0.26, 0.34], [0.45, 0.72], [0.8, 0.86], [0.98, 1.25]]


const DYING_SECONDS := 1.25


## Metres from her a glimpse ends early: she is something seen down a corridor, never met.
const GLIMPSE_NEAR := 6.0


## True while the load gate covers the screen or settles the body: no input, no round clock,
## no catches. False without a gate (a suite that adopts without this node's `_ready`).
func _covered() -> bool:
	var gate := platform.gate if platform != null else null
	return gate != null and is_instance_valid(gate) and not gate.is_open()


## Everything the sanity meter drives goes back to rest: audio layers, pending jump scare, demons,
## the dot-fx flash and shake. The HUD's meter and vignette follow `player.meter`, which the server
## resets with the player.
func rest_sanity() -> void:
	if audio != null:
		audio.rest()

	if scare_view != null:
		scare_view.rest()

	if effects != null:
		effects.clear()

	if _flash_rect != null:
		_flash_rect.color = Color(0, 0, 0, 0)


## The house closes in as the meter rises: the fog thickens and goes faintly red, and the
## flashlight stutters. Cheap, and all of it the client's own. The stutter is a flash, so
## "allow flashes" off keeps the beam steady.
func _dread(delta: float, caught: bool) -> void:
	var fear := 0.0 if caught else clampf(player.meter, 0.0, 1.0)
	_dread_level = move_toward(_dread_level, fear, delta * 0.5)

	if _env != null:
		_env.fog_density = lerpf(FOG_CALM, FOG_AFRAID, _dread_level)
		_env.fog_light_color = Color(0.015, 0.015, 0.025).lerp(Color(0.07, 0.008, 0.008), _dread_level)

	if flashlight == null:
		return

	_flicker_left -= delta

	if _flicker_left > 0.0:
		fl.energy_scale = 0.12
		return

	fl.energy_scale = 1.0
	var allowed: bool = settings == null or settings.settings.get_bool(&"allow_flashes", true)

	# From a third of the meter up, a dip now and then, more often as it fills.
	if allowed and _dread_level > 0.3 and _flicker_rng.randf() < delta * lerpf(0.1, 1.2, _dread_level):
		_flicker_left = _flicker_rng.randf_range(0.05, 0.16)


## Sound and effects, once a frame, after the camera is placed.
func _present(delta: float) -> void:
	# Scares, sounds and the stinger wait: the cover shows nothing and they would be spent.
	if _covered():
		return

	var caught := player.caught_left > 0.0

	# Dying, coming back and leaving the level each put the madness to rest: the heartbeat, the
	# whispers, a jump scare half shown, the flash and the shake. Before the catch's own scream.
	if caught != _was_caught or player.level != _rest_level:
		rest_sanity()
		_rest_level = player.level

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

	_dread(delta, caught)

	if audio != null:
		# A caught player's meter is pinned at full for the length of the catch: no heartbeat.
		audio.meter = 0.0 if caught else player.meter
		audio.listen_from(camera.global_position)

	if effects != null:
		effects.viewer_position = camera.global_position
		effects.viewer_forward = -camera.global_basis.z
		effects.advance(delta)
		# dot-fx computes the jolt and touches no camera; it is added here, after the camera
		# is placed from the player, so it never feeds back into where the player looks.
		camera.global_position += camera.global_basis * effects.shake.offset()
		_flash_rect.color = effects.flash_colour


## The figure an avatar action plays on: that peer's player, or the local one offline.
func _avatar_figure(peer_id: int) -> Object:
	var who: LmPlayer = null
	if bridge != null and peer_id != 0:
		who = game.players.get(bridge.key_of_peer(peer_id), null)
	if who == null and player != null and (net == null or peer_id == net.local_peer_id):
		who = player
	return who.figure.person if who != null and who.figure != null else null


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


## The camera on the drawn eye, or swept back from it in third person with dot-core's
## [DotCameraProbe] (set 3.2 m back it sat inside walls). The server's `mp_forceview` applies here
## every frame.
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


## Each witch where the clock puts her, her sight on the floor, her footfalls and hum, and the
## stinger when one starts seeing you. Whether she sees you is [method LmGame.exposure], asked for
## the local player alone: the witches are posed from the clock on both ends.
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
			var listening := bool(pose.get("listening", false))

			if bool(pose.get("running", false)):
				walking *= game.config.witch_chase_speed
			elif bool(pose.get("still", false)):
				walking = 0.0

			view.call(&"set_listening", listening, delta)

			if listening and not bool(_witch_listening.get(key, false)) and audio != null:
				var _cued := audio.listen_cue(view.global_position + Vector3(0, 1.9, 0))

			_witch_listening[key] = listening
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

		# Breathing stops: a witch listening makes no sound of her own, and the hush is the tell.
		if view.visible and audio != null and not bool(_witch_listening.get(key, false)):
			# Her hum is hung where she is, at her head.
			audio.witch(key, view.global_position + Vector3(0, 1.9, 0))
			heard[key] = true

	# The drones of a level left behind stop: a hidden node's player kept humming, from where
	# the witch last stood, on a level nobody here was on any more.
	if audio != null:
		audio.keep_witches(heard)


## Doors the local player has opened swing open on their hinge, for them: a door is open per player
## (Decision 1). Only the drawing turns; the body stays for everybody else.
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


## The level's events as they happen to the local player ([member LmPlayer.fired]): lamps flicker
## and die, a door slams, a witch looks back and is gone. A new level or a catch lights every lamp again.
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
	if audio == null or _covered():
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
