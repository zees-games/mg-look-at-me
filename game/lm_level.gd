extends Node3D

## A level document, built: the rooms, their walls with doorways cut in them, the doors, the
## items and the things you use them on, the lamps, and where every witch is at any moment.
##
## [b]A witch's walk is a pure function of time[/b], like mg-wipeout's obstacles: a loop of
## points through room centres and doorways, at the document's speed. Every machine poses
## every witch from the clock it already agrees on, so nothing about a witch is ever sent, and
## the server's "can she see you" and the client's picture of where she is cannot disagree.
##
## [b]Doors are per player.[/b] A door is one StaticBody3D in the world, solid; a player who
## has opened it has its RID in their controller's exclusion list, so it is open for them and
## shut for everybody else (see [LmGame]). The level never knows who opened what.
##
## [b]Floors.[/b] A room is on a floor (format 2), a storey ([method storey]) above the one
## below; a STAIRWELL is two storeys high, a landing at its foot, a ramp, and a landing at its
## head level with the floor above, and is the only way between floors. A door says where it
## is ("at", in cells, and "floor"); a format 1 document's doors sit in the middle of the wall
## their rooms share, on the ground floor, as they always did.

const LmPaths := preload("lm_paths.gd")
const LmWeatherHash := preload("lm_hash.gd")

const CHANNEL := "lookatme.level"

## Kenney's furniture is built about 0.43 of a person's size.
const FURNITURE_SCALE := 2.3

## Furniture by what a room is called: something to hide behind that belongs there.
const FURNITURE := {
	"kitchen": ["kitchenFridge", "kitchenStove", "kitchenCabinet", "kitchenSink", "table"],
	"bath": ["bathtub", "bathroomSink", "washer", "dryer"],
	"study": ["bookcaseClosed", "bookcaseOpen", "bookcaseClosedWide", "desk", "loungeChair", "lampRoundFloor"],
	"sitting": ["loungeSofa", "loungeChair", "tableCoffee", "pottedPlant", "bookcaseClosedWide", "lampRoundFloor"],
	"bedroom": ["sideTableDrawers", "bookcaseClosed", "cardboardBoxClosed", "coatRackStanding", "loungeChair"],
	"store": ["cardboardBoxClosed", "cardboardBoxClosed", "bookcaseClosedWide", "table", "washer"],
}

const ROOM_THEMES := {
	"kitchen": "kitchen", "pantry": "kitchen", "larder": "kitchen", "dining": "kitchen", "servants": "kitchen",
	"bath": "bath", "laundry": "bath",
	"library": "study", "study": "study", "gallery": "study", "music": "study",
	"parlour": "sitting", "lobby": "sitting", "landing": "sitting", "hall": "sitting", "conservatory": "sitting", "chapel": "sitting",
	"bedroom": "bedroom", "nursery": "bedroom", "sewing": "bedroom",
}

## Model id -> PackedScene, loaded once for every level, and its bounds.
static var _furniture_scenes: Dictionary = {}
static var _furniture_bounds: Dictionary = {}

const DOOR_WIDTH := 1.5
const DOOR_HEIGHT := 2.3
const WALL := 0.15
const SLAB := 0.25

var doc: Dictionary = {}

## room id -> {"rect": Rect2 (x, z in metres), "doc": room, "floor": int, "floors": int (2 for
## a stairwell), "kind": "room" | "corridor" | "stair"}.
var rooms: Dictionary = {}

## door id -> {"centre": Vector3, "normal": Vector3 (from a into b), "body": StaticBody3D, "doc": door}.
var doors: Dictionary = {}

## item id -> {"at": Vector3, "node": Node3D, "doc": item}.
var items: Dictionary = {}

## station id -> {"at": Vector3, "node": Node3D, "doc": station}.
var stations: Dictionary = {}

## Each witch's loop: {"points": PackedVector3Array, "lengths": PackedFloat32Array, "total",
## "speed", "sight", "cone"}.
var witches: Array = []

## event id -> the event's document: what the house does to a player on the way (the lights
## of a room die, a door slams, she is seen at a distance). [LmGame] fires them per player.
var events: Dictionary = {}

## room id -> [{"light": OmniLight3D, "bulb": Node3D, "energy": float}]: a room's lamps, so a
## client can put them out ([method set_room_light]). Empty on a server.
var lamps: Dictionary = {}

## Whether this level draws (meshes, labels, lamps). Off on a server.
var draws: bool = true

var _materials: Dictionary = {}


func number() -> int:
	return int(doc.get("number", 0))


func build(p_doc: Dictionary, p_draws: bool = true) -> DotResult:
	doc = p_doc
	draws = p_draws
	var cell := float(doc.get("cell", 8.0))

	for room: Dictionary in doc["rooms"]:
		var kind := str(room.get("kind", "room"))
		rooms[str(room["id"])] = {
			"rect": Rect2(float(room["x"]) * cell, float(room["z"]) * cell, float(room["w"]) * cell, float(room["d"]) * cell),
			"doc": room, "floor": int(room.get("floor", 0)), "floors": 2 if kind == "stair" else 1, "kind": kind,
		}

		if kind == "stair" and not str(room.get("up", "")) in ["n", "s", "e", "w"]:
			return DotResult.fail(DotError.CODE_INVALID, "stairwell %s does not say which way is up" % room["id"])

	for door: Dictionary in doc["doors"]:
		var placed := _place_door(door)

		if placed.is_empty():
			return DotResult.fail(DotError.CODE_INVALID, "door %s is not on a wall its rooms share" % door["id"])

		doors[str(door["id"])] = placed

	for room_id: String in rooms:
		_build_room(room_id)

	for door_id: String in doors:
		_build_door(door_id)

	for item: Dictionary in doc["items"]:
		var at := _room_point(str(item["room"]), item["at"])
		items[str(item["id"])] = {"at": at, "node": _build_item(item, at), "doc": item}

	for station: Dictionary in doc["stations"]:
		var at: Vector3

		if station.has("door"):
			# In front of its door, on the near side: a fire burns in the doorway it blocks.
			var door: Dictionary = doors[str(station["door"])]
			at = door["centre"] - door["normal"] * 1.3
		else:
			at = _room_point(str(station["room"]), station["at"])

		stations[str(station["id"])] = {"at": at, "node": _build_station(station, at), "doc": station}

	for witch: Dictionary in doc["witches"]:
		witches.append(_witch_loop(witch))

	for event: Dictionary in doc.get("events", []):
		events[str(event.get("id", ""))] = event

	return DotResult.success(self)


# --- Placement ---------------------------------------------------------------

## Metres from one floor to the next: a room's height and two slabs, the ceiling of the room
## below and the floor of the one above, one over the other (two boxes in one place flicker).
func storey() -> float:
	return float(doc.get("storey", float(doc.get("height", 3.2)) + SLAB * 2.0))


## The height of [param room_id]'s floor, local to the level.
func room_base(room_id: String) -> float:
	return float(rooms[room_id]["floor"]) * storey()


func _spans_floor(room: Dictionary, floor_index: int) -> bool:
	return floor_index >= int(room["floor"]) and floor_index < int(room["floor"]) + int(room["floors"])


func _place_door(door: Dictionary) -> Dictionary:
	if not rooms.has(str(door["a"])):
		return {}

	var a: Rect2 = rooms[str(door["a"])]["rect"]

	if door.has("at"):
		return _place_door_at(door, a)

	if bool(door.get("exit", false)) or str(door.get("b", "")) == "":
		var side := str(door.get("side", "n"))
		var centre: Vector3
		var normal: Vector3

		match side:
			"n":
				centre = Vector3(a.position.x + a.size.x * 0.5, 0.0, a.position.y)
				normal = Vector3(0, 0, -1)
			"s":
				centre = Vector3(a.position.x + a.size.x * 0.5, 0.0, a.end.y)
				normal = Vector3(0, 0, 1)
			"w":
				centre = Vector3(a.position.x, 0.0, a.position.y + a.size.y * 0.5)
				normal = Vector3(-1, 0, 0)
			_:
				centre = Vector3(a.end.x, 0.0, a.position.y + a.size.y * 0.5)
				normal = Vector3(1, 0, 0)

		return {"centre": centre, "normal": normal, "doc": door, "body": null}

	var b: Rect2 = rooms[str(door["b"])]["rect"]

	if is_equal_approx(a.end.x, b.position.x) or is_equal_approx(b.end.x, a.position.x):
		var x := a.end.x if is_equal_approx(a.end.x, b.position.x) else a.position.x
		var lo := maxf(a.position.y, b.position.y)
		var hi := minf(a.end.y, b.end.y)

		if hi - lo < DOOR_WIDTH:
			return {}

		return {"centre": Vector3(x, 0.0, (lo + hi) * 0.5), "normal": Vector3(signf(b.position.x - a.position.x), 0, 0), "doc": door, "body": null}

	if is_equal_approx(a.end.y, b.position.y) or is_equal_approx(b.end.y, a.position.y):
		var z := a.end.y if is_equal_approx(a.end.y, b.position.y) else a.position.y
		var lo := maxf(a.position.x, b.position.x)
		var hi := minf(a.end.x, b.end.x)

		if hi - lo < DOOR_WIDTH:
			return {}

		return {"centre": Vector3((lo + hi) * 0.5, 0.0, z), "normal": Vector3(0, 0, signf(b.position.y - a.position.y)), "doc": door, "body": null}

	return {}


