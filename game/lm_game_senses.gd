extends "lm_game_houses.gd"

## The rules a house plays by: doors, interaction, the events, and what a witch sees and hears.


## Puts [param player] in the start room of level [param number] with that level's progress
## fresh. What the lobby is, what a catch does under "reset", and what /l does.
func send_to(player: LmPlayer, number: int) -> void:
	var level: LmLevel = levels.get(number, levels.get(1, null))

	if level == null:
		return

	player.level = level.number()
	player.best = maxi(player.best, player.level)
	player.reset_level()
	_apply_doors(player)
	var slot := players.keys().find(player.player_key)
	player.place_at(level.position + level.spawn_point(maxi(slot, 0)), 180.0)


func _apply_doors(player: LmPlayer) -> void:
	var level := level_of(player)
	var rids: Array[RID] = []

	if level != null:
		var ids: Dictionary = player.opened.duplicate()

		# A door a witch is opening is open for everybody while she has it open: the same clock
		# on every machine, so a predicting client agrees with the server (Decision 2).
		for i in level.witches.size():
			var pose := level.witch_pose(i, seconds_now(), config.witch_speed_scale, config.witch_head_sweep, config.witch_door_seconds)

			if str(pose["door"]) != "" and float(pose["open"]) > 0.3:
				ids[str(pose["door"])] = true

		for door_id: String in ids:
			var rid := level.door_rid(door_id)

			if rid.is_valid():
				rids.append(rid)

	player.set_open_doors(rids)




## What [param key] would interact with now: {"kind": item|door|station, "id", "text"} or {}.
func target_of(key: StringName) -> Dictionary:
	var player: LmPlayer = players.get(key, null)
	var level := level_of(player) if player != null else null

	if level == null or player.caught_left > 0.0:
		return {}

	var eye := player.eye_position() - level.position
	var look := player.look_direction()
	var best := {}
	var best_d := config.reach + 0.6

	for item_id: String in level.items:
		if player.taken.has(item_id):
			continue

		var at: Vector3 = (level.items[item_id]["at"] as Vector3) + Vector3(0, 0.9, 0)
		var d := _reach_to(eye, look, at)

		if d < best_d:
			best_d = d
			best = {"kind": "item", "id": item_id, "text": "Take the %s" % str(level.items[item_id]["doc"]["name"]).to_lower()}

	for station_id: String in level.stations:
		var station: Dictionary = level.stations[station_id]["doc"]

		if player.used.has(station_id) and not _repeatable(station):
			continue

		var d := _reach_to(eye, look, (level.stations[station_id]["at"] as Vector3) + Vector3(0, 0.8, 0))

		if d < best_d:
			best_d = d
			best = {"kind": "station", "id": station_id, "text": str(station.get("verb", "Use it"))}

	for door_id: String in level.doors:
		if player.opened.has(door_id):
			continue

		var d := _reach_to(eye, look, (level.doors[door_id]["centre"] as Vector3) + Vector3(0, 1.2, 0))

		if d < best_d:
			best_d = d
			best = {"kind": "door", "id": door_id, "text": "Open the %s" % str(level.doors[door_id]["doc"].get("label", "door")).to_lower()}

	return best


static func _repeatable(_station: Dictionary) -> bool:
	return false


## Distance to [param at], or INF when it is behind or beside the eye: what you interact with
## is what you are looking at, not what is behind you.
func _reach_to(eye: Vector3, look: Vector3, at: Vector3) -> float:
	var to := at - eye
	var d := to.length()

	if d > config.reach + 0.6 or (d > 0.8 and look.dot(to / d) < 0.55):
		return INF

	return d


