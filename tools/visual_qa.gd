extends GSGameVisualQaCapture

## Look At Me's visual QA capture (the loop is gs-game's docs/visual-qa.md). Three kinds of item, each recorded frame by frame
## at --fps in three views (f first person, t behind-right, o in front):
##   person_<letter>  one of the six people (LmFigure) idling, walking, running, crouching and jumping; f is another player's eye a few metres in front.

##   witch            the witch (LmWitch) idling, walking, reaching for you with the fan flared, and lunging; f is her victim's eye.
##   clown            the clown hallucination (LmClown) watching you with its mouth shut and talking.
## This game has no weapons, so no weapon items. The outside views and frame saving are gs-game's GSGameVisualQaViews.

const LmFigure := preload("../game/lm_figure.gd")
const LmWitch := preload("../game/lm_witch.gd")
const LmClown := preload("../game/lm_clown.gd")

## Your own body draws only in the outside views.
const BODY_LAYER := 1 << 18
const ALL_LAYERS := 0xFFFFF
const BODY_HEIGHT := 1.8
const PERSON_CLIPS: PackedStringArray = ["idle", "walk", "run", "crouch", "jump"]
const WITCH_CLIPS: PackedStringArray = ["idle", "walk", "reach", "lunge"]
const CLOWN_CLIPS: PackedStringArray = ["watch", "talk"]
## Ground speed per clip (metres a second), about the game's walk and run; the witch's reach is her own slower loop.
const SPEED := {"idle": 0.0, "walk": 2.9, "run": 6.5, "crouch": 2.9, "jump": 2.9, "reach": 1.3, "lunge": 0.0, "watch": 0.0, "talk": 0.0}
const SECONDS := {"idle": 2.0, "walk": 2.4, "run": 2.0, "crouch": 2.0, "jump": 1.6, "reach": 2.0, "lunge": 1.4, "watch": 2.0, "talk": 3.0}
## The witch walks at her own slower loop speed, not a player's.
const WITCH_WALK := 1.3
## The witch's victim (the first-person view): where they stand per clip, far enough back that her boots stay in frame
## (the lunge ends 1.6 m short of them, her reach, the scare distance); their eye height and torch.
const VICTIM_Z := {"idle": -3.4, "walk": -4.4, "reach": -3.3, "lunge": -2.3}
const VICTIM_EYE := 1.65
const VICTIM_SIDE := -0.12
const VICTIM_FOV := 70.0
const WITCH_LOOK := 1.15
## How high the floating clown bust hangs (metres), its bust being 0.9 m.
const CLOWN_HEIGHT := 1.6

var _holder := Node3D.new()
var _figure: LmFigure = null
var _witch: LmWitch = null
var _clown: LmClown = null
var _kind := ""
var _staged := ""
var _torch := SpotLight3D.new()


func _items() -> PackedStringArray:
	var items := PackedStringArray()
	for path in LmFigure.ATLASES:
		items.append("person_" + path.get_file().get_basename().trim_prefix("texture-"))
	items.append("witch")
	items.append("clown")
	return items


func _clips(item: String) -> PackedStringArray:
	if item == "witch":
		return WITCH_CLIPS
	if item == "clown":
		return CLOWN_CLIPS
	return PERSON_CLIPS


func _seconds(_item: String, clip: String) -> float:
	return float(SECONDS.get(clip, 2.0))


func _warmup_frames(_item: String, _clip: String) -> int:
	return 4


func _build() -> void:
	build_stage()
	first_person.cull_mask = ALL_LAYERS & ~BODY_LAYER
	# the victim's torch, held low by their right hand
	_torch.position = Vector3(0.25, -0.3, 0.0)
	_torch.light_color = Color(1.0, 0.9, 0.75)
	_torch.light_energy = 2.5
	_torch.spot_range = 9.0
	_torch.spot_angle = 28.0
	_torch.visible = false
	first_person.add_child(_torch)
	root.add_child(_holder)


