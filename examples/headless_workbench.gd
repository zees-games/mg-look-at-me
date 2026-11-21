extends GSGameWorkbenchSuite

## mg-look-at-me: the workbench over the config binder, one edit per profile set, the export and its cfg round trip.
## Run: godot --headless --path . res://examples/headless_workbench.tscn

const LmConfig := preload("../game/lm_config.gd")


func _make_config() -> GSConfig:
	return LmConfig.new()


func _make_binder(config: GSConfig) -> GSGameConfigBinder:
	return LmConfig.make_binder(config)
