extends DotGameCheckSuite

## The on-screen buttons: the layout fits a phone's right half without overlap, the buttons are the game's actions, and a finger on a button is kept off the look sampler.
##   godot --headless --path . res://examples/headless_touch.tscn

const LmSettings := preload("../game/lm_settings.gd")
const LmClientWorld := preload("../game/lm_client_world.gd")
const CHECKS := 15


func _ready() -> void:
	DotLog.set_level(DotLog.Level.FATAL)
	_run.call_deferred()


func _run() -> void:
	print("mg-look-at-me: touch controls")
	var list: Array[Dictionary] = LmClientWorld.TOUCH_LAYOUT
	var ids: Array = list.map(func(b: Dictionary) -> Variant: return b["id"])
	for want: StringName in [&"use", &"flash", &"jump", &"crouch"]:
		_check(ids.has(want), "the layout has the %s button" % want)
	var probe := DotTouchButtons.new()
	var m := probe.margin
	probe.free()
	for size: Vector2 in [Vector2(667, 375), Vector2(844, 390), Vector2(932, 430)]:
		var clear := true
		var inside := true
		for i in list.size():
			var a: Vector2 = size - Vector2(m, m) - (list[i]["offset"] as Vector2)
			var ra: float = list[i]["radius"]
			inside = inside and a.x - ra >= size.x * 0.5 and a.y - ra >= 0.0 and a.x + ra <= size.x and a.y + ra <= size.y
			for j in range(i + 1, list.size()):
				var b: Vector2 = size - Vector2(m, m) - (list[j]["offset"] as Vector2)
				clear = clear and a.distance_to(b) >= ra + float(list[j]["radius"])
		_check(inside, "every button sits in the right half at %dx%d" % [size.x, size.y])
		_check(clear, "and no two overlap at %dx%d" % [size.x, size.y])

	var host := Control.new()
	host.size = Vector2(844, 390)
	add_child(host)
	var buttons := DotTouchButtons.new()
	buttons.only_on_touch = false
	buttons.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	buttons.set_buttons(list)
	host.add_child(buttons)
	await get_tree().process_frame
	_check(buttons.contains_point(buttons.centre_of(&"use")), "a point on the use button belongs to the buttons")
	_check(not buttons.contains_point(Vector2(100, 100)), "a point on the left half does not")

	var sampler := DotFpsTouchSampler.new(DotFpsTunables.new())
	sampler.ignore_fn = buttons.contains_point
	sampler.hold(DotFpsCommand.BUTTON_JUMP, true)
	_check((sampler.sample(0.016).buttons & DotFpsCommand.BUTTON_JUMP) != 0, "the jump button holds jump on the sampler")
	sampler.hold(DotFpsCommand.BUTTON_JUMP, false)
	_check((sampler.sample(0.016).buttons & DotFpsCommand.BUTTON_JUMP) == 0, "and releases it")
	sampler.ignore_fn = Callable()
	host.queue_free()

	var settings := LmSettings.new()
	var corner: Variant = settings.config.get(&"menu_button_corner")
	_check(corner == null or corner == &"top_left", "the menu button is top-left where dot-menu has a corner", str(corner))
	settings.free()
	_report(CHECKS)
