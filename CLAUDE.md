# mg-look-at-me

A dark house, thirty-two levels deep, with witches walking its rooms: a small horror game. Find what opens the next door before one of them looks at you.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and dot-player-controller's `CLAUDE.md` before touching movement. This file is only about what this game decides.

**Built 2026-10-06, in one session**: offline first (the house, the 32 levels, the witches, the meter, per-player doors, the commands, winning, a playable client), then networked the same day — a module, a bridge with predicted players, a mirroring client, chat and voice — and joined by a real client over a real socket in a delivered pack (dot-server-deploy's `examples/lookatme_client`, 17 checks). Not seen in a browser yet and not published. Remote set (`gamemann/mg-look-at-me`), nothing pushed.

## Layout

```
game/
  lm_config.gd   every rule (LM_*, --lm-*): the meter, what changes it, what a catch costs, the witches, the dark
  lm_level.gd    a level document built: rooms, walls cut for doors, doors (one StaticBody each), items, stations, lamps; witch_pose()
  lm_player.gd   a CharacterBody3D with dot-player-controller's first person, EXTERNAL drive; holds/opened/used/taken; the meter; the crown
  lm_game.gd     the house: every level side by side, join/leave, interact, exposure, caught, exits, /r and /l, winners
  lm_client.gd   one player: offline it owns the house, connected it predicts its own player; the dark, the flashlight, first/third person, witches with a sight fan, the HUD, a / command line
  lm_module.gd   the DotGameModule: predicted netcode, progress keyed by account uid, lm_status / lm_send / lm_winners, /commands in chat
  lm_services.gd chat (all, admin, whisper) and voice for everybody across the house
  lm_server.gd   what scenes/lm_server.tscn runs: the house, drawing nothing
  lm_vote.gd     the house vote over dot-vote: a time limit, rock the vote, applied at once
  lm_progress.gd dot-stats (levels, deepest, catches, wins) and four achievements, "Out" the brief's; reported to the backbone
  lm_settings.gd the player's settings and the screen Escape opens
  lm_audio.gd    the sounds as a dot-audio catalogue of audio/ files: ambience, creaks, steps, a witch's hum and steps, door, latch, stinger, shriek, heartbeat; a -1 dB limiter on master
  lm_witch.gd    a witch drawn: the kit's zombie recoloured, skirt, hat, glowing eyes, head turned with her sight, the floor fan; flares while she sees you
  net/           lm_events (JSON kinds), lm_event/lm_request, lm_net_link, lm_net_command (the move), lm_player_net (movement + level/flashlight/won, meter/caught to the owner), lm_net_bridge
  lm_figure.gd   a player drawn as one of the family's animated people (dot-player-char's DotHumanoidFigure; the avatar's blocky atlas letter picks the person; told floor, vertical speed, crouch)
  lm_avatars.gd, lm_paths.gd   mg-deathrun's, renamed (the avatar schema, mount paths)
levels/          The House: lm_01 .. lm_32 and house.json, written by tools/build_levels.py
houses/asylum/   The Asylum: asylum_01 .. asylum_16, the same builder
scenes/          lm_server.tscn
audio/          the sounds and their CREDITS.md (tools/make_sounds.py)
assets/witch/   her body and atlas (tools/make_witch.py)
examples/        headless_run (14 sections, 80 checks), headless_net (8, 28), dedicated (7, 25)
tools/           build_levels.py; make_sounds.py (--levels); make_witch.py; shot.sh/.gd (render: eyes, third, witch, above, prompt, door --near=m, --caught=1); playthrough.sh (xvfb: eight frames of level 1 and the recorded mix, measured); witch_shot (the witch from four sides); audio_probe (xvfb only: is there a sound); probe.gd
```

## How it is built

One line each; the reasoning is in [docs/design.md](docs/design.md) (Decisions 1 to 8, the HUD, the settings, the cameras) and [docs/horror.md](docs/horror.md) (the witch, the sound, the light, the signs).

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | Touching doors, witches, the meter, levels, netcode, houses, avatars, the HUD's prompt, settings or cameras |
| [docs/horror.md](docs/horror.md) | Touching the witch's model or behaviour, any sound, the light, the room signs or the HUD's layout |
| [docs/history.md](docs/history.md) | Believing a render or a suite: what each found that the other missed |

- **Doors are per player**: one solid body, opened by an exclusion in that player's controller; the opener's client swings its drawing open (`LmClient._swing_doors`). [design](docs/design.md#decision-1-doors-are-per-player-and-that-is-an-exclusion-list)
- **A witch's walk is a pure function of time** (`LmLevel.witch_pose`); never send her. Draw her at the interpolated time and animate her from her loop's speed, never a measured one. [design](docs/design.md#decision-2-a-witchs-walk-is-a-pure-function-of-time), [horror](docs/horror.md#the-witch)
- **Being seen is a meter**, out of her fan she cannot see you; the client asks `LmGame.exposure` for the local player only to draw and play it. [design](docs/design.md#decision-3-being-seen-is-a-meter)
- **Levels are generated and proven** by `tools/build_levels.py` (`--check`); a witch starts in a room with somewhere to walk. [design](docs/design.md#decision-4-levels-are-generated-and-proven)
- **Movement and doors are predicted**; progress goes to its owner alone. [design](docs/design.md#decision-5-movement-is-predicted-and-so-are-the-doors)
- **A house is a map**, voted between. [design](docs/design.md#decision-6-a-house-is-a-map-and-the-players-vote-between-them)
- **A TMC account is its site avatar.** [design](docs/design.md#decision-7-a-tmc-account-walks-the-house-as-its-site-avatar)
- **Sound is a dot-audio catalogue of files** (`audio/`, written by `tools/make_sounds.py`, every file at a -2 dBFS peak); loudness is each def's `gain_db`, measured in the recorded mix, with a -1 dB hard limiter on master. [horror](docs/horror.md#sound)
- **Every key is an `LmBindings` row** on the menu's Controls page; nothing is matched by keycode but Enter and Escape. [design](docs/design.md#settings-and-escape-opens-them)
- **The HUD wraps inside the window** (`LmClient.hud_fits`, checked at 640x360 to 1280x720). [horror](docs/horror.md#signs-and-the-hud)
- **A room's name is a plaque over each door into it**, in front of the wall's face (each room's wall is a whole `WALL` deep inside its edge). [horror](docs/horror.md#signs-and-the-hud)

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"; done
godot --headless --path . res://examples/headless_run.tscn   # 14 sections, 80 checks
godot --headless --path . res://examples/headless_net.tscn   # 8 sections, 28 checks: predicted, a lost input packet recovered from the copies, through a door open for one, a face that arrives late, the click
godot --headless --path . res://examples/dedicated.tscn      # 7 sections, 25 checks
tools/build_levels.py --check
tools/shot.sh; tools/shot.sh --view=witch --level=8; tools/shot.sh --view=third
tools/camera_check.sh [--render]   # third person round every room and door (armed), mp_forceview, mp_solidplayers both ways
xvfb-run -a godot --path . res://tools/audio_probe.tscn       # does the house make a noise
tools/playthrough.sh --sheet                                  # look at the eight frames; the mix must peak under -1 dBFS
xvfb-run -a godot --path . --resolution 1600x500 res://tools/witch_shot.tscn -- --seeing
```

## Still to do

In the order they are worth doing.

1. **A browser look**, then publishing: the pack is `tmc/lookatme` (dot-server-deploy `content/lookatme/`), and the release order is the family's.
2. **The GitHub repository** is the owner's to create.
