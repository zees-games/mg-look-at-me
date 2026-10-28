extends Node

## The bridge's state and the client half: asking the server, applying what it sends.



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

## Commands in every input packet: this tick's and the four before it, so a lost packet costs no
## tick unless the next four are lost too. Inputs go unreliable, and one command a packet made
## every drop a server tick run on the previous command, a correction each time.
const INPUT_COPIES := 5

## The most LEVEL bytes a client may have been sent and not yet acknowledged: half a browser's 64 KiB
## WebSocket buffer, since snapshots, chat and a frame spent building need the other half. A larger
## level still goes, alone.
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
## Carries the game's profile runtime over this manager (rows down, for a remote admin's panel).
var profile_link: DotNetProfileLink = null

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
## Server: peers whose READY came before their seat ([method add_player]); over ENet with loss
## READY can overtake `loaded`, and dropping it left the client waiting for ever. Admitted when seated.
var _ready_unseated: Dictionary = {}

## Client: the HELLO the LEVELs arriving belong to, and whether this frame's ack is queued.
var _hello_serial: int = 0
var _ack_queued := false


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


