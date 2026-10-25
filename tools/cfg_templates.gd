extends SceneTree

## Rewrites cfg/game/mg-look-at-me/config_*/game.yml from LmConfig's fields: godot --headless --path . --script tools/cfg_templates.gd

const LmConfig := preload("../game/lm_config.gd")


func _init() -> void:
	var binder := LmConfig.make_binder(LmConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()
