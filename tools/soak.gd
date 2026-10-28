extends Node

const LmBot := preload("../game/lm_bot.gd")
const LmGame := preload("../game/lm_game.gd")
const LmPlayer := preload("../game/lm_player.gd")

## Bot soak: N stand-ins (LmBot) play one house (the "map") for M simulated minutes through
## dot-bot's DotBotSoak: `./game.sh soak [house] [minutes]`. Writes .godot/test-logs/soak-<house>.json,
## prints the SOAK line, exits 1 on failure. A stand-in is stuck only while it has a goal.

const DEFAULT_MAP := &"house"
const DEFAULT_MINUTES := 1.0
const DEFAULT_BOTS := 2
const TICK_RATE := 60

var _game: LmGame
var _bots: Array[LmBot] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := _arg("map", String(DEFAULT_MAP))
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))

	_game = LmGame.new()
	_game.name = "World"
	_game.draws = false
	_game.self_tick = false
	_game.register_service = false
	_game.tick_rate = TICK_RATE
	_game.config.winners_file = "user://soak_lookatme_winners.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(_game.config.winners_file))
	add_child(_game)
	await get_tree().physics_frame
	if not _game.houses.has(StringName(map_id)):
		printerr("SOAK setup failed: no house %s" % map_id)
		get_tree().quit(2)
		return
	var _changed := _game.change_house(StringName(map_id))
	_game.tick_rate = TICK_RATE

	var taken: Array = []
	for i in range(cfg.bots):
		var bot_name := DotBotNames.pick(taken, i, PackedStringArray(["Ada", "Bram", "Cleo", "Dov"]))
		taken.append(bot_name)
		var key := StringName("u%d" % (900100 + i))
		var _p := _game.join(key, bot_name)
		_bots.append(LmBot.new(_game, key))
	# The house's bodies are in the physics space only after a physics frame.
	await get_tree().physics_frame
	await get_tree().physics_frame

	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	watch.rules.kill_y = -5000.0

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		if soak.ticks % 32 == 0:
			await get_tree().physics_frame
	await _finish(map_id, soak)


func _finish(map_id: String, soak: DotBotSoak) -> void:
	var report := soak.finish()
	report["map"] = map_id
	var done := 0
	var did := 0
	var gave_up := 0
	var idle := 0.0
	var best := 0
	for bot in _bots:
		done += bot.levels_done
		did += bot.interacted
		gave_up += bot.gave_up
		idle += bot.idle_seconds
		best = maxi(best, bot.player().best)
	report["levels_done"] = done
	report["interactions"] = did
	report["deepest"] = best
	report["gave_up"] = gave_up
	report["idle_sec"] = snappedf(idle, 0.1)
	# A stand-in that never gets anywhere is a bot or a level that cannot be played.
	if did == 0:
		report["ok"] = false
		(report["reasons"] as Array).append("play: nothing was taken, used or opened")
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame
	get_tree().quit(0 if report["ok"] else 1)


func _step(delta: float) -> void:
	for bot in _bots:
		bot.drive(delta)
	_game.step(delta)
	if _game.tick % TICK_RATE == 0 and OS.get_cmdline_user_args().has("--trace"):
		for bot in _bots:
			print("TRACE t=%d %s %s" % [_game.tick / TICK_RATE, bot.key, bot.describe()])


func _movers() -> Array:
	var out: Array = []
	for bot in _bots:
		var body := bot.player()
		out.append({"id": bot.key, "position": body.global_position, "kind": &"bot",
			"has_goal": bot.has_goal() and body.caught_left <= 0.0})
	return out
