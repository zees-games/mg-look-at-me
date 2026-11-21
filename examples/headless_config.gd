extends GSGameCheckSuite

## LmConfig through GSGameConfigBinder: fields, cvars, strict refusal, the diff, a shipped yml loading back, and the workbench round trip.

const LmConfig := preload("../game/lm_config.gd")
const CHECKS := 31


func _ready() -> void:
	GSLog.set_level(GSLog.Level.FATAL)
	_run.call_deferred()


## One directory per suite process (the probe child is handed its parent's): user:// is shared by
## every copy of this project on a box, and two suites at once wrote and deleted each other's cfg files.
const ROOT_ARG := "--cfgroot="
var ROOT := _root()
const GAME := "mg-look-at-me"


func _root() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(ROOT_ARG):
			return a.substr(ROOT_ARG.length())
	return "user://lm_cfgtest_%d" % OS.get_process_id()


func _run() -> void:
	if OS.get_cmdline_user_args().has("--probe"):
		_probe()
		return
	print("mg-look-at-me: config binder")
	var config := LmConfig.new()
	var binder := LmConfig.make_binder(config)
	binder.strict = true
	_check(binder.load_layers().ok, "defaults load")
	_check(binder.diff().is_empty(), "no diff at the code defaults")
	var keys := PackedStringArray()
	for e: Dictionary in binder.schema():
		keys.append(e["key"])
	for k in ["run_speed", "gravity", "accelerate", "stop_speed", "exposure_rate", "witch_hear_range", "slam_clear",
			"bot_skip_seconds", "darkness_ambient", "flashlight_range", "scare_cooldown", "house_minutes"]:
		_check(keys.has(k), "%s is exposed" % k)

	var console := GSConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, GSConVar.FLAG_ARCHIVE, console.has_name)
	console.set_cvar("lm_witch_hear_range", "12.0")
	_check(is_equal_approx(config.witch_hear_range, 12.0) and binder.source_of("witch_hear_range") == "cvar", "a cvar writes the field")
	_check(binder.diff_yaml().contains("witch_hear_range: 12.0"), "the diff names the edit")
	var schema_path := ROOT + "_config_schema.json"
	_check(binder.write_schema(schema_path).ok and FileAccess.file_exists(schema_path), "write_schema writes the schema")
	DirAccess.remove_absolute(schema_path)

	var bad := FileAccess.open(ROOT + "_config_bad.json", FileAccess.WRITE)
	bad.store_string('{"no_such_field": 1}')
	bad.close()
	var strict := LmConfig.make_binder(LmConfig.new(), ROOT + "_config_bad.json")
	strict.strict = true
	_check(not strict.load_layers().ok, "strict: an unknown key is refused")
	DirAccess.remove_absolute(ROOT + "_config_bad.json")

	_layers()
	_templates(binder)

	var wb := GSGameWorkbench.new()
	wb.panel_mode = 1
	wb.config = {"enabled": false}
	for set: GSProfileSet in binder.profile_sets():
		wb.add_set(set, set.rel_path)
	add_child(wb)
	_check(wb.start().ok, "the workbench starts")
	binder.attach(wb.api.runtime)
	var listed := PackedStringArray()
	for kind: String in wb.api.kinds():
		var got: GSResult = wb.api.handle(GSGameWorkbench.LOCAL_ACTOR, {"op": "get", "kind": kind, "id": binder.profile_id})
		if got.ok:
			listed.append_array(PackedStringArray((got.value as Dictionary).get("values", {}).keys()))
	var missing := PackedStringArray()
	for k in keys:
		if not listed.has(k):
			missing.append(k)
	_check(missing.is_empty() and binder.profile_sets().size() == 5, "the workbench lists all %d keys over %d files" % [keys.size(), binder.profile_sets().size()], ",".join(missing))
	var res: GSResult = wb.api.handle(GSGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "config_witches", "id": binder.profile_id, "key": "witch_hear_range", "value": 9.5})
	_check(res.ok and is_equal_approx(config.witch_hear_range, 9.5), "a workbench edit reaches the live config")
	var files: Dictionary = wb.exporter.call("collect")
	var text: String = files.get("cfg/game/mg-look-at-me/config_witches/game.yml", "")
	_check(text.contains("witch_hear_range: 9.5"), "the export holds the edit in the cfg layout")

	wb.free()
	console.free()
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


