extends DotGameCheckSuite

## A server and a client in one process, over the link's loopback, each in its own physics
## world, with the client predicting its own player as a real one does.
##
##   godot --headless --path . res://examples/headless_net.tscn

const LmGame := preload("res://game/lm_game.gd")
const LmNetBridge := preload("res://game/net/lm_net_bridge.gd")
const LmPlayer := preload("res://game/lm_player.gd")
const LmLevel := preload("res://game/lm_level.gd")

const SECTIONS := 9
const CHECKS := 38
const LmAvatars := preload("res://game/lm_avatars.gd")
const LmEvent := preload("res://game/net/lm_event.gd")
const LmEvents := preload("res://game/net/lm_events.gd")
const LmRequest := preload("res://game/net/lm_request.gd")
const CLIENT_PEER := 7
const SESSION := 42
const INPUT_LEAD := 2

var _entered := 0
var _finished := 0

var _server_game: LmGame = null
var _client_game: LmGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: LmNetBridge = null
var _client_bridge: LmNetBridge = null
var _to_client: Array = []
var _to_server: Array = []
var _tick := 0
var _key: StringName = &""


func _ready() -> void:
	print("look at me, over the wire")

	if await _build():
		await _test_joining()
		await _test_walking()
		await _test_a_lost_input()
		await _test_a_door_for_one()
		await _test_the_witches_agree()
		await _test_the_click()
		await _test_progress_and_meter()
		_test_one_account_twice()

	if _server_bridge != null and _server_bridge.link != null:
		_server_bridge.link.loopback = Callable()
	if _client_bridge != null and _client_bridge.link != null:
		_client_bridge.link.loopback = Callable()
		_client_bridge.rtt_source = Callable()
	for child in get_children():
		remove_child(child)
		child.free()
	_server_game = null
	_client_game = null
	_server_net = null
	_client_net = null
	_server_bridge = null
	_client_bridge = null
	_to_client.clear()
	_to_server.clear()
	DotHumanoidFigure.clear_cache()
	DotHudPiece.clear_cache()
	DotMenuKit.clear_cache()
	LmLevel.clear_cache()
	DotRegistry.clear()
	_report_sections(_entered, _finished, SECTIONS, CHECKS)


func _make_game(authoritative: bool, parent: Node) -> LmGame:
	var world := LmGame.new()
	world.name = "World"
	world.authoritative = authoritative
	world.draws = false
	world.register_service = false
	world.self_tick = false
	world.config.winners_file = "user://test_net_winners.json"
	parent.add_child(world)
	return world


func _make_manager(is_server: bool, parent: Node) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Net"
	manager.is_server = is_server
	manager.local_peer_id = 1 if is_server else CLIENT_PEER
	manager.auto_tick = false
	manager.config_file = ""
	var config := DotNetConfig.new()
	config.tick_rate = 60
	config.snapshot_rate = LmGame.NET_SNAPSHOT_RATE
	config.world_extent = LmGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	config.enable_lag_compensation = false
	manager.config = config
	parent.add_child(manager)
	var _s := manager.setup()
	return manager


