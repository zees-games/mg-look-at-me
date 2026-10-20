"""Furnishing for tools/build_levels.py: what each kind of room holds, where it stands, and the proof.

A level document carries its furniture (`props`), placed here per room type from the level's own
seed, so every machine has the same rooms and `--check` can prove what the game will build:

    "prop_scale": 2.3
    "models": {"bedDouble": [w, h, d]}           final metres (Kenney's kit is built small, so scaled)
    "props":  [["bedDouble", "r3", x, z, rot]]   centre in metres from the room's corner, rot 0/90/180/270
                                                 (a piece's front is +z; rot 0 is against the north wall)
    a sixth number is a height: a thing standing on something, drawn only, no collision.

The rules the proof holds every room to: a piece is inside the room's walls, overlaps no other
piece, stays out of every doorway (2.6 m wide, 2 m deep), every item and station (0.8 m round)
and every straight line a witch walks through the room (she walks centre to door and passes
through anything), and what is left of the floor still joins every door, item and station to
every other, with a player's width (0.45 m each side of a piece). Furniture is only ever
placed, never relied on: a level that cannot be furnished to the rules is left bare.
"""
import json
import math
import random
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
FURNITURE_DIR = os.path.join(HERE, "..", "assets", "kenney", "furniture")

# Kenney's kit is built about 0.43 of a person's size. game/lm_level.gd's FURNITURE_SCALE.
SCALE = 2.3
GAP = 0.2            # from the wall's face (the wall is 0.15 deep, plus a hand)
DOOR_W, DOOR_D = 2.6, 2.0
SPOT = 0.8
LANE = 0.8
WALK = 0.45
GRID = 0.25

_extents = {}


def extent(model):
    """A model's raw size in metres, from its glTF: the POSITION accessors' bounds under each
    mesh node's transform."""
    if model in _extents:
        return _extents[model]
    with open(os.path.join(FURNITURE_DIR, model + ".glb"), "rb") as f:
        data = f.read()
    length = struct.unpack("<I", data[12:16])[0]
    j = json.loads(data[20:20 + length])
    nodes = j.get("nodes", [])
    lo, hi = [1e9] * 3, [-1e9] * 3

    def mat(n):
        if "matrix" in n:
            m = n["matrix"]
            return [[m[c * 4 + r] for c in range(4)] for r in range(4)]
        t = n.get("translation", [0, 0, 0])
        q = n.get("rotation", [0, 0, 0, 1])
        s = n.get("scale", [1, 1, 1])
        x, y, z, w = q
        r = [[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
             [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
             [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]]
        return [[r[i][0] * s[0], r[i][1] * s[1], r[i][2] * s[2], t[i]] for i in range(3)] + [[0, 0, 0, 1]]

    def mul(a, b):
        return [[sum(a[i][k] * b[k][c] for k in range(4)) for c in range(4)] for i in range(4)]

    def walk(i, parent):
        nonlocal lo, hi
        n = nodes[i]
        m = mul(parent, mat(n))
        if "mesh" in n:
            for prim in j["meshes"][n["mesh"]]["primitives"]:
                acc = j["accessors"][prim["attributes"]["POSITION"]]
                for corner in range(8):
                    p = [acc["max"][a] if corner >> a & 1 else acc["min"][a] for a in range(3)]
                    out = [m[r][0] * p[0] + m[r][1] * p[1] + m[r][2] * p[2] + m[r][3] for r in range(3)]
                    for a in range(3):
                        lo[a], hi[a] = min(lo[a], out[a]), max(hi[a], out[a])
        for c in n.get("children", []):
            walk(c, m)

    ident = [[1 if i == k else 0 for k in range(4)] for i in range(4)]
    scene = j["scenes"][j.get("scene", 0)]
    for root in scene["nodes"]:
        walk(root, ident)
    _extents[model] = [hi[a] - lo[a] for a in range(3)]
    return _extents[model]


def size_of(model):
    """The final size in metres: width, height, depth (depth is front to back)."""
    return [round(v * SCALE, 2) for v in extent(model)]


# What a room is called -> its theme. First match wins; the rest are the store.
THEMES = [
    ("padded", "cell"), ("isolation", "cell"), ("solitary", "cell"),
    ("kitchen", "kitchen"), ("scullery", "kitchen"), ("still room", "kitchen"), ("pantry", "pantry"), ("larder", "pantry"),
    ("refectory", "dining"), ("dining", "dining"), ("servants", "dining"),
    ("bath", "bath"), ("shower", "bath"), ("hydrotherapy", "bath"),
    ("laundry", "laundry"), ("linen", "laundry"), ("boiler", "laundry"),
    ("nursery", "nursery"),
    ("ward", "ward"), ("infirmary", "ward"), ("treatment", "ward"),
    ("bedroom", "bedroom"), ("dressing", "bedroom"),
    ("library", "library"), ("records", "library"), ("gallery", "library"),
    ("study", "study"), ("office", "study"), ("night station", "study"), ("porter", "study"), ("dispensary", "study"), ("pharmacy", "study"),
    ("matron", "study"),
    ("music", "sitting"), ("morning", "sitting"), ("drawing", "sitting"), ("smoking", "sitting"), ("parlour", "sitting"),
    ("day room", "sitting"), ("visiting", "sitting"), ("conservatory", "garden"), ("lobby", "sitting"), ("reception", "sitting"),
    ("hall", "hall"), ("landing", "hall"),
    ("chapel", "chapel"), ("mortuary", "chapel"),
    ("workshop", "workshop"), ("gun", "workshop"),
    ("billiard", "sitting"), ("sewing", "bedroom"),
]

# [model, how, count]. wall: against a wall anywhere; run: on from the last piece's wall;
# corner: tucked in a corner; front: facing the last piece, in front of it; centre: standing
# free in the middle; on: standing on the last wall or centre piece (drawn only).
RECIPES = {
    "bedroom": [("bedDouble", "wall", 1), ("sideTableDrawers", "run", 1), ("lampSquareTable", "on", 1), ("bookcaseClosed", "wall", 1),
                ("coatRackStanding", "corner", 1), ("chair", "wall", 1), ("pottedPlant", "corner", 1)],
    "nursery": [("bedSingle", "wall", 2), ("cardboardBoxOpen", "wall", 2), ("bookcaseOpen", "wall", 1), ("chairCushion", "wall", 1),
                ("lampRoundFloor", "corner", 1)],
    "kitchen": [("kitchenFridge", "wall", 1), ("kitchenCabinet", "run", 1), ("kitchenStove", "run", 1), ("kitchenSink", "run", 1),
                ("kitchenCabinet", "run", 1), ("table", "centre", 1), ("chair", "front", 1), ("trashcan", "corner", 1)],
    "pantry": [("bookcaseOpen", "wall", 3), ("kitchenFridgeSmall", "wall", 1), ("cardboardBoxClosed", "corner", 2), ("table", "wall", 1),
               ("trashcan", "corner", 1)],
    "dining": [("tableRound", "centre", 1), ("chair", "front", 1), ("sideTableDrawers", "wall", 2), ("bookcaseClosedWide", "wall", 1),
               ("lampRoundFloor", "corner", 1), ("pottedPlant", "corner", 1)],
    "bath": [("bathtub", "wall", 1), ("toilet", "wall", 1), ("bathroomSink", "wall", 1), ("washer", "wall", 1), ("trashcan", "corner", 1),
             ("pottedPlant", "corner", 1)],
    "laundry": [("washer", "wall", 2), ("dryer", "run", 2), ("table", "wall", 1), ("cardboardBoxClosed", "corner", 2), ("trashcan", "corner", 1)],
    "ward": [("bedSingle", "wall", 3), ("sideTable", "run", 1), ("chair", "wall", 1), ("cabinetTelevision", "wall", 1), ("trashcan", "corner", 1)],
    "cell": [("bench", "wall", 1), ("bucket", "corner", 1)],
    "library": [("bookcaseClosedWide", "wall", 3), ("bookcaseOpen", "run", 3), ("table", "centre", 1), ("chair", "front", 1),
                ("lampRoundFloor", "corner", 2), ("loungeChair", "wall", 1)],
    "study": [("desk", "wall", 1), ("laptop", "on", 1), ("chairDesk", "front", 1), ("bookcaseClosed", "wall", 2), ("bookcaseOpen", "run", 1),
              ("lampRoundFloor", "corner", 1), ("loungeChair", "wall", 1), ("pottedPlant", "corner", 1)],
    "sitting": [("loungeSofa", "wall", 1), ("tableCoffee", "front", 1), ("loungeChair", "wall", 2), ("cabinetTelevision", "wall", 1),
                ("televisionVintage", "on", 1), ("bookcaseClosedWide", "wall", 1), ("lampRoundFloor", "corner", 2), ("pottedPlant", "corner", 2),
                ("loungeSofaOttoman", "wall", 1)],
    "garden": [("pottedPlant", "corner", 4), ("benchCushion", "wall", 2), ("tableRound", "centre", 1), ("chair", "front", 1), ("pottedPlant", "wall", 2)],
    "hall": [("coatRackStanding", "corner", 1), ("sideTableDrawers", "wall", 2), ("lampSquareTable", "on", 1), ("bench", "wall", 1),
             ("pottedPlant", "corner", 2), ("bookcaseClosed", "wall", 1)],
    "chapel": [("benchCushion", "wall", 3), ("bench", "wall", 3), ("lampRoundFloor", "corner", 2), ("sideTable", "wall", 1)],
    "workshop": [("desk", "wall", 1), ("cardboardBoxClosed", "corner", 3), ("bench", "wall", 2), ("chairDesk", "front", 1), ("trashcan", "corner", 1)],
    "store": [("cardboardBoxClosed", "corner", 3), ("cardboardBoxOpen", "wall", 2), ("bookcaseOpen", "wall", 2), ("table", "wall", 1),
              ("chair", "wall", 1), ("lampRoundFloor", "corner", 1)],
}
FRONT_ORDER = [0, 180, 90, 270]

# Pieces the kit has under other names or lacks: swapped for what it has.
ALIASES = {"bucket": "trashcan"}


def theme_of(name):
    text = name.lower()
    for word, theme in THEMES:
        if word in text:
            return theme
    return "store"


def models_used():
    out = set()
    for recipe in RECIPES.values():
        for model, _how, _n in recipe:
            out.add(ALIASES.get(model, model))
    return sorted(out)


class Rect:
    __slots__ = ("x0", "z0", "x1", "z1")

    def __init__(self, x0, z0, x1, z1):
        self.x0, self.z0, self.x1, self.z1 = x0, z0, x1, z1

    def hits(self, o, pad=0.0):
        return self.x0 - pad < o.x1 and o.x0 < self.x1 + pad and self.z0 - pad < o.z1 and o.z0 < self.z1 + pad


def footprint(model, x, z, rot):
    w, _h, d = size_of(model)
    fx, fz = (w, d) if rot in (0, 180) else (d, w)
    return Rect(x - fx / 2, z - fz / 2, x + fx / 2, z + fz / 2)


def room_geometry(doc, room):
    """Everything in one room a piece must keep clear of: its size, doors, spots, lanes."""
    cell = doc["cell"]
    ox, oz = room["x"] * cell, room["z"] * cell
    width, depth = room["w"] * cell, room["d"] * cell
    doors = []
    for d in doc["doors"]:
        if d["a"] != room["id"] and d.get("b") != room["id"]:
            continue
        px, pz = d["at"][0] * cell - ox, d["at"][1] * cell - oz
        doors.append((px, pz))
    spots = []
    for thing in doc["items"] + doc["stations"]:
        if thing.get("room") == room["id"] and "at" in thing:
            spots.append((thing["at"][0] * width, thing["at"][1] * depth))
    return width, depth, doors, spots


def keepouts(width, depth, doors, spots):
    """Rectangles a piece may not overlap."""
    out = []
    for (px, pz) in doors:
        if abs(pz) < 0.01:
            out.append(Rect(px - DOOR_W / 2, 0, px + DOOR_W / 2, DOOR_D))
        elif abs(pz - depth) < 0.01:
            out.append(Rect(px - DOOR_W / 2, depth - DOOR_D, px + DOOR_W / 2, depth))
        elif abs(px) < 0.01:
            out.append(Rect(0, pz - DOOR_W / 2, DOOR_D, pz + DOOR_W / 2))
        else:
            out.append(Rect(width - DOOR_D, pz - DOOR_W / 2, width, pz + DOOR_W / 2))
    for (sx, sz) in spots:
        out.append(Rect(sx - SPOT, sz - SPOT, sx + SPOT, sz + SPOT))
    # A witch walks centre to each door: a lane along it.
    cx, cz = width / 2, depth / 2
    for (px, pz) in doors:
        steps = max(int(math.hypot(px - cx, pz - cz) / 0.25), 1)
        for i in range(steps + 1):
            x = cx + (px - cx) * i / steps
            z = cz + (pz - cz) * i / steps
            out.append(Rect(x - LANE, z - LANE, x + LANE, z + LANE))
    return out


def reachable(width, depth, doors, spots, boxes):
    """A grid flood from the first door: does it join every door and every spot, with a
    player's width kept off every piece?"""
    nx, nz = int(width / GRID), int(depth / GRID)
    blocked = [[False] * nz for _ in range(nx)]
    for b in boxes:
        for i in range(max(int((b.x0 - WALK) / GRID), 0), min(int((b.x1 + WALK) / GRID) + 1, nx)):
            for k in range(max(int((b.z0 - WALK) / GRID), 0), min(int((b.z1 + WALK) / GRID) + 1, nz)):
                cx, cz = (i + 0.5) * GRID, (k + 0.5) * GRID
                if b.x0 - WALK < cx < b.x1 + WALK and b.z0 - WALK < cz < b.z1 + WALK:
                    blocked[i][k] = True

    def cell_of(p):
        return min(max(int(p[0] / GRID), 0), nx - 1), min(max(int(p[1] / GRID), 0), nz - 1)

    targets = [cell_of(p) for p in doors + spots]
    if not targets:
        return True
    # A doorway's own cell may sit inside the wall's inflation: step one metre in from it.
    def inward(p):
        x, z = p
        if abs(z) < 0.01:
            z = 0.6
        elif abs(z - depth) < 0.01:
            z = depth - 0.6
        elif abs(x) < 0.01:
            x = 0.6
        elif abs(x - width) < 0.01:
            x = width - 0.6
        return cell_of((x, z))
    starts = [inward(p) for p in doors] or [cell_of(p) for p in spots]
    seen = {starts[0]}
    todo = [starts[0]]
    while todo:
        i, k = todo.pop()
        for (a, b) in ((i + 1, k), (i - 1, k), (i, k + 1), (i, k - 1)):
            if 0 <= a < nx and 0 <= b < nz and (a, b) not in seen and not blocked[a][b]:
                seen.add((a, b))
                todo.append((a, b))
    need = [inward(p) for p in doors] + [cell_of(p) for p in spots]
    return all(c in seen for c in need)


def room_ok(doc, room, pieces):
    """The proof for one room. pieces: [(model, x, z, rot)] with collision."""
    width, depth, doors, spots = room_geometry(doc, room)
    boxes = []
    keep = keepouts(width, depth, doors, spots)
    for (model, x, z, rot) in pieces:
        r = footprint(model, x, z, rot)
        if r.x0 < 0.15 or r.z0 < 0.15 or r.x1 > width - 0.15 or r.z1 > depth - 0.15:
            return False
        if any(r.hits(k) for k in keep) or any(r.hits(o, 0.05) for o in boxes):
            return False
        boxes.append(r)
    return reachable(width, depth, doors, spots, boxes)


def furnish_room(rng, doc, room):
    """The pieces of one room: [model, x, z, rot, y] (y 0 for something on the floor)."""
    width, depth, doors, spots = room_geometry(doc, room)
    keep = keepouts(width, depth, doors, spots)
    placed = []      # (model, x, z, rot, y)
    boxes = []

    def collide(model, x, z, rot):
        r = footprint(model, x, z, rot)
        if r.x0 < 0.15 or r.z0 < 0.15 or r.x1 > width - 0.15 or r.z1 > depth - 0.15:
            return None
        if any(r.hits(k) for k in keep) or any(r.hits(o, 0.05) for o in boxes):
            return None
        return r

    def accept(model, x, z, rot):
        r = collide(model, x, z, rot)
        if r is None:
            return False
        if not reachable(width, depth, doors, spots, boxes + [r]):
            return False
        boxes.append(r)
        placed.append([model, round(x, 2), round(z, 2), rot, 0.0])
        return True

    def at_wall(model, side, t):
        """Centre and rotation of a piece against a wall at distance t along it."""
        w, _h, d = size_of(model)
        if side == "n":
            return t, GAP + d / 2, 0
        if side == "s":
            return t, depth - GAP - d / 2, 180
        if side == "w":
            return GAP + d / 2, t, 90
        return width - GAP - d / 2, t, 270

    def wall_spots(model, sides, step=0.4):
        w = size_of(model)[0]
        out = []
        for side in sides:
            length = width if side in "ns" else depth
            t = w / 2 + GAP
            while t < length - w / 2 - GAP:
                out.append((side, round(t, 2)))
                t += step
        rng.shuffle(out)
        return out

    last = None
    fronts = 0
    for (model, how, count) in RECIPES[theme_of(room["name"])]:
        model = ALIASES.get(model, model)
        for _ in range(count):
            done = False
            if how == "on":
                if last is not None and placed:
                    base = last
                    placed.append([model, base[1], base[2], base[3], round(size_of(base[0])[1], 2)])
                continue
            if how == "run" and last is not None and last[5] in "nsew":
                # On from the last piece along its wall, either side.
                lw = size_of(last[0])[0]
                mw = size_of(model)[0]
                for sign in (1, -1):
                    t = (last[6] + sign * (lw / 2 + mw / 2 + 0.05))
                    side = last[5]
                    x, z, rot = at_wall(model, side, t)
                    if accept(model, x, z, rot):
                        last = [model, x, z, rot, 0.0, side, t]
                        done = True
                        break
            if not done and how in ("wall", "run"):
                for (side, t) in wall_spots(model, "nsew"):
                    x, z, rot = at_wall(model, side, t)
                    if accept(model, x, z, rot):
                        last = [model, x, z, rot, 0.0, side, t]
                        done = True
                        break
            elif how == "corner":
                w, _h, d = size_of(model)
                spots_c = []
                for sx in (0, 1):
                    for sz in (0, 1):
                        x = GAP + w / 2 if sx == 0 else width - GAP - w / 2
                        z = GAP + d / 2 if sz == 0 else depth - GAP - d / 2
                        spots_c.append((x, z, 0))
                rng.shuffle(spots_c)
                for (x, z, rot) in spots_c:
                    if accept(model, x, z, rot):
                        last = [model, x, z, rot, 0.0, "c", 0]
                        done = True
                        break
            elif how == "front" and last is not None:
                # Around the last piece, one side at a time, each facing it.
                lw, _lh, ld = size_of(last[0])
                lrot = last[3]
                _w, _h2, md = size_of(model)
                for turn in (FRONT_ORDER[fronts % 4], FRONT_ORDER[(fronts + 1) % 4]):
                    rot = (lrot + turn) % 360
                    face = {0: (0, 1), 90: (1, 0), 180: (0, -1), 270: (-1, 0)}[rot]
                    reach = (ld if turn in (0, 180) else lw) / 2 + md / 2 + 0.1
                    x, z = last[1] + face[0] * reach, last[2] + face[1] * reach
                    if accept(model, x, z, (rot + 180) % 360):
                        done = True
                        break
                fronts += 1
            elif how == "centre":
                tries = [(width / 2 + rng.uniform(-1, 1), depth / 2 + rng.uniform(-1, 1), rng.choice([0, 90])) for _ in range(30)]
                for (x, z, rot) in tries:
                    if accept(model, x, z, rot):
                        last = [model, x, z, rot, 0.0, "c", 0]
                        done = True
                        break
    return [[m, x, z, r, y] for (m, x, z, r, y) in placed]


def furnish(doc):
    """Adds props, models and prop_scale to a finished level document."""
    props = []
    used = set()
    for room in doc["rooms"]:
        if room["kind"] != "room":
            continue
        # A per-room salt is for a hand-laid level whose first dealing of a big room left two pieces
        # 0.05 m apart before rounding and touching after it (the builder deals that room again).
        rng = random.Random("%s|%s%s" % (doc["id"], room["id"], doc.get("furnish_salt", {}).get(room["id"], "")))
        for (m, x, z, rot, y) in furnish_room(rng, doc, room):
            used.add(m)
            row = [m, room["id"], x, z, rot]
            if y:
                row.append(y)
            props.append(row)
    doc["prop_scale"] = SCALE
    doc["models"] = {m: size_of(m) for m in sorted(used)}
    doc["props"] = props
    return doc


def prove(doc):
    """What is wrong with the furniture of a document, as a list of sentences (empty: nothing)."""
    bad = []
    by_room = {}
    for (m, rid, x, z, rot, *rest) in doc.get("props", []):
        if doc["models"].get(m) != size_of(m):
            bad.append("%s: model %s is not the size the kit has" % (doc["id"], m))
        if not rest:
            by_room.setdefault(rid, []).append((m, x, z, rot))
    rooms = {r["id"]: r for r in doc["rooms"]}
    for rid, pieces in by_room.items():
        if rooms[rid]["kind"] != "room":
            bad.append("%s: furniture in %s, which is not a room" % (doc["id"], rid))
        elif not room_ok(doc, rooms[rid], pieces):
            bad.append("%s: %s's furniture blocks a door, spot, lane or walk, or overlaps" % (doc["id"], rid))
    return bad
