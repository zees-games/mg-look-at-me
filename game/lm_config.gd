extends DotConfig

## Every rule a level is played under: the witches, the meter, the light, the penalties. The
## levels themselves are documents (`levels/`). Layered like every DotConfig in the family:
## exported defaults < JSON file < LM_* environment < --lm-* command line.
##
## [b]"Configurable down to the tee" was the brief[/b], so every number about being seen is
## here: how far a witch sees, how wide, how a flashlight or a crouch changes it, how fast the
## meter climbs and falls, and what being caught costs.

@export_group("Players")

@export_range(1.0, 15.0, 0.1) var run_speed: float = 4.6
@export_range(0.1, 1.0, 0.05) var walk_speed_scale: float = 0.5
@export_range(0.0, 3.0, 0.05) var jump_height: float = 0.9
@export_range(1.0, 40.0, 0.5) var gravity: float = 18.0

## Ground movement. Predicted by each client, so they are sent in the HELLO.
@export_range(0.5, 20.0, 0.5) var accelerate: float = 9.0
@export_range(0.0, 20.0, 0.5) var friction: float = 7.0

## Friction only bites below this speed; the classic 1.43 lets a body coast past a doorway.
@export_range(0.0, 10.0, 0.25) var stop_speed: float = 4.0
@export_range(0.1, 1.0, 0.05) var crouch_speed_scale: float = 0.45

## Whether a player may switch to third person.
@export var allow_third_person: bool = true

## Metres a player can reach to take an item, open a door or use something.
@export_range(0.5, 6.0, 0.1) var reach: float = 2.2

## Whether objectives are shared by everybody on a level (one key opens the door for all).
## Off by default, as the brief asks: everybody does every level themselves, which is what
## makes a server that never ends possible.
@export var shared_progress: bool = false

@export_group("The meter")

## How fast the caught meter fills, per second, for a player in full view at point-blank range.
@export_range(0.05, 5.0, 0.05) var exposure_rate: float = 0.9

## How fast it drains, per second, out of sight.
@export_range(0.01, 5.0, 0.01) var decay_rate: float = 0.05

## Seconds after being seen before it starts to drain. The meter was draining in about four
## seconds, which let a player stand in a witch's sight twice over; now it takes twenty.
@export_range(0.0, 10.0, 0.25) var decay_delay: float = 2.0

## A lit flashlight multiplies how fast you are seen, and how far.
@export_range(1.0, 5.0, 0.05) var flashlight_exposure: float = 1.8
@export_range(1.0, 3.0, 0.05) var flashlight_sight: float = 1.5

## Crouching multiplies how fast you are seen.
@export_range(0.05, 1.0, 0.05) var crouch_exposure: float = 0.55

## Standing still multiplies it too: a witch notices movement.
@export_range(0.05, 1.0, 0.05) var still_exposure: float = 0.6

@export_group("Being caught")

## What a catch costs: 0 back to the level's start room keeping what you hold, 1 back to the
## start with the level's progress lost.
@export_enum("keep", "reset") var caught_penalty: int = 1

## Seconds the screen is the witch's before the player is put back.
@export_range(0.0, 10.0, 0.25) var caught_seconds: float = 2.0

@export_group("Witches")

## Each witch's own numbers are the level document's; these scale every one, so an owner can
## make a whole server easier or harder without editing 32 files.
@export_range(0.1, 5.0, 0.05) var witch_speed_scale: float = 1.0
@export_range(0.1, 5.0, 0.05) var witch_sight_scale: float = 1.0
@export_range(0.1, 3.0, 0.05) var witch_cone_scale: float = 1.0

## Whether witches turn their heads as they walk, sweeping the cone.
@export var witch_head_sweep: bool = true

@export_group("Witches' senses")