## Child process: loads the layers strictly over the test root and prints what the live config holds.
func _probe() -> void:
	var config := LmConfig.new()
	var binder := LmConfig.make_binder(config)
	binder.strict = true
	binder.roots = PackedStringArray([ProjectSettings.globalize_path(ROOT)])
	var loaded := binder.load_layers()
	var console := GSConsole.new()
	add_child(console)
	binder.bind_cvars(console.cvar, GSConVar.FLAG_ARCHIVE, console.has_name)
	print("PROBE ok=%s exp=%s exp_src=%s hear=%s hear_src=%s cvar=%s scare=%s scare_src=%s dark=%s dark_src=%s" % [
		loaded.ok, config.exposure_rate, binder.source_of("exposure_rate"), config.witch_hear_range, binder.source_of("witch_hear_range"),
		console.find_cvar("lm_witch_hear_range").get_string(), config.scare_cooldown, binder.source_of("scare_cooldown"),
		config.darkness_ambient, binder.source_of("darkness_ambient")])
	get_tree().quit(0)


func _write(rel: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ROOT.path_join(rel).get_base_dir())
	var f := FileAccess.open(ROOT.path_join(rel), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _child() -> String:
	var out: Array = []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"res://examples/headless_config.tscn", "--", "--probe", ROOT_ARG + ROOT, "--lm-scare-cooldown=33.0", "--lm-darkness-ambient=0.2"], out, true)
	return "".join(PackedStringArray(out))


## A value set in a cfg file, the environment and argv each reaches the live config, and later layers win.
func _layers() -> void:
	_write("game/%s/config_meter/game.yml" % GAME, "exposure_rate: 0.9\n")
	_write("game/%s/config_witches/game.yml" % GAME, "witch_hear_range: 11.0\n")
	_write("game/%s/config_scares/game.yml" % GAME, "scare_cooldown: 77.0\n")
	OS.set_environment("LM_WITCH_HEAR_RANGE", "13.0")
	var text := _child()
	_check(text.contains("PROBE ok=true"), "the layers load strictly in a fresh process", text.right(300))
	_check(text.contains("exp=0.9") and text.contains("exp_src=yml"), "a cfg file reaches the live config (config_meter)")
	_check(text.contains(" hear=13") and text.contains("hear_src=env") and text.contains("cvar=13"), "the environment beats the file and reaches the cvar")
	_check(text.contains("scare=33") and text.contains("scare_src=argv"), "argv beats the file")
	_check(text.contains("dark=0.2") and text.contains("dark_src=argv"), "argv alone reaches the config")
	OS.unset_environment("LM_WITCH_HEAR_RANGE")
	_write("game/%s/config_meter/game.yml" % GAME, "witch_hear_range: 11.0\n")
	_check(_child().contains("PROBE ok=false"), "strict: a key in the wrong file is refused")
	var removed := GSPaths.remove_tree(ProjectSettings.globalize_path(ROOT))
	_check(removed.ok and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(ROOT)), "the per-process cfg fixture directory is removed", ROOT if removed.ok else str(removed.error))


## The shipped cfg files hold every key, in step with LmConfig, and change nothing as they are.
func _templates(binder: GSGameConfigBinder) -> void:
	var files := binder.template_files()
	_check(files.size() == 5, "five shipped cfg files", str(files.size()))
	var stale := PackedStringArray()
	for path: String in files:
		if not FileAccess.file_exists("res://" + path) or FileAccess.get_file_as_string("res://" + path) != files[path]:
			stale.append(path)
	_check(stale.is_empty(), "the shipped files match the config (run addons/dot_game/qa/dot_game_cfg_templates.gd)", ",".join(stale))
