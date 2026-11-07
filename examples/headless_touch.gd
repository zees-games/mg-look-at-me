extends DotGameCheckSuite

const LmTouch := preload("../game/lm_touch.gd")

## The touch layout: the buttons fit a phone at three sizes without overlapping, and each DotTouchButtons is freed.
## Run: `godot --headless --path . res://examples/headless_touch.tscn`

const CHECKS := 13


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
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
			var buttons := DotTouchButtons.new()
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
	var want: Array = [&"use", &"jump", &"crouch", &"flashlight"]
	var got: Array = LmTouch.touch_layout().ids()
	got.sort()
	want.sort()
	_check(got == want, "the layout is the canonical use, jump, crouch and the flashlight", str(got))
	DotPlatform.touch_override = 0
	_check(not LmTouch.wanted(), "no touch: the client builds no buttons")
	var off := DotTouchButtons.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	DotPlatform.touch_override = -1
	_report(CHECKS)


func _min_diameter(layout: Array[Dictionary]) -> float:
	var least := INF
	for b: Dictionary in layout:
		least = minf(least, float(b["radius"]) * 2.0)
	return least
