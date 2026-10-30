extends "lm_game_senses.gd"

## The house: every level at once, side by side, every player on the level they are on, and the witches. Headless; [LmClient] draws.
## A server that never ends: no rounds or sides, only each player's own progress. Being seen is a meter: each tick a witch asks whether she
## sees a player (range, cone, line of sight; nearer, lit and moving is faster); it climbs while she does, drains after a pause, full is caught.


func ensure_runtime() -> DotProfileRuntime:
	if profile_runtime == null:
		profile_runtime = DotProfileRuntime.new()
		profile_runtime.permit = func(actor: Variant, _flag: String) -> bool:
			return typeof(actor) == TYPE_STRING_NAME and actor == &"local"
	return profile_runtime


func _init() -> void:
	config = LmConfig.new()


## A player's motor mask under `mp_solidplayers`: the walls, and the other players when they
## are solid. Their capsule is already on LAYER_PLAYERS, so the mask is the whole change.
func _apply_body_mask(player: LmPlayer) -> void:
	if player != null and player.controller != null:
		body_rules.apply_to(player.controller, LAYER_WORLD, LAYER_PLAYERS)


func _on_body_rules_changed() -> void:
	for key in players:
		_apply_body_mask(players[key] as LmPlayer)
	apply_pass_through()


## The side a player is on for dot-team's block rules: everybody is one, because the house is played together.
func team_of_side(_key: Variant) -> Variant:
	return "1"


## Hands every controller the bodies it passes through under `block_rules`; the same call on every machine, or a client predicts a wall.
func apply_pass_through() -> void:
	var entries := {}
	for key: Variant in players:
		var who := players[key] as LmPlayer
		if who != null and who.controller != null:
			entries[key] = {"body": who, "controller": who.controller}
	body_rules.apply_exceptions(entries)


func _ready() -> void:
	if config_binder == null:
		config_binder = LmConfig.make_binder(config, "user://cfg/lookatme.json")
	var loaded := config_binder.load_layers()
	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return
	tick_rate = Engine.physics_ticks_per_second
	# The config's old switch is the server rule's first value until a cvar says otherwise.
	if not config.allow_third_person:
		view_rules.force_view = DotPlayerViewRules.FIRST_ONLY
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)

	if authoritative:
		_find_houses()
		follow_content(DotContentIndex.shared(), accepted_map_kinds())
		var _rotation := load_rotation()
		var start := StringName(config.house) if houses.has(StringName(config.house)) else &"house"
		var _h := change_house(start)
		_read_winners()

	if register_service:
		DotRegistry.register(SERVICE, self)

	set_physics_process(self_tick)
	DotLog.info(CHANNEL, "the house is ready", {"levels": levels.size(), "refused": refused.size()})


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


## Plays house [param id]: its levels replace these, and everybody starts again in its lobby.
## What the vote does, and what `lm_house` does for an operator.
func change_house(id: StringName) -> DotResult:
	sync_content()

	if not houses.has(id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no house '%s'." % id)

	documents.clear()
	refused.clear()
	var _n := load_directory(str(houses[id]["directory"]))

	if documents.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "House '%s' has no levels." % id)

	build_levels()
	house_id = id
	_select_winners()

	for key: StringName in players:
		var player: LmPlayer = players[key]
		player.best = 1
		send_to(player, 1)

	if has_rotation_file() and _defs.get_map(id) != null:
		_rotation.note_played(id)

	DotLog.info(CHANNEL, "a house opened", {"house": String(id), "levels": levels.size()})
	house_changed.emit(id)
	return DotResult.success(id)


func join(key: StringName, name_text: String, avatar: DotAvatar = null) -> LmPlayer:
	if players.has(key):
		return players[key]

	var player := LmPlayer.new()
	player.name = "Player_%s" % String(key)
	player.player_key = key
	player.display_name = name_text
	player.avatar = avatar
	player.config = config
	player.tick_rate = tick_rate
	add_child(player)
	players[key] = player
	_apply_body_mask(player)
	apply_pass_through()
	player.won = winners.has(String(key))
	send_to(player, 1)
	player_joined.emit(key)
	return player


func leave(key: StringName) -> void:
	var player: LmPlayer = players.get(key, null)

	if player == null:
		return

	players.erase(key)
	if block_rules != null:
		block_rules.call(&"forget", key)
	player.queue_free()
	apply_pass_through()
	player_left.emit(key)


func set_flashlight(key: StringName, on: bool) -> void:
	var player: LmPlayer = players.get(key, null)

	if player != null:
		player.flashlight = on


