extends "lm_game_senses.gd"

## What a witch sees and hears: [method _watch] and the senses and modes it runs.

## [method _watch]'s witches (every witch's [method _listen_witch], then her [method exposure]) are
## run by gs-sim's `GSSimWitches` when the library has it, to the script's bit
## (`headless_native_witches`); off, or with no library (the web), the script runs them.
static var native_witches := true
## Runs the script beside every native watch and counts the watches compared and any that differ;
## the script's answer is the one kept. For a suite.
static var witch_verify := false
static var witch_checked := 0
static var witch_differ := 0
## Floats per witch in `GSSimWitches.watch`'s states and answer.
const WITCH_STATE_F := 17
const WITCH_OUT_F := 19

## The `GSSimWitches` the witches run in; null until the first native watch.
var _witches: RefCounted = null
## Level instance id -> the level, for every level registered with [member _witches].
var _witch_levels: Dictionary = {}


## Every witch on [param player]'s level looks for them, and the meter moves.
func _watch(player: LmPlayer, seconds: float, delta: float) -> void:
	var level := level_of(player)

	if level == null:
		return

	# Behind its client's cover a player sees nothing, so a witch's look must not fill its meter.
	# The one place a catch starts; the rest of the tick (doors, exits) is not a harm. A catch
	# already in progress is stepped before this and is not interrupted.
	if not can_be_harmed(player.player_key):
		player.seen_by = 0
		return

	var best_rate := 0.0
	var seen := 0
	var rates: Variant = _watch_native(player, level, seconds, delta) if native_witches else null

	if rates == null:
		rates = _watch_script(player, level, seconds, delta)

	for i in level.witches.size():
		var rate := float(rates[i])

		if rate > 0.0:
			seen += 1
			best_rate = maxf(best_rate, rate)

	player.seen_by = seen

	if seen > 0:
		# Two witches watching is worse than one, but not twice as bad: the nearest is most of it.
		player.meter += best_rate * (1.0 + 0.35 * float(seen - 1)) * delta
		player.unseen_for = 0.0
	else:
		player.unseen_for += delta

		if player.unseen_for >= config.decay_delay:
			player.meter = maxf(player.meter - config.decay_rate * delta, 0.0)

	if player.meter >= 1.0:
		player.meter = 1.0
		player.caught_left = maxf(config.caught_seconds, 0.01)
		caught.emit(player.player_key)
		said.emit(player.player_key, "SHE SEES YOU")


## The witches in script: [method _listen], then each witch's [method exposure].
func _watch_script(player: LmPlayer, level: LmLevel, seconds: float, delta: float) -> PackedFloat64Array:
	var rates := PackedFloat64Array()
	_listen(player, level, seconds, delta)

	for i in level.witches.size():
		rates.append(exposure(player, level, i, seconds))

	return rates


## The witches in gs-sim: the same gaze, rates and `listened` as [method _watch_script]. Null when
## the library has no witches, and the script runs. With [member witch_verify] the script runs
## too, from the same start, and its answer is kept.
func _watch_native(player: LmPlayer, level: LmLevel, seconds: float, delta: float) -> Variant:
	if _witches == null:
		if not GSSim.has(&"witches"):
			return null

		_witches = ClassDB.instantiate(&"GSSimWitches")

	var key := level.get_instance_id()

	if not _witch_levels.has(key):
		_register_witches(level, key)

	var before := {}

	if witch_verify:
		before = {"gaze": player.gaze.duplicate(true), "noise": player.noise_left, "voice": player.voice_left}

	var rates: Variant = _watch_call(player, level, key, seconds, delta, not witch_verify)

	if not witch_verify or rates == null:
		return rates

	var native := {"gaze": player.gaze.duplicate(true), "noise": player.noise_left, "voice": player.voice_left, "rates": rates}
	player.gaze = before["gaze"]
	player.noise_left = before["noise"]
	player.voice_left = before["voice"]
	var script := _watch_script(player, level, seconds, delta)
	witch_checked += 1

	if native != {"gaze": player.gaze, "noise": player.noise_left, "voice": player.voice_left, "rates": script}:
		witch_differ += 1

	return script


