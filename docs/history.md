# History

Bug stories worth keeping. Each one's rule is in `CLAUDE.md` or a topic doc.

## 2026-10-12: the horror pass, and what rendering and recording found

Christian's first play test saw no witch, heard near silence, and read room names hanging in mid-air. Every suite passed throughout.

- **No witch in 36 s.** Level 1's witch circled the corners of the Larder, behind the red door; the builder started her in a dead-end room. `patrol()` now starts a witch where there is a neighbour to walk to, which rewrote the witch paths of 16 levels across both houses and nothing else.
- **A door you opened stood there shut** while you walked through it: doors are per player, the body stays for everybody else, and nothing hid or turned it for the opener. Found in the first playthrough frame.
- **The plaques were inside the wall.** Each room builds its own wall a whole `WALL` inside its edge; a plaque half a wall out from the edge was drawn inside the plaster. The headless check of the nodes said they existed.
- **The witch flickered between walking and idle** in the suite: posed only when the clock ticked, a frame between ticks measured her speed as nothing. She is now animated from her loop's speed and drawn at the interpolated time.
- **The mix peaked at 0.0 dBFS** in the first recording, at the catch. Gains came down and a -1 dB limiter went on master; the file peaks themselves were at -1 and decoded to 0, so they are -2 now.
- **The first witch was one of the players' people**, and looked like a cheerful girl in a crop top. The kit's zombie on the same rig is the witch now.
