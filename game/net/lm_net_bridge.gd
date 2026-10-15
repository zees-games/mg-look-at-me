extends Node

## The only file that names both the house and the netcode. Both ends.
##
## [b]Movement is mg-deathrun's[/b]: a [LmNetCommand] a tick into dot-net's input buffer, the
## owner predicting with the same controller the server simulates, snapshots reconciling it.
## [b]Everything else is mg-dangerous-delivery's[/b]: a few JSON events and requests.
##
## [b]What makes this game's prediction work is the doors.[/b] A door is open for the player
## who opened it and nobody else ([LmGame._apply_doors]); the owner's client must exclude the
## same doors from its predicting controller, or it predicts a wall the server walks them
## through and every snapshot drags them back. PROGRESS carries `opened` to the owner, and the
## client applies it before its next predicted tick.

const LmEvent := preload("lm_event.gd")
const LmEvents := preload("lm_events.gd")
const LmNetCommand := preload("lm_net_command.gd")
const LmNetLink := preload("lm_net_link.gd")
const LmPlayerNet := preload("lm_player_net.gd")
const LmRequest := preload("lm_request.gd")

const LmGame := preload("../lm_game.gd")
const LmPlayer := preload("../lm_player.gd")
const LmAvatars := preload("../lm_avatars.gd")

## The most a JSON avatar document may be on the wire; mg-deathrun's number.
const AVATAR_BYTES := 1024

const CHANNEL := "lookatme.net"

const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so a lost packet costs
## the server no tick unless the next four are lost too. Inputs go unreliable, and over ENet
## (the desktop client) one command a packet made every dropped packet a tick the server ran on
## the previous command, which the client had predicted on the real one: a correction each time.
## mg-wipeout's number; game-arena measured 80% of ticks on the right command at 20% loss with
## one copy and 99-100% with three to five.
const INPUT_COPIES := 5

## The most LEVEL bytes a client may have been sent and not yet acknowledged (LmEvents.Ask.LEVELS).
## Half a browser's 64 KiB inbound WebSocket buffer, which the page fills between two frames and
## the engine empties once a frame, dropping what does not fit: snapshots, chat and a frame
## spent building the house need the other half. A level larger than this still goes, alone.
const LEVEL_WINDOW := 32768

signal hello_received(key: StringName)
signal progress_received(data: Dictionary)
signal said(text: String)
signal notice_received(text: String)
signal chat_received(wire: Dictionary)
## The server says this player should hear [param id] (an LmAudio catalogue id).
signal sound_received(id: StringName)
signal voice_arrived(payload: PackedByteArray)
signal say_requested(peer_id: int, channel_id: StringName, text: String)
## Server: [param peer_id]'s player was handed to a newer connection of the same account (two
## browser tabs of one guest share a device id, so one uid). The bridge has already taken the old
## peer out of the house; the module disconnects it with [constant SUPERSEDED_REASON].
signal superseded(peer_id: int, key: StringName)

## What the older connection is told when a newer one of the same account takes its player.
const SUPERSEDED_REASON := "You joined from another tab or window"

var game: LmGame = null
var net: DotNetManager = null
var link: LmNetLink = null

var local_key: StringName = &""
var voice_relay_fn: Callable = Callable()
var rtt_source: Callable = Callable()

## [code]func(peer_id, session_id) -> StringName[/code]: the key a player's progress and win are
## kept under. The module returns the account uid; unset, the session.
var key_fn: Callable = Callable()

## (session_id) -> DotAvatar: what a session looks like, set by the module to dot-platform's
## answer. Unset, or answering null, is the stock person for the key.
var avatar_fn: Callable = Callable()

var _key_of_peer: Dictionary = {}

## Client: the server's peer id of each player (voice speakers are named by it), from their JOIN.
## The client's own `_key_of_peer` is only a server's.
var speaker_keys: Dictionary = {}
var _key_of_session: Dictionary = {}
var _peer_of_key: Dictionary = {}
var _ready_peers: Dictionary = {}
var _behaviours: Dictionary = {}
var _game_ticked_for: int = -1
var _client_ticked_for: int = -1
var _levels_expected: int = -1
var _levels_got: Array = []

