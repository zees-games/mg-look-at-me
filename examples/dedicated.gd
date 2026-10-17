extends Node

## The game as a deployed server runs it: a real [DotServer], the world from the server scene,
## the module loaded BY PATH the way an operator names it.
##
##   godot --headless --path . res://examples/dedicated.tscn

const LmGame := preload("../game/lm_game.gd")

const SECTIONS := 7
const CHECKS := 25

const SERVER_DIR := "user://lm_dedicated"
const PORT := 28951
const QUERY_PORT := 28952
const TICK_RATE := 60

var _passed := 0
var _failed := 0
var _entered := 0
var _finished := 0
var _failures := PackedStringArray()

var server: DotServer = null
var scene: Node = null
var game: LmGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("look at me as a dedicated server")
	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()

	if server != null and server.state == DotServer.State.RUNNING:
		await _test_the_module_loads()
		_test_the_console()
		await _test_stand_ins()
		_test_an_empty_server()
		await _test_it_unloads()

	_test_no_message_preloads_itself()

	print("")
	print("%d sections entered, %d finished" % [_entered, _finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _entered != SECTIONS or _finished != SECTIONS:
		print("ERROR: %d of %d sections finished, %d declared." % [_finished, _entered, SECTIONS])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d declared. A section aborted part-way." % [_passed + _failed, CHECKS])
		code = 1

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)
	get_tree().quit(code)


## A booted server's listener holds the main loop: take it down before quitting, or the run
## prints its results and hangs.
func _shut_down() -> void:
	if server == null:
		return

	if server.modules != null:
		server.modules.unload_all()

	server.shutdown("the dedicated test is finished")

	for _i in range(10):
		await get_tree().process_frame

	if is_instance_valid(scene):
		remove_child(scene)
		scene.free()

	if is_instance_valid(server):
		remove_child(server)
		server.free()

	await get_tree().process_frame


func _boot() -> void:
	_section("booting")
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_line("sv_tickrate %d" % TICK_RATE)
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	config.autoexec_config = ""
	config.hostname = "look at me test"
	config.max_players = 16
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.port = PORT
	config.query_port = QUERY_PORT
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)

	for _i in range(120):
		await get_tree().process_frame

		if server.state == DotServer.State.RUNNING:
			break

	_check(server.state == DotServer.State.RUNNING, "the server boots", DotServer.State.keys()[server.state])
	_check(Engine.physics_ticks_per_second == TICK_RATE, "and sv_tickrate reached the engine")
	_finished_section()


func _test_the_module_loads() -> void:
	_section("the module")
	scene = (load("res://scenes/lm_server.tscn") as PackedScene).instantiate()
	add_child(scene)
	await get_tree().process_frame
	game = DotRegistry.get_node_service(LmGame.SERVICE) as LmGame
	_check(game != null and game.levels.size() == 32, "the server scene builds the house and publishes it")
	_check(game != null and not game.draws, "and draws nothing")
	game.config.winners_file = "%s/winners.json" % SERVER_DIR
	var loaded: DotResult = await server.modules.load_module("res://game/lm_module.gd")
	_check(loaded.ok, "the module loads into the server", loaded.error.message if not loaded.ok else "")
	var module := _module()
	_check(module != null and module.get("net") != null and module.get("bridge") != null, "with its netcode and bridge")
	var net: DotNetManager = module.get("net") if module != null else null
	_check(net != null and net.config.enable_prediction and absf(net.config.world_extent - LmGame.NET_WORLD_EXTENT) < 0.01,
		"predicting players, against the extent a client decodes with")
	_finished_section()


func _test_the_console() -> void:
	_section("the console")
	_check(_said(_run_command("lm_status"), "levels"), "lm_status describes the house")
	_check(_said(_run_command("lm_winners"), "winners (0)"), "lm_winners lists nobody yet")
	_check(_said(_run_command("lm_send nobody 3"), "Nobody called"), "lm_send refuses somebody who is not here")
	_check(_module().get("vote") != null and _said(_run_command("lm_house"), "asylum"), "the house vote is built, and lm_house lists the houses")

	# The map menu's server half (M): the owner's flag changes the house now, anybody else
	# gets a nomination and a rock-the-vote. Contexts as dot-server makes them for a chat line.
	var menu_half: Object = _module().get("vote").get("commands").get("map_menu")
	_check(menu_half != null and server.console.find_command("mapmenu") != null
		and server.console.find_cvar("sv_map_menu_flag").get_string() == "generic"
		and (menu_half.get("change_fn") as Callable).is_valid(),
		"the map menu is there, staff-only by default, changing the house now")
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var player := DotCmdContext.new()
	player.source = DotCmdContext.Source.CHAT
	var offered: Dictionary = menu_half.call("offer", player)
	_check((offered["maps"] as Array).size() > 1 and not bool(offered["allowed"]) and bool(offered["vote"]),
		"a player is offered every house, as a vote")
	var target: StringName = &""
	for row: Dictionary in offered["maps"]:
		if not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var changed: Dictionary = await menu_half.call("choose", staff, target)
	_check(bool(changed["ok"]) and game.house_id == target, "staff choosing one changes the house on the spot",
		"%s: %s" % [target, changed.get("text", "")])
	var _a := _run_command("lm_house asylum")
	_check(game.house_id == &"asylum" and game.levels.size() == 17, "lm_house asylum opens it")
	var _h := _run_command("lm_house house")
	_finished_section()