## A door where the document puts it: "at" a point in cells on room a's edge, on "floor". The
## edge says which way it faces; room b must be across that edge, and both rooms on that floor.
func _place_door_at(door: Dictionary, a: Rect2) -> Dictionary:
	var cell := float(doc.get("cell", 8.0))
	var at: Array = door["at"]
	var x := float(at[0]) * cell
	var z := float(at[1]) * cell
	var floor_index := int(door.get("floor", 0))
	var normal := Vector3.ZERO

	if is_equal_approx(x, a.position.x):
		normal = Vector3(-1, 0, 0)
	elif is_equal_approx(x, a.end.x):
		normal = Vector3(1, 0, 0)
	elif is_equal_approx(z, a.position.y):
		normal = Vector3(0, 0, -1)
	elif is_equal_approx(z, a.end.y):
		normal = Vector3(0, 0, 1)
	else:
		return {}

	var across_x := absf(normal.x) > 0.5
	var along := z if across_x else x
	var half := DOOR_WIDTH * 0.5

	if along - half < (a.position.y if across_x else a.position.x) - 0.01 or along + half > (a.end.y if across_x else a.end.x) + 0.01:
		return {}

	if not _spans_floor(rooms[str(door["a"])], floor_index):
		return {}

	var b_id := str(door.get("b", ""))

	if b_id != "":
		if not rooms.has(b_id) or not _spans_floor(rooms[b_id], floor_index):
			return {}

		var b: Rect2 = rooms[b_id]["rect"]
		var line := b.position.x if normal.x > 0.5 else (b.end.x if normal.x < -0.5 else (b.position.y if normal.z > 0.5 else b.end.y))

		if not is_equal_approx(line, x if across_x else z):
			return {}

		if along - half < (b.position.y if across_x else b.position.x) - 0.01 or along + half > (b.end.y if across_x else b.end.x) + 0.01:
			return {}

	return {"centre": Vector3(x, float(floor_index) * storey(), z), "normal": normal, "doc": door, "body": null}


func _room_point(room_id: String, at: Variant) -> Vector3:
	var rect: Rect2 = rooms[room_id]["rect"]
	var f: Array = at if at is Array else [0.5, 0.5]
	var point := Vector3(rect.position.x + rect.size.x * float(f[0]), 0.0, rect.position.y + rect.size.y * float(f[1]))
	point.y = floor_at(room_id, point)
	return point


## The height of the floor you stand on at [param local] in [param room_id]: the room's floor,
## or in a stairwell its foot landing, the ramp, or its head landing.
func floor_at(room_id: String, local: Vector3) -> float:
	var room: Dictionary = rooms[room_id]
	var base := room_base(room_id)

	if str(room["kind"]) != "stair":
		return base

	var cell := float(doc.get("cell", 8.0))
	var run := _stair_length(room) - cell * 2.0
	return base + clampf((_along_stair(room, local) - cell) / maxf(run, 0.01), 0.0, 1.0) * storey()


func _stair_length(room: Dictionary) -> float:
	var rect: Rect2 = room["rect"]
	return rect.size.x if str(room["doc"].get("up", "e")) in ["e", "w"] else rect.size.y


## Metres from a stairwell's foot wall to [param local], up the stairs.
func _along_stair(room: Dictionary, local: Vector3) -> float:
	var rect: Rect2 = room["rect"]
	match str(room["doc"].get("up", "e")):
		"e":
			return local.x - rect.position.x
		"w":
			return rect.end.x - local.x
		"s":
			return local.z - rect.position.y
		_:
			return rect.end.y - local.z


## The middle of a stairwell's ramp at its foot ([param head] false) or its head, on the ramp.
func stair_point(room_id: String, head: bool) -> Vector3:
	var room: Dictionary = rooms[room_id]
	var rect: Rect2 = room["rect"]
	var cell := float(doc.get("cell", 8.0))
	var s := _stair_length(room) - cell if head else cell
	var centre := rect.get_center()
	var point: Vector3
	match str(room["doc"].get("up", "e")):
		"e":
			point = Vector3(rect.position.x + s, 0.0, centre.y)
		"w":
			point = Vector3(rect.end.x - s, 0.0, centre.y)
		"s":
			point = Vector3(centre.x, 0.0, rect.position.y + s)
		_:
			point = Vector3(centre.x, 0.0, rect.end.y - s)
	point.y = room_base(room_id) + (storey() if head else 0.0)
	return point


func room_centre(room_id: String) -> Vector3:
	return _room_point(room_id, [0.5, 0.5])


## The start room's id.
func spawn_room() -> String:
	for room_id: String in rooms:
		if bool(rooms[room_id]["doc"].get("spawn", false)):
			return room_id

	return str(doc["rooms"][0]["id"])


## Where player [param slot] is put down in the start room, local to the level.
func spawn_point(slot: int) -> Vector3:
	var rect: Rect2 = rooms[spawn_room()]["rect"]
	var ring := float(slot % 8) / 8.0 * TAU
	var radius := minf(rect.size.x, rect.size.y) * 0.25 * float(1 + slot / 8 % 2)
	return Vector3(rect.get_center().x + cos(ring) * radius, room_base(spawn_room()) + 0.1, rect.get_center().y + sin(ring) * radius)


## The room [param local] is in, or "". Each room owns the height from a little under its floor
## to a little under the floor above its top, so floors one over the other never both claim a
## point, and a body standing on a floor (or a point on it) is in that floor's room.
func room_at(local: Vector3) -> String:
	var high := storey()

	for room_id: String in rooms:
		var room: Dictionary = rooms[room_id]

		if not (room["rect"] as Rect2).grow(0.05).has_point(Vector2(local.x, local.z)):
			continue

		var base := float(room["floor"]) * high

		if local.y >= base - 0.9 and local.y < base + float(room["floors"]) * high - 0.9:
			return room_id

	return ""


## Whether [param local] is through the exit doorway and out of the house.
func is_out(local: Vector3) -> bool:
	var exit: Dictionary = doors.get("exit", {})

	if exit.is_empty():
		return false

	var past: float = (local - (exit["centre"] as Vector3)).dot(exit["normal"])
	return past > 0.6 and room_at(local) == ""


