extends "lm_level_parts.gd"

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

## Model id -> PackedScene, loaded once for every level, and its bounds.
static var _furniture_scenes: Dictionary = {}
static var _furniture_bounds: Dictionary = {}


## Drops the shared furniture scenes so a process can exit without leaking them.
static func clear_cache() -> void:
	_furniture_scenes.clear()
	_furniture_bounds.clear()


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

	DotLog.debug(CHANNEL, "the house was built", {"id": str(doc.get("id", "?")), "rooms": rooms.size()})
	return DotResult.success(self)


# --- Placement ---------------------------------------------------------------


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

	# Which of her points are a doorway: she stops there to open the door ([method witch_pose]).
	var door_ids: Array = []

	for point in points:
		var found := ""

		for door_id: String in doors:
			if (doors[door_id]["centre"] as Vector3).is_equal_approx(point):
				found = door_id
				break

		door_ids.append(found)

	return {
		"points": points, "lengths": lengths, "total": maxf(total, 0.01), "door_ids": door_ids,
		"speed": float(witch.get("speed", 1.6)), "sight": float(witch.get("sight", 10.0)), "cone": float(witch.get("cone", 70.0)),
	}


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
	var shift := float(room_id.hash() % 13) / 13.0
	var floor_mat := _surface("floor", Color(0.4, 0.31, 0.24), "floor", 2.0, shift)
	var paper: Color = WALLPAPERS[room_id.hash() % WALLPAPERS.size()]
	# Each room's own paper and its own share of the pattern; the tint is brighter than the old
	# flat colour because the texture carries the darker stripes and stains.
	var wall_mat := _surface("wall_%d" % (room_id.hash() % WALLPAPERS.size()), paper * 1.25, "wall", 2.5, shift)
	var centre := rect.get_center()
	_box(root, Vector3(rect.size.x, SLAB, rect.size.y), Vector3(centre.x, base - SLAB * 0.5, centre.y), floor_mat, true)
	var ceiling := _box(root, Vector3(rect.size.x, SLAB, rect.size.y), Vector3(centre.x, top + height + SLAB * 0.5, centre.y), _surface("ceiling", Color(0.17, 0.155, 0.14), "ceiling", 3.0, shift), true)
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
		if doc.has("props"):
			# The builder placed it, per room type, and proved it clear of every door, item,
			# station and witch's lane (tools/lm_furnish.py).
			if furnished:
				_place_props(root, room_id, rect)
		else:
			# A document from before the builder furnished: the old wall-by-wall hash.
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


## One room's props from the document: `[model, room, x, z, rot]`, the centre in metres from
## the room's corner, plus a height for something standing on another piece (drawn only). The
## sizes come from the document (`models`), the ones the builder proved, never from the mesh.
func _place_props(root: Node, room_id: String, rect: Rect2) -> void:
	var sizes: Dictionary = doc.get("models", {})
	var scale := float(doc.get("prop_scale", FURNITURE_SCALE))
	var base := room_base(room_id)

	for row: Array in doc["props"]:
		if str(row[1]) != room_id:
			continue

		var model := str(row[0])
		var size_a: Array = sizes.get(model, [])

		if size_a.size() < 3:
			continue

		var size := Vector3(float(size_a[0]), float(size_a[1]), float(size_a[2]))
		var lift := float(row[5]) if row.size() > 5 else 0.0
		var body: Node3D = Node3D.new() if lift > 0.0 else StaticBody3D.new()
		body.name = "Furniture_%s" % model
		root.add_child(body)
		body.rotation.y = deg_to_rad(float(row[4]))
		body.position = Vector3(rect.position.x + float(row[2]), base + lift, rect.position.y + float(row[3]))

		if lift <= 0.0:
			var shape := BoxShape3D.new()
			shape.size = size
			var collider := CollisionShape3D.new()
			collider.shape = shape
			collider.position = Vector3(0, size.y * 0.5, 0)
			body.add_child(collider)

		if not draws:
			continue

		var packed := _furniture_scene(model)

		if packed == null:
			continue

		var piece := packed.instantiate() as Node3D
		piece.scale = Vector3.ONE * scale
		var bounds: AABB = _furniture_bounds[model]
		var centre := bounds.get_center() * scale
		piece.position = Vector3(-centre.x, -bounds.position.y * scale, -centre.z)
		body.add_child(piece)


## A model's scene and (once) its bounds; null for a model the kit does not have here.
func _furniture_scene(model: String) -> PackedScene:
	if not _furniture_scenes.has(model):
		var path := LmPaths.rebase("res://assets/kenney/furniture/%s.glb" % model)
		_furniture_scenes[model] = load(path) if ResourceLoader.exists(path) else null

	var packed: PackedScene = _furniture_scenes[model]

	if packed != null and not _furniture_bounds.has(model):
		var probe := packed.instantiate() as Node3D
		_furniture_bounds[model] = _bounds_of(probe)
		probe.free()

	return packed


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


## Puts a room's lamps at [param fraction] of their brightness: 0 is out, bulbs and all. A
## client's, for the lights-fail event; a server has no lamps.
func set_room_light(room_id: String, fraction: float) -> void:
	for lamp: Dictionary in lamps.get(room_id, []):
		(lamp["light"] as OmniLight3D).light_energy = float(lamp["energy"]) * fraction
		(lamp["bulb"] as Node3D).visible = fraction > 0.25


func describe() -> Dictionary:
	return {
		"id": str(doc.get("id", "")), "number": number(), "name": str(doc.get("name", "")),
		"rooms": rooms.size(), "floors": floor_count(), "area": int(floor_area()), "doors": doors.size(),
		"items": items.size(), "stations": stations.size(), "witches": witches.size(),
		"steps": (doc.get("steps", []) as Array).size(), "events": events.size(),
	}
