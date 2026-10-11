extends Node

const LmPaths := preload("lm_paths.gd")

## What the house sounds like, on the client: a heartbeat that quickens and loudens as she
## sees you, a low drone on every witch that you hear before you see her, and a click for
## each thing you take or open.
##
## [b]The meter is the whole game, and a meter that is only a bar is one you stop watching.[/b]
## The heartbeat is the same number, heard: nothing below 0.2, a slow thud past it, racing at
## the top. The drone is the other warning: a witch is heard through a wall before her fan is
## on the floor in front of you.
##
## [b]A catalogue of ids and stand-ins, which is the family's shape.[/b] dot-audio decides what
## is audible, how many at once and how far; [method sound_catalogue] is those decisions,
## naming paths under `audio/` that nobody has produced yet. None of dot-audio's stock voices
## is a heartbeat or a sustained hum (they are swept one-shots that decay to nothing), so
## [method stand_ins] bakes this game's own into the sink's bank under the id and the path a
## real file would have, and [DotAudioSinkGodot] consults the file first: dropping
## `audio/heartbeat.ogg` in switches that one id over with no code change.
##
## [b]Never on a server, and never deciding anything.[/b] Every call here comes from
## [LmClient], from what the world already says.

const CHANNEL := "lookatme.audio"

## Where the real files go when somebody produces them. Rebased, because a delivered pack
## mounts this game somewhere other than `res://`.
static var SOUND_DIR := LmPaths.rebase("res://audio")

## One thud of the lub-dub. Flat: it is your own heart.
const HEARTBEAT := &"heartbeat"
## A witch's drone, looped and hung where she is.
const WITCH_DRONE := &"witch_drone"
## Something taken, opened or used.
const CLICK := &"click"

## The most witches a level has (tools/build_levels.py: 1 + (n-1)/4, up to 6), and two spare
## for an owner's house that has more. Past that, the furthest ones go unheard.
const MAX_DRONES := 8

## The heartbeat, as it was before this used dot-audio: silent below this meter...
const HEART_FROM := 0.2
## ...and the gap between one lub-dub and the next, slow to racing.
const HEART_GAP_SLOW := 1.0
const HEART_GAP_FAST := 0.32
## The dub follows the lub this soon.
const HEART_DUB := 0.18
## Loudness in decibels across the meter.
const HEART_DB_QUIET := -18.0
const HEART_DB_LOUD := 0.0

var manager: DotAudioManager = null

## 0 to 1: how close she is to seeing you. Set by the client every frame.
var meter: float = 0.0

var _until_beat := 0.0
var _beat_second := false
## Witch key ("level|index") -> the handle of her drone.
var _drones: Dictionary = {}


static func ids() -> Array[StringName]:
	return [HEARTBEAT, WITCH_DRONE, CLICK]


static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	var heart := _def(HEARTBEAT, 2, 90)
	c.add(heart)

	var drone := _def(WITCH_DRONE, MAX_DRONES, 30)
	drone.kind = DotAudioDef.Kind.POSITIONAL_3D
	drone.looping = true
	# What the hand-made player had: heard from 18 m, full at 3, six decibels down.
	drone.unit_size = 3.0
	drone.max_distance = 18.0
	drone.gain_db = -6.0
	c.add(drone)

	var click := _def(CLICK, 2, 60)
	click.cooldown_ms = 60
	c.add(click)
	return c


static func _def(id: StringName, concurrent: int, priority: int) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	# Every sound on SFX: the effects slider is the one that means "the house", and the UI bus
	# defaults to 0.8, which would have made the click quieter than it always was.
	def.bus = &"SFX"
	def.max_concurrent = concurrent
	def.priority = priority
	return def


## The synthesised stand-in for every id, as this game sounded before it used dot-audio.
static func stand_ins() -> Dictionary:
	return {
		# A low thud: a sine falling 70 to 40 Hz in 160 ms, full volume, no grit.
		HEARTBEAT: DotAudioSynth.bake(70.0, 40.0, 0.16, 1.0, 0.0, 0.002),
		# The click: 880 Hz for 60 ms. dot-audio's CLICK voice is 35 ms, which is too short to
		# read as "that worked".
		CLICK: DotAudioSynth.bake(880.0, 880.0, 0.06, 0.4, 0.0, 0.002),
		WITCH_DRONE: _hum(),
	}


