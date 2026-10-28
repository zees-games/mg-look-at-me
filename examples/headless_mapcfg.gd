extends DotGameCheckSuite

const LmMapConfig := preload("../game/lm_map_config.gd")

## A map with a file gets its values and the next map has the previous ones back.
## The file is written to the server tier into user://, so the check does not depend on what ships.

const CHECKS := 8


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("mg-look-at-me: per-map rules from cfg/game/mg-look-at-me/dot_map/map")
	if not ResourceLoader.exists("res://addons/dot_map/config/dot_map_config.gd"):
		print("SKIPPED: dot-map is not linked at addons/dot_map")
		get_tree().quit(0)
		return
	var console := DotConsole.new()
	add_child(console)
	console.cvar("lm_demon_max", "2", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("lm_scares_enabled", "1", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("lm_bots", "1", "", DotConVar.FLAG_ARCHIVE)
	var cfg := DotGameMapConfig.for_console(LmMapConfig.GAME_ID, console, LmMapConfig.KEYS)

	var dir := "res://cfg/server/game/%s/dot_map/map" % LmMapConfig.GAME_ID
	var real := ProjectSettings.globalize_path(dir)
	DirAccess.make_dir_recursive_absolute(real)
	var path := real.path_join("lm_testhouse.yml")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("lm_demon_max: 5\nlm_scares_enabled: 0\nlm_bots: 0\nlm_witch_hear_range: 99\n")
	f.close()

	var got := cfg.apply("lm_testhouse")
	_check(got.size() == 2, "the map's two whitelisted keys apply (%s)" % [got])
	_check(console.find_cvar("lm_demon_max").get_int() == 5, "lm_demon_max is 5 on that map")
	_check(console.find_cvar("lm_scares_enabled").get_int() == 0, "lm_scares_enabled is 0 on that map")
	_check(console.find_cvar("lm_bots").get_int() == 1, "a cvar outside the whitelist is untouched")

	cfg.apply("lm_other")
	_check(console.find_cvar("lm_demon_max").get_int() == 2, "the next map has lm_demon_max back")
	_check(console.find_cvar("lm_scares_enabled").get_int() == 1, "and lm_scares_enabled")
	_check(cfg.applied().is_empty(), "a map with no active values applies nothing")

	cfg.restore()
	DirAccess.remove_absolute(path)
	var up := real
	for _i in 5:
		DirAccess.remove_absolute(up)
		up = up.get_base_dir()
	_check(not FileAccess.file_exists(path), "the test file is removed")

	_report(CHECKS)
