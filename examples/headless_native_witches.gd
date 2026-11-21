extends GSGameCheckSuite

const LmBot := preload("../game/lm_bot.gd")
const LmGame := preload("../game/lm_game.gd")
const LmLevel := preload("../game/lm_level.gd")
const LmPlayer := preload("../game/lm_player.gd")

## What a witch hears, sees and does each tick ([method LmGame._watch]) is run by gs-sim's `GSSimWitches` when the
## library is there, and it must do what the script does: a bot round on every level, the players thrown in front of
## and behind the witches with their lights and noise seeded, run with [member LmGame.witch_verify] on, re-runs the

## script beside every native watch and finds no difference in the gaze, the rates or the noise; a world with
## [member LmGame.native_witches] off keeps the script. With no library the native half is skipped;
## [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.

# A web server would run the script while native servers run the library; both must catch the same players.
# Hit registration and lag compensation are not touched.

const SECTIONS := 4
const CHECKS := 7
const BOTS := 8
const TICKS := 2400
const RATE := 60
## Ticks between throws of the players at the witches: past a witch's reaction, so she listens and turns.
const THROW := 150
## Alternated blocks of ticks timed each way, and ticks per block.
const BENCH_REPS := 6
const BENCH_TICKS := 240

var _entered := 0
## Player key -> whether they stay loud until the next throw.
var _loud := {}
var _finished := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("Look at Me native witches")
	print("")
	_entered += 1
	print("the library has the witches")
	if not GSSim.has(&"witches"):
		print("  gs-sim's witches module is not loaded: the native half is skipped")
		var required := (OS.get_environment("GS_SIM_REQUIRE_NATIVE") if OS.has_environment("GS_SIM_REQUIRE_NATIVE") else OS.get_environment("GS_SIM_REQUIRE_NATIVE")) == "1"
		_check(not required, "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		_finished += 1
		_report_sections(_entered, _finished, 1, 1)
		return
	_check(LmGame.native_witches, "LmGame.native_witches is on without the game turning it on")
	_finished += 1

	_entered += 1
	print("a seeded bot round on every level, native against the script at every watch")
	LmGame.witch_verify = true
	LmGame.witch_checked = 0
	LmGame.witch_differ = 0
	var game := await _world()
	var bots := _join(game)
	await _settle()
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5eed
	var modes := {}
	var heard := [0]
	game.listened.connect(func(_key: StringName, _witch: int) -> void: heard[0] += 1)
	for t in TICKS:
		if t % THROW == 0:
			_throw(game, rng)
		_keep_loud(game)
		_tick(game, bots)
		for player: LmPlayer in game.players.values():
			for state: Dictionary in player.gaze.values():
				modes[int(state["mode"])] = true
		if t % 32 == 0:
			await get_tree().physics_frame
	LmGame.witch_verify = false
	_check(game._witches != null, "the world runs its witches in gs-sim")
	_check(LmGame.witch_checked >= TICKS, "the watches were compared", "%d compared" % LmGame.witch_checked)
	_check(LmGame.witch_differ == 0, "every watch gave the same gaze, rates and noise", "%d of %d differ" % [LmGame.witch_differ, LmGame.witch_checked])
	_check(modes.size() >= 4 and heard[0] > 0, "the witches walked, listened, turned and ran", "modes %s, %d listens" % [modes.keys(), heard[0]])
	print("  %d watches compared, modes %s, %d listens" % [LmGame.witch_checked, modes.keys(), heard[0]])
	_finished += 1

	_entered += 1
	await _script_world()
	_finished += 1

	_entered += 1
	print("the tick either way, in alternated blocks on the same world")
	var spent := {"native": [], "script": []}
	for rep in BENCH_REPS:
		for mode: String in (["native", "script"] if rep % 2 == 0 else ["script", "native"]):
			LmGame.native_witches = mode == "native"
			var start := Time.get_ticks_usec()
			for t in BENCH_TICKS:
				if t % THROW == 0:
					_throw(game, rng)
				_keep_loud(game)
				_tick(game, bots)
			(spent[mode] as Array).append(float(Time.get_ticks_usec() - start) / float(BENCH_TICKS))
			await get_tree().physics_frame
	LmGame.native_witches = true
	var native := _median(spent["native"])
	var script := _median(spent["script"])
	print("  median us per tick (%d players): native %.1f, script %.1f (%.2fx)" % [game.players.size(), native, script, script / maxf(native, 0.001)])
	_check(native > 0.0 and script > 0.0, "both ways ran")
	await _dispose(game)
	_finished += 1

	_report_sections(_entered, _finished, SECTIONS, CHECKS)


## A world with [member LmGame.native_witches] off keeps the script.
func _script_world() -> void:
	print("native_witches off keeps the script")
	LmGame.native_witches = false
	var off := await _world()
	var off_bots := _join(off)
	await _settle()
	for _t in 120:
		_tick(off, off_bots)
	LmGame.native_witches = true
	_check(off._witches == null, "a script world builds no native witches")
	await _dispose(off)


## A server's house, as the soak makes it.
func _world() -> LmGame:
	var game := LmGame.new()
	game.draws = false
	game.self_tick = false
	game.register_service = false
	game.tick_rate = RATE
	game.config.winners_file = "user://native_witches_winners.json"
	add_child(game)
	await get_tree().physics_frame
	return game


## Bots on every level the house has: one each, round and round.
func _join(game: LmGame) -> Array[LmBot]:
	var bots: Array[LmBot] = []
	var numbers: Array = game.levels.keys()
	numbers.sort()
	for i in BOTS:
		var key := StringName("u%d" % (900200 + i))
		var player := game.join(key, "Bot%d" % i)
		player.best = 99
		game.send_to(player, int(numbers[i % numbers.size()]))
		bots.append(LmBot.new(game, key))
	return bots


func _settle() -> void:
	# The house's bodies are in the physics space only after a physics frame.
	await get_tree().physics_frame
	await get_tree().physics_frame


func _tick(game: LmGame, bots: Array[LmBot]) -> void:
	var delta := 1.0 / float(RATE)
	for bot in bots:
		bot.drive(delta)
	game.step(delta)


## Every player to a seeded spot near one of their level's witches: in front, behind, beside,
## near and far, lit or dark, loud or quiet, so every sense and mode is asked.
func _throw(game: LmGame, rng: RandomNumberGenerator) -> void:
	for player: LmPlayer in game.players.values():
		var level := game.level_of(player)
		if level == null or level.witches.is_empty() or player.caught_left > 0.0:
			continue
		var i := rng.randi_range(0, level.witches.size() - 1)
		var pose := level.witch_pose(i, game.seconds_now(), game.config.witch_speed_scale, game.config.witch_head_sweep, game.config.witch_door_seconds)
		var angle := rng.randf_range(-PI, PI)
		var reach := rng.randf_range(1.0, 14.0)
		var at: Vector3 = level.position + (pose["at"] as Vector3) + Vector3(sin(angle) * reach, 0.1, cos(angle) * reach)
		player.place_at(at, rng.randf_range(0.0, 360.0))
		player.flashlight = rng.randf() < 0.5
		player.meter = minf(player.meter, 0.5)
		_loud[player.player_key] = rng.randf() < 0.5
		if rng.randf() < 0.2:
			player.voice_left = game.config.witch_voice_seconds


## The loud players keep making noise until they are thrown again.
func _keep_loud(game: LmGame) -> void:
	for player: LmPlayer in game.players.values():
		if _loud.get(player.player_key, false):
			player.noise_left = game.config.witch_noise_seconds


func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2]) if not sorted.is_empty() else 0.0


func _dispose(game: LmGame) -> void:
	game.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame
