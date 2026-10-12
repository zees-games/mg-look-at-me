# The horror

What makes the house frightening, and the rules each piece keeps. Christian's first play test (2026-10-11): "the witches should be really scary too and the atmosphere should be legitimately creepy and scary. Ambient sounds that are creepy and just eerie." The video showed no witch in 36 s, near silence, names hanging in mid-air and a clipped objective line.

## The rules a player reads

The game's rules did not change (Decisions 2 and 3 in [design.md](design.md)): a witch walks a fixed round, sees along a cone that turns with her head, and fills your meter while you are in it. What changed is that every part of that rule is now something you see or hear:

| Rule | Shown by |
| --- | --- |
| Where she is | her hum (`witch_drone`, heard from 18 m, through walls) and her slow steps (`witch_step`, 22 m), before she is in view |
| Where she looks | the fan on the floor, turning with her head, and her head itself turned by the same angle |
| She sees you now | the fan goes hard red, her eyes and the lamp in her face blaze, her arms come up (`attack_idle`), and a stinger plays once (`LmAudio.stinger`, 4 s cooldown) |
| How close you are to caught | the heartbeat (silent under 0.2, racing at the top), the red vignette, the bar |
| Caught | she is in your face with a shriek for 0.9 s (`LmClient._scare_at`), then the red screen and the start room |

The client asks `LmGame.exposure` for the local player only, from the same clock and the same physics the server uses, so what a player sees her do is what is filling the meter. Nothing about her is sent.

## The witch

`game/lm_witch.gd`. The Zombie Apocalypse Kit's basic zombie (Quaternius, CC0), copied from game-zombie-zone and recoloured grey and black by `tools/make_witch.py`; 2.2 m tall and drawn narrow; a black cone skirt from hips to floor wide enough to hide her stride, so she glides; a hat, lank hair and two glowing eyes on a `BoneAttachment3D` of her head. The family's people (dot-player-char) were tried first and drew a cheerful girl in a crop top.

- **Animated from her loop's speed, posed at the interpolated time.** Her pose only changes when the clock ticks; measured per frame, she stood still on every frame between ticks and flickered between her walk and her idle, and posed at the tick she stepped at the tick rate on any faster display.
- **The head turn is written right after the clip is advanced, every frame.** Written onto a pose the clip did not just write, it adds up.
- `tools/witch_shot.tscn` draws her from four sides (`--seeing` for the flare); look at it after any change to her.

## Sound

`game/lm_audio.gd`, files in `audio/` written by `tools/make_sounds.py` (numpy and SoX for the ambience, hum, stinger, shriek and heartbeat; Kenney's foley for the rest; `audio/CREDITS.md`).

- **Every file peaks at -2 dBFS.** A Vorbis file decodes up to a decibel over its source, so normalising to -1 came back at 0.
- **Loudness is the catalogue's `gain_db`**, set against the recorded mix, not file by file. The worst moment is a catch (shriek, stinger, racing heart at once); a -1 dB `AudioEffectHardLimiter` on the master bus (`LmAudio._limit_master`) keeps it off the rail whatever the sliders say.
- **Measured** with `tools/playthrough.sh`: a scripted minute of level 1 recorded off the master bus after the limiter. 2026-10-12: peak -2.3 dBFS, -17.7 LUFS integrated, 9.9 LU range. The first recording, before the gains were set, peaked at 0.0 dBFS.
- **The ambience and the creaks are the house's own** (`house_sounds`), a 40 s loop and a creak every 6 to 16 s somewhere 5 to 13 m away. A looping sound plays a copy of its stream, which has no path, so the probe asks the manager by handle.

## Light

Dark, but never so dark a player cannot step through a room: ambient 0.05, fog 0.05, filmic at 1.1, a little glow so lamps and eyes bloom, saturation down. The flashlight is a 36° spot with `spot_angle_attenuation` 0.55 (under 1 it falls away from a hot middle; at 1 and over it was the flat disc the play test saw), and a faint 3 m spill round the camera so the floor at your feet is there with the light off. The flashlight is still what a witch sees you by.

## Signs and the HUD

- **A room's name is a plaque over each door into it**, on the wall of the room you are in, small, gone beyond 11 m. It used to be a billboard in the middle of the room. The plaque sits a whole `WALL` in front of the room's edge: each room builds its own wall inside its edge, and a plaque half a wall out was inside the plaster.
- **Only a locked door says what it is** ("Red door", "The way out"), small, gone within 1.2 m and beyond 9 m.
- **An opened door swings open for whoever opened it** (`LmClient._swing_doors`): it is open for them only, and until this pass it still stood there shut while they walked through it.
- **The step, what you hold, the key line and the message wrap inside the window**; the meter sits above a key line that may take two lines. `headless_run` lays the HUD out at 1280x720, 800x600 and 640x360 with a long step and checks every piece is inside (`LmClient.hud_fits`).