## Server: per peer, the house it is being sent: {serial, wires, sent, acked, held}. While a peer
## is here everything else told to it is held and follows the last LEVEL, so a client hears
## nothing about a house it has not been given yet, exactly as when the levels went at once.
var _house_out: Dictionary = {}
var _house_serial: int = 0
## Server: each level of the current house as a LEVEL body, deflated once, not once a joiner.
var _level_wires: Dictionary = {}
## Server: peers whose READY came before their seat ([method add_player]). A client sends READY
## when its link says PLAYING, which it decides itself after sending `loaded` on another channel;
## over ENet with loss the READY can overtake `loaded`, and dropping it left the client waiting
## for a house for ever. Admitted when seated.
var _ready_unseated: Dictionary = {}

## Client: the HELLO the LEVELs arriving belong to, and whether this frame's ack is queued.
var _hello_serial: int = 0
var _ack_queued := false


func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	var world := p_game as LmGame

	if world == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs a house and a manager.")

	if world.authoritative != p_net.is_server:
		return DotResult.fail(DotError.CODE_STATE, "The house and the manager disagree about who is authoritative.")

	game = world
	net = p_net
	net.send_fn = _send

	var event := net.messages.register(LmEvent.NAME, LmEvent, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT)

	if not event.ok:
		return event

	var request := net.messages.register(LmRequest.NAME, LmRequest, DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER)

	if not request.ok:
		return request

	net.messages.on(LmEvent.NAME, _on_event)
	net.messages.on(LmRequest.NAME, _on_request)
	game.self_tick = false
	game.set_physics_process(false)

	if net.is_server:
		game.said.connect(func(key: StringName, text: String) -> void: _tell_key(key, LmEvents.Kind.SAY, {"text": text}))
		for changed in [game.took, game.opened_door, game.event_fired]:
			changed.connect(func(key: StringName, _what: String) -> void: _send_progress(key))
		game.caught.connect(_send_progress)
		game.level_done.connect(func(key: StringName, _n: int) -> void: _send_progress.call_deferred(key))
		game.player_left.connect(func(key: StringName) -> void: _broadcast(LmEvents.Kind.LEAVE, {"key": String(key)}))
		# A new house: every client is sent it, as a joiner is, and their progress after.
		game.house_changed.connect(func(_id: StringName) -> void:
			_level_wires.clear()

			for peer_id in _ready_peers.keys():
				_send_house(int(peer_id))
				_send_progress(key_of_peer(int(peer_id))))

	return DotResult.success(true)


func open_link(parent: Node) -> void:
	if parent == null or link != null:
		return

	link = LmNetLink.attached_to(parent, self, net != null and net.is_server)


func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)


static func session_key(session_id: int) -> StringName:
	return StringName("s%d" % session_id)


# --- Server: people --------------------------------------------------------------

func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var key: StringName = key_fn.call(peer_id, session_id) if key_fn.is_valid() else session_key(session_id)

	if key == &"":
		key = session_key(session_id)

	# The same account again, on another connection: the newest wins. Left alone, the second seat
	# took the first's player under it (one key), and the first's keys moved nothing while its link
	# stayed up; worse, its eventual leave then took the newcomer's player out. The old peer leaves
	# exactly as a disconnect does, BEFORE the newcomer is seated, so its later remove_peer finds no
	# key; the module is told so it can disconnect that peer with a reason it will show.
	var held_by: int = int(_peer_of_key.get(key, 0))

	if held_by != 0 and held_by != peer_id:
		DotLog.info(CHANNEL, "a newer connection of the same account takes the player", {"key": String(key), "old_peer": held_by, "new_peer": peer_id})
		remove_peer(held_by)
		superseded.emit(held_by, key)

	_key_of_peer[peer_id] = key
	_peer_of_key[key] = peer_id
	_key_of_session[session_id] = key
	var avatar: DotAvatar = avatar_fn.call(session_id) if avatar_fn.is_valid() else null
	var player := game.join(key, display_name, avatar if avatar != null else LmAvatars.stock_avatar(key))
	_build_entity(player, peer_id)

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(key)


func remove_peer(peer_id: int) -> void:
	var key: StringName = _key_of_peer.get(peer_id, &"")
	_key_of_peer.erase(peer_id)
	_ready_peers.erase(peer_id)
	_house_out.erase(peer_id)
	_ready_unseated.erase(peer_id)

	if key == &"":
		return

	_peer_of_key.erase(key)

	for session_id: int in _key_of_session.keys():
		if _key_of_session[session_id] == key:
			_key_of_session.erase(session_id)

	var behaviour: LmPlayerNet = _behaviours.get(key, null)
	_behaviours.erase(key)

	if behaviour != null and behaviour.identity != null and net.registry.has(behaviour.identity.net_id):
		net.registry.unregister(behaviour.identity.net_id)

	game.leave(key)

	if net.peers().has(peer_id):
		var _gone := net.remove_peer(peer_id)


## A name or a face that arrived after the player was seated (dot-platform admits AFTER the
## seat, so the first JOIN is a guest's whenever the profile store is slower than the join),
## or a wardrobe change later: the player takes it and everybody is sent the JOIN again.
func refresh_player(session_id: int, display_name: String, avatar: DotAvatar) -> bool:
	if net == null or not net.is_server or game == null:
		return false

	var key: StringName = _key_of_session.get(session_id, &"")
	var player: LmPlayer = game.players.get(key, null)

	if player == null:
		return false

	if display_name != "":
		player.display_name = display_name

	player.set_avatar(avatar if avatar != null else LmAvatars.stock_avatar(key))
	_broadcast(LmEvents.Kind.JOIN, _join_body(key))
	return true


func key_of_peer(peer_id: int) -> StringName:
	return _key_of_peer.get(peer_id, &"")


func peer_of(key: StringName) -> int:
	return int(_peer_of_key.get(key, 0))


## Behaviour before identity: [DotNetIdentity] collects its behaviours in `_ready`.
func _build_entity(player: LmPlayer, peer_id: int, net_id: int = 0) -> DotNetIdentity:
	var behaviour := LmPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)
	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. Walking a dark corridor a round trip
	# behind your own keys is the thing nobody forgives a first-person game.
	identity.authority = DotNetIdentity.Authority.SHARED
	identity.always_relevant = true
	player.add_child(identity)
	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})

	_behaviours[player.player_key] = behaviour
	behaviour.pull()
	return identity


func _admit(peer_id: int) -> void:
	var key: StringName = _key_of_peer.get(peer_id, &"")

	if key == &"":
		_ready_unseated[peer_id] = true
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	_send_house(peer_id)

	for other: StringName in _behaviours:
		_tell(peer_id, LmEvents.Kind.JOIN, _join_body(other))

	_broadcast(LmEvents.Kind.JOIN, _join_body(key))
	_send_progress(key)


## The house to one peer: a HELLO saying how many levels follow, then one LEVEL each, paced by
## the peer's acks ([constant LEVEL_WINDOW]). Anything else told to the peer meanwhile is held
## until the last LEVEL has gone. A second house before the first finished replaces it; what was
## held for the first still follows.
## The scare tunables as they stand, so a joining client's director runs the server's numbers.
func _scare_settings() -> Dictionary:
	var out := {}

	for setting in game.config.scare_keys():
		out[setting] = game.config.get(setting)

	return out


