#!/usr/bin/env python3
"""Writes assets/witch/: the witch's body and her atlas (game/lm_witch.gd draws them).

    tools/make_witch.py [path to game-zombie-zone]   # default: ../game-zombie-zone

Her body is the Zombie Apocalypse Kit's basic zombie by Quaternius (CC0 1.0,
https://quaternius.com/packs/zombieapocalypsekit.html), as game-zombie-zone builds it
(tools/build_zombie_models.py there: one decimated mesh, the kit's clips renamed). It is copied,
not linked: a game ships its own art, and a delivered pack cannot reach into another game.

Her atlas is that zombie's palette atlas recoloured: the green skin a corpse grey, the trousers
and belt black, and every other swatch greyed and darkened, so nothing on her is a colour but
her eyes (which are the view's, not the atlas's).
"""
import os
import shutil
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets", "witch")
ZZ = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "game-zombie-zone")

# The basic zombie's swatches (game-zombie-zone's ZzZombieView.WEARS) and what they become.
SWAPS = {"769751": "9aa293", "3f5363": "1a161d", "664531": "0f0d10"}


def rgb(hex_text):
    return tuple(int(hex_text[i:i + 2], 16) for i in (0, 2, 4))


def main():
    os.makedirs(OUT, exist_ok=True)
    shutil.copyfile(os.path.join(ZZ, "assets", "zombies", "zombie_basic.glb"), os.path.join(OUT, "witch.glb"))
    atlas = Image.open(os.path.join(ZZ, "assets", "zombies", "atlas_basic.png")).convert("RGB")
    swaps = {rgb(a): rgb(b) for a, b in SWAPS.items()}
    px = atlas.load()
    for y in range(atlas.size[1]):
        for x in range(atlas.size[0]):
            c = px[x, y]
            if c == (255, 255, 255):
                continue
            if c in swaps:
                px[x, y] = swaps[c]
                continue
            grey = int((c[0] * 0.3 + c[1] * 0.59 + c[2] * 0.11) * 0.45)
            px[x, y] = (grey + 3, grey, grey + 5)
    atlas.save(os.path.join(OUT, "witch_atlas.png"))
    print("wrote", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
