# History

Bug stories worth keeping. Each one's rule is in `CLAUDE.md` or a topic doc.

## 2026-10-12: the levels three times the size, and what rendering found

Christian: "The maps definitely need to be bigger and longer with more to do though." The builder went to a 4 m grid, 14 + n rooms, corridors, stairwells and an upstairs, chests, and events. Every suite passed long before the house was right.

- **Stairwells led nowhere.** The first upstairs had no rooms: a room upstairs must stand on rooms below, and a stairwell that climbed straight away from its door put its head over empty ground. Stairwells now mostly climb alongside the wall they are entered through, are kept only with a room off their head, and the ground floor is grown before upstairs. Found by counting rooms per floor, not by any suite.
- **She stood unlit at the end of her corridor.** The glimpse was drawn, the event fired, the suite said so, and the render showed two red dots: every level is built at once, the compatibility renderer draws a capped number of lights, and the lamps of other levels in view pushed out the light on her. The client now draws only the player's level, with a 90 m far plane.
- **A fitted fuse sent the step back.** "Find a fuse" was done while the fuse was held or taken from the floor; a fuse from a chest, fitted, was neither, and the step line went back to it (the bucket's water always had). A step about an item is now done once anything that gives it has been used.
- **A sound for an event was refused** when the player had just been moved: the listener follows the camera after the events are shown, so a sound placed from the new spot was out of earshot of the old one. The client moves the listener first.

## 2026-10-12: the horror pass, and what rendering and recording found

Christian's first play test saw no witch, heard near silence, and read room names hanging in mid-air. Every suite passed throughout.

- **No witch in 36 s.** Level 1's witch circled the corners of the Larder, behind the red door; the builder started her in a dead-end room. `patrol()` now starts a witch where there is a neighbour to walk to, which rewrote the witch paths of 16 levels across both houses and nothing else.
- **A door you opened stood there shut** while you walked through it: doors are per player, the body stays for everybody else, and nothing hid or turned it for the opener. Found in the first playthrough frame.
- **The plaques were inside the wall.** Each room builds its own wall a whole `WALL` inside its edge; a plaque half a wall out from the edge was drawn inside the plaster. The headless check of the nodes said they existed.
- **The witch flickered between walking and idle** in the suite: posed only when the clock ticked, a frame between ticks measured her speed as nothing. She is now animated from her loop's speed and drawn at the interpolated time.
- **The mix peaked at 0.0 dBFS** in the first recording, at the catch. Gains came down and a -1 dB limiter went on master; the file peaks themselves were at -1 and decoded to 0, so they are -2 now.
- **The first witch was one of the players' people**, and looked like a cheerful girl in a crop top. The kit's zombie on the same rig is the witch now.

## 2026-10-12: the house was a burst a browser could not hold

The levels went to a joining client as 32 LEVEL messages in one tick, 490 KB once the levels tripled (210 KB before). Every suite passed: `headless_net` is a loopback, and dot-server-deploy's `lookatme_client` joins a native client, which reads its socket only when polled. A minimal web export joined to a server sending the house's real message sizes received 27 of 32 in Chromium, with five "Buffer payload full! Dropping data." errors (the 210 KB house before it: 26 of 32, so this was never the bigger levels' bug alone): the web WebSocket peer copies each arriving message into its 64 KiB inbound buffer as the page receives it and drains it once a frame. With a 40 KB acknowledged window it received all 32 in 25 frames. The house now goes deflated (90 KB) and paced ([design](design.md#the-house-on-the-wire)).
