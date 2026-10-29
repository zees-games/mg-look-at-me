extends "headless_run_witch.gd"

## The house, headless: every level built and finished, doors that are open for one player and
## shut for another, what a witch can see, being caught, the commands, and winning.
##
##   godot --headless --path . res://examples/headless_run.tscn

const SECTIONS := 23
const CHECKS := 187


func _ready() -> void:
	print("look at me, headless")
	game = LmGame.new()
	game.draws = false
	game.self_tick = false
	game.config.winners_file = "user://test_lookatme_winners.json"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(game.config.winners_file))
	add_child(game)
	await get_tree().physics_frame
	var progress := LmProgress.new()
	add_child(progress)
	var _p := progress.setup(game, "", false)
	progress.earned.connect(func(key: StringName, title: String, _points: int) -> void: _earned.append([String(key), title]))

	_test_levels()
	_test_every_level_finishes()
	await _test_a_stand_in_plays()
	await _test_doors_are_per_player()
	_test_sight()
	await _test_caught()
	_test_commands()
	await _test_winning()
	_test_shared()
	_test_events()
	_test_houses()
	await _test_the_client_settings()
	await _test_sound_and_effects()
	await _test_the_mouse_turns_the_view()
	await _test_the_witch_and_the_house()
	await _test_the_events_seen_and_heard()
	await _test_upstairs()
	await _test_the_hud_fits()
	_test_witch_senses()
	await _test_voice()
	await _test_scares()
	_test_wheel_jumps()
	await _test_collision_audit()

	# Freed here so its resources and RIDs are released before the engine's leak report.
	for child in get_children():
		remove_child(child)
		child.free()
	game = null
	(load("res://game/lm_surfaces.gd") as GDScript).call(&"clear_cache")
	DotHumanoidFigure.clear_cache()
	DotHudPiece.clear_cache()
	DotMenuKit.clear_cache()
	LmLevel.clear_cache()
	DotRegistry.clear()
	_report_sections(_entered, _finished, SECTIONS, CHECKS)