func _send_house(peer_id: int) -> void:
	var key: StringName = _key_of_peer.get(peer_id, &"")
	var numbers: Array = game.levels.keys()
	numbers.sort()
	var held: Array = _house_out.get(peer_id, {}).get("held", [])
	_house_out.erase(peer_id)
	_house_serial += 1
	_tell(peer_id, LmEvents.Kind.HELLO, {"serial": _house_serial,
		"you": String(key), "tick_rate": game.tick_rate, "tick": net.clock.tick, "levels": numbers.size(),
		"house": String(game.house_id), "house_name": game.house_name(),
		"config": {"allow_third_person": game.config.allow_third_person, "witch_speed_scale": game.config.witch_speed_scale,
			"witch_sight_scale": game.config.witch_sight_scale, "witch_cone_scale": game.config.witch_cone_scale,
			"witch_head_sweep": game.config.witch_head_sweep, "reach": game.config.reach,
			"flashlight_range": game.config.flashlight_range, "flashlight_angle": game.config.flashlight_angle}.merged(_scare_settings()),
	})

	var wires: Array = []

	for n: int in numbers:
		if not _level_wires.has(n):
			_level_wires[n] = LmEvents.write_level(game.documents[n])

		wires.append(_level_wires[n])

	_house_out[peer_id] = {"serial": _house_serial, "wires": wires, "sent": 0, "acked": 0, "held": held}
	_pump_house(peer_id)


## Sends the peer's next LEVELs while what it has not acknowledged stays under
## [constant LEVEL_WINDOW] (one always goes when nothing is outstanding); after the last, what
## was held.
func _pump_house(peer_id: int) -> void:
	var out: Dictionary = _house_out.get(peer_id, {})

	if out.is_empty():
		return

	var wires: Array = out["wires"]
	var outstanding := 0

	for i in range(int(out["acked"]), int(out["sent"])):
		outstanding += (wires[i] as PackedByteArray).size()

	while int(out["sent"]) < wires.size():
		var wire: PackedByteArray = wires[int(out["sent"])]

		if int(out["sent"]) > int(out["acked"]) and outstanding + wire.size() > LEVEL_WINDOW:
			return

		_emit(peer_id, LmEvent.new(LmEvents.Kind.LEVEL, wire))
		outstanding += wire.size()
		out["sent"] = int(out["sent"]) + 1

	_house_out.erase(peer_id)

	for told: Array in out["held"]:
		_tell(peer_id, int(told[0]), told[1])


## A client's LEVELS ack: how many of the HELLO numbered `serial` it holds. An ack for an older
## house, or a count it was never sent, moves nothing.
func _on_levels_ack(peer_id: int, args: Dictionary) -> void:
	var out: Dictionary = _house_out.get(peer_id, {})

	if out.is_empty() or int(args.get("serial", -1)) != int(out["serial"]):
		return

	out["acked"] = clampi(int(args.get("got", 0)), int(out["acked"]), int(out["sent"]))
	_pump_house(peer_id)


## How a peer's house is going, for describe(): {} when none is in flight.
func house_progress(peer_id: int) -> Dictionary:
	var out: Dictionary = _house_out.get(peer_id, {})

	if out.is_empty():
		return {}

	var outstanding := 0

	for i in range(int(out["acked"]), int(out["sent"])):
		outstanding += (out["wires"][i] as PackedByteArray).size()

	return {"levels": (out["wires"] as Array).size(), "sent": out["sent"], "acked": out["acked"],
		"outstanding": outstanding, "held": (out["held"] as Array).size()}


func _join_body(key: StringName) -> Dictionary:
	var behaviour: LmPlayerNet = _behaviours.get(key, null)

	if behaviour == null or behaviour.identity == null:
		return {}

	return {"key": String(key), "name": behaviour.player.display_name, "net_id": behaviour.identity.net_id,
		"peer": peer_of(key), "avatar": _avatar_wire(behaviour.player.avatar)}


## The avatar DOCUMENT rather than the skin it picks, so a client reads a site avatar itself
## (deathrun's reason: a slot added later needs no new wire). Capped, because a document a
## hostile profile made enormous would otherwise ride every JOIN; over the cap is the stock person.
static func _avatar_wire(avatar: DotAvatar) -> Dictionary:
	if avatar == null:
		return {}

	var doc := avatar.to_dict()
	return doc if JSON.stringify(doc).length() <= AVATAR_BYTES else {}