func setup() -> DotResult:
	manager = DotAudioManager.new()
	manager.name = "Audio"
	manager.catalogue = sound_catalogue()
	manager.mixer = DotAudioMixer.new()
	# Not published: a client and a server in one process, which the suites are, would
	# otherwise fight over one registry name, and nothing looks this up by name.
	manager.register_as_service = false
	# Six drones, a heart and a click is the busiest the house gets.
	manager.voices = 16
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("lookatme audio")

	# Only on a real sink: the manager has already decided whether there is a device, and a
	# headless process has nothing to bake for.
	var godot_sink := manager.sink as DotAudioSinkGodot

	if godot_sink != null:
		var made := stand_ins()

		for id: StringName in made:
			godot_sink.bank[id] = made[id]
			var def := manager.catalogue.find(id)

			if def != null and not def.path.is_empty():
				godot_sink.bank[def.path] = made[id]

		DotLog.info(CHANNEL, "no audio files; synthesised stand-ins are in use", {
			"ids": made.size(), "dir": SOUND_DIR,
		})

	return DotResult.success(null)


## Where the ears are, once a frame: the camera.
func listen_from(at: Vector3) -> void:
	if manager != null:
		manager.listener_position = at


func _process(delta: float) -> void:
	if manager == null:
		return

	if meter < HEART_FROM:
		_until_beat = 0.0
		return

	_until_beat -= delta

	if _until_beat > 0.0:
		return

	# A real heart's lub-dub: two beats close together, then the gap, which shortens with fear.
	var gap := lerpf(HEART_GAP_SLOW, HEART_GAP_FAST, clampf((meter - HEART_FROM) / (1.0 - HEART_FROM), 0.0, 1.0))
	_until_beat = HEART_DUB if not _beat_second else gap - HEART_DUB
	_beat_second = not _beat_second
	var volume := db_to_linear(lerpf(HEART_DB_QUIET, HEART_DB_LOUD, meter))
	var _beat := manager.play(HEARTBEAT, volume, 1.0 if _beat_second else 0.85)


## Plays catalogue [param id] as the server asked (`LmEvents.Kind.SOUND`). An id the catalogue
## does not have is refused, never guessed at.
func play(id: StringName) -> bool:
	return manager != null and manager.catalogue.has(id) and manager.play(id) != 0


## A click for something taken or opened.
func click() -> bool:
	return manager != null and manager.play(CLICK) != 0


## Keeps witch [param key]'s drone where she is, starting it when she comes within earshot.
##
## [b]Asked every frame, not once.[/b] The manager refuses a sound beyond its `max_distance`
## when it starts, so a drone asked for once, from the far end of the level, would never be
## heard; asking again costs one distance check until she is near enough.
func witch(key: String, at: Vector3) -> void:
	if manager == null:
		return

	var handle := int(_drones.get(key, 0))

	if handle != 0 and manager.is_playing(handle):
		manager.move(handle, at)
		return

	handle = manager.play_at(WITCH_DRONE, at)

	if handle != 0:
		_drones[key] = handle
	else:
		_drones.erase(key)


## Silences every drone not in [param keep] (the witches of the level the player is on).
func keep_witches(keep: Dictionary) -> void:
	if manager == null:
		return

	for key: String in _drones.keys():
		if not keep.has(key):
			manager.stop(int(_drones[key]))
			_drones.erase(key)


func forget_witches() -> void:
	keep_witches({})


## Witch keys whose drone is sounding now.
func droning() -> int:
	var n := 0

	if manager == null:
		return 0

	for handle: int in _drones.values():
		if manager.is_playing(handle):
			n += 1

	return n


## Two low sines a few hertz apart, beating against each other, with a slow breath on top: the
## sound of something standing in a dark room. Two seconds, which is whole cycles of every
## component, so it loops without a seam.
static func _hum() -> AudioStreamWAV:
	var rate := DotAudioSynth.RATE
	var n := rate * 2
	var data := PackedByteArray()
	data.resize(n * 2)

	for i in n:
		var t := float(i) / rate
		var breath := 0.6 + 0.4 * sin(TAU * 0.5 * t)
		var s := (sin(TAU * 55.0 * t) * 0.5 + sin(TAU * 58.0 * t) * 0.4 + sin(TAU * 110.0 * t) * 0.1) * breath * 0.5
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = rate
	wav.stereo = false
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = n
	return wav


func describe() -> Dictionary:
	return {
		"ids": ids().size(),
		"device": manager != null and manager.sink is DotAudioSinkGodot,
		"drones": droning(),
		"meter": meter,
	}
