extends DotGameModule

## This game, as a module a dedicated server loads. Over dot-game, like the others.
##
## What is this game's: the netcode's numbers, the commands an operator types, where who won is
## kept, and the key a player's progress is kept under. A chat line beginning with / that the
## house understands (/r, /l3) is the house's; everything else goes to chat.
##
## [b]No `class_name`[/b]: a module delivered inside a dot-cloud pack cannot have one.

const LmNetBridge := preload("net/lm_net_bridge.gd")
const LmServices := preload("lm_services.gd")
const LmGame := preload("lm_game.gd")
const LmPlayer := preload("lm_player.gd")
const LmProgress := preload("lm_progress.gd")
const LmVote := preload("lm_vote.gd")
const LmAvatars := preload("lm_avatars.gd")
const LmMapConfig := preload("lm_map_config.gd")

## The players' vote for the next house, or null.
var vote: LmVote = null

## Players' numbers and achievements, or null when the server keeps none.
var progress: LmProgress = null


func _module_name() -> String:
	return "lookatme"


## The rules a house's `cfg/game/mg-look-at-me/dot_map/map/<house>.yml` may set (see docs/map-config.md in dot-game).
func _map_config_keys() -> Dictionary:
	return LmMapConfig.KEYS


func _map_config_game() -> String:
	return LmMapConfig.GAME_ID


func _game_service() -> StringName:
	return LmGame.SERVICE


func _game_missing_hint() -> String:
	return "load scenes/lm_server.tscn as the game scene: it builds the house this module drives"


func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as LmGame).tick_rate
	config.snapshot_rate = LmGame.NET_SNAPSHOT_RATE
	config.world_extent = LmGame.NET_WORLD_EXTENT
	# Players are predicted by their owners, as in every first-person game here.
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 64
	return config


func _make_bridge() -> Node:
	var made := LmNetBridge.new()
	# A win and a level reached are kept under the account, so a reconnect is the same person.
	made.key_fn = func(_peer_id: int, session_id: int) -> StringName:
		var session := server.session_by_userid(session_id) if server != null else null
		var uid := session.uid() if session != null else ""
		return StringName("uid:%s" % uid) if uid != "" else &""
	# One account, one player: the newest connection wins and the older is told why it was
	# dropped (docs/design.md, "One account, one connection"). Deferred, because the bridge
	# says so from inside the roster seating the newcomer, and a kick re-enters that roster.
	made.superseded.connect(func(peer_id: int, _key: StringName) -> void:
		_drop_superseded.call_deferred(peer_id))
	return made


func _drop_superseded(peer_id: int) -> void:
	var session := server.session_of(peer_id) if server != null else null

	if session != null and session.is_active():
		var _kicked := server.kick(session, LmNetBridge.SUPERSEDED_REASON)


func _make_services() -> Node:
	return LmServices.new()


## Profiles, names and faces: dot-platform's identity over mg-deathrun's one-slot schema, so a
## TMC account walks the house as the avatar it picked on the site. Authentication is the
## host's, as for every game; with it off everybody is a guest with a stock face.
func _make_identity() -> Node:
	var identity_layer := DotPlatformIdentity.new()
	identity_layer.avatar_schema = LmAvatars.schema()
	identity_layer.stock_avatar_fn = LmAvatars.stock_avatar
	identity_layer.avatar_translate_fn = LmAvatars.from_site
	return identity_layer


## The Tab board's columns: the level each player is on, the furthest they have reached,
## and whether they got out. Kept under the account (see [method _make_bridge]), which a
## client cannot work out from a session, so they come from here.
func _game_board_fields(session: Object) -> Dictionary:
	var world := game as LmGame
	var uid := str(session.call("uid")) if session != null and session.has_method("uid") else ""
	if world == null or uid == "":
		return {}
	var who: LmPlayer = world.players.get(StringName("uid:%s" % uid))
	if who == null:
		return {}
	return {"level": who.level, "best": who.best, "won": who.won}