# --- Witches -----------------------------------------------------------------

func _witch_loop(witch: Dictionary) -> Dictionary:
	# A stairwell on her walk is the ramp, walked from the end she comes in at: kept as its id
	# until the points either side of it are known.
	var raw: Array = []

	for step: Array in witch["path"]:
		match str(step[0]):
			"room":
				var room_id := str(step[1])
				raw.append(room_id if str(rooms[room_id]["kind"]) == "stair" else room_centre(room_id))
			"door":
				raw.append(doors[str(step[1])]["centre"])
			"at":
				raw.append(_room_point(str(step[1]), [step[2], step[3]]))

	var points := PackedVector3Array()

	for i in raw.size():
		if raw[i] is Vector3:
			points.append(raw[i])
			continue

		var room_id: String = raw[i]
		var middle := room_base(room_id) + storey() * 0.5
		var before: Variant = raw[(i - 1 + raw.size()) % raw.size()]
		var after: Variant = raw[(i + 1) % raw.size()]
		var from_below := not (before is Vector3) or (before as Vector3).y < middle
		var to_below := not (after is Vector3) or (after as Vector3).y < middle
		var first := stair_point(room_id, not from_below)
		points.append(first)
		points.append(stair_point(room_id, from_below))

		# In and back out the same end: down again.
		if from_below == to_below:
			points.append(first)

	var lengths := PackedFloat32Array()
	var total := 0.0

	for i in points.size():
		var leg := points[i].distance_to(points[(i + 1) % points.size()])
		lengths.append(leg)
		total += leg

	return {
		"points": points, "lengths": lengths, "total": maxf(total, 0.01),
		"speed": float(witch.get("speed", 1.6)), "sight": float(witch.get("sight", 10.0)), "cone": float(witch.get("cone", 70.0)),
	}


## Where witch [param index] is at [param seconds]: {"at", "facing" (radians), "head" (radians,
## added to facing)}. Local to the level. [param speed_scale] is the server's scaling.
func witch_pose(index: int, seconds: float, speed_scale: float = 1.0, sweep: bool = true) -> Dictionary:
	var loop: Dictionary = witches[index]
	var points: PackedVector3Array = loop["points"]
	var lengths: PackedFloat32Array = loop["lengths"]
	var along := fmod(seconds * float(loop["speed"]) * speed_scale + float(index) * 7.3, float(loop["total"]))
	var i := 0

	while i < lengths.size() - 1 and along > lengths[i]:
		along -= lengths[i]
		i += 1

	var a := points[i]
	var b := points[(i + 1) % points.size()]
	var t := clampf(along / maxf(lengths[i], 0.001), 0.0, 1.0)
	var dir := (b - a)
	var facing := atan2(-dir.x, -dir.z) if dir.length_squared() > 0.0001 else 0.0
	var head := sin(seconds * 0.8 + float(index)) * deg_to_rad(35.0) if sweep else 0.0
	return {"at": a.lerp(b, t), "facing": facing, "head": head}


# --- Geometry ----------------------------------------------------------------

func _material(key: String, colour: Color, emission: float = 0.0) -> StandardMaterial3D:
	if _materials.has(key):
		return _materials[key]

	var m := StandardMaterial3D.new()
	m.albedo_color = colour
	m.roughness = 0.9

	if emission > 0.0:
		m.emission_enabled = true
		m.emission = colour
		m.emission_energy_multiplier = emission

	_materials[key] = m
	return m


func _box(parent: Node, size: Vector3, at: Vector3, material: Material, solid: bool) -> Node3D:
	var node: Node3D

	if solid:
		var body := StaticBody3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		var collider := CollisionShape3D.new()
		collider.shape = shape
		body.add_child(collider)
		node = body
	else:
		node = Node3D.new()

	if draws:
		var mesh := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = size
		mesh.mesh = box
		mesh.material_override = material
		node.add_child(mesh)

	parent.add_child(node)
	node.position = at
	return node


const WALLPAPERS := [Color(0.32, 0.26, 0.24), Color(0.24, 0.27, 0.25), Color(0.27, 0.25, 0.3), Color(0.3, 0.29, 0.24)]


