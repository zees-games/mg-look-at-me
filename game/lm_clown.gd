extends Node3D

## The clown hallucination drawn: the Sketchfab bust (assets/clown/clown.glb, see its CREDITS.md)
## with a jaw bone and two eyeballs, floating. The client's own: it is never sent anywhere and its
## light is a child that only this client's world contains.

const MODEL := "res://assets/clown/clown.glb"
## The bust is 0.9 m; this makes it a head that fills a corner.
const SCALE := 1.7

var _skeleton: Skeleton3D = null
var _jaw := -1
var _eyes: Array[Node3D] = []
var _eye_rest: Array[Basis] = []
var _jitter := Vector2.ZERO
var _jitter_left := 0.0
var _t := 0.0
## 0 closed, 1 wide open: set by the caller, eased here.
var mouth := 0.0
var _mouth_now := 0.0
var _rng := RandomNumberGenerator.new()


func build() -> bool:
	name = "Clown"
	var packed: Resource = load(MODEL) if ResourceLoader.exists(MODEL) else null

	if not packed is PackedScene:
		return false

	var model: Node3D = (packed as PackedScene).instantiate()
	model.scale = Vector3.ONE * SCALE
	add_child(model)
	_skeleton = model.find_child("Skeleton3D", true, false) as Skeleton3D
	_jaw = _skeleton.find_bone("jaw") if _skeleton != null else -1

	for node in model.find_children("Eye*", "MeshInstance3D", true, false):
		_eyes.append(node)
		_eye_rest.append(node.basis)

	for node in model.find_children("*", "MeshInstance3D", true, false):
		_grade(node as MeshInstance3D)

	# A cold rim from above-behind and a dim fill from the front, so it reads in a dark room without
	# lighting the room: short range, no shadows, only this client's tree.
	var rim := OmniLight3D.new()
	rim.name = "Rim"
	rim.light_color = Color(0.55, 0.7, 1.0)
	rim.light_energy = 0.45
	rim.omni_range = 3.2
	rim.position = Vector3(0.35, 1.2, -0.5)
	add_child(rim)
	var fill := OmniLight3D.new()
	fill.name = "Fill"
	fill.light_color = Color(1.0, 0.82, 0.7)
	fill.light_energy = 0.12
	fill.omni_range = 3.0
	fill.position = Vector3(-0.2, 0.9, 1.0)
	add_child(fill)
	_rng.seed = 0xc10e
	return true


## Materials tuned for the dark: matte skin that still shows through the black (a little of its
## own texture as emission) and a wet sheen on the eyes.
func _grade(mesh: MeshInstance3D) -> void:
	for i in mesh.get_surface_override_material_count():
		var mat := mesh.get_active_material(i)

		if mat is BaseMaterial3D:
			var m := (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
			m.roughness = 0.35 if mesh.name.begins_with("Eye") else clampf(m.roughness, 0.55, 0.9)
			m.metallic = 0.0
			m.albedo_color = Color(0.58, 0.56, 0.6)
			m.emission_enabled = true
			m.emission_texture = m.albedo_texture
			m.emission = Color(1, 1, 1)
			m.emission_energy_multiplier = 0.02
			m.rim_enabled = true
			m.rim = 0.2
			m.rim_tint = 0.4
			m.cull_mode = BaseMaterial3D.CULL_DISABLED if mesh.name == "Hair" else m.cull_mode
			mesh.set_surface_override_material(i, m)


## Faces [param target] (world), eyes tracking it with a small jitter, jaw as [member mouth] says.
func watch(target: Vector3, delta: float) -> void:
	_t += delta
	var to := target - global_position
	rotation.y = atan2(to.x, to.z) + sin(_t * 0.7) * 0.06
	rotation.z = sin(_t * 1.3) * 0.05
	_jitter_left -= delta

	if _jitter_left <= 0.0:
		_jitter = Vector2(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * 0.07
		_jitter_left = _rng.randf_range(0.15, 0.6)

	for i in _eyes.size():
		var eye := _eyes[i]
		var local: Vector3 = (eye.get_parent() as Node3D).to_local(target)
		var dir: Vector3 = (local - eye.position).normalized()
		var look := Basis.looking_at(-dir, Vector3.UP).rotated(Vector3.RIGHT, _jitter.y).rotated(Vector3.UP, _jitter.x)
		eye.basis = look.orthonormalized() * Basis.from_scale(_eye_rest[i].get_scale())

	_mouth_now = move_toward(_mouth_now, mouth, delta * 6.0)
	var ajar := 0.06 + 0.04 * sin(_t * 2.1)

	if _skeleton != null and _jaw >= 0:
		var angle := deg_to_rad(35.0) * (_mouth_now if mouth > 0.0 or _mouth_now > 0.0 else 0.0) + ajar * (1.0 - _mouth_now)
		# The bone's rest is turned (it lies along the head's X); swing about the model's X on top of it.
		var rest := _skeleton.get_bone_rest(_jaw).basis.get_rotation_quaternion()
		_skeleton.set_bone_pose_rotation(_jaw, Quaternion(Vector3.RIGHT, -angle) * rest)