func _build() -> bool:
	_section("both halves")
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	var client_view := SubViewport.new()
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)
	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)
	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame
	_check(_server_game.levels.size() == 32 and _client_game.levels.is_empty(), "the server reads the levels; the client reads none")
	_server_net = _make_manager(true, server_side)
	_client_net = _make_manager(false, client_side)
	# This harness stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them (only dot-net's cap
	# holds it). By the constant map, so this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = LmNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)
	_client_bridge = LmNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)
	var a := _server_bridge.attach(_server_game, _server_net)
	var b := _client_bridge.attach(_client_game, _client_net)
	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(a.ok and b.ok and _server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both attach, on one schema")
	_server_bridge.link.loopback = func(method: StringName, _peer: int, payload: PackedByteArray) -> void:
		_to_client.append({"method": method, "payload": payload})
	_client_bridge.link.loopback = func(method: StringName, _peer: int, payload: PackedByteArray) -> void:
		_to_server.append({"method": method, "payload": payload})
	_client_bridge.rtt_source = func() -> float: return 40.0
	var _s := _server_net.start()
	var _c := _client_net.start()

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	_check(LmEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [LmEvents.Kind.size(), LmEvent.KIND_BITS])
	_check(LmRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [LmEvents.Ask.size(), LmRequest.KIND_BITS])

	_finished_section()
	return _failed == 0


func _test_joining() -> void:
	_section("a client joins")
	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat.
	_client_bridge.ask_ready()
	_flush()
	_check(_to_client.is_empty() and _server_bridge.house_progress(CLIENT_PEER).is_empty(),
		"a READY before the seat is told nothing yet")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_key = seated.value if seated.ok else &""
	# What the client had built when its first PROGRESS came: held behind the last LEVEL, it is 32.
	var built_at_progress := [-1]
	_client_bridge.progress_received.connect(func(_data: Dictionary) -> void:
		if built_at_progress[0] < 0:
			built_at_progress[0] = _client_game.levels.size(), CONNECT_ONE_SHOT)
	# Seated, the waiting READY is answered: the HELLO and the first window.
	var first := _server_bridge.house_progress(CLIENT_PEER)
	_check(int(first.get("sent", 0)) > 0 and int(first.get("sent", 0)) < 32
		and int(first.get("outstanding", 0)) <= LmNetBridge.LEVEL_WINDOW,
		"the house goes a window at a time, not all 32 at once (a browser drops what overflows its buffer)", str(first))
	var raw := 0
	var wire := 0

	for n: int in _server_game.documents:
		raw += JSON.stringify(_server_game.documents[n]).to_utf8_buffer().size()
		wire += LmEvents.write_level(_server_game.documents[n]).size()

	_check(wire * 3 < raw, "and deflated", "%d bytes of JSON as %d" % [raw, wire])
	_exchange()
	await _steps(30)
	_check(_client_bridge.local_key == _key and _client_game.levels.size() == 32, "it is told who it is, and builds all 32 levels from the documents")
	_check(built_at_progress[0] == 32 and _server_bridge.house_progress(CLIENT_PEER).is_empty(),
		"and hears its progress only after the last level", "built %d" % built_at_progress[0])
	var mine: LmPlayer = _client_game.players.get(_key, null)
	var identity: DotNetIdentity = mine.get_node_or_null("Identity") if mine != null else null
	_check(identity != null and identity.is_predicted(), "and predicts its own player")
	_check(absf(_client_game.levels[16].position.x - _server_game.levels[16].position.x) < 0.001, "its house is laid out where the server's is")
	var server_mine: LmPlayer = _server_game.players.get(_key, null)
	_check(mine != null and server_mine != null and LmAvatars.skin_index(mine.avatar) == LmAvatars.skin_index(server_mine.avatar),
		"it draws its player in the face the server seated them with")
	# The platform's answer arriving after the seat: another skin, and the same JOIN again.
	var other := DotAvatar.make(LmAvatars.SCHEMA_ID)
	var next_skin: StringName = LmAvatars.SKINS[(maxi(LmAvatars.skin_index(server_mine.avatar), 0) + 1) % LmAvatars.SKINS.size()]
	other.set_part(LmAvatars.SLOT_SKIN, next_skin)
	var refreshed := _server_bridge.refresh_player(SESSION, "Ada Lovelace", other)
	_exchange()
	await _steps(5)
	mine = _client_game.players.get(_key, null)
	_check(refreshed and mine != null and mine.avatar.part_in(LmAvatars.SLOT_SKIN) == next_skin and mine.display_name == "Ada Lovelace"
		and _client_game.players.size() == 1,
		"a face and a name that arrive later replace the first ones, and are not a second player",
		"%s %s" % [mine.avatar.to_dict() if mine != null else null, mine.display_name if mine != null else ""])
	_finished_section()


func _test_walking() -> void:
	_section("walking, predicted")
	var server_player: LmPlayer = _server_game.players[_key]
	var start := server_player.global_position
	var go := DotFpsCommand.new()
	go.yaw = 90.0
	go.move = Vector2(0, 1)
	await _steps(90, go)
	await _steps(15)
	var moved := server_player.global_position.distance_to(start)
	_check(moved > 2.0, "the client's keys move the server's player", "%.1f m" % moved)
	var mine: LmPlayer = _client_game.players[_key]
	var gap := mine.controller.state.position.distance_to(server_player.controller.state.position)
	_check(gap < 0.3, "and its prediction ends where the server does", "%.3f m" % gap)
	_finished_section()


## Inputs go unreliable, so every packet carries the last few commands
## ([constant LmNetBridge.INPUT_COPIES]). One packet is dropped here and the server must still
## hold that tick's command from the next packet's copies; with one command a packet it never
## arrives. Then copies of ticks the server has already simulated must be skipped, not pushed
## (which would count every one of them as a late input).
func _test_a_lost_input() -> void:
	_section("a lost input packet")
	var buffer := _server_net.input_buffer_for(CLIENT_PEER)
	var late_before := buffer.late_count
	var duplicates_before := buffer.duplicate_count
	var turn := DotFpsCommand.new()
	turn.yaw = 33.0
	turn.move = Vector2(1, 0)

	# _step, with the client's input packet lost on the way.
	_tick += 1
	var _t := _client_net.clock.advance(1.0 / 60.0)
	_server_bridge.server_tick(_tick)
	_flush()
	var lost_tick := _tick + INPUT_LEAD
	_client_bridge.client_tick(lost_tick, turn)
	var dropped := 0

	for i in range(_to_server.size() - 1, -1, -1):
		if _to_server[i]["method"] == &"input":
			_to_server.remove_at(i)
			dropped += 1

	_flush()
	await get_tree().physics_frame
	var missing := buffer.peek(lost_tick) == null

	await _step()
	var held := buffer.peek(lost_tick)
	var move: DotFpsCommand = held.get("move") if held != null else null
	_check(dropped == 1 and missing and move != null and absf(move.yaw - 33.0) < 0.5 and move.move.x > 0.5,
		"a dropped input packet is recovered from the next packet's copies",
		"dropped %d, held %s" % [dropped, "yes" if held != null else "no"])

	await _steps(30)
	_check(buffer.late_count == late_before and buffer.duplicate_count > duplicates_before,
		"and the copies of ticks already simulated are skipped, not counted late",
		"%d late, %d duplicates" % [buffer.late_count - late_before, buffer.duplicate_count - duplicates_before])
	_finished_section()


## The point of this game's prediction: a door open for one player only, walked through on both
## ends without the client being dragged back.
func _test_a_door_for_one() -> void:
	_section("a door that is open only for this player")
	var server_player: LmPlayer = _server_game.players[_key]
	var level: LmLevel = _server_game.levels[1]
	var door: Dictionary = level.doors["d1"] if level.doors.has("d1") else level.doors["d0"]
	var door_id := "d1" if level.doors.has("d1") else "d0"
	_server_game._unlock(server_player, door_id)
	_exchange()
	await _steps(4)
	var mine: LmPlayer = _client_game.players[_key]
	_check(mine.opened.has(door_id), "the client is told it opened it")
	_check(mine.controller.body.exclude.has(_client_game.levels[1].door_rid(door_id)), "and its own controller now walks through it")
	var normal: Vector3 = door["normal"]
	var yaw := rad_to_deg(atan2(-normal.x, -normal.z))
	var at := level.position + (door["centre"] as Vector3) - normal * 2.0 + Vector3(0, 0.1, 0)
	server_player.place_at(at, yaw)
	_exchange()
	await _steps(20)
	var go := DotFpsCommand.new()
	go.yaw = yaw
	go.move = Vector2(0, 1)
	await _steps(80, go)
	await _steps(15)
	var past: float = (server_player.global_position - level.position - (door["centre"] as Vector3)).dot(normal)
	_check(past > 1.0, "the server walks it through", "%.2f m" % past)
	var gap := mine.controller.state.position.distance_to(server_player.controller.state.position)
	_check(gap < 0.3, "and the client was predicting the same walk, not a wall", "%.3f m" % gap)

	# A door that slams behind the player (an event, the server's) is shut in the client's own
	# prediction too: progress carries the events, and the doors with them.
	var slam: Dictionary = {}
	for id: String in level.events:
		if str(level.events[id].get("do", "")) == "slam":
			slam = level.events[id]
	var slammed := str(slam.get("door", ""))
	var shut: Dictionary = level.doors[slammed]
	_server_game._unlock(server_player, slammed)
	var room := str(shut["doc"]["b"])
	# The corner of the room past it furthest from the doorway: clear of it, so it slams.
	var far := level._room_point(room, [0.5, 0.5])
	for f in [[0.15, 0.15], [0.85, 0.15], [0.15, 0.85], [0.85, 0.85]]:
		var corner := level._room_point(room, f)
		if corner.distance_to(shut["centre"]) > far.distance_to(shut["centre"]):
			far = corner
	server_player.place_at(level.position + far + Vector3(0, 0.1, 0), 0.0)
	_server_game.fire_events(server_player)
	_exchange()
	await _steps(4)
	_check(mine.fired.has(str(slam["id"])) and not mine.opened.has(slammed), "a door that slams behind the player is shut for its client too", str(mine.describe()))
	var witch_has_it := false
	for w in level.witches.size():
		var wp := level.witch_pose(w, _client_game.seconds_now(), _client_game.config.witch_speed_scale, _client_game.config.witch_head_sweep, _client_game.config.witch_door_seconds)
		witch_has_it = witch_has_it or (str(wp["door"]) == slammed and float(wp["open"]) > 0.3)
	print("  (witch has it open: %s)" % witch_has_it)
	_check(witch_has_it or not mine.controller.body.exclude.has(_client_game.levels[1].door_rid(slammed)), "and its own controller no longer walks through it")
	_finished_section()


func _test_the_witches_agree() -> void:
	_section("the witches agree")
	var ok := true

	for n in [1, 9, 32]:
		var a: LmLevel = _server_game.levels[n]
		var b: LmLevel = _client_game.levels[n]
		for i in a.witches.size():
			var pa := a.witch_pose(i, _server_game.seconds_now())
			var pb := b.witch_pose(i, _server_game.seconds_now())
			if (pa["at"] as Vector3).distance_to(pb["at"]) > 0.001:
				ok = false
	_check(ok, "every witch is where the server has her, posed from the clock alone")
	_check(absi(_client_game.tick - _server_game.tick) <= INPUT_LEAD + 6, "and the clocks agree", "%d vs %d" % [_client_game.tick, _server_game.tick])
	_finished_section()


## E pressed on a connected client: the server decides it landed and the client's own sound
## listener plays the click. The client is not put in the tree (its `_ready` would build a house
## of its own); it is given the bridge and builds only its sound.
func _test_the_click() -> void:
	_section("the click of a use, on a connected client")
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	client.set("bridge", _client_bridge)
	client.call("_build_audio")
	client.call("_listen_for_sounds")
	var audio: Node = client.get("audio")
	var sink := audio.get("manager").get("sink") as DotAudioSinkNull if audio != null else null
	var server_player: LmPlayer = _server_game.players[_key]
	var level: LmLevel = _server_game.levels[server_player.level]
	var item_id := ""

	for id: String in level.items:
		if not server_player.taken.has(id):
			item_id = id
			break

	var at: Vector3 = level.position + (level.items[item_id]["at"] as Vector3) + Vector3(0, 0.9, 0)
	var eye := at + Vector3(0, 0, 1.2)
	server_player.place_at(eye - Vector3(0, server_player.EYE_HEIGHT, 0), 0.0)
	server_player.controller.state.pitch = rad_to_deg(asin(clampf((at - eye).normalized().y, -1.0, 1.0)))
	server_player.controller.state.yaw = 0.0
	_client_bridge.ask_act("use")
	_exchange()
	await _steps(2)
	_check(server_player.taken.has(item_id), "E on a connected client takes what the server says it faces", item_id)
	_check(sink != null and sink.count_of(&"click") == 1, "and the client plays the click",
		str(sink.played_ids()) if sink != null else "no sink")
	client.free()
	_finished_section()


func _test_progress_and_meter() -> void:
	_section("progress and the meter")
	var server_player: LmPlayer = _server_game.players[_key]
	server_player.meter = 0.6
	await _steps(6)
	var mine: LmPlayer = _client_game.players[_key]
	# Against the server's own value: out of sight it drains while the snapshot travels.
	_check(server_player.meter > 0.5 and absf(mine.meter - server_player.meter) < 0.03, "the meter reaches its owner",
		"%.2f vs %.2f" % [mine.meter, server_player.meter])
	_client_bridge.ask_act("flashlight", {"on": false})
	_exchange()
	await _steps(6)
	_check(not server_player.flashlight, "the flashlight switch reaches the server")
	server_player.best = 3
	_client_bridge.ask_act("command", {"text": "/l3"})
	_exchange()
	await _steps(10)
	_exchange()
	await _steps(4)
	_check(server_player.level == 3 and mine.level == 3, "/l3 moves them on both ends", "%d / %d" % [server_player.level, mine.level])
	# Her own body, and at most the door each witch has open at this instant (open for everybody
	# while she has it: where each is depends on the house's layout).
	_check(mine.opened.is_empty() and mine.controller.body.exclude.size() <= 1 + (_client_game.levels[3] as LmLevel).witches.size(), "with a fresh level: no doors open for them there",
		"opened %s, exclude %d" % [str(mine.opened.keys()), mine.controller.body.exclude.size()])
	var _changed := _server_game.change_house(&"asylum")
	_exchange()
	await _steps(6)
	_exchange()
	await _steps(4)
	_check(_client_game.levels.size() == 18 and _client_game.house_id == &"asylum" and mine.level == 1,
		"a new house reaches the client: it rebuilds sixteen levels and stands in the new lobby (%d, %s, %d)" % [_client_game.levels.size(), _client_game.house_id, mine.level])
	_server_bridge.remove_peer(CLIENT_PEER)
	_check(not _server_game.players.has(_key), "a peer that leaves takes its player with it")
	_check(_server_net.registry.all().is_empty(), "and its entity")
	_finished_section()


## Two browser tabs of one guest share a device id, so one uid, so one key. The newest connection
## wins: the module is told to drop the older (dot-server-deploy's lookatme_client sees the reason
## arrive), and the older's leave, which follows the kick, must not take the newcomer's player.
func _test_one_account_twice() -> void:
	_section("one account on two connections: the newest wins")
	const TAB_ONE := 21
	const TAB_TWO := 22
	var key := &"uid:guest-two-tabs"
	var saved := _server_bridge.key_fn
	_server_bridge.key_fn = func(_peer: int, _session: int) -> StringName: return key
	var dropped: Array = []
	var on_drop := func(peer: int, which: StringName) -> void: dropped.append([peer, which])
	_server_bridge.superseded.connect(on_drop)
	var one := _server_bridge.add_player(TAB_ONE, 61, "Tab one")
	var two := _server_bridge.add_player(TAB_TWO, 62, "Tab two")
	_check(one.ok and two.ok and dropped == [[TAB_ONE, key]],
		"the second connection of one account has the first dropped", str(dropped))
	_check(_server_bridge.peer_of(key) == TAB_TWO and _server_bridge.key_of_peer(TAB_ONE) == &""
		and _server_game.players.size() == 1, "and the player is the newcomer's alone",
		"%d %s %d" % [_server_bridge.peer_of(key), _server_bridge.key_of_peer(TAB_ONE), _server_game.players.size()])
	# What the kick sets off: the older session leaves, and the roster tells the bridge.
	_server_bridge.remove_peer(TAB_ONE)
	var player: LmPlayer = _server_game.players.get(key, null)
	var identity: DotNetIdentity = player.get_node_or_null("Identity") if player != null else null
	_check(identity != null and identity.owner_peer_id == TAB_TWO and _server_net.registry.all().size() == 1,
		"the older connection's leave does not take the newcomer's player", str(identity.owner_peer_id if identity != null else -1))
	_server_bridge.remove_peer(TAB_TWO)
	_check(_server_game.players.is_empty() and _server_net.registry.all().is_empty(), "and the newcomer's own leave does")
	_server_bridge.superseded.disconnect(on_drop)
	_server_bridge.key_fn = saved
	_to_client.clear()
	_finished_section()


# --- Harness -----------------------------------------------------------------

func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _t := _client_net.clock.advance(1.0 / 60.0)
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in count:
		await _step(command)


func _section(name: String) -> void:
	_entered += 1
	print("")
	print(name)


func _finished_section() -> void:
	_finished += 1

