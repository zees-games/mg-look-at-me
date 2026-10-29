extends "lm_net_bridge_client.gd"

## The only file that names both the house and the netcode. Both ends. Movement is mg-deathrun's, the rest JSON events.
## A door is open only for the player who opened it ([LmGame._apply_doors]), so the owner's client must exclude the
## same doors from its predicting controller or every snapshot drags them back; PROGRESS carries `opened`.


func _exit_tree() -> void:
	# The link and the runtime hold each other through broadcast.
	if profile_link != null:
		profile_link.release()
		profile_link = null


func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	var world := p_game as LmGame

	if world == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs a house and a manager.")

	if world.authoritative != p_net.is_server:
		return DotResult.fail(DotError.CODE_STATE, "The house and the manager disagree about who is authoritative.")

	game = world
	net = p_net
	net.send_fn = _send
	profile_link = DotNetProfileLink.attach(net, world.ensure_runtime())

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

	# Not parent.add_child: the link sits under the server (RPCs route by path) but must die with this
	# bridge, or a module reload leaves a second one and Godot renames the live one `@Node@n`.
	# DotGameLink frees it without remove_child, which errors on a busy parent.
	DotGameLink.attach(link, parent, self, LmNetLink.NODE_NAME)


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




func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	var key: StringName = key_fn.call(peer_id, session_id) if key_fn.is_valid() else session_key(session_id)

	if key == &"":
		key = session_key(session_id)

	# The same account again: the newest wins. The old peer leaves exactly as a disconnect does, BEFORE the
	# newcomer is seated, or the one key makes the newcomer's seat take its player and its later leave remove it;
	# the module is told so it can disconnect that peer with a reason it will show.
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


func _admit(peer_id: int) -> void:
	var key: StringName = _key_of_peer.get(peer_id, &"")

	if key == &"":
		_ready_unseated[peer_id] = true
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	if profile_link != null:
		profile_link.peer_joined(peer_id)

	_send_house(peer_id)

	for other: StringName in _behaviours:
		_tell(peer_id, LmEvents.Kind.JOIN, _join_body(other))

	_broadcast(LmEvents.Kind.JOIN, _join_body(key))
	_send_progress(key)


## The house to one peer: a HELLO, then one LEVEL each paced by acks ([constant LEVEL_WINDOW]); anything else
## told meanwhile is held until the last LEVEL; a second house replaces the first.
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
			"flashlight_range": game.config.flashlight_range, "flashlight_angle": game.config.flashlight_angle,
			"darkness_ambient": game.config.darkness_ambient, "witch_door_seconds": game.config.witch_door_seconds,
			"witch_chase_speed": game.config.witch_chase_speed, "run_speed": game.config.run_speed,
			"walk_speed_scale": game.config.walk_speed_scale, "jump_height": game.config.jump_height,
			"gravity": game.config.gravity, "accelerate": game.config.accelerate, "friction": game.config.friction,
			"stop_speed": game.config.stop_speed, "crouch_speed_scale": game.config.crouch_speed_scale}.merged(_scare_settings()),
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
