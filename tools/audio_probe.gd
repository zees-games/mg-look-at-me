extends Node

## Under xvfb-run (never --headless, whose audio driver is Dummy): does the house make a noise?
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn
##
## Asks the engine's own players, not dot-audio's book-keeping: an id the manager accepted is
## not a sound unless a real player in its pool is playing a stream, and which file that stream
## came from says which sound it is. tools/playthrough.sh records the mix and measures it.

const LmClient := preload("res://game/lm_client.gd")
const LmPlayer := preload("res://game/lm_player.gd")


func _ready() -> void:
	var client := LmClient.new()
	client.start_level = 8
	add_child(client)
	await get_tree().physics_frame
	var me: LmPlayer = client.player
	var game = client.game
	var level = game.level_of(me)
	var heard := {}

	for i in 120:
		# Beside the first witch, behind her: her hum and her steps, and a high meter's heart.
		var pose: Dictionary = level.witch_pose(0, game.seconds_now(), game.config.witch_speed_scale, game.config.witch_head_sweep, game.config.witch_door_seconds)
		var facing := float(pose["facing"])
		var behind := Vector3(sin(facing), 0, cos(facing))
		me.place_at(level.position + (pose["at"] as Vector3) + behind * 0.5 + Vector3(0, 0.1, 0), 0.0)
		me.meter = 0.9
		await get_tree().process_frame

		if i == 60:
			var _clicked: bool = client.audio.click()

		for p in client.audio.manager.get_children():
			var stream: AudioStream = p.get(&"stream") if (p is AudioStreamPlayer or p is AudioStreamPlayer3D) else null
			if stream != null and bool(p.get(&"playing")):
				heard[stream.resource_path.get_file().get_basename().split("_")[0]] = true

	var sink := client.audio.manager.sink.sink_name() if client.audio.manager.sink != null else "none"
	# A looping sound plays a copy of its stream (dot-audio's rule), which has no path: the
	# ambience and the drones are asked of the manager by handle instead.
	if client.audio.manager.is_playing(int(client.audio.get(&"_ambience"))):
		heard["ambience"] = true
	if client.audio.droning() > 0:
		heard["witch_drone"] = true
	heard.erase("")
	var wanted := ["ambience", "heartbeat", "click", "step", "witch_drone"]
	var missing := wanted.filter(func(w: String) -> bool: return not heard.has(w))
	print("driver=%s sink=%s heard=%s missing=%s drones=%d" % [AudioServer.get_driver_name(), sink, heard.keys(), missing, client.audio.droning()])
	get_tree().quit(0 if missing.is_empty() else 1)
