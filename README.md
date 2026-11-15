This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, players make their way through a dark house, 32 levels deep, while witches walk its rooms. Find what opens the next door before one of them looks at you for too long.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

This game was built with Claude Code and has had little testing with real players, so please report anything odd you run into.

## How it plays
You arrive in the lobby, the one lit room in the house and the start of level 1. Every level is a set of rooms behind doors that don't open on their own:

- a coloured key for a coloured door;
- a bucket filled at a tap, to put out a fire in a doorway;
- a fuse for a dead fuse box, a crowbar for a boarded door, a screwdriver for a vent;
- a code from a note for a keypad, or a lever somewhere else that opens a gate.

The top left of the screen always says what to do next. The gold key opens the way out, and the way out is the next level.

**Everybody plays every level for themselves.** What you pick up, open and use is yours: a door you unlocked is open for you and still locked for the player behind you. So people can arrive and leave at any time.

**The witches** walk the same rounds through the rooms, over and over, and you hear them before you see them: a low hum and slow, heavy footsteps through the walls. Where a witch looks is drawn as a red fan on the floor, turning as her head turns. The rules are simple:

- **Out of her fan, she cannot see you**, however close you are. Behind her is safe; so is anywhere a wall or a piece of furniture is between you.
- **In her fan, the meter at the bottom fills**: faster the closer she is, much faster with your flashlight on, slower if you crouch or keep still. The moment she sees you, you hear it, her eyes blaze and her arms come up, and your heart starts to pound.
- **Get out of her fan and the meter drains** after a moment.
- **If it fills, she has you**, and you're back at the start of the level.

The start room of every level is safe: no witch ever walks into it. Level 1 has two witches, and each level adds one more for every three levels (12 on level 32). Later witches walk faster and see further.

Finish all 32 and you get a crown everybody else can see.

There are five **houses**. A server plays one at a time. After 45 minutes by default (`house_minutes`; 0 means only `!rtv` calls a vote) the players vote on the next. `!rtv` calls a vote at any time. A server holds 24 players by default (`max_players` in `game.yml`).

| House | Levels | What it is |
| --- | --- | --- |
| The House (`house`) | 32 | The main game, grown by `tools/build_levels.py` |
| The Asylum (`asylum`) | 20 | Cut from a converted asylum plan |
| Forgotten Wing (`forgotten`) | 1 | A 51-room level over a Workshop asylum's plan |
| The Pit (`ashpit`) | 1 | Converted from a community map |
| The Mall Deck (`mallparking`) | 1 | Converted from a community map |

## Controls

