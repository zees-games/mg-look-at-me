extends Node

const LmPaths := preload("lm_paths.gd")

## What the house sounds like, on the client: the house itself breathing under everything, its
## boards creaking somewhere you are not, your own steps, a witch's steps and the hum she carries,
## which you hear through a wall before you see her, a stab of strings the moment one sees you, a
## heartbeat that quickens as she keeps seeing you, and a shriek when she has you.
##
## [b]Every warning the game gives is a sound before it is a picture.[/b] The meter is the whole
## game, and a meter that is only a bar is one you stop watching: the heartbeat is the same
## number, heard (nothing below 0.2, a slow thud past it, racing at the top). The drone and her
## footfalls are the other warning: where she is, through walls, from 22 m. The stinger is the
## one moment that matters most, being seen at all, said once.
##
## [b]Files, generated and copied by tools/make_sounds.py[/b], which is their source: the
## ambience, drone, stinger, shriek and heartbeat are synthesised there (numpy and SoX, ours,
## CC0), the steps, creaks and doors are Kenney's (CC0; audio/CREDITS.md). Every file peaks at
## -2 dBFS; how loud each one plays is its `gain_db` here, measured together in a mix under xvfb
## (tools/audio_probe, `--record`). Until 2026-10-12 the house had three synthesised stand-ins
## (a thud, a beep and a hum) and was otherwise silent, which the first play test heard.
##
## [b]Never on a server, and never deciding anything.[/b] Every call here comes from
## [LmClient], from what the world already says.

const CHANNEL := "lookatme.audio"

## Where the files are. Rebased, because a delivered pack mounts this game somewhere other
## than `res://`.
static var SOUND_DIR := LmPaths.rebase("res://audio")

## The house breathing: a 40 s loop under everything, flat.
const AMBIENCE := &"ambience"
## One thud of the lub-dub. Flat: it is your own heart.
const HEARTBEAT := &"heartbeat"
## A witch's hum, looped and hung where she is.
const WITCH_DRONE := &"witch_drone"
## A witch's footfall, where she put her foot: a slow, heavy step.
const WITCH_STEP := &"witch_step"
## The player's own footfall.
const STEP := &"step"
## A board or a door somewhere in the dark, placed near the player but never on them.
const CREAK := &"creak"
## A door the player opened, where the door is.
const DOOR := &"door"
## Something taken or used: a latch.
const CLICK := &"click"
## A witch has started seeing you.
const STINGER := &"stinger"
## She has you.
const SCREAM := &"scream"
## A door slamming shut behind you (an event), where the door is.
const SLAM := &"slam"
## The lights of a room dying (an event): the buzz stutters with the lamps, then a pop.
const LIGHTS_OUT := &"lights_out"

## The most witches a level has (tools/build_levels.py: 2 + (n-1)/3, up to 12), and two spare
## for an owner's house that has more. Past that, the furthest ones go unheard.
const MAX_DRONES := 14

## The heartbeat: silent below this meter...
const HEART_FROM := 0.2
## ...and the gap between one lub-dub and the next, slow to racing.
const HEART_GAP_SLOW := 1.0
const HEART_GAP_FAST := 0.32
## The dub follows the lub this soon.
const HEART_DUB := 0.18
## Loudness in decibels across the meter.
const HEART_DB_QUIET := -20.0
const HEART_DB_LOUD := -5.0

## Seconds between creaks: somewhere in this range, rolled each time.
const CREAK_GAP_MIN := 6.0
const CREAK_GAP_MAX := 16.0
## How far from the ears a creak is put: close enough to hear, far enough to be somewhere else.
const CREAK_NEAR := 5.0
const CREAK_FAR := 13.0

var manager: DotAudioManager = null

## 0 to 1: how close she is to seeing you. Set by the client every frame.
var meter: float = 0.0

## Whether the house's own sounds (the ambience and the creaks) run. A suite that counts what
## played turns them off.
var house_sounds: bool = true

var _until_beat := 0.0
var _beat_second := false
var _until_creak := 4.0
var _ambience := 0
var _rng := RandomNumberGenerator.new()
## Witch key ("level|index") -> the handle of her drone.
var _drones: Dictionary = {}


static func ids() -> Array[StringName]:
	return [AMBIENCE, HEARTBEAT, WITCH_DRONE, WITCH_STEP, STEP, CREAK, DOOR, CLICK, STINGER, SCREAM, SLAM, LIGHTS_OUT]


static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	var bed := _def(AMBIENCE, 1, 20)
	bed.looping = true
	bed.gain_db = -13.0
	c.add(bed)

	c.add(_def(HEARTBEAT, 2, 90))

	var drone := _def(WITCH_DRONE, MAX_DRONES, 30)
	drone.kind = DotAudioDef.Kind.POSITIONAL_3D
	drone.looping = true
	# Heard from 18 m, full at 2.5: a witch in the next room is a sound before she is a shape.
	drone.unit_size = 2.5
	drone.max_distance = 18.0
	drone.gain_db = -9.0
	c.add(drone)

	var her_step := _def(WITCH_STEP, MAX_DRONES * 2, 40, _numbered("step", 5))
	her_step.kind = DotAudioDef.Kind.POSITIONAL_3D
	# Heavier and slower than yours: the same boards, pitched down.
	her_step.pitch_min = 0.62
	her_step.pitch_max = 0.72
	her_step.unit_size = 3.0
	her_step.max_distance = 22.0
	her_step.gain_db = -4.0
	c.add(her_step)

	var step := _def(STEP, 2, 35, _numbered("step", 5))
	step.pitch_min = 0.92
	step.pitch_max = 1.08
	step.gain_db = -17.0
	c.add(step)

	var creak := _def(CREAK, 2, 25, _numbered("creak", 4))
	creak.kind = DotAudioDef.Kind.POSITIONAL_3D
	creak.pitch_min = 0.75
	creak.pitch_max = 1.0
	creak.unit_size = 4.0
	creak.max_distance = 30.0
	creak.gain_db = -7.0
	c.add(creak)

	var door := _def(DOOR, 2, 55, _numbered("door", 2))
	door.kind = DotAudioDef.Kind.POSITIONAL_3D
	door.pitch_min = 0.8
	door.pitch_max = 0.95
	door.unit_size = 4.0
	door.max_distance = 25.0
	door.gain_db = -7.0
	c.add(door)

	var click := _def(CLICK, 2, 60)
	click.cooldown_ms = 60
	click.gain_db = -9.0
	c.add(click)

	var stinger := _def(STINGER, 1, 85)
	# Once per scare: two witches catching sight of you a frame apart are one fright.
	stinger.cooldown_ms = 4000
	stinger.gain_db = -9.0
	c.add(stinger)

	var scream := _def(SCREAM, 1, 100)
	scream.gain_db = -9.0
	c.add(scream)

	var slam := _def(SLAM, 1, 80)
	slam.kind = DotAudioDef.Kind.POSITIONAL_3D
	slam.unit_size = 6.0
	slam.max_distance = 40.0
	slam.gain_db = -5.0
	c.add(slam)

	var lights := _def(LIGHTS_OUT, 1, 70)
	lights.kind = DotAudioDef.Kind.POSITIONAL_3D
	lights.unit_size = 5.0
	lights.max_distance = 30.0
	lights.gain_db = -10.0
	c.add(lights)
	return c


static func _numbered(stem: String, count: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in count:
		out.append("%s/%s_%d.ogg" % [SOUND_DIR, stem, i])
	return out


static func _def(id: StringName, concurrent: int, priority: int, variants := PackedStringArray()) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.variants = variants
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)] if variants.is_empty() else variants[0]
	# Every sound on SFX: the effects slider is the one that means "the house".
	def.bus = &"SFX"
	def.max_concurrent = concurrent
	def.priority = priority
	return def


