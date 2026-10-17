extends Node3D

## The house: every level at once, side by side, every player on whichever level they are on,
## and the witches. Headless; [LmClient] draws.
##
## [b]A server that never ends.[/b] Nobody waits for a round: a player arrives in the lobby
## (level 1's start room), goes through the levels at their own pace, and the next person can
## arrive at any moment. So there are no rounds and no sides, only each player's own progress.
##
## [b]Being seen is a meter, not a moment.[/b] Every tick each witch on a player's level asks
## whether she can see them — in range, inside her cone, nothing in the way — and how well:
## nearer is faster, a lit flashlight faster, a crouch or standing still slower. The meter
## climbs while she does and drains after a pause when she does not, and full is caught.

const LmConfig := preload("lm_config.gd")
const LmLevel := preload("lm_level.gd")
const LmPlayer := preload("lm_player.gd")
const LmPaths := preload("lm_paths.gd")

const CHANNEL := "lookatme.game"
const SERVICE := &"lookatme.game"

## Metres between levels laid side by side, and how many to a row: 32 levels in one line ran
## to 5 km once they were three times the size, and the further from the origin the coarser a
## float's metre.
const LEVEL_GAP := 40.0
const LEVELS_PER_ROW := 8

## Metres from a door a player must be before it slams behind them: never shut on somebody
## standing in the doorway.
const SLAM_CLEAR := 3.0

## The physics layer walls and doors are on, and the one players are on.
const LAYER_WORLD := 1
const LAYER_PLAYERS := 2

## The netcode's numbers, read by the module and the client from here, so both ends agree.
const NET_SNAPSHOT_RATE := 30

## Metres from the origin a position may be: 32 levels side by side reach a long way.
const NET_WORLD_EXTENT := 8192.0

signal said(key: StringName, text: String)
signal took(key: StringName, item_id: String)
signal opened_door(key: StringName, door_id: String)
signal caught(key: StringName)
signal level_done(key: StringName, number: int)
## One of the level's events happened to [param key] (a slam when the door actually shuts).
signal event_fired(key: StringName, event_id: String)
signal won(key: StringName)
signal player_joined(key: StringName)
signal player_left(key: StringName)
## A different house is being played: every level is new, and everybody is in its lobby.
signal house_changed(id: StringName)

@export var authoritative: bool = true
@export var draws: bool = true
@export var self_tick: bool = true
@export var register_service: bool = true

var config: LmConfig = null

## dot-player-controller's `mp_forceview` (may a player switch to third person; the config's
## `allow_third_person` false is `1`, first person only) and `mp_solidplayers` (players block
## each other). Bound by the module (REPLICATED) and followed by a client through its link.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()

## level number -> LmLevel, and the documents by number.
var levels: Dictionary = {}
var documents: Dictionary = {}
var refused: Dictionary = {}

## key -> LmPlayer.
var players: Dictionary = {}

## Keys of everybody who has got out of THIS house: key -> when. One of [member _all_winners].
var winners: Dictionary = {}

## Every house's winners, house id -> {key: when}, kept in config.winners_file. Per house,
## because getting out of a 18-level house is not getting out of the 32-level one, and a crown
## that said so would be one the second house's players stop believing.
var _all_winners: Dictionary = {}

## Every house this server can play: id -> {"name", "directory"}. And the one being played.
var houses: Dictionary = {}
var house_id: StringName = &""

var tick_rate: int = 60
var tick: int = 0


func _init() -> void:
	config = LmConfig.new()


## A player's motor mask under `mp_solidplayers`: the walls, and the other players when they
## are solid. Their capsule is already on LAYER_PLAYERS, so the mask is the whole change.
func _apply_body_mask(player: LmPlayer) -> void:
	if player != null and player.controller != null:
		body_rules.apply_to(player.controller, LAYER_WORLD, LAYER_PLAYERS)


func _on_body_rules_changed() -> void:
	for key in players:
		_apply_body_mask(players[key] as LmPlayer)


