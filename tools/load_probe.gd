extends SceneTree

const LmClient := preload("../game/lm_client.gd")

## Boots the solo client and prints, per rendered frame, what a player would see: whether house, player and camera exist, where the body is,
## and whether the load gate covers the screen (a body moving uncovered, or a meter or clock moving covered, is the glitch). Needs xvfb-run:
##   xvfb-run -a godot --path . --script tools/load_probe.gd -- --offline [--frames=90] [--shot=N]
var _client: Node = null
var _frame := 0
var _frames := 90
var _shot := -1
var _last := Vector3.ZERO
var _was_covered := true


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--frames="):
			_frames = int(a.get_slice("=", 1))
		if a.begins_with("--shot="):
			_shot = int(a.get_slice("=", 1))
	DirAccess.make_dir_recursive_absolute("res://screenshots")
	_client = LmClient.new()
	root.add_child(_client)


func _process(_delta: float) -> bool:
	_frame += 1
	var platform: Object = _client.get("platform")
	var gate: Object = platform.get("gate") if platform != null else null
	var covered: bool = gate != null and not gate.is_open()
	var player: Object = _client.get("player")
	var game: Object = _client.get("game")
	var pos: Vector3 = player.global_position if player != null else Vector3.ZERO
	var moved := pos.distance_to(_last)
	_last = pos
	print("frame %3d gate=%s covered=%s settling=%s tick=%s meter=%s player=%s pos=%s moved=%.3f" % [
		_frame, gate != null, covered, gate != null and gate.is_settling(),
		game.get("tick") if game != null else -1, player.get("meter") if player != null else -1,
		player != null, pos, moved])
	var lifted := _was_covered and not covered
	_was_covered = covered
	if _frame == _shot or (_shot < 0 and (_frame == 4 or lifted)):
		get_root().get_viewport().get_texture().get_image().save_png(
			ProjectSettings.globalize_path("res://screenshots/load_probe_%d.png" % _frame))
	if _frame >= _frames:
		quit(0)
	return false
