extends RefCounted

## The phone's controls: gs-mobile's stick, drag-look and buttons over the HUD, driving the client's own
## [GSFpsTouchSampler]. Buttons: use, flashlight, jump and crouch, and one for every key the keyboard has: camera (F5),
## command line, scoreboard (Tab, held), map list (M), look-to-gag and look-to-mute (G, K). Help (H) is the menu's own button.

## Not a shooter: no crosshair, no auto-fire and no aim assist. The client turns a press into what the key would have done.

const SelfScript := preload("lm_touch.gd")

## The margin the layout checks fit the cluster inside.
const EDGE_MARGIN := 20.0

var controls: GSMobileControls = null
## gs-ui's buttons inside the overlay, for the shell's DPI fit.
var buttons: GSTouchButtons:
	get:
		return controls.buttons if controls != null else null

## A press (true) or a release (false) of a declared button.
var on_button: Callable = Callable()


## Whether this device wants them.
static func wanted() -> bool:
	return GSPlatform.has_touch()


## gs-game's platformer preset without sprint and chat, plus the flashlight in the corner home and a button for every key
## the keyboard has. Help (H) is the menu's own button, which opens "Help & commands".
static func touch_layout() -> GSGameTouchLayout:
	var res := GSGameTouchLayout.build(GSGameTouchLayout.PLATFORMER, {
		GSGameTouchLayout.SPRINT: null,
		GSGameTouchLayout.CHAT: null,
		GSGameTouchLayout.CAMERA: &"row1",
		GSGameTouchLayout.COMMAND: &"row2",
		GSGameTouchLayout.MAPS: &"row4",
		GSGameTouchLayout.GAG: &"secondary",
		GSGameTouchLayout.MUTE: &"inner",
		&"flashlight": {"slot": &"corner", "label": "LIGHT"},
	})
	if not res.ok:
		push_error("mg-look-at-me touch layout refused: %s" % str(res.error))
		return GSGameTouchLayout.custom()
	return res.value


## The layout as gs-mobile takes it: jump and crouch are held on the sampler by the overlay.
static func overlay_layout() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for b: Dictionary in touch_layout().buttons():
		var copy := b.duplicate()
		if copy["id"] == GSGameTouchLayout.JUMP:
			copy["hold"] = GSFpsCommand.BUTTON_JUMP
		elif copy["id"] == GSGameTouchLayout.CROUCH:
			copy["hold"] = GSFpsCommand.BUTTON_CROUCH
		out.append(copy)
	return out


## Builds the overlay under [param host] (the HUD) driving [param sampler]. [param menu_fn] returns the menu's own button
## (or null), whose corner is left to it. Never null.
static func build(host: Control, sampler: GSFpsSampler, menu_fn: Callable = Callable()) -> RefCounted:
	var made: RefCounted = (SelfScript as GDScript).new()
	made.call(&"_setup", host, sampler, menu_fn)
	return made


func _setup(host: Control, sampler: GSFpsSampler, menu_fn: Callable) -> void:
	controls = GSMobileControls.new()
	controls.name = "TouchControls"
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if menu_fn.is_valid():
		controls.ignore_fn = func(at: Vector2) -> bool:
			var menu_button := menu_fn.call() as Button
			return menu_button != null and menu_button.is_visible_in_tree() and menu_button.get_global_rect().has_point(at)
	controls.setup(sampler, overlay_layout())
	controls.button_pressed.connect(func(id: StringName) -> void: _emit(id, true))
	controls.button_released.connect(func(id: StringName) -> void: _emit(id, false))
	host.add_child(controls)


## Hands the overlay the sampler the client drives now (offline and connected play each have one).
func use_sampler(sampler: GSFpsSampler) -> void:
	if controls != null and sampler != null:
		controls.setup(sampler, overlay_layout())


## True when the overlay is up and forwards [param event] itself, or [param event] is the mouse Godot emulates
## from a touch, which would turn the view a second time.
func takes(event: InputEvent) -> bool:
	if controls == null or not controls.touch:
		return false
	return controls.takes(event) or (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION)


func active() -> bool:
	return controls != null and controls.touch


## Called every frame by the client: the overlay hides and lets go under the cover, a menu or the command line.
func sync(busy: bool) -> void:
	if controls != null:
		controls.paused = busy


func describe() -> Dictionary:
	return controls.describe() if controls != null else {"built": false}


func _emit(id: StringName, down: bool) -> void:
	if on_button.is_valid():
		on_button.call(id, down)