## One `GSSimWitches.watch`: packs [param player]'s gaze, unpacks the answer into it and returns
## the rates; null (nothing changed) when the call is refused.
func _watch_call(player: LmPlayer, level: LmLevel, key: int, seconds: float, delta: float, emit: bool) -> Variant:
	var count := level.witches.size()
	var noise_left := player.noise_left
	var voice_left := player.voice_left
	player.noise_left = maxf(player.noise_left - delta, 0.0)
	player.voice_left = maxf(player.voice_left - delta, 0.0)
	var states := PackedFloat64Array()
	states.resize(count * WITCH_STATE_F)

	for i in count:
		var state: Dictionary = player.gaze.get(i, {})

		if state.is_empty():
			continue

		var o := i * WITCH_STATE_F
		var at: Vector3 = state["at"]
		var pos: Vector3 = state["pos"]
		states[o] = 1.0
		states[o + 1] = float(state["head"])
		states[o + 2] = float(state["notice"])
		states[o + 3] = 1.0 if bool(state["alert"]) else 0.0
		states[o + 4] = float(state["hold"])
		states[o + 5] = at.x
		states[o + 6] = at.y
		states[o + 7] = at.z
		states[o + 8] = float(state["mode"])
		states[o + 9] = float(state["t"])
		states[o + 10] = float(state["heard"])
		states[o + 11] = float(state["stall"])
		states[o + 12] = float(state["cool"])
		states[o + 13] = pos.x
		states[o + 14] = pos.y
		states[o + 15] = pos.z
		states[o + 16] = float(state["face"])

	var exclude: Array[RID] = [player.get_rid()]

	for door_id: String in player.opened:
		var rid := level.door_rid(door_id)

		if rid.is_valid():
			exclude.append(rid)

	var who := PackedFloat64Array([noise_radius(player), player.horizontal_speed(), player.caught_left,
		1.0 if player.flashlight else 0.0, 1.0 if player.is_crouching() else 0.0, float(player.level)])
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	var out: PackedFloat64Array = _witches.call(&"watch", key, level.position, _witch_config(), who,
		player.eye_position(), states, seconds, delta, space, exclude)

	if out.size() != count * WITCH_OUT_F + 1:
		player.noise_left = noise_left
		player.voice_left = voice_left
		return null

	var rates := PackedFloat64Array()
	rates.resize(count)

	for i in count:
		var o := i * WITCH_OUT_F
		var state: Dictionary = player.gaze.get(i, {})
		state["head"] = out[o + 1]
		state["notice"] = out[o + 2]
		state["alert"] = out[o + 3] != 0.0
		state["hold"] = out[o + 4]
		state["at"] = Vector3(out[o + 5], out[o + 6], out[o + 7])
		state["mode"] = int(out[o + 8])
		state["t"] = out[o + 9]
		state["heard"] = out[o + 10]
		state["stall"] = out[o + 11]
		state["cool"] = out[o + 12]
		state["pos"] = Vector3(out[o + 13], out[o + 14], out[o + 15])
		state["face"] = out[o + 16]
		player.gaze[i] = state
		rates[i] = out[o + 17]

		if emit and out[o + 18] != 0.0:
			listened.emit(player.player_key, i)

	return rates


## [member config] in `GSSimWitches.watch`'s order.
func _witch_config() -> PackedFloat64Array:
	return PackedFloat64Array([
		config.witch_speed_scale, 1.0 if config.witch_head_sweep else 0.0, config.witch_door_seconds,
		config.witch_sight_scale, config.flashlight_sight, config.witch_cone_scale, config.exposure_rate,
		config.opening_ease, float(config.opening_levels), config.flashlight_exposure, config.crouch_exposure,
		config.still_exposure, config.witch_listen_hearing, config.witch_light_range, config.witch_hear_walls,
		config.witch_reaction_seconds, config.witch_alert_seconds, 1.0 if config.witch_listens else 0.0,
		config.witch_listen_seconds, config.witch_listen_confirm, config.witch_listen_cooldown,
		config.witch_turn_delay, config.witch_chase_seconds, config.witch_turn_rate, config.witch_chase_speed,
	])


## Gives [member _witches] [param level]'s witch loops and door bodies (a door by its slot), and
## forgets the levels since freed.
func _register_witches(level: LmLevel, key: int) -> void:
	for old: int in _witch_levels.keys():
		if not is_instance_id_valid(old):
			_witches.call(&"remove_level", old)
			_witch_levels.erase(old)

	_witches.call(&"clear_level", key)
	var slots: Array[String] = []
	var rids: Array[RID] = []

	for loop: Dictionary in level.witches:
		var doors := PackedInt32Array()

		for door_id: String in loop["door_ids"]:
			if door_id == "":
				doors.append(-1)
				continue

			var slot := slots.find(door_id)

			if slot < 0:
				slot = slots.size()
				slots.append(door_id)
				rids.append(level.door_rid(door_id))

			doors.append(slot)

		_witches.call(&"add_witch", key, loop["points"], loop["lengths"], doors, float(loop["total"]),
			float(loop["speed"]), float(loop["sight"]), float(loop["cone"]))

	_witches.call(&"set_doors", key, rids)
	_witch_levels[key] = true


## How fast witch [param index] fills [param player]'s meter, per second, or 0 when she cannot
## see them. Public so a suite can ask the question the tick asks.
func exposure(player: LmPlayer, level: LmLevel, index: int, seconds: float) -> float:
	var loop: Dictionary = level.witches[index]
	var pose := witch_pose_for(player, level, index, seconds)
	var eye: Vector3 = level.position + (pose["at"] as Vector3) + Vector3(0, 2.0, 0)
	var target := player.eye_position()
	var to := target - eye
	var sight := float(loop["sight"]) * config.witch_sight_scale * (config.flashlight_sight if player.flashlight else 1.0)
	var distance := to.length()

	if distance > sight or distance < 0.01:
		return 0.0

	var facing := float(pose["facing"]) + float(pose["head"])
	var forward := Vector3(-sin(facing), 0.0, -cos(facing))
	var flat := Vector3(to.x, 0.0, to.z).normalized()
	var half_cone := deg_to_rad(float(loop["cone"]) * config.witch_cone_scale * 0.5)

	if forward.dot(flat) < cos(half_cone):
		return 0.0

	if not _clear_between(eye, target, player, str(pose["door"]) if float(pose["open"]) > 0.5 else ""):
		return 0.0

	var rate := config.exposure_rate * clampf(1.0 - distance / sight, 0.15, 1.0)
	rate *= lerpf(config.opening_ease, 1.0, clampf(float(player.level - 1) / float(maxi(config.opening_levels, 1)), 0.0, 1.0))

	if player.flashlight:
		rate *= config.flashlight_exposure
	if player.is_crouching():
		rate *= config.crouch_exposure
	if player.horizontal_speed() < 0.3:
		rate *= config.still_exposure

	return rate


## Witch [param index]'s pose for [param player]: the clock's, with her head where she has turned
## it to look at a sound or the light ([method _listen]) when she has.
func witch_pose_for(player: LmPlayer, level: LmLevel, index: int, seconds: float) -> Dictionary:
	return _pose_of(level, index, seconds, player.gaze.get(index, {}))


## The clock's pose, held back by the seconds she has stood listening or run (`stall`: her walk
## is still a function of time, only a time that did not pass while she stood), her head where
## she has turned it, and where she is while she runs at a sound or walks back to her path.
func _pose_of(level: LmLevel, index: int, seconds: float, state: Dictionary) -> Dictionary:
	var stall := float(state.get("stall", 0.0))
	var pose := level.witch_pose(index, maxf(seconds - stall, 0.0), config.witch_speed_scale, config.witch_head_sweep, config.witch_door_seconds)
	pose["listening"] = false
	pose["running"] = false

	if state.is_empty():
		return pose

	pose["head"] = float(state["head"])
	var mode := int(state["mode"])
	pose["listening"] = mode == MODE_LISTEN
	# Facing a sound, not walking: both the listen and the turn stand still.
	pose["still"] = mode == MODE_LISTEN or mode == MODE_TURN

	if mode == MODE_CHASE or mode == MODE_BACK:
		pose["at"] = state["pos"]
		pose["facing"] = float(state["face"])
		pose["running"] = mode == MODE_CHASE
		pose["door"] = ""
		pose["open"] = 0.0

	return pose


## Somebody's voice went out: a witch near them hears it for a moment. Server only, and cheap:
## one float, read by the noise the witches already perceive.
func hear_voice(key: StringName) -> void:
	var talker: LmPlayer = players.get(key, null)

	if talker != null and config.witch_hear_voice:
		talker.voice_left = config.witch_voice_seconds


