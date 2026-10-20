extends Node3D

## A witch, drawn: a tall grey corpse in a black skirt and a pointed hat (the Zombie Apocalypse
## Kit's basic zombie, recoloured; tools/make_witch.py), shambling round the loop the clock puts
## her on, her head turning the way her sight turns, and her sight laid on the floor as a red fan.
##
## [b]Only what the server already decides is drawn here, and how it is drawn is the rule a
## player reads.[/b] Where she is and where she looks are [method LmLevel.witch_pose] (Decision 2);
## whether she sees YOU is [method LmGame.exposure], asked by [LmClient] for the local player
## alone. Seeing you, her eyes and the lamp in her face flare, her fan goes from a faint smear to
## a hard red and her arms come up: the meter is filling, and the way out of it is out of the fan.
##
## [b]A creature, not a cone in a hat, and not one of the players' people[/b] (2026-10-12; the
## first play test saw no witch in 36 s, and the one there was a black cylinder). The family's
## people were tried first and drew a cheerful girl in a crop top; the kit's zombie on the same
## rig has a skull's face and reaching arms, and its own clips (walk, idle, attack_idle, attack),
## so nothing is retargeted. The skirt is a cone from the hips to the floor, wide enough that her
## stride stays inside it: she seems to glide.

const CHANNEL := "lookatme.witch"

const LmPaths := preload("lm_paths.gd")

## Taller than the tallest player (1.8 m): something you look up at.
const HEIGHT := 2.2

## Her body: the Zombie Apocalypse Kit's basic zombie (Quaternius, CC0), and its atlas in grey
## and black. tools/make_witch.py makes both from the kit's files in game-zombie-zone.
static var BODY := LmPaths.rebase("res://assets/witch/witch.glb")
static var ATLAS := LmPaths.rebase("res://assets/witch/witch_atlas.png")

## Her skin when the atlas is missing.
const SKIN := Color("9aa293")

## Where her eyes are under the top of her head, and in front of its middle.
const EYE_DROP := -0.36
const EYE_FORWARD := 0.36

## The clips that loop (the kit's are imported once-through).
const LOOPING: Array[StringName] = [&"idle", &"walk", &"run", &"run_arms", &"attack_idle"]

## The fan's alpha: barely there while she walks, hard red while she sees you.
const FAN_IDLE := 0.07
const FAN_SEEING := 0.26

## Her eyes and the lamp in her face, at rest and seeing you.
const EYES_IDLE := 3.0
const EYES_SEEING := 9.0
const GLOW_IDLE := 0.7
const GLOW_SEEING := 2.6

## The body's clip playing now, for the suite and describe().
var clip: StringName = &"":
	get:
		return _clip

## 0 to 1: how much she is seeing the local player now, eased, for the flare.
var seeing: float = 0.0

## Metres walked since the last footfall, for [LmClient]'s steps.
var stride: float = 0.0

## The fan on the floor, turned with her sight. Null on a witch drawn without one.
var fan: MeshInstance3D = null

var _fan_material: StandardMaterial3D = null
var _eyes_material: StandardMaterial3D = null
var _glow: OmniLight3D = null
var _last_at: Vector3 = Vector3.INF
var _head_bone := -1
var _model: Node3D = null
var _skeleton: Skeleton3D = null
var _anim: AnimationPlayer = null
var _clip: StringName = &""
var _lunge_left := 0.0


## Builds her: sight reaching [param sight] metres across [param cone] degrees, and no fan for a
## [param sight] of 0 (the one that lunges at a caught player has nothing to show).
func build(sight: float, cone: float) -> void:
	name = "Witch"
	var scene := load(BODY) as PackedScene if ResourceLoader.exists(BODY) else null

	if scene != null:
		_model = scene.instantiate() as Node3D

	if _model == null:
		# A dark column rather than nothing: an invisible witch is a lottery.
		DotLog.warn(CHANNEL, "no witch model; drawing a column", {"path": BODY})
		_model = Node3D.new()
		var column := MeshInstance3D.new()
		var capsule := CapsuleMesh.new()
		capsule.height = HEIGHT
		capsule.radius = 0.3
		column.mesh = capsule
		column.position.y = HEIGHT * 0.5
		_model.add_child(column)
		add_child(_model)
	else:
		_model.name = "Body"
		add_child(_model)
		_skeleton = _model.find_children("*", "Skeleton3D", true, false).front() as Skeleton3D
		_anim = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
		var mesh := _model.find_children("*", "MeshInstance3D", true, false).front() as MeshInstance3D
		mesh.material_override = _skin()
		var raw := mesh.get_aabb().end.y
		# The kit faces +Z and this family's forward is -Z; drawn a little narrow for her height.
		var s := HEIGHT / maxf(raw, 0.01)
		_model.basis = Basis(Vector3.UP, PI).scaled(Vector3(s * 0.8, s, s * 0.8))
		_head_bone = _skeleton.find_bone("Head") if _skeleton != null else -1

	if _anim != null:
		_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
		for clip in LOOPING:
			if _anim.has_animation(clip):
				_anim.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		_play(&"idle", 1.0)

	_dress()

	if sight > 0.0:
		fan = _fan(sight, cone)
		add_child(fan)


