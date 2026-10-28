extends "lm_level_geometry.gd"

## The pieces a level is drawn from: materials, boxes, walls, stairs, doors, items and stations.


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


## A [method _material] with one of [LmSurfaces]'s textures laid on in world space ([param metres]
## across one tile), mipmapped and filtered anisotropically, offset by [param shift] so rooms
## sharing a texture do not share its pattern. Without drawing there is nothing to texture.
func _surface(key: String, colour: Color, kind: String, metres: float, shift: float) -> StandardMaterial3D:
	var full := "%s|%s|%.2f" % [key, kind, shift]

	if _materials.has(full):
		return _materials[full]

	var m := _material(full, colour)

	if draws and OS.get_environment("LM_FLAT") == "":
		m.albedo_texture = LmSurfaces.texture(kind)
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		m.texture_repeat = true
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3.ONE / metres
		m.uv1_offset = Vector3(shift, shift * 0.37, shift * 0.71)

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


## A label in the world fades out as the eye comes within [param near] metres, and beyond [param far]:
## a painted "Door" at eye height filled the screen, and the HUD prompt names it within reach.
static func _fade_up_close(label: Label3D, near: float, far: float = 0.0) -> void:
	label.visibility_range_begin = near
	label.visibility_range_begin_margin = near * 0.4
	if far > 0.0:
		label.visibility_range_end = far
		label.visibility_range_end_margin = far * 0.3
	label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


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


func _build_item(item: Dictionary, at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Item_%s" % item["id"]
	# Picked up at arm's length by interacting, never collided with: a solid stand would block
	# the room's walk lanes (the builder proves them clear) and the witches' paths.
	root.set_meta(DotCollisionAudit.META, true)
	add_child(root)
	root.position = at

	if not draws:
		return root

	# A little stand, so a thing on the floor of a dark room can be located with a flashlight.
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
	# Used by interacting from beside it; the builder keeps its surroundings clear and it is
	# passable by design, as the witches' lanes may cross it.
	root.set_meta(DotCollisionAudit.META, true)
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
