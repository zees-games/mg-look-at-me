extends Node

## The first play test's cameras and bodies, in the real offline house: the third-person camera flown round every room and both sides of every door
## (dot-core's DotCameraCheck, armed), a walked player vs a held one under `mp_solidplayers` 1 and 0, and `mp_forceview` through the view key.
##   tools/camera_check.sh [--render]   # headless, exit 1 on failure; --render also writes frames to screenshots/cameras/

const LmClient := preload("res://game/lm_client.gd")
const LmGame := preload("res://game/lm_game.gd")
const LmPlayer := preload("res://game/lm_player.gd")

var _client: LmClient = null
var _render := false
var _failed := false


func _ready() -> void:
	_render = OS.get_cmdline_user_args().has("--render")
	_client = LmClient.new()
	_client.start_level = 1
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	for i in 10:
		await get_tree().physics_frame
	var game: LmGame = _client.game
	_fly(game)
	_views_rule(game)
	var other: LmPlayer = game.join(&"second", "Second")
	await get_tree().physics_frame
	var loose := await _walk(game, other, false)
	var solid := await _walk(game, other, true)
	_check(solid > 0.6 and solid < 1.0, "mp_solidplayers 1: walking into another player stops at them (closest %.2f m apart)" % solid)
	_check(loose < 0.3, "armed: mp_solidplayers 0, the same walk goes through them (closest %.2f m)" % loose)
	if _render:
		await _views(game, other)
	print("all passed" if not _failed else "FAILED")
	get_tree().quit(1 if _failed else 0)


func _fly(game: LmGame) -> void:
	var pivots: Array[Vector3] = []
	var space := _client.get_viewport().world_3d.direct_space_state
	for number in game.levels:
		var level = game.levels[number]
		for room in level.rooms:
			pivots.append(level.position + level.room_centre(room) + Vector3.UP * LmPlayer.EYE_HEIGHT)
		for id in level.doors:
			var door: Dictionary = level.doors[id]
			for side in [-1.2, 1.2]:
				pivots.append(level.position + (door["centre"] as Vector3) + (door["normal"] as Vector3) * side + Vector3.UP * LmPlayer.EYE_HEIGHT)
	var clear: Array[Vector3] = []
	for pivot in pivots:
		if not DotCameraProbe.is_inside(space, pivot, 0.3, LmGame.LAYER_WORLD):
			clear.append(pivot)
	var total := {}
	for pivot in clear:
		total = DotCameraCheck.add(total, DotCameraCheck.fly(_client.get_viewport().world_3d, DotCameraCheck.orbit_path(pivot), Vector3(0.0, 0.6, 3.2), LmGame.LAYER_WORLD))
	_check(DotCameraCheck.passed(total), "third person round %d places in the house: %s" % [clear.size(), DotCameraCheck.summary(total)])


func _views_rule(game: LmGame) -> void:
	_client.third_person = false
	game.view_rules.force_view = DotPlayerViewRules.ANY
	_client.third_person = game.view_rules.toggled(_client.third_person)
	_check(_client.third_person, "the view key goes to third person")
	game.view_rules.force_view = DotPlayerViewRules.FIRST_ONLY
	_client._place_camera()
	_check(not _client.third_person, "mp_forceview 1 puts the camera back on the eye")
	game.view_rules.force_view = DotPlayerViewRules.THIRD_ONLY
	_client._place_camera()
	_check(_client.third_person, "mp_forceview 2 holds third person")
	game.view_rules.force_view = DotPlayerViewRules.ANY
	_client.third_person = false


func _walk(game: LmGame, other: LmPlayer, solid: bool) -> float:
	game.body_rules.solid = solid
	var me: LmPlayer = _client.player
	var level = game.level_of(me)
	var centre: Vector3 = level.position + level.room_centre(level.spawn_room())
	var spot := centre + Vector3(0.0, 0.05, -1.3)
	var from := centre + Vector3(0.0, 0.05, 1.3)
	me.place_at(from, 0.0)
	await get_tree().physics_frame
	Input.action_press(&"dot_fps_forward")
	var closest := INF
	for i in 90:
		other.place_at(spot, 0.0)
		await get_tree().physics_frame
		var a := me.controller.state.position
		closest = minf(closest, Vector2(a.x - spot.x, a.z - spot.z).length())
	Input.action_release(&"dot_fps_forward")
	print("    %s: closest %.2f m" % ["solid" if solid else "pass-through", closest])
	game.body_rules.solid = true
	return closest


func _views(game: LmGame, other: LmPlayer) -> void:
	DirAccess.make_dir_recursive_absolute("screenshots/cameras")
	var me: LmPlayer = _client.player
	var level = game.level_of(me)
	var centre: Vector3 = level.position + level.room_centre(level.spawn_room())
	me.place_at(centre + Vector3(0, 0.05, 1.0), 0.0)
	other.place_at(centre + Vector3(30, 0.05, 30), 0.0)
	await _seconds(0.5)
	await _shot("lookatme_view_first")
	_client.third_person = true
	await _seconds(0.6)
	await _shot("lookatme_view_third")
	_client.third_person = false
	await _seconds(0.3)
	game.body_rules.solid = false
	var fade: DotCameraFade = _client._fade
	var figures: Callable = fade.bodies_fn
	fade.bodies_fn = Callable()
	await _held_at_lens(me, other, "lookatme_walk_in_before")
	fade.bodies_fn = figures
	await _held_at_lens(me, other, "lookatme_walk_in_after")
	game.body_rules.solid = true


func _held_at_lens(me: LmPlayer, other: LmPlayer, file: String) -> void:
	for i in 20:
		other.place_at(me.controller.state.position + Vector3(0, 0, -0.35), 180.0)
		await get_tree().process_frame
	await _shot(file)


func _shot(file: String) -> void:
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "screenshots/cameras/%s.png" % file
	var _saved := get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed = true


func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout
