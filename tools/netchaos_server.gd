extends DotGameNetchaosServer

## Look At Me's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosServer): the house, the witches, the module; no bots.

var _scene: Node = null


func _boot_world() -> void:
	if not (await boot_server()).ok:
		return
	_scene = (load("res://scenes/lm_server.tscn") as PackedScene).instantiate()
	add_child(_scene)
	await get_tree().process_frame
	var loaded: DotResult = await server.modules.load_module("res://game/lm_module.gd")
	if not loaded.ok:
		printerr("netchaos server: ", loaded.error)
		return
	module = server.modules.get_module("lookatme")
	if solid != "":
		var cv: DotConVar = server.console.find_cvar("mp_solidplayers")
		if cv != null:
			cv.force_set(solid)


func _players() -> Array:
	return _scene.game.players.values() if _scene != null else []