## A skirt to the floor, a hat, hair down her back and two eyes, on the head bone where they
## must move with it. Placed once from the rest pose, in her own frame; a BoneAttachment3D
## keeps each where it was put as the bone moves.
func _dress() -> void:
	var black := StandardMaterial3D.new()
	black.albedo_color = Color(0.035, 0.03, 0.04)
	black.roughness = 1.0

	# The skirt: from the hips to the floor, wide enough that a stride stays inside it, so
	# she seems to glide.
	var skirt := MeshInstance3D.new()
	skirt.name = "Skirt"
	var skirt_mesh := CylinderMesh.new()
	skirt_mesh.top_radius = 0.2
	skirt_mesh.bottom_radius = 0.56
	skirt_mesh.height = HEIGHT * 0.52
	skirt_mesh.radial_segments = 14
	skirt.mesh = skirt_mesh
	skirt.material_override = black
	skirt.position = Vector3(0, HEIGHT * 0.26 + 0.02, 0)
	add_child(skirt)

	var head := Node3D.new()
	head.name = "HeadMount"

	if _skeleton != null and _head_bone >= 0:
		var bone := BoneAttachment3D.new()
		bone.name = "HeadBone"
		bone.bone_name = "Head"
		_skeleton.add_child(bone)
		bone.add_child(head)
		# Where the top of her head is at rest, upright and at metre scale in her frame.
		var at_rest := global_transform.affine_inverse() * _skeleton.global_transform * _skeleton.get_bone_global_rest(_head_bone)
		var top := Vector3(at_rest.origin.x, HEIGHT, at_rest.origin.z)
		head.global_transform = global_transform * Transform3D(Basis.IDENTITY, top)
	else:
		head.position = Vector3(0, HEIGHT, 0)
		add_child(head)

	var brim := MeshInstance3D.new()
	var brim_mesh := CylinderMesh.new()
	brim_mesh.top_radius = 0.46
	brim_mesh.bottom_radius = 0.5
	brim_mesh.height = 0.025
	brim.mesh = brim_mesh
	brim.material_override = black
	brim.position = Vector3(0, -0.1, 0)
	head.add_child(brim)
	var point := MeshInstance3D.new()
	var point_mesh := CylinderMesh.new()
	point_mesh.top_radius = 0.0
	point_mesh.bottom_radius = 0.26
	point_mesh.height = 0.85
	point.mesh = point_mesh
	point.material_override = black
	point.position = Vector3(0.04, 0.3, 0.06)
	point.rotation = Vector3(deg_to_rad(-14.0), 0.0, deg_to_rad(8.0))
	head.add_child(point)

	# Lank hair down her back, under the brim.
	for i in 5:
		var strand := MeshInstance3D.new()
		var strand_mesh := BoxMesh.new()
		strand_mesh.size = Vector3(0.09, 0.75 + 0.1 * float(i % 3), 0.03)
		strand.mesh = strand_mesh
		strand.material_override = black
		var across := -0.24 + 0.12 * float(i)
		strand.position = Vector3(across, -0.5 - 0.05 * float(i % 3), 0.22 - absf(across) * 0.3)
		strand.rotation = Vector3(deg_to_rad(8.0), atan2(across, 0.2) * 0.5, 0.0)
		head.add_child(strand)

	_eyes_material = StandardMaterial3D.new()
	_eyes_material.albedo_color = Color(1.0, 0.12, 0.05)
	_eyes_material.emission_enabled = true
	_eyes_material.emission = Color(1.0, 0.12, 0.05)
	_eyes_material.emission_energy_multiplier = EYES_IDLE
	_eyes_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	for side in [-0.09, 0.09]:
		var eye := MeshInstance3D.new()
		var dot := SphereMesh.new()
		dot.radius = 0.03
		dot.height = 0.06
		eye.mesh = dot
		eye.material_override = _eyes_material
		eye.position = Vector3(side, EYE_DROP, -EYE_FORWARD)
		head.add_child(eye)

	_glow = OmniLight3D.new()
	_glow.light_color = Color(1.0, 0.18, 0.1)
	_glow.light_energy = GLOW_IDLE
	_glow.omni_range = 3.2
	_glow.position = Vector3(0, EYE_DROP, -0.4)
	head.add_child(_glow)


## Her skin and rags: the kit's atlas recoloured grey and black (tools/make_witch.py).
static func _skin() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(ATLAS) as Texture2D if ResourceLoader.exists(ATLAS) else null
	m.albedo_color = Color.WHITE if m.albedo_texture != null else SKIN
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.roughness = 0.95
	return m


func _play(clip: StringName, rate: float) -> void:
	if _anim == null or not _anim.has_animation(clip):
		return
	_anim.speed_scale = rate
	if _clip == clip:
		return
	_clip = clip
	_anim.play(clip, 0.25)