## Presses E. Returns the line the player is told.
func interact(key: StringName) -> String:
	var player: LmPlayer = players.get(key, null)
	var target := target_of(key)

	if player == null or target.is_empty():
		return ""

	var level := level_of(player)
	var text := ""

	match str(target["kind"]):
		"item":
			var item_id := str(target["id"])
			player.taken[item_id] = true
			player.holds.append(item_id)
			text = "Took the %s" % str(level.items[item_id]["doc"]["name"]).to_lower()
			_share(player, func(other: LmPlayer) -> void:
				other.taken[item_id] = true
				if not other.holds.has(item_id):
					other.holds.append(item_id))
			took.emit(key, item_id)
		"station":
			text = _use(player, level, str(target["id"]))
		"door":
			text = _open(player, level, str(target["id"]))

	if text != "":
		said.emit(key, text)
		# A door, a latch, a tap: heard.
		player.noise_left = config.witch_noise_seconds

	fire_events(player)
	return text


func _use(player: LmPlayer, level: LmLevel, station_id: String) -> String:
	var station: Dictionary = level.stations[station_id]["doc"]
	var needs := str(station.get("needs", ""))

	if needs != "" and not player.holds.has(needs):
		return "You need %s" % _name_of(level, needs)

	if needs != "" and bool(station.get("consumes", false)):
		player.holds.erase(needs)

	player.used[station_id] = true
	var gives := str(station.get("gives", ""))

	if gives != "" and not player.holds.has(gives):
		player.holds.append(gives)

	var opens := str(station.get("opens", ""))

	if opens != "":
		_unlock(player, opens)

	_share(player, func(other: LmPlayer) -> void:
		other.used[station_id] = true
		if opens != "":
			_unlock(other, opens))

	if level.stations[station_id]["node"] is Node3D and str(station.get("kind", "")) == "fire":
		(level.stations[station_id]["node"] as Node3D).visible = not _everyone_used(level, station_id)

	return str(station.get("verb", "Done")) + (": now you have %s" % _name_of(level, gives) if gives != "" else "")


func _open(player: LmPlayer, level: LmLevel, door_id: String) -> String:
	var door: Dictionary = level.doors[door_id]["doc"]
	var lock := str(door.get("lock", ""))

	if lock.begins_with("@"):
		return "It will not open from here"

	if lock != "" and not player.holds.has(lock):
		return "It is locked. You need %s" % _name_of(level, lock)

	_unlock(player, door_id)
	_share(player, func(other: LmPlayer) -> void: _unlock(other, door_id))
	return "Opened the %s" % str(door.get("label", "door")).to_lower()


func _unlock(player: LmPlayer, door_id: String) -> void:
	if player.opened.has(door_id):
		return

	player.opened[door_id] = true
	_apply_doors(player)
	opened_door.emit(player.player_key, door_id)


## Under shared progress, everybody on the same level gets the same effect.
func _share(player: LmPlayer, effect: Callable) -> void:
	if not config.shared_progress:
		return

	for key: StringName in players:
		var other: LmPlayer = players[key]

		if other != player and other.level == player.level:
			effect.call(other)


func _everyone_used(_level: LmLevel, _station_id: String) -> bool:
	return false


func _name_of(level: LmLevel, item_id: String) -> String:
	for item: Dictionary in level.doc.get("items", []):
		if str(item["id"]) == item_id:
			return "the %s" % str(item["name"]).to_lower()

	for station: Dictionary in level.doc.get("stations", []):
		if str(station.get("gives", "")) == item_id:
			# A chest says what is in it: "you need the red key", not "something from a chest".
			if station.has("gives_name"):
				return "the %s" % str(station["gives_name"]).to_lower()
			return "something from the %s" % str(station["name"]).to_lower()

	return "something"


## The step a player is on: the first in the document they have not done.
func step_of(player: LmPlayer) -> String:
	var level := level_of(player)

	if level == null:
		return ""

	for step: Dictionary in level.doc.get("steps", []):
		if _done(player, level, step.get("when", {}), ""):
			continue

		return str(step["text"])

	return "Get out"


