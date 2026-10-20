# Map bases

Christian's rule: every map starts from a community workshop map as its base, and nothing starts from a blank sheet. We do not copy a base exactly; we take its floor plan, loops, hiding places and set pieces and rebuild them in the game's own room-grid format (`tools/build_levels.py`, `game/lm_level.gd`) with art that is Kenney, CC0 or MIT. Researched 2026-10-20.

## How this list was made and what it does not prove

- Searched the Steam Workshop (map tag) for horror with asylum, hospital, mansion, hotel, school, facility, forest, cabin and mine. Mine yielded nothing useful.
- The Workshop has no licence field. "None stated" means the item page description says nothing about licence. Several of the maps also contain other people's textures and sounds, so we take layout only and never the packed art.
- "No-port statement checked" means I read the item's description text for any request not to share, port, reupload, convert or redistribute. I did not read the comment sections or the authors' external pages, so a restriction there would be missed. Check the page again before starting a conversion, and drop the map on any such statement.
- Source files: none of these ship a .vmf. Each is a compiled .bsp inside a .gma, so a base is a decompile (BSPSource or similar) used as a reference for the plan, plus a screenshot or fly-through. Treat "decompilable" as likely but unverified; nothing was downloaded.
- Credit rule: the README credits the original name, author and link, with an offer to remove the map on request.
- Maps that are single-player only are still fine as plan references; the witches replace their scripted scares.

## Ranked shortlist

| # | Map | Author | Licence | No-port checked | Size |
| --- | --- | --- | --- | --- | --- |
| 1 | [Blackbrook Asylum](https://steamcommunity.com/sharedfiles/filedetails/?id=903842886) | The Old Swashbuckler (credits Chris Ward, DeepInferno, Sir Someone) | none stated | yes, none found | 31 MB, large derelict asylum, AI-noded |
| 2 | [Forgotten Asylum](https://steamcommunity.com/sharedfiles/filedetails/?id=1682965311) | WhiteKnuckles | none stated | yes, none found | 54 MB, asylum plus sewers, key-and-door progression |
| 3 | [Henbane Mansion](https://steamcommunity.com/sharedfiles/filedetails/?id=3586537135) | Drizz | none stated (credits custom props by Drizz404) | yes, none found | 50 MB, mansion |
| 4 | [Never Lose Hope Hospital Complete](https://steamcommunity.com/sharedfiles/filedetails/?id=3292074817) | Freef (stitched by MoonDust) | none stated | yes, none found | 388 MB, lab, morgue, surgery, radiology, prison, asylum, tunnels |
| 5 | [The Last Signal: Mansion](https://steamcommunity.com/sharedfiles/filedetails/?id=2335948699) | Sebyelcapo | none stated | yes, none found | 149 MB, mansion with prison |
| 6 | [The Abandoned Facility](https://steamcommunity.com/sharedfiles/filedetails/?id=1263087601) | ItsRifter | none stated | yes, none found | 29 MB, facility with checkpoints and secrets |
| 7 | [Haunted Hotel](https://steamcommunity.com/sharedfiles/filedetails/?id=2564446014) | bush boi | none stated | yes, none found (very short page) | 378 MB, hotel |
| 8 | [gm_cabin_in_the_woods](https://steamcommunity.com/sharedfiles/filedetails/?id=3340858553) | Stub@ | none stated | yes, none found | 235 MB, huge forest with cabin |
| 9 | [Abandoned School](https://steamcommunity.com/sharedfiles/filedetails/?id=2094693177) | boggington | none stated | yes, none found | 42 MB, school; author calls it short |
| 10 | [Nightmare Hotel](https://steamcommunity.com/sharedfiles/filedetails/?id=1233840585) | ItsRifter | none stated (author says its textures and sounds belong to others) | yes, none found | 15 MB, hotel |

## Notes per map

1. **Blackbrook Asylum.** Built for hide-and-seek and survival modes, so the plan already has the loops and open halls a chase needs, and it is AI-noded (useful as a hint of intended routes). Sizes well beyond today's levels. Replaces or extends the Asylum house (`houses/asylum`), as its large ground plan and overgrown wings.
2. **Forgotten Asylum.** Dark by design, keys and objects open doors, a sewer branch and a crowbar hunt, with co-op support. That is the game's own loop (keys, tools, doors), so it maps almost one to one onto levels. Replaces or extends the Asylum house; the sewers suit a late-level underground.
3. **Henbane Mansion.** Halloween mansion, recent (2025). Best candidate for the house levels: take the room set for the middle levels of the main house (levels 9 to 24). Page is thin, so the floor count is unconfirmed.
4. **Never Lose Hope Hospital Complete.** The biggest multi-area plan found: lab, docks, morgue, radio room, surgery, radiology, prison, asylum and tunnels stitched together. Not one level but a pool: split by area to give the top levels (25 to 32) different settings. Heavy; the stitching suggests long corridors, which fit sight fans.
5. **The Last Signal: Mansion.** Mansion and prison in one map, so it gives two storeys of rooms and a cell block. Extends the house with a prison wing.
6. **The Abandoned Facility.** Linear with checkpoints and two endings. Compact (29 MB) but with secrets, so use as a facility area, breaking its line into loops.
7. **Haunted Hotel.** Hotel corridors are a good fit for long sight lines. The listing has no description, so its layout needs an in-engine look before committing; very large file, likely mostly assets.
8. **gm_cabin_in_the_woods.** The only outdoor candidate: huge forest and cabins. The game is indoors with a dark house, so use it only for an outdoor courtyard or grounds level. Day and navmesh variants exist on the Workshop but are separate uploads and were not checked.
9. **Abandoned School.** Classrooms and halls give a repeating grid that is easy to loop, but the author calls it short and it is single-player. Good for one level, not a base for a large map.
10. **Nightmare Hotel.** Small hotel (15 MB). Its art credit line says the assets are borrowed from others, which is one more reason to take only the plan.

## Skipped or not pursued

- A Workshop map that is a copy of a commercial game's level (a remake of a game's mansion, for example Mr. Miles Mansion) is skipped: the layout is that game's, not the community author's.
- Single rooms and tiny test maps (for example "Asylum room") are too small to help.
- None of the maps above had a "do not port, reupload or redistribute" statement in its description. No map was dropped for that reason; if one turns up in comments, drop it.
- GameBanana: not searched. Its horror coverage is for other engines and the Workshop covered every setting asked for.
