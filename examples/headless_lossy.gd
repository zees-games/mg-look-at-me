extends DotGameCheckSuite

## A real look-at-me server, a real client on ENet, and dot-net's lossy UDP relay between them.
##
##   godot --headless --path . res://examples/headless_lossy.tscn
##   godot --headless --path . res://examples/headless_lossy.tscn -- --verbose
##
## [b]What only this can see.[/b] `headless_net` drops packets in its own loopback: in order,
## instantly, and never a reliable one. The house is the most reliable data any game here sends
## a joiner (32 levels, deflated, a window at a time), on the same ENet channel as the snapshots
## and the commands; over a real UDP path with a real round trip that traffic is what ENet's
## own congestion control reacts to. This puts dot-net's relay in front of a dual-stack
## [DotServer] running the module, connects a [DotClientLink] on ENet through it, builds the
## client's netcode as [code]LmClient._build_netcode[/code] does (drawing nothing), and walks.
##
## Windows: a steady 60 ms each way with no loss; the same while the server changes the house
## (every client is sent the new one, and builds it, while it walks: three 600 ms frames in one
## process stall both ends, as the delivered client's build did); and the house changed back at
## 5% loss. Each measures the share of the client's input packets the server's link received,
## the share of the server's snapshots the client's link received, ENet's packet throttle at
## both ends, that the server's player walked, and that the client's prediction ends within half
## a metre of it.
##
## [code]--stock-throttle[/code] is the control: it puts ENet's packet throttle back as the
## engine ships it (see dot-core's [code]DotTransportENet.packet_throttle_deceleration[/code]),
## and the throttle check fails in every run, the delivery checks in most.

const LmGame := preload("res://game/lm_game.gd")
const LmNetBridge := preload("res://game/net/lm_net_bridge.gd")
const LmPlayer := preload("res://game/lm_player.gd")
const Relay := preload("res://addons/dot_net/testing/dot_net_udp_relay.gd")

## Long frames while a new house arrives, and how long each is.
const HITCHES := 3
const HITCH_MS := 600

## Checks in a window without a house change; one more with one.
const WINDOW_CHECKS := 7
const SECTIONS := 5
const CHECKS := 7 + 3 * WINDOW_CHECKS + 2

const PORT := 28961
const DATA := "user://lm_lossy"

## Name, loss each way, delay each way (ms), jitter (ms), seconds walked, and the house the
## server changes to as the window starts ("" none): every client is sent the new house while
## it walks, and builds it, which is the burst of reliable data and the long frames ENet's
## throttle reacted to.
const WINDOWS := [
	["60 ms, no loss", 0.0, 60.0, 0.0, 6.0, ""],
	["60 ms, no loss, the house changes", 0.0, 60.0, 0.0, 8.0, "asylum"],
	["60 ms, 5% loss, the house changes back", 0.05, 60.0, 0.0, 8.0, "house"],
]

## Waits on anything sent reliably: ENet's own contract with dot-core's peer timeouts (30 s),
## as game-arena's headless_lossy says. A wait on it ends the moment the thing arrives.
const RELIABLE_SECONDS := 35.0

var _entered := 0
var _finished := 0
var _verbose := false
var _stock := false

var _server_side: Node = null
var _server: DotServer = null
var _server_game: LmGame = null
var _relay = null

var _client_side: Node = null
var _link: DotClientLink = null
var _client_game: LmGame = null
var _client_net: DotNetManager = null
var _client_bridge: LmNetBridge = null
var _spawned := [false]
var _gone := [""]