## Metres a witch hears a player at a full run in the open; walking is quieter in proportion,
## crouching quieter again, standing still silent. A wall in the way costs `witch_hear_walls` of it.
@export_range(0.0, 40.0, 0.5) var witch_hear_range: float = 9.0
@export_range(0.0, 1.0, 0.05) var witch_hear_walls: float = 0.5

## A door opened or something used is this much louder than a run, for `witch_noise_seconds`.
@export_range(1.0, 5.0, 0.1) var witch_noise_boost: float = 1.4
@export_range(0.1, 3.0, 0.1) var witch_noise_seconds: float = 0.6

## A witch hears a player's voice (a packet the server relayed) as a sound that long after the
## last packet, as loud as a footstep run (`witch_hear_range`); walls still halve it. Off, a
## player may talk as they like. The cvar `lm_witch_hear_voice` flips it live.
@export var witch_hear_voice: bool = true
@export_range(0.05, 2.0, 0.05) var witch_voice_seconds: float = 0.35

## Metres a witch sees a lit flashlight at, inside her cone and with nothing between: the beam
## is seen from much further than a player is.
@export_range(0.0, 80.0, 0.5) var witch_light_range: float = 28.0

## Seconds from a sound or the light first being perceived to her starting to turn, and how
## fast her head turns after that, in degrees a second. A person takes about this long and
## turns about this fast; a witch that turned at once would never miss.
@export_range(0.0, 5.0, 0.05) var witch_reaction_seconds: float = 1.1
@export_range(10.0, 720.0, 5.0) var witch_turn_rate: float = 75.0

## Seconds she keeps looking where it came from after it stops, before her head goes back.
@export_range(0.0, 30.0, 0.5) var witch_alert_seconds: float = 4.0

## Listening. A witch that suspects somebody behind her (a faint sound, or a glimpse at the edge of
## her view for `witch_reaction_seconds`) stops dead for `witch_listen_seconds`, head tilted, and
## hears `witch_listen_hearing` times as far while she does. Hearing the player for
## `witch_listen_confirm` seconds in that window, she looks back (`witch_turn_delay`) and runs at the
## sound at `witch_chase_speed` times her walk for up to `witch_chase_seconds`; hearing nothing she
## walks on and will not stop to listen again for `witch_listen_cooldown`. A player standing
## still makes no sound, which is the whole of the answer.
@export var witch_listens: bool = true
@export_range(0.5, 10.0, 0.25) var witch_listen_seconds: float = 3.5
@export_range(1.0, 4.0, 0.1) var witch_listen_hearing: float = 1.8
@export_range(0.05, 2.0, 0.05) var witch_listen_confirm: float = 0.35
@export_range(0.0, 3.0, 0.05) var witch_turn_delay: float = 0.6
@export_range(1.0, 4.0, 0.1) var witch_chase_speed: float = 2.4
@export_range(1.0, 20.0, 0.5) var witch_chase_seconds: float = 6.0
@export_range(0.0, 60.0, 1.0) var witch_listen_cooldown: float = 10.0

## The first levels are gentler: she sees `opening_ease` as fast on level 1, rising to full speed
## by level `opening_levels` + 1. Out of the box a new player meets her at her least sharp.
@export_range(0.1, 1.0, 0.05) var opening_ease: float = 0.55
@export_range(1, 12, 1) var opening_levels: int = 4

## Seconds a witch stands at a closed door, opening it, before she walks through. 0 is the old
## walk, through the door as if it were not there.
@export_range(0.0, 10.0, 0.1) var witch_door_seconds: float = 1.6

## Metres from a doorway a player must be before a slam event may shut it (server only).
@export_range(0.5, 10.0, 0.5) var slam_clear: float = 3.0

## Seconds a stand-in player (tests, the soak) gives up on a goal it cannot reach.
@export_range(1.0, 120.0, 1.0) var bot_skip_seconds: float = 20.0

@export_group("House")

