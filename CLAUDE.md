# mg-look-at-me

A dark house, thirty-two levels deep and up to three floors high, with witches walking its rooms: a small horror game. Find what opens the next door before one of them looks at you.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and dot-player-controller's `CLAUDE.md` before touching movement. This file is only about what this game decides.

**Built 2026-10-06, in one session**: offline first (the house, the 32 levels, the witches, the meter, per-player doors, the commands, winning, a playable client), then networked the same day — a module, a bridge with predicted players, a mirroring client, chat and voice — and joined by a real client over a real socket in a delivered pack (dot-server-deploy's `examples/lookatme_client`, 26 checks, a second client over a throttled WebSocket and a second tab of the same guest among them). Seen in headless Chromium against a local server (a fresh shell export): it joins, builds all 32 levels and then the Asylum on `lm_house asylum`, with no "Buffer payload full". Not published. Remote set (`gamemann/mg-look-at-me`), nothing pushed.

## Layout

```
game/
  lm_config.gd   every rule (LM_*, --lm-*): the meter, what changes it, what a catch costs, the witches, the dark
  lm_level.gd    a level document built: rooms on floors, walls cut per storey for doors, stairwells (ramp + landing), doors (one StaticBody each), items, stations, lamps per room, events; room_at/floor_at; witch_pose()
  lm_player.gd   a CharacterBody3D with dot-player-controller's first person, EXTERNAL drive; holds/opened/used/taken; the meter; the crown
  lm_game.gd     the house: every level in rows of eight, join/leave, interact, events (fire_events), exposure, caught, exits, /r and /l, winners
  lm_client.gd   one player: offline it owns the house, connected it predicts its own player; the dark, the flashlight (dot-flashlight), first/third person, witches with a sight fan, the HUD, a / command line
  lm_module.gd   the DotGameModule: predicted netcode, progress keyed by account uid, lm_status / lm_send / lm_winners, /commands in chat
  lm_services.gd chat (all, admin, whisper) and voice for everybody across the house
  lm_server.gd   what scenes/lm_server.tscn runs: the house, drawing nothing
  lm_vote.gd     the house vote over dot-vote: a time limit, rock the vote, applied at once
  lm_progress.gd dot-stats (levels, deepest, catches, wins) and four achievements, "Out" the brief's; reported to the backbone
  lm_settings.gd the player's settings and the screen Escape opens
  lm_audio.gd    the sounds as a dot-audio catalogue of audio/ files: ambience, creaks, steps, a witch's hum and steps, door, latch, stinger, shriek, heartbeat, slam, lights out; a -1 dB limiter on master
  lm_scares.gd   sanity scares, demons and the look-behind whisper decided as pure scheduling (lm_* cvars, seeded); lm_scare_view.gd draws and plays them; see docs/horror.md
  lm_surfaces.gd the wallpaper, floorboards and ceiling painted into mipmapped, tileable images (world-space triplanar, anisotropic); LM_FLAT=1 in the environment draws the old flat colours for a before/after (tools/shot.sh --view=range --dist=N)
  lm_witch.gd    a witch drawn: the kit's zombie recoloured, skirt, hat, glowing eyes, head turned with her sight, the floor fan; flares while she sees you
  net/           lm_events (JSON kinds), lm_event/lm_request, lm_net_link, lm_net_command (the move), lm_player_net (movement + level/flashlight/won, meter/caught to the owner), lm_net_bridge
  lm_figure.gd   a player drawn as one of the family's animated people (dot-player-char's DotHumanoidFigure; the avatar's blocky atlas letter picks the person; told floor, vertical speed, crouch)
  lm_bot.gd      a stand-in player (tests and the soak only): walks the puzzle with real movement and E; see docs/soak.md
  lm_avatars.gd, lm_paths.gd   mg-deathrun's, renamed (the avatar schema, mount paths)
levels/          The House: lm_01 .. lm_32 and house.json, written by tools/build_levels.py
houses/asylum/   The Asylum: asylum_01 .. asylum_18, the same builder
houses/forgotten/ The Forgotten Wing: one 51-room level laid over a Workshop map's plan (tools/layouts/forgotten.json, tools/bsp_layout.py, docs/map-bases.md)
scenes/          lm_server.tscn
audio/          the sounds and their CREDITS.md (tools/make_sounds.py)
assets/witch/   her body and atlas (tools/make_witch.py)
assets/clown/   the clown hallucination's model, CC-BY (CREDITS.md; tools/make_clown.py); game/lm_clown.gd draws it, LmScares schedules it (lm_clown_* cvars: chance, wait and damage are curves over the meter; so are the demon and look-behind spikes, lm_demon_spike_min/max, lm_look_behind_spike_min/max, lm_spike_curve); tools/shot.sh --view=clown|clownlunge
examples/        headless_run (23 sections, 187 checks), headless_net (9, 38), headless_lossy (5, 30), dedicated (12, 69), headless_workshop (1, 19), headless_config (1, 22)
tools/           build_levels.py (--check, --stats; furnishing and its proof in lm_furnish.py); make_sounds.py (--levels); make_witch.py; shot.sh/.gd (render: eyes, third, witch, glimpse, above = a labelled plan of one --floor, prompt, door --near=m, --caught=1); playthrough.sh (xvfb: eight frames of level 1 and the recorded mix, measured); witch_shot (the witch from four sides); audio_probe (xvfb only: is there a sound); probe.gd
```

## How it is built

One line each; the reasoning is in [docs/design.md](docs/design.md) (Decisions 1 to 8, the HUD, the settings, the cameras) and [docs/horror.md](docs/horror.md) (the witch, the sound, the light, the signs).

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | Touching doors, witches, the meter, levels, netcode, houses, avatars, the HUD's prompt, settings or cameras |
| [docs/levels.md](docs/levels.md) | Touching the builder, the level format, floors and stairwells, puzzles or events |
| [docs/horror.md](docs/horror.md) | Touching the witch's model or behaviour, any sound, the light, the room signs or the HUD's layout |
| [docs/history.md](docs/history.md) | Believing a render or a suite: what each found that the other missed |

- **Doors are per player**: one solid body, opened by an exclusion in that player's controller; the opener's client swings its drawing open (`LmClient._swing_doors`). [design](docs/design.md#decision-1-doors-are-per-player-and-that-is-an-exclusion-list)
- **A witch's walk is a pure function of time** (`LmLevel.witch_pose`); never send her. Draw her at the interpolated time and animate her from her loop's speed, never a measured one. [design](docs/design.md#decision-2-a-witchs-walk-is-a-pure-function-of-time), [horror](docs/horror.md#the-witch)
- **A witch listens before she hunts** (`LmGame._listen`, per player and witch: WALK, LISTEN, TURN, CHASE, BACK). A faint sound or a glimpse at the edge of her view for `witch_reaction_seconds` stops her clock (`gaze.stall`: her walk stays a function of time, only a time that did not pass), head cocked, hum cut, a low sting; her ears are `witch_listen_hearing` times sharper for `witch_listen_seconds`. Heard for `witch_listen_confirm` she looks back, then runs at the sound along a clear line and walks back to her path. A player standing still makes no sound. The first levels are gentler (`opening_ease`). Chasing is per-player server state like the head turn.
- **Quiet moods under the house**: `LmAudio.ambient` is dot-audio's `DotAmbienceDirector` (moods by house id, defaults in `game/lm_ambience.gd`, chosen in `LmClient._apply_mood` when a house opens); the old bed plays only when no mood loaded. `lm_ambient*` are bound by the module (REPLICATED, `lm_ambient_dir` local), followed by the client; the Ambience bus follows the Effects slider. `dedicated` checks a server change reaches a client's director.
- **The madness rests** on death, respawn and a level change (`LmClient.rest_sanity`: heartbeat, scare sounds, demons, a jump scare in progress, the dot-fx flash and shake).
- **Being seen is a meter**, out of her fan she cannot see you; the client asks `LmGame.exposure` for the local player only to draw and play it. [design](docs/design.md#decision-3-being-seen-is-a-meter)
- **Levels are generated and proven** by `tools/build_levels.py` (`--check`); a witch starts in a room with somewhere to walk. [design](docs/design.md#decision-4-levels-are-generated-and-proven)
- **A level is 14 + n rooms on a 4 m grid, on two floors from level 2 and three from level 16**; a stairwell is the only way up and is placed only with a room off its head; a room upstairs stands over rooms below. Three-floor levels grow a floor at a time (`grow_floors`); two-floor ones keep `grow()`'s order so their houses do not change. [levels](docs/levels.md#size)
- **Every placed thing goes through `LmLevel.floor_at` / `room_at` with a height**: a point at y 0 is the ground floor, not "the room". [levels](docs/levels.md#size)
- **Events fire once per go, per player** (`LmPlayer.fired`, in PROGRESS); lights and the glimpse are the client's to show, a slam is the server's and waits until the player is 3 m clear of the doorway. A slam only ever shuts a door that opens again. [levels](docs/levels.md#events)
- **The client draws only the player's level, with a 90 m far plane**: the compatibility renderer caps lights, and other levels' lamps pushed out the near ones. [history](docs/history.md)
- **Furniture is placed and proven by the builder, per room type** (`props` in the document, Kenney's Furniture Kit; `--check` proves it clear of doors, items, stations, witches' lanes and walkable). Rooms are 8 to 16 m. [levels](docs/levels.md#furniture)
- **A level document stays under 48,000 bytes compact** (one LEVEL message each; the builder refuses more). [levels](docs/levels.md#the-house-laid-out)
- **The house goes deflated and a window at a time** (`LEVEL_WINDOW`, acked by `Ask.LEVELS`), and everything else to that peer is held behind the last LEVEL: a browser drops what overflows its 64 KiB inbound buffer between frames. Never send a client a burst. [design](docs/design.md#the-house-on-the-wire)
- **A house is the biggest reliable burst in the family**, on the channel the commands and snapshots share; over ENet it needs dot-core's packet throttle setting, held by `headless_lossy`. [history](docs/history.md)
- **Voice is proximity** (`LmServices.configure_voice`: 14 m, full inside 2 m, a wall leaves 30%, all `sv_voice_*` cvars) and a witch hears a relayed voice frame as far as a run (`lm_witch_hear_voice`, `LmGame.hear_voice`). Look at a player: G gags, K mutes (`LmClient.voice_target`, a JOIN carries each player's `peer` because voice speakers are peer ids).
- **A READY before the player is seated is kept** (`_ready_unseated`) and answered by `add_player`: over ENet with loss it overtakes the link's `loaded`. [design](docs/design.md#the-house-on-the-wire)
- **One account, one player: the newest connection wins** (two tabs of a guest share a device id); the older is taken out and kicked with "You joined from another tab or window", never left on a link whose keys move nothing. [design](docs/design.md#one-account-one-connection)
- **Movement and doors are predicted**; progress goes to its owner alone. [design](docs/design.md#decision-5-movement-is-predicted-and-so-are-the-doors)
- **Workshop houses** (`provides.json`: `accepts.kinds` `["map"]`, `map_kinds` `["lookatme"]`): a pack's `map` entry has `map_kind: lookatme` and its `scene` is the pack's `house.json` with the house's level documents beside it; the document's `id` must equal the entry's and the directory must hold a level, or the entry is refused (logged, never listed). `LmGame.follow_content` reads `DotContentIndex.shared()` on every `house_rows()`, `listed_houses()` and `change_house()`, so the M menu, the vote and a change of house see a solo subscription as "Name [Pack]" and an online session none; the game's own ids win. The vote takes `listed_houses` through `entries_fn` and not dot-vote's `follow_content`, which cannot leave out a refused document. `examples/headless_workshop` (19 checks) holds it; `tools/shot.sh --view=mapmenu --workshop` renders the M menu.
- **A house is a map**, voted between. [design](docs/design.md#decision-6-a-house-is-a-map-and-the-players-vote-between-them)
- **A TMC account is its site avatar.** [design](docs/design.md#decision-7-a-tmc-account-walks-the-house-as-its-site-avatar)
- **Sound is a dot-audio catalogue of files** (`audio/`, written by `tools/make_sounds.py`, every file at a -2 dBFS peak); loudness is each def's `gain_db`, measured in the recorded mix, with a -1 dB hard limiter on master. [horror](docs/horror.md#sound)
- **Every key is an `LmBindings` row** on the menu's Controls page; nothing is matched by keycode but Enter and Escape. [design](docs/design.md#settings-and-escape-opens-them)
- **The platform is dot-game's `DotGameClient`** (`LmClient.platform`, added first in `_ready`): the loading cover (held until the player exists and the camera is current), the settings' menu, the console, the HUD's theme, Tab on `lm_scoreboard`, M, the pointer, and `input_blocked_changed`, which suspends every sampler (chat typing included). A suite that boots a client waits for the cover (`headless_run`'s `_shown`); `tools/shot.sh --view=cover` renders it. See dot-game's [client-migration.md](../dot-game/docs/client-migration.md).
- **A seat behind its client's loading cover cannot be caught** (dot-game's "still loading"): `LmGame.harm_gate`, set by the module from `can_peer_be_harmed`, is asked by `_watch` (the one place the meter rises from a witch) and `spook` (a reported fright); a catch in progress and the server's own commands are not affected, and offline or bot suites have no gate. There is no round, role draw or living count here. The bridge frees its link (a child of the server) on `_exit_tree`: a module loaded again otherwise left a second `@Node@` link and lost every RPC. `dedicated` holds both over a real socket; `tools/render_cover.sh` renders a real client's cover and the frame after it lifts (the stock cover is not replaced here, so none is orphaned).
- **Config goes through dot-game's `DotGameConfigBinder`** (`LmGame.config_binder`, prefix `lm`, made in `LmGame._ready`). Every `LmConfig` field is an `lm_<field>` cvar (`sv_map_rotation_file` stays hand-written and follows edits), a key in one of five `cfg/game/mg-look-at-me/config_<players|meter|witches|world|scares>/game.yml` files (`LmConfig.CFG_FILES` maps each `@export_group` to its file; every key is shipped commented out at its default by `addons/dot_game/qa/dot_game_cfg_templates.gd`, which `headless_config` holds in step; operator override under `cfg/server/game/...`), env/argv and a workbench "Game settings" set per file (the `lm_ambient*` cvars are a sixth, "Ambience"); unknown keys stop a dedicated or headless boot. Client-predicted numbers (run speed, gravity, jump, accelerate, friction, stop and crouch speed, flashlight, darkness, witch door and chase) travel in the HELLO's config; `EYE_HEIGHT` and the witch's body stay code. `DotGameWorkbench` is hosted by the module (F9 off a dedicated server; HTTP only with `workbench.enabled`; `server.admins` decides who may edit, plus dot-game's ticket login) and by the offline client. `headless_config` checks it.
- **Noblock**: `!block`, `!noblock`, `mp_teamblock` 0, `mp_enemyblock` 1 from `DotGameNoblock`. Everybody is one side (`LmGame.team_of_side`) and players are solid by default (`mp_solidplayers`), so out of the box players now walk through each other and `mp_teamblock 1` restores the old blocking. The client follows with `platform.add_noblock`. `dedicated` checks it.
- **The HUD wraps inside the window** (`LmClient.hud_fits`, checked at 640x360 to 1280x720). [horror](docs/horror.md#signs-and-the-hud)
- **A room's name is a plaque over each door into it**, in front of the wall's face (each room's wall is a whole `WALL` deep inside its edge). [horror](docs/horror.md#signs-and-the-hud)

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"; done
godot --headless --path . res://examples/headless_run.tscn   # 20 sections, 151 checks: the solver plays all 32 levels, events, stairs, the third floor
./game.sh soak [house] [minutes]                             # bot soak, docs/soak.md
godot --headless --path . res://examples/headless_net.tscn   # 9 sections, 38 checks: a READY before the seat, the house paced and deflated, predicted, a lost input packet recovered from the copies, through a door open for one, a face that arrives late, the click, one account on two connections
godot --headless --path . res://examples/headless_lossy.tscn # 5 sections, 30 checks: a client on ENet through dot-net's relay at 60 ms, walking while the house changes, 0% and 5% loss; -- --stock-throttle is the control
godot --headless --path . res://examples/dedicated.tscn      # 10 sections, 50 checks: cfg/maps.yml (rotation file), also a real ENet client behind its cover is not caught and is once it lifts, and a module loaded again leaves one net link
tools/build_levels.py --check
tools/shot.sh; tools/shot.sh --view=witch --level=8; tools/shot.sh --view=third
tools/shot.sh --view=above --level=8 --floor=1 --res=1400x1400   # a plan of one floor; look at it after any builder change
tools/shot.sh --view=glimpse --level=8 --seconds=0.6             # her at the end of a corridor
tools/camera_check.sh [--render]   # third person round every room and door (armed), mp_forceview, mp_solidplayers both ways
xvfb-run -a godot --path . res://tools/audio_probe.tscn       # does the house make a noise
tools/playthrough.sh --sheet                                  # look at the eight frames; the mix must peak under -1 dBFS
xvfb-run -a godot --path . --resolution 1600x500 res://tools/witch_shot.tscn -- --seeing
```

## Still to do

In the order they are worth doing.

1. **Publishing**: the pack is `tmc/lookatme` (dot-server-deploy `content/lookatme/`), and the release order is the family's.
2. **The GitHub repository** is the owner's to create.