## The command the client plays each tick while [member _driving].
var _move: DotFpsCommand = null
var _driving := false


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_verbose = "--verbose" in args
	_stock = "--stock-throttle" in args
	DotLog.set_level(DotLog.Level.DEBUG if _verbose else DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("look at me, over ENet through a lossy relay%s" % (" (stock throttle)" if _stock else ""))
	DotPaths.remove_tree(DATA)
	DirAccess.make_dir_recursive_absolute(DATA)

	if await _boot() and await _connect():
		for window in WINDOWS:
			await _walk_window(window)

	await _teardown()
	DotPaths.remove_tree(DATA)

	_report_sections(_entered, _finished, SECTIONS, CHECKS)


# --- The harness ------------------------------------------------------------

func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_finished += 1




func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true

		await get_tree().physics_frame

	return bool(condition.call())


func _seconds(s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(s * 1000.0)

	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame


func _module() -> DotModule:
	return _server.modules.get_module("lookatme") if _server != null else null


func _server_link() -> Node:
	var module := _module()
	var bridge: LmNetBridge = module.get("bridge") if module != null else null
	return bridge.link if bridge != null else null


## A peer's ENet packet throttle out of 32 ([code]ENetPacketPeer.PEER_PACKET_THROTTLE[/code]),
## or -1 off ENet. [param mp] is the end's multiplayer peer, [param peer_id] the far end.
static func _throttle(mp: Object, peer_id: int) -> int:
	if mp == null:
		return -1

	var enet: Object = mp.get("enet") if "enet" in mp else mp
	var packet_peer: Object = enet.call("get_peer", peer_id) if enet != null and enet.has_method("get_peer") else null

	if packet_peer == null or not packet_peer.has_method("get_statistic"):
		return -1

	return int(packet_peer.call("get_statistic",
		ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_PACKET_THROTTLE")))


func _client_throttle() -> int:
	return _throttle(_client_side.multiplayer.multiplayer_peer, 1)


func _server_throttle() -> int:
	return _throttle(_server_side.multiplayer.multiplayer_peer, _client_side.multiplayer.get_unique_id())


# --- Boot -------------------------------------------------------------------

func _boot() -> bool:
	_section("a dual-stack look-at-me server, and the relay in front of its UDP port")

	_server_side = Node.new()
	_server_side.name = "ServerSide"
	add_child(_server_side)
	# Its own MultiplayerAPI, and so does the client: an RPC is routed by its path relative to
	# the API's root, `Server/LookAtMe` on both ends.
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _server_side.get_path())

	var scene: Node = (load("res://scenes/lm_server.tscn") as PackedScene).instantiate()
	_server_side.add_child(scene)
	await get_tree().process_frame
	_server_game = DotRegistry.get_node_service(LmGame.SERVICE) as LmGame

	if not _check(_server_game != null and _server_game.levels.size() == 32, "the server scene builds the house"):
		_done()
		return false

	_server_game.config.winners_file = "%s/winners.json" % DATA

	var config := DotServerConfig.new()
	config.hostname = "look at me lossy"
	config.port = PORT
	config.bind_address = "127.0.0.1"
	config.transport_mode = "dual"
	config.rcon_password = ""
	config.admins_path = "%s/admins.json" % DATA
	config.bans_path = "%s/bans.json" % DATA
	config.audit_log_path = "%s/audit.jsonl" % DATA
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""
	# No query listener and ENet on its own port: the demux is not what this measures.
	config.query_enabled = false
	config.enet_share_udp_port = false
	config.stdin_console_enabled = false
	config.log_level = "debug" if _verbose else "error"

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	_server_side.add_child(_server)

	var booted: DotResult = await _server.boot()

	if not _check(booted.ok, "the server boots, WebSocket and ENet", str(booted.error)):
		_done()
		return false

	var loaded: DotResult = await _server.modules.load_module("res://game/lm_module.gd")

	if not _check(loaded.ok, "the module loads", str(loaded.error)):
		_done()
		return false

	_relay = Relay.new()
	_relay.seed = 20261012
	var w: Array = WINDOWS[0]
	_relay.up.configure(float(w[1]), float(w[2]), float(w[3]))
	_relay.down.configure(float(w[1]), float(w[2]), float(w[3]))
	var relayed: DotResult = _relay.start(0, "127.0.0.1", config.effective_enet_port())
	_check(relayed.ok, "the relay listens in front of UDP %d" % config.effective_enet_port(), str(relayed.error))
	_done()
	return relayed.ok


## A client: a [DotClientLink] on ENet only, in a world of its own (its player is a body, and
## the server's is another one in the same place), and the netcode `LmClient._build_netcode`
## builds, minus everything that draws.
func _connect() -> bool:
	_section("a client on ENet joins through the relay and is sent the house")

	var view := SubViewport.new()
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(view)
	_client_side = Node.new()
	_client_side.name = "ClientSide"
	view.add_child(_client_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), _client_side.get_path())

	_link = DotClientLink.new()
	_link.name = "Server"
	_link.player_name = "Walker"
	_link.transport_preference = "udp"
	_link.udp_address = "127.0.0.1:%d" % _relay.port()

	_client_side.add_child(_link)
	_link.spawned.connect(func() -> void: _spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: _gone[0] = reason)

	_client_game = LmGame.new()
	_client_game.name = "World"
	_client_game.authoritative = false
	_client_game.draws = false
	_client_game.register_service = false
	_client_game.self_tick = false
	_client_side.add_child(_client_game)

	_client_net = DotNetManager.new()
	_client_net.name = "Net"
	_client_net.is_server = false
	_client_net.auto_tick = false
	_client_net.config_file = ""
	# Not the server's manager's registry slot: two ends in one process.
	_client_net.service_scope = &"lossy_client"
	var cfg := DotNetConfig.new()
	cfg.tick_rate = Engine.physics_ticks_per_second
	cfg.snapshot_rate = LmGame.NET_SNAPSHOT_RATE
	cfg.world_extent = LmGame.NET_WORLD_EXTENT
	cfg.enable_prediction = true
	cfg.enable_lag_compensation = false
	cfg.max_entities_per_snapshot = 64
	_client_net.config = cfg
	_client_side.add_child(_client_net)
	var _set := _client_net.setup()

	_client_bridge = LmNetBridge.new()
	_client_bridge.name = "Bridge"
	_client_side.add_child(_client_bridge)
	var attached := _client_bridge.attach(_client_game, _client_net)
	_client_net.messages.seal()
	# What LmClient feeds it.
	_client_bridge.rtt_source = func() -> float: return float(maxi(0, _link.ping_ms()))

	_link.connect_to_server("127.0.0.1:%d" % PORT)
	await _until(func() -> bool:
		return _spawned[0] or _gone[0] != "" or _link.phase == DotClientLink.Phase.FAILED, 30.0)

	_check(_spawned[0] and _link.transport_used == "enet", "the client is seated, on ENet",
		"transport %s, %s" % [_link.transport_used, _gone[0]])

	# The control: ENet's own throttle back, on this end, which ENet sends on to the server's.
	if _stock:
		var mp: Object = _client_side.multiplayer.multiplayer_peer
		var to_server: Object = mp.call("get_peer", 1) if mp != null and mp.has_method("get_peer") else null
		if to_server != null:
			to_server.call("throttle_configure", DotTransportENet.ENET_DEFAULT_THROTTLE_INTERVAL_MS,
				DotTransportENet.ENET_DEFAULT_THROTTLE_ACCELERATION, DotTransportENet.ENET_DEFAULT_THROTTLE_DECELERATION)

	# Under the link once it is playing, as a delivered game's scene does: the link retires
	# whatever it finds under itself when it loads the game.
	_client_bridge.open_link(_link)
	_client_net.local_peer_id = _client_side.multiplayer.get_unique_id()
	var _started := _client_net.start()
	_client_bridge.ask_ready()
	_driving = true
	var t0 := Time.get_ticks_msec()

	var housed := await _until(func() -> bool:
		return _client_game.levels.size() == 32 and _client_bridge.local_key != &"" \
			and _client_game.players.has(_client_bridge.local_key), RELIABLE_SECONDS)
	_check(attached.ok and housed, "it builds all 32 levels and is told who it is",
		"%d levels in %.1f s" % [_client_game.levels.size(), (Time.get_ticks_msec() - t0) / 1000.0])
	var synced := await _until(func() -> bool: return _client_net.clock.is_synced(), 10.0)
	_check(synced, "and its clock syncs")
	_done()
	return housed and synced


# --- Walking ----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not _driving or _client_net == null or not _client_net.is_running():
		return

	if not _link.is_playing():
		return

	var ticks := _client_net.clock.advance(delta)
	var move := _move if _move != null else DotFpsCommand.new()

	for i in range(ticks):
		if _client_net.clock.is_synced():
			_client_bridge.client_tick(_client_net.clock.input_tick() - (ticks - 1 - i), move)


func _walk_window(window: Array) -> void:
	var title := str(window[0])
	_section("walking, %s" % title)
	_relay.set_impairment(true, float(window[1]), float(window[2]), float(window[3]))
	_relay.set_impairment(false, float(window[1]), float(window[2]), float(window[3]))
	await _seconds(1.0)

	var key := _client_bridge.local_key
	var server_link := _server_link()
	var client_link: Node = _client_bridge.link
	var in_sent := int(client_link.get("inputs_sent"))
	var in_got := int(server_link.get("inputs_received"))
	var snap_sent := int(server_link.get("snapshots_sent"))
	var snap_got := int(client_link.get("snapshots_received"))
	_relay.reset_counts()
	var throttle_low := [32, 32]
	var t0 := Time.get_ticks_msec()
	var seconds := float(window[4])
	var house := str(window[5])
	var deadline := t0 + int(seconds * 1000.0)
	var house_note := ""

	if house != "":
		_run_command("lm_house %s" % house)
		# Walking while it arrives: the commands keep going, as a player's would.
		_move = _leg(0)
		# A frame as long as the delivered client's while it built the house (dot-server-deploy's
		# lookatme_client measured 600 ms): one process, so both ends stall, as a real server
		# does on a long frame of its own. Acknowledgements read after it are late by its length.
		for i in range(HITCHES):
			await _seconds(0.25)
			OS.delay_msec(HITCH_MS)
		var arrived := await _until(func() -> bool:
			throttle_low[0] = mini(throttle_low[0], _client_throttle())
			throttle_low[1] = mini(throttle_low[1], _server_throttle())
			return _client_game.house_id == StringName(house) and _client_game.levels.size() == _server_game.levels.size() \
				and _client_game.players.has(key), RELIABLE_SECONDS)
		house_note = "%s, %d levels in %.1f s" % [house, _client_game.levels.size(), (Time.get_ticks_msec() - t0) / 1000.0]
		_check(arrived and _server_game.house_id == StringName(house), "the new house arrives while the client walks", house_note)
		deadline = maxi(deadline, Time.get_ticks_msec() + 3000)

	var server_player: LmPlayer = _server_game.players.get(key, null)
	var mine: LmPlayer = _client_game.players.get(key, null)

	if server_player == null or mine == null:
		for i in range(WINDOW_CHECKS - (1 if house != "" else 0)):
			_check(false, "(no player)", "key %s" % key)
		_done()
		return

	# Back and forth across the room the player stands in, so the walk stays on open floor.
	var start := server_player.global_position
	var furthest := 0.0
	var leg := 0

	while Time.get_ticks_msec() < deadline:
		_move = _leg(leg)
		var leg_end := Time.get_ticks_msec() + 700

		while Time.get_ticks_msec() < mini(leg_end, deadline):
			await get_tree().physics_frame
			furthest = maxf(furthest, server_player.global_position.distance_to(start))
			throttle_low[0] = mini(throttle_low[0], _client_throttle())
			throttle_low[1] = mini(throttle_low[1], _server_throttle())

		leg += 1

		if _verbose:
			print("    t=%.1f inputs %d/%d snapshots %d/%d throttle client %d server %d" % [
				(Time.get_ticks_msec() - t0) / 1000.0,
				int(server_link.get("inputs_received")) - in_got, int(client_link.get("inputs_sent")) - in_sent,
				int(client_link.get("snapshots_received")) - snap_got, int(server_link.get("snapshots_sent")) - snap_sent,
				_client_throttle(), _server_throttle()])

	_move = DotFpsCommand.new()
	await _seconds(0.8)

	var inputs_sent := int(client_link.get("inputs_sent")) - in_sent
	var inputs_got := int(server_link.get("inputs_received")) - in_got
	var snaps_sent := int(server_link.get("snapshots_sent")) - snap_sent
	var snaps_got := int(client_link.get("snapshots_received")) - snap_got
	var said: Dictionary = _relay.describe()
	var loss := float(window[1])
	# What the relay lets through, less a margin for the packets in flight at either edge.
	var floor_share := (1.0 - loss) * 0.9
	var in_share := float(inputs_got) / float(maxi(inputs_sent, 1))
	var snap_share := float(snaps_got) / float(maxi(snaps_sent, 1))

	print("    relay: up %s lost, down %s lost; lowest throttle client %d, server %d (of 32)" % [
		said["up"]["measured_loss"], said["down"]["measured_loss"], throttle_low[0], throttle_low[1]])
	_check(in_share >= floor_share, "the server's link received the client's inputs",
		"%d of %d, %.0f%%" % [inputs_got, inputs_sent, in_share * 100.0])
	_check(snap_share >= floor_share, "the client's link received the server's snapshots",
		"%d of %d, %.0f%%" % [snaps_got, snaps_sent, snap_share * 100.0])
	_check(throttle_low[0] == 32 and throttle_low[1] == 32,
		"ENet's packet throttle never dropped an unreliable packet at either end",
		"lowest client %d, server %d" % [throttle_low[0], throttle_low[1]])
	_check(furthest > 2.0, "the client's keys walk the server's player", "%.1f m" % furthest)
	var gap := mine.controller.state.position.distance_to(server_player.controller.state.position)
	_check(gap < 0.5, "and the client's prediction ends within half a metre of it", "%.3f m" % gap)
	_check(_link.phase == DotClientLink.Phase.PLAYING and _gone[0] == "", "the client is still connected", _gone[0])
	_check(int(said["up"]["delivered"]) > 0 and int(said["down"]["delivered"]) > 0,
		"and every datagram went through the relay",
		"up %s, down %s" % [said["up"]["delivered"], said["down"]["delivered"]])
	_done()


## The command for one leg of the walk: forward, facing one way and then the other.
static func _leg(n: int) -> DotFpsCommand:
	var go := DotFpsCommand.new()
	go.yaw = 90.0 if n % 2 == 0 else -90.0
	go.move = Vector2(0, 1)
	return go


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	_server.console.execute(line, context)
	return PackedStringArray(captured)


func _teardown() -> void:
	_driving = false

	if _link != null:
		_link.disconnect_from_server()

	await _seconds(0.3)

	if _relay != null:
		_relay.stop()

	if _server != null:
		_server.shutdown("done")

	await _seconds(0.3)
