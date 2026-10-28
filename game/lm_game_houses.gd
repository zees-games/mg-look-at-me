extends Node3D

## The house's state and its catalogue: the houses on offer, the content index and the rotation.



const LmAmbience := preload("lm_ambience.gd")
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
## A witch has stopped to listen for this player: the client's cue for the tell.
signal listened(key: StringName, witch: int)
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
## The ambience cvars (`lm_ambient*`): bound by the module (REPLICATED), followed by a client through its link.
var ambient_rules: DotAmbienceRules = LmAmbience.make_rules()

## Binds [member config] to cvars, the cfg/ yml layers and the workbench; made in [method _ready] unless a caller set one.
var config_binder: DotGameConfigBinder = null

## The workbench's profile rows, made on first ask: the bridge's profile link must exist before the netcode seals, the workbench after.
var profile_runtime: DotProfileRuntime = null


## dot-team's block rules (`!block`, `!noblock`, `mp_teamblock`), set by the server module or `DotGameClient.add_noblock`. They feed [member body_rules]'s `pair_fn`.
var block_rules: Object = null:
	set(value):
		if block_rules != null and block_rules.has_signal(&"changed") and block_rules.is_connected(&"changed", body_rules.refresh):
			block_rules.disconnect(&"changed", body_rules.refresh)
		block_rules = value
		if block_rules != null and block_rules.has_signal(&"changed"):
			block_rules.connect(&"changed", body_rules.refresh)


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


## Directories laid out like [member LmConfig.houses_directory], from the map packs the
## server names (DotGameContent.map_dirs). Set through [method add_house_roots].
var extra_house_roots := PackedStringArray()


## The Workshop: a subscribed pack's `map` entries of an accepted `map_kind` are houses here,
## for the index's current session only. Opt-in (see [method follow_content]).
var content_index: DotContentIndex = null


var content_kinds := PackedStringArray()


## Pack houses by entry key -> {"ok", "id", "name", "directory", "why"}, so a pack's files are
## read once and not on every menu draw.
var _content_houses: Dictionary = {}


## Pack house ids currently in [member houses], so a session change takes exactly those out.
var _content_ids: Dictionary = {}


## The server's maps.yml, or null when there is none (every house rotates, as it always did).
## dot-map's rotation file speaks DotMapDef; this game holds house records, so [member _defs]
## mirrors the ids and the file marks `in_rotation` on the mirror. See [method rotating_houses].
var rotation_file: DotMapRotationFile = null


var _defs: DotMapCatalogue = DotMapCatalogue.new()


var _rotation: DotMapRotation = DotMapRotation.of(_defs)


## Asked every tick of a world that ticks itself: true while a cover is up (the client's load
## gate). Only the bodies are stepped then, so the meter, catches, events and exits do not act on
## anybody in front of a picture. Unset, never held.
var hold_clock: Callable = Callable()


## `func(key: StringName) -> bool`: whether a player may be caught now, assigned by the module
## from dot-game's `can_peer_be_harmed` (a client still behind its loading cover cannot be). Unset
## offline, and a bot is never loading.
var harm_gate: Callable = Callable()


## A head turns about this far off the shoulders and no further.
const MAX_HEAD := deg_to_rad(140.0)


## A witch's state toward one player: walking her path, standing to listen, turning to a sound she
## heard, running at it, walking back to her path.
const MODE_WALK := 0


const MODE_LISTEN := 1


const MODE_TURN := 2


const MODE_CHASE := 3


const MODE_BACK := 4


static func _resolve(dir: String) -> String:
	return dir if dir.begins_with("res://") or dir.begins_with("user://") else LmPaths.rebase("res://%s" % dir)


## Adds houses delivered as packs and lists every house again, so the vote and `lm_house`
## see them. The house being played is not changed.
func add_house_roots(roots: PackedStringArray) -> void:
	for root in roots:
		if not extra_house_roots.has(root):
			extra_house_roots.append(root)

	_find_houses()
	apply_rotation()


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

	sync_content()