func _game_load() -> DotResult:
	var world := game as LmGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not the house.")

	# dot-player-controller's mp_forceview (0 the player's choice, 1 first person only, 2 third
	# only; the config's allow_third_person false starts it at 1) and mp_solidplayers.
	# REPLICATED: each client places its own camera and predicts its own player under them.
	var _views := world.view_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	var _bodies := world.body_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	# lm_ambient*: REPLICATED, because each client plays its own ambience under the server's intent; the directory cvar stays local.
	var _ambient := world.ambient_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED,
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)

	# dot-game's "still loading": a seat behind its client's cover is not caught (LmGame.harm_gate).
	world.harm_gate = func(key: StringName) -> bool:
		if bridge == null:
			return true
		var peer: int = bridge.call("peer_of", key)
		return peer <= 0 or can_peer_be_harmed(peer)

	_wire_voice(world)

	add_command("lm_status", _cmd_status, "Show the house and who is on which level")
	add_command("lm_send", _cmd_send, "Send a player to a level: lm_send <name> <level>", DotAdminFlags.CHANGEMAP)
	add_command("lm_winners", _cmd_winners, "List everybody who has got out of this house")
	# Renameable from maps.yml's `commands:` block, like dot-vote's. An admin's lm_house loads
	# any house, in the rotation or not.
	for name in world.command_names("lm_house"):
		add_command(name, _cmd_house, "Play another house now: lm_house <id>, or the list with none", DotAdminFlags.CHANGEMAP)
	add_command("lm_rotation", _cmd_rotation,
		"lm_rotation [name]: switch to a rotation in maps.yml, or list them", DotAdminFlags.CHANGEMAP)
	add_command("lm_maps_reload", _cmd_maps_reload, "Re-read maps.yml", DotAdminFlags.CHANGEMAP)
	_file_cvar = add_cvar("sv_map_rotation_file", world.config.map_rotation_file,
		"maps.yml: the houses that rotate, in named rotations. Unlisted houses stay installed.")
	_file_cvar.changed.connect(func(_old: String, new_value: String) -> void:
		world.config.map_rotation_file = new_value.strip_edges()
		var _read := world.load_rotation()
		if vote != null:
			vote.refresh_houses())

	# After the commands: the config's `house` has no cvar where `lm_house` is the command.
	var configured := _bind_config(world)
	if not configured.ok:
		return configured

	if bridge != null:
		bridge.connect("say_requested", _on_say_requested)

	_wire_identity()

	# Houses from the map packs the server names (its cfg/content.yml), before the vote
	# lists what can be played.
	var delivered: PackedStringArray = await DotGameContent.map_dirs(server, "houses")

	if not delivered.is_empty():
		world.add_house_roots(delivered)

	_build_vote(world)

	progress = LmProgress.new()
	progress.name = "Progress"
	add_child(progress)
	var made := progress.setup(world, "user://lookatme_achievements", true)

	if not made.ok:
		DotLog.result(CHANNEL, "progress is off", made)
		progress.queue_free()
		progress = null
	else:
		progress.earned.connect(func(key: StringName, title: String, points: int) -> void:
			var peer: int = bridge.call("peer_of", key) if bridge != null else 0

			if peer > 0:
				bridge.call("notice", peer, "Achievement: %s (+%d)" % [title, points]))

	if not world.levels.is_empty():
		var _reported := report_map(str((world.levels[1] as Node).get("doc").get("id", "lm_01")))
		# The house is this game's map: its yml applies when one opens, the old house's values go back.
		world.house_changed.connect(func(id: StringName) -> void:
			var _again := report_map(String(id)))

	return DotResult.success(null)


## dot-workbench over the config; the F9 panel off a dedicated server, the HTTP page only with `workbench.enabled`.
var workbench: DotGameWorkbench = null

var _file_cvar: DotConVar = null


## Every config field as an `lm_<field>` cvar (`sv_map_rotation_file` keeps its handler and follows edits), the cfg/ diff commands, the workbench and the block rules.
func _bind_config(world: LmGame) -> DotResult:
	var binder := world.config_binder
	if binder == null:
		return DotResult.success(null)
	workbench = DotGameWorkbench.new()
	workbench.name = "Workbench"
	workbench.dedicated = DisplayServer.get_name() == "headless"
	workbench.listen_host_fn = func() -> bool: return DisplayServer.get_name() != "headless"
	workbench.permit_fn = func(actor: Variant, flag: String) -> bool:
		return server != null and server.admins != null and actor is String \
			and bool(server.admins.uid_has_permission(actor, flag))
	workbench.add_set(binder.profile_set(), "Game settings")
	add_child(workbench)
	var started := workbench.start()
	var runtime: DotProfileRuntime = workbench.api.runtime if started.ok and workbench.api != null else null
	if not started.ok:
		log_warn("the workbench did not start", {"why": started.error.message})

	binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY,
		func(name: String) -> bool: return console.has_name(name))
	binder.bind_commands(add_command)
	binder.field_changed.connect(_on_config_field)
	if runtime != null:
		binder.attach(runtime)
	return DotResult.success(null)