## The sight: a fan on the floor, its point under her.
func _fan(sight: float, cone: float) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = "Sight"
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := 20
	var half := deg_to_rad(cone * 0.5)

	for k in steps:
		var a0 := -half + 2.0 * half * float(k) / float(steps)
		var a1 := -half + 2.0 * half * float(k + 1) / float(steps)
		# Brightest at her feet, nothing at the edge of her reach: where she sees best.
		st.set_color(Color(1, 1, 1, 1))
		st.add_vertex(Vector3.ZERO)
		st.set_color(Color(1, 1, 1, 0.15))
		st.add_vertex(Vector3(-sin(a1), 0, -cos(a1)) * sight)
		st.set_color(Color(1, 1, 1, 0.15))
		st.add_vertex(Vector3(-sin(a0), 0, -cos(a0)) * sight)

	mesh.mesh = st.commit()
	_fan_material = StandardMaterial3D.new()
	_fan_material.albedo_color = Color(0.85, 0.0, 0.0, FAN_IDLE)
	_fan_material.vertex_color_use_as_albedo = true
	_fan_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_fan_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fan_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fan_material.no_depth_test = false
	mesh.material_override = _fan_material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.position = Vector3(0, 0.03, 0)
	return mesh


## Where the clock puts her this frame: at [param at], walking toward [param facing] (radians)
## at [param speed] metres a second, her head and her sight turned [param head] further.
## Returns the metres she moved.
##
## [b]The speed is her loop's, not measured[/b]: her pose moves when the clock ticks, and a
## frame between two ticks (any display faster than the tick rate) measured her standing still,
## so she flickered between her walk and her idle. A negative [param speed] measures it (the
## caught player's witch, who is placed by the camera).
## How far she is into listening, 0 to 1 (see [method set_listening]).
var listening := 0.0
const LISTEN_TILT := 0.45


func place(at: Vector3, facing: float, head: float, delta: float, speed: float = -1.0) -> float:
	var moved := 0.0 if _last_at == Vector3.INF else Vector2(at.x - _last_at.x, at.z - _last_at.z).length()
	_last_at = at
	global_position = at
	rotation = Vector3(0.0, facing, 0.0)
	if speed < 0.0:
		speed = moved / delta if delta > 0.0 else 0.0
	# A loop that jumps (a house change, a long hitch) is not a stride.
	if moved < 1.0:
		stride += speed * delta

	if _anim != null:
		# A shamble when she walks; seeing you, her arms come up and reach.
		if _lunge_left > 0.0:
			_lunge_left -= delta
			_play(&"attack", 1.3)
		elif speed < 0.2:
			_play(&"idle", 1.0)
		elif seeing > 0.5:
			# Arms up and reaching, legs still under the skirt: she glides at you.
			_play(&"attack_idle", 1.0)
		else:
			_play(&"walk", clampf(speed / 1.3, 0.6, 1.8))
		_anim.advance(delta)
		_turn_head(head)

	if fan != null:
		fan.rotation = Vector3(0.0, head, 0.0)

	return moved


## Her head turned [param angle] radians from where she walks, over the clip's pose. Right after
## the clip is advanced, every frame: written on a pose the clip had not just written, the turn
## would add up frame on frame.
func _turn_head(angle: float) -> void:
	if _skeleton == null or _head_bone < 0:
		return

	var pose := _skeleton.get_bone_pose_rotation(_head_bone)
	# The listening tilt: the head cocked to one side, as a person's is toward a sound.
	var cock := Quaternion(Vector3.BACK, listening * LISTEN_TILT)
	_skeleton.set_bone_pose_rotation(_head_bone, pose * Quaternion(Vector3.UP, angle) * cock)


## Whether she sees the local player now. Eased, so the flare comes up fast and dies slowly.
## Whether she stands listening: eased, so the head cocks over a moment and comes back slowly.
func set_listening(on: bool, delta: float) -> void:
	listening = move_toward(listening, 1.0 if on else 0.0, delta * (2.5 if on else 1.0))


func set_seeing(on: bool, delta: float) -> void:
	seeing = move_toward(seeing, 1.0 if on else 0.0, delta * (6.0 if on else 1.2))

	if _fan_material != null:
		_fan_material.albedo_color.a = lerpf(FAN_IDLE, FAN_SEEING, seeing)

	if _eyes_material != null:
		_eyes_material.emission_energy_multiplier = lerpf(EYES_IDLE, EYES_SEEING, seeing)

	if _glow != null:
		_glow.light_energy = lerpf(GLOW_IDLE, GLOW_SEEING, seeing)


## The lunge of a catch: arms up at you.
func lunge() -> void:
	_lunge_left = 0.9
	if _anim != null and _anim.has_animation(&"attack"):
		_clip = &""
		_play(&"attack", 1.3)
		_anim.seek(0.0, true)


func describe() -> Dictionary:
	return {
		"art": _skeleton != null,
		"clip": String(_clip),
		"seeing": snappedf(seeing, 0.01),
		"at": str(global_position.snapped(Vector3.ONE * 0.01)) if is_inside_tree() else "-",
	}
