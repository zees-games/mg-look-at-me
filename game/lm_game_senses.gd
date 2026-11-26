extends "lm_game_houses.gd"

## The rules a house plays by: doors, interaction, the events and the commands.

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
	player.place_at(level.position + level.spawn_point(maxi(slot, 0)), level.spawn_yaw())


func _apply_doors(player: LmPlayer) -> void:
	var level := level_of(player)
	var rids: Array[RID] = []
	player.lift_level = level if level != null and not level.lifts.is_empty() else null

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
	GSLog.debug(CHANNEL, "an event", {"player": String(player.player_key), "level": player.level, "event": event_id})
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
