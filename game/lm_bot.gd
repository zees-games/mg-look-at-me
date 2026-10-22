extends RefCounted

## A stand-in player: plays its level with real movement and E, server side, off unless a test or
## the soak creates one. It is the house's own puzzle format (items, stations, doors, stairwells),
## so it is game code; there is no navigation mesh to hand to dot-bot's navigation.
##
## Each tick [method drive] picks the nearest thing it can usefully do from the rooms it can walk
## through, walks door to door to it, aims and presses E. Witches are ignored: a catch puts it back.

const LmGame := preload("lm_game.gd")
const LmLevel := preload("lm_level.gd")
const LmPlayer := preload("lm_player.gd")

const ARRIVE := 0.7
const STAND_OFF := 1.1
const STUCK_WIGGLE := 0.8
const STUCK_GIVE_UP := 4.0
const SKIP_SECONDS := 20.0

var key: StringName
var game: LmGame
## Things done, for the report.
var interacted := 0
var gave_up := 0
var levels_done := 0
var idle_seconds := 0.0

var _goal: Dictionary = {}
var _route: Array[Vector3] = []
var _skipped: Dictionary = {}
var _clock := 0.0
var _progress_at := Vector3.ZERO
var _progress_clock := 0.0
var _level_number := 0
var _sig := 0


func _init(p_game: LmGame, p_key: StringName) -> void:
	game = p_game
	key = p_key
	game.level_done.connect(func(who: StringName, _n: int) -> void:
		if who == key:
			levels_done += 1)


func player() -> LmPlayer:
	return game.players.get(key, null)


## Whether it has somewhere to go right now.
func has_goal() -> bool:
	return not _goal.is_empty()


## One line of where it is and what it is after.
func describe() -> String:
	var body := player()
	return "L%d pos=%s goal=%s route=%d caught=%.1f done=%d gave_up=%d" % [body.level, body.global_position.snappedf(0.1), \
			"%s:%s" % [_goal["kind"], _goal["id"]] if not _goal.is_empty() else "-", _route.size(), body.caught_left, levels_done, gave_up]


## Sets the player's command for the next tick; call before [method LmGame.step].
func drive(delta: float) -> void:
	var body := player()
	var level := game.level_of(body) if body != null else null
	_clock += delta

	if level == null or body.caught_left > 0.0:
		_goal = {}
		return

	if body.level != _level_number or body.warps != _sig:
		_level_number = body.level
		_sig = body.warps
		_goal = {}
		_skipped.clear()

	var local := body.global_position - level.position

	if _goal.is_empty() and not _choose(body, level, local):
		idle_seconds += delta
		body.controller.apply_command(DotFpsCommand.new())
		return

	var command := DotFpsCommand.new()

	if _route.is_empty():
		_act(body, level, local, command)
	else:
		_walk(body, local, command, delta)

	body.controller.apply_command(command)


func _act(body: LmPlayer, level: LmLevel, local: Vector3, command: DotFpsCommand) -> void:
	var at: Vector3 = _goal["at"]
	var eye := body.eye_position() - level.position
	var to := at - eye
	command.yaw = rad_to_deg(atan2(-to.x, -to.z))
	command.pitch = rad_to_deg(asin(clampf(to.normalized().y, -1.0, 1.0)))

	if str(_goal["kind"]) == "leave":
		command.move = Vector2(0, 1)
		return

	if body.look_direction().dot(to.normalized()) < 0.97:
		return

	var before := _sig_of(body)
	var _said := game.interact(key)
	interacted += 1

	if _sig_of(body) == before:
		_skip()
	else:
		_goal = {}


func _sig_of(body: LmPlayer) -> int:
	return body.holds.size() + body.opened.size() + body.used.size() + body.taken.size() + body.level * 1000


func _skip() -> void:
	_skipped[str(_goal["kind"]) + str(_goal["id"])] = _clock + SKIP_SECONDS
	gave_up += 1
	_goal = {}
	_route.clear()


func _walk(body: LmPlayer, local: Vector3, command: DotFpsCommand, delta: float) -> void:
	var flat := Vector2(local.x, local.z)
	var next := _route[0]

	if flat.distance_to(Vector2(next.x, next.z)) < ARRIVE:
		_route.remove_at(0)
		_progress_clock = 0.0
		return

	var to := Vector3(next.x - local.x, 0.0, next.z - local.z).normalized()
	command.yaw = rad_to_deg(atan2(-to.x, -to.z))
	command.move = Vector2(0, 1)

	if local.distance_to(_progress_at) > 0.15:
		_progress_at = local
		_progress_clock = 0.0
	else:
		_progress_clock += delta

	if _progress_clock > STUCK_GIVE_UP:
		_skip()
	elif _progress_clock > STUCK_WIGGLE:
		# Round a corner of furniture: sidestep one way, then the other.
		command.move = Vector2(1.0 if int(_progress_clock * 2.0) % 2 == 0 else -1.0, 0.6)


