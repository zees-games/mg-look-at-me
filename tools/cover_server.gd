extends DotCoverServer

## A headless dedicated world for tools/render_cover.gd to join: the boot examples/dedicated.gd does, left running.
##   godot --headless --path . res://tools/cover_server.tscn -- --port 27499

var scene: Node = null


func _default_port() -> int:
	return 27499


func _max_players() -> int:
	return 16


func _boot(_dir: String) -> void:
	scene = (load("res://scenes/lm_server.tscn") as PackedScene).instantiate()
	add_child(scene)
	await get_tree().process_frame

	var loaded: DotResult = await server.modules.load_module("res://game/lm_module.gd")
	print("cover_server: module loaded=%s port=%d" % [loaded.ok, port])
