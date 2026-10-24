# Levels

How a level is grown, what is in it, and what the house does to you on the way. `tools/build_levels.py` writes every level of every house; `game/lm_level.gd` builds one; `game/lm_game.gd` plays it. Christian's ask that shaped it: "The maps definitely need to be bigger and longer with more to do though."

## Size

A level is rooms on a grid of 4 m cells (`cell` in the document). Level n has at least 14 + n rooms (15 on level 1, 49 on level 32 counting its stairwells; the Asylum's 18 levels go to 32), about three times the floor area of the first build (level 1 from 960 m² to about 1,900; level 32 from 2,300 to about 5,200, after the rooms were cut to 8 to 16 m). `tools/build_levels.py --stats` prints every level's rooms, area, floors, doors, steps, events and size.

Three shapes of room:

| Kind | Size | What it is for |
| --- | --- | --- |
| `room` | 8 to 16 m a side (8 to 12 upstairs too; they were 12 to 20 m until the full game review found them too big) | furnished by its name; where the parts of puzzles are |
| `corridor` | 4 m wide, 12 to 24 m long | the way between rooms, bare (furniture down both walls of a 4 m passage leaves no passage); where she is seen at a distance |
| `stair` | 8 by 16 m, two storeys | the only way between floors: a 4 m landing at its foot, an 8 m ramp (25°, the controller walks up to 46°), a 4 m landing at its head, level with the floor above, solid underneath |

The lobby (level 1's start room, 20 by 16 m) is still the biggest room in the game, and level 1 is one floor, to learn the house on. Levels 16 and up (and the Asylum's 16 to 18) have a third floor, of three to five rooms, up a stairwell from the first floor. Every level from 2 has an upstairs: a stairwell's foot opens off a room, and a room upstairs only stands over rooms below it (a stairwell mostly climbs alongside the wall it is entered through, so its head is beside the house; one that climbed away from it led nowhere, because nothing could stand there). A stairwell is placed only with a room off its head, or not at all.

**A third floor is grown a floor at a time** (`grow_floors`). A stairwell up from the first floor needs ground under all eight of its cells as well as two free storeys over them, beside the first-floor room it is entered from. Grown the two-floor way (a third of the house upstairs, stairwells tried at random throughout), the first floor had covered nearly all the ground by the time one was tried, and almost none fitted, so the third floor was dropped. Now each floor is finished before the next is started, the first floor is a quarter of the house (leaving ground uncovered round its edges), and a stairwell to floor f is tried from a room on f-1 or from the head of a stairwell up to f-1, where it runs back alongside the first over the room that one was entered from (a stair tower). A level whose top floor has fewer than three rooms is grown again. Two-floor levels keep the old order, so their houses are what they were.

Floors are a storey apart (`storey`, 3.7 m: a room's 3.2 m, its ceiling slab and the next floor's slab, one over the other; two boxes in one place flicker). Walls are built a storey at a time, each cut for the doors on that storey. `LmLevel.room_at` takes a height: each room owns from 0.9 m under its floor to 0.9 m under the floor above its top, so two floors never both claim a point. `LmLevel.floor_at` is the floor under a point, the ramp included, and everything placed in a level (items, stations, witches' points, spawn points) is placed on it.

## Furniture

Each `room` is furnished by its name (`tools/lm_furnish.py`: bedroom, nursery, kitchen, pantry, dining, bath, laundry, ward, cell, library, study, sitting, garden, hall, chapel, workshop, else a store), with Kenney's CC0 Furniture Kit. The builder writes it into the document: `prop_scale`, `models` (each model's final size in metres, read from its glTF) and `props` (`[model, room, x, z, rot]`, the centre in metres from the room's corner, rotation 0/90/180/270, plus a height for something standing on another piece, drawn only). `LmLevel._place_props` builds a box body per piece from the document's size and draws the model (loaded through `LmPaths.rebase`, so it survives pack delivery). A document without `props` (an owner's older house) keeps the old hash placement.

`tools/build_levels.py` refuses a level, and `--check` fails, unless every room's furniture is inside its walls, overlaps nothing, stays out of every doorway (2.6 by 2 m), every item and station (0.8 m round) and every line a witch walks through the room, and leaves a floor that still joins every door, item and station with 0.45 m kept off each piece (`prove`). A level that cannot be furnished to that is left with fewer pieces, never with a blocked door. `lm_furniture_enabled` (0) builds bare rooms; it is solid, so server and clients must agree. A level with furniture is about 60% bigger as a document (level 32 about 37 KB, still under the 48,000 limit).

## Doors

A door says where it is: `at` (a point on the edge of room `a`, in cells) and `floor`. `LmLevel._place_door_at` refuses one that is not on a's edge, not across from b, or not on a floor both rooms reach. A format 1 document's doors have no `at` and sit in the middle of the wall their rooms share, on the ground floor, as before, so an owner's own house from before still loads.

The way out is on the ground floor, on the outside wall of the deepest room (most doors from the start), opened by the gold key.

## Puzzles

Every door into a new room is open (about half: rooms 45%, corridors 65%, stairwells 50%) or locked behind a puzzle whose parts are in rooms already reachable, so the level is finishable by construction; `solve()` plays the logic and the builder grows the level again (the seed walks on, the same on every machine) until it passes and fits. The kinds: a coloured key (eight colours, each one door's; past eight it is another kind of lock, because a second "black key" for a second "black door" reads as a mistake), a crowbar, a keypad code on a note, a lever, a fuse for a fuse box, a bucket filled at a tap to put out a fire, a screwdriver for a vent with a key behind it. From level 3 any part may be locked in a chest whose small key is somewhere else (a third of the time): the chest names what is in it (`gives_name`), so "you need the red key" still says which.

A step is done once it has ever been true: `LmGame._done` counts an item held, taken, or given by a station already used, so fitting the fuse or pouring the water does not send the step line back to "Find a fuse".

## Events

What the house does to you on the way, in the document's `events`: `{id, when, do, ...}`, where `when` is a step's condition (`holds`, `opened`, `used`) or `entered` (a room). `LmGame.fire_events` runs every tick and after every E; each event fires once per player per go at the level (`LmPlayer.fired`, sent to the owner in PROGRESS like the rest of their progress, cleared with the level).

| `do` | When | What happens |
| --- | --- | --- |
| `lights` | you take the thing that was in a lit room (the builder lights the room for it) | the room's lamps stutter for 1.25 s with a buzz (`lights_out`) and go out, bulbs and all, until the next go at the level |
| `slam` | you enter the room past a door | once you are 3 m clear of the doorway (`slam_clear`), the door slams shut for you (`slam`) and you open it again to go back. Only a door that opens again: unlocked, or locked by something nothing uses up |
| `glimpse` | you enter a long corridor | she stands at its far end (at least 8 m away), looking back at you, with a stinger, for 2.5 s or until you are within 6 m, and is gone. She is drawn only (`LmClient._glimpse`): she sees nothing and fills no meter |

The lights and the glimpse are the owner's client's to show (`LmClient._show_events`); a slam is the server's, because it changes which doors are open, and the client's prediction shuts it with progress like any door. Per level: 1 + n/10 lights, 1 + n/6 slams, 1 + n/8 glimpses.

## Witches

2 + (n-1)/3 witches (12 on level 32), each walking an out-and-back round of 3 to 8 rooms, never into a start room or starting on a stairwell. A stairwell on her round is its ramp, walked from the end she comes in at (`LmLevel._witch_loop` turns the room into the foot and head of the ramp, and back down if she leaves by the end she came in), so she walks on the floor; `headless_run` samples every witch's round and checks.

## No toys

The family's map toys (dot-props' balls, swings, horns and the rest) are not placed in the house. It is a stealth game whose levels are generated and proven as measured: a toy's noise, or a ball rolling into a witch's round or across a doorway, would change a level after it was proven, and every level would have to be measured again with the toys where they ended up.

## The house laid out

Every level is built at once, side by side in rows of eight (`LmGame.LEVELS_PER_ROW`, 40 m apart): 32 levels three times the size in one line ran to 5 km. A level is sent to a client as one LEVEL message (deflated, and paced so a browser's 64 KiB inbound buffer never overflows: [design](design.md#the-house-on-the-wire)), so the builder refuses a document over 48,000 bytes compact, which a client with nothing outstanding must still be able to take whole; level 32 is about 25 KB.

## Looking at one

`tools/shot.sh --view=above --level=8 --floor=1 --res=1400x1400` renders a plan of one floor: ceilings and other floors hidden, an orthographic camera, every room, item, station, event and witch point written where it is, and the doors in their colours.

## Workshop houses

A subscribed pack can offer houses in solo: the entry's `scene` is the pack's `house.json` and the level documents sit beside it, in the format above. Online none are listed. Not done: a pack house is only checked to be a house of the entry's id with at least one level document; the builder's `--check` proofs (clear furniture, reachable doors) are the author's to run.
