extends CanvasLayer

## The on-screen buttons of a phone player, one for each key the game has, as dot-ui's [DotTouchButtons].
## The client turns a press into what the key would have done. Walking and looking are the touch sampler's.

const CHANNEL := "lookatme.touch"

const BOARD := DotGameTouchLayout.BOARD
const CHAT := DotGameTouchLayout.CHAT
const CAMERA := DotGameTouchLayout.CAMERA
const FLASHLIGHT := &"flashlight"
const HOUSE := &"house"
const HELP := &"help"
const GAG := &"gag"
const MUTE := &"mute"

signal pressed(id: StringName)
signal released(id: StringName)

var buttons: DotTouchButtons = null


## Whether this device wants them.
static func wanted() -> bool:
	return DotPlatform.has_touch()


## dot-game's platformer preset: use, jump, crouch, the held board and the command line in their homes, the flashlight
## beside use, the camera, the house list, gag and mute on the free slots, and help past the last of the row.
static func touch_layout() -> DotGameTouchLayout:
	var res := DotGameTouchLayout.build(DotGameTouchLayout.PLATFORMER, {
		DotGameTouchLayout.SPRINT: null,
		FLASHLIGHT: {"slot": &"secondary", "label": "LIGHT"},
		CAMERA: {"slot": &"inner", "label": "CAM"},
		HOUSE: {"slot": &"corner", "label": "M"},
		GAG: {"slot": &"row1", "label": "GAG"},
		MUTE: {"slot": &"row2", "label": "MUTE"},
		HELP: {"offset": Vector2(312, 246), "radius": 22.0, "label": "?"},
		CHAT: {"slot": &"row4", "label": "/"},
	})
	if not res.ok:
		DotLog.error(CHANNEL, "touch layout refused", {"error": str(res.error)})
		return DotGameTouchLayout.custom()
	return res.value as DotGameTouchLayout


static func layout() -> Array[Dictionary]:
	return touch_layout().buttons()


func _init() -> void:
	name = "Touch"
	layer = 6


func build() -> void:
	buttons = DotTouchButtons.new()
	buttons.name = "Buttons"
	buttons.only_on_touch = false
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_layout().apply(buttons)
	buttons.button_down.connect(func(id: StringName) -> void: pressed.emit(id))
	buttons.button_up.connect(func(id: StringName) -> void: released.emit(id))
	add_child(buttons)


## Whether a screen position is on a button, so the sampler leaves that touch alone.
func contains_point(screen_pos: Vector2) -> bool:
	return buttons != null and buttons.contains_point(screen_pos)
