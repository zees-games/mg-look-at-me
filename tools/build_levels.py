#!/usr/bin/env python3
"""Writes every level document of every house and proves each can be finished.

    tools/build_levels.py            # rewrite levels/*.json and houses/*/*.json
    tools/build_levels.py --check    # exit 1 if a file on disk is not what this writes
    tools/build_levels.py --stats    # one line per level: rooms, floor area, floors, doors, steps, events

A level is rooms on a grid of CELL-metre cells, on one or more floors, joined by doors on the
walls they share. Rooms are grown as a tree from the start room, and every door into a new
room is locked behind a PUZZLE whose parts are put in rooms already reachable: so a level can
always be finished, by construction, and solve() checks it anyway before writing.

Three shapes of room: a ROOM (12 to 20 m a side), a CORRIDOR (4 m wide, 12 to 24 m long) and
a STAIRWELL (8 by 16 m, two storeys: a landing, a ramp, a landing). A stairwell is the only way
between floors, and a room upstairs only stands over the floor below it.

The puzzles are the genre's: a coloured key for a coloured door, a bucket filled at a tap to
put out a fire, a fuse for a dead fuse box, a crowbar for a boarded door, a code found on a
note for a keypad, a lever somewhere else, a screwdriver for a vent with a key behind it, and
any of those parts locked in a chest whose small key is somewhere else again.

EVENTS are what the house does to you on the way: the lights of a room die as you take what
was in it, a door slams shut behind you (you open it again to go back), and at the end of a
long corridor she stands and watches you for a moment and is gone. An event fires once per
go at a level, from the same conditions a step uses, plus "entered" (a room).

Every number is written as a float where the format says float, so a document that
round-trips through a parser comes back the same (mg-wipeout's finding).
"""
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

CELL = 4.0
HEIGHT = 3.2
SLAB = 0.25
# Floor to floor: a room's height, its ceiling slab and the next floor's slab, which sit one
# over the other rather than in the same place (two boxes in one place flicker).
STOREY = HEIGHT + 2 * SLAB
LEVELS = 32
FORMAT = 2

# The biggest compact document a level may be: each goes to a client as one message, and a
# browser's WebSocket buffer is 64 KiB (game/net/lm_events.gd).
MAX_BYTES = 48000

COLOURS = ["red", "blue", "green", "yellow", "purple", "orange", "white", "black"]

ROOM_NAMES = [
    "Hall", "Kitchen", "Bathroom", "Pantry", "Study", "Bedroom", "Nursery", "Cellar", "Parlour",
    "Library", "Laundry", "Chapel", "Attic", "Boiler Room", "Conservatory", "Gallery", "Servants' Hall",
    "Dining Room", "Music Room", "Storeroom", "Wine Cellar", "Workshop", "Sewing Room", "Larder",
    "Drawing Room", "Smoking Room", "Scullery", "Billiard Room", "Morning Room", "Linen Room",
    "Gun Room", "Still Room", "Box Room", "Dressing Room", "Guest Bedroom", "Master Bedroom",
]

CORRIDOR_NAMES = ["Corridor", "Passage", "Back Passage", "Long Corridor", "Servants' Passage", "Hallway"]
STAIR_NAMES = ["Stairs", "Back Stairs", "Servants' Stairs", "Great Stairs"]

ASYLUM_ROOMS = [
    "Ward A", "Ward B", "Ward C", "Day Room", "Dispensary", "Records", "Hydrotherapy", "Kitchen",
    "Laundry", "Chapel", "Isolation", "Office", "Mortuary", "Boiler Room", "Visiting Room", "Showers",
    "Refectory", "Storeroom", "Infirmary", "Treatment Room", "Linen Room", "Porter's Lodge",
    "Padded Cell", "Night Station", "Pharmacy", "Library", "Workshop", "Matron's Office",
]
ASYLUM_CORRIDORS = ["Ward Corridor", "Corridor", "Service Passage", "East Corridor", "West Corridor"]
ASYLUM_STAIRS = ["Stairs", "Fire Stairs", "Service Stairs"]

LEVEL_NAMES = [
    "The Front Door", "Supper", "Bath Time", "The Pantry", "Lessons", "Lights Out", "The Nursery",
    "Down Below", "Visitors", "Quiet, Please", "Wash Day", "Evensong", "Up the Stairs", "Pressure",
    "Glasshouse", "Portraits", "Below Stairs", "Dinner Is Served", "Out of Tune", "Inventory",
    "Vintage", "Tools Down", "Needlework", "Leftovers", "The Long Corridor", "Two Witches", "Hide",
    "Hush", "The Whole House", "No Light", "Almost Home", "Look At Me",
]

ASYLUM_NAMES = [
    "Admissions", "The Day Room", "Lights Out", "Ward B", "Solitary", "The Dispensary", "Visiting Hours",
    "Night Shift", "The Records Room", "Hydrotherapy", "The East Wing", "The Chapel", "Restraints",
    "The Director's Office", "The Basement", "Discharge",
]

