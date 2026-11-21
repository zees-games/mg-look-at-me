extends GSGameCheckSuite

const LmTouch := preload("../game/lm_touch.gd")

## The touch layout and dot-mobile's overlay: the buttons fit a phone at three sizes without overlapping, and each GSTouchButtons is freed.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 24


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-look-at-me: touch buttons")
	var sets: Dictionary = {"look": LmTouch.touch_layout().buttons()}
	for label: String in sets:
		var layout: Array[Dictionary] = sets[label]
		var ids: Array[StringName] = []
		for b: Dictionary in layout:
			ids.append(b["id"])
		_check(ids.size() >= 4, "%s: the layout has its buttons" % label)
		for size: Vector2 in [Vector2(844, 390), Vector2(667, 375), Vector2(932, 430)]:
			var buttons := GSTouchButtons.new()
			buttons.margin = LmTouch.EDGE_MARGIN
			buttons.size = size
			buttons.set_buttons(layout)
			add_child(buttons)
			_check(Rect2(Vector2.ZERO, size).encloses(buttons.footprint()), "%s: the cluster fits %dx%d" % [label, size.x, size.y], str(buttons.footprint()))
			var clash := ""
			for i in ids.size():
				for j in range(i + 1, ids.size()):
					var gap := buttons.centre_of(ids[i]).distance_to(buttons.centre_of(ids[j])) - buttons.radius_of(ids[i]) - buttons.radius_of(ids[j])
					if gap < 4.0:
						clash = "%s and %s" % [ids[i], ids[j]]
			_check(clash == "", "%s: no two buttons overlap at %dx%d" % [label, size.x, size.y], clash)
			_check(_min_diameter(layout) >= 44.0, "%s: every button is at least 44 px at %dx%d" % [label, size.x, size.y])
			buttons.free()
	var want: Array = [&"use", &"jump", &"crouch", &"flashlight", &"camera", &"command", &"board", &"maps", &"gag", &"mute"]
	var got: Array = LmTouch.touch_layout().ids()
	got.sort()
	want.sort()
	_check(got == want, "the layout is the canonical use, jump, crouch, the flashlight, and a button for the camera, command line, scoreboard, map list, gag and mute keys", str(got))
	GSPlatform.touch_override = 0
	_check(not LmTouch.wanted(), "no touch: the client builds no buttons")
	var off := GSTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	GSPlatform.touch_override = -1
	_overlay()
	_report(CHECKS)


## dot-mobile's overlay on a HUD-typed host (a Control, as the client's is): it drives the client's own sampler.
func _overlay() -> void:
	GSPlatform.touch_override = 1
	var host := Control.new()
	host.size = Vector2(844, 390)
	add_child(host)
	var sampler := GSFpsTouchSampler.new(GSFpsTunables.new())
	var menu_button := Button.new()
	menu_button.position = Vector2(4, 4)
	menu_button.size = Vector2(80, 40)
	host.add_child(menu_button)
	var touch: RefCounted = LmTouch.build(host, sampler, func() -> Button: return menu_button)
	var pressed: Array = []
	touch.set(&"on_button", func(id: StringName, down: bool) -> void: pressed.append([id, down]))
	var controls: GSMobileControls = touch.get(&"controls")
	_check(controls != null and controls.touch and controls.sampler == sampler, "the overlay drives the client's own sampler", str(touch.call(&"describe")))
	_check(not controls.effective.autofire, "auto-fire is off by default (not a shooter)")
	_check(not controls.effective.aim_assist, "aim assist is off by default")
	var ids: Array = []
	for b: Dictionary in LmTouch.overlay_layout():
		ids.append(b["id"])
	ids.sort()
	var want: Array = LmTouch.touch_layout().ids()
	want.sort()
	var placed := true
	for id: StringName in ids:
		placed = placed and controls.buttons.radius_of(id) > 0.0
	_check(ids == want and placed and ids.size() == 10, "every button the layout declares is built: use, jump, crouch, light, camera, command, board, maps, gag, mute", str(ids))
	var tap := InputEventScreenTouch.new()
	tap.pressed = true
	var fake := InputEventMouseMotion.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	_check(bool(touch.call(&"takes", tap)) and bool(touch.call(&"takes", fake)), "it takes touches and the mouse emulated from them")
	var clash := false
	for id: StringName in ids:
		clash = clash or controls.buttons.centre_of(id).distance_to(Vector2(44, 24)) < controls.buttons.radius_of(id) + 40.0
	_check(not clash, "no button sits on the menu's corner")
	_check(controls.ignore_fn.call(Vector2(10, 10)) and not controls.ignore_fn.call(Vector2(400, 200)), "a touch on the menu button is left to the menu")
	controls.buttons.button_down.emit(&"flashlight")
	_check(pressed == [[&"flashlight", true]], "a button press reaches the client's handler", str(pressed))
	var finger := InputEventScreenTouch.new()
	finger.index = 3
	finger.pressed = true
	finger.position = controls.buttons.centre_of(&"jump")
	controls.buttons._input(finger)
	_check((sampler.sample(1.0 / 60.0).buttons & GSFpsCommand.BUTTON_JUMP) != 0, "jump is held on the sampler while it is down")
	touch.call(&"sync", true)
	_check(not controls.visible and not bool(touch.call(&"active")), "a menu or the command line pauses it")
	touch.call(&"sync", false)
	_check(bool(touch.call(&"active")), "and closing it brings it back")
	host.free()
	GSPlatform.touch_override = -1


func _min_diameter(layout: Array[Dictionary]) -> float:
	var least := INF
	for b: Dictionary in layout:
		least = minf(least, float(b["radius"]) * 2.0)
	return least
