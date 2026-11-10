#!/usr/bin/env python3
"""The builder's laid-out houses below the ground floor: python3 tools/test_build_levels.py"""
import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_levels as bl  # noqa: E402

# A lobby and a hall on the ground, a stairwell down from the hall (foot on -1, head on 0) and
# three rooms under the ground at its foot.
CELLAR = {"name": "Cellar test", "rooms": [
    {"name": "Lobby", "kind": "room", "x": 0, "z": 0, "w": 3, "d": 3},
    {"name": "Hall", "kind": "room", "x": 3, "z": 0, "w": 3, "d": 3},
    {"name": "Kitchen", "kind": "room", "x": 0, "z": 3, "w": 3, "d": 3},
    {"name": "Parlour", "kind": "room", "x": 3, "z": 3, "w": 3, "d": 3},
    {"name": "Cellar Stair", "kind": "stair", "up": "w", "x": 6, "z": 0, "w": 4, "d": 1, "floor": -1, "from": "Hall"},
    {"name": "Wine Cellar", "kind": "room", "x": 10, "z": 0, "w": 3, "d": 3, "floor": -1},
    {"name": "Coal Cellar", "kind": "room", "x": 10, "z": 3, "w": 3, "d": 3, "floor": -1},
    {"name": "Cold Store", "kind": "room", "x": 13, "z": 0, "w": 2, "d": 3, "floor": -1},
]}


class Cellar(unittest.TestCase):
    def test_layout_grower_joins_a_cellar(self):
        g = bl.layout_grower(random.Random(1), CELLAR)
        by_name = {r["name"]: r for r in g.rooms}
        self.assertEqual(len(g.rooms), len(CELLAR["rooms"]))
        stair = by_name["Cellar Stair"]
        self.assertEqual((stair["floor"], stair["door"]["floor"]), (-1, 0))
        self.assertEqual(by_name["Wine Cellar"]["door"]["floor"], -1)
        self.assertIn((6, 0, 0), g.occupied)

    def test_the_way_out_is_on_the_ground(self):
        g = bl.layout_grower(random.Random(1), CELLAR)
        room, cell, side = bl.exit_of(g)
        self.assertEqual(room["floor"], 0)
        dx, dz = bl.DIRS[side]
        self.assertNotIn((cell[0] + dx, cell[1] + dz, 0), g.occupied)

    def test_a_cellar_deals_and_proves(self):
        doc = bl.deal_layout(CELLAR, 3, 6, bl.plan(6), ["Cellar test"] * 6, 1, "cellar", one_level=True, glimpse=False)
        self.assertIsNotNone(doc)
        floor_of = {r["id"]: r["floor"] for r in doc["rooms"]}
        self.assertEqual(floor_of[[d for d in doc["doors"] if d.get("exit")][0]["a"]], 0)
        # Three rooms down there: something to find or use is down there too.
        used = [t for t in doc["items"] + doc["stations"] if t.get("room") and floor_of[t["room"]] < 0]
        self.assertTrue(used)
        self.assertEqual(bl.floors_without_parts(doc), [])

    def test_a_laid_out_lock_is_the_one_dealt(self):
        rooms = [dict(r, lock="switch") if r["name"] == "Cold Store" else r for r in CELLAR["rooms"]]
        doc = bl.deal_layout(dict(CELLAR, rooms=rooms), 3, 6, bl.plan(6), ["Cellar test"] * 6, 1, "cellar", one_level=True, glimpse=False)
        self.assertIsNotNone(doc)
        store = [r["id"] for r in doc["rooms"] if r["name"] == "Cold Store"][0]
        door = [d for d in doc["doors"] if d["b"] == store][0]
        switch = [s for s in doc["stations"] if s["kind"] == "switch"][0]
        self.assertEqual((door["lock"], switch["opens"]), ("@" + switch["id"], door["id"]))
        bad = dict(CELLAR, rooms=[dict(r, lock="magic") if r["name"] == "Cold Store" else r for r in CELLAR["rooms"]])
        with self.assertRaises(SystemExit):
            bl.layout_grower(random.Random(1), bad)

    def test_overlap_below_is_refused(self):
        bad = dict(CELLAR, rooms=CELLAR["rooms"] + [{"name": "Crypt", "kind": "room", "x": 10, "z": 0, "w": 1, "d": 1, "floor": -1}])
        with self.assertRaises(SystemExit):
            bl.layout_grower(random.Random(1), bad)


if __name__ == "__main__":
    unittest.main()
