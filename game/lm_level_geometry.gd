extends Node3D

## A level's data and its geometry questions: floors, stairwells, rooms, spawns and where a witch is.



const LmPaths := preload("lm_paths.gd")
const LmWeatherHash := preload("lm_hash.gd")
const LmSurfaces := preload("lm_surfaces.gd")

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


## Whether the document's furniture is built (`lm_furniture_enabled`). It is collision as well
## as a drawing, so a server and its clients must agree.
var furnished: bool = true


var _materials: Dictionary = {}


## Seconds a door a witch opened stays open after she leaves the doorway, before it closes.
const DOOR_HELD := 2.0




const WALLPAPERS := [Color(0.32, 0.26, 0.24), Color(0.24, 0.27, 0.25), Color(0.27, 0.25, 0.3), Color(0.3, 0.29, 0.24)]


const DOOR_COLOURS := {
	"red": Color(0.6, 0.12, 0.1), "blue": Color(0.12, 0.2, 0.6), "green": Color(0.12, 0.45, 0.16),
	"yellow": Color(0.75, 0.62, 0.12), "purple": Color(0.4, 0.15, 0.5), "orange": Color(0.75, 0.38, 0.1),
	"white": Color(0.8, 0.8, 0.78), "black": Color(0.07, 0.07, 0.08), "gold": Color(0.85, 0.65, 0.15),
	"brown": Color(0.3, 0.19, 0.11), "wood": Color(0.42, 0.3, 0.18), "steel": Color(0.45, 0.48, 0.52), "iron": Color(0.2, 0.2, 0.22),
}


func number() -> int:
	return int(doc.get("number", 0))


## Metres from one floor to the next: a room's height and two slabs, the ceiling of the room
## below and the floor of the one above, one over the other (two boxes in one place flicker).
func storey() -> float:
	return float(doc.get("storey", float(doc.get("height", 3.2)) + SLAB * 2.0))


## The height of [param room_id]'s floor, local to the level.
func room_base(room_id: String) -> float:
	return float(rooms[room_id]["floor"]) * storey()


func _spans_floor(room: Dictionary, floor_index: int) -> bool:
	return floor_index >= int(room["floor"]) and floor_index < int(room["floor"]) + int(room["floors"])


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




## Where witch [param index] is at [param seconds], local to the level: {"at", "facing", "head",
## "door", "open" (0 to 1)}. [param dwell] is the seconds she stands at each doorway; the walk stays
## a pure function of time. A door stays open a couple of seconds after she passes.
func witch_pose(index: int, seconds: float, speed_scale: float = 1.0, sweep: bool = true, dwell: float = 0.0) -> Dictionary:
	var loop: Dictionary = witches[index]
	var points: PackedVector3Array = loop["points"]
	var lengths: PackedFloat32Array = loop["lengths"]
	var door_ids: Array = loop["door_ids"]
	var v := maxf(float(loop["speed"]) * speed_scale, 0.001)
	var stops := 0

	if dwell > 0.0:
		for id: String in door_ids:
			if id != "":
				stops += 1

	var cycle := float(loop["total"]) / v + float(stops) * dwell
	var u := fmod(seconds + float(index) * 7.3 / v, cycle)
	var i := 0
	var at := points[0]
	var door := ""
	var open := 0.0

	while true:
		var here := dwell if (dwell > 0.0 and door_ids[i] != "") else 0.0
		var a := points[i]
		var b := points[(i + 1) % points.size()]

		if u < here:
			at = a
			door = door_ids[i]
			open = smoothstep(0.0, here * 0.5, u)
			break

		u -= here
		var leg := lengths[i] / v

		if u <= leg or i >= lengths.size() - 1:
			at = a.lerp(b, clampf(u * v / maxf(lengths[i], 0.001), 0.0, 1.0))

			if here > 0.0:
				door = door_ids[i]
				open = clampf(DOOR_HELD + 1.0 - u, 0.0, 1.0) if u > DOOR_HELD else 1.0

			break

		u -= leg
		i += 1

	var dir := points[(i + 1) % points.size()] - points[i]
	var facing := atan2(-dir.x, -dir.z) if dir.length_squared() > 0.0001 else 0.0
	var head := sin(seconds * 0.8 + float(index)) * deg_to_rad(35.0) if sweep else 0.0
	return {"at": at, "facing": facing, "head": head, "door": door if open > 0.0 else "", "open": open}


## The door's body, for a player's exclusion list.
func door_rid(door_id: String) -> RID:
	var body: Variant = doors.get(door_id, {}).get("body")
	return (body as CollisionObject3D).get_rid() if body is CollisionObject3D else RID()


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
