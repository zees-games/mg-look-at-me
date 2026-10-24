extends Node

## The game as a deployed server runs it: a real [DotServer], the world from the server scene,
## the module loaded BY PATH the way an operator names it.
##
##   godot --headless --path . res://examples/dedicated.tscn

const LmGame := preload("../game/lm_game.gd")
const LmNetBridge := preload("../game/net/lm_net_bridge.gd")
const LmNetLink := preload("../game/net/lm_net_link.gd")

const SECTIONS := 10
const CHECKS := 57

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
		await _test_a_covered_seat_is_not_caught()
		_test_rotation_file()
		await _test_a_reload_leaves_one_link()
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
	_noblock_and_config(module)
	_finished_section()


## Config cvars, the workbench, and dot-team's block rules through dot-game's DotGameNoblock.
func _noblock_and_config(module: DotModule) -> void:
	var teamblock := server.console.find_cvar("mp_teamblock")
	var enemyblock := server.console.find_cvar("mp_enemyblock")
	_check(teamblock != null and teamblock.get_string() == "0" and enemyblock != null and enemyblock.get_string() == "1",
		"mp_teamblock is 0 and mp_enemyblock is 1 by default")
	_check(server.console.has_name("lm_run_speed") and server.console.has_name("lm_slam_clear") and server.console.has_name("lm_demon_max"),
		"config fields are lm_ cvars, the scares' among them")
	_check(module.get("workbench") != null, "the module hosts the workbench")
	var rotation := server.console.find_cvar("sv_map_rotation_file")
	game.config.map_rotation_file = "cfg/other.yml"
	module.call("_on_config_field", "map_rotation_file", game.config.map_rotation_file, "workbench")
	_check(rotation.get_string() == "cfg/other.yml", "a workbench edit reaches the hand-written rotation cvar", rotation.get_string())
	rotation.set_value("cfg/maps.yml")
	var a := game.join(&"uid:91", "Walker")
	var b := game.join(&"uid:92", "Other")
	_check(game.body_rules.solid and not game.body_rules.blocks(&"uid:91", &"uid:92"), "everybody is one side, so with mp_teamblock 0 players pass")
	teamblock.set_value("1")
	_check(game.body_rules.blocks(&"uid:91", &"uid:92"), "mp_teamblock 1 makes them block")
	teamblock.set_value("0")
	game.leave(&"uid:91")
	game.leave(&"uid:92")
	_check(a != null and b != null, "both players were seated")


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
	_check(game.house_id == &"asylum" and game.levels.size() == 18, "lm_house asylum opens it")
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


