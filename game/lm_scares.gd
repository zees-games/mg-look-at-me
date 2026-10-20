extends RefCounted

## What frightens the player beyond the witches: sanity scares, demons, and a whisper to look
## behind you. Pure scheduling and geometry, with no nodes and no clock of its own: [method tick]
## is told the time that passed and where the player is and looks, and answers with events the
## client draws and plays ([LmScareView]). That split is why a suite can run minutes of fright in
## a frame, and why the same seed gives the same night.
##
## [b]Why the client and not the server.[/b] Where a face flashes is nobody else's business and
## must not wait a round trip, so the drawing and the schedule are the client's. The one thing
## the rules care about is the meter, so an event that moves it carries a "spike", the client
## asks the server for it (`LmGame.spook`), and the server applies it capped and rate limited.
## A client that never asks simply is not frightened, which costs nobody else anything.
##
## [b]Deterministic.[/b] Every draw comes from one generator seeded from the house seed, the
## level and the player ([method reseed]); a tick is only a function of that and what it is told.
##
## The tunables are all [LmConfig]'s (`lm_*` cvars).

const LmConfig := preload("lm_config.gd")

const SCARE := &"scare"
const WHISPER := &"whisper"
const DEMON_SHOWS := &"demon_shows"
const DEMON_JUMPS := &"demon_jumps"
const DEMON_GONE := &"demon_gone"
const BEHIND_WHISPER := &"behind_whisper"
const BEHIND_SCARE := &"behind_scare"

## What a sanity scare shows. Picked from the generator, so a night's mix is the seed's.
const STYLES: Array[StringName] = [&"witch", &"demon", &"flash"]

var config: LmConfig = null
var rng := RandomNumberGenerator.new()

var level: int = -1
## Whether a witch has seen the player on this level (the meter passed `demon_sight_meter`).
var sighted := false

## Progress to the next sanity scare, 0 to `_need`; it fills at 1 / interval a second, and the
## interval is the meter's, so it is read live.
var charge := 0.0
var _need := 1.0
## Seconds since anything frightened the player; the cooldown is measured on it.
var since_event := 1000.0

## Seconds until the next demon shows, or -1 while none is due (not sighted yet).
var _until_demon := -1.0
var _until_behind := -1.0
var _next_id := 1

## Each demon: {"id", "at" (feet), "age", "looked", "whisper" (seconds to its next)}.
var demons: Array[Dictionary] = []
## An open look-behind: {"left", "back" (the unit vector pointing where the whisper came from),
## "at"}, or empty.
var behind: Dictionary = {}

## Everything told, newest last; a suite reads it, and the client takes it with [method tick].
var told: Array[Dictionary] = []


func _init(p_config: LmConfig = null) -> void:
	config = p_config if p_config != null else LmConfig.new()
	reseed(0, 0, 0)


## A new night on [param p_level]: nothing remembered, the generator back to its start.
func reseed(seed_value: int, p_level: int, who: int) -> void:
	level = p_level
	rng.seed = hash([seed_value, p_level, who, 0x5ca7e])
	sighted = false
	charge = 0.0
	_need = rng.randf_range(0.7, 1.3)
	since_event = 1000.0
	_until_demon = -1.0
	_until_behind = _roll_behind()
	demons.clear()
	behind = {}


## Rest: whatever was hunting the player, and the build-up to the next scare, is gone. The night's
## seed and level are kept, so only this one night's progress is lost.
func rest() -> void:
	charge = 0.0
	since_event = 1000.0
	demons.clear()
	behind = {}


## Seconds a sanity scare takes to come at [param meter] (0 to 1): the long wait at an empty
## meter, the short one at a full one. Static, so a check can ask it without a night.
static func interval_for(cfg: LmConfig, meter: float) -> float:
	return maxf(lerpf(cfg.scare_interval_max, cfg.scare_interval_min, clampf(meter, 0.0, 1.0)), 0.5)


func _roll_behind() -> float:
	return rng.randf_range(config.look_behind_min, config.look_behind_max)


