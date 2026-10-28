extends Node3D

## Draws and plays what [LmScares] decides: the face or flash of a sanity scare, the demons in the
## corners of the view, the whisper to look behind you. The client's alone: nothing here is sent
## anywhere but the one number a fright moves, the meter, which goes through [member spook].
##
## Everything is drawn from primitives (a demon is a pale head, a dark body, long arms and two
## red eyes) and heard from audio/ (made for this game, see audio/CREDITS.md), so nothing needs
## a file to exist: a demon with no model is still a demon.

const LmScares := preload("lm_scares.gd")
const LmWitch := preload("lm_witch.gd")
const LmAudio := preload("lm_audio.gd")
const LmClown := preload("lm_clown.gd")

const CHANNEL := "lookatme.scares"

## Called with the meter's rise when a fright asks for one; the client points it at the server.
var spook: Callable = Callable()
var director: LmScares = null
var audio: LmAudio = null
var camera: Camera3D = null
## A full-view colour rect the flash is drawn on (the HUD's); optional.
var flash: ColorRect = null

var _figures: Dictionary = {}
var _scare_figure: Node3D = null
var _scare_witch: Node3D = null
var _scare_left := 0.0
var _scare_total := 0.5
var _flash_alpha := 0.0
var _jump: Dictionary = {}
var _sway := 0.0
var _clown: Node3D = null
## The lunge in progress: {"left", "total", "from"}, or empty.
var _lunge: Dictionary = {}


## One tick: ask the director, show what it says, keep the figures as the director has them.
func present(delta: float, view: Dictionary) -> Array[Dictionary]:
	var events := director.tick(delta, view)
	var eye: Vector3 = view["eye"]

	for event in events:
		_on_event(event, eye)

	_sync_demons(eye)
	_sync_clown(delta, eye)
	_animate(delta, eye, view["forward"])
	return events


func _on_event(event: Dictionary, eye: Vector3) -> void:
	DotLog.debug(CHANNEL, "a scare event", {"kind": String(event["kind"])})
	match StringName(event["kind"]):
		LmScares.SCARE:
			_startle(str(event["style"]), float(event["side"]), float(event["seconds"]), eye)
		LmScares.WHISPER:
			if audio != null:
				var _w := audio.whisper(event["at"])
		LmScares.DEMON_JUMPS:
			# It is on you: the demon itself, in your face, for a moment.
			_startle("demon", 0.0, director.config.scare_seconds, eye)
			_fright(float(event["spike"]))
		LmScares.CLOWN_LUNGES:
			_start_lunge(event, eye)
			_fright(float(event["spike"]))
		LmScares.BEHIND_WHISPER:
			if audio != null:
				var _b := audio.whisper_behind(event["at"])
		LmScares.BEHIND_SCARE:
			_startle("behind", 0.0, float(event["seconds"]) * 1.4, eye, event["at"])
			_fright(float(event["spike"]))


## Rest: no jump scare pending or showing, no demon standing, no flash.
func rest() -> void:
	director.rest()
	_scare_left = 0.0
	_flash_alpha = 0.0
	_jump = {}
	_lunge = {}

	if _clown != null:
		_clown.visible = false

	if _scare_figure != null:
		_scare_figure.queue_free()
		_scare_figure = null

	if _scare_witch != null:
		_scare_witch.visible = false

	if flash != null:
		flash.color = Color(0, 0, 0, 0)

	_sync_demons(Vector3.ZERO)