## How far off a witch hears [param player] right now, in metres: footsteps scaled by speed,
## less crouched, nothing standing still, and a door or a use louder for a moment.
func noise_radius(player: LmPlayer) -> float:
	var speed := player.horizontal_speed()
	var radius := 0.0

	if speed > 0.3:
		radius = config.witch_hear_range * clampf(speed / maxf(config.run_speed, 0.1), 0.0, 1.0)

		if player.is_crouching():
			radius *= config.crouch_exposure * 0.6

	if player.noise_left > 0.0:
		radius = maxf(radius, config.witch_hear_range * config.witch_noise_boost)

	if player.voice_left > 0.0 and config.witch_hear_voice:
		radius = maxf(radius, config.witch_hear_range)

	return radius


## Every witch perceives the player's noise and lit flashlight and reacts: after
## `witch_reaction_seconds` she turns her head toward it, holds for `witch_alert_seconds`, then
## sweeps again. She never leaves her walk (Decision 2); being seen is still the cone's question.
func _listen(player: LmPlayer, level: LmLevel, seconds: float, delta: float) -> void:
	player.noise_left = maxf(player.noise_left - delta, 0.0)
	player.voice_left = maxf(player.voice_left - delta, 0.0)
	var noise := noise_radius(player)
	var target := player.eye_position()

	for i in level.witches.size():
		var state: Dictionary = player.gaze.get(i, {})

		if state.is_empty():
			var first := level.witch_pose(i, seconds, config.witch_speed_scale, config.witch_head_sweep, config.witch_door_seconds)
			state = {"head": float(first["head"]), "notice": 0.0, "alert": false, "hold": 0.0, "at": target,
				"mode": MODE_WALK, "t": 0.0, "heard": 0.0, "stall": 0.0, "cool": 0.0, "pos": Vector3.ZERO, "face": 0.0}

		_listen_witch(player, level, i, state, seconds, delta, noise, target)


func _listen_witch(player: LmPlayer, level: LmLevel, i: int, state: Dictionary, seconds: float, delta: float, noise: float, target: Vector3) -> void:
	var pose := _pose_of(level, i, seconds, state)
	var mode := int(state["mode"])
	var eye: Vector3 = level.position + (pose["at"] as Vector3) + Vector3(0, 2.0, 0)
	var to := target - eye
	var distance := to.length()
	var open_door := str(pose["door"]) if float(pose["open"]) > 0.5 else ""
	var live := distance > 0.01 and player.caught_left <= 0.0
	var sensed := _sense(player, level, i, state, pose, mode, noise, target, eye, open_door, live)
	var heard: bool = sensed[0]
	var light: bool = sensed[1]
	var glimpse: bool = sensed[2]
	state["cool"] = maxf(float(state["cool"]) - delta, 0.0)
	var wanted := float(pose["head"])

	match mode:
		MODE_WALK:
			_mode_walk(player, i, state, heard, light, glimpse, delta, target)
		MODE_LISTEN:
			wanted = _mode_listen(state, heard, delta, target)
		MODE_TURN:
			wanted = _mode_turn(player, state, pose, heard, live, eye, open_door, delta, target, wanted)
		MODE_CHASE:
			wanted = _mode_chase(player, level, i, state, heard, light, delta, target)
		MODE_BACK:
			wanted = _mode_back(level, i, state, seconds, delta)

	if bool(state["alert"]) and int(state["mode"]) != MODE_CHASE and int(state["mode"]) != MODE_BACK:
		var look: Vector3 = (state["at"] as Vector3) - eye
		var heading := atan2(-look.x, -look.z) - float(pose["facing"])
		wanted = clampf(wrapf(heading, -PI, PI), -MAX_HEAD, MAX_HEAD)

	var turn_step := deg_to_rad(config.witch_turn_rate) * delta
	var head := float(state["head"])
	state["head"] = head + clampf(wrapf(wanted - head, -PI, PI), -turn_step, turn_step)
	player.gaze[i] = state