## Proximity voice as this game configures it: the gain a listener gets at distance, a wall
## turning it down, nothing past the radius, and a witch hearing a talker.
func _test_voice() -> void:
	_section("voice: proximity with a short radius, a wall turns it down, witches hear it")
	var services := LmServices.new()
	services.game = game
	var router := DotVoiceRouter.new()
	var format := LmServices.voice_format()
	router.config = format
	router.default_channel = services._voice_default_channel()
	services.configure_voice(router)
	_check(router.default_channel == DotVoiceRouter.Channel.PROXIMITY, "voice is proximity by default")
	_check(router.proximity_range == LmServices.PROXIMITY_RANGE and router.proximity_range <= 20.0, "with a short radius", str(router.proximity_range))
	_check(router.proximity_occlusion and router.occlusion_fn.is_valid(), "and a wall in the way is on")
	var specs := {}

	for spec in router.cvar_specs():
		specs[String(spec["name"])] = String(spec["value"])

	_check(specs.get("sv_voice_proximity_occlusion", "") == "1" and specs.get("sv_voice_proximity_range", "") == str(LmServices.PROXIMITY_RANGE), "the sv_voice_* cvars default to those", str(specs))

	var level: LmLevel = game.levels[1]
	var centre: Vector3 = level.position + level.room_centre(level.spawn_room())
	var space := game.get_world_3d().direct_space_state
	var head := Vector3.UP * 1.6
	var clear_at := Vector3.ZERO
	var wall_at := Vector3.ZERO
	var dirs: Array[Vector3] = [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD]

	for dir in dirs:
		for step in range(6, 25):
			var d := float(step) * 0.5
			var at := centre + dir * d
			var hit := not space.intersect_ray(PhysicsRayQueryParameters3D.create(centre + head, at + head, LmGame.LAYER_WORLD)).is_empty()

			if not hit and d >= 3.0 and clear_at == Vector3.ZERO:
				clear_at = at
			if hit and wall_at == Vector3.ZERO and d >= 4.0:
				wall_at = at

	_check(clear_at != Vector3.ZERO and wall_at != Vector3.ZERO, "the first room has open floor and a wall to test through", "%s %s" % [clear_at, wall_at])

	var places := {1: centre, 2: clear_at, 3: wall_at, 4: centre + Vector3(0.5, 0, 0), 5: centre + Vector3(60, 0, 0)}
	router.position_fn = func(peer: int) -> Vector3: return places.get(peer, Vector3.ZERO)
	var heard := {}
	router.send_fn = func(peer: int, bytes: PackedByteArray) -> void:
		var parsed := DotVoicePacket.from_bytes(bytes)
		heard[peer] = parsed.value.gain if parsed.ok else -1.0

	for peer in places:
		router.add_peer(peer)

	var packet := DotVoicePacket.new()
	packet.speaker = 1
	packet.sample_count = format.frame_samples()
	packet.channel = DotVoiceRouter.Channel.PROXIMITY
	packet.codec_id = &"adpcm"
	packet.payload = DotVoiceCodec.instance_for(&"adpcm").encode(DotVoiceSourceBuffer.tone(300.0, 0.02, format.sample_rate, 0.4))
	var relayed := router.relay(1, packet.to_bytes())
	_check(relayed.ok, "a frame relays", str(relayed.error))

	var expected_clear := DotVoiceProximity.gain(centre.distance_to(clear_at), router.proximity_range, router.proximity_min_distance, router.proximity_falloff)
	var expected_wall := DotVoiceProximity.gain(centre.distance_to(wall_at), router.proximity_range, router.proximity_min_distance, router.proximity_falloff) * router.occlusion_gain
	_check(heard.has(4) and is_equal_approx(heard[4], 1.0), "a player 0.5 m away hears full volume", str(heard.get(4)))
	_check(heard.has(2) and absf(heard[2] - expected_clear) < 0.02 and heard[2] < 1.0, "a player in the open at distance hears the falloff's gain", "%.3f expected %.3f" % [heard.get(2, -1.0), expected_clear])
	_check(heard.has(3) and absf(heard[3] - expected_wall) < 0.02, "through a wall it is turned down by the occlusion gain", "%.3f expected %.3f" % [heard.get(3, -1.0), expected_wall])
	_check(heard.has(3) and heard.has(2) and expected_wall < expected_clear and not heard.has(5), "a wall is quieter than open floor, and past the radius nothing is sent")

	# Witches: a relayed frame is a sound for a moment, and the cvar's field turns it off.
	var p: LmPlayer = game.players[&"a"]
	p.voice_left = 0.0
	var quiet := game.noise_radius(p)
	game.hear_voice(&"a")
	var loud := game.noise_radius(p)
	_check(quiet == 0.0 and absf(loud - game.config.witch_hear_range) < 0.001, "a talker is heard by witches as far as a run", "%.1f then %.1f m" % [quiet, loud])
	game.config.witch_hear_voice = false
	p.voice_left = 0.0
	game.hear_voice(&"a")
	_check(game.noise_radius(p) == 0.0, "and not when the switch is off")
	game.config.witch_hear_voice = true
	p.voice_left = 0.0

	services.free()
	router.free()
	await get_tree().process_frame
	_finished_section()


## Sanity scares, demons and the look-behind whisper: the director's schedule against the meter,
## what a sighting starts, an approach, a stare, a turn; then the same drawn and heard by a client.
func _test_scares() -> void:
	_section("scares: sanity scares by the meter, demons after a sighting, approach, look behind")
	var config := LmConfig.new()
	_check(LmScares.interval_for(config, 0.0) > LmScares.interval_for(config, 0.5) and LmScares.interval_for(config, 0.5) > LmScares.interval_for(config, 1.0),
		"a sanity scare comes sooner as the meter climbs", "%.0f, %.0f, %.0f s" % [LmScares.interval_for(config, 0.0), LmScares.interval_for(config, 0.5), LmScares.interval_for(config, 1.0)])

	var calm := _scare_night(1, 0.0, 1800.0)
	var haunted := _scare_night(1, 0.9, 1800.0)
	var calm_scares := calm.filter(func(e: Dictionary) -> bool: return e["kind"] == LmScares.SCARE)
	var haunted_scares := haunted.filter(func(e: Dictionary) -> bool: return e["kind"] == LmScares.SCARE)
	_check(haunted_scares.size() >= calm_scares.size() * 3 and calm_scares.size() >= 1,
		"half an hour at a high meter has several times the scares of an empty one", "%d against %d" % [haunted_scares.size(), calm_scares.size()])
	_check(JSON.stringify(_scare_night(1, 0.9, 600.0)) == JSON.stringify(_scare_night(1, 0.9, 600.0)) and JSON.stringify(_scare_night(1, 0.9, 600.0)) != JSON.stringify(_scare_night(2, 0.9, 600.0)),
		"the same seed is the same night, another seed another")

	var gaps_ok := true
	var last := -1000.0
	for e: Dictionary in haunted:
		if e["kind"] == LmScares.SCARE:
			gaps_ok = gaps_ok and float(e["t"]) - last >= config.scare_cooldown - 0.01
			last = float(e["t"])
	_check(gaps_ok, "no two scares closer than the cooldown", "%.0f s" % config.scare_cooldown)

	var off := LmConfig.new()
	off.scares_enabled = false
	_check(_scare_night(1, 0.9, 600.0, off).filter(func(e: Dictionary) -> bool: return e["kind"] == LmScares.SCARE).is_empty(),
		"lm_scares_enabled off is no scares")
	await _scares_2(config)


func _scares_2(config: LmConfig) -> void:
	# Demons: none before a witch has seen you; after, one in the corner of the view.
	var dir := LmScares.new(LmConfig.new())
	var view := {"meter": 0.0, "level": 1, "eye": Vector3(0, 1.6, 0), "feet": Vector3.ZERO, "forward": Vector3.FORWARD, "caught": false}
	var shown_before := 0
	for i in 600:
		for e in dir.tick(0.5, view):
			if e["kind"] == LmScares.DEMON_SHOWS:
				shown_before += 1
	_check(shown_before == 0 and dir.demons.is_empty(), "no demon while no witch has seen you", str(shown_before))

	view["meter"] = 0.3
	var spawned: Dictionary = {}
	var whispered := false
	for i in 200:
		for e in dir.tick(0.25, view):
			if e["kind"] == LmScares.DEMON_SHOWS and spawned.is_empty():
				spawned = e
			whispered = whispered or e["kind"] == LmScares.WHISPER
		if not spawned.is_empty():
			break
	_check(not spawned.is_empty() and dir.sighted, "after a sighting a demon shows within its spawn window", "%.0f s" % (float(dir.told.size())))
	var at: Vector3 = spawned.get("at", Vector3.ZERO)
	var off_axis := rad_to_deg(Vector3.FORWARD.angle_to(Vector3(at.x, 0.0, at.z).normalized())) if not spawned.is_empty() else 0.0
	var away := Vector2(at.x, at.z).length()
	_check(off_axis >= config.demon_corner_min - 0.5 and off_axis <= config.demon_corner_max + 0.5 and away >= config.demon_distance_min - 0.01 and away <= config.demon_distance_max + 0.01,
		"in the corner of the view, at its distance", "%.0f degrees, %.1f m" % [off_axis, away])
	_check(whispered, "and it whispers from where it stands")

	# Approach: walk at it, it jumps, with a spike for the meter, and is gone.
	var spiked := 0.0
	var gone := false
	for i in 80:
		view["eye"] = (view["eye"] as Vector3).move_toward(Vector3(at.x, 1.6, at.z), 0.25)
		for e in dir.tick(0.1, view):
			if e["kind"] == LmScares.DEMON_JUMPS:
				spiked = float(e["spike"])
	gone = dir.demons.is_empty() or not dir.demons.any(func(d: Dictionary) -> bool: return int(d["id"]) == int(spawned["id"]))
	_check(absf(spiked - LmScares.demon_spike(config, 0.3)) < 0.001 and gone, "walking up to it makes it jump you, then it vanishes", "spike %.2f" % spiked)

	var sp := [LmScares.demon_spike(config, 0.0), LmScares.demon_spike(config, 0.5), LmScares.demon_spike(config, 1.0)]
	var lb := [LmScares.look_behind_spike(config, 0.0), LmScares.look_behind_spike(config, 0.5), LmScares.look_behind_spike(config, 1.0)]
	_check(absf(sp[0] - config.demon_spike_min) < 0.001 and absf(sp[2] - config.demon_spike_max) < 0.001 and sp[0] < sp[1] and sp[1] < sp[2]
		and absf(lb[0] - config.look_behind_spike_min) < 0.001 and absf(lb[2] - config.look_behind_spike_max) < 0.001 and lb[0] < lb[1] and lb[1] < lb[2],
		"demon and look-behind spikes rise with the meter, min at 0 and max at 1", "%.3f %.3f %.3f / %.3f %.3f %.3f" % [sp[0], sp[1], sp[2], lb[0], lb[1], lb[2]])

	# The server's side of the spike: it raises the meter, to the cap and no further, and not twice at once.
	game.config.scare_cooldown = 10.0
	var key := &"scare_test"
	var guest := game.join(key, "Scare")
	guest.meter = 0.2
	game.tick += 600
	_check(game.spook(key, 0.25) and absf(guest.meter - 0.45) < 0.001, "the house applies the spike to the meter", "%.2f" % guest.meter)
	_check(not game.spook(key, 0.25) and absf(guest.meter - 0.45) < 0.001, "and refuses a second inside the cooldown")
	game.tick += 600
	guest.meter = 0.8
	var _again := game.spook(key, 0.25)
	_check(guest.meter <= game.config.scare_meter_cap + 0.001 and guest.meter > 0.8 - 0.001, "and never past the cap, so a fright is never a catch", "%.2f" % guest.meter)
	game.leave(key)
	await _scares_3(view)