## The clown floats where the director put it, a little above the floor, watching; during a lunge
## it flies at the lens with its jaw wide, then is gone.
func _sync_clown(delta: float, eye: Vector3) -> void:
	var present := not director.clown.is_empty() or not _lunge.is_empty()

	if not present:
		if _clown != null:
			_clown.visible = false

		return

	if _clown == null:
		_clown = LmClown.new()
		add_child(_clown)

		if not _clown.call(&"build"):
			_clown.queue_free()
			_clown = null
			_lunge = {}
			return

	_clown.visible = true

	if _lunge.is_empty():
		var at: Vector3 = director.clown["at"]
		_clown.global_position = at + Vector3(0, 0.75 + sin(_sway * 0.9) * 0.08, 0)
		_clown.set(&"mouth", 0.0)
		_clown.call(&"watch", eye, delta)
		return

	_lunge["left"] = float(_lunge["left"]) - delta
	var t := 1.0 - clampf(float(_lunge["left"]) / maxf(float(_lunge["total"]), 0.01), 0.0, 1.0)
	var from: Vector3 = _lunge["from"]
	var face := eye + Vector3(0, -0.85, 0) + (from - eye).normalized() * 1.15
	_clown.global_position = from.lerp(face, t * t)
	_clown.set(&"mouth", 1.0)
	_clown.call(&"watch", eye, delta)

	if float(_lunge["left"]) <= 0.0:
		_lunge = {}
		_clown.visible = false


func _start_lunge(event: Dictionary, eye: Vector3) -> void:
	_lunge = {"left": float(event["seconds"]) + 0.15, "total": float(event["seconds"]) + 0.15,
		"from": (event["at"] as Vector3) + Vector3(0, 0.75, 0)}
	_flash_alpha = 0.6
	_scare_left = 0.1

	if audio != null:
		var _h := audio.scare_hit()
		var _s := audio.whisper(event["at"])


func _fright(amount: float) -> void:
	if spook.is_valid() and amount > 0.0:
		spook.call(amount)


## A face or a figure, a flash and a sound, for [param seconds]. [param where] is a floor spot
## for the one that stands somewhere (behind you); the others are put in front of the lens.
func _startle(style: String, side: float, seconds: float, eye: Vector3, where: Vector3 = Vector3.INF) -> void:
	_scare_left = maxf(seconds, 0.05)
	_scare_total = _scare_left
	_flash_alpha = 0.85 if style == "flash" else 0.45

	if audio != null:
		var _h := audio.scare_hit()

	if _scare_figure != null:
		_scare_figure.queue_free()
		_scare_figure = null

	if _scare_witch != null:
		_scare_witch.visible = false

	_jump = {"style": style, "side": side, "where": where}

	if style == "witch":
		_ensure_witch()
		_scare_witch.visible = true
		_scare_witch.call(&"lunge")
	else:
		_scare_figure = make_demon(2.0 if style == "flash" else 1.0)
		add_child(_scare_figure)


func _ensure_witch() -> void:
	if _scare_witch != null:
		return

	_scare_witch = LmWitch.new()
	add_child(_scare_witch)
	_scare_witch.call(&"build", 0.0, 0.0)
	_scare_witch.name = "ScareWitch"
	_scare_witch.visible = false


func _sync_demons(eye: Vector3) -> void:
	var live := {}

	for demon in director.demons:
		live[int(demon["id"])] = demon

		if not _figures.has(int(demon["id"])):
			var figure := make_demon(1.0)
			figure.name = "Demon%d" % int(demon["id"])
			add_child(figure)
			_figures[int(demon["id"])] = figure

		var node: Node3D = _figures[int(demon["id"])]
		node.global_position = demon["at"]

	for id: int in _figures.keys():
		if not live.has(id):
			(_figures[id] as Node3D).queue_free()
			_figures.erase(id)


