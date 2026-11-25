extends Node3D

## A witch, drawn: a hunched, hooded crone (the Sketchfab "Witch" made gaunt and clawed by tools/make_witch.py), shambling her clock loop, head turning with her sight, which lies on the floor as a red fan.
## Only what the server already decides is drawn: pose is [method LmLevel.witch_pose] (Decision 2), whether she sees YOU is [method LmGame.exposure], asked by [LmClient] for the local player alone.
## Seeing you, her eyes and lamp flare, the fan goes hard red and her arms come up: the meter is filling and the way out is out of the fan.

const CHANNEL := "lookatme.witch"

const LmPaths := preload("lm_paths.gd")

## Taller than the tallest player (1.8 m): something you look up at.
const HEIGHT := 2.2

## Her body: "Witch" by Tamko Dmitry (CC BY 4.0, assets/witch/CREDITS.md) rigged, hunched and
## clawed, with its painted atlas. tools/make_witch.py makes both from the Sketchfab file.
static var BODY := LmPaths.rebase("res://assets/witch/witch.glb")
static var ATLAS := LmPaths.rebase("res://assets/witch/witch_atlas.png")

## Her skin when the atlas is missing.
const SKIN := Color("9aa293")

## Her eye bones (tools/make_witch.py puts one at the centre of each socket, its +Y out of the face),
## and how far in front of the socket's centre the glowing core sits (model units, along the bone).
const EYE_BONES: PackedStringArray = ["Eye.L", "Eye.R"]
const EYE_OUT := 0.005

## The clips that loop (glTF clips import once-through).
const LOOPING: Array[StringName] = [&"idle", &"walk", &"run", &"run_arms", &"attack_idle"]

## The fan's alpha: barely there while she walks, hard red while she sees you.
const FAN_IDLE := 0.07
const FAN_SEEING := 0.26

## Her eyes and the lamp in her face, at rest and seeing you: embers in the hood, not floodlights (brighter
## blew the face out to red).
const EYES_IDLE := 1.6
const EYES_SEEING := 2.2
const GLOW_IDLE := 0.02
const GLOW_SEEING := 0.04     # brighter smeared red over her cheeks

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
var _halo_material: StandardMaterial3D = null
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
		GSLog.warn(CHANNEL, "no witch model; drawing a column", {"path": BODY})
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
		# The model faces +Z and this family's forward is -Z; it is built at HEIGHT already.
		var s := HEIGHT / maxf(raw, 0.01)
		_model.basis = Basis(Vector3.UP, PI).scaled(Vector3(s, s, s))
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


## Her eyes and the lamp in her face, each eye on its own bone in the centre of its socket, so
## they stay in the sockets whatever the head does.
func _dress() -> void:
	var mounts: Array[Node3D] = []
	if _skeleton != null:
		for bone_name in EYE_BONES:
			if _skeleton.find_bone(bone_name) < 0:
				continue
			var bone := BoneAttachment3D.new()
			bone.name = bone_name.replace(".", "")
			bone.bone_name = bone_name
			_skeleton.add_child(bone)
			mounts.append(bone)
	if mounts.is_empty():
		# No eye bones (the column): two points high on its front.
		for side: float in PackedFloat32Array([-0.04, 0.04]):
			var at := Node3D.new()
			at.position = Vector3(side, HEIGHT - 0.25, -0.3)
			add_child(at)
			mounts.append(at)
	_dress_eyes(mounts)


func _dress_eyes(mounts: Array[Node3D]) -> void:
	_eyes_material = StandardMaterial3D.new()
	_eyes_material.albedo_color = Color(1.0, 0.12, 0.05)
	_eyes_material.emission_enabled = true
	_eyes_material.emission = Color(1.0, 0.12, 0.05)
	_eyes_material.emission_energy_multiplier = EYES_IDLE
	_eyes_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_halo_material = StandardMaterial3D.new()
	_halo_material.albedo_color = Color(1.0, 0.1, 0.04, 0.12)
	_halo_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_halo_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_halo_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	for mount in mounts:
		var eye := MeshInstance3D.new()
		var dot := SphereMesh.new()
		dot.radius = 0.012
		dot.height = 0.024
		eye.mesh = dot
		eye.material_override = _eyes_material
		eye.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		eye.position = Vector3(0.0, EYE_OUT, 0.0)
		mount.add_child(eye)
		var halo := MeshInstance3D.new()      # a short soft halo round the bright core, inside the socket
		var haze := SphereMesh.new()
		haze.radius = 0.022
		haze.height = 0.044
		halo.mesh = haze
		halo.material_override = _halo_material
		halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		halo.position = eye.position
		mount.add_child(halo)

	# The lamp in her face: a little out in front of her first eye, lighting the socket rims.
	_glow = OmniLight3D.new()
	_glow.light_color = Color(1.0, 0.18, 0.1)
	_glow.light_energy = GLOW_IDLE
	_glow.omni_range = 0.2         # the sockets only, not the whole face
	_glow.position = Vector3(0.0, 0.08, 0.0)
	mounts[0].add_child(_glow)


## Her skin and rags: the painted atlas (tools/make_witch.py), mipmapped so its cloth grain does not shimmer.
static func _skin() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(ATLAS) as Texture2D if ResourceLoader.exists(ATLAS) else null
	m.albedo_color = Color.WHITE if m.albedo_texture != null else SKIN
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	m.roughness = 0.9
	# both faces: the hood is a single sheet, and from in front its inside is what frames her face
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	# a soft sheen on the silhouette, so the folds and the arms read against the dark front
	m.rim_enabled = true
	m.rim = 0.3
	m.rim_tint = 0.5
	return m


func _play(clip: StringName, rate: float) -> void:
	if _anim == null or not _anim.has_animation(clip):
		return
	_anim.speed_scale = rate
	if _clip == clip:
		return
	# The first clip starts clean: blended from the rig's bind pose it would drag the feet.
	var blend := 0.25 if _clip != &"" else 0.0
	_clip = clip
	_anim.play(clip, blend)


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


## How far she is into listening, 0 to 1 (see [method set_listening]).
var listening := 0.0
const LISTEN_TILT := 0.45


## Where the clock puts her this frame: at [param at], walking toward [param facing] (radians) at [param speed] m/s, head and sight turned [param head] further. Returns the metres she moved.
## The speed is her loop's, not measured: between two ticks a measured speed read zero and she flickered between walk and idle. A negative [param speed] measures it (the caught player's witch, placed by the camera).
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
			_play(&"attack", 1.0)
		elif speed < 0.2:
			_play(&"idle", 1.0)
		elif seeing > 0.5:
			# Arms up and reaching, legs shambling: she lurches at you.
			_play(&"attack_idle", clampf(speed / 1.3, 0.6, 1.8))
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


## The lunge of a catch: she gathers, then strikes and grabs, the whole clip once through.
func lunge() -> void:
	_lunge_left = 0.9
	if _anim != null and _anim.has_animation(&"attack"):
		_lunge_left = _anim.get_animation(&"attack").length
		_clip = &""
		_play(&"attack", 1.0)
		_anim.seek(0.0, true)


func describe() -> Dictionary:
	return {
		"art": _skeleton != null,
		"clip": String(_clip),
		"seeing": snappedf(seeing, 0.01),
		"at": str(global_position.snapped(Vector3.ONE * 0.01)) if is_inside_tree() else "-",
	}