func setup() -> DotResult:
	manager = DotAudioManager.new()
	manager.name = "Audio"
	manager.catalogue = sound_catalogue()
	manager.mixer = DotAudioMixer.new()
	# Not published: a client and a server in one process, which the suites are, would
	# otherwise fight over one registry name, and nothing looks this up by name.
	manager.register_as_service = false
	# Six drones and their steps, a heart, a creak and a stinger is the busiest the house gets.
	manager.voices = 24
	# The whole house a little up, the quiet and the catches together (the range is the design
	# and a trim keeps it): tools/playthrough.sh read -18.9 and -19.8 LUFS on 2026-10-12, under
	# the family's -18..-16 band, with the catch held by the limiter. At +3: -17.3 and -17.4,
	# range 17 LU, true peak -1.9 dBTP.
	manager.loudness_trim_db = 3.0
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("lookatme audio")

	var missing := manager.catalogue.missing_files()

	if not missing.is_empty():
		# Silence for those, not an error: a pack still downloading plays what it has.
		DotLog.warn(CHANNEL, "sound files missing; those sounds are silent", {"missing": missing.size(), "first": missing[0]})

	_rng.seed = 20261012
	_limit_master()
	return DotResult.success(null)


## A hard limiter at -1 dB on the master bus, once: the moment of a catch is a shriek, a stinger
## and a racing heart at once, and the first recorded mix (2026-10-12) peaked at 0 dBFS there.
## The gains above keep the house well under it; this is what keeps the worst moment from
## clipping on a speaker whatever the player's sliders are.
static func _limit_master() -> void:
	for i in AudioServer.get_bus_effect_count(0):
		if AudioServer.get_bus_effect(0, i) is AudioEffectHardLimiter:
			return
	var limiter := AudioEffectHardLimiter.new()
	limiter.ceiling_db = -1.0
	AudioServer.add_bus_effect(0, limiter)


## Where the ears are, once a frame: the camera.
func listen_from(at: Vector3) -> void:
	if manager != null:
		manager.listener_position = at


func _process(delta: float) -> void:
	if manager == null:
		return

	_house(delta)

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


## The bed under everything, and now and then a board somewhere near.
func _house(delta: float) -> void:
	if not house_sounds:
		if _ambience != 0:
			manager.stop(_ambience)
			_ambience = 0
		return

	if _ambience == 0 or not manager.is_playing(_ambience):
		_ambience = manager.play(AMBIENCE)

	_until_creak -= delta

	if _until_creak > 0.0:
		return

	_until_creak = _rng.randf_range(CREAK_GAP_MIN, CREAK_GAP_MAX)
	var angle := _rng.randf() * TAU
	var away := _rng.randf_range(CREAK_NEAR, CREAK_FAR)
	var at := manager.listener_position + Vector3(sin(angle) * away, _rng.randf_range(-0.5, 1.5), cos(angle) * away)
	var _creaked := manager.play_at(CREAK, at)


## Plays catalogue [param id] as the server asked (`LmEvents.Kind.SOUND`). An id the catalogue
## does not have is refused, never guessed at.
func play(id: StringName) -> bool:
	return manager != null and manager.catalogue.has(id) and manager.play(id) != 0


## A latch for something taken or used.
func click() -> bool:
	return manager != null and manager.play(CLICK) != 0


## A door swinging open at [param at].
func door(at: Vector3) -> bool:
	return manager != null and manager.play_at(DOOR, at) != 0


## One of the player's own footfalls; quieter crouched.
func step(crouched: bool) -> bool:
	return manager != null and manager.play(STEP, 0.45 if crouched else 1.0) != 0


## One of a witch's footfalls, at her feet.
func witch_step(at: Vector3) -> bool:
	return manager != null and manager.play_at(WITCH_STEP, at) != 0


## A witch has just started seeing you.
func stinger() -> bool:
	return manager != null and manager.play(STINGER) != 0


## A door slamming at [param at].
func slam(at: Vector3) -> bool:
	return manager != null and manager.play_at(SLAM, at) != 0


## A room's lights dying, from its middle at [param at].
func lights_out(at: Vector3) -> bool:
	return manager != null and manager.play_at(LIGHTS_OUT, at) != 0


## She has you.
func scream() -> bool:
	return manager != null and manager.play(SCREAM) != 0


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


func describe() -> Dictionary:
	return {
		"ids": ids().size(),
		"device": manager != null and manager.sink is DotAudioSinkGodot,
		"drones": droning(),
		"ambience": _ambience != 0,
		"meter": meter,
	}