func _animate(delta: float, eye: Vector3, forward: Vector3) -> void:
	_sway += delta

	for id: int in _figures:
		var node: Node3D = _figures[id]
		# Always facing you, with a slow lean: it does not walk, it is simply nearer when you look back.
		var to := eye - node.global_position
		node.rotation.y = atan2(to.x, to.z)
		node.rotation.z = sin(_sway * 1.3 + float(id)) * 0.06

	if _flash_alpha > 0.0:
		_flash_alpha = maxf(_flash_alpha - delta * 2.2, 0.0)

	if flash != null:
		flash.color = Color(1, 1, 1, _flash_alpha) if _scare_left > 0.0 or _flash_alpha > 0.0 else Color(0, 0, 0, 0)

	if _scare_left <= 0.0:
		if _scare_figure != null:
			_scare_figure.queue_free()
			_scare_figure = null

		if _scare_witch != null:
			_scare_witch.visible = false

		return

	_scare_left -= delta
	var flat := Vector3(forward.x, 0.0, forward.z)
	flat = flat.normalized() if flat.length_squared() > 0.001 else Vector3.FORWARD
	var right := flat.cross(Vector3.UP)
	var style: String = _jump.get("style", "")
	var side: float = _jump.get("side", 0.0)

	if style == "behind":
		if _scare_figure != null:
			var at: Vector3 = _jump["where"]
			_scare_figure.global_position = at
			var look := eye - at
			_scare_figure.rotation.y = atan2(look.x, look.z)

		return

	# In front of the lens, a little to one side, lunging in over the first moments.
	var progress := 1.0 - clampf(_scare_left / maxf(_scare_total, 0.01), 0.0, 1.0)
	var distance := lerpf(2.2, 1.0, minf(progress * 4.0, 1.0))
	var feet := eye + flat * distance + right * side * 0.3 - Vector3(0, 1.75, 0)
	var facing := atan2(-flat.x, -flat.z)

	if _scare_figure != null:
		_scare_figure.global_position = feet
		_scare_figure.rotation.y = facing

	if _scare_witch != null and _scare_witch.visible:
		var _moved: float = _scare_witch.call(&"place", feet, atan2(flat.x, flat.z), 0.0, delta)
		_scare_witch.call(&"set_seeing", true, delta)


## A demon: a pale head over a dark, narrow body, arms to the knees, two red eyes and a faint
## red light of their own so it shows in the dark house. [param head_scale] swells the face.
static func make_demon(head_scale: float) -> Node3D:
	var root := Node3D.new()
	root.name = "Demon"
	var cloth := StandardMaterial3D.new()
	cloth.albedo_color = Color(0.03, 0.025, 0.03)
	cloth.roughness = 1.0
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.72, 0.74, 0.7)
	skin.emission_enabled = true
	skin.emission = Color(0.25, 0.2, 0.2)
	var eye := StandardMaterial3D.new()
	eye.albedo_color = Color(1.0, 0.1, 0.05)
	eye.emission_enabled = true
	eye.emission = Color(1.0, 0.1, 0.05)
	eye.emission_energy_multiplier = 3.0
	eye.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.2
	capsule.height = 1.55
	body.mesh = capsule
	body.material_override = cloth
	body.position.y = 0.85
	root.add_child(body)

	for sign_x in [-1.0, 1.0]:
		var arm := MeshInstance3D.new()
		var rod := CylinderMesh.new()
		rod.top_radius = 0.04
		rod.bottom_radius = 0.025
		rod.height = 1.1
		arm.mesh = rod
		arm.material_override = cloth
		arm.position = Vector3(sign_x * 0.27, 0.95, 0.0)
		arm.rotation.z = sign_x * 0.08
		root.add_child(arm)

	var head := Node3D.new()
	head.position = Vector3(0, 1.72, 0)
	head.scale = Vector3.ONE * head_scale
	root.add_child(head)
	var skull := MeshInstance3D.new()
	var ball := SphereMesh.new()
	ball.radius = 0.15
	ball.height = 0.36
	skull.mesh = ball
	skull.material_override = skin
	head.add_child(skull)

	for sign_x in [-1.0, 1.0]:
		var pupil := MeshInstance3D.new()
		var dot := SphereMesh.new()
		dot.radius = 0.028
		dot.height = 0.056
		pupil.mesh = dot
		pupil.material_override = eye
		# The face is +Z: the figure is turned to face the player by the caller.
		pupil.position = Vector3(sign_x * 0.06, 0.03, 0.135)
		head.add_child(pupil)

	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.15, 0.1)
	glow.light_energy = 0.5 * head_scale
	glow.omni_range = 2.6
	glow.shadow_enabled = false
	glow.position = Vector3(0, 0, 0.3)
	head.add_child(glow)
	return root


func describe() -> Dictionary:
	return {"figures": _figures.size(), "clown": _clown != null and _clown.visible, "scare_left": _scare_left, "flash": _flash_alpha,
		"director": director.describe() if director != null else {}}