func _scares_3(view: Dictionary) -> void:
	# The clown: damage, chance and rate are curves over the meter; a lunge is once, at the trigger.
	var cc := LmConfig.new()
	var dmg := [LmScares.clown_damage(cc, 0.0), LmScares.clown_damage(cc, 0.5), LmScares.clown_damage(cc, 1.0)]
	var chance := [LmScares.clown_chance(cc, 0.0), LmScares.clown_chance(cc, 0.5), LmScares.clown_chance(cc, 1.0)]
	var wait := [LmScares.clown_wait(cc, 0.0), LmScares.clown_wait(cc, 0.5), LmScares.clown_wait(cc, 1.0)]
	_check(absf(dmg[0] - cc.clown_damage_min) < 0.001 and absf(dmg[2] - cc.clown_damage_max) < 0.001 and dmg[0] < dmg[1] and dmg[1] < dmg[2],
		"clown damage rises with the meter, min at 0 and max at 1", "%.3f, %.3f, %.3f" % dmg)
	_check(chance[0] < chance[1] and chance[1] < chance[2] and wait[0] > wait[1] and wait[1] > wait[2],
		"and its chance rises and its wait falls", "chance %.2f %.2f %.2f, wait %.0f %.0f %.0f s" % [chance[0], chance[1], chance[2], wait[0], wait[1], wait[2]])
	var shows: Array[int] = []
	for m in [0.0, 0.5, 1.0]:
		var n := 0
		for who in 12:
			for e in _scare_clown_night(who, m, 1800.0, cc):
				n += 1 if e["kind"] == LmScares.CLOWN_SHOWS else 0
		shows.append(n)
	_check(shows[0] < shows[1] and shows[1] < shows[2] and shows[0] >= 1, "twelve half-hours show the clown more often as the meter climbs", "%d, %d, %d" % [shows[0], shows[1], shows[2]])
	for m in [0.0, 0.5, 1.0]:
		var lunges: Array = _scare_clown_night(3, m, 3600.0, cc).filter(func(e: Dictionary) -> bool: return e["kind"] == LmScares.CLOWN_LUNGES)
		var ok := not lunges.is_empty()
		for e: Dictionary in lunges:
			ok = ok and absf(float(e["spike"]) - LmScares.clown_damage(cc, m)) < 0.001
		_check(ok, "each lunge at meter %.1f carries exactly its damage, once per clown" % m, "%d lunges, %.3f" % [lunges.size(), LmScares.clown_damage(cc, m)])
	var coff := LmConfig.new()
	coff.clown_enabled = false
	_check(_scare_clown_night(3, 1.0, 1800.0, coff).filter(func(e: Dictionary) -> bool: return str(e["kind"]).begins_with("clown")).is_empty(), "lm_clown_enabled off is no clown")
	game.config.scare_cooldown = 10.0
	game.config.scare_meter_cap = 0.85
	var victim := game.join(&"clown_test", "Clown")
	victim.meter = 0.5
	game.tick += 600
	_check(game.spook(&"clown_test", LmScares.clown_damage(game.config, 0.5)) and absf(victim.meter - (0.5 + LmScares.clown_damage(game.config, 0.5))) < 0.001,
		"the house applies the clown's whole damage (its cap includes the clown)", "%.3f" % victim.meter)
	game.leave(&"clown_test")

	# A stare sends it away, no jump.
	var stare := LmScares.new(LmConfig.new())
	view["eye"] = Vector3(0, 1.6, 0)
	view["meter"] = 0.4
	var target := {}
	for i in 400:
		for e in stare.tick(0.25, view):
			if e["kind"] == LmScares.DEMON_SHOWS and target.is_empty():
				target = e
		if not target.is_empty():
			break
	var look := (target["at"] as Vector3) - Vector3(0, 0, 0)
	view["forward"] = Vector3(look.x, 0.0, look.z).normalized()
	var seen_off := false
	var jumped := false
	for i in 60:
		for e in stare.tick(0.1, view):
			seen_off = seen_off or (e["kind"] == LmScares.DEMON_GONE and e["why"] == "seen")
			jumped = jumped or e["kind"] == LmScares.DEMON_JUMPS
	_check(seen_off and not jumped, "looking straight at it long enough sends it away without a jump")
	await _scares_4(view)