func _sense(player: LmPlayer, level: LmLevel, i: int, state: Dictionary, pose: Dictionary, mode: int, noise: float, target: Vector3, eye: Vector3, open_door: String, live: bool) -> Array:
	var to := target - eye
	var distance := to.length()
	var heard := false
	var light := false
	var glimpse := false
	var clear := false
	# Sharper ears while she stands listening, and only then.
	var ears := noise * (config.witch_listen_hearing if mode == MODE_LISTEN else 1.0)

	if live:
		var facing := float(pose["facing"]) + float(state["head"])
		var forward := Vector3(-sin(facing), 0.0, -cos(facing))
		var half_cone := deg_to_rad(float((level.witches[i] as Dictionary)["cone"]) * config.witch_cone_scale * 0.5)
		var flat := Vector3(to.x, 0.0, to.z).normalized()
		var in_cone := forward.dot(flat) >= cos(half_cone)
		var reach := maxf(ears, config.witch_light_range if player.flashlight else 0.0)

		if distance <= maxf(reach, float((level.witches[i] as Dictionary)["sight"]) * config.witch_sight_scale):
			clear = _clear_between(eye, target, player, open_door)

		# A sound goes round and through walls, quieter; a beam is seen only in the open, by a
		# witch looking roughly its way; the edge of her view is a movement or a light seen
		# from the corner of her eye.
		heard = ears > 0.0 and distance <= ears * (1.0 if clear else config.witch_hear_walls)
		light = clear and player.flashlight and distance <= config.witch_light_range and in_cone

		if clear and not in_cone and (player.horizontal_speed() > 0.3 or player.flashlight):
			var edge := deg_to_rad(float((level.witches[i] as Dictionary)["cone"]) * config.witch_cone_scale * 0.5 + 35.0)
			glimpse = forward.dot(flat) >= cos(edge) and distance <= float((level.witches[i] as Dictionary)["sight"]) * config.witch_sight_scale
	return [heard, light, glimpse]


func _mode_walk(player: LmPlayer, i: int, state: Dictionary, heard: bool, light: bool, glimpse: bool, delta: float, target: Vector3) -> void:
	if light:
		state["notice"] = float(state["notice"]) + delta
		state["at"] = target

		if float(state["notice"]) >= config.witch_reaction_seconds:
			state["alert"] = true
			state["hold"] = config.witch_alert_seconds
	elif (heard or glimpse) and config.witch_listens and float(state["cool"]) <= 0.0:
		state["notice"] = float(state["notice"]) + delta
		state["at"] = target

		if float(state["notice"]) >= config.witch_reaction_seconds:
			state["notice"] = 0.0
			state["mode"] = MODE_LISTEN
			state["t"] = config.witch_listen_seconds
			state["heard"] = 0.0
			state["alert"] = false
			listened.emit(player.player_key, i)
	elif heard and not config.witch_listens:
		state["notice"] = float(state["notice"]) + delta
		state["at"] = target

		if float(state["notice"]) >= config.witch_reaction_seconds:
			state["alert"] = true
			state["hold"] = config.witch_alert_seconds
	else:
		state["notice"] = maxf(float(state["notice"]) - delta, 0.0)

	if bool(state["alert"]) and not light and not heard:
		state["hold"] = float(state["hold"]) - delta

		if float(state["hold"]) <= 0.0:
			state["alert"] = false


func _mode_listen(state: Dictionary, heard: bool, delta: float, target: Vector3) -> float:
	var wanted := 0.0
	# The clock stops: she stands where she is.
	state["stall"] = float(state["stall"]) + delta
	state["t"] = float(state["t"]) - delta
	wanted = float(state["head"])

	if heard:
		state["heard"] = float(state["heard"]) + delta
		state["at"] = target
	else:
		state["heard"] = maxf(float(state["heard"]) - delta * 0.5, 0.0)

	if float(state["heard"]) >= config.witch_listen_confirm:
		state["mode"] = MODE_TURN
		state["t"] = config.witch_turn_delay
		state["alert"] = true
		state["hold"] = config.witch_alert_seconds
	elif float(state["t"]) <= 0.0:
		state["mode"] = MODE_WALK
		state["cool"] = config.witch_listen_cooldown
		state["notice"] = 0.0
	return wanted


func _mode_turn(player: LmPlayer, state: Dictionary, pose: Dictionary, heard: bool, live: bool, eye: Vector3, open_door: String, delta: float, target: Vector3, wanted: float) -> float:
	state["stall"] = float(state["stall"]) + delta
	state["t"] = float(state["t"]) - delta

	if heard:
		state["at"] = target

	# She looks back first, her head all the way round, then runs.
	var wanted_turn := wrapf(atan2(-((state["at"] as Vector3) - eye).x, -((state["at"] as Vector3) - eye).z) - float(pose["facing"]), -PI, PI)
	var looked := absf(wrapf(clampf(wanted_turn, -MAX_HEAD, MAX_HEAD) - float(state["head"]), -PI, PI)) < 0.35

	if float(state["t"]) <= 0.0 and (looked or float(state["t"]) < -3.0):
		# Run only along a clear line; round a wall she looks and walks on.
		if live and _clear_between(eye, (state["at"] as Vector3), player, open_door):
			state["mode"] = MODE_CHASE
			state["t"] = config.witch_chase_seconds
			state["pos"] = pose["at"]
			var look: Vector3 = (state["at"] as Vector3) - eye
			state["face"] = float(pose["facing"]) + float(state["head"])
			state["head"] = 0.0
			wanted = 0.0
		else:
			state["mode"] = MODE_WALK
			state["cool"] = config.witch_listen_cooldown
	return wanted


func _mode_chase(player: LmPlayer, level: LmLevel, i: int, state: Dictionary, heard: bool, light: bool, delta: float, target: Vector3) -> float:
	var wanted := 0.0
	state["stall"] = float(state["stall"]) + delta
	state["t"] = float(state["t"]) - delta
	wanted = 0.0

	if heard or light:
		state["at"] = target

	var here: Vector3 = state["pos"]
	var aim: Vector3 = (state["at"] as Vector3) - (level.position + here + Vector3(0, 2.0, 0))
	var flat_aim := Vector3(aim.x, 0.0, aim.z)
	var face := atan2(-aim.x, -aim.z)
	var turn := deg_to_rad(config.witch_turn_rate) * 3.0 * delta
	state["face"] = float(state["face"]) + clampf(wrapf(face - float(state["face"]), -PI, PI), -turn, turn)
	var step := float((level.witches[i] as Dictionary)["speed"]) * config.witch_speed_scale * config.witch_chase_speed * delta
	var next: Vector3 = here + flat_aim.normalized() * minf(step, flat_aim.length())

	if flat_aim.length() < 1.0 or float(state["t"]) <= 0.0 or player.caught_left > 0.0 \
			or not _clear_between(level.position + here + Vector3(0, 2.0, 0), level.position + next + Vector3(0, 2.0, 0), player):
		state["mode"] = MODE_BACK
		state["alert"] = false
		state["cool"] = config.witch_listen_cooldown
	else:
		state["pos"] = next
	return wanted


func _mode_back(level: LmLevel, i: int, state: Dictionary, seconds: float, delta: float) -> float:
	var wanted := 0.0
	state["stall"] = float(state["stall"]) + delta
	wanted = 0.0
	var home: Vector3 = (level.witch_pose(i, seconds - float(state["stall"]), config.witch_speed_scale, config.witch_head_sweep, config.witch_door_seconds)["at"] as Vector3)
	var here: Vector3 = state["pos"]
	var way := Vector3(home.x - here.x, 0.0, home.z - here.z)
	var step := float((level.witches[i] as Dictionary)["speed"]) * config.witch_speed_scale * delta

	if way.length() <= maxf(step, 0.2):
		state["mode"] = MODE_WALK
	else:
		state["pos"] = here + way.normalized() * step
		state["face"] = atan2(-way.x, -way.z)
	return wanted


## Nothing solid between a witch's eye and a player's: walls, and doors still shut for THAT
## player (one they opened is open for them, and she sees through it).
func _clear_between(from: Vector3, to: Vector3, player: LmPlayer, open_door: String = "") -> bool:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null

	if space == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(from, to, LAYER_WORLD)
	var exclude: Array[RID] = [player.get_rid()]
	var level := level_of(player)

	var open_ids: Array = player.opened.keys()

	# A door she is standing in, open, is no more in her way than one the player opened.
	if open_door != "":
		open_ids.append(open_door)

	for door_id: String in open_ids:
		var rid := level.door_rid(door_id) if level != null else RID()

		if rid.is_valid():
			exclude.append(rid)

	query.exclude = exclude
	return space.intersect_ray(query).is_empty()
