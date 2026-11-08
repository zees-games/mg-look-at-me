# Converted houses

The owner's rule (2026-11-08): every house is a converted Steam Workshop map, heavily altered (layout, rooms and props changed), with our own or free art only. This is how a house is converted, what is altered, and what is left for later.

## The design: the source's geometry, our house on top

A converted house has two parts:

- The source map's **geometry**, converted by dot-map-convert (`bsp.py mesh`) with every texture and model mapped to a free or own one. It ships as a world pack next to the levels (`houses/<house>/world/<pack>/`). The source's textures, models, sounds and text are never used.
- The source's **plan**: rooms, floors, stairs and the openings between them, read off the same geometry. The builder deals our puzzles, doors, keys, furniture, witches and events on it, and proves every level solvable as it writes it.

A house without a world pack (the built-in House, the Forgotten Wing) is still rooms on the 4 m grid (`docs/levels.md`), with walls we build.

## The pipeline

1. The `.gma` is unpacked and the `.bsp` read by dot-map-convert (`bsp.py convert`) into its intermediate JSON. That stays in the map source store, outside every repository.
2. `adapters/mg-look-at-me/bsp_house.py` in dot-map-convert turns the intermediate and a spec into a layout, with numpy only and no choices of its own: the same intermediate and spec give the same layout, byte for byte (the layout records the intermediate's sha256).
   - Each storey's walkable, roofed floor is rasterised from the world brushes and the wall-like brush entities (a floor top in the storey's band, no wall at eye height above it, a ceiling over it).
   - The floor is eroded to pinch it apart at the doorways, labelled into pieces, and grown back. Two pieces that touch are joined by an opening of the source's, which is the only place a door can go.
   - Each 4 m cell takes the piece covering most of it, and the pieces become rectangles, biggest first. A rectangle one cell wide is a corridor.
   - The rooms come out as a tree from the source's player start (the door tree is the builder's model). Pieces the tree cannot reach, and dead-end nooks of one or two cells, are dropped.
   - Rooms are named from the source's props (a bed makes a ward, a desk an office) and otherwise from our own name lists. No source text is kept.
3. The spec is in this repository next to the layout it makes (`tools/convert/<house>.json`): scale, storeys, stairwells, the growth and the alterations, plus the source's title, author and page.
4. `tools/build_levels.py` deals the house from the layout (`CONVERTED`): level n is the first rooms of the tree, as many as `plan(n)` asks for (more while no cut deals), with an upper floor of fewer than three rooms left out. Each level is dealt and proved like any other level.

Regenerate the Asylum's layout with:

    python3 -P <dot-map-convert>/adapters/mg-look-at-me/bsp_house.py <intermediate.json> tools/convert/asylum.json --out tools/layouts/asylum.json

`--ascii` prints the plan of each floor.

## What is altered

- **Size.** A grid house's plan is grown and snapped to the 4 m grid, so its rooms are this game's 8 to 16 m. A house with a world pack keeps the source's size (on the pack's scale) and a 2 m cell.
- **Layout.** Rooms the tree does not reach and the small nooks are dropped. On a grid house the stairwells are ours (8 by 16 m), placed by the spec and carved out of both floors they span, so the way between floors changes. On a house with a world pack they are the source's own stairs. A spec can mirror the plan, carve cells out of it and rename rooms (`alter`).
- **Rooms.** Names, furniture (Kenney, by name), puzzles, keys, witches, lights and events are this game's own, dealt again on every level.
- **Levels.** One source plan becomes twenty levels, each a bigger cut of it.

## The Asylum

From [Blackbrook Asylum](https://steamcommunity.com/sharedfiles/filedetails/?id=903842886) by The Old Swashbuckler (page checked 2026-10-20: no licence stated and no request against porting, sharing or reuploading). Its layout has two floors joined by the source's stairs, and is dealt as levels of 18 to 34 rooms.

- Every level has both floors and a glimpse event: the builder asks for one on a converted house only when the cut has a long corridor.
- The old hand-grown Asylum (the builder's own rooms and seed) is gone.

## Queue

Each needs its own spec and a check of its page for a request against porting. A map whose author forbids porting is skipped and reported.

- **The Forgotten Wing** (Forgotten Asylum, WhiteKnuckles): today a hand-laid plan (`tools/layouts/forgotten.json`). Its walls are mostly props and brush entities, so the converter needs a spec per segment, or props as walls.
- **Henbane Mansion** (Drizz): not downloaded.
- **The House** (the built-in 32 levels): needs a base chosen from the shortlist in `docs/map-bases.md`.
- **The lam-maps houses**: the same converter, through `build_levels.py --layout`.

## Phase 2: the source's meshes (the Asylum)

The Asylum draws and collides with its converted world (`houses/asylum/world/gm_blackbrook_asylum/`). How each limit of the grid house was met:

- **Message size.** The mesh is not in the level message. A level names its pack (`world`: path, scale, origin) and every client and server loads it from the house's files. The levels stay under `MAX_BYTES`.
- **Rooms and floors.** The layout's rooms are the source's own, in metres, each at its real floor height (`y`, and `y2` at the top of a stair). `room_at`, `floor_at` and `stair_point` read those heights, not the grid's storeys.
- **Collision.** The pack's solid, clip and glass hulls become one shared trimesh per pack. A server builds every level of a house at once, and one convex shape per hull per level stalled it.
- **Doors.** Doors and locks go only in the source's openings, at the opening's width (up to 2.4 m) and height. An opening a level does not use as a door is sealed with a plank wall, so a cut of the house is closed. The exit is a ground-floor opening to the outside.
- **Witches.** Witches still walk the builder's lanes between room centres and door middles.

Not done yet:

- Some of the source's floor pieces are not reached by the room tree and are left out of the levels.
- Witches glide up stairs and can pass through walls that are not straight.
- An opening the converter missed is a hole in the cut; a wall it missed may stand across a room.
- A door's name plaque can sit inside a thick source wall.