func _ready() -> void:
	var _loaded := config.load_layered("user://cfg/lookatme.json")
	tick_rate = Engine.physics_ticks_per_second
	# The config's old switch is the server rule's first value until a cvar says otherwise.
	if not config.allow_third_person:
		view_rules.force_view = DotPlayerViewRules.FIRST_ONLY
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)

	if authoritative:
		_find_houses()
		var start := StringName(config.house) if houses.has(StringName(config.house)) else &"house"
		var _h := change_house(start)
		_read_winners()

	if register_service:
		DotRegistry.register(SERVICE, self)

	set_physics_process(self_tick)
	DotLog.info(CHANNEL, "the house is ready", {"levels": levels.size(), "refused": refused.size()})


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


static func _resolve(dir: String) -> String:
	return dir if dir.begins_with("res://") or dir.begins_with("user://") else LmPaths.rebase("res://%s" % dir)


## Directories laid out like [member LmConfig.houses_directory], from the map packs the
## server names (DotGameContent.map_dirs). Set through [method add_house_roots].
var extra_house_roots := PackedStringArray()


## Adds houses delivered as packs and lists every house again, so the vote and `lm_house`
## see them. The house being played is not changed.
func add_house_roots(roots: PackedStringArray) -> void:
	for root in roots:
		if not extra_house_roots.has(root):
			extra_house_roots.append(root)

	_find_houses()


## The built-in house, and every directory under [member LmConfig.houses_directory] with a
## house.json: in res://, in user:// (an owner's own), and in every map pack the server
## names for this game.
func _find_houses() -> void:
	houses.clear()
	houses[&"house"] = {"name": "The House", "directory": _resolve(config.level_directory)}

	for root in [_resolve(config.houses_directory), "user://lookatme_houses"] + Array(extra_house_roots):
		var dir := DirAccess.open(root)

		if dir == null:
			continue

		for sub in dir.get_directories():
			var path: String = root.path_join(sub)
			var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(path.path_join("house.json"))) if FileAccess.file_exists(path.path_join("house.json")) else null

			if meta is Dictionary:
				houses[StringName(str((meta as Dictionary).get("id", sub)))] = {"name": str((meta as Dictionary).get("name", sub)), "directory": path}


## Plays house [param id]: its levels replace these, and everybody starts again in its lobby.
## What the vote does, and what `lm_house` does for an operator.
func change_house(id: StringName) -> DotResult:
	if not houses.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no house '%s'." % id)

	documents.clear()
	refused.clear()
	var _n := load_directory(str(houses[id]["directory"]))

	if documents.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "House '%s' has no levels." % id)

	build_levels()
	house_id = id
	_select_winners()

	for key: StringName in players:
		var player: LmPlayer = players[key]
		player.best = 1
		send_to(player, 1)

	DotLog.info(CHANNEL, "a house opened", {"house": String(id), "levels": levels.size()})
	house_changed.emit(id)
	return DotResult.success(id)


## Every house, as the map menu (M) lists them: `{id, name, detail, current}`, how many levels
## under the name. Solo the client's list, online the server's (the module hands it to
## dot-vote's map menu), so both say the same.
func house_rows() -> Array:
	var out: Array = []
	var ids := houses.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	for id: StringName in ids:
		var levels_in := 0
		var dir := DirAccess.open(str(houses[id]["directory"]))
		if dir != null:
			for f in dir.get_files():
				if f.ends_with(".json") and f != "house.json":
					levels_in += 1
		out.append({"id": String(id), "name": str(houses[id]["name"]), "current": id == house_id,
			"detail": "%d levels" % levels_in if levels_in > 0 else ""})
	return out


func house_name() -> String:
	return str(houses.get(house_id, {}).get("name", house_id))


func load_directory(directory: String) -> int:
	var dir := DirAccess.open(directory)

	if dir == null:
		DotLog.warn(CHANNEL, "no level directory", {"path": directory})
		return 0

	for file in dir.get_files():
		if file.get_extension() != "json" or file == "house.json":
			continue

		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join(file)))

		if not (parsed is Dictionary) or str((parsed as Dictionary).get("kind", "")) != "level" or int((parsed as Dictionary).get("number", 0)) < 1:
			refused[file] = "not a level document"
			continue

		documents[int(parsed["number"])] = parsed

	return documents.size()