func _stage(item: String, clip: String) -> GSResult:
	_clear()
	_staged = clip
	views.behind_offset = Vector3(1.6, 1.6, 3.2)
	views.behind_look_height = 1.0
	views.opponent_offset = Vector3(0.4, 1.6, -4.0)
	views.opponent_look_height = 1.3
	if item == "witch":
		_kind = "witch"
		views.behind_offset = Vector3(2.0, 2.0, 4.0)
		views.behind_look_height = 1.2
		views.opponent_offset = Vector3(0.4, 1.8, -4.5)
		_witch = LmWitch.new()
		_holder.add_child(_witch)
		_witch.build(0.0, 60.0)
		_witch.global_position = Vector3.ZERO
		if clip == "lunge":
			_witch.lunge()
		elif clip == "walk" or clip == "reach":
			# Already walking when the clip starts: the first 0.25 s of a walk is the blend out of the
			# idle, and a foot mid-blend is no foot to judge.
			_witch.set_seeing(clip == "reach", 1.0)
			_witch.place(Vector3(0.0, 0.0, WITCH_WALK * float(SECONDS.get(clip, 2.0)) * 0.5), 0.0, 0.0, 0.4, WITCH_WALK)
	elif item == "clown":
		_kind = "clown"
		views.behind_offset = Vector3(1.8, 1.0, 3.4)
		views.behind_look_height = 0.75
		views.opponent_offset = Vector3(0.0, 0.85, -3.2)
		views.opponent_look_height = 0.75
		_clown = LmClown.new()
		_holder.add_child(_clown)
		if not _clown.build():
			return GSResult.fail(GSError.CODE_INVALID, "the clown model did not load")
		_clown.position = Vector3(0.0, CLOWN_HEIGHT - 0.75, 0.0)
	else:
		_kind = "person"
		_figure = LmFigure.new()
		_figure.name = "Figure"
		_holder.add_child(_figure)
		_figure.global_position = Vector3.ZERO
		_figure.build(BODY_HEIGHT, _atlas_of(item.trim_prefix("person_")), Color(0.3, 0.45, 0.9))
	return GSResult.success(clip)


func _atlas_of(letter: String) -> String:
	for path in LmFigure.ATLASES:
		if path.ends_with("texture-%s.png" % letter):
			return path
	return LmFigure.ATLASES[0]


func _clear() -> void:
	for child in _holder.get_children():
		_holder.remove_child(child)
		child.free()
	_figure = null
	_witch = null
	_clown = null


func _subject(_item: String) -> Node3D:
	if _kind == "witch":
		return _witch
	if _kind == "clown":
		return _clown
	return _figure


## A subject stands at the origin facing -Z; the walking clips move it along -Z from behind so the stage is walked, not skated on.
func _drive(_item: String, clip: String, t: float, _frame: int) -> void:
	var step := 1.0 / float(fps)
	var speed := float(SPEED.get(clip, 0.0))
	if _kind == "witch" and (clip == "walk" or clip == "reach"):
		speed = WITCH_WALK
	var start := speed * float(SECONDS.get(clip, 2.0)) * 0.5
	if _kind == "witch":
		_witch.set_seeing(clip == "reach" or clip == "lunge", step)
		_witch.place(Vector3(0.0, 0.0, start - speed * t), 0.0, 0.0, step, speed)
		return
	if _kind == "clown":
		_clown.mouth = 0.5 + 0.5 * sin(t * 9.0) if clip == "talk" else 0.0
		_clown.watch(Vector3(0.0, 1.6, -3.0), step)
		return
	var airborne := false
	var vertical := 0.0
	var lift := 0.0
	if clip == "jump":
		# A 0.6 s hop at the start of each second.
		var phase := fmod(t, 1.0) / 0.6
		airborne = phase < 1.0
		vertical = 4.0 * (1.0 - 2.0 * phase) if airborne else 0.0
		lift = 0.6 * 4.0 * phase * (1.0 - phase) if airborne else 0.0
	_figure.set_motion({"on_floor": not airborne, "vertical": vertical, "crouched": clip == "crouch",
		"sprinting": clip == "run", "aim": 0.0, "velocity": Vector3(0.0, 0.0, -speed)})
	_figure.pose(Vector3(0.0, lift, start - speed * t), 0.0, speed)


func _grounded(_item: String, clip: String, t: float) -> bool:
	return not (_kind == "person" and clip == "jump" and fmod(t, 1.0) < 0.6)


func _before_draw(_item: String, _clip: String, _frame: int) -> void:
	if _figure != null:
		var _tagged := GSGameVisualQaViews.tag_layers(_figure, BODY_LAYER)


## A rival's eye in front, looking at the subject (the clown the same way). The witch's is her victim's eye instead: standing
## still where she is heading, at a person's eye height, torch in hand, so she comes at the lens and the lunge ends at her
## reach (the opponent view follows her at a fixed offset, this one does not move).
func _place_first_person(_item: String) -> void:
	var at := _subject(_item).global_position
	if _kind == "witch":
		_torch.visible = true
		first_person.fov = VICTIM_FOV
		first_person.global_position = Vector3(VICTIM_SIDE, VICTIM_EYE, float(VICTIM_Z.get(_staged, -2.4)))
		# aimed below her face, so her boots stay in frame as she closes in
		first_person.look_at(at + Vector3(0.0, WITCH_LOOK, 0.0))
		return
	_torch.visible = false
	first_person.fov = 75.0
	var mid := 0.75 if _kind == "clown" else BODY_HEIGHT * 0.5
	var dist := 3.0 if _kind == "clown" else 2.5
	first_person.global_position = at + Vector3(0.0, 0.85 if _kind == "clown" else 1.6, -dist)
	first_person.look_at(at + Vector3(0.0, mid, 0.0))