## The `map_kind`s of subscribed maps this game takes: `accepts.map_kinds` in `provides.json`,
## so the site's offer and this list cannot drift.
static func accepted_map_kinds() -> PackedStringArray:
	var out := PackedStringArray()
	var path := LmPaths.rebase("res://provides.json")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	var accepts: Variant = (parsed as Dictionary).get("accepts") if parsed is Dictionary else null
	var kinds: Variant = (accepts as Dictionary).get("map_kinds") if accepts is Dictionary else null

	if not (kinds is Array):
		kinds = ["lookatme"]

	for kind: Variant in (kinds as Array):
		out.append(str(kind))

	return out


## Follows [param index]. A pack's entry `scene` is its `house.json`; its `id` must equal the entry's.
## Synced on every read, since the index filters by its current session. The game's own ids win.
func follow_content(index: DotContentIndex, accepted_kinds: PackedStringArray) -> void:
	content_index = index
	content_kinds = accepted_kinds
	sync_content()


func sync_content() -> void:
	for id: StringName in _content_ids:
		houses.erase(id)

	_content_ids.clear()

	if content_index == null:
		return

	for entry in content_index.entries(&"map"):
		var kind := str(entry.raw.get("map_kind", ""))

		if kind == "" or not (content_kinds.has("*") or content_kinds.has(kind)):
			continue

		var id := StringName(entry.id)

		if houses.has(id):
			continue

		var found := _content_house(entry)

		if bool(found["ok"]):
			houses[id] = {"name": str(found["name"]), "directory": str(found["directory"]), "pack": entry.pack_title}
			_content_ids[id] = true


func _content_house(entry: DotContentEntry) -> Dictionary:
	if _content_houses.has(entry.key):
		return _content_houses[entry.key]

	var found := {"ok": false, "name": "", "directory": ""}
	var path := entry.path("scene")
	var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if path != "" and FileAccess.file_exists(path) else null
	var why := ""

	if not (meta is Dictionary):
		why = "the scene is not a house document"
	elif str((meta as Dictionary).get("kind", "")) != "house" or str((meta as Dictionary).get("id", "")) != entry.id:
		why = "the document is not a house whose id is the entry's"
	else:
		var saved_documents := documents
		var saved_refused := refused
		documents = {}
		refused = {}

		if load_directory(path.get_base_dir()) == 0:
			why = "the house has no levels"

		documents = saved_documents
		refused = saved_refused

	if why == "":
		found = {"ok": true, "name": entry.name, "directory": path.get_base_dir()}
	else:
		DotLog.warn(CHANNEL, "a Workshop house was refused", {"entry": entry.key, "why": why})

	_content_houses[entry.key] = found
	return found


func _shown_name(id: StringName) -> String:
	var house: Dictionary = houses[id]
	return "%s [%s]" % [house["name"], house["pack"]] if house.has("pack") else str(house["name"])


## Whether [param id] came from a subscribed pack.
func is_workshop(id: StringName) -> bool:
	return _content_ids.has(id)


## Every house, as `[id, name]` pairs, a pack's as "Name [Pack]": what the vote lists.
func listed_houses() -> Array:
	sync_content()
	var out: Array = []

	for id: StringName in houses:
		out.append([id, _shown_name(id)])

	return out


## Whether maps.yml names rotations, so that it decides which houses rotate and in what order.
func has_rotation_file() -> bool:
	return rotation_file != null and rotation_file.has_rotations()


## Brings the mirror up to date with [member houses] and lets the file mark who rotates.
## Without a file every house is in.
func apply_rotation() -> void:
	sync_content()

	for id: StringName in houses:
		if _defs.get_map(id) == null:
			var def := DotMapDef.new()
			def.id = id
			def.scene_path = "lm:%s" % id
			def.display_name = str(houses[id]["name"])
			var _added := _defs.add(def)

	for def: DotMapDef in _defs.maps.duplicate():
		if not houses.has(def.id):
			var _gone := _defs.remove(def.id)

	if has_rotation_file():
		rotation_file.fallback_in = func(_def: DotMapDef) -> bool: return true
		var _applied := rotation_file.apply(_rotation)
		return

	_rotation.order = []

	for def: DotMapDef in _defs.maps:
		def.in_rotation = true