## [b]A seat whose client has not lifted its loading cover cannot be caught, and can once it does[/b]
## (dot-game's "still loading"), over a real ENet socket. A client joins and says nothing, as one
## still loading its level; a fright it reports (the one way the meter is raised by a client) is
## refused and a witch's look leaves the meter alone. It then sends `game.cover` on the wire and
## the same fright lands. Stand-ins never reach this: a bot is never loading.
func _test_a_covered_seat_is_not_caught() -> void:
	_section("a client behind its loading cover is not caught, and is once it lifts")

	var module := _module()
	var bridge := module.get("bridge") as LmNetBridge if module != null else null
	var side := Node.new()
	side.name = "CoverClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Covered"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	# RPC paths are relative to the multiplayer root, so the link must sit at the path the
	# server's does: "Dedicated/Server" under the root.
	var mirror := Node.new()
	mirror.name = "Dedicated"
	side.add_child(mirror)
	mirror.add_child(link)
	# The link retires whatever the game left under it when it signs on, so a sink for the
	# server's snapshots is put back at each phase change (a real game scene does this itself).
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(LmNetLink.NODE_NAME)) == null:
			var sink := LmNetLink.attached_to(link, null, false)
			sink.name = LmNetLink.NODE_NAME
			link.add_child(sink)
	attach.call()
	link.phase_changed.connect(attach)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var joined := await _until(func() -> bool:
		return spawned[0] or link.phase == DotClientLink.Phase.FAILED, 30.0)
	joined = joined and spawned[0]
	var peer := side.multiplayer.get_unique_id() if joined else 0
	var key: StringName = &""
	if bridge != null and joined:
		var _seated := await _until(func() -> bool: return bridge.key_of_peer(peer) != &"", 10.0)
		key = bridge.key_of_peer(peer)
	var victim: Object = game.players.get(key)
	_check(victim != null, "a client joins over the socket and is seated", "peer %d key %s" % [peer, key])

	if victim == null:
		for what in [
			"the server holds it as loading", "a reported fright does not raise its meter",
			"a witch's look (and the drain) leaves its meter alone", "its cover report crosses the wire",
			"and the same fright now lands", "and the meter is stepped again",
		]:
			_check(false, what)
		link.disconnect_from_server("done")
		side.queue_free()
		_finished_section()
		return

	game.config.demons_enabled = true
	victim.meter = 0.0
	victim.spooked_at = -100.0
	_check(bool(module.call("is_peer_loading", peer)) and not game.can_be_harmed(key),
		"the server holds it as loading from its spawn")
	_check(not game.spook(key, 0.4) and victim.meter == 0.0, "a reported fright does not raise its meter",
		"meter %s" % victim.meter)
	# Left to itself an unseen meter drains, so a meter that stays put was not stepped at all.
	victim.meter = 0.5
	victim.unseen_for = 999.0
	game._watch(victim, game.seconds_now(), 0.5)
	_check(is_equal_approx(victim.meter, 0.5), "a witch's look (and the drain) leaves its meter alone",
		"meter %s" % victim.meter)

	DotGameClient.report_cover(link, false)
	var lifted := await _until(func() -> bool: return not bool(module.call("is_peer_loading", peer)), 10.0)
	_check(lifted and game.can_be_harmed(key), "its cover report crosses the wire and ends the loading state")
	victim.spooked_at = -100.0
	_check(game.spook(key, 0.4) and victim.meter > 0.0, "and the same fright now lands", "meter %s" % victim.meter)
	victim.meter = 0.5
	victim.unseen_for = 999.0
	game._watch(victim, game.seconds_now(), 0.5)
	_check(victim.meter < 0.5, "and the meter is stepped again", "meter %s" % victim.meter)

	link.disconnect_from_server("done")
	side.queue_free()
	_finished_section()


## [b]A module loaded again leaves one link under the server[/b], the live one still named
## `LookAtMe`. The link is the server's child, not the bridge's, so the bridge going away left it
## and the next one was named `@Node@n`, and a client's RPCs addressed a path nothing had.
func _test_a_reload_leaves_one_link() -> void:
	_section("a module loaded again leaves one net link")
	server.modules.unload_all()
	await get_tree().process_frame
	var stale := 0
	for child in server.get_children():
		if child is LmNetLink and not String(child.name).begins_with(DotGameLink.RETIRED):
			stale += 1
	_check(stale == 0, "unloading takes the link off the server", "%d left" % stale)
	var loaded: DotResult = await server.modules.load_module("res://game/lm_module.gd")
	_check(loaded.ok, "and the module loads again", loaded.error.message if not loaded.ok else "")
	var links := 0
	for child in server.get_children():
		if child is LmNetLink and not String(child.name).begins_with(DotGameLink.RETIRED):
			links += 1
	_check(links == 1 and server.get_node_or_null(NodePath(LmNetLink.NODE_NAME)) is LmNetLink,
		"leaving one link, under its own name", "%d links" % links)
	_finished_section()


## Stands in for the module a vote's commands are registered on, recording the names.
class CommandHost extends Node:
	var added: Dictionary = {}

	func add_command(full: String, fn: Callable, _help: String, _permission: String) -> Object:
		added[full] = fn
		return null