func _send_progress(key: StringName) -> void:
	var player: LmPlayer = game.players.get(key, null)

	if player == null:
		return

	_tell_key(key, LmEvents.Kind.PROGRESS, {
		"level": player.level, "best": player.best, "won": player.won, "holds": player.holds,
		"opened": player.opened.keys(), "used": player.used.keys(), "taken": player.taken.keys(),
		"fired": player.fired.keys(),
	})


# --- Server: the tick ----------------------------------------------------------------

func server_tick(tick: int) -> void:
	_game_ticked_for = -1

	if net != null:
		net.server_tick(tick)

	# A server with nobody on it has no behaviours to call this; the witches keep walking.
	ensure_game_ticked(tick)


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick

	for key: StringName in _behaviours:
		var behaviour: LmPlayerNet = _behaviours[key]

		if behaviour.player != null and behaviour.identity != null and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())

	# The house's tick is the server's: step() counts one, so it starts one short. The witches
	# are posed from it on both ends, and a house a tick off from its clients is a witch a tick
	# off from where they see her.
	game.tick = tick - 1
	game.step(net.clock.tick_duration())


# --- Requests ----------------------------------------------------------------------

func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if not _key_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	var _acked := net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	# A batch: this tick's command and the ones before it (see [constant INPUT_COPIES]). Copies
	# of ticks already simulated are skipped rather than pushed, or each would count as a late
	# input; the packet's own tick is always pushed, so a late one still counts.
	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return LmNetCommand.new()
	)

	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")

	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)

	for input in batch:
		if input != newest and input.tick <= buffer.last_consumed_tick():
			continue

		pushed = buffer.push(input)

	return pushed


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	return net.receive(payload, peer_id) if net != null else DotResult.fail(DotError.CODE_STATE, "No manager.")


func receive_event(payload: PackedByteArray) -> DotResult:
	return net.receive(payload, 1) if net != null else DotResult.fail(DotError.CODE_STATE, "No manager.")


func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)


func _on_request(message: DotNetMessage) -> void:
	var ask := message as LmRequest

	if ask == null or net == null or not net.is_server:
		return

	var peer_id := ask.sender_peer_id

	match ask.kind:
		LmEvents.Ask.READY:
			_admit(peer_id)
		LmEvents.Ask.LEVELS:
			_on_levels_ack(peer_id, LmEvents.read_json(ask.reader()))
		LmEvents.Ask.ACT:
			var key: StringName = _key_of_peer.get(peer_id, &"")

			if key == &"":
				return

			var args := LmEvents.read_json(ask.reader())

			match str(args.get("action", "")):
				"use":
					# The click offline is "E landed on something" (any answer); the server is
					# the one who knows, so it tells the presser.
					if game.interact(key) != "":
						_tell(peer_id, LmEvents.Kind.SOUND, {"id": "click"})
				"flashlight":
					game.set_flashlight(key, bool(args.get("on", true)))
				"spook":
					var _applied := game.spook(key, float(args.get("amount", 0.0)))
				"command":
					var reply := game.command(key, str(args.get("text", "")))
					_tell(peer_id, LmEvents.Kind.SAY, {"text": reply if reply != "" else "Nothing called that"})
					_send_progress(key)
				"say":
					say_requested.emit(peer_id, StringName(str(args.get("channel", "all"))), str(args.get("text", "")))


func notice(peer_id: int, text: String) -> void:
	_tell(peer_id, LmEvents.Kind.SAY, {"text": text, "notice": true})


func _broadcast(kind: int, data: Dictionary) -> void:
	if data.is_empty():
		return

	for peer_id in _ready_peers.keys():
		_tell(int(peer_id), kind, data)


func _tell_key(key: StringName, kind: int, data: Dictionary) -> void:
	var peer := peer_of(key)

	if peer > 0 and _ready_peers.has(peer):
		_tell(peer, kind, data)