func _test_stand_ins() -> void:
	_section("the house runs with nobody in it")
	var before := game.tick
	await _seconds(1.0)
	_check(game.tick > before + 30, "the house ticks on the server's clock", "%d ticks" % (game.tick - before))
	_finished_section()


## Nobody connected. With hibernation off (this suite's server) the house's time running out
## changes the house on its own, at random; with it on, the clock waits and starts again from
## the top on waking. DotGameModule hands the director the server; this game writes no line.
func _test_an_empty_server() -> void:
	_section("an empty server: a new house on its own, or a clock that waits")
	var vote: Node = _module().get("vote")
	var director: DotVoteDirector = vote.get("director") if vote != null else null

	if director == null:
		_check(false, "the house vote is built")
		_finished_section()
		return

	_check(server.hibernation_changed.is_connected(director.set_hibernating),
		"the house vote follows the server's hibernation")

	# The vote's lines go through this game's chat router, which is what the box draws.
	# dot-server's system chat reaches no box in this game.
	var chat: Object = _module().get("services").get("chat") if _module().get("services") != null else null
	var heard: Array[String] = []
	var hear := func(message: Object, _to: PackedInt32Array) -> void: heard.append(str(message.get("text")))

	if chat != null:
		chat.connect("message_accepted", hear)

	(vote.get("announce_fn") as Callable).call("Vote: The House, The Asylum (30s)")
	_check(heard.has("Vote: The House, The Asylum (30s)"),
		"the house vote announces through the game's chat router, which the box draws", str(heard))

	if chat != null:
		chat.disconnect("message_accepted", hear)

	var before := game.house_id
	director.advance(director.clock.remaining + 1.0)
	_check(game.house_id != before and game.houses.has(game.house_id),
		"the house's time running out with nobody here opens another house", "%s -> %s" % [before, game.house_id])

	server.console.execute("sv_hibernate_when_empty 1")
	var asleep_on := game.house_id
	director.advance(director.clock.remaining + 1.0)
	_check(server.is_hibernating() and game.house_id == asleep_on,
		"hibernating, the same wait changes nothing", server.state_name())
	server.console.execute("sv_hibernate_when_empty 0")
	_check(not director.hibernating, "waking wakes the vote")
	_check(is_equal_approx(director.clock.remaining, director.clock.duration),
		"with the house's whole time limit ahead of it", director.clock.formatted_remaining())
	_finished_section()


func _test_it_unloads() -> void:
	_section("unloading")
	server.modules.unload_all()
	await get_tree().process_frame
	_check(_module() == null, "the module unloads")
	_check(is_instance_valid(game), "and leaves the world, which outlives it")
	_finished_section()


## A message script that preloads itself leaks the whole script graph at exit
## (mg-buses-from-hell's 8ed866c), after quit(), where no assertion reaches: checked on the source.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")
	var offenders := PackedStringArray()

	for file in DirAccess.open("res://game/net").get_files():
		if file.ends_with(".gd"):
			var source := FileAccess.get_file_as_string("res://game/net/" + file)

			if source.contains("extends DotNetMessage") and source.contains("preload(\"%s\")" % file):
				offenders.append(file)

	_check(offenders.is_empty(), "no message preloads itself", ", ".join(offenders))
	_finished_section()


# --- Harness -----------------------------------------------------------------

func _module() -> DotModule:
	return server.modules.get_module("lookatme") if server != null and server.modules != null else null


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, context)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true

	return false


func _seconds(s: float) -> void:
	var until := Time.get_ticks_msec() + int(s * 1000.0)

	while Time.get_ticks_msec() < until:
		await get_tree().physics_frame


func _section(name: String) -> void:
	_entered += 1
	print("")
	print(name)


func _finished_section() -> void:
	_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	else:
		_failed += 1
		var line := what if detail == "" else "%s  (%s)" % [what, detail]
		_failures.append(line)
		print("  FAIL  %s" % line)