## Builds every level, laid side by side along +X in rows of [constant LEVELS_PER_ROW], each
## row along +Z after the deepest level of the one before.
func build_levels() -> void:
	# Out of the tree now, not at the end of the frame: a house change builds the new levels
	# under the same names in the same places, and two Level_01s for a frame is two sets of
	# walls in one place.
	for n: int in levels:
		remove_child(levels[n] as Node)
		(levels[n] as Node).queue_free()

	levels.clear()
	var numbers: Array = documents.keys()
	numbers.sort()
	var next_x := 0.0
	var row_z := 0.0
	var row_depth := 0.0
	var in_row := 0

	for n: int in numbers:
		var level := LmLevel.new()
		level.name = "Level_%02d" % n
		add_child(level)
		level.furnished = config.furniture_enabled
		var built := level.build(documents[n], draws)

		if not built.ok:
			refused["level %d" % n] = built.error.message
			level.queue_free()
			continue

		var bounds := Rect2()
		var first := true

		for room_id: String in level.rooms:
			var rect: Rect2 = level.rooms[room_id]["rect"]
			bounds = rect if first else bounds.merge(rect)
			first = false

		if in_row == LEVELS_PER_ROW:
			row_z += row_depth + LEVEL_GAP
			next_x = 0.0
			row_depth = 0.0
			in_row = 0

		level.position = Vector3(next_x - bounds.position.x, 0.0, row_z - bounds.position.y)
		next_x += bounds.size.x + LEVEL_GAP
		row_depth = maxf(row_depth, bounds.size.y)
		in_row += 1
		levels[n] = level


func last_level() -> int:
	var numbers: Array = levels.keys()
	return int(numbers.max()) if not numbers.is_empty() else 0


func level_of(player: LmPlayer) -> LmLevel:
	return levels.get(player.level, null)


# --- People ------------------------------------------------------------------

func join(key: StringName, name_text: String, avatar: DotAvatar = null) -> LmPlayer:
	if players.has(key):
		return players[key]

	var player := LmPlayer.new()
	player.name = "Player_%s" % String(key)
	player.player_key = key
	player.display_name = name_text
	player.avatar = avatar
	player.config = config
	player.tick_rate = tick_rate
	add_child(player)
	players[key] = player
	_apply_body_mask(player)
	player.won = winners.has(String(key))
	send_to(player, 1)
	player_joined.emit(key)
	return player


func leave(key: StringName) -> void:
	var player: LmPlayer = players.get(key, null)

	if player == null:
		return

	players.erase(key)
	player.queue_free()
	player_left.emit(key)


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


# --- Doing things --------------------------------------------------------------

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


# --- Events ----------------------------------------------------------------------

## What the house does to [param player] now: every event of their level whose condition has
## come true and that has not happened to them on this go. Called every tick and after every
## E. "lights" and "glimpse" are the player's own client's to show; "slam" shuts the door
## for them (they open it again to go back), once they are clear of the doorway.
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
			if Vector2(local.x - centre.x, local.z - centre.z).length() < SLAM_CLEAR and absf(local.y - centre.y) < 2.0:
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


func set_flashlight(key: StringName, on: bool) -> void:
	var player: LmPlayer = players.get(key, null)

	if player != null:
		player.flashlight = on


## A fright the player's client reports (a demon's jump, a look-behind): the meter rises by
## [param amount] and no higher than `scare_meter_cap`, and the drain waits as it does after a
## sighting. Refused for a catch in progress, with demons off, or inside `scare_cooldown` of the
## last: a client may ask for the meter to go UP, which costs nobody but itself, and the cooldown
## keeps a loop of asks from being the way to a catch. Returns whether it applied.
func spook(key: StringName, amount: float) -> bool:
	var player: LmPlayer = players.get(key, null)

	if player == null or player.caught_left > 0.0 or amount <= 0.0:
		return false

	if not config.demons_enabled and not config.look_behind_enabled:
		return false

	var now := seconds_now()

	if now - player.spooked_at < minf(config.scare_cooldown, 5.0):
		return false

	var top := maxf(config.demon_meter_spike, config.look_behind_spike)
	player.spooked_at = now
	player.meter = maxf(player.meter, minf(player.meter + minf(amount, top), config.scare_meter_cap))
	player.unseen_for = 0.0
	return true


# --- The tick ------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	tick += 1

	if not authoritative:
		return

	var seconds := float(tick) / float(maxi(tick_rate, 1))

	for key: StringName in players:
		var player: LmPlayer = players[key]

		if player.caught_left > 0.0:
			player.caught_left -= delta

			if player.caught_left <= 0.0:
				_put_back(player)

			continue

		_apply_doors(player)
		player.simulate(tick, delta)
		_watch(player, seconds, delta)
		fire_events(player)
		_check_exit(player)


func seconds_now() -> float:
	return float(tick) / float(maxi(tick_rate, 1))


## Every witch on [param player]'s level looks for them, and the meter moves.
func _watch(player: LmPlayer, seconds: float, delta: float) -> void:
	var level := level_of(player)

	if level == null:
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
	var pose := level.witch_pose(index, seconds, config.witch_speed_scale, config.witch_head_sweep, config.witch_door_seconds)
	var state: Dictionary = player.gaze.get(index, {})

	if not state.is_empty():
		pose["head"] = float(state["head"])

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


## Every witch on the level perceives the player's noise and lit flashlight, and reacts: after
## `witch_reaction_seconds` of it she turns her head toward where it came from at
## `witch_turn_rate`, keeps looking for `witch_alert_seconds`, then turns back to her sweep. She
## never leaves her walk (Decision 2), only looks; being seen is still the cone's question, asked
## with the head where it is now, so a player has the delay and the turn to get out of the way.
func _listen(player: LmPlayer, level: LmLevel, seconds: float, delta: float) -> void:
	player.noise_left = maxf(player.noise_left - delta, 0.0)
	player.voice_left = maxf(player.voice_left - delta, 0.0)
	var noise := noise_radius(player)
	var target := player.eye_position()

	for i in level.witches.size():
		var pose := level.witch_pose(i, seconds, config.witch_speed_scale, config.witch_head_sweep, config.witch_door_seconds)
		var state: Dictionary = player.gaze.get(i, {})

		if state.is_empty():
			state = {"head": float(pose["head"]), "notice": 0.0, "alert": false, "hold": 0.0, "at": target}

		var eye: Vector3 = level.position + (pose["at"] as Vector3) + Vector3(0, 2.0, 0)
		var to := target - eye
		var distance := to.length()
		var perceived := false

		if distance > 0.01 and player.caught_left <= 0.0:
			var open_door := str(pose["door"]) if float(pose["open"]) > 0.5 else ""
			var in_range := (noise > 0.0 and distance <= noise) or (player.flashlight and distance <= config.witch_light_range)

			if in_range:
				var clear := _clear_between(eye, target, player, open_door)

				# A sound goes round and through walls, quieter; a beam is seen only in the open,
				# by a witch looking roughly its way.
				if noise > 0.0 and distance <= noise * (1.0 if clear else config.witch_hear_walls):
					perceived = true

				if not perceived and clear and player.flashlight and distance <= config.witch_light_range:
					var facing := float(pose["facing"]) + float(state["head"])
					var forward := Vector3(-sin(facing), 0.0, -cos(facing))
					var half_cone := deg_to_rad(float((level.witches[i] as Dictionary)["cone"]) * config.witch_cone_scale * 0.5)
					perceived = forward.dot(Vector3(to.x, 0.0, to.z).normalized()) >= cos(half_cone)

		if perceived:
			state["notice"] = float(state["notice"]) + delta
			state["at"] = target

			if float(state["notice"]) >= config.witch_reaction_seconds:
				state["alert"] = true
				state["hold"] = config.witch_alert_seconds
		else:
			state["notice"] = maxf(float(state["notice"]) - delta, 0.0)

			if bool(state["alert"]):
				state["hold"] = float(state["hold"]) - delta

				if float(state["hold"]) <= 0.0:
					state["alert"] = false

		var wanted := float(pose["head"])

		if bool(state["alert"]):
			var look: Vector3 = (state["at"] as Vector3) - eye
			var heading := atan2(-look.x, -look.z) - float(pose["facing"])
			wanted = clampf(wrapf(heading, -PI, PI), -MAX_HEAD, MAX_HEAD)

		var step := deg_to_rad(config.witch_turn_rate) * delta
		var head := float(state["head"])
		state["head"] = head + clampf(wrapf(wanted - head, -PI, PI), -step, step)
		player.gaze[i] = state


## A head turns about this far off the shoulders and no further.
const MAX_HEAD := deg_to_rad(140.0)


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


func _put_back(player: LmPlayer) -> void:
	var keep := player.holds.duplicate()
	var keep_opened := player.opened.duplicate()
	var keep_used := player.used.duplicate()
	var keep_taken := player.taken.duplicate()
	var keep_fired := player.fired.duplicate()
	send_to(player, player.level)

	if config.caught_penalty == 0:
		player.holds.assign(keep)
		player.opened = keep_opened
		player.used = keep_used
		player.taken = keep_taken
		player.fired = keep_fired
		_apply_doors(player)


func _check_exit(player: LmPlayer) -> void:
	var level := level_of(player)

	if level == null or not player.opened.has("exit"):
		return

	if not level.is_out(player.global_position - level.position):
		return

	var done := player.level
	level_done.emit(player.player_key, done)

	if done >= last_level():
		player.won = true
		winners[String(player.player_key)] = Time.get_datetime_string_from_system()
		_write_winners()
		won.emit(player.player_key)
		said.emit(player.player_key, "YOU GOT OUT. ALL OF IT.")
		send_to(player, 1)
		return

	said.emit(player.player_key, "LEVEL %d" % (done + 1))
	send_to(player, done + 1)


func _read_winners() -> void:
	if not FileAccess.file_exists(config.winners_file):
		return

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(config.winners_file))

	if not (parsed is Dictionary):
		return

	_all_winners.clear()

	for k: Variant in parsed:
		if parsed[k] is Dictionary:
			_all_winners[str(k)] = parsed[k]
		else:
			# The file before houses had winners: one flat {key: when}, and the only house there
			# was the built-in one. Read as that house's, so nobody's crown goes missing.
			if not _all_winners.has("house"):
				_all_winners["house"] = {}

			_all_winners["house"][str(k)] = parsed[k]

	_select_winners()


## [member winners] made this house's, and every player's crown with it.
func _select_winners() -> void:
	var key := String(house_id)

	if not _all_winners.has(key):
		_all_winners[key] = {}

	winners = _all_winners[key]

	for player_key: StringName in players:
		(players[player_key] as LmPlayer).won = winners.has(String(player_key))


## Every house's winners: house id -> {key: when}.
func all_winners() -> Dictionary:
	return _all_winners


func _write_winners() -> void:
	DirAccess.make_dir_recursive_absolute(config.winners_file.get_base_dir())
	var file := FileAccess.open(config.winners_file, FileAccess.WRITE)

	if file != null:
		file.store_string(JSON.stringify(_all_winners, "\t"))
		file.close()
		DotWeb.sync_filesystem()


func describe() -> Dictionary:
	return {"house": String(house_id), "houses": houses.size(), "levels": levels.size(), "players": players.size(), "winners": winners.size(), "tick": tick}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["look at me: %s" % describe()])

	for key: StringName in players:
		lines.append("  %s %s" % [(players[key] as LmPlayer).display_name, (players[key] as LmPlayer).describe()])

	return lines
