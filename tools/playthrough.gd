extends Node

## A minute of level 1, played by a script under xvfb, seen and heard: a frame at each beat and
## the whole mix recorded off the master bus, so both can be looked at and measured.
##
##   tools/playthrough.sh          # screenshots/play_*.png, screenshots/play.wav, and the levels
##
## The beats: the lobby; the doorway to the Workshop and its plaque; the Workshop door opened;
## the witch walking the rooms the red key is in, seen from the side, out of her sight; in her
## sight (the stinger, her flare); a second later (the heartbeat, the meter); caught (her face,
## the shriek); back in the lobby with the flashlight off.

const LmClient := preload("res://game/lm_client.gd")
const LmGame := preload("res://game/lm_game.gd")
const LmPlayer := preload("res://game/lm_player.gd")
const LmLevel := preload("res://game/lm_level.gd")

var _out := "res://screenshots"
var _client: Node3D = null
var _recorder: AudioEffectRecord = null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)

	_client = LmClient.new()
	add_child(_client)
	await get_tree().physics_frame

	# After the client, so the recording is taken after its limiter: what a speaker gets.
	_recorder = AudioEffectRecord.new()
	AudioServer.add_bus_effect(0, _recorder)
	_recorder.set_recording_active(true)
	var game: LmGame = _client.get("game")
	var me: LmPlayer = _client.get("player")
	var level := game.level_of(me)
	var lobby := level.spawn_room()
	game.set_flashlight(me.player_key, true)

	# 1. The lobby, looking toward the Workshop's door.
	var d0: Dictionary = level.doors["d0"]
	var into: Vector3 = d0["normal"]
	var door_at: Vector3 = level.position + (d0["centre"] as Vector3)
	_stand(me, door_at - into * 7.0, door_at)
	await _beat("1_lobby", 2.0)

	# 2. At its doorway: the plaque over it names the room it leads into.
	_stand(me, door_at - into * 3.2, door_at + Vector3(0, 2.4, 0))
	await _beat("2_plaque", 1.0)

	# 3. Opened (as E would), the door heard.
	me.opened["d0"] = true
	game._apply_doors(me)
	me.opened["d1"] = true
	game._apply_doors(me)
	_stand(me, door_at - into * 1.5, door_at + into * 4.0)
	await _beat("3_opened", 1.5)

	# 4. The witch, seen from across a room and out of her sight: her walk, her hum, her steps.
	# From the middle of whichever of her two rooms she is not in, waiting for a moment she
	# is in view, within 12 m, and not looking this way.
	var seconds := game.seconds_now()
	var pose := {}
	var her := Vector3.ZERO
	for i in 600:
		seconds = game.seconds_now()
		pose = level.witch_pose(0, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep)
		her = level.position + (pose["at"] as Vector3)
		var hers := level.room_at(pose["at"])
		var mine := "r1" if hers == "r2" else "r2"
		var spot := level.position + level.room_centre(mine)
		_stand(me, spot, her + Vector3(0, 1.4, 0))
		await get_tree().physics_frame
		if spot.distance_to(her) < 12.0 and spot.distance_to(her) > 5.0 and game.exposure(me, level, 0, game.seconds_now()) == 0.0 and hers != "":
			break
	await _beat("4_witch_walking", 0.2)
	var facing := 0.0
	# 5. In her sight, 3 m in front of her: the stinger, her eyes flare, she reaches.
	for i in 90:
		seconds = game.seconds_now()
		pose = level.witch_pose(0, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep)
		facing = float(pose["facing"]) + float(pose["head"])
		var ahead := Vector3(-sin(facing), 0, -cos(facing))
		her = level.position + (pose["at"] as Vector3)
		# Only where 3 m in front of her is the room she is in: never inside a wall.
		if level.room_at((pose["at"] as Vector3) + ahead * 3.0) == level.room_at(pose["at"]):
			_stand(me, her + ahead * 3.0, her + Vector3(0, 1.6, 0))
		me.meter = minf(me.meter, 0.3)
		await get_tree().physics_frame
	await _beat("5_seen", 0.1)

	# 6. Still in it: the meter fills and the heart races.
	for i in 45:
		seconds = game.seconds_now()
		pose = level.witch_pose(0, seconds, game.config.witch_speed_scale, game.config.witch_head_sweep)
		facing = float(pose["facing"]) + float(pose["head"])
		var ahead := Vector3(-sin(facing), 0, -cos(facing))
		her = level.position + (pose["at"] as Vector3)
		# Only where 3 m in front of her is the room she is in: never inside a wall.
		if level.room_at((pose["at"] as Vector3) + ahead * 3.0) == level.room_at(pose["at"]):
			_stand(me, her + ahead * 3.0, her + Vector3(0, 1.6, 0))
		me.meter = minf(me.meter, 0.85)
		await get_tree().physics_frame
	await _beat("6_heartbeat", 0.1)

	# 7. Caught: her face in yours, a shriek.
	me.meter = 1.0
	me.caught_left = 2.0
	game.caught.emit(me.player_key)
	await get_tree().create_timer(0.3).timeout
	await _beat("7_caught", 0.0)
	await get_tree().create_timer(2.0).timeout

	# 8. Back in the lobby, the flashlight off: dark, and still readable.
	game.set_flashlight(me.player_key, false)
	_stand(me, level.position + level.room_centre(lobby) + Vector3(0, 0.1, 0), door_at)
	await _beat("8_dark", 2.0)

	_recorder.set_recording_active(false)
	var wav := _recorder.get_recording()
	var path := ProjectSettings.globalize_path("%s/play.wav" % _out)
	var saved := wav.save_to_wav(path) if wav != null else ERR_UNAVAILABLE
	print("recorded %s (%s), %.1f s, driver %s" % [path, error_string(saved), float(wav.data.size()) / float(wav.mix_rate * 4) if wav != null else 0.0, AudioServer.get_driver_name()])
	get_tree().quit(0 if saved == OK else 1)


## The player at [param from], looking at [param at].
func _stand(me: LmPlayer, from: Vector3, at: Vector3) -> void:
	var eye := from + Vector3(0, me.EYE_HEIGHT, 0)
	var to := at - eye
	me.place_at(Vector3(from.x, from.y + 0.1, from.z), rad_to_deg(atan2(-to.x, -to.z)))
	me.controller.state.pitch = rad_to_deg(asin(clampf(to.normalized().y, -1.0, 1.0)))


## Waits [param seconds], then saves the frame as play_[param name].png.
func _beat(name: String, seconds: float) -> void:
	if seconds > 0.0:
		await get_tree().create_timer(seconds).timeout
	for _i in 2:
		await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("%s/play_%s.png" % [_out, name])
	var _saved := get_viewport().get_texture().get_image().save_png(path)
	print("frame %s" % path)
