extends Node

## Under xvfb-run (never --headless, whose audio driver is Dummy): does the house make a noise?
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn
##
## Asks the engine's own players, not dot-audio's book-keeping: a heartbeat id the manager
## accepted is not a sound unless a real AudioStreamPlayer in its pool is playing a stream.

const LmClient := preload("res://game/lm_client.gd")


func _ready() -> void:
	var client := LmClient.new()
	client.start_level = 8
	add_child(client)
	await get_tree().physics_frame
	var heard_heart := false
	var heard_click := false

	for i in 120:
		await get_tree().process_frame
		client.player.meter = 0.9

		if i == 60:
			heard_click = client.audio.click()

		for p in client.audio.manager.get_children():
			if p is AudioStreamPlayer and (p as AudioStreamPlayer).playing and (p as AudioStreamPlayer).stream != null:
				var length := (p as AudioStreamPlayer).stream.get_length()
				# The heartbeat is 0.16 s, the click 0.06 s: told apart by length.
				heard_heart = heard_heart or length > 0.1

	var drones := 0
	for p in client.audio.manager.get_children():
		if p is AudioStreamPlayer3D and (p as AudioStreamPlayer3D).playing and (p as AudioStreamPlayer3D).stream != null:
			drones += 1

	var sink := client.audio.manager.sink.sink_name() if client.audio.manager.sink != null else "none"
	print("driver=%s sink=%s heartbeat=%s click=%s drones=%d of %d witches (%d near enough)" % [
		AudioServer.get_driver_name(), sink, heard_heart, heard_click, drones,
		client._witch_views.size(), client.audio.droning(),
	])
	get_tree().quit(0 if heard_heart and heard_click and drones > 0 else 1)