## Everybody is one side: the house is played together.
func _noblock_side(id: Variant) -> Variant:
	return game.call(&"team_of_side", id) if game != null else ""


## The workbench's runtime, so its "noblock" kind is listed beside the config.
func _noblock_runtime() -> Object:
	return workbench.api.runtime if workbench != null and workbench.api != null else null


## The block commands are keyed by the house's player keys (`uid:<uid>`), not the session id.
func _build_noblock() -> DotResult:
	var built := super()
	if built.ok and noblock != null and noblock.commands != null:
		noblock.commands.set(&"key_fn", func(ctx: Object) -> Variant:
			var session: Variant = ctx.get("session")
			if session is Object and (session as Object).has_method("uid"):
				return StringName("uid:%s" % (session as Object).call("uid"))
			return null)
	return built


## A workbench or file edit of a field the game also acts on beyond the config.
func _on_config_field(key: String, _value: Variant, source: String) -> void:
	var world := game as LmGame
	if world == null:
		return
	if key == "map_rotation_file" and _file_cvar != null and _file_cvar.get_string() != world.config.map_rotation_file:
		_file_cvar.set_value(world.config.map_rotation_file)
	if source == "cvar":
		return
	match key:
		"house_minutes":
			if vote != null:
				vote.house_minutes = world.config.house_minutes


func _game_unload() -> void:
	if workbench != null:
		workbench.queue_free()
		workbench = null
	if game != null and "block_rules" in game:
		game.set(&"block_rules", null)
	noblock = null


## Voice's server side beyond what dot-game binds (sv_voice_enable, _mode and the proximity
## cvars, which [LmServices] gave this game's defaults): the witches hearing a talker.
## The look-to-gag switches are registered by dot-game's module.
func _wire_voice(world: LmGame) -> void:
	var router: Object = services.get("voice") if services != null else null

	if router != null and router.has_signal(&"speech_relayed"):
		# The router counts a packet it relayed, so a muted or rate-limited speaker is no
		# sound; the key is looked up here because the router knows peers and the house keys.
		router.connect(&"speech_relayed", func(speaker: int, _listeners: int) -> void:
			world.hear_voice(bridge.call("key_of_peer", speaker)))


## A chat line: the house's when it is one of its commands, the chat router's otherwise.
func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var key: StringName = bridge.call("key_of_peer", peer_id)

	if text.begins_with("/") and key != &"":
		var reply := (game as LmGame).command(key, text)

		if reply != "":
			bridge.call("notice", peer_id, reply)
			return

	if services == null:
		return

	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if not said.ok:
		bridge.call("notice", peer_id, said.error.message)


