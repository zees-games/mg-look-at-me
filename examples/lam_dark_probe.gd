extends "headless_run_base.gd"

func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	game = LmGame.new()
	game.draws = false
	game.self_tick = false
	add_child(game)
	await get_tree().physics_frame
	var solver := game.join(&"solver", "Solver")
	for h: StringName in [&"ashpit", &"mallparking"]:
		var r := game.change_house(h)
		var ok: bool = r.ok
		print("refused ", game.refused); print("%s changed=%s levels=%d houses=%s" % [h, ok, game.levels.size(), str(game.houses.keys())])
		if not ok: print("  err ", r.error.message if r.error else "?"); continue
		var stuck := _solve_house(solver)
		_check(ok and game.levels.size() == 1 and stuck.is_empty(), "%s solves" % h, ", ".join(stuck))
		var lv: LmLevel = game.levels[1]
		print("  rooms=%d witches=%d" % [lv.rooms.size(), lv.witches.size()])
		var drawn := LmLevel.new()
		add_child(drawn)
		var _b := drawn.build(lv.doc, true)
		var res := DotCollisionAudit.audit(drawn, true)
		var n: int = res.value.count() if res.ok else -1
		print("  audit findings=%d" % n)
		if res.ok:
			for line in res.value.describe_lines().slice(1, 8): print("    ", line)
		_check(res.ok and n == 0, "%s audit" % h)
		drawn.queue_free()
	print("RESULT checks failed=%d" % _failed)
	get_tree().quit(0 if _failed == 0 else 1)
