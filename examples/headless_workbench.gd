extends DotGameWorkbenchSuite

## mg-look-at-me: the workbench over the config binder, one edit per profile set, the export and its cfg round trip.
## Run: godot --headless --path . res://examples/headless_workbench.tscn

const LmConfig := preload("../game/lm_config.gd")


func _make_config() -> DotConfig:
	return LmConfig.new()


func _make_binder(config: DotConfig) -> DotGameConfigBinder:
	return LmConfig.make_binder(config)