func _build_room(room_id: String) -> void:
	var room: Dictionary = rooms[room_id]
	var rect: Rect2 = room["rect"]
	var height := float(doc.get("height", 3.2))
	var base := room_base(room_id)
	var floors := int(room["floors"])
	var top := base + float(floors - 1) * storey()
	var root := Node3D.new()
	root.name = "Room_%s" % room_id
	# What a render from above hides to look at one floor: every room whose top is over it.
	root.set_meta(&"floor", int(room["floor"]))
	root.set_meta(&"top_floor", int(room["floor"]) + floors - 1)
	add_child(root)
	var floor_mat := _material("floor", Color(0.22, 0.17, 0.13))
	var paper: Color = WALLPAPERS[room_id.hash() % WALLPAPERS.size()]
	var wall_mat := _material("wall_%d" % (room_id.hash() % WALLPAPERS.size()), paper)
	var centre := rect.get_center()
	_box(root, Vector3(rect.size.x, SLAB, rect.size.y), Vector3(centre.x, base - SLAB * 0.5, centre.y), floor_mat, true)
	var ceiling := _box(root, Vector3(rect.size.x, SLAB, rect.size.y), Vector3(centre.x, top + height + SLAB * 0.5, centre.y), _material("ceiling", Color(0.12, 0.11, 0.1)), true)
	ceiling.name = "Ceiling"

	# A wall a storey at a time, each cut for the doors on that storey; every storey but the
	# top runs up through the slabs to the next.
	for storey_index in floors:
		var bottom := base + float(storey_index) * storey()
		var band := storey() if storey_index < floors - 1 else height

		for side in ["n", "s", "w", "e"]:
			_build_wall(root, rect, side, bottom, band, wall_mat)

	if str(room["kind"]) == "stair":
		_build_stair(root, room_id)
	elif str(room["kind"]) == "room":
		# A corridor is left bare: furniture down both walls of a 4 m passage leaves no passage.
		for side in ["n", "s", "w", "e"]:
			_furnish(root, room_id, rect, side)

	var light := float(room["doc"].get("light", 0.0))

	# Lamps every couple of cells, so a big lit room is lit all over: one lamp in the middle of
	# the lobby left its corners as dark as the house (the first render).
	if draws and light > 0.0:
		var spacing := 12.0
		var across := maxi(int(round(rect.size.x / spacing)), 1)
		var down := maxi(int(round(rect.size.y / spacing)), 1)
		var list: Array = []

		for i in across:
			for j in down:
				var lamp := OmniLight3D.new()
				lamp.light_color = Color(1.0, 0.8, 0.55)
				lamp.light_energy = light * 2.4
				lamp.omni_range = 12.8
				lamp.position = Vector3(rect.position.x + rect.size.x * (float(i) + 0.5) / float(across), top + height - 0.4,
					rect.position.y + rect.size.y * (float(j) + 0.5) / float(down))
				root.add_child(lamp)
				var bulb := _box(root, Vector3(0.3, 0.2, 0.3), lamp.position + Vector3(0, 0.25, 0), _material("bulb", Color(1.0, 0.85, 0.6), 2.0), false)
				list.append({"light": lamp, "bulb": bulb, "energy": lamp.light_energy})

		lamps[room_id] = list

	# A room's name is on the wall over each of its doors, seen from the room you are leaving
	# ([method _build_door]): it used to hang in mid-air in the middle of the room, a billboard
	# turning to follow you (the first play test).


## A label in the world fades out as the eye comes within [param near] metres of it, and
## beyond [param far]. At eye height a painted "Door" a player walks up to filled the screen
## (Christian's first play test), and within reach the HUD's prompt says what it is anyway; a
## sign read from across a level is a sign nobody needs.
static func _fade_up_close(label: Label3D, near: float, far: float = 0.0) -> void:
	label.visibility_range_begin = near
	label.visibility_range_begin_margin = near * 0.4
	if far > 0.0:
		label.visibility_range_end = far
		label.visibility_range_end_margin = far * 0.3
	label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


## Furniture along one wall: something to hide behind, as solid to a witch's sight as the
## wall. Never in front of a door, and never further from the wall than an item is ever put
## (items are at least a fifth of a cell in), so nothing a level needs is ever behind it.
## Placed from a hash of the level, room and slot, so every machine furnishes alike.
func _furnish(root: Node, room_id: String, rect: Rect2, side: String) -> void:
	var name_text := str(rooms[room_id]["doc"].get("name", "")).to_lower()
	var theme := "store"

	for word: String in ROOM_THEMES:
		if name_text.contains(word):
			theme = ROOM_THEMES[word]
			break

	var choices: Array = FURNITURE[theme]
	var base := room_base(room_id)
	var along_x := side == "n" or side == "s"
	var start := rect.position.x if along_x else rect.position.y
	var end := rect.end.x if along_x else rect.end.y
	var edge := rect.position.y if side == "n" else (rect.end.y if side == "s" else (rect.position.x if side == "w" else rect.end.x))
	var inward := {"n": Vector3(0, 0, 1), "s": Vector3(0, 0, -1), "w": Vector3(1, 0, 0), "e": Vector3(-1, 0, 0)}[side] as Vector3
	var facing := {"n": 0.0, "s": PI, "w": PI * 0.5, "e": -PI * 0.5}[side] as float
	var slot := 0
	var cursor := start + 1.4

	while cursor < end - 1.4:
		var roll := LmWeatherHash.unit("%s|%s|%s|%d" % [doc.get("id", ""), room_id, side, slot])
		var clear := true

		for door_id: String in doors:
			var c: Vector3 = doors[door_id]["centre"]

			if absf((c.z if along_x else c.x) - edge) < 0.05 and absf((c.x if along_x else c.z) - cursor) < 1.9 and absf(c.y - base) < 0.1:
				clear = false

		if clear and roll < 0.42:
			var model := str(choices[int(roll * 1000.0) % choices.size()])
			var at := Vector3(cursor, base, edge) if along_x else Vector3(edge, base, cursor)
			_place_furniture(root, model, at, inward, facing)

		cursor += 2.4
		slot += 1