| Key | Action |
| --- | --- |
| **WASD** / mouse | Move and look |
| **Ctrl** | Crouch |
| **E** | Take, open, use |
| **F** | Flashlight |
| **F5** | First or third person, where the server allows it |
| **/** | A command: `/r` goes back to the lobby, `/l3` (or `/l 3`) goes to a level you have reached |
| **H** | Help: the rules and every key as you have it bound |
| **M** | The list of houses |
| **Tab** | Who is playing (hold) |
| **Esc** | Menu: settings (every key above can be rebound on the Controls page), help, and leave |

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/gamespice-platform/bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/gamespice-platform/bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/mg-look-at-me
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/`. `./game.sh shot --help` lists the views |
| `./game.sh help` | All of the options |

`online` and `server` use [dot-server-deploy](https://github.com/gamespice-platform/server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

## Running a server
Console commands:

| Command | |
| --- | --- |
| `lm_status` | What the server is doing |
| `lm_send <name> <level>` | Send a player to a level |
| `lm_winners` | Who has finished the house |
| `lm_house <id>` | Switch to another house (e.g. `lm_house asylum`) |

Everything else is a setting. Each is a key in the files under `cfg/game/mg-look-at-me/` (`config_meter`, `config_witches`, `config_players`, `config_world`, `config_scares`; every key is listed there with its default and range), and an `lm_<name>` console variable. A server operator overrides them in `cfg/server/game/mg-look-at-me/<folder>/game.yml`, in `user://cfg/lookatme.json`, with an `LM_*` environment variable or with an `--lm-*` argument (the later one wins). The main ones, with their defaults:

| Setting | Default | What it does |
| --- | --- | --- |
| `exposure_rate` | 0.9 | How fast the caught meter fills per second, in full view up close |
| `decay_rate`, `decay_delay` | 0.05, 2.0 | How fast it drains per second, and how many seconds out of sight before it starts |
| `flashlight_exposure`, `flashlight_sight` | 1.8, 1.5 | How much a lit flashlight speeds up being seen, and how much further |
| `crouch_exposure`, `still_exposure` | 0.55, 0.6 | How much crouching, or standing still, slows being seen |
| `caught_penalty` | 1 | 0 = back to the level's start keeping what you hold, 1 = back to the start and lose what you hold |
| `witch_speed_scale`, `witch_sight_scale`, `witch_cone_scale` | 1.0 | Scale every witch in the level files |
| `witch_hear_range` | 9.0 | Metres a witch hears a running player |
| `witch_light_range` | 28.0 | Metres a witch sees a lit flashlight |
| `witch_reaction_seconds` | 1.1 | How long she takes to react to a sound or light |
| `witch_turn_rate` | 75 | Degrees per second her head turns |
| `witch_alert_seconds` | 4.0 | How long she keeps looking after it stops |
| `shared_progress` | false | One player's key opens the door for everybody on that level |
| `allow_third_person` | true | Whether **F5** works |
| `house_minutes` | 45 | Minutes a house plays before the vote |

## Writing a level
A level is one JSON file in `levels/`. It describes:

- **rooms** on a grid (a room is `w` by `d` cells of `cell` metres);
- **doors** on the walls two rooms share (or, for the way out, on an outside wall);
- **items**, and **stations** you use an item on (`needs`, `gives`, `opens`);
- **steps**, the text the HUD shows, each done when you hold, open or use something;
- **witches**: a loop of room centres, doorways and points in rooms, a speed, a sight range and a cone.

The shipped levels are written by `tools/build_levels.py`. It grows each level's rooms as a tree, locks every new door behind a puzzle whose parts are already reachable, and refuses to write a level it can't finish.

A house is a folder of levels with a `house.json` (`{"kind": "house", "id": "mine", "name": "My House"}`), in `houses/` or `user://lookatme_houses/`.

## Testing

```bash
./game.sh test                  # every script parses, then every suite runs
./game.sh test headless_run     # one suite
tools/build_levels.py --check   # the shipped levels are what the builder writes
```

| Suite | What it covers |
| --- | --- |
| `headless_run` | The game itself: levels, doors, puzzles, the witches and the meter |
| `headless_net` | A server and a client in one process, over the network code |
| `dedicated` | A real server: boots, loads the game, runs its commands |

[`CLAUDE.md`](CLAUDE.md) has the design decisions and the reasoning behind them.

## Credits

| Asset | Author / source | License | Where |
| --- | --- | --- | --- |
| Players | Quaternius, [Zombie Apocalypse Kit](https://quaternius.com/packs/zombieapocalypsekit.html), skinned from Kenney's Blocky Characters | CC0 1.0 | dot-player-char |
| The witch | Quaternius basic zombie, recoloured and dressed in code (`tools/make_witch.py`) | CC0 1.0 | `assets/witch/` |
| Furniture | Kenney, [Furniture Kit](https://kenney.nl/assets/furniture-kit), placed by `tools/lm_furnish.py` | CC0 1.0 | `assets/kenney/CREDITS.md` |
| Footsteps, creaks, doors, latch | Kenney, Impact Sounds and RPG Audio | CC0 | `audio/CREDITS.md` |
| Flashlight click | Kenney, Interface Sounds | CC0 | `audio/CREDITS.md` |
| Ambience, witch's hum, stinger, shriek, heartbeat, scare sound, whispers | Synthesised for this game by `tools/make_sounds.py` | CC0 | `audio/CREDITS.md` |
| Clown hallucination | [Da-Clown #StylizedBustChallenge](https://sketchfab.com/3d-models/da-clown-stylizedbustchallenge-59bdbb3cc60748b995106b6020b25303) by Nwilly_art; eyes split off, jaw bone added | CC BY 4.0 | `assets/clown/`, `tools/make_clown.py` |
| Everything else | Drawn in code | none | in code |
| The Forgotten Wing (`houses/forgotten/`) | Laid out over the floor plan of [Forgotten Asylum](https://steamcommunity.com/sharedfiles/filedetails/?id=1682965311) by WhiteKnuckles. Only the plan was used; rebuilt by hand with this game's own art | none stated (no request against porting on 2026-10-20) | [docs/map-bases.md](docs/map-bases.md) |
| The Asylum (`houses/asylum/`) | Converted from the plan of [Blackbrook Asylum](https://steamcommunity.com/sharedfiles/filedetails/?id=903842886) by The Old Swashbuckler; rooms read automatically, then grown, cut into twenty levels and furnished by this game; no original textures, props, sounds or text | none stated (no request against porting on 2026-10-20) | [docs/converted-houses.md](docs/converted-houses.md) |
| The Pit (`houses/ashpit/`) | Converted the same way from [Ashpit](https://steamcommunity.com/sharedfiles/filedetails/?id=2902149974) by Redstone.Co; every texture is a CC0 replacement | none stated | `houses/*/world/*/CREDITS.md` |
| The Mall Deck (`houses/mallparking/`) | Converted the same way from the ground deck of [gm_mallparking](https://steamcommunity.com/sharedfiles/filedetails/?id=2619660952) by bean; every texture is a CC0 replacement | none stated | `houses/*/world/*/CREDITS.md` |

**Made one of these maps or assets and want it removed? Open an issue, or tell us, and it goes.**

## License
MIT. See [LICENSE](LICENSE). The Kenney and Quaternius art and sounds are CC0, which is public domain.