## Picks the nearest useful thing and plans the walk. False when there is none.
func _choose(body: LmPlayer, level: LmLevel, local: Vector3) -> bool:
	var here := level.room_at(local)

	if here == "":
		return false

	var depth := {here: 0}
	var came := {}
	var queue: Array[String] = [here]

	while not queue.is_empty():
		var room: String = queue.pop_front()

		for door_id: String in level.doors:
			var door: Dictionary = level.doors[door_id]["doc"]
			var other := ""

			if not body.opened.has(door_id) or door_id == "exit":
				continue

			if str(door["a"]) == room:
				other = str(door["b"])
			elif str(door["b"]) == room:
				other = str(door["a"])

			if other != "" and not depth.has(other):
				depth[other] = int(depth[room]) + 1
				came[other] = {"from": room, "door": door_id}
				queue.append(other)

	var best := {}
	var best_cost := INF

	for id: String in level.items:
		if not body.taken.has(id):
			best = _better(best, level, depth, "item", id, level.items[id]["at"], 0.9, best_cost)
			best_cost = float(best.get("cost", INF))

	for id: String in level.stations:
		var station: Dictionary = level.stations[id]["doc"]
		var needs := str(station.get("needs", ""))

		if not body.used.has(id) and (needs == "" or body.holds.has(needs)):
			best = _better(best, level, depth, "station", id, level.stations[id]["at"], 0.8, best_cost)
			best_cost = float(best.get("cost", INF))

	for id: String in level.doors:
		var door: Dictionary = level.doors[id]["doc"]
		var lock := str(door.get("lock", ""))

		if body.opened.has(id) or lock.begins_with("@") or (lock != "" and not body.holds.has(lock)):
			continue

		best = _better(best, level, depth, "door", id, level.doors[id]["centre"], 1.2, best_cost)
		best_cost = float(best.get("cost", INF))

	if body.opened.has("exit"):
		var exit: Dictionary = level.doors["exit"]
		best = _better(best, level, depth, "leave", "exit", exit["centre"], 1.0, INF)

	if best.is_empty():
		return false

	_goal = best
	_plan(level, local, here, came)
	return true


func _better(best: Dictionary, level: LmLevel, depth: Dictionary, kind: String, id: String, at: Vector3, lift: float, best_cost: float) -> Dictionary:
	if _skipped.get(kind + id, -1.0) > _clock:
		return best

	var room := _room_for(level, kind, id, at, depth)

	if room == "" or not depth.has(room):
		return best

	# Doors first at equal distance, so a locked-in thing is not walked past an open way.
	var cost := -1.0 if kind == "leave" else float(depth[room]) * 100.0 + (0.0 if kind == "door" else 1.0)

	if cost >= best_cost and not best.is_empty():
		return best

	return {"kind": kind, "id": id, "at": at + Vector3(0, lift, 0), "room": room, "cost": cost}


## The room the player stands in to do it: a thing's own room, a door's near side.
func _room_for(level: LmLevel, kind: String, id: String, at: Vector3, depth: Dictionary) -> String:
	if kind == "door" or kind == "leave":
		var door: Dictionary = level.doors[id]["doc"]
		var a := str(door["a"])
		var b := str(door["b"])

		if depth.has(a) and (not depth.has(b) or int(depth[a]) <= int(depth[b])):
			return a

		return b

	return level.room_at(at + Vector3(0, 0.1, 0))


## Waypoints: through each door on the way, along a stairwell's ramp, then up to the thing.
func _plan(level: LmLevel, local: Vector3, here: String, came: Dictionary) -> void:
	_route.clear()
	var chain: Array = []
	var room: String = _goal["room"]

	while room != here and came.has(room):
		chain.push_front(came[room])
		room = str(came[room]["from"])

	var at_room := here

	for step: Dictionary in chain:
		var door: Dictionary = level.doors[step["door"]]
		var normal: Vector3 = door["normal"]
		var side := 1.0 if str((door["doc"] as Dictionary)["a"]) == at_room else -1.0
		var centre: Vector3 = door["centre"]

		_route.append(centre - normal * side * 1.2)
		_route.append(centre + normal * side * 1.2)
		at_room = _other(door["doc"], at_room)
		_stair_walk(level, at_room, centre + normal * side * 1.2)

	var target: Vector3 = _goal["at"]

	if str(_goal["kind"]) == "door" or str(_goal["kind"]) == "leave":
		var door: Dictionary = level.doors[_goal["id"]]
		var normal: Vector3 = door["normal"]
		var side := 1.0 if str((door["doc"] as Dictionary)["a"]) == _goal["room"] else -1.0
		var centre: Vector3 = door["centre"]

		if str(_goal["kind"]) == "leave":
			_route.append(centre - normal * 1.2)
			_route.append(centre + normal * 1.5)
		else:
			_route.append(centre - normal * side * STAND_OFF)
	else:
		_route.append(target)

	if str(_goal["kind"]) == "leave":
		_goal["at"] = (level.doors["exit"]["centre"] as Vector3) + (level.doors["exit"]["normal"] as Vector3) * 3.0 + Vector3(0, 1.0, 0)

	_progress_at = local
	_progress_clock = 0.0


func _other(door: Dictionary, room: String) -> String:
	return str(door["b"]) if str(door["a"]) == room else str(door["a"])


## Entering a stairwell by one door and leaving by another: up or down its ramp between them.
func _stair_walk(level: LmLevel, room: String, entered_at: Vector3) -> void:
	if str(level.rooms[room]["kind"]) != "stair":
		return

	var foot := level.stair_point(room, false)
	var head := level.stair_point(room, true)
	var near_foot := Vector2(entered_at.x, entered_at.z).distance_to(Vector2(foot.x, foot.z)) \
			<= Vector2(entered_at.x, entered_at.z).distance_to(Vector2(head.x, head.z))
	_route.append(foot if near_foot else head)
	_route.append(head if near_foot else foot)