## Advances [param delta] seconds. [param view]: "meter", "level", "eye" and "feet" (Vector3),
## "forward" (the view's direction), "caught" (bool), and optionally "clear", a
## Callable(from, direction, max_distance) -> float of how far that way is open, so a demon is
## never put in a wall. Returns this tick's events (also appended to [member told]).
func tick(delta: float, view: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var meter := float(view.get("meter", 0.0))
	var number := int(view.get("level", level))

	if number != level:
		# A new level is a new night, from the same seed: leaving a level forgets its demons.
		reseed(config.seed_value, number, int(view.get("who", 0)))

	if bool(view.get("caught", false)):
		# Whatever was hunting you is gone when you are put back.
		demons.clear()
		behind = {}
		charge = 0.0
		return events

	var eye: Vector3 = view.get("eye", Vector3.ZERO)
	var forward := _flat(view.get("forward", Vector3.FORWARD))
	since_event += delta

	if not sighted and meter >= config.demon_sight_meter and meter > 0.0:
		sighted = true
		_until_demon = _roll_demon(meter)

	_scares(delta, meter, events)
	_demons(delta, meter, eye, forward, view, events)
	_look_behind(delta, meter, eye, forward, view, events)
	told.append_array(events)
	return events


func _scares(delta: float, meter: float, events: Array[Dictionary]) -> void:
	if not config.scares_enabled:
		return

	charge += delta / interval_for(config, meter)

	if charge < _need or since_event < config.scare_cooldown:
		return

	charge = 0.0
	_need = rng.randf_range(0.7, 1.3)
	since_event = 0.0
	events.append({"kind": SCARE, "style": STYLES[rng.randi() % STYLES.size()], "side": 1.0 if rng.randf() < 0.5 else -1.0,
		"seconds": config.scare_seconds, "meter": meter})


func _roll_demon(meter: float) -> float:
	# The meter halves the wait at its worst: a player a witch is on is the one to haunt.
	return rng.randf_range(config.demon_spawn_min, config.demon_spawn_max) * (1.0 - 0.5 * clampf(meter, 0.0, 1.0))


func _demons(delta: float, meter: float, eye: Vector3, forward: Vector3, view: Dictionary, events: Array[Dictionary]) -> void:
	if not config.demons_enabled:
		demons.clear()
		return

	var keep: Array[Dictionary] = []

	for demon in demons:
		demon["age"] = float(demon["age"]) + delta
		var at: Vector3 = demon["at"]
		var to := at - eye
		to.y = 0.0

		if to.length() <= config.demon_trigger_distance:
			since_event = 0.0
			charge = 0.0
			events.append({"kind": DEMON_JUMPS, "id": demon["id"], "at": at, "spike": config.demon_meter_spike})
			continue

		# Looking at it dead on, long enough, and it is gone: the thing in the corner of the eye
		# is only there while you are not looking.
		var looking := to.length() > 0.01 and rad_to_deg(forward.angle_to(to.normalized())) <= config.demon_look_degrees
		demon["looked"] = float(demon["looked"]) + delta if looking else maxf(float(demon["looked"]) - delta, 0.0)

		if float(demon["looked"]) >= config.demon_look_seconds:
			events.append({"kind": DEMON_GONE, "id": demon["id"], "why": "seen"})
			continue

		if float(demon["age"]) >= config.demon_lifetime:
			events.append({"kind": DEMON_GONE, "id": demon["id"], "why": "faded"})
			continue

		demon["whisper"] = float(demon["whisper"]) - delta

		if float(demon["whisper"]) <= 0.0:
			demon["whisper"] = config.demon_whisper_gap * rng.randf_range(0.6, 1.4)
			events.append({"kind": WHISPER, "id": demon["id"], "at": at + Vector3(0, 1.4, 0), "variant": rng.randi() % 3})

		keep.append(demon)

	demons = keep

	if not sighted:
		return

	_until_demon -= delta

	if _until_demon > 0.0 or demons.size() >= config.demon_max:
		return

	var at := _corner(eye, forward, view)

	if at == Vector3.INF:
		# No open corner right now (a wall at the elbow): try again shortly, drawing nothing.
		_until_demon = 1.5
		return

	_until_demon = _roll_demon(meter)
	var demon := {"id": _next_id, "at": at, "age": 0.0, "looked": 0.0, "whisper": config.demon_whisper_gap * rng.randf_range(0.6, 1.4)}
	_next_id += 1
	demons.append(demon)
	events.append({"kind": DEMON_SHOWS, "id": demon["id"], "at": at})
	events.append({"kind": WHISPER, "id": demon["id"], "at": at + Vector3(0, 1.4, 0), "variant": rng.randi() % 3})


## A spot in the corner of the view, on the floor: this far, this many degrees off to a random
## side, shortened to what is open. [constant Vector3.INF] when neither side has room.
func _corner(eye: Vector3, forward: Vector3, view: Dictionary) -> Vector3:
	var side := 1.0 if rng.randf() < 0.5 else -1.0
	var angle := deg_to_rad(rng.randf_range(config.demon_corner_min, config.demon_corner_max))
	var distance := rng.randf_range(config.demon_distance_min, config.demon_distance_max)
	var clear: Callable = view.get("clear", Callable())
	var feet: Vector3 = view.get("feet", eye)

	for attempt in 2:
		var dir := forward.rotated(Vector3.UP, side * angle)
		var room := distance

		if clear.is_valid():
			room = minf(distance, float(clear.call(eye, dir, distance + 0.5)) - 0.5)

		# Closer than this and it is on top of you, not in the corner of your eye.
		if room >= maxf(config.demon_trigger_distance + 1.0, 3.0):
			return Vector3(eye.x + dir.x * room, feet.y, eye.z + dir.z * room)

		side = -side

	return Vector3.INF


func _look_behind(delta: float, meter: float, eye: Vector3, forward: Vector3, view: Dictionary, events: Array[Dictionary]) -> void:
	if not config.look_behind_enabled:
		behind = {}
		return

	if not behind.is_empty():
		behind["left"] = float(behind["left"]) - delta
		var back: Vector3 = behind["back"]

		if rad_to_deg(forward.angle_to(back)) <= config.look_behind_degrees:
			# Turned round: it is there, where you now look, close.
			var distance := 2.4
			var clear: Callable = view.get("clear", Callable())

			if clear.is_valid():
				distance = clampf(float(clear.call(eye, back, distance + 0.5)) - 0.5, 1.0, distance)

			var feet: Vector3 = view.get("feet", eye)
			var at := Vector3(eye.x + back.x * distance, feet.y, eye.z + back.z * distance)
			events.append({"kind": BEHIND_SCARE, "at": at, "spike": config.look_behind_spike, "seconds": config.scare_seconds})
			since_event = 0.0
			charge = 0.0
			behind = {}
			_until_behind = _roll_behind()
		elif float(behind["left"]) <= 0.0:
			behind = {}
			_until_behind = _roll_behind()

		return

	# Shorter at a high meter: three times as fast at a full one.
	_until_behind -= delta * (1.0 + 2.0 * clampf(meter, 0.0, 1.0))

	if _until_behind > 0.0 or since_event < config.scare_cooldown:
		return

	var back := -forward
	behind = {"left": config.look_behind_window, "back": back, "at": eye + back * 2.0}
	events.append({"kind": BEHIND_WHISPER, "at": eye + back * 1.6 + Vector3(0, 0.1, 0), "window": config.look_behind_window})


static func _flat(v: Vector3) -> Vector3:
	v.y = 0.0
	return v.normalized() if v.length_squared() > 0.0001 else Vector3.FORWARD


func describe() -> Dictionary:
	return {"level": level, "sighted": sighted, "charge": "%.2f/%.2f" % [charge, _need], "demons": demons.size(),
		"behind": not behind.is_empty(), "told": told.size()}
