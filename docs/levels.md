# Levels

How a level is grown, what is in it, and what the house does to you on the way. `tools/build_levels.py` writes every level of every house; `game/lm_level.gd` builds one; `game/lm_game.gd` plays it. Christian's ask that shaped it: "The maps definitely need to be bigger and longer with more to do though."

## Size

A level is rooms on a grid of 4 m cells (`cell` in the document). Level n has at least 14 + n rooms (15 on level 1, 47 on level 32; the Asylum's 16 levels go to 30), about three times the floor area of the first build (level 1 from 960 m² to about 3,600; level 32 from 2,300 to about 7,900). `tools/build_levels.py --stats` prints every level's rooms, area, floors, doors, steps, events and size.

Three shapes of room:

| Kind | Size | What it is for |
| --- | --- | --- |
| `room` | 12 to 20 m a side (8 to 12 upstairs too) | furnished by its name; where the parts of puzzles are |
| `corridor` | 4 m wide, 12 to 24 m long | the way between rooms, bare (furniture down both walls of a 4 m passage leaves no passage); where she is seen at a distance |
| `stair` | 8 by 16 m, two storeys | the only way between floors: a 4 m landing at its foot, an 8 m ramp (25°, the controller walks up to 46°), a 4 m landing at its head, level with the floor above, solid underneath |

The lobby (level 1's start room, 24 m square) is still the biggest room in the game, and level 1 is one floor, to learn the house on. Every level from 2 has an upstairs: a stairwell's foot opens off a room, and a room upstairs only stands over rooms below it (a stairwell mostly climbs alongside the wall it is entered through, so its head is beside the house; one that climbed away from it led nowhere, because nothing could stand there). A stairwell is placed only with a room off its head, or not at all.

Floors are a storey apart (`storey`, 3.7 m: a room's 3.2 m, its ceiling slab and the next floor's slab, one over the other; two boxes in one place flicker). Walls are built a storey at a time, each cut for the doors on that storey. `LmLevel.room_at` takes a height: each room owns from 0.9 m under its floor to 0.9 m under the floor above its top, so two floors never both claim a point. `LmLevel.floor_at` is the floor under a point, the ramp included, and everything placed in a level (items, stations, witches' points, spawn points) is placed on it.

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
| `slam` | you enter the room past a door | once you are 3 m clear of the doorway (`LmGame.SLAM_CLEAR`), the door slams shut for you (`slam`) and you open it again to go back. Only a door that opens again: unlocked, or locked by something nothing uses up |
| `glimpse` | you enter a long corridor | she stands at its far end (at least 8 m away), looking back at you, with a stinger, for 2.5 s or until you are within 6 m, and is gone. She is drawn only (`LmClient._glimpse`): she sees nothing and fills no meter |

The lights and the glimpse are the owner's client's to show (`LmClient._show_events`); a slam is the server's, because it changes which doors are open, and the client's prediction shuts it with progress like any door. Per level: 1 + n/10 lights, 1 + n/6 slams, 1 + n/8 glimpses.

## Witches

2 + (n-1)/3 witches (12 on level 32), each walking an out-and-back round of 3 to 8 rooms, never into a start room or starting on a stairwell. A stairwell on her round is its ramp, walked from the end she comes in at (`LmLevel._witch_loop` turns the room into the foot and head of the ramp, and back down if she leaves by the end she came in), so she walks on the floor; `headless_run` samples every witch's round and checks.

## The house laid out

Every level is built at once, side by side in rows of eight (`LmGame.LEVELS_PER_ROW`, 40 m apart): 32 levels three times the size in one line ran to 5 km. A level is sent to a client as one LEVEL message (deflated, and paced so a browser's 64 KiB inbound buffer never overflows: [design](design.md#the-house-on-the-wire)), so the builder refuses a document over 48,000 bytes compact, which a client with nothing outstanding must still be able to take whole; level 32 is about 25 KB.

## Looking at one

`tools/shot.sh --view=above --level=8 --floor=1 --res=1400x1400` renders a plan of one floor: ceilings and other floors hidden, an orthographic camera, every room, item, station, event and witch point written where it is, and the doors in their colours.