func _place_furniture(root: Node, model: String, wall_point: Vector3, inward: Vector3, facing: float) -> void:
	if not _furniture_scenes.has(model):
		var path := LmPaths.rebase("res://assets/kenney/furniture/%s.glb" % model)
		_furniture_scenes[model] = load(path) if ResourceLoader.exists(path) else null

	var packed: PackedScene = _furniture_scenes[model]

	if packed == null:
		return

	# The bounds once per model: a house three times the size instances a model only to read
	# its size several thousand times on a server that draws nothing.
	if not _furniture_bounds.has(model):
		var probe := packed.instantiate() as Node3D
		_furniture_bounds[model] = _bounds_of(probe)
		probe.free()

	var bounds: AABB = _furniture_bounds[model]
	var size := bounds.size * FURNITURE_SCALE

	# Deeper than the band items never enter: left out rather than let it hide a key.
	if minf(size.x, size.z) > 1.4:
		return

	var piece: Node3D = packed.instantiate() as Node3D if draws else null

	if piece != null:
		piece.scale = Vector3.ONE * FURNITURE_SCALE

	var depth := size.z
	var body := StaticBody3D.new()
	body.name = "Furniture_%s" % model
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, size.y, size.z)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.position = Vector3(0, size.y * 0.5, 0)
	body.add_child(collider)

	if piece != null:
		# The model's own origin is not its centre: put its bounds' centre on the body's.
		var centre := bounds.get_center() * FURNITURE_SCALE
		piece.position = Vector3(-centre.x, -bounds.position.y * FURNITURE_SCALE, -centre.z)
		body.add_child(piece)

	root.add_child(body)
	body.rotation.y = facing
	body.position = wall_point + inward * (WALL + depth * 0.5 + 0.05)


static func _bounds_of(node: Node3D) -> AABB:
	var out := AABB()
	var first := true

	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D

		if mesh.mesh == null:
			continue

		var xf := Transform3D.IDENTITY
		var walk: Node = mesh

		while walk != null and walk != node:
			xf = (walk as Node3D).transform * xf if walk is Node3D else xf
			walk = walk.get_parent()

		var box := xf * mesh.mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false

	return out if not first else AABB(Vector3(-0.2, 0, -0.2), Vector3(0.4, 0.4, 0.4))


## One wall of one storey, from [param bottom] up [param height], cut wherever a door on that
## storey sits on it. Inset by [constant WALL] so two rooms that share a wall each have their
## own face, back to back, and never fight over one.
func _build_wall(root: Node, rect: Rect2, side: String, bottom: float, height: float, material: Material) -> void:
	var along_x := side == "n" or side == "s"
	var fixed: float
	match side:
		"n": fixed = rect.position.y + WALL * 0.5
		"s": fixed = rect.end.y - WALL * 0.5
		"w": fixed = rect.position.x + WALL * 0.5
		_: fixed = rect.end.x - WALL * 0.5
	var start := rect.position.x if along_x else rect.position.y
	var end := rect.end.x if along_x else rect.end.y
	var gaps: Array[float] = []
	var edge := rect.position.y if side == "n" else (rect.end.y if side == "s" else (rect.position.x if side == "w" else rect.end.x))

	for door_id: String in doors:
		var c: Vector3 = doors[door_id]["centre"]
		var on := absf((c.z if along_x else c.x) - edge) < 0.01 and absf(c.y - bottom) < 0.1
		var within := (c.x if along_x else c.z) > start and (c.x if along_x else c.z) < end

		if on and within:
			gaps.append(c.x if along_x else c.z)

	gaps.sort()
	var cursor := start
	var half := DOOR_WIDTH * 0.5

	for gap in gaps:
		_wall_piece(root, along_x, fixed, cursor, gap - half, bottom, bottom + height, material)
		_wall_piece(root, along_x, fixed, gap - half, gap + half, bottom + DOOR_HEIGHT, bottom + height, material)
		cursor = gap + half

	_wall_piece(root, along_x, fixed, cursor, end, bottom, bottom + height, material)


## A stairwell's insides: a ramp from its foot landing up to its head, and under the head
## landing solid stone, so there is nothing to walk under. 25 degrees, well inside what the
## controller walks up (46).
func _build_stair(root: Node, room_id: String) -> void:
	var room: Dictionary = rooms[room_id]
	var rect: Rect2 = room["rect"]
	var cell := float(doc.get("cell", 8.0))
	var length := _stair_length(room)
	var up := str(room["doc"].get("up", "e"))
	var along_x := up == "e" or up == "w"
	var width := (rect.size.y if along_x else rect.size.x) - WALL * 2.0
	var run := length - cell * 2.0
	var rise := storey()
	var base := room_base(room_id)
	var dir: Vector3 = {"e": Vector3(1, 0, 0), "w": Vector3(-1, 0, 0), "s": Vector3(0, 0, 1), "n": Vector3(0, 0, -1)}[up]
	var foot := Vector3(rect.get_center().x, base, rect.get_center().y) - dir * length * 0.5
	var yaw := atan2(-dir.z, dir.x)
	var stone := _material("stair", Color(0.2, 0.16, 0.12))

	# The ramp: a wedge rising along local +x, turned to climb the way the stairs go.
	var ramp := StaticBody3D.new()
	ramp.name = "Ramp"
	var shape := ConvexPolygonShape3D.new()
	var hx := run * 0.5
	var hy := rise * 0.5
	var hz := width * 0.5
	shape.points = PackedVector3Array([
		Vector3(-hx, -hy, -hz), Vector3(-hx, -hy, hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz),
		Vector3(hx, hy, -hz), Vector3(hx, hy, hz),
	])
	var collider := CollisionShape3D.new()
	collider.shape = shape
	ramp.add_child(collider)

	if draws:
		var mesh := MeshInstance3D.new()
		var prism := PrismMesh.new()
		prism.size = Vector3(run, rise, width)
		prism.left_to_right = 1.0
		mesh.mesh = prism
		mesh.material_override = stone
		ramp.add_child(mesh)

	root.add_child(ramp)
	ramp.position = foot + dir * (cell + run * 0.5) + Vector3(0, hy, 0)
	ramp.rotation.y = yaw

	var landing := _box(root, Vector3(cell, rise, width), Vector3.ZERO, stone, true)
	landing.name = "HeadLanding"
	landing.position = foot + dir * (length - cell * 0.5) + Vector3(0, hy, 0)
	landing.rotation.y = yaw


func _wall_piece(root: Node, along_x: bool, fixed: float, from: float, to: float, bottom: float, top: float, material: Material) -> void:
	if to - from < 0.01 or top - bottom < 0.01:
		return

	var size := Vector3(to - from, top - bottom, WALL) if along_x else Vector3(WALL, top - bottom, to - from)
	var mid := (from + to) * 0.5
	var at := Vector3(mid, (bottom + top) * 0.5, fixed) if along_x else Vector3(fixed, (bottom + top) * 0.5, mid)
	_box(root, size, at, material, true)


const DOOR_COLOURS := {
	"red": Color(0.6, 0.12, 0.1), "blue": Color(0.12, 0.2, 0.6), "green": Color(0.12, 0.45, 0.16),
	"yellow": Color(0.75, 0.62, 0.12), "purple": Color(0.4, 0.15, 0.5), "orange": Color(0.75, 0.38, 0.1),
	"white": Color(0.8, 0.8, 0.78), "black": Color(0.07, 0.07, 0.08), "gold": Color(0.85, 0.65, 0.15),
	"brown": Color(0.3, 0.19, 0.11), "wood": Color(0.42, 0.3, 0.18), "steel": Color(0.45, 0.48, 0.52), "iron": Color(0.2, 0.2, 0.22),
}


func _build_door(door_id: String) -> void:
	var door: Dictionary = doors[door_id]
	var normal: Vector3 = door["normal"]
	var size := Vector3(DOOR_WIDTH, DOOR_HEIGHT, WALL * 2.0) if absf(normal.z) > 0.5 else Vector3(WALL * 2.0, DOOR_HEIGHT, DOOR_WIDTH)
	var colour: Color = DOOR_COLOURS.get(str(door["doc"].get("colour", "brown")), Color(0.3, 0.19, 0.11))
	var body := _box(self, size, (door["centre"] as Vector3) + Vector3(0, DOOR_HEIGHT * 0.5, 0), _material("door_" + str(door["doc"].get("colour", "")), colour), true)
	body.name = "Door_%s" % door_id
	door["body"] = body

	if not draws:
		return

	var exit := bool(door["doc"].get("exit", false)) or str(door["doc"].get("b", "")) == ""

	for face in [-1.0, 1.0]:
		var turned := atan2(normal.x, normal.z) + (PI if face < 0.0 else 0.0)
		# What the door is, painted small on it: only a locked door's says anything ("Red
		# door", "The way out"); a plain one is a door.
		var what := str(door["doc"].get("label", "Door"))
		if what != "Door":
			var label := Label3D.new()
			label.text = what
			label.font_size = 32
			label.pixel_size = 0.0035
			label.modulate = Color(0.95, 0.9, 0.8, 0.9)
			label.outline_size = 6
			label.position = normal * face * (WALL + 0.02) + Vector3(0, 0.35, 0)
			label.rotation.y = turned
			_fade_up_close(label, 1.2, 9.0)
			body.add_child(label)

		# Over the door, on the wall, a plaque with the name of the room it leads into, as
		# seen from the room you are in. In front of the wall's face: each room builds its own
		# wall inside its edge, a whole WALL deep.
		if exit and face > 0.0:
			continue
		var into := str(door["doc"].get("a", "")) if face > 0.0 else str(door["doc"].get("b", ""))
		var named := "Out" if exit else str(rooms.get(into, {}).get("doc", {}).get("name", ""))
		if named == "":
			continue
		var plaque_at: Vector3 = (door["centre"] as Vector3) + normal * face * (WALL + 0.02) + Vector3(0, DOOR_HEIGHT + 0.32, 0)
		var plaque := _box(self, Vector3(DOOR_WIDTH * 0.8, 0.24, 0.02) if absf(normal.z) > 0.5 else Vector3(0.02, 0.24, DOOR_WIDTH * 0.8),
			plaque_at, _material("plaque", Color(0.12, 0.09, 0.07)), false)
		plaque.name = "Plaque_%s_%s" % [door_id, "b" if face > 0.0 else "a"]
		var sign := Label3D.new()
		sign.name = "Name"
		sign.text = named
		sign.font_size = 56
		sign.pixel_size = 0.0022
		sign.modulate = Color(0.86, 0.78, 0.6, 0.85)
		sign.outline_size = 0
		sign.position = normal * face * 0.015
		sign.rotation.y = turned
		_fade_up_close(sign, 0.0, 11.0)
		plaque.add_child(sign)