## One peer, never zero: `net.send(msg, 0)` is a broadcast in dot-net.
func _tell(peer_id: int, kind: int, data: Dictionary) -> void:
	if peer_id <= 0 or net == null:
		return

	if _house_out.has(peer_id) and kind != LmEvents.Kind.HELLO:
		(_house_out[peer_id]["held"] as Array).append([kind, data])
		return

	_emit(peer_id, LmEvent.new(kind, LmEvents.write_json(data)))


func _emit(peer_id: int, event: LmEvent) -> void:
	net.send(event, peer_id)


# --- Client ------------------------------------------------------------------------

func ask_ready() -> void:
	_ask(LmEvents.Ask.READY, {})


func ask_act(action: String, args: Dictionary = {}) -> void:
	var body := args.duplicate()
	body["action"] = action
	_ask(LmEvents.Ask.ACT, body)


func ask_say(channel_id: StringName, text: String) -> void:
	ask_act("say", {"channel": String(channel_id), "text": text})


## One LEVELS ack a frame however many arrived in it: the server's next ones wait on it.
func _ack_levels() -> void:
	_ack_queued = false
	_ask(LmEvents.Ask.LEVELS, {"serial": _hello_serial, "got": _levels_got.size()})


func _ask(kind: int, data: Dictionary) -> void:
	if net == null or net.is_server:
		return

	net.send(LmRequest.new(kind, LmEvents.write_json(data)), 1)


## One tick on a connected client: the command into the history, predicted, and sent.
func client_tick(tick: int, command: DotFpsCommand) -> void:
	if net == null or net.is_server or game == null:
		return

	var packet := LmNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()
	net.local_inputs().push(packet)
	var mine: LmPlayerNet = _behaviours.get(local_key, null)

	if mine != null:
		mine.last_move = packet.move

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		DotNetInput.write_batch(writer, _input_copies(packet))
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	if _client_ticked_for != tick:
		_client_ticked_for = tick
		game.tick = tick

		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())


## [param packet] and the commands before it from the local replay history, oldest first, for
## one input packet. See [constant INPUT_COPIES].
func _input_copies(packet: DotNetInput) -> Array:
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, packet.tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(packet)
	return batch


func _on_event(message: DotNetMessage) -> void:
	var event := message as LmEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var data := LmEvents.read_level(event.reader()) if event.kind == LmEvents.Kind.LEVEL \
		else LmEvents.read_json(event.reader())

	match event.kind:
		LmEvents.Kind.HELLO:
			local_key = StringName(str(data.get("you", "")))
			_levels_expected = int(data.get("levels", 0))
			_hello_serial = int(data.get("serial", 0))
			game.house_id = StringName(str(data.get("house", "house")))
			game.houses[game.house_id] = {"name": str(data.get("house_name", "")), "directory": ""}
			_levels_got = []
			var settings: Dictionary = data.get("config", {})

			for setting: String in settings:
				if setting in game.config:
					game.config.set(setting, settings[setting])

			# A server older than mp_forceview says only this; a newer one's cvar arrives
			# through the link and outranks it.
			if settings.has("allow_third_person") and not bool(settings["allow_third_person"]) \
					and game.view_rules.force_view == DotPlayerViewRules.ANY:
				game.view_rules.force_view = DotPlayerViewRules.FIRST_ONLY

			if _levels_expected == 0:
				hello_received.emit(local_key)
		LmEvents.Kind.LEVEL:
			if data.is_empty():
				DotLog.error(CHANNEL, "a level arrived that could not be read", {"bytes": event.body.size()})
				return

			_levels_got.append(data)

			if not _ack_queued:
				_ack_queued = true
				_ack_levels.call_deferred()

			if _levels_got.size() == _levels_expected:
				game.documents.clear()

				for doc: Dictionary in _levels_got:
					game.documents[int(doc["number"])] = doc

				game.build_levels()
				hello_received.emit(local_key)
		LmEvents.Kind.JOIN:
			_apply_join(data)
		LmEvents.Kind.LEAVE:
			var key := StringName(str(data.get("key", "")))
			var behaviour: LmPlayerNet = _behaviours.get(key, null)
			_behaviours.erase(key)

			if behaviour != null and behaviour.identity != null and net.registry.has(behaviour.identity.net_id):
				net.registry.unregister(behaviour.identity.net_id)

			game.leave(key)
		LmEvents.Kind.PROGRESS:
			_apply_progress(data)
		LmEvents.Kind.SAY:
			if bool(data.get("notice", false)):
				notice_received.emit(str(data.get("text", "")))
			else:
				said.emit(str(data.get("text", "")))
		LmEvents.Kind.CHAT:
			chat_received.emit(data)
		LmEvents.Kind.SOUND:
			sound_received.emit(StringName(str(data.get("id", ""))))