## `cfg/maps.yml`: which houses rotate. The format is dot-map's selftest's; this is what the GAME
## does with it: a house left out is installed and loadable and is never drawn, never on a
## ballot, never nominated, marked in the map list; a switch of rotation takes effect; a renamed
## command is registered; no file means every house.
func _test_rotation_file() -> void:
	_section("rotation file")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var dir: String = str(game.houses[&"asylum"]["directory"])
	var made: Array[StringName] = []

	for n in 4:
		var id := StringName("rot_%d" % n)
		game.houses[id] = {"name": "Rotation %d" % n, "directory": dir}
		made.append(id)

	var keep_a: Array = ["house", "rot_0"]
	var keep_b: Array = ["rot_2", "rot_3"]
	var parsed := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "a",
		"rotations": {"a": {"maps": keep_a, "mode": "random"}, "b": {"maps": keep_b, "mode": "cycle"}},
		"commands": {"names": {"rtv": "rockit", "lm_house": "gohouse"}},
	}}], "mg-look-at-me")
	_check(parsed.ok, "a rotation file parses", str(parsed.error))
	var kept = game.rotation_file
	game.rotation_file = parsed.value
	game.apply_rotation()

	var drawn := {}
	for _i in 30:
		var id := game.next_house()
		drawn[String(id)] = true
		game._rotation.note_played(id)
		game._rotation.seed_value += 1
	var strays := drawn.keys().filter(func(id: String) -> bool: return not keep_a.has(id))
	_check(not drawn.is_empty() and strays.is_empty(), "a house outside the rotation is never drawn", str(strays))
	_check(game.houses.has(&"rot_2") and not game.rotating_ids().has(&"rot_2") and not game.in_rotation(&"rot_2"),
		"and stays installed but is not what the rotation offers")

	if vote != null:
		vote.call("refresh_houses")
		var ballot: Array = []
		for choice in (vote.get("source") as DotVoteListSource).entries:
			ballot.append(String(choice.id))
		_check(ballot.has("rot_0") and not ballot.has("rot_2") and not ballot.has("asylum"),
			"never on a ballot", str(ballot))
		var refused := _run_command("nominate rot_2")
		_check(not _said(refused, "Nominated"), "refused by nominate", ", ".join(refused))
		var accepted := _run_command("nominate rot_0")
		# A ballot may be running already, which refuses any nomination; what matters is that a
		# house in the rotation is known to nominate and an unlisted one is not.
		_check(not _said(accepted, "nothing called"), "while one in the rotation is known to it", ", ".join(accepted))
	else:
		_check(false, "never on a ballot", "no vote")
		_check(false, "refused by nominate", "no vote")
		_check(false, "while one in the rotation is known to it", "no vote")

	var out_row: Dictionary = {}
	var in_row: Dictionary = {}
	for row: Dictionary in game.house_rows():
		if row["id"] == "rot_2":
			out_row = row
		elif row["id"] == "rot_0":
			in_row = row
	_check(not out_row.is_empty() and not bool(out_row["in_rotation"])
			and str(out_row["name"]).contains("not in rotation"), "the house list marks it")
	_check(not in_row.is_empty() and bool(in_row["in_rotation"])
			and not str(in_row["name"]).contains("not in rotation"), "and leaves the rotating ones alone")

	var before := game.house_id
	_check(game.change_house(&"rot_2").ok and game.house_id == &"rot_2",
		"while an admin's house change still loads it", str(game.house_id))

	_check(game.switch_rotation("b").ok and game.rotating_ids().size() == 2
			and game.rotating_ids().has(&"rot_2") and game.rotating_ids().has(&"rot_3"),
		"a rotation switch takes effect")
	_check(not game.switch_rotation("nowhere").ok, "and an unknown rotation changes nothing")

	var seen: Array = []
	for _i in 4:
		var id := game.next_house()
		seen.append(String(id))
		game._rotation.note_played(id)
	_check(seen[0] != seen[1] and seen[0] == seen[2] and seen[1] == seen[3]
			and keep_b.has(seen[0]) and keep_b.has(seen[1]), "a cycle walks the rotation in turn", str(seen))

	_check(game.command_names("lm_house") == PackedStringArray(["gohouse"])
			and game.command_names("lm_winners") == PackedStringArray(["lm_winners"]),
		"the game's own map command is renameable from the file")

	var host := CommandHost.new()
	var bound: DotResult = vote.call("install_commands", host) if vote != null else null
	_check(bound != null and bound.ok and host.added.has("rockit") and not host.added.has("rtv"),
		"and a renamed rtv is registered under its new name", ", ".join(host.added.keys().slice(0, 6)))
	host.free()

	# No file: every house rotates, as it always did.
	game.rotation_file = null
	game.apply_rotation()
	_check(game.rotating_ids().size() == game.houses.size() and game.in_rotation(&"rot_2"),
		"with no file every house is in the rotation")

	# Put the world back: the later sections share this house.
	for id in made:
		var _gone: bool = game.houses.erase(id)
	game.rotation_file = kept
	game.apply_rotation()
	var _back := game.change_house(before if game.houses.has(before) else &"house")
	if vote != null:
		vote.call("refresh_houses")
	_finished_section()


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


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
