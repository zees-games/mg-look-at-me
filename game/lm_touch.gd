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


## dot-game's platformer preset without sprint and chat, plus the flashlight in the corner home and a button for every key
## the keyboard has: camera (F5), command line, scoreboard (Tab, held), map list (M), and look-to-gag and look-to-mute (G, K).
## Help (H) is the menu's own button, which opens "Help & commands".
static func touch_layout() -> DotGameTouchLayout:
	var res := DotGameTouchLayout.build(DotGameTouchLayout.PLATFORMER, {
		DotGameTouchLayout.SPRINT: null,
		DotGameTouchLayout.CHAT: null,
		DotGameTouchLayout.CAMERA: &"row1",
		DotGameTouchLayout.COMMAND: &"row2",
		DotGameTouchLayout.MAPS: &"row4",
		DotGameTouchLayout.GAG: &"secondary",
		DotGameTouchLayout.MUTE: &"inner",
		&"flashlight": {"slot": &"corner", "label": "LIGHT"},
	})
	if not res.ok:
		push_error("mg-look-at-me touch layout refused: %s" % str(res.error))
		return DotGameTouchLayout.custom()
	return res.value


func _init() -> void:
	name = "Touch"
	layer = 6


func build(client: Object = null) -> void:
	buttons = DotTouchButtons.new()
	buttons.name = "Buttons"
	buttons.only_on_touch = false
	buttons.margin = EDGE_MARGIN
	buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	buttons.mouse_filter = Control.MOUSE_FILTER_IGNORE
	touch_layout().apply(buttons, client)
	buttons.button_down.connect(func(id: StringName) -> void: pressed.emit(id))
	buttons.button_up.connect(func(id: StringName) -> void: released.emit(id))
	add_child(buttons)


## Whether a screen position is on a button, so the sampler leaves that touch alone.
func contains_point(screen_pos: Vector2) -> bool:
	return buttons != null and buttons.contains_point(screen_pos)