## The furniture the builder placed in each room (`lm_furniture_enabled`). Solid, so a server and
## its clients must agree; off, a house is bare rooms, as the first build had it.
@export var furniture_enabled: bool = true

@export_group("Scares")

## Sanity scares: a sudden sound and a brief face, flash or figure, the client's alone. How
## often one comes depends on the meter: `scare_interval_max` seconds apart at an empty meter,
## `scare_interval_min` at a full one (the meter is read live, so a fright mid-wait shortens it).
## Each wait is stretched or shrunk by 0.7 to 1.3 from the house's seed. Every one of these is
## an `lm_*` cvar of the same name (`lm_scare_interval_max`).
@export var scares_enabled: bool = true
@export_range(1.0, 600.0, 1.0) var scare_interval_max: float = 90.0
@export_range(1.0, 600.0, 1.0) var scare_interval_min: float = 14.0

## Seconds after any scare, jump or whisper-turned scare before the next may start.
@export_range(0.0, 120.0, 0.5) var scare_cooldown: float = 10.0

## How long a scare's figure and flash stay.
@export_range(0.1, 3.0, 0.05) var scare_seconds: float = 0.55

## What a demon's jump or a look-behind scare can push the meter to, and no further: a fright
## alone never catches anybody, a witch still has to.
@export_range(0.0, 1.0, 0.05) var scare_meter_cap: float = 0.85

@export_group("Demons")

## Once a witch has seen you (the meter has passed `demon_sight_meter` on this level) demons
## whisper and show in the corners of your view.
@export var demons_enabled: bool = true
@export_range(0.0, 1.0, 0.01) var demon_sight_meter: float = 0.05
@export_range(1, 6, 1) var demon_max: int = 2

## Seconds between one showing and the next, scaled down by the meter (at a full one, by half).
@export_range(1.0, 300.0, 1.0) var demon_spawn_min: float = 12.0
@export_range(1.0, 300.0, 1.0) var demon_spawn_max: float = 35.0

## Where one shows: this far from the eyes, this many degrees off the middle of the view (so
## the corner of it, not the middle).
@export_range(2.0, 20.0, 0.5) var demon_distance_min: float = 4.5
@export_range(2.0, 20.0, 0.5) var demon_distance_max: float = 8.0
@export_range(5.0, 80.0, 1.0) var demon_corner_min: float = 28.0
@export_range(5.0, 80.0, 1.0) var demon_corner_max: float = 48.0

## Walking this close to one makes it jump you.
@export_range(0.5, 6.0, 0.1) var demon_trigger_distance: float = 2.2

## Looking straight at one (within this many degrees) for this many seconds sends it away.
@export_range(1.0, 45.0, 1.0) var demon_look_degrees: float = 12.0
@export_range(0.2, 20.0, 0.1) var demon_look_seconds: float = 2.0

## It fades by itself after this long.
@export_range(2.0, 300.0, 1.0) var demon_lifetime: float = 30.0

## Seconds between one's whispers, from where it stands.
@export_range(0.5, 60.0, 0.5) var demon_whisper_gap: float = 6.0

## What its jump adds to the meter.
@export_range(0.0, 1.0, 0.01) var demon_meter_spike: float = 0.25

@export_group("Look behind you")

## A whisper from behind, "look behind you". Turn round (to within `look_behind_degrees` of
## straight back) inside `look_behind_window` seconds and something is there. The wait between
## whispers is `look_behind_min` to `look_behind_max`, shorter as the meter climbs.
@export var look_behind_enabled: bool = true
@export_range(5.0, 600.0, 1.0) var look_behind_min: float = 45.0
@export_range(5.0, 600.0, 1.0) var look_behind_max: float = 140.0
@export_range(0.5, 20.0, 0.1) var look_behind_window: float = 4.0
@export_range(10.0, 90.0, 1.0) var look_behind_degrees: float = 50.0
@export_range(0.0, 1.0, 0.01) var look_behind_spike: float = 0.1

