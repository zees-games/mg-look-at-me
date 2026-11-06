extends DotGameCheckSuite

const LmTouch := preload("../game/lm_touch.gd")

## The touch layout: a button for every key a keyboard player has, in dot-game's slots, inside the design canvas and
## clear of each other (the fit to a real phone is dot-game's headless_screen_fit).
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 12

const KEYS := [&"use", &"jump", &"crouch", &"flashlight", &"board", &"chat", &"camera", &"house", &"help", &"gag", &"mute"]


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-look-at-me: touch buttons")
	var layout := LmTouch.layout()
	var ids: Array[StringName] = []
	for b: Dictionary in layout:
		ids.append(b["id"])
	var missing := []
	for id: StringName in KEYS:
		if not ids.has(id):
			missing.append(id)
	_check(missing.is_empty(), "every key has a button", str(missing))
	_check(not ids.has(&"sprint"), "no run button: this game has no sprint")
	_check(LmTouch.touch_layout().validate().ok, "dot-game accepts the layout")

	for size: Vector2 in [Vector2(1280, 720), Vector2(1600, 720)]:
		var buttons := DotTouchButtons.new()
		buttons.size = size
		buttons.set_buttons(layout)
		add_child(buttons)
		_check(Rect2(Vector2.ZERO, size).encloses(buttons.footprint()), "the cluster fits %dx%d" % [size.x, size.y], str(buttons.footprint()))
		var clash := ""
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				var gap := buttons.centre_of(ids[i]).distance_to(buttons.centre_of(ids[j])) - buttons.radius_of(ids[i]) - buttons.radius_of(ids[j])
				if gap < 4.0:
					clash = "%s and %s" % [ids[i], ids[j]]
		_check(clash == "", "no two buttons overlap at %dx%d" % [size.x, size.y], clash)
		buttons.free()

	var built := LmTouch.new()
	built.build()
	add_child(built)
	var seen: Array[StringName] = []
	built.pressed.connect(func(id: StringName) -> void: seen.append(id))
	built.buttons.button_down.emit(&"board")
	_check(seen == [&"board"], "a press is the client's to hear")
	_check(built.contains_point(built.buttons.centre_of(&"use")), "a finger on a button is not the look sampler's")
	_check(not built.contains_point(Vector2(10, 10)), "the top-left corner is free for the menu button")
	built.free()

	DotPlatform.touch_override = 0
	_check(not LmTouch.wanted(), "no touch: the client builds no buttons")
	var off := DotTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	DotPlatform.touch_override = -1
	_report(CHECKS)