## dot-vote over the houses: a time limit (house_minutes), rock the vote, nominations. The
## ballot is drawn on clients from a `map_ballot` notice, as every game's map vote is.
func _build_vote(world: LmGame) -> void:
	vote = LmVote.new()
	vote.name = "HouseVote"
	vote.commands_spec_fn = world.rotation_commands
	vote.house_minutes = world.config.house_minutes
	vote.houses_fn = func() -> Array:
		return world.rotating_houses()
	vote.apply_fn = func(id: StringName) -> DotResult:
		return world.change_house(id)
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for key: StringName in world.players:
			var peer: int = bridge.call("peer_of", key) if bridge != null else 0
			var session := server.session_of(peer) if server != null and peer > 0 else null

			if session != null:
				out.append(StringName(str(session.userid)))

		return out
	# [b]Through this game's chat router, not dot-server's system chat.[/b] A routed line keeps
	# the channel and colour every other line here has, and reaches a client whose shell is
	# older than the dot-game that draws dot-server's own lines too (DotGameChatClient). The
	# house ballot's "Vote: The House, The Asylum, Extend (30s)" was once drawn nowhere.
	# smash and the other minigames announce the same way.
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, LmServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	# Who a voter is: the ballot draws their avatar, and dot-vote's chat lines ("Alice
	# nominated The Asylum.") name them with it. Unset, both fell back to the userid.
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(&"", "", float(state.get("seconds", -1.0)), &"map_ballot", data))
	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the house vote; the server stays on its house", ready)
		vote.queue_free()
		vote = null
		return

	DotLog.result(CHANNEL, "the house vote's commands", vote.install_commands(self))
	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` opens a house
	# now, and sees the same rows a solo player does. Read by name, because a server on a
	# dot-vote older than the menu has no `map_menu` and runs without it.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", world.change_house)
		(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return world.house_rows())
	vote.note_house(world.house_id)
	world.house_changed.connect(func(id: StringName) -> void:
		if vote != null:
			vote.note_house(id))

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid))))


func _game_tick(_tick: int, delta: float) -> void:
	if vote != null:
		vote.advance(delta)


func _cmd_house(ctx: DotCmdContext) -> void:
	var world := game as LmGame
	var id := ctx.arg(0)

	if id == "":
		var lines := PackedStringArray(["houses (playing %s)" % String(world.house_id)])

		for key: StringName in world.houses:
			lines.append("  %-10s %s" % [key, world.houses[key]["name"]])

		ctx.reply_lines(lines)
		return

	var changed := world.change_house(StringName(id))

	if not changed.ok:
		ctx.reply_error(changed)
		return

	ctx.reply("Now playing %s." % world.house_name())


func _cmd_rotation(ctx: DotCmdContext) -> void:
	var world := game as LmGame

	if world == null or not world.has_rotation_file():
		ctx.reply("There is no maps.yml; every house rotates.")
		return

	var file := world.rotation_file

	if ctx.argc() == 0:
		ctx.reply("Rotations: %s (active: %s)" % [", ".join(file.rotation_names()), file.active_name()])
		return

	var switched := world.switch_rotation(ctx.arg(0))

	if not switched.ok:
		ctx.reply(switched.error.message)
		return

	if vote != null:
		vote.refresh_houses()

	ctx.reply("Rotation: %s" % ctx.arg(0))


func _cmd_maps_reload(ctx: DotCmdContext) -> void:
	var world := game as LmGame
	var read := world.load_rotation()

	if vote != null:
		vote.refresh_houses()

	ctx.reply("maps.yml read." if read.ok else read.error.message)


func _cmd_status(ctx: DotCmdContext) -> void:
	ctx.reply_lines((game as LmGame).describe_lines())


func _cmd_send(ctx: DotCmdContext) -> void:
	var world := game as LmGame
	var who := ctx.arg(0)
	var n := ctx.arg_int(1, 1)

	for key: StringName in world.players:
		var player: Node = world.players[key]

		if str(player.get("display_name")).to_lower() == who.to_lower():
			player.set("best", maxi(int(player.get("best")), n))
			world.send_to(player, n)
			ctx.reply("%s is on level %d." % [who, n])
			return

	ctx.reply("Nobody called '%s' is here." % who)


func _cmd_winners(ctx: DotCmdContext) -> void:
	var world := game as LmGame
	var lines := PackedStringArray(["winners (%d) of %s" % [world.winners.size(), world.house_name()]])

	for key: String in world.winners:
		lines.append("  %s  %s" % [key, world.winners[key]])

	var everywhere := world.all_winners()

	for house: String in everywhere:
		if house != String(world.house_id) and not (everywhere[house] as Dictionary).is_empty():
			lines.append("  and %d out of %s" % [(everywhere[house] as Dictionary).size(), house])

	ctx.reply_lines(lines)


## Admission finishes after a player is seated, so the real name and face arrive as
## `player_admitted`; a wardrobe change and an operator's rename are the same thing later. All
## three end in [method LmNetBridge.refresh_player], a JOIN every client already applies.
func _wire_identity() -> void:
	var link := bridge as LmNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## Through the platform module's `player_for`, never the hub by a key made here: the hub keys
## a player by the scoped profile key only admission knows (mg-deathrun found a lookup by any
## other key finds nobody, every time, and reads as "no avatar"). Duck-typed, because a server
## without dot-platform is a configuration.
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session != null and platform != null and platform.has_method("player_for"):
		var player: Variant = platform.call("player_for", session)

		if player is Object and (player as Object).get("avatar") is DotAvatar:
			return (player as Object).get("avatar") as DotAvatar

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null
	var link := bridge as LmNetBridge

	if session == null or link == null:
		return

	var _refreshed := link.refresh_player(session_id, session.display_name, _avatar_for(session_id))