## The door's body, for a player's exclusion list.
func door_rid(door_id: String) -> RID:
	var body: Variant = doors.get(door_id, {}).get("body")
	return (body as CollisionObject3D).get_rid() if body is CollisionObject3D else RID()


func _build_item(item: Dictionary, at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Item_%s" % item["id"]
	add_child(root)
	root.position = at

	if not draws:
		return root

	# A little stand, so a thing on the floor of a dark room can be found by a flashlight.
	_box(root, Vector3(0.5, 0.8, 0.5), Vector3(0, 0.4, 0), _material("stand", Color(0.25, 0.2, 0.16)), false)
	var colour: Color = DOOR_COLOURS.get(str(item.get("colour", "")), Color(0.75, 0.72, 0.65))
	var size: Vector3 = {"key": Vector3(0.28, 0.06, 0.1), "bucket": Vector3(0.35, 0.35, 0.35), "crowbar": Vector3(0.8, 0.05, 0.06),
		"note": Vector3(0.25, 0.01, 0.18), "fuse": Vector3(0.1, 0.1, 0.22), "screwdriver": Vector3(0.3, 0.04, 0.04),
		"smallkey": Vector3(0.14, 0.04, 0.06)}.get(str(item.get("kind", "")), Vector3(0.2, 0.2, 0.2))
	_box(root, size, Vector3(0, 0.82 + size.y * 0.5, 0), _material("item_" + str(item.get("kind", "")) + str(item.get("colour", "")), colour, 0.6), false)
	return root


func _build_station(station: Dictionary, at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Station_%s" % station["id"]
	add_child(root)
	root.position = at

	if not draws:
		return root

	match str(station.get("kind", "")):
		"fire":
			_box(root, Vector3(1.2, 1.4, 0.6), Vector3(0, 0.7, 0), _material("fire", Color(1.0, 0.45, 0.1), 3.0), false)
			var glow := OmniLight3D.new()
			glow.light_color = Color(1.0, 0.5, 0.2)
			glow.light_energy = 1.5
			glow.omni_range = 6.0
			glow.position = Vector3(0, 1.2, 0)
			root.add_child(glow)
		"tap":
			_box(root, Vector3(0.9, 0.9, 0.5), Vector3(0, 0.45, 0), _material("sink", Color(0.8, 0.8, 0.78)), false)
		"lever":
			_box(root, Vector3(0.3, 1.0, 0.2), Vector3(0, 0.5, 0), _material("iron", Color(0.2, 0.2, 0.22)), false)
			_box(root, Vector3(0.06, 0.6, 0.06), Vector3(0, 1.2, 0), _material("handle", Color(0.7, 0.1, 0.1), 0.5), false)
		"fusebox":
			_box(root, Vector3(0.6, 0.8, 0.25), Vector3(0, 1.3, 0), _material("fusebox", Color(0.4, 0.42, 0.38)), false)
		"vent":
			_box(root, Vector3(0.7, 0.5, 0.1), Vector3(0, 0.4, 0), _material("vent", Color(0.55, 0.55, 0.55)), false)
		"chest":
			_box(root, Vector3(1.0, 0.6, 0.6), Vector3(0, 0.3, 0), _material("chest", Color(0.36, 0.22, 0.12)), false)
			_box(root, Vector3(1.04, 0.08, 0.64), Vector3(0, 0.62, 0), _material("iron", Color(0.2, 0.2, 0.22)), false)
		_:
			_box(root, Vector3(0.5, 0.5, 0.5), Vector3(0, 0.25, 0), _material("thing", Color(0.5, 0.5, 0.5)), false)

	return root


## Puts a room's lamps at [param fraction] of their brightness: 0 is out, bulbs and all. A
## client's, for the lights-fail event; a server has no lamps.
func set_room_light(room_id: String, fraction: float) -> void:
	for lamp: Dictionary in lamps.get(room_id, []):
		(lamp["light"] as OmniLight3D).light_energy = float(lamp["energy"]) * fraction
		(lamp["bulb"] as Node3D).visible = fraction > 0.25


## How many floors the level has, counting a stairwell's head.
func floor_count() -> int:
	var top := 0
	for room_id: String in rooms:
		top = maxi(top, int(rooms[room_id]["floor"]) + int(rooms[room_id]["floors"]) - 1)
	return top + 1


## Floor area in square metres, a stairwell counted once per storey.
func floor_area() -> float:
	var area := 0.0
	for room_id: String in rooms:
		area += (rooms[room_id]["rect"] as Rect2).get_area() * float(rooms[room_id]["floors"])
	return area


func describe() -> Dictionary:
	return {
		"id": str(doc.get("id", "")), "number": number(), "name": str(doc.get("name", "")),
		"rooms": rooms.size(), "floors": floor_count(), "area": int(floor_area()), "doors": doors.size(),
		"items": items.size(), "stations": stations.size(), "witches": witches.size(),
		"steps": (doc.get("steps", []) as Array).size(), "events": events.size(),
	}