## Reads maps.yml (the `--config` directory first) and applies it. Called at boot and by
## `sv_map_rotation_file`. A file that is present and unreadable is an ERROR and changes nothing:
## rotating every house is a better failure than rotating none.
func load_rotation() -> DotResult:
	var stem := config.map_rotation_file
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != LmConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every house rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()

	if found != "":
		paths.append(found)

	var read := DotMapRotationFile.load_files(paths, "mg-look-at-me")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every house rotates", {
			"why": read.error.message,
		})
		rotation_file = null
		apply_rotation()
		return read

	rotation_file = read.value
	apply_rotation()

	if has_rotation_file():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(rotation_file.sources), "active": rotation_file.active_name(),
		})

	return read


## `lm_rotation <name>`: the live switch to another named rotation in the file.
func switch_rotation(rotation_name: String) -> DotResult:
	if not has_rotation_file():
		return DotResult.fail(DotError.CODE_STATE, "There is no maps.yml to switch rotations in.")

	apply_rotation()
	return rotation_file.switch(_rotation, rotation_name)


## Whether [param id] is in the active rotation. A house this game does not hold is not.
func in_rotation(id: StringName) -> bool:
	sync_content()

	if not houses.has(id):
		return false

	if not has_rotation_file():
		return true

	apply_rotation()
	var def := _defs.get_map(id)
	return def != null and def.in_rotation


## What the ballot, a nomination and [method next_house] may offer: every house less the ones
## maps.yml leaves out, in the file's order. A house left out stays [i]playable[/i] (`lm_house`
## and the map menu load it). With no file, or a file that leaves nothing, every house.
func rotating_ids() -> Array[StringName]:
	sync_content()
	var every: Array[StringName] = []

	for id: StringName in houses:
		every.append(id)

	if not has_rotation_file():
		return every

	apply_rotation()
	var out: Array[StringName] = []

	for def: DotMapDef in _rotation.pool(0):
		if houses.has(def.id):
			out.append(def.id)

	return out if not out.is_empty() else every


## [method listed_houses] less the houses maps.yml leaves out: what the vote's ballot lists.
func rotating_houses() -> Array:
	var out: Array = []

	for id in rotating_ids():
		out.append([id, _shown_name(id)])

	return out


## The house after this one: the file's rotation (mode, cooldown, written order) or, with no file,
## the next in id order. Never an out-of-rotation house; changes nothing ([method change_house] does).
func next_house() -> StringName:
	if has_rotation_file():
		apply_rotation()

		if _rotation.seed_value == 0:
			_rotation.seed_value = maxi(1, config.seed_value) if config.seed_value != 0 else randi_range(1, 0x3fffffff)

		var chosen := _rotation.choose(0)

		if chosen != null and houses.has(chosen.id):
			return chosen.id

	var ids := rotating_ids()
	ids.sort()

	if ids.is_empty():
		return house_id

	var at := ids.find(house_id)
	return ids[(at + 1) % ids.size()]


## `lm_house` and `lm_houses` answer to the names maps.yml's `commands:` block gives them.
func rotation_commands() -> Dictionary:
	return rotation_file.commands() if rotation_file != null else {}


## Every name a role of this game's own answers to (the first is the one help shows); the
## role's own name with no file.
func command_names(role: String) -> PackedStringArray:
	var names: Dictionary = rotation_commands().get("names", {})

	if not names.has(role):
		return PackedStringArray([role])

	return DotCommandNames.all_of("", names, {}, role)


## Every house, as the map menu (M) lists them: `{id, name, detail, current}`, how many levels
## under the name. Solo the client's list, online the server's (the module hands it to
## dot-vote's map menu), so both say the same.
func house_rows() -> Array:
	sync_content()
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
		var rotates := in_rotation(id)
		out.append({"id": String(id), "name": _shown_name(id) + ("" if rotates else " (not in rotation)"),
			"in_rotation": rotates, "current": id == house_id,
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