## A fright the player's client reports: raises the meter by [param amount], capped at `scare_meter_cap`; the drain waits as after a sighting.
## Refused during a catch, with demons off, or inside `scare_cooldown` of the last: a client may only ask for the meter to go UP,
## and the cooldown stops a loop of asks being the way to a catch. Returns whether it applied.
func spook(key: StringName, amount: float) -> bool:
	var player: LmPlayer = players.get(key, null)

	if player == null or player.caught_left > 0.0 or amount <= 0.0:
		return false

	if not can_be_harmed(key):
		return false

	if not config.demons_enabled and not config.look_behind_enabled and not config.clown_enabled:
		return false

	var now := seconds_now()

	if now - player.spooked_at < minf(config.scare_cooldown, 5.0):
		return false

	var top := maxf(maxf(config.demon_spike_max, config.look_behind_spike_max), config.clown_damage_max if config.clown_enabled else 0.0)
	player.spooked_at = now
	player.meter = maxf(player.meter, minf(player.meter + minf(amount, top), config.scare_meter_cap))
	player.unseen_for = 0.0
	return true



func _physics_process(delta: float) -> void:
	step(delta)


func step(delta: float) -> void:
	tick += 1

	if not authoritative:
		return

	if hold_clock.is_valid() and bool(hold_clock.call()):
		for key: StringName in players:
			var body: LmPlayer = players[key]
			_apply_doors(body)
			body.simulate(tick, delta)
		return

	var seconds := float(tick) / float(maxi(tick_rate, 1))

	for key: StringName in players:
		var player: LmPlayer = players[key]

		if player.caught_left > 0.0:
			player.caught_left -= delta

			if player.caught_left <= 0.0:
				_put_back(player)

			continue

		_apply_doors(player)
		player.simulate(tick, delta)
		_watch(player, seconds, delta)
		fire_events(player)
		_check_exit(player)


func _put_back(player: LmPlayer) -> void:
	var keep := player.holds.duplicate()
	var keep_opened := player.opened.duplicate()
	var keep_used := player.used.duplicate()
	var keep_taken := player.taken.duplicate()
	var keep_fired := player.fired.duplicate()
	send_to(player, player.level)

	if config.caught_penalty == 0:
		player.holds.assign(keep)
		player.opened = keep_opened
		player.used = keep_used
		player.taken = keep_taken
		player.fired = keep_fired
		_apply_doors(player)


func _check_exit(player: LmPlayer) -> void:
	var level := level_of(player)

	if level == null or not player.opened.has("exit"):
		return

	if not level.is_out(player.global_position - level.position):
		return

	var done := player.level
	level_done.emit(player.player_key, done)

	if done >= last_level():
		player.won = true
		winners[String(player.player_key)] = Time.get_datetime_string_from_system()
		_write_winners()
		won.emit(player.player_key)
		said.emit(player.player_key, "YOU GOT OUT. ALL OF IT.")
		send_to(player, 1)
		return

	said.emit(player.player_key, "LEVEL %d" % (done + 1))
	send_to(player, done + 1)


func _read_winners() -> void:
	if not FileAccess.file_exists(config.winners_file):
		return

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(config.winners_file))

	if not (parsed is Dictionary):
		return

	_all_winners.clear()

	for k: Variant in parsed:
		if parsed[k] is Dictionary:
			_all_winners[str(k)] = parsed[k]
		else:
			# The file before houses had winners: one flat {key: when}, and the only house there
			# was the built-in one. Read as that house's, so nobody's crown goes missing.
			if not _all_winners.has("house"):
				_all_winners["house"] = {}

			_all_winners["house"][str(k)] = parsed[k]

	_select_winners()


## [member winners] made this house's, and every player's crown with it.
func _select_winners() -> void:
	var key := String(house_id)

	if not _all_winners.has(key):
		_all_winners[key] = {}

	winners = _all_winners[key]

	for player_key: StringName in players:
		(players[player_key] as LmPlayer).won = winners.has(String(player_key))


## Every house's winners: house id -> {key: when}.
func all_winners() -> Dictionary:
	return _all_winners


func _write_winners() -> void:
	DirAccess.make_dir_recursive_absolute(config.winners_file.get_base_dir())
	var file := FileAccess.open(config.winners_file, FileAccess.WRITE)

	if file != null:
		file.store_string(JSON.stringify(_all_winners, "\t"))
		file.close()
		DotWeb.sync_filesystem()


func describe() -> Dictionary:
	return {"house": String(house_id), "houses": houses.size(), "levels": levels.size(), "players": players.size(), "winners": winners.size(), "tick": tick}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["look at me: %s" % describe()])

	for key: StringName in players:
		lines.append("  %s %s" % [(players[key] as LmPlayer).display_name, (players[key] as LmPlayer).describe()])

	return lines
