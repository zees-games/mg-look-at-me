# Converted houses

The owner's rule (2026-11-08): every house is a converted Steam Workshop map, heavily altered (layout, rooms and props changed), with our own or free art only. This is how a house is converted, what is altered, and what is left for later.

## The design: a converted plan, not converted meshes

A house in this game is rooms on the 4 m grid (`docs/levels.md`), and everything else reads that grid: per-player doors, keys and the puzzle proof, the witches' walks, `room_at`/`floor_at`, the furniture proof and the level message size. So a converted house is the source map's **plan**, converted automatically and laid on the grid, and the builder deals our puzzles, furniture and witches on it as it does for every house. The source's meshes, textures, props, sounds and text are never used.

This is the least risky way to take a map whole: nothing in the game changes, only a layout, and the builder proves every level solvable as it writes it. Loading the source's own world meshes (phase 2, below) would touch every one of those systems at once.

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

- **Size.** The plan is grown (×2 for the Asylum) and snapped to the 4 m grid, so the rooms are this game's 8 to 16 m and not the source's.
- **Layout.** Rooms the tree does not reach and the small nooks are dropped. The stairwells are ours (8 by 16 m), placed by the spec and carved out of both floors they span, so the way between floors changes. A spec can mirror the plan, carve cells out of it and rename rooms (`alter`).
- **Rooms.** Names, furniture (Kenney, by name), puzzles, keys, witches, lights and events are this game's own, dealt again on every level.
- **Levels.** One source plan becomes twenty levels, each a bigger cut of it.

## The Asylum

From [Blackbrook Asylum](https://steamcommunity.com/sharedfiles/filedetails/?id=903842886) by The Old Swashbuckler (page checked 2026-10-20: no licence stated and no request against porting, sharing or reuploading). Its layout has three floors, about 5,500 m², and is dealt as levels of 15 to 34 rooms.

- Levels 1 to 4 are the ground floor alone. The house's other floors are only reached up the stairwells, and the nearest long corridor is on the top floor. So the first four levels have no glimpse event: the builder asks for one on a converted house only when the cut has a long corridor.
- From level 5 every level has all three floors.
- The old hand-grown Asylum (the builder's own rooms and seed) is gone.

## Queue

Each needs its own spec and a check of its page for a request against porting. A map whose author forbids porting is skipped and reported.

- **The Forgotten Wing** (Forgotten Asylum, WhiteKnuckles): today a hand-laid plan (`tools/layouts/forgotten.json`). Its walls are mostly props and brush entities, so the converter needs a spec per segment, or props as walls.
- **Henbane Mansion** (Drizz): not downloaded.
- **The House** (the built-in 32 levels): needs a base chosen from the shortlist in `docs/map-bases.md`.
- **The lam-maps houses**: the same converter, through `build_levels.py --layout`.

## Phase 2: the source's meshes (owner's call)

Drawing the converted world mesh, with the source's textures and props mapped to free assets, would look much more like a real building. It is not done, because each of these would have to change first:

- A level document is held under 48,000 bytes (`MAX_BYTES`) and sent in a 32 KB window: a mesh does not fit in a level message.
- `room_at` and `floor_at` read the grid; a mesh's floors and stairs do not.
- Witches walk grid lanes, and the furniture proof keeps those lanes clear.
- Doors are per player and cut in grid walls.