# Every house the builder writes: id -> (directory, how many levels, seed base, level names,
# what the start room of level 1 is called, the house's name, room / corridor / stair names).
# A server plays one house at a time and votes between them (game/lm_vote.gd); an owner's own
# house is a directory of the same documents.
HOUSES = {
    "house": ("levels", LEVELS, 1000, LEVEL_NAMES, "The Lobby", "The House", ROOM_NAMES, CORRIDOR_NAMES, STAIR_NAMES),
    "asylum": ("houses/asylum", 16, 5000, ASYLUM_NAMES, "Reception", "The Asylum", ASYLUM_ROOMS, ASYLUM_CORRIDORS, ASYLUM_STAIRS),
}

ROOM_SHAPES = [(3, 3), (3, 3), (4, 3), (3, 4), (4, 4), (5, 3), (3, 5), (5, 4), (4, 5)]
DIRS = {"n": (0, -1), "s": (0, 1), "w": (-1, 0), "e": (1, 0)}
OPPOSITE = {"n": "s", "s": "n", "w": "e", "e": "w"}


def plan(n):
    """How big level n is and what it may have: rooms, floors, witches, events."""
    return {
        "rooms": min(14 + n, 46),
        # Upstairs from level 2: the lobby's level is one floor, to learn the house on. A third
        # floor from level 16, up a stairwell from the first floor.
        "floors": 1 if n < 2 else (2 if n < 16 else 3),
        "witches": min(2 + (n - 1) // 3, 12),
        "lights": 1 + n // 10,
        "slams": 1 + n // 6,
        "glimpses": 1 + n // 8,
        "chest": 0.0 if n < 3 else 0.3,
        "kinds": 3 + min(n // 3, 5),
    }


class Grower:
    """Rooms on a grid of cells, per floor: occupied[(x, z, floor)] = room id."""

    def __init__(self, rng):
        self.rng = rng
        self.rooms = []
        self.by_id = {}
        self.occupied = {}
        self.doors = []

    def cells(self, x, z, w, d):
        return [(x + i, z + j) for i in range(w) for j in range(d)]

    def fits(self, x, z, w, d, floor, floors):
        for f in range(floor, floor + floors):
            for (cx, cz) in self.cells(x, z, w, d):
                if (cx, cz, f) in self.occupied:
                    return False
        # Nothing hangs in the air: a room upstairs stands on rooms below (a stairwell is its own
        # support for its upper storey).
        if floor > 0:
            for (cx, cz) in self.cells(x, z, w, d):
                if (cx, cz, floor - 1) not in self.occupied:
                    return False
        return True

    def put(self, name, kind, x, z, w, d, floor, parent, extra=None):
        rid = "r%d" % len(self.rooms)
        floors = 2 if kind == "stair" else 1
        for f in range(floor, floor + floors):
            for c in self.cells(x, z, w, d):
                self.occupied[(c[0], c[1], f)] = rid
        room = {"id": rid, "name": name, "kind": kind, "x": x, "z": z, "w": w, "d": d, "floor": floor,
                "parent": parent, "spawn": parent is None, "light": 0.0, "depth": 0}
        if extra:
            room.update(extra)
        if parent is not None:
            room["depth"] = self.by_id[parent]["depth"] + 1
        self.rooms.append(room)
        self.by_id[rid] = room
        return room

    def door_cells(self, room):
        """The cells a door out of this room may be cut beside, and the floor it is on."""
        if room["kind"] != "stair":
            return self.cells(room["x"], room["z"], room["w"], room["d"]), room["floor"]
        # A stairwell's children are off its upper landing.
        return stair_landing(room, high=True), room["floor"] + 1

    def edges_out(self, room):
        cells, floor = self.door_cells(room)
        own = set(self.cells(room["x"], room["z"], room["w"], room["d"]))
        out = []
        for (cx, cz) in cells:
            for side, (dx, dz) in DIRS.items():
                o = (cx + dx, cz + dz)
                if o not in own:
                    out.append(((cx, cz), side, o, floor))
        return out


def stair_landing(room, high):
    """A stairwell's landing cells: the low one at its foot, the high one at its head."""
    up = room["up"]
    x, z, w, d = room["x"], room["z"], room["w"], room["d"]
    if up in "ew":
        col = (x + w - 1 if up == "e" else x) if high else (x if up == "e" else x + w - 1)
        return [(col, z + j) for j in range(d)]
    row = (z + d - 1 if up == "s" else z) if high else (z if up == "s" else z + d - 1)
    return [(x + i, row) for i in range(w)]


def door_at(cell, side):
    """The middle of a cell's edge on [side], in cells."""
    cx, cz = cell
    return {"n": [cx + 0.5, cz], "s": [cx + 0.5, cz + 1], "w": [cx, cz + 0.5], "e": [cx + 1, cz + 0.5]}[side]


def grow(rng, n, lobby_name, names, corridor_names, stair_names):
    p = plan(n)
    g = Grower(rng)

    # The start room. Level 1's is the lobby: the biggest room in the game, lit, where everybody
    # arrives and talks before anybody goes through a door.
    if n == 1:
        g.put(lobby_name, "room", 0, 0, 6, 6, 0, None)["light"] = 0.8
    else:
        g.put("Landing", "room", 0, 0, 4, 2, 0, None)["light"] = 0.45

    pool = names[:]
    rng.shuffle(pool)
    counts = {"stair": 0}

    def name_for(kind):
        if kind == "stair":
            counts["stair"] += 1
            return stair_names[(counts["stair"] - 1) % len(stair_names)]
        if kind == "corridor":
            return rng.choice(corridor_names)
        return pool[len(g.rooms) % len(pool)]

    def attempt(parent, kind):
        """One try at a room of [kind] through one of [parent]'s walls. The room, or None."""
        edges = g.edges_out(parent)
        if not edges:
            return None
        cell, side, o, floor = rng.choice(edges)
        extra = None
        if kind == "stair":
            if floor + 1 >= p["floors"]:
                return None
            # Its foot is the cell beyond the door. Mostly it climbs alongside the wall it is
            # entered through, so its head is beside the house and a room upstairs has a floor
            # under it; otherwise it climbs straight away from the door.
            up = rng.choice("ns" if side in "ew" else "ew") if rng.random() < 0.7 else side
            w, d = (4, 2) if up in "ew" else (2, 4)
            if up == "e":
                x = o[0]
            elif up == "w":
                x = o[0] - 3
            else:
                x = o[0] if side == "e" else (o[0] - 1 if side == "w" else o[0] - rng.randint(0, 1))
            if up == "s":
                z = o[1]
            elif up == "n":
                z = o[1] - 3
            else:
                z = o[1] if side == "s" else (o[1] - 1 if side == "n" else o[1] - rng.randint(0, 1))
            extra = {"up": up}
            floors = 2
        else:
            if kind == "corridor":
                length = rng.choice([3, 4, 5, 6])
                w, d = (length, 1) if rng.random() < 0.5 else (1, length)
            else:
                # Upstairs has the smaller rooms too: bedrooms over the big rooms below.
                w, d = rng.choice(ROOM_SHAPES + ([(2, 3), (3, 2), (2, 2), (3, 3)] if floor > 0 else []))
            # Any placement that puts cell o inside the new room, against the wall it is beside.
            if side == "e":
                x, z = o[0], o[1] - rng.randint(0, d - 1)
            elif side == "w":
                x, z = o[0] - w + 1, o[1] - rng.randint(0, d - 1)
            elif side == "s":
                x, z = o[0] - rng.randint(0, w - 1), o[1]
            else:
                x, z = o[0] - rng.randint(0, w - 1), o[1] - d + 1
            floors = 1
        if not g.fits(x, z, w, d, floor, floors):
            return None
        room = g.put(name_for(kind), kind, x, z, w, d, floor, parent["id"], extra)
        # A lamp in one room in five: somewhere to catch your breath, and somewhere you are seen.
        if kind == "room" and rng.random() < 0.2:
            room["light"] = 0.35
        room["door"] = {"at": door_at(cell, side), "floor": floor}
        return room

    def remove_last():
        room = g.rooms.pop()
        del g.by_id[room["id"]]
        for key in [k for k, v in g.occupied.items() if v == room["id"]]:
            del g.occupied[key]
        if room["kind"] == "stair":
            counts["stair"] -= 1

    def grow_from(parent, kind):
        """One try; a stairwell only with a room off its head, or not at all."""
        room = attempt(parent, kind)
        if room is None or kind != "stair":
            return room
        for _ in range(400):
            if attempt(room, "room" if rng.random() < 0.7 else "corridor") is not None:
                return room
        remove_last()
        return None

    def pick_kind(parent):
        return "corridor" if parent["kind"] != "corridor" and rng.random() < 0.3 else "room"

    if p["floors"] > 2:
        return grow_floors(g, rng, p, name_for, grow_from, pick_kind)

    # The ground floor first, then upstairs: a third of the house, over the ground floor, up
    # one stairwell or more. Grown in that order the tree goes up the stairs late, so a level is
    # the ground floor searched, then upstairs, then back down to the way out on the ground.
    upstairs_target = 0 if p["floors"] < 2 else p["rooms"] // 3
    ground_target = p["rooms"] - upstairs_target
    tries = 0

    while len(g.rooms) < ground_target and tries < 20000:
        tries += 1
        recent = g.rooms[max(0, len(g.rooms) - 5):]
        parent = rng.choice(recent) if rng.random() < 0.6 else rng.choice(g.rooms)
        grow_from(parent, pick_kind(parent))

    tries = 0
    while len(g.rooms) < p["rooms"] and tries < 20000:
        tries += 1
        upstairs = [r for r in g.rooms if r["floor"] > 0 or r["kind"] == "stair"]
        ground = [r for r in g.rooms if r["floor"] == 0 and r["kind"] != "stair"]
        if len(upstairs) < upstairs_target + 1 and (not upstairs or rng.random() < 0.03):
            # Another way up: from any room on the ground floor.
            grow_from(rng.choice(ground), "stair")
        elif upstairs and tries < 15000:
            recent = upstairs[max(0, len(upstairs) - 4):]
            parent = rng.choice(recent) if rng.random() < 0.6 else rng.choice(upstairs)
            grow_from(parent, pick_kind(parent))
        else:
            # Upstairs is full: what is left grows on the ground floor.
            parent = rng.choice(ground)
            grow_from(parent, pick_kind(parent))

    return g


def grow_floors(g, rng, p, name_for, grow_from, pick_kind):
    """The house on three floors or more: the ground floor, then each floor in turn over the one
    below, each up its own stairwell from the floor under it.

    A stairwell up from floor 1 needs ground under all eight of its cells (nothing hangs in the
    air) and two free storeys over them, beside a room on floor 1 it is entered from. Grown the
    two-floor way (a third of the house upstairs, stairwells tried at random throughout), floor
    1 had covered nearly all the ground by the time one was tried, and almost none fitted. So
    here a floor is finished before the one above it is started, floor 1 is only a quarter of
    the house (ground with nothing over it is left round its edges for the next stairwell), and
    a stairwell to floor f is tried from a room on floor f-1 or from the head of a stairwell up
    to f-1: off a head, the next one can run back alongside the first, over the room the first
    was entered from (a stair tower). Two-floor levels keep the old order (grow()), so their
    houses are what they were.

    Floor 1 is a quarter of the house and each floor above an eighth, at least three rooms;
    level() refuses a top floor with fewer than three."""
    floors = p["floors"]
    targets = {f: (p["rooms"] // 4 if f == 1 else max(3, p["rooms"] // 8)) for f in range(1, floors)}
    ground_target = p["rooms"] - sum(targets.values())

    tries = 0
    while len(g.rooms) < ground_target and tries < 20000:
        tries += 1
        recent = g.rooms[max(0, len(g.rooms) - 5):]
        parent = rng.choice(recent) if rng.random() < 0.6 else rng.choice(g.rooms)
        grow_from(parent, pick_kind(parent))

    for f in range(1, floors):
        def on_floor():
            # The rooms of floor f and the stairwells up to it (their heads are on it).
            return [r for r in g.rooms if (r["kind"] == "stair" and r["floor"] == f - 1)
                    or (r["kind"] != "stair" and r["floor"] == f)]

        def below():
            return [r for r in g.rooms if (r["kind"] == "stair" and r["floor"] == f - 2)
                    or (r["kind"] != "stair" and r["floor"] == f - 1)]

        tries = 0
        while tries < 20000:
            tries += 1
            here = on_floor()
            if len([r for r in here if r["kind"] != "stair"]) >= targets[f]:
                break
            stairs = [r for r in here if r["kind"] == "stair"]
            if not stairs or (len(stairs) < 2 and rng.random() < 0.03):
                grow_from(rng.choice(below()), "stair")
            elif tries < 15000:
                rooms_here = [r for r in here if r["kind"] != "stair"] or stairs
                recent = rooms_here[max(0, len(rooms_here) - 4):]
                parent = rng.choice(recent) if rng.random() < 0.6 else rng.choice(here)
                # Only rooms on this floor grow here: a stairwell up from it waits for the next.
                kind = pick_kind(parent)
                grow_from(parent, kind)
            else:
                break

    # Whatever is left grows on the ground floor.
    tries = 0
    while len(g.rooms) < p["rooms"] and tries < 20000:
        tries += 1
        ground = [r for r in g.rooms if r["floor"] == 0 and r["kind"] != "stair"]
        parent = rng.choice(ground)
        grow_from(parent, pick_kind(parent))
    return g


def level(n, seed_base, level_names, lobby_name, total, prefix, names, corridor_names, stair_names):
    p = plan(n)
    # A level is grown until it has what its plan asks for: a stairwell where it has floors to
    # climb, a corridor long enough to see her down, and a way out. The seed walks on from the
    # level's own, so every machine grows the same house.
    for attempt in range(200):
        rng = random.Random((seed_base + n) * 1000 + attempt)
        g = grow(rng, n, lobby_name, names, corridor_names, stair_names)
        if len(g.rooms) < p["rooms"]:
            continue
        if p["floors"] > 1 and not any(r["kind"] == "stair" for r in g.rooms):
            continue
        # Every floor the plan asks for is there, and the top one is somewhere to search: three
        # rooms at least, not one attic at the head of a stairwell.
        if top_floor(g) < p["floors"] - 1 or (p["floors"] > 2 and rooms_on(g, p["floors"] - 1) < 3):
            continue
        if not glimpse_corridors(g):
            continue
        if exit_of(g) is None:
            continue
        doc = furnish_puzzles(rng, g, n, p, level_names, total, prefix)
        if solve(doc) and len(compact(doc)) <= MAX_BYTES:
            return doc
    raise SystemExit("level %d of %s: no house grew that fits its plan" % (n, prefix))


def top_floor(g):
    """The highest floor with a room on it."""
    return max(r["floor"] for r in g.rooms if r["kind"] != "stair")


def rooms_on(g, floor):
    """How many rooms (not stairwells) are on [floor]."""
    return sum(1 for r in g.rooms if r["kind"] != "stair" and r["floor"] == floor)


def glimpse_corridors(g):
    """Corridors long enough that the far end is a distance from the door into them."""
    out = []
    for room in g.rooms:
        if room["kind"] != "corridor" or room["parent"] is None:
            continue
        at = room["door"]["at"]
        far = far_end(room, at)
        if far is None:
            continue
        dist = ((far[0] - at[0]) ** 2 + (far[1] - at[1]) ** 2) ** 0.5 * CELL
        if dist >= 8.0:
            out.append((room, far))
    return out


def far_end(room, at):
    """The point in a corridor furthest along it from where you came in, in cells."""
    x, z, w, d = room["x"], room["z"], room["w"], room["d"]
    if w > d:
        mid = x + w / 2.0
        return [x + w - 0.6 if at[0] < mid else x + 0.6, z + 0.5]
    if d > w:
        mid = z + d / 2.0
        return [x + 0.5, z + d - 0.6 if at[1] < mid else z + 0.6]
    return None


def exit_of(g):
    """The way out: on the ground floor, in the deepest room with an outside wall, the cell edge
    whose outside is nothing at all."""
    best = None
    for room in g.rooms:
        if room["floor"] != 0 or room["kind"] == "stair" or room["spawn"]:
            continue
        own = set(g.cells(room["x"], room["z"], room["w"], room["d"]))
        for c in sorted(own):
            for side in "nesw":
                dx, dz = DIRS[side]
                o = (c[0] + dx, c[1] + dz)
                if o in own or (o[0], o[1], 0) in g.occupied:
                    continue
                key = (room["depth"], room["kind"] == "room", -int(room["id"][1:]))
                if best is None or key > best[0]:
                    best = (key, room, c, side)
                break
            else:
                continue
            break
    return None if best is None else (best[1], best[2], best[3])


def furnish_puzzles(rng, g, n, p, level_names, total, prefix):
    rooms = g.rooms
    doors, items, stations, steps, events = [], [], [], [], []
    colours = COLOURS[:]
    rng.shuffle(colours)
    reachable = [rooms[0]["id"]]
    by_id = g.by_id

    def placeable(rid):
        return by_id[rid]["kind"] != "stair"

    def spot(rid):
        room = by_id[rid]
        if room["kind"] == "corridor":
            # Down the middle of a corridor, never in a doorway at its end.
            along = round(rng.uniform(0.25, 0.75), 2)
            return [along, 0.5] if room["w"] > room["d"] else [0.5, along]
        return [round(rng.uniform(0.2, 0.8), 2), round(rng.uniform(0.2, 0.8), 2)]

    def far_room():
        # Later levels put the parts further from where they are needed: never the newest few
        # rooms, and more often an old one.
        pool = [r for r in reachable if placeable(r)]
        keep = max(1, len(pool) - (n // 6))
        pool = pool[:keep]
        if rng.random() < 0.55:
            return rng.choice(pool[-8:])
        return rng.choice(pool)

    def place_item(item, label):
        """An item in a room, or now and then in a chest whose small key is somewhere else."""
        if rng.random() < p["chest"]:
            k = len(stations)
            small = "smallkey_%d" % k
            chest = "chest_%d" % k
            room = far_room()
            items.append({"id": small, "name": "Small key", "kind": "smallkey", "room": room, "at": spot(room)})
            room = far_room()
            # What it gives is named, so "you need the red key" can say so when the key is in here.
            stations.append({"id": chest, "name": "Chest", "kind": "chest", "room": room, "at": spot(room), "needs": small,
                             "gives": item["id"], "gives_name": item["name"], "opens": "", "consumes": True, "verb": "Unlock the chest"})
            steps.append({"text": "Find the small key to a chest", "when": {"holds": small}})
            steps.append({"text": "Open the chest: %s is inside" % label, "when": {"used": chest}})
            return
        item["room"] = far_room()
        item["at"] = spot(item["room"])
        items.append(item)

    kinds = ["key", "key", "lever", "crowbar", "fuse", "bucket", "code", "vent"]

    for room in rooms[1:]:
        did = "d%d" % len(doors)
        door = {"id": did, "a": room["parent"], "b": room["id"], "at": [float(v) for v in room["door"]["at"]],
                "floor": room["door"]["floor"], "lock": "", "label": "Door", "colour": "brown"}
        # The first door of level 1 is open: the lobby is a lobby, and the game starts past it.
        open_odds = {"room": 0.45, "corridor": 0.65, "stair": 0.5}[room["kind"]]
        if n == 1 and len(doors) == 0:
            kind = "open"
        elif rng.random() < open_odds:
            kind = "open"
        else:
            kind = rng.choice(kinds[: p["kinds"]])
        # Eight colours of key, each one door's: past that, a second "black key" for a second
        # "black door" is a puzzle that reads as a mistake, so it is another kind of lock.
        if kind == "key" and not colours:
            kind = rng.choice([k for k in kinds[: p["kinds"]] if k != "key"])

        if kind == "key":
            colour = colours.pop(0)
            item = {"id": "key_%s_%d" % (colour, len(doors)), "name": "%s key" % colour.capitalize(), "kind": "key", "colour": colour}
            steps.append({"text": "Find the %s key" % colour, "when": {"holds": item["id"]}})
            place_item(item, "the %s key" % colour)
            door.update({"lock": item["id"], "label": "%s door" % colour.capitalize(), "colour": colour})
            steps.append({"text": "Open the %s door" % colour, "when": {"opened": did}})
        elif kind == "crowbar":
            item = {"id": "crowbar_%d" % len(doors), "name": "Crowbar", "kind": "crowbar"}
            steps.append({"text": "Find something to pry the boards off", "when": {"holds": item["id"]}})
            place_item(item, "a crowbar")
            door.update({"lock": item["id"], "label": "Boarded door", "colour": "wood"})
            steps.append({"text": "Pry the boarded door open", "when": {"opened": did}})
        elif kind == "code":
            code = "%04d" % rng.randint(0, 9999)
            item = {"id": "note_%d" % len(doors), "name": "Note: %s" % code, "kind": "note"}
            steps.append({"text": "Find the keypad's code", "when": {"holds": item["id"]}})
            place_item(item, "a note")
            door.update({"lock": item["id"], "label": "Keypad door", "colour": "steel"})
            steps.append({"text": "Enter the code at the keypad door", "when": {"opened": did}})
        elif kind == "lever":
            sid = "lever_%d" % len(doors)
            r = far_room()
            stations.append({"id": sid, "name": "Lever", "kind": "lever", "room": r, "at": spot(r), "needs": "", "gives": "", "opens": did, "verb": "Pull the lever"})
            door.update({"lock": "@" + sid, "label": "Gate", "colour": "iron"})
            steps.append({"text": "Find the lever that opens the gate", "when": {"used": sid}})
        elif kind == "fuse":
            item = {"id": "fuse_%d" % len(doors), "name": "Fuse", "kind": "fuse"}
            sid = "fusebox_%d" % len(doors)
            steps.append({"text": "Find a fuse", "when": {"holds": item["id"]}})
            place_item(item, "a fuse")
            r = far_room()
            stations.append({"id": sid, "name": "Fuse box", "kind": "fusebox", "room": r, "at": spot(r), "needs": item["id"], "gives": "", "opens": did, "consumes": True, "verb": "Fit the fuse"})
            door.update({"lock": "@" + sid, "label": "Electric gate", "colour": "steel"})
            steps.append({"text": "Fit it in the fuse box", "when": {"used": sid}})
        elif kind == "bucket":
            bucket = {"id": "bucket_%d" % len(doors), "name": "Bucket", "kind": "bucket"}
            water = "water_%d" % len(doors)
            tap = "tap_%d" % len(doors)
            fire = "fire_%d" % len(doors)
            steps.append({"text": "Find a bucket", "when": {"holds": bucket["id"]}})
            place_item(bucket, "a bucket")
            r = far_room()
            stations.append({"id": tap, "name": "Tap", "kind": "tap", "room": r, "at": spot(r), "needs": bucket["id"], "gives": water, "consumes": True, "verb": "Fill the bucket"})
            # The fire burns in front of its door, on the near side.
            stations.append({"id": fire, "name": "Fire", "kind": "fire", "room": room["parent"], "door": did, "needs": water, "gives": bucket["id"], "opens": did, "consumes": True, "verb": "Put out the fire"})
            door.update({"lock": "@" + fire, "label": "Door behind the fire", "colour": "brown"})
            steps.append({"text": "Fill it with water", "when": {"holds": water}})
            steps.append({"text": "Put out the fire", "when": {"used": fire}})
        elif kind == "vent":
            driver = {"id": "screwdriver_%d" % len(doors), "name": "Screwdriver", "kind": "screwdriver"}
            key = "key_vent_%d" % len(doors)
            vent = "vent_%d" % len(doors)
            steps.append({"text": "Find a screwdriver", "when": {"holds": driver["id"]}})
            place_item(driver, "a screwdriver")
            r = far_room()
            stations.append({"id": vent, "name": "Vent", "kind": "vent", "room": r, "at": spot(r), "needs": driver["id"], "gives": key, "consumes": False, "verb": "Unscrew the vent"})
            door.update({"lock": key, "label": "Locked door", "colour": "brown"})
            steps.append({"text": "Something is behind a vent", "when": {"holds": key}})
            steps.append({"text": "Open the locked door", "when": {"opened": did}})

        doors.append(door)
        reachable.append(room["id"])

    # The way out: a door on the outer wall of the deepest room on the ground floor, locked
    # behind the gold key, which is somewhere in the house.
    last, cell, side = exit_of(g)
    gold = {"id": "key_gold", "name": "Gold key", "kind": "key", "colour": "gold"}
    steps.append({"text": "Find the gold key", "when": {"holds": gold["id"]}})
    place_item(gold, "the gold key")
    doors.append({"id": "exit", "a": last["id"], "b": "", "side": side, "at": [float(v) for v in door_at(cell, side)],
                  "floor": 0, "lock": gold["id"], "label": "The way out", "colour": "gold", "exit": True})
    steps.append({"text": "Get out", "when": {"opened": "exit"}})

    events.extend(make_events(rng, g, n, p, doors, items))

    witches = []
    for k in range(p["witches"]):
        path = patrol(rng, rooms, doors)
        if path:
            witches.append({"path": path, "speed": round(1.5 + 0.05 * n + 0.1 * (k % 6), 2),
                            "sight": round(8.0 + 0.35 * n, 2), "cone": round(min(70.0 + 1.2 * n, 120.0), 1)})

    out_rooms = []
    for room in rooms:
        r = {"id": room["id"], "name": room["name"], "kind": room["kind"], "x": room["x"], "z": room["z"],
             "w": room["w"], "d": room["d"], "floor": room["floor"], "spawn": room["spawn"], "light": float(room["light"])}
        if room["kind"] == "stair":
            r["up"] = room["up"]
        out_rooms.append(r)

    return {
        "format": FORMAT, "kind": "level", "id": "%s_%02d" % (prefix, n), "number": n,
        "name": level_names[n - 1], "author": "mg-look-at-me",
        "blurb": "Level %d of %d." % (n, total),
        "cell": CELL, "height": HEIGHT, "storey": STOREY,
        "rooms": out_rooms, "doors": doors, "items": items, "stations": stations,
        "steps": steps, "events": events, "witches": witches,
    }


def make_events(rng, g, n, p, doors, items):
    """What the house does to you: lights that die, doors that slam, her at a distance."""
    events = []
    by_id = g.by_id

    # The lights die in a room as you take what you came for. The room is lit for it: a lamp
    # going out is only a fright where there was one.
    loose = [i for i in items if not by_id[i["room"]]["spawn"] and by_id[i["room"]]["kind"] == "room"]
    rng.shuffle(loose)
    used_rooms = set()
    for item in loose:
        if len([e for e in events if e["do"] == "lights"]) >= p["lights"]:
            break
        if item["room"] in used_rooms:
            continue
        used_rooms.add(item["room"])
        by_id[item["room"]]["light"] = max(by_id[item["room"]]["light"], 0.35)
        events.append({"id": "ev%d" % len(events), "when": {"holds": item["id"]}, "do": "lights",
                       "rooms": [item["room"]], "text": "The lights die"})

    # A door slams behind you as you go on. Only one you can open again from the other side:
    # unlocked, or locked with something you still hold (nothing that opens a door is used up).
    slammable = [d for d in doors if not d.get("exit") and not d["lock"].startswith("@") and by_id[d["b"]]["kind"] != "stair"]
    rng.shuffle(slammable)
    for door in slammable[: p["slams"]]:
        events.append({"id": "ev%d" % len(events), "when": {"entered": door["b"]}, "do": "slam",
                       "door": door["id"], "text": "A door slams behind you"})

    # At the far end of a long corridor she stands, looking back at you, and is gone.
    glimpses = glimpse_corridors(g)
    rng.shuffle(glimpses)
    for room, far in glimpses[: p["glimpses"]]:
        w, d = room["w"], room["d"]
        at = [round((far[0] - room["x"]) / w, 3), round((far[1] - room["z"]) / d, 3)]
        events.append({"id": "ev%d" % len(events), "when": {"entered": room["id"]}, "do": "glimpse",
                       "room": room["id"], "at": at, "look": [float(v) for v in room["door"]["at"]], "seconds": 2.5, "text": ""})

    return events


def patrol(rng, rooms, doors):
    """An out-and-back walk along the room tree, never into a start room: start rooms are safe.

    Points are rooms and door centres, so a witch walks through doorways and never through a
    wall; the game walks her up a stairwell's ramp (LmLevel._witch_loop)."""
    by_id = {r["id"]: r for r in rooms}
    links = {}
    for door in doors:
        if door.get("exit"):
            continue
        links.setdefault(door["a"], []).append((door["b"], door))
        links.setdefault(door["b"], []).append((door["a"], door))
    candidates = [r["id"] for r in rooms if not r["spawn"] and r["kind"] != "stair"]
    if len(candidates) < 2:
        return []
    # Start where there is somewhere to walk to: a witch circling the corners of one dead-end
    # room is a witch nobody meets (level 1's sat in the Larder behind the red door, and the
    # first play test saw no witch in 36 s). Now she walks between the rooms you search.
    walkable = [c for c in candidates if any(not by_id[b]["spawn"] for (b, _d) in links.get(c, []))]
    here = rng.choice(walkable or candidates)
    route = [here]
    seen = {here}
    for _ in range(rng.randint(3, 8)):
        options = [(b, d) for (b, d) in links.get(route[-1], []) if b not in seen and not by_id[b]["spawn"]]
        if not options:
            break
        nxt, door = rng.choice(options)
        route.append(("door", door["id"]))
        route.append(nxt)
        seen.add(nxt)
    rooms_only = [pt for pt in route if isinstance(pt, str)]
    if len(rooms_only) < 2:
        # Nowhere to walk to: round the inside of the one room, corner to corner.
        return [["at", here, 0.2, 0.2], ["at", here, 0.8, 0.2], ["at", here, 0.8, 0.8], ["at", here, 0.2, 0.8]]
    back = list(reversed(route))[1:-1]
    out = []
    for point in route + back:
        if isinstance(point, tuple):
            out.append(["door", point[1]])
        else:
            out.append(["room", point])
    return out


def solve(doc):
    """Plays a level's logic: opens what can be opened with what can be reached, until nothing
    changes. True when the way out opens and every room is reachable. Events are checked to
    name what is there, and a slam to be a door that opens again."""
    rooms = {r["id"] for r in doc["rooms"]}
    doors = {d["id"]: d for d in doc["doors"]}
    start = [r["id"] for r in doc["rooms"] if r["spawn"]][0]
    reach = {start}
    holds, used, opened = set(), set(), set()
    changed = True
    while changed:
        changed = False
        for item in doc["items"]:
            if item["room"] in reach and item["id"] not in holds:
                holds.add(item["id"])
                changed = True
        for st in doc["stations"]:
            room = st.get("room")
            if room in reach and st["id"] not in used and (st["needs"] == "" or st["needs"] in holds):
                used.add(st["id"])
                if st.get("gives"):
                    holds.add(st["gives"])
                if st.get("opens"):
                    opened.add(st["opens"])
                changed = True
        for door in doc["doors"]:
            if door["id"] in opened:
                pass
            elif door["a"] in reach and (door["lock"] == "" or door["lock"] in holds):
                opened.add(door["id"])
                changed = True
            else:
                continue
            if door.get("b") and door["b"] not in reach and door["a"] in reach:
                reach.add(door["b"])
                changed = True
    if not ("exit" in opened and reach == rooms):
        return False
    consumed = {st["needs"] for st in doc["stations"] if st.get("consumes")}
    for ev in doc.get("events", []):
        when = ev["when"]
        if "entered" in when and when["entered"] not in rooms:
            return False
        if ev["do"] == "slam":
            door = doors.get(ev["door"])
            if door is None or door["lock"].startswith("@") or door["lock"] in consumed:
                return False
        if ev["do"] == "lights" and not set(ev["rooms"]) <= rooms:
            return False
    return True


def compact(doc):
    return json.dumps(doc, separators=(",", ":"))


def text_of(doc):
    return json.dumps(doc, indent="\t") + "\n"


def stats_line(doc):
    cell = doc["cell"]
    area = sum(r["w"] * r["d"] * cell * cell * (2 if r.get("kind") == "stair" else 1) for r in doc["rooms"])
    floors = len({r.get("floor", 0) for r in doc["rooms"]} | {r["floor"] + 1 for r in doc["rooms"] if r.get("kind") == "stair"})
    kinds = {}
    for ev in doc.get("events", []):
        kinds[ev["do"]] = kinds.get(ev["do"], 0) + 1
    return "%-10s rooms %2d  area %5d m2  floors %d  doors %2d (%2d locked)  steps %3d  events %s  witches %2d  %5d bytes" % (
        doc["id"], len(doc["rooms"]), area, floors, len(doc["doors"]), sum(1 for d in doc["doors"] if d["lock"]),
        len(doc["steps"]), ",".join("%s %d" % kv for kv in sorted(kinds.items())), len(doc["witches"]), len(compact(doc)))


def main():
    check = "--check" in sys.argv
    stats = "--stats" in sys.argv
    stale, broken = [], []
    written = 0

    for house_id, (directory, total, seed_base, level_names, lobby_name, title, names, corridors, stairs) in HOUSES.items():
        out = os.path.join(HERE, "..", directory)
        os.makedirs(out, exist_ok=True)
        prefix = "lm" if house_id == "house" else house_id
        meta = os.path.join(out, "house.json")
        meta_text = json.dumps({"kind": "house", "id": house_id, "name": title}, indent="\t") + "\n"
        if check:
            if not os.path.exists(meta) or open(meta).read() != meta_text:
                stale.append(house_id + "/house.json")
        elif not stats:
            with open(meta, "w") as f:
                f.write(meta_text)

        for n in range(1, total + 1):
            doc = level(n, seed_base, level_names, lobby_name, total, prefix, names, corridors, stairs)
            if not solve(doc):
                broken.append(doc["id"])
            if stats:
                print(stats_line(doc))
                continue
            path = os.path.join(out, doc["id"] + ".json")
            text = text_of(doc)
            if check:
                if not os.path.exists(path) or open(path).read() != text:
                    stale.append(doc["id"])
                continue
            with open(path, "w") as f:
                f.write(text)
            written += 1

    if broken:
        print("cannot be finished:", ", ".join(broken))
        return 1
    if check and stale:
        print("not what tools/build_levels.py writes:", ", ".join(stale))
        return 1
    if not check and not stats:
        print("wrote %d levels in %d houses, every one finishable" % (written, len(HOUSES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