func _scares_4(view: Dictionary) -> void:
	# Look behind: the whisper, then turning round inside the window.
	var back_config := LmConfig.new()
	back_config.look_behind_min = 5.0
	back_config.look_behind_max = 6.0
	back_config.scares_enabled = false
	var turn := LmScares.new(back_config)
	view = {"meter": 0.0, "level": 1, "eye": Vector3(0, 1.6, 0), "feet": Vector3.ZERO, "forward": Vector3.FORWARD, "caught": false}
	var whisper_at := Vector3.INF
	for i in 200:
		for e in turn.tick(0.1, view):
			if e["kind"] == LmScares.BEHIND_WHISPER:
				whisper_at = e["at"]
		if whisper_at != Vector3.INF:
			break
	_check(whisper_at != Vector3.INF and whisper_at.z > 0.5, "a whisper \"look behind you\" comes from behind the player", str(whisper_at))
	view["forward"] = Vector3.BACK
	var scare_at := Vector3.INF
	var behind_spike := -1.0
	for i in 10:
		for e in turn.tick(0.1, view):
			if e["kind"] == LmScares.BEHIND_SCARE:
				scare_at = e["at"]
				behind_spike = float(e["spike"])
	_check(scare_at != Vector3.INF and scare_at.z > 1.0 and absf(behind_spike - LmScares.look_behind_spike(back_config, 0.0)) < 0.001,
		"turning round inside the window puts a scare where they look, behind where they were", str(scare_at))

	var slow := LmScares.new(back_config)
	view["forward"] = Vector3.FORWARD
	var whispers := 0
	var scares_seen := 0
	for i in 140:
		for e in slow.tick(0.1, view):
			whispers += 1 if e["kind"] == LmScares.BEHIND_WHISPER else 0
			scares_seen += 1 if e["kind"] == LmScares.BEHIND_SCARE else 0
	_check(whispers >= 1 and scares_seen == 0 and slow.behind.size() <= 3, "a player who never turns round is not scared by it", "%d whispers" % whispers)

	# Drawn and heard: a client with a sighting shows a demon and whispers; a jump flashes.
	var client: Node = (load("res://game/lm_client.gd") as GDScript).new()
	client.set("start_level", 3)
	add_child(client)
	for i in 6:
		await get_tree().process_frame
	var me: LmPlayer = client.get("player")
	var sink := client.get("audio").get("manager").get("sink") as DotAudioSinkNull
	var view_node: Node3D = client.get("scare_view")
	var director: LmScares = client.get("scares")
	director.config.demon_spawn_min = 1.0
	director.config.demon_spawn_max = 1.5
	director.config.demon_corner_min = 25.0
	director.config.look_behind_enabled = false
	director.config.scares_enabled = false
	me.meter = 0.3
	for i in 400:
		me.meter = 0.3
		await get_tree().process_frame
		if not director.demons.is_empty():
			break
	_check(not director.demons.is_empty() and view_node.find_child("Demon1", true, false) != null, "the client draws a demon once the meter says a witch saw it", str(view_node.describe()))
	_check(sink.count_of(&"whisper") >= 1, "and the whisper is heard", str(sink.count_of(&"whisper")))
	var jolts := sink.count_of(&"scare_hit")
	var meter_before := me.meter
	var demon: Dictionary = director.demons[0]
	var drawn_at: Vector3 = (view_node.get("_figures") as Dictionary)[int(demon["id"])].global_position if (view_node.get("_figures") as Dictionary).has(int(demon["id"])) else Vector3.INF
	_check(drawn_at.distance_to(demon["at"] as Vector3) < 0.01, "at the spot the director chose", str(drawn_at))
	me.global_position = demon["at"] as Vector3
	me.controller.state.position = demon["at"] as Vector3
	for i in 8:
		await get_tree().process_frame
	_check(sink.count_of(&"scare_hit") > jolts and me.meter > meter_before and director.demons.is_empty(),
		"walking into it: a sound, the meter up, the demon gone", "%d to %d, %.2f to %.2f" % [jolts, sink.count_of(&"scare_hit"), meter_before, me.meter])
	client.queue_free()
	_finished_section()