func _apply_join(data: Dictionary) -> void:
	var key := StringName(str(data.get("key", "")))

	if key == &"":
		return

	var avatar := _avatar_from_wire(key, data.get("avatar", {}))
	var voice_peer := int(data.get("peer", 0))

	if voice_peer > 0:
		speaker_keys[voice_peer] = key

	# Again for somebody already here is a new name or face, not a second player.
	if _behaviours.has(key):
		var known: LmPlayer = game.players.get(key, null)

		if known != null:
			known.display_name = str(data.get("name", known.display_name))
			known.set_avatar(avatar)

		return

	var player := game.join(key, str(data.get("name", key)), avatar)
	var mine := key == local_key
	var identity := _build_entity(player, net.local_peer_id if mine else 0, int(data.get("net_id", 0)))

	if mine:
		var _claimed := net.registry.change_owner(identity.net_id, net.local_peer_id)


## A document that does not parse is the stock person, not a refused join: an avatar is
## cosmetic, and somebody who cannot be drawn as themselves can still be drawn.
static func _avatar_from_wire(key: StringName, wire: Variant) -> DotAvatar:
	if wire is Dictionary and not (wire as Dictionary).is_empty():
		var built := DotAvatar.from_dict(wire)

		if built.ok:
			return built.value

	return LmAvatars.stock_avatar(key)


## The owner's own progress: what to show, and the doors its prediction must walk through.
func _apply_progress(data: Dictionary) -> void:
	var player: LmPlayer = game.players.get(local_key, null)

	if player == null:
		return

	player.level = int(data.get("level", player.level))
	player.best = int(data.get("best", player.best))
	player.won = bool(data.get("won", player.won))
	player.holds.assign(data.get("holds", []))
	player.opened = _set_of(data.get("opened", []))
	player.used = _set_of(data.get("used", []))
	player.taken = _set_of(data.get("taken", []))
	player.fired = _set_of(data.get("fired", []))
	game._apply_doors(player)
	progress_received.emit(data)


static func _set_of(list: Variant) -> Dictionary:
	var out := {}

	if list is Array:
		for id: Variant in list:
			out[str(id)] = true

	return out


# --- Chat and voice: dot-game's services reach the wire through these -----------------

func send_chat(peer_id: int, wire: Dictionary) -> void:
	_tell(peer_id, LmEvents.Kind.CHAT, wire)


func receive_voice(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net != null and net.is_server:
		if voice_relay_fn.is_valid():
			voice_relay_fn.call(peer_id, payload)
	else:
		voice_arrived.emit(payload)

	return DotResult.success(true)


func send_voice_up(payload: PackedByteArray) -> void:
	if link != null:
		link.send_voice(1, payload)


func describe() -> Dictionary:
	return {"server": net != null and net.is_server, "players": _behaviours.size(), "peers": _ready_peers.size(), "local": String(local_key),
		"houses_sending": _house_out.size()}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["bridge %s" % describe()])

	if link != null:
		lines.append_array(link.describe_lines())

	return lines