@export_group("The world")

## How dark: the ambient light everywhere a lamp is not.
@export_range(0.0, 1.0, 0.01) var darkness_ambient: float = 0.05

## The flashlight's reach in metres, and its cone.
@export_range(2.0, 60.0, 0.5) var flashlight_range: float = 20.0
@export_range(5.0, 90.0, 1.0) var flashlight_angle: float = 36.0

## Where the built-in house's level documents are read from.
@export var level_directory: String = "levels"

## Where other houses are: every subdirectory with a house.json in it is one. An owner's own
## house is a directory of level documents dropped in here.
@export var houses_directory: String = "houses"

## The house a server opens with.
@export var house: String = "house"

## The file that says which houses this server ROTATES: `cfg/maps.yml` (dot-map's
## `DotMapRotationFile`: named rotations, `random` or `cycle`, wildcards, command names), looked
## for in the `--config` directory. Empty, or no such file, rotates every house. A house it
## leaves out stays installed (`lm_house` and the map menu load it); it is only never drawn,
## balloted or nominated. `sv_map_rotation_file`.
@export var map_rotation_file: String = "cfg/maps.yml"

## Minutes a house is played before the players vote on the next (the same house is on the
## ballot). 0 is no limit: the house changes only when players rock the vote.
@export_range(0.0, 600.0, 1.0) var house_minutes: float = 45.0

## Where who has won is kept, so a winner's mark survives a restart.
@export var winners_file: String = "user://lookatme_winners.json"

@export var seed_value: int = 0


## The scare tunables, by property name: each is an `lm_<name>` cvar and is sent to a joining
## client, whose director runs the same numbers.
func scare_keys() -> PackedStringArray:
	return PackedStringArray([
		"scares_enabled", "scare_interval_max", "scare_interval_min", "scare_cooldown", "scare_seconds", "scare_meter_cap",
		"demons_enabled", "demon_sight_meter", "demon_max", "demon_spawn_min", "demon_spawn_max", "demon_distance_min",
		"demon_distance_max", "demon_corner_min", "demon_corner_max", "demon_trigger_distance", "demon_look_degrees",
		"demon_look_seconds", "demon_lifetime", "demon_whisper_gap", "demon_meter_spike",
		"look_behind_enabled", "look_behind_min", "look_behind_max", "look_behind_window", "look_behind_degrees", "look_behind_spike",
	])


func env_prefix() -> String:
	return "LM_"


func cli_prefix() -> String:
	return "--lm-"


func validate() -> DotResult:
	if exposure_rate <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "exposure_rate must be above 0, or nobody is ever caught.")

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"meter": "+%.2f/s seen, -%.2f/s hidden after %.1f s" % [exposure_rate, decay_rate, decay_delay],
		"light": "flashlight x%.1f seen, x%.1f sight" % [flashlight_exposure, flashlight_sight],
		"caught": ["keep what you hold", "lose the level"][caught_penalty],
		"witches": "speed x%.2f, sight x%.2f" % [witch_speed_scale, witch_sight_scale],
		"senses": "hears %.1f m, sees a light at %.1f m, reacts in %.2f s, turns %.0f deg/s, opens doors in %.1f s" % [witch_hear_range, witch_light_range, witch_reaction_seconds, witch_turn_rate, witch_door_seconds],
		"scares": "%s, every %.0f to %.0f s by the meter, cooldown %.0f s" % ["on" if scares_enabled else "off", scare_interval_max, scare_interval_min, scare_cooldown],
		"demons": "%s, up to %d, jump at %.1f m for +%.2f" % ["on" if demons_enabled else "off", demon_max, demon_trigger_distance, demon_meter_spike],
		"look_behind": "%s, %.0f to %.0f s, %.1f s to turn" % ["on" if look_behind_enabled else "off", look_behind_min, look_behind_max, look_behind_window],
		"shared": shared_progress,
	}