func _test_wheel_jumps() -> void:
	_section("the wheel jumps")
	var keys := LmBindings.make()
	_check(keys.row_for_setting(DotMenuBindings.WHEEL_JUMP_UP_SETTING).get("action", &"") == DotMenuBindings.JUMP_ACTION, "Wheel up is a row")
	_check(keys.row_for_setting(DotMenuBindings.WHEEL_JUMP_DOWN_SETTING).get("action", &"") == DotMenuBindings.JUMP_ACTION, "Wheel down is a row")
	var sampler := DotFpsSampler.new(DotFpsTunables.new())
	DotFpsSampler.register_default_actions(sampler)
	var tick := InputEventMouseButton.new()
	tick.button_index = MOUSE_BUTTON_WHEEL_UP
	tick.pressed = true
	InputMap.action_erase_events(DotMenuBindings.JUMP_ACTION)
	InputMap.action_add_event(DotMenuBindings.JUMP_ACTION, tick)
	sampler.handle_event(tick)
	var release := tick.duplicate() as InputEventMouseButton
	release.pressed = false
	sampler.handle_event(release)
	_check(sampler.sample(0.016).is_pressed(DotFpsCommand.BUTTON_JUMP), "a wheel tick gives the jump bit in the next sample")
	_check(not sampler.sample(0.016).is_pressed(DotFpsCommand.BUTTON_JUMP), "and not in the one after")
	_finished_section()


## dot-core's [DotCollisionAudit] over every level of both houses, built drawn as a client
## builds it: visible geometry nothing collides with is walked through. Strict.
func _test_collision_audit() -> void:
	_section("nothing drawn is walked through")

	for house_id: StringName in [&"house", &"asylum", &"forgotten"]:
		var _changed := game.change_house(house_id)
		var examined := 0
		var found := 0
		var failed_levels: Array = []

		for n: int in game.levels:
			var drawn := LmLevel.new()
			add_child(drawn)
			var _b := drawn.build((game.levels[n] as LmLevel).doc, true)
			var res := DotCollisionAudit.audit(drawn, true)

			if res.ok:
				var report: DotCollisionAudit = res.value
				examined += report.examined
				found += report.count()

				if report.count() > 0:
					failed_levels.append(n)
					print("  %s level %d: %d findings" % [house_id, n, report.count()])

					for line in report.describe_lines().slice(1, 8):
						print("    %s" % line)
			else:
				failed_levels.append(n)

			drawn.queue_free()

		print("  %s collision audit: %d findings in %d meshes" % [house_id, found, examined])
		_check(found == 0 and failed_levels.is_empty(), "%s: no drawn geometry without a shape" % house_id, str(failed_levels))

	var _back := game.change_house(&"house")
	_finished_section()
