extends CanvasLayer

## The on-screen buttons of a phone player: use, flashlight, jump and crouch, as dot-ui's [DotTouchButtons].
## The client turns a press into what the key would have done. Walking and looking are the touch sampler's.

# No CHANNEL: buttons that emit signals; what they cause is logged where it happens.

signal pressed(id: StringName)
signal released(id: StringName)

const EDGE_MARGIN := 20.0

var buttons: DotTouchButtons = null


## Whether this device wants them.
static func wanted() -> bool:
	return DotPlatform.has_touch()


## Offsets are from the bottom-right corner, towards the middle; 390 px tall leaves little to spare.
static func layout() -> Array[Dictionary]:
	return [
		{"id": &"use", "label": "USE", "offset": Vector2(66, 76), "radius": 46.0},
		{"id": &"jump", "label": "JUMP", "offset": Vector2(160, 40), "radius": 32.0},
		{"id": &"flashlight", "label": "LIGHT", "offset": Vector2(40, 160), "radius": 26.0},
		{"id": &"crouch", "label": "DUCK", "offset": Vector2(132, 130), "radius": 28.0},
	]


func _init() -> void:
	name = "Touch"
	layer = 6


func build() -> void:
	buttons = DotTouchButtons.new()
	buttons.name = "Buttons"
	buttons.only_on_touch = false
	buttons.margin = EDGE_MARGIN
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	buttons.set_buttons(layout())
	buttons.button_down.connect(func(id: StringName) -> void: pressed.emit(id))
	buttons.button_up.connect(func(id: StringName) -> void: released.emit(id))
	add_child(buttons)


## Whether a screen position is on a button, so the sampler leaves that touch alone.
func contains_point(screen_pos: Vector2) -> bool:
	return buttons != null and buttons.contains_point(screen_pos)
