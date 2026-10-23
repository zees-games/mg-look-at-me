extends RefCounted

## Look At Me's per-house settings: the rules a house's file may change, through dot-game's [DotGameMapConfig].
##
## A house (the House, the Asylum, the Forgotten Wing) is this game's map, so `cfg/game/mg-look-at-me/dot_map/map/<house id>.yml` applies when it opens and the previous house's values come back. The game has no movement cvars, so the client mirrors nothing.

const GAME_ID := "mg-look-at-me"

## cvar -> its constraint. Only cvars the module registers; never a command or a path.
const KEYS := {
	"lm_witch_hear_voice": {"type": "bool"},
	"lm_scares_enabled": {"type": "bool"},
	"lm_scare_interval_min": {"type": "float", "min": 1.0, "max": 600.0},
	"lm_scare_interval_max": {"type": "float", "min": 1.0, "max": 600.0},
	"lm_scare_cooldown": {"type": "float", "min": 0.0, "max": 120.0},
	"lm_scare_meter_cap": {"type": "float", "min": 0.0, "max": 1.0},
	"lm_demons_enabled": {"type": "bool"},
	"lm_demon_max": {"type": "int", "min": 0, "max": 6},
	"lm_demon_spawn_min": {"type": "float", "min": 1.0, "max": 300.0},
	"lm_demon_spawn_max": {"type": "float", "min": 1.0, "max": 300.0},
	"lm_look_behind_enabled": {"type": "bool"},
	"lm_look_behind_min": {"type": "float", "min": 5.0, "max": 600.0},
	"lm_look_behind_max": {"type": "float", "min": 5.0, "max": 600.0},
}