## Whether a step's or an event's condition holds for [param player]: holds an item (or ever
## had it: taken it, or used what gives it, so a fuse fitted or water poured is still a step
## done), opened a door, used a station, or is in a room ([param room], where they are now).
func _done(player: LmPlayer, level: LmLevel, when: Dictionary, room: String) -> bool:
	if when.has("holds"):
		var item := str(when["holds"])
		if not (player.holds.has(item) or player.taken.has(item) or _given(player, level, item)):
			return false
	if when.has("opened") and not player.opened.has(str(when["opened"])):
		return false
	if when.has("used") and not player.used.has(str(when["used"])):
		return false
	if when.has("entered") and str(when["entered"]) != room:
		return false
	return not when.is_empty()


func _given(player: LmPlayer, level: LmLevel, item: String) -> bool:
	for station_id: String in player.used:
		var station: Dictionary = level.stations.get(station_id, {}).get("doc", {})
		if str(station.get("gives", "")) == item:
			return true
	return false




## What the house does to [param player] now: every event of their level whose condition has come
## true and not yet happened to them. "lights" and "glimpse" are the client's to show; "slam" shuts
## the door for them once they are clear of the doorway.
func fire_events(player: LmPlayer) -> void:
	var level := level_of(player)

	if level == null or level.events.is_empty() or player.caught_left > 0.0:
		return

	var local := player.global_position - level.position
	var room := level.room_at(local)

	for event_id: String in level.events:
		if player.fired.has(event_id) or player.slams_waiting.has(event_id):
			continue

		var event: Dictionary = level.events[event_id]

		if not _done(player, level, event.get("when", {}), room):
			continue

		if str(event.get("do", "")) == "slam":
			player.slams_waiting.append(event_id)
			continue

		_fire(player, event_id)

	for event_id: String in player.slams_waiting.duplicate():
		var door_id := str(level.events[event_id].get("door", ""))
		var door: Dictionary = level.doors.get(door_id, {})

		if not door.is_empty():
			var centre: Vector3 = door["centre"]
			if Vector2(local.x - centre.x, local.z - centre.z).length() < config.slam_clear and absf(local.y - centre.y) < 2.0:
				continue

		player.slams_waiting.erase(event_id)

		if player.opened.has(door_id):
			player.opened.erase(door_id)
			_apply_doors(player)

		_fire(player, event_id)


func _fire(player: LmPlayer, event_id: String) -> void:
	player.fired[event_id] = true
	var level := level_of(player)
	var text := str(level.events[event_id].get("text", "")) if level != null else ""
	DotLog.debug(CHANNEL, "an event", {"player": String(player.player_key), "level": player.level, "event": event_id})
	event_fired.emit(player.player_key, event_id)

	if text != "":
		said.emit(player.player_key, text)


## A typed command: /r (back to the lobby), /l N (a level you have reached). Returns the reply.
func command(key: StringName, text: String) -> String:
	var player: LmPlayer = players.get(key, null)

	if player == null:
		return ""

	var words := text.strip_edges().trim_prefix("/").trim_prefix("!").split(" ", false)

	if words.is_empty():
		return ""

	var verb := words[0].to_lower()

	if verb == "r" or verb == "restart" or verb == "lobby":
		send_to(player, 1)
		return "Back to the lobby"

	if verb.begins_with("l") and (verb.substr(1).is_valid_int() or (words.size() > 1 and words[1].is_valid_int())):
		var n := int(verb.substr(1)) if verb.substr(1).is_valid_int() else int(words[1])

		if not levels.has(n):
			return "There is no level %d" % n

		if n > player.best:
			return "You have not reached level %d yet" % n

		send_to(player, n)
		return "Level %d" % n

	return ""


## Whether [param key] may be caught (the meter rising, a scare landing) now. True for anybody
## the gate does not know.
func can_be_harmed(key: StringName) -> bool:
	return not harm_gate.is_valid() or bool(harm_gate.call(key))


func seconds_now() -> float:
	return float(tick) / float(maxi(tick_rate, 1))


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
	_listen(player, level, seconds, delta)

	for i in level.witches.size():
		var rate := exposure(player, level, i, seconds)

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
