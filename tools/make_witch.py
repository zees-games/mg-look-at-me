"""Builds assets/witch/witch.glb and witch_atlas.png: the scary witch, rigged and animated.

    blender -b -P tools/make_witch.py -- <Witch.glb from Sketchfab> assets/witch/witch.glb [--stage=N] [--keep=path.blend]

Source: "Witch" by Tamko Dmitry, https://sketchfab.com/3d-models/witch-0b6f69bbaa864bd78c0cfa98dabca0aa,
CC Attribution 4.0: one static mesh of a fat hooded woman with a staff and bottles. This script
  1. drops the staff and the bottles and makes her gaunt (narrow, flat bellied, long legged),
  2. adds a tattered hem and cloak edge and black hollow eye sockets,
  3. rigs her (bones weighted by distance, the mesh is not watertight), hunches her by posing the
     rig and keeping the pose as the rest pose, lengthens the arms and curls the fingers into claws,
  4. paints a new atlas (witch_atlas.png, the one texture the game draws her with): every texel is
     traced back to the point on the body it covers, and coloured by what that part is (wool cloak,
     oxblood robe, pallid skin, linen leg wraps, leather belt, hair) with layered hue noise, folds,
     seams, patches, wear and a mud-dark hem; the source texture gives only the fine detail,
  5. scales her so the top of the hood is 2.2 m (the game's HEIGHT) and keys idle, walk,
     attack_idle (the reach) and attack (the lunge) for game/lm_witch.gd, at 24 frames a second.
Facing +Z in the file (Blender -Y); the head bone is "Head", the eye sockets' centres are the bones
"Eye.L" and "Eye.R" (the game lights her eyes on them).
--stage=N stops after step N and saves /tmp/wl/stage.blend.
"""
import bpy, bmesh, sys, math, random, os
from mathutils import Vector, Matrix, Euler, Quaternion

argv = sys.argv[sys.argv.index("--") + 1:]
SRC, DST = argv[0], argv[1]
STAGE = next((int(a.split("=")[1]) for a in argv if a.startswith("--stage=")), 9)
HEIGHT = 2.2
rng = random.Random(7)
d = math.radians


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def stop(n):
    if STAGE == n:
        bpy.ops.wm.save_as_mainfile(filepath="/tmp/wl/stage.blend")
        sys.exit(0)


bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
body = [o for o in bpy.data.objects if o.type == "MESH"][0]
mw = body.matrix_world.copy()
body.parent = None
body.data.transform(mw)
body.matrix_world = Matrix.Identity(4)
for o in list(bpy.data.objects):
    if o != body:
        bpy.data.objects.remove(o)
body.name = "Witch"

# the base colour image, before the material is rebuilt
mat0 = body.data.materials[0]
base_img = None
for n in mat0.node_tree.nodes:
    if n.type == "BSDF_PRINCIPLED":
        l = n.inputs["Base Color"].links
        while l and l[0].from_node.type != "TEX_IMAGE":
            nn = l[0].from_node
            l = [i for i in nn.inputs if i.links][0].links if any(i.links for i in nn.inputs) else []
        base_img = l[0].from_node.image if l else None
assert base_img is not None, "no base colour image"


def islands(bm):
    seen, res = set(), []
    for v in bm.verts:
        if v.index in seen:
            continue
        st, comp = [v], []
        seen.add(v.index)
        while st:
            x = st.pop()
            comp.append(x)
            for e in x.link_edges:
                w = e.other_vert(x)
                if w.index not in seen:
                    seen.add(w.index)
                    st.append(w)
        res.append(comp)
    return res


bm = bmesh.new()
bm.from_mesh(body.data)
bm.verts.ensure_lookup_table()
comps = islands(bm)
assert len(comps) == 50 and len(bm.verts) == 3488, "not the Sketchfab witch this script was written for"
DROP = [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 34, 35, 36, 37, 38, 39, 40, 47, 48, 49]
# What each kept island is, for the painter (step 4): the source's islands by index.
ROBE, CLOAK, HOODIN, SKIN, MOUTH, WRAPS, FEET, BELT, STRANDS, HAIR, SOCKET, FACE = range(1, 13)
KIND = {0: CLOAK, 1: ROBE, 2: ROBE, 3: WRAPS, 28: WRAPS, 4: FEET, 29: FEET, 5: SKIN, 30: SKIN, 6: SKIN, 31: SKIN,
        7: HOODIN, 8: BELT, 9: SOCKET, 10: SOCKET, 32: FACE, 33: MOUTH, 41: STRANDS, 42: STRANDS, 43: STRANDS,
        44: STRANDS, 45: STRANDS, 46: STRANDS}
kind_l = bm.faces.layers.int.new("kind")
for k, comp in enumerate(comps):
    for f in {f for v in comp for f in v.link_faces}:
        f[kind_l] = KIND.get(k, 0)
# The source's eyeballs, whose centres are where the sockets and the glowing eyes go.
EYE_SRC = [sum((v.co for v in comps[k]), Vector()) / len(comps[k]) for k in (9, 10)]


def inflate(vs, by):
    """Fattens thin parts (the fingers) along their normals: in the source they are flat slivers."""
    moved = {v: v.co + v.normal * by for v in vs}
    for v, c in moved.items():
        v.co = c


bm.normal_update()
# Fingers and hands: the left hand hangs at the hip, the right is raised by the face.
inflate([v for k in (5, 6) for v in comps[k] if v.co.z < 12.4], 0.045)
inflate([v for k in (30, 31) for v in comps[k] if (v.co - Vector((-7.1, -1.9, 20.6))).length < 2.0], 0.045)
bmesh.ops.delete(bm, geom=[v for k in DROP for v in comps[k]], context="VERTS")
bm.verts.ensure_lookup_table()
uvl = bm.loops.layers.uv.active


def skin_uv(co_hint):
    """The uv of the nearest vertex to a point: for new geometry that should look like it."""
    best = min(bm.verts, key=lambda v: (v.co - co_hint).length_squared)
    return best.link_loops[0][uvl].uv.copy()


# ---------------------------------------------------------------- 1. gaunt
def fz(z):
    return 1.2 * z if z <= 9.2 else 11.04 + 1.12 * (z - 9.2)


def warp(p):
    x, y, z = p
    k = 0.84 + 0.16 * smooth((z - 20.0) / 3.0)
    if abs(x) < 5.0:
        x *= k
    if z > 22.0 and abs(x - 0.8) < 6.5:
        # the hood's crown in to the head: wider than the shoulders it read as a helmet from behind
        x = 0.8 + (x - 0.8) * (1.0 - 0.14 * smooth((z - 23.5) / 3.5) - 0.22 * smooth((z - 26.0) / 3.0))
    if z > 26.0 and y > -1.5:
        # and a cowl that comes to a slumped point behind the crown, not a round cap
        w = smooth((z - 26.0) / 3.0) * math.exp(-((x - 0.8) / 2.4) ** 2) * smooth((y + 1.5) / 2.5)
        z += 0.6 * w
        y += 1.3 * w
    if 9.0 < z < 24.5 and y < 1.4:
        # flatten the belly and the front of the chest; the hood (z>23) stays
        f = 0.5 + 0.5 * smooth((z - 21.5) / 3.0) + 0.0 * smooth((12.0 - z) / 3.0)
        y = 1.4 + (y - 1.4) * f
    return Vector((x, y, fz(z)))


for v in bm.verts:
    v.co = warp(v.co)
# The cape over the shoulders slopes down off them (level, it was a mushroom cap from behind).
for v in comps[0]:
    out = abs(v.co.x - 0.8) - 3.2
    if out > 0.0:
        v.co.z -= 0.3 * out * smooth((v.co.z - fz(17.0)) / 3.0)

# The hood and cape: one smooth subdivision, so their hems curve instead of running in a few straight
# segments (from behind, the hood's lower edge read as a faceted cone).
print("custom normals", body.data.has_custom_normals, "smooth faces", sum(f.smooth for f in bm.faces), len(bm.faces))
cl = [f for f in bm.faces if f[kind_l] in (CLOAK, HOODIN) and min(v.co.z for v in f.verts) > fz(16.0)]
n0 = len(bm.verts)
bmesh.ops.subdivide_edges(bm, edges=list({e for f in cl for e in f.edges}), cuts=1, smooth=1.0, use_grid_fill=True)
for f in bm.faces:
    f.smooth = True
bm.verts.ensure_lookup_table()
print("hood subdivided", n0, "->", len(bm.verts))

# ---------------------------------------------------------------- 2. tatter, sockets
robe = [v for v in bm.verts if v.co.z > fz(8.0) and v.co.z < fz(12) and abs(v.co.x) < 6]
hem_z = min(v.co.z for v in robe)
# boundary edges of the robe skirt, and of the cloak
shred_edges = []
for e in bm.edges:
    if len(e.link_faces) == 1:
        a, b = e.verts
        mz = (a.co.z + b.co.z) / 2
        if hem_z - 0.1 < mz < hem_z + 0.9 and abs(a.co.x) < 6 and a.co.y * 0 == 0:
            shred_edges.append((a, b, 2.2, e.link_faces[0][kind_l]))
        elif fz(18.5) < mz < fz(22.6) and abs(a.co.x) < 6.5 and a.co.z > fz(17):
            shred_edges.append((a, b, 1.6, e.link_faces[0][kind_l]))
n_shred = 0
for a, b, depth, e_kind in shred_edges:
    if rng.random() < 0.18:
        continue
    pa, pb = a.co.copy(), b.co.copy()
    mid = (pa + pb) / 2
    out = Vector((mid.x, mid.y - 1.4, 0)).normalized() * 0.35
    ln = depth * rng.uniform(0.35, 1.0)
    tip = mid + Vector((rng.uniform(-0.5, 0.5) + out.x, rng.uniform(-0.4, 0.4) + out.y, -ln))
    t = bm.verts.new(tip)
    try:
        f = bm.faces.new((a, b, t))
    except ValueError:
        continue
    f[kind_l] = e_kind
    for lp in f.loops:
        src = a if lp.vert in (a, t) else b
        lp[uvl].uv = src.link_loops[0][uvl].uv
    n_shred += 1
print("shreds", n_shred)

# The sockets take their own swatch in the corner the staff and bottles left free. (No added hair strands: the
# source's own dark hair frames her face, and the flat grey cards hung beside it read as opaque slabs.)
SOCKET_UV = (0.93, 0.05)

# hollow eye sockets: dark ellipsoids over the eyes, black texels (the game lights the eyes in them)
EYE_IDX = []
EYES = [warp(c) for c in EYE_SRC]      # [her left (+x), her right]
EYES.sort(key=lambda c: -c.x)
for c in EYES:
    geom = bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=6, radius=1.0)
    vs = [g for g in geom["verts"]]
    bm.verts.index_update()
    EYE_IDX.append([v.index for v in vs])
    for v in vs:
        v.co = c + Vector((v.co.x * 0.4, v.co.y * 0.2 + 0.18, v.co.z * 0.28))
    for f in {f for v in vs for f in v.link_faces}:
        f[kind_l] = SOCKET
        for lp in f.loops:
            lp[uvl].uv = SOCKET_UV   # painted black below
bm.normal_update()
bm.to_mesh(body.data)
bm.free()
body.data.update()
stop(2)

# ---------------------------------------------------------------- 3. rig
S = HEIGHT / 1.0  # replaced below once the pose is baked
BONES = {}


def B(name, parent, head, tail):
    BONES[name] = (parent, warp(Vector(head)), warp(Vector(tail)))


B("Hips", None, (0, 1.5, 9.5), (0, 1.3, 13))
B("Spine", "Hips", (0, 1.3, 13), (0, 1.0, 17))
B("Chest", "Spine", (0, 1.0, 17), (0, 0.6, 21.5))
B("Neck", "Chest", (0, 0.6, 21.5), (0.4, -0.6, 23.6))
B("Head", "Neck", (0.4, -0.6, 23.6), (0.8, -1.0, 29.0))
for s, sx in ((".L", 1.0), (".R", -1.0)):
    B("UpperLeg" + s, "Hips", (3.0 * sx, 2.3, 9.3), (3.1 * sx, 2.2, 5.0))
    B("LowerLeg" + s, "UpperLeg" + s, (3.1 * sx, 2.2, 5.0), (3.0 * sx, 2.1, 1.5))
    B("Foot" + s, "LowerLeg" + s, (3.0 * sx, 2.1, 1.5), (3.3 * sx, -0.4, 0.4))
B("UpperArm.L", "Chest", (4.5, 2.5, 20.0), (6.1, 2.9, 15.5))
B("LowerArm.L", "UpperArm.L", (6.1, 2.9, 15.5), (6.2, 2.5, 12.3))
B("Hand.L", "LowerArm.L", (6.2, 2.5, 12.3), (6.2, 2.4, 10.8))
B("Fingers.L", "Hand.L", (6.2, 2.4, 10.8), (6.0, 2.2, 9.0))
B("UpperArm.R", "Chest", (-4.5, 2.5, 20.0), (-5.9, 2.0, 16.4))
B("LowerArm.R", "UpperArm.R", (-5.9, 2.0, 16.4), (-7.0, -1.6, 19.2))
B("Hand.R", "LowerArm.R", (-7.0, -1.6, 19.2), (-7.0, -2.9, 22.0))
# cloth: four hem bones hanging off the hips, one for the hood's crown and back
B("Robe.F", "Hips", (0.8, -2.2, 12.5), (0.8, -2.8, 6.0))
B("Robe.B", "Hips", (0.8, 4.8, 12.5), (0.8, 5.6, 6.0))
B("Robe.L", "Hips", (4.6, 1.5, 12.5), (5.2, 1.5, 6.0))
B("Robe.R", "Hips", (-3.0, 1.5, 12.5), (-3.6, 1.5, 6.0))
B("Hood", "Head", (0.8, 0.6, 26.0), (0.9, 1.4, 31.0))
# the cape over the shoulders and back (warped units already): a flap over each shoulder that rides up
# with the arm (a stiff cape the raised arm came through), and the back panel that trails and swings
BONES["Cape.B"] = ("Chest", Vector((0.0, 2.6, 26.0)), Vector((0.0, 6.0, 20.6)))
BONES["Cape.L"] = ("Chest", Vector((3.0, 1.2, 26.0)), Vector((6.0, 1.8, 21.0)))
BONES["Cape.R"] = ("Chest", Vector((-3.0, 1.2, 26.0)), Vector((-6.0, 1.8, 21.0)))
# the eyes: at the sockets' centres (EYES is already warped), pointing out of the face; never weighted
for name, c in (("Eye.L", EYES[0]), ("Eye.R", EYES[1])):
    BONES[name] = ("Head", c.copy(), c + Vector((0.0, -1.0, 0.0)))

arm = bpy.data.objects.new("Rig", bpy.data.armatures.new("Rig"))
bpy.context.scene.collection.objects.link(arm)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="EDIT")
for name, (parent, head, tail) in BONES.items():
    eb = arm.data.edit_bones.new(name)
    eb.head, eb.tail = head, tail
    eb.align_roll(Vector((0, 1, 0)))
for name, (parent, _h, _t) in BONES.items():
    if parent:
        arm.data.edit_bones[name].parent = arm.data.edit_bones[parent]
bpy.ops.object.mode_set(mode="OBJECT")


def seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
    return (p - (a + ab * t)).length


def weights(p, names, power=3.0):
    ds = sorted(((1.0 / (seg_dist(p, BONES[n][1], BONES[n][2]) + 0.25) ** power, n) for n in names), reverse=True)[:3]
    tot = sum(w for w, _ in ds)
    return {n: w / tot for w, n in ds}


for n in BONES:
    body.vertex_groups.new(name=n)
LEGS = ["UpperLeg.L", "UpperLeg.R", "LowerLeg.L", "LowerLeg.R", "Foot.L", "Foot.R"]
ARML = ["UpperArm.L", "LowerArm.L", "Hand.L", "Fingers.L"]
ARMR = ["UpperArm.R", "LowerArm.R", "Hand.R"]
CORE = ["Hips", "Spine", "Chest", "Neck", "Head"]
_kinds = body.data.attributes["kind"].data
CAPE_V = {i for f in body.data.polygons if _kinds[f.index].value == CLOAK for i in f.vertices}
CAPE_TOP_W = fz(23.2) + 0.6
# The leg wraps and feet ride their own leg only: an inner-thigh vertex nearer the other leg's bone took a
# share of it (the shins dragged across each other), and the robe's cloth bones took up to 85% of the thighs
# and knees below (the left leg bent like rubber as the hem swung, the knee texture smeared).
LEG_V = {i for f in body.data.polygons if _kinds[f.index].value in (WRAPS, FEET) for i in f.vertices}
G = {}
for v in body.data.vertices:
    p = v.co
    if v.index in LEG_V:
        s = "L" if p.x > 0 else "R"
        G[v.index] = weights(p, ["UpperLeg." + s, "LowerLeg." + s, "Foot." + s, "Hips"])
        continue
    if v.index in CAPE_V and p.z < fz(23.2) + 0.6:
        # the cape hangs off the chest (its shoulder flaps then ride up with the arms through Cape.L/R): an arm
        # weight here, cut off where the arm's weights end, tore a plate out of it when the arm rose
        g = weights(p, ["Chest", "Neck", "Spine"])
        # over each shoulder it is a wool pauldron on the upper arm (the arm lies under it, and a chest-only
        # mantle was what every raised arm came through); toward the throat and down the back it stays on
        # the chest. The diffusion below fades the seam between the two over several rings.
        a = smooth((abs(p.x) - 2.4) / 2.4) * smooth((4.2 - p.y) / 2.6)
        if a > 0.0:
            up = "UpperArm.L" if p.x > 0 else "UpperArm.R"
            g = {n: w * (1.0 - a) for n, w in g.items()}
            g[up] = a
    elif p.z > fz(23.2) and abs(p.x - 0.8) < 4.2 and p.y < 3.5 and p.z > fz(23.2):
        # hood, head, hair roots: the head, blended into the neck at the bottom
        w = smooth((p.z - fz(22.2)) / 1.8)
        g = {"Head": w, "Neck": 1 - w}
    else:
        if p.z < fz(9.5) and abs(p.x) > 1.2:
            g = weights(p, LEGS + ["Hips"])
        else:
            g = weights(p, CORE[:3] + ["Neck"] + LEGS)
        # the shoulder: blended from the body onto the arm over 1.6 units, not switched at a line (a hard
        # switch tore the seam six times its length open when the arm rose to strike)
        side = ARML if p.x > 0 else ARMR
        if p.z > 16.0:          # from the armpit up (the wrist hangs below it)
            a = smooth((abs(p.x) - 3.2) / 2.8)
        else:                   # down the side the hanging hand lies against the robe: switched, as it hangs apart
            a = 1.0 if abs(p.x) > 5.0 and p.z > fz(8.5) else 0.0
        if a > 0.0:
            ga = weights(p, side + ["Chest"])
            g = {n: g.get(n, 0.0) * (1 - a) + ga.get(n, 0.0) * a for n in set(g) | set(ga)}
    G[v.index] = g
# The cape's shoulder edge is sewn to the arm: a cape vertex on the chest beside a sleeve vertex on the arm
# stretched that edge five times its length when the arm rose (a strip of cloak dragged up to the elbow).
# Diffuse the weights over the mesh around the shoulders so the arm's share fades out over several rings.
_nb = {i: [] for i in range(len(body.data.vertices))}
for e in body.data.edges:
    i, j = e.vertices
    _nb[i].append(j)
    _nb[j].append(i)
SHOULDER = [v.index for v in body.data.vertices if abs(v.co.x) > 2.2 and 15.0 < v.co.z < CAPE_TOP_W]
for _ in range(12):
    new = {}
    for i in SHOULDER:
        acc = {n: 0.5 * w for n, w in G[i].items()}
        ns = _nb[i]
        for j in ns:
            for n, w in G[j].items():
                acc[n] = acc.get(n, 0.0) + 0.5 * w / len(ns)
        new[i] = acc
    G.update(new)
for i, g in G.items():
    top = sorted(g.items(), key=lambda kv: -kv[1])[:4]
    tot = sum(w for _, w in top)
    for n, w in top:
        if w / tot > 0.004:
            body.vertex_groups[n].add([i], w / tot, "REPLACE")

CLOTH = ["Robe.F", "Robe.B", "Robe.L", "Robe.R", "Hood", "Cape.B", "Cape.L", "Cape.R"]
for n in CLOTH:
    body.vertex_groups.new(name=n)
# the arms' skin never takes a cloth share: the hanging hand's inner edge lies inside the robe's
# reach, and robe-weighted knuckles stay behind when the arm lifts (a sheet stretched to the wrist)
ARM_SKIN = {i for f in body.data.polygons if _kinds[f.index].value == SKIN for i in f.vertices}
CAPE_TOP = fz(23.2) + 0.6
for v in body.data.vertices:
    p = v.co
    ws = {}
    if v.index in CAPE_V and p.z < CAPE_TOP:
        # the cape below the hood: free toward its edge, by which side of her it hangs on
        k = 0.9 * smooth((CAPE_TOP - p.z) / 3.2)
        dx, dy = p.x, p.y - 1.5
        r = max(math.hypot(dx, dy), 1e-6)
        for n, (ax, ay) in (("Cape.B", (0, 1)), ("Cape.L", (1, 0)), ("Cape.R", (-1, 0))):
            c = max(0.0, (dx * ax + dy * ay) / r)
            if c > 0.0:
                ws[n] = k * c * c
        front = max(0.0, -dy / r)          # the front edges, over the chest: the shoulder flaps
        if front > 0.0:
            ws["Cape.L" if dx > 0 else "Cape.R"] = ws.get("Cape.L" if dx > 0 else "Cape.R", 0.0) + 0.5 * k * front * front
        # the flaps fade out toward her throat: Cape.L and Cape.R swing apart there as the arms rise, and an
        # edge weighted to both tore open down the front
        for n in ("Cape.L", "Cape.R"):
            if n in ws:
                ws[n] *= smooth(abs(dx) / 2.0)
    elif abs(p.x - 0.8) > 5.6 or v.index in ARM_SKIN or v.index in LEG_V:   # limbs stay on their bones
        continue
    if fz(5.0) < p.z < fz(14.0):
        k = smooth((fz(14.0) - p.z) / (fz(14.0) - fz(7.0))) * 0.85
        dx, dy = p.x - 0.8, p.y - 1.5
        for n, (ax, ay) in (("Robe.F", (0, -1)), ("Robe.B", (0, 1)), ("Robe.L", (1, 0)), ("Robe.R", (-1, 0))):
            c = max(0.0, (dx * ax + dy * ay) / max(math.hypot(dx, dy), 1e-6))
            if c > 0.0 and math.hypot(dx, dy) > 1.0:
                ws[n] = k * c * c
    if p.z > fz(24.5) and abs(p.x - 0.8) < 4.6 and p.y < 4.5:
        ws["Hood"] = smooth((p.z - fz(24.5)) / 3.0) * 0.7 * smooth((p.y + 3.0) / 4.0)
    tot = sum(ws.values())
    if tot <= 0.004:
        continue
    if tot > 0.95:
        ws = {n: w * 0.95 / tot for n, w in ws.items()}
        tot = 0.95
    for g in body.vertex_groups:      # take the cloth share from the existing weights
        if g.name in CLOTH:
            continue
        try:
            w0 = g.weight(v.index)
        except RuntimeError:
            continue
        g.add([v.index], w0 * (1.0 - tot), "REPLACE")
    for n, w in ws.items():
        body.vertex_groups[n].add([v.index], w, "REPLACE")

for i, idx in enumerate(EYE_IDX):
    body.vertex_groups.new(name="Socket%d" % i).add(idx, 1.0, "REPLACE")
mod = body.modifiers.new("Armature", "ARMATURE")
mod.object = arm
body.parent = arm


def rest3(bone):
    return arm.data.bones[bone].matrix_local.to_3x3()


def pose(rots=None, scales=None, locs=None):
    for pb in arm.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = Quaternion()
        pb.scale = Vector((1, 1, 1))
        pb.location = Vector((0, 0, 0))
    for n, e in (rots or {}).items():
        r = rest3(n)
        arm.pose.bones[n].rotation_quaternion = (r.inverted() @ Euler(e, "XYZ").to_matrix() @ r).to_quaternion()
    for n, s in (scales or {}).items():
        arm.pose.bones[n].scale = Vector(s)
    for n, v in (locs or {}).items():
        arm.pose.bones[n].location = rest3(n).inverted() @ Vector(v)
    bpy.context.view_layer.update()


for n in ("LowerArm.L", "Hand.L", "Fingers.L", "Hand.R", "UpperArm.L", "Head"):
    arm.data.bones[n].inherit_scale = "NONE"
pose(
    # hunched at the back, but the neck carries the head up and forward out of the mantle (bent over it
    # further, the head sank into the chest and from behind she had none)
    rots={"Spine": (d(10), 0, 0), "Chest": (d(8), 0, 0), "Neck": (d(-6), 0, 0), "Head": (d(-6), 0, 0),
          "UpperArm.L": (d(3), 0, d(-5)), "UpperArm.R": (d(5), 0, d(6)), "Fingers.L": (d(-22), 0, 0)},
    # long bony fingers, but a hand no bigger than her face (the source's left one was a shovel)
    scales={"Neck": (1, 1.35, 1), "UpperArm.L": (1, 1.15, 1), "LowerArm.L": (0.85, 1.12, 0.85), "Hand.L": (0.68, 0.72, 0.68),
            "Fingers.L": (0.7, 0.86, 0.7), "Hand.R": (0.78, 0.95, 0.78)},
)
bpy.ops.object.select_all(action="DESELECT")
bpy.context.view_layer.objects.active = body
bpy.ops.object.modifier_apply(modifier="Armature")
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode="POSE")
bpy.ops.pose.select_all(action="SELECT")
bpy.ops.pose.armature_apply()
bpy.ops.object.mode_set(mode="OBJECT")
m = body.modifiers.new("Armature", "ARMATURE")
m.object = arm
pose()
bpy.context.view_layer.update()

# scale to HEIGHT (top of the hood), feet on the floor
vs = [body.matrix_world @ v.co for v in body.data.vertices]
top = max(v.z for v in vs)
bot = min(v.z for v in vs)
k = HEIGHT / (top - bot)
bpy.ops.object.select_all(action="DESELECT")
body.select_set(True)
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
for ob in (body, arm):
    ob.parent = None if ob == arm else ob.parent
arm.scale = (k, k, k)
arm.location = Vector((0, 0, -bot * k))
bpy.context.view_layer.update()
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
stop(3)

# ---------------------------------------------------------------- 4. texture
# The source texture is a flat hand-painted one; under the game's dim light it read as a grey, blotchy
# blanket. Every texel is traced back to the point on her (rest pose, metres) it covers, and painted by
# what that part is, with noise in 3D so seams between UV islands do not show.
import numpy as np
from PIL import Image

W0, H0 = base_img.size
src = np.array(base_img.pixels[:], dtype=np.float32).reshape(H0, W0, 4)[..., :3]   # row 0 = v 0
# Painted at twice the source's size: the procedural skin, weave and hand detail is what the
# extra texels are for (the source's own paint is upsampled and only lends its local contrast).
UP = 2
src = np.repeat(np.repeat(src, UP, 0), UP, 1)
H, W = src.shape[:2]
src_lum = src @ np.array([0.3, 0.59, 0.11], dtype=np.float32)

me = body.data
me.calc_loop_triangles()
kind_attr = me.attributes["kind"]
kinds_f = np.zeros(len(me.polygons), dtype=np.int32)
kind_attr.data.foreach_get("value", kinds_f)
uv_data = me.uv_layers.active.data
POS = np.zeros((H, W, 3), dtype=np.float32)
KINDS = np.zeros((H, W), dtype=np.int32)
for tri in me.loop_triangles:
    uv = np.array([uv_data[li].uv[:] for li in tri.loops], dtype=np.float64) * (W, H)
    xyz = np.array([me.vertices[vi].co[:] for vi in tri.vertices], dtype=np.float64)
    x0, y0 = np.floor(uv.min(0)).astype(int) - 1
    x1, y1 = np.ceil(uv.max(0)).astype(int) + 1
    x0, y0, x1, y1 = max(x0, 0), max(y0, 0), min(x1, W - 1), min(y1, H - 1)
    if x1 < x0 or y1 < y0:
        continue
    gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
    (ax, ay), (bx, by), (cx, cy) = uv
    den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
    if abs(den) < 1e-12:
        continue
    l0 = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
    l1 = ((cy - ay) * (gx - cx) + (ax - cx) * (gy - cy)) / den
    l2 = 1 - l0 - l1
    inside = (l0 >= -0.02) & (l1 >= -0.02) & (l2 >= -0.02)
    if not inside.any():
        continue
    p3 = l0[..., None] * xyz[0] + l1[..., None] * xyz[1] + l2[..., None] * xyz[2]
    sub_pos = POS[y0:y1 + 1, x0:x1 + 1]
    sub_kind = KINDS[y0:y1 + 1, x0:x1 + 1]
    sub_pos[inside] = p3[inside]
    sub_kind[inside] = kinds_f[tri.polygon_index]
# Grow every island a few texels so mip levels and filtering never pull in the gaps between them.
for _ in range(8 * UP):
    empty = KINDS == 0
    if not empty.any():
        break
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
        sk = np.roll(KINDS, (dy, dx), (0, 1))
        sp = np.roll(POS, (dy, dx), (0, 1))
        take = empty & (sk != 0) & (KINDS == 0)
        KINDS[take] = sk[take]
        POS[take] = sp[take]


def box(a, r):
    """Box blur (numpy only: Blender's Python has no scipy), radius r texels, wrapping."""
    out = a
    for ax in (0, 1):
        c = np.cumsum(np.concatenate([out.take(range(-r - 1, 0), ax), out, out.take(range(0, r), ax)], ax), ax)
        n = out.shape[ax]
        out = (c.take(range(2 * r + 1, 2 * r + 1 + n), ax) - c.take(range(0, n), ax)) / (2 * r + 1)
    return out


def hash3(i, j, k, seed):
    h = (i * 374761393 + j * 668265263 + k * 1274126177 + seed * 974634511) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF).astype(np.float32) / 65535.0


def noise(p, freq, seed=0):
    """Smooth value noise in [0, 1] at points p (..., 3) metres."""
    q = p * freq
    f = np.floor(q)
    t = q - f
    t = t * t * (3 - 2 * t)
    i = f.astype(np.int64)
    out = 0.0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (t[..., 0] if dx else 1 - t[..., 0]) * (t[..., 1] if dy else 1 - t[..., 1]) * \
                    (t[..., 2] if dz else 1 - t[..., 2])
                out = out + w * hash3(i[..., 0] + dx, i[..., 1] + dy, i[..., 2] + dz, seed)
    return out


def fbm(p, freq, seed=0, octaves=4):
    tot, amp, norm = 0.0, 1.0, 0.0
    for o in range(octaves):
        tot = tot + amp * noise(p, freq * 2 ** o, seed + 17 * o)
        norm += amp
        amp *= 0.5
    return tot / norm


def mix(a, b, t):
    return a + (np.asarray(b, dtype=np.float32) - a) * t[..., None]


def C(*rgb):
    return np.array(rgb, dtype=np.float32)


P = POS
z = P[..., 2]
lo_n = fbm(P, 1.6, 1)         # big hue patches
mid_n = fbm(P, 6.0, 2)        # cloth mottling
fine_n = fbm(P, 30.0, 3, 3)   # weave and grain
# The source's painted detail (wrinkles, wrap stripes, the face): its local contrast only.
lum_s = box(src_lum, UP)
detail = np.clip(lum_s / np.maximum(box(src_lum, 18 * UP), 0.02), 0.55, 1.6)
ang = np.arctan2(P[..., 1] - 0.05, P[..., 0] - 0.07)   # around her body axis, for folds

out = np.full((H, W, 3), 0.3, dtype=np.float32)
k = KINDS
# Relief and sheen painted alongside the colour: a height per texel (folds, weave, wrinkles) that becomes the
# tangent-space normal map, and a roughness per texel (wool and linen matt, skin and nails with a waxy sheen).
hgt = np.zeros((H, W), dtype=np.float32)
rough = np.full((H, W), 0.95, dtype=np.float32)

# Robe: oxblood shading to aubergine, folds of three sizes that wander and break (not one even stripe),
# a twill weave, a mud-dark ragged hem under a faded embroidered band, patches.
m = (k == ROBE)
col = mix(np.broadcast_to(C(0.42, 0.2, 0.17), (H, W, 3)).copy(), C(0.30, 0.2, 0.28), np.clip(lo_n * 1.8 - 0.4, 0, 1))
col = mix(col, C(0.33, 0.24, 0.19), np.clip((mid_n - 0.55) * 3.0, 0, 1) * 0.6)        # faded brown blotches
warp = fbm(P, 2.5, 4) * 6.0
folds = (0.5 * np.sin(ang * 7.0 + warp + z * 1.5) + 0.3 * np.sin(ang * 17.0 + warp * 1.7 - z * 3.0)
         + 0.2 * np.sin(ang * 31.0 + fbm(P, 9.0, 8) * 9.0))
folds = np.clip(0.5 + 0.5 * folds * (0.6 + 0.8 * fbm(P, 4.0, 9)), 0, 1)   # some folds fade out, some deepen
col *= (0.68 + 0.45 * folds ** 1.3)[..., None]
# the back hangs in long deep pleats from the belt, flaring toward the hem (seen from behind, not a tube)
back = np.clip((P[..., 1] - 0.0) / 0.08, 0, 1)
pleat = np.clip(0.5 + 0.5 * np.sin(ang * 13.0 + fbm(P, 2.0, 31) * 4.0 + (1.0 - z) * 2.5), 0, 1)
col *= (1.0 - back * (0.38 * (1.0 - pleat) ** 2 - 0.08 * pleat ** 4))[..., None]
twill = 0.5 + 0.5 * np.sin((ang * 0.32 + z) * 420.0)
col *= (0.9 + 0.1 * twill + 0.16 * (fine_n - 0.5))[..., None]
band = np.clip(1 - np.abs(z - 0.98 - 0.02 * mid_n) / 0.045, 0, 1) > 0.0
zig = np.abs(((ang * 24.0) % 2.0) - 1.0)                      # a zigzag of faded ochre thread
stitchrow = (np.abs((z - 0.98) / 0.03 - (zig - 0.5)) < 0.22) | (np.abs(np.abs(z - 0.98) - 0.04) < 0.005)
emb = band & stitchrow & (noise(P, 25, 12) > 0.3)              # worn through in places
col[m & emb] = (C(0.52, 0.4, 0.2) * (0.75 + 0.4 * fine_n[m & emb])[:, None])
hem = np.clip((0.55 + 0.25 * mid_n - z) / 0.35, 0, 1)
col *= 1.2                     # lifted out of the mud: the front read as one dark mass under the capture's light
col = mix(col, C(0.17, 0.13, 0.10), hem * 0.85)
for i, (pc, size, tint) in enumerate((((-0.12, -0.24, 0.85), 0.09, (0.26, 0.24, 0.17)),
                                      ((0.17, 0.25, 0.65), 0.11, (0.2, 0.14, 0.2)),
                                      ((0.2, -0.18, 0.45), 0.07, (0.3, 0.2, 0.14)))):
    d3 = np.abs(P - C(*pc))
    box_d = np.maximum(d3[..., 0], d3[..., 2]) + (d3[..., 1] > 0.35) * 9.0
    edge = size + 0.012 * (noise(P, 40, 30 + i) - 0.5)
    inside = box_d < edge
    col[m & inside] = (C(*tint) * (0.85 + 0.3 * fine_n[m & inside])[:, None])
    stitch = (np.abs(box_d - edge + 0.008) < 0.004) & (np.sin((P[..., 0] + P[..., 2]) * 300) > 0.2)
    col[m & stitch] = C(0.55, 0.5, 0.4)
out[m] = col[m]
hgt[m] = (0.9 * folds + 0.5 * back * pleat + 0.12 * twill + 0.25 * fine_n)[m]
rough[m] = (0.9 + 0.08 * fine_n)[m]
rough[m & (hem > 0.5)] = 0.98

# Cloak and hood: moss-green wool fading to peat brown, deep folds, a twill weave, darned holes,
# a darker felted border at the hem and the bleached wear of the source's high spots.
m = (k == CLOAK)
col = mix(np.broadcast_to(C(0.30, 0.36, 0.16), (H, W, 3)).copy(), C(0.36, 0.25, 0.14), np.clip(lo_n * 2 - 0.5, 0, 1))
col = mix(col, C(0.22, 0.27, 0.13), np.clip((mid_n - 0.55) * 4.0, 0, 1) * 0.6)
warp = fbm(P, 3.0, 5) * 5.0
folds = 0.6 * np.sin(ang * 9.0 + warp) + 0.4 * np.sin(ang * 22.0 + warp * 1.5 + z * 4.0)
folds = np.clip(0.5 + 0.5 * folds, 0, 1)
col *= (0.62 + 0.5 * folds ** 1.2)[..., None]
# no weave or darning at texel scale: finer than a texel at play distance, it crawled as speckle and lit
# a bright fringe along the hood's outline. Broad folds, soft mottling and the source's creases only.
col *= (0.95 + 0.1 * (mid_n - 0.5))[..., None]
col *= np.clip(box(detail, 2 * UP), 0.8, 1.2)[..., None] ** 0.6          # the source's painted creases, blurred
wear = np.clip((box(detail, 3 * UP) - 1.12) * 2.0, 0, 1) * 0.2
col = mix(col, C(0.4, 0.4, 0.3), wear)
twill = 0.5 + 0.5 * np.sin((P[..., 0] + P[..., 1] + z) * 380.0)
border = np.clip((1.58 + 0.03 * mid_n - z) / 0.06, 0, 1)
col *= 1.35
col = mix(col, C(0.14, 0.13, 0.08), border * 0.7)
out[m] = col[m]
hgt[m] = (0.9 * folds + 0.3 * mid_n + 0.4 * np.clip(box(detail, 2 * UP), 0.8, 1.2))[m]
rough[m] = 0.93

# Hood lining: the same wool turned inward and in shadow, still folded and woven (never a black hole
# beside her face); the deeper toward the crown, the darker.
m = (k == HOODIN)
col = mix(np.broadcast_to(C(0.20, 0.21, 0.11), (H, W, 3)).copy(), C(0.21, 0.15, 0.09), np.clip(lo_n * 2 - 0.5, 0, 1))
lfold = np.clip(0.5 + 0.5 * np.sin(ang * 11.0 + fbm(P, 3.0, 21) * 5.0 + z * 9.0), 0, 1)
col *= (0.7 + 0.45 * lfold)[..., None] * (0.85 + 0.12 * twill + 0.25 * (fine_n - 0.5))[..., None]
col *= (1.0 - 0.35 * np.clip((z - 1.62) / 0.15, 0, 1))[..., None]
out[m] = col[m]
hgt[m] = (0.8 * lfold + 0.1 * twill)[m]
rough[m] = 0.97

# Skin (arms, hands, face): pallid grey-green, bruised purple, veined, crêpe-wrinkled across the limb,
# liver-spotted and pored; the face keeps its painted features.
crepe_w = fbm(P, 7.0, 22, 3) * 7.0
crepe = 0.5 + 0.5 * np.sin(z * 260.0 + crepe_w) * (0.4 + 0.6 * fbm(P, 11.0, 23, 2))   # fine creases around the limb
crepe2 = 0.5 + 0.5 * np.sin((P[..., 0] * 0.6 + P[..., 1] * 0.8 + z * 0.3) * 520.0 + crepe_w * 1.5)
ridge = 1.0 - np.abs(2.0 * fbm(P, 22.0, 24, 3) - 1.0)                               # tendons and knobbly knuckles
spots = np.clip((noise(P, 55.0, 25) - 0.72) * 6.0, 0, 1) * np.clip((noise(P, 9.0, 26) - 0.35) * 3.0, 0, 1)
pores = noise(P, 260.0, 27)
for kk, strength in ((SKIN, 0.7), (FACE, 0.65)):
    m = (k == kk)
    col = mix(np.broadcast_to(C(0.43, 0.46, 0.38), (H, W, 3)).copy(), C(0.44, 0.36, 0.44), np.clip(mid_n * 2.2 - 0.7, 0, 1) * 0.45)
    col = mix(col, C(0.5, 0.5, 0.43), np.clip(lo_n * 2 - 1.1, 0, 1) * 0.5)   # one pallid skin, not patches
    vein = np.clip(1 - np.abs(fbm(P, 14.0, 6, 3) - 0.5) / 0.03, 0, 1)
    col = mix(col, C(0.30, 0.31, 0.46), vein * 0.6)
    col = mix(col, C(0.36, 0.29, 0.18), spots * 0.7)
    # the crêpe and pores kept faint: at full strength they read as speckled stone at play distance
    col *= (0.92 + 0.08 * crepe ** 2 + 0.03 * crepe2 - 0.02)[..., None]
    col *= (0.9 + 0.16 * ridge ** 2)[..., None] * (0.97 + 0.04 * pores)[..., None]
    col *= (1.0 + strength * (detail - 1.0))[..., None] * (0.9 + 0.2 * fine_n)[..., None]
    # never pale: the source's light-painted palms read as a cream glove under the torch. Skin past a
    # dead-grey luminance is pulled back, so the whole hand is one sickly tone.
    lum = col @ np.array([0.3, 0.59, 0.11], dtype=np.float32)
    col *= np.minimum(1.0, 0.44 / np.maximum(lum, 1e-3))[..., None]
    if kk == FACE:
        # gaunt: the source's hollows (cheeks, temples, under the brow) sunk deeper and bruised
        hollow = np.clip((1.0 - box(detail, 2 * UP)) * 3.0, 0, 1)
        col = mix(col, C(0.16, 0.12, 0.17), hollow * 0.7)
    out[m] = col[m]
    hgt[m] = (0.25 * crepe + 0.12 * crepe2 + 0.5 * ridge + 0.05 * pores + 0.6 * (detail - 1.0) + 0.3 * vein)[m]
    rough[m] = (0.62 + 0.15 * fine_n - 0.1 * vein)[m]
# Nails and fingertips: the darkest skin texels are the source's nails: keep them dark and horn-yellow.
m = (k == SKIN) & (lum_s < 0.18)
out[m] = (C(0.2, 0.18, 0.1) * (0.8 + 0.4 * fine_n[..., None]))[m]
rough[m] = 0.45

m = (k == MOUTH)
out[m] = (C(0.32, 0.07, 0.08) * np.clip(detail, 0.5, 1.3)[..., None])[m]
rough[m] = 0.35
hgt[m] = (0.5 * detail)[m]

# Leg wraps: dirty linen over the source's stripes, browner and filthier toward the feet.
m = (k == WRAPS)
col = mix(np.broadcast_to(C(0.36, 0.31, 0.24), (H, W, 3)).copy(), C(0.22, 0.18, 0.13), np.clip(mid_n * 2 - 0.6, 0, 1))
col = mix(col, C(0.16, 0.13, 0.1), np.clip((0.35 - z) / 0.3, 0, 1) * 0.7)
col *= (detail ** 0.7)[..., None] * (0.9 + 0.2 * fine_n)[..., None] * 1.3
out[m] = col[m]
hgt[m] = (0.8 * detail + 0.25 * fine_n)[m]

m = (k == FEET)
out[m] = (C(0.27, 0.21, 0.16) * (detail ** 0.8)[..., None] * (0.85 + 0.3 * fine_n)[..., None])[m]
hgt[m] = (0.8 * detail + 0.3 * fine_n)[m]
rough[m] = 0.8

m = (k == BELT)
col = C(0.43, 0.2, 0.13) * (detail ** 1.2)[..., None] * (0.85 + 0.3 * mid_n)[..., None]
out[m] = col[m]
hgt[m] = detail[m]
rough[m] = 0.7

m = (k == STRANDS)
out[m] = (C(0.11, 0.11, 0.1) * (0.8 + 0.4 * fine_n[..., None]))[m]

m = (k == SOCKET) | (k == 0)
out[m] = 0.02

su, sv = int(SOCKET_UV[0] * W), int(SOCKET_UV[1] * H)
out[sv - 6 * UP:sv + 6 * UP, su - 6 * UP:su + 6 * UP] = 0.02
rough[(k == SOCKET) | (k == 0)] = 1.0
rough[sv - 6 * UP:sv + 6 * UP, su - 6 * UP:su + 6 * UP] = 1.0

# Normals from the height's slope across the atlas (u along a row, v down the rows: row 0 is v 0 here),
# flat wherever a neighbour texel lies on another part or across a UV seam (a jump in 3D position).
def _slope(ax):
    a, b = np.roll(hgt, -1, ax), np.roll(hgt, 1, ax)
    ka, kb = np.roll(k, -1, ax), np.roll(k, 1, ax)
    pa, pb = np.roll(POS, -1, ax), np.roll(POS, 1, ax)
    near = 0.012 * UP
    oka = (ka == k) & (np.linalg.norm(pa - POS, axis=-1) < near)
    okb = (kb == k) & (np.linalg.norm(pb - POS, axis=-1) < near)
    d = np.where(oka, a, hgt) - np.where(okb, b, hgt)
    return d / np.maximum(oka.astype(np.float32) + okb.astype(np.float32), 1.0)
BUMP = 2.2
nx, ny = -BUMP * _slope(1), -BUMP * _slope(0)
nz = np.ones_like(nx)
nl = np.sqrt(nx * nx + ny * ny + nz * nz)
nrm = np.stack([nx / nl, ny / nl, nz / nl], -1)
nrm[(k == SOCKET) | (k == 0)] = (0.0, 0.0, 1.0)
# Cavity shading baked into the colour: texels below their neighbourhood (fold valleys, creases) darker.
cav = np.clip((hgt - box(hgt, 4 * UP)) * 1.6, -0.35, 0.2)
out *= (1.0 + cav)[..., None]

out = np.clip(out, 0, 1)
ATLAS = os.path.join(os.path.dirname(os.path.abspath(DST)), "witch_atlas.png")
Image.fromarray((out[::-1] * 255 + 0.5).astype(np.uint8), "RGB").save(ATLAS, optimize=True)
print("atlas bytes", os.path.getsize(ATLAS), W, H)
NORMAL = os.path.join(os.path.dirname(ATLAS), "witch_normal.png")
Image.fromarray(((nrm[::-1] * 0.5 + 0.5) * 255 + 0.5).astype(np.uint8), "RGB").save(NORMAL, optimize=True)
ROUGH = os.path.join(os.path.dirname(ATLAS), "witch_rough.png")
Image.fromarray((np.clip(rough[::-1], 0, 1) * 255 + 0.5).astype(np.uint8), "L").save(ROUGH, optimize=True)
print("normal bytes", os.path.getsize(NORMAL), "slope p99", float(np.percentile(np.hypot(nx, ny), 99)))
me.attributes.remove(me.attributes["kind"])
img = bpy.data.images.load(ATLAS)
img.name = "witch_atlas"
mat = bpy.data.materials.new("Witch")
mat.use_nodes = True
tex = mat.node_tree.nodes.new("ShaderNodeTexImage")
tex.image = img
mat.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.9
mat.node_tree.nodes["Principled BSDF"].inputs["Specular IOR Level"].default_value = 0.1
mat.node_tree.links.new(tex.outputs["Color"], mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"])
body.data.materials.clear()
body.data.materials.append(mat)
stop(4)

# ---------------------------------------------------------------- 5. clips
bpy.context.scene.render.fps = 24     # the game's clip lengths and the walk speed assume 24
arm.animation_data_create()


# How fast each clip carries her forward (m/s, the game's root motion), for the cloth's drag.
CLIP_SPEED = {"idle": 0.0, "walk": 1.3, "attack_idle": 1.3, "attack": 0.0}


def _sample(rots, locs):
    """What the cloth needs from a posed frame: the knees' and hips' forward positions, and the body's pitch
    and yaw down to the chest and to the head (the sum of the world-axis Eulers up the chain)."""
    pose(rots=rots, locs=locs)
    pb = arm.pose.bones
    hips = arm.matrix_world @ pb["Hips"].head
    knees = [(arm.matrix_world @ pb["LowerLeg." + s].head).y for s in ("L", "R")]

    def chain(names, i):
        return sum(rots.get(n, (0, 0, 0))[i] for n in names)
    trunk = ["Hips", "Spine", "Chest"]
    head = trunk + ["Neck", "Head"]
    return {"hy": hips.y, "knee_f": hips.y - min(knees), "knee_b": max(knees) - hips.y,
            "knee_d": knees[1] - knees[0],           # how far the left knee is ahead of the right

            "chest_x": chain(trunk, 0), "chest_z": chain(trunk, 2), "head_x": chain(head, 0), "head_z": chain(head, 2),
            "hips_y": rots.get("Hips", (0, 0, 0))[1], "hips_z": rots.get("Hips", (0, 0, 0))[2],
            # how far each upper arm is raised from hanging (radians), for the cape's shoulder flaps
            "arm_l": _raise(pb["UpperArm.L"]), "arm_r": _raise(pb["UpperArm.R"])}


def _raise(pb):
    v = (pb.tail - pb.head).normalized()
    return math.acos(max(-1.0, min(1.0, -v.z)))


def _spring(target, loop, w=2 * math.pi * 1.4, zeta=0.32, fps=24.0):
    """A damped spring's angle chasing `target` (one value a frame): the lag and overshoot of cloth. A loop is
    run three times over and the last kept, so it starts where it ends."""
    n = len(target)
    reps = 3 if loop else 1
    x, v = target[0], 0.0
    out = []
    sub = 8
    h = 1.0 / fps / sub
    for rep in range(reps):
        for f in range(n):
            for _ in range(sub):
                a = w * w * (target[f] - x) - 2 * zeta * w * v
                v += a * h
                x += v * h
            if rep == reps - 1:
                out.append(x)
    return out


def _cloth_rows(name, rows, loop):
    """Secondary motion for the robe's panels, the hood and the cape, from the posed frames: the robe's front
    rides out over whichever knee is forward (and its back over the one behind); everything trails behind
    her by her speed and swings on, through a spring, when she stops or lurches; the hood and cape lag the
    head's and chest's turns; the shoulder flaps ride up with the arms (so a raised arm never comes through
    the cape)."""
    n = len(rows)
    dt = 1.0 / 24.0
    speed = CLIP_SPEED[name]
    fwd = []
    for f in range(n):
        g, h = (f + 1) % n if loop else min(f + 1, n - 1), (f - 1) % n if loop else max(f - 1, 0)
        fwd.append(speed - (rows[g]["hy"] - rows[h]["hy"]) / ((g - h) % n * dt if loop else max(g - h, 1) * dt))
    drag = [d(8.0) * v for v in fwd]                       # radians the hem trails per m/s
    robe = _spring(drag, loop)
    hood_x = _spring([r["head_x"] + 0.6 * dg for r, dg in zip(rows, drag)], loop, w=2 * math.pi * 1.8)
    hood_z = _spring([r["head_z"] for r in rows], loop, w=2 * math.pi * 1.8)
    # the cape hangs half by the chest and half by its own weight
    cape_x = _spring([0.5 * r["chest_x"] + 1.1 * dg for r, dg in zip(rows, drag)], loop, w=2 * math.pi * 1.2)
    cape_z = _spring([r["chest_z"] for r in rows], loop, w=2 * math.pi * 1.2)
    # the skirt swings on after the hips' roll and turn
    roll = _spring([r["hips_y"] for r in rows], loop, w=2 * math.pi * 1.3, zeta=0.25)
    yaw = _spring([r["hips_z"] for r in rows], loop, w=2 * math.pi * 1.3, zeta=0.25)
    # the stride: the side panels follow their knees fore and aft and the back panel swings toward the
    # leg behind, a beat late (from behind, the hem splits and sways with each step instead of one tube)
    stride = _spring([math.atan2(r["knee_d"], 0.5) for r in rows], loop, w=2 * math.pi * 3.2, zeta=0.45)  # above the 1.6 Hz step: follows it, no resonance
    out = []
    for f, r in enumerate(rows):
        fade = 1.0         # the lunge ends standing over you, still swinging: no fade to a rest pose
        rb = robe[f]
        kf = math.atan2(max(0.0, r["knee_f"] - KNEE_F0 - 0.02), 0.5)
        kb = math.atan2(max(0.0, r["knee_b"] - KNEE_B0 - 0.02), 0.5)
        hx = (hood_x[f] - r["head_x"]) * fade
        hz = (hood_z[f] - r["head_z"]) * fade
        cx = (cape_x[f] - r["chest_x"]) * fade
        cz = (cape_z[f] - r["chest_z"]) * fade
        # a shoulder flap rides up with its arm once the arm is raised past 40 degrees, out to her side
        # (the flaps ride the upper arms through their skin weights now; this only lifts their free edge)
        al = 0.25 * max(0.0, r["arm_l"] - d(40))
        ar = 0.25 * max(0.0, r["arm_r"] - d(40))
        st = stride[f]
        ry = roll[f] - r["hips_y"]
        rz = yaw[f] - r["hips_z"]
        out.append({
            # a little flare at rest: the back hem stood tucked under her
            "Robe.F": (rb - 1.8 * kf, ry, rz),
            "Robe.B": (d(6) + rb + 2.8 * kb, 2.0 * ry + 1.4 * st, 1.8 * rz),
            "Robe.L": (rb - 1.8 * st, d(-4) + 1.8 * ry, 1.2 * rz),
            "Robe.R": (rb + 1.8 * st, d(4) + 1.8 * ry, 1.2 * rz),
            "Hood": (hx, 0, hz),
            "Cape.B": (cx, 0, cz),
            "Cape.L": (0.8 * cx, -al, cz),
            "Cape.R": (0.8 * cx, ar, cz),
        })
    return out


def clip(name, frames, fn, loop=True):
    act = bpy.data.actions.new(name)
    arm.animation_data.action = act
    count = frames if loop else frames + 1
    poses = []
    rows = []
    for f in range(count):
        t = f / frames
        rots, locs = fn(t)
        poses.append((dict(rots), locs))
        rows.append(_sample(rots, locs))
    sec = _cloth_rows(name, rows, loop)
    for f in range(frames + 1):
        i = f % count
        rots, locs = poses[i]
        rots = dict(rots)
        for n, e in cloth(f / frames, name).items():
            x0, y0, z0 = sec[i].get(n, (0, 0, 0))
            rots[n] = (x0 + e[0], y0 + e[1], z0 + e[2])
        pose(rots=rots, locs=locs)
        for pb in arm.pose.bones:
            pb.keyframe_insert("rotation_quaternion", frame=f)
            if pb.name == "Hips":
                pb.keyframe_insert("location", frame=f)
    act.use_fake_user = True
    tr = arm.animation_data.nla_tracks.new()
    tr.name = name
    tr.strips.new(name, 0, act)


def sw(t, ph=0.0):
    return math.sin(2 * math.pi * (t + ph))


# The cloth's own small sway on top (breath, a draught): (degrees, cycles a clip).
CLOTH_AMP = {"idle": (5.5, 1), "walk": (9.0, 2), "attack_idle": (9.0, 4), "attack": (6.0, 2)}


def cloth(t, name):
    a, f = CLOTH_AMP[name]
    u = t * f
    return {
        "Robe.F": (d(a * sw(u, 0.30)), 0, d(0.4 * a * sw(u, 0.1))),
        "Robe.B": (d(-a * sw(u, 0.30)), 0, d(0.4 * a * sw(u, 0.6))),
        "Robe.L": (d(0.4 * a * sw(u, 0.2)), d(a * sw(u, 0.55)), 0),
        "Robe.R": (d(0.4 * a * sw(u, 0.7)), d(-a * sw(u, 0.55)), 0),
        "Hood": (d(0.5 * a * sw(u, 0.45)), d(0.3 * a * sw(u, 0.15)), d(0.4 * a * sw(u, 0.8))),
        "Cape.B": (d(0.6 * a * sw(u, 0.35)), d(0.4 * a * sw(u, 0.05)), 0),
        "Cape.L": (d(0.4 * a * sw(u, 0.65)), 0, d(0.3 * a * sw(u, 0.4))),
        "Cape.R": (d(0.4 * a * sw(u, 0.15)), 0, d(0.3 * a * sw(u, 0.9))),
    }


pose()
KNEE_F0 = _sample({}, {})["knee_f"]      # the knees' rest spot, from which the robe is pushed
KNEE_B0 = _sample({}, {})["knee_b"]


def base_idle(t):
    return {
        "Spine": (d(4.0 * sw(t)), 0, d(3.5 * sw(t, 0.25))),
        "Chest": (d(5.0 * sw(t, 0.1)), d(4.0 * sw(t, 0.35)), 0),
        "Head": (d(4.0 * sw(t, 0.3)), d(7.0 * sw(t, 0.5)), d(4.0 * sw(t, 0.2))),
        "UpperArm.L": (d(7 * sw(t, 0.2)), 0, d(-5 * sw(t))),
        "UpperArm.R": (d(5 * sw(t, 0.4)), 0, d(5 * sw(t))),
        "Hand.L": (d(-12 * sw(t, 0.3)), 0, 0),
        "LowerArm.R": (d(8 * sw(t, 0.15)), 0, d(6 * sw(t, 0.5))),
        "Hand.R": (d(18 * sw(t, 0.35)), d(14 * sw(t, 0.1)), d(16 * sw(t, 0.6))),
        "Fingers.L": (d(18 * sw(t, 0.5)), 0, d(8 * sw(t, 0.6))),
    }


STRIDE = 35
LIFT = 0.09


def _ankle(r, drop, side, axis=2):
    pose(rots=r, locs={"Hips": (0, 0, drop)})
    return (arm.matrix_world @ arm.pose.bones["Foot." + side].head)[axis]


def _ankle_z(r, drop, side):
    return _ankle(r, drop, side, 2)


WALK_SPEED = 1.3     # m/s, the speed the game plays the walk clip at (rate 1)
WALK_CYCLE = 0.625   # s, two stride cycles in the 30-frame clip: short quick steps her short legs can make
                     # (one 1.6 m cycle threw the back foot so far behind her it read as a leg splayed out)
WALK_KNEE = 40       # deg, the most a swinging knee bends
WALK_TRACK = 0.95    # of her rest foot spread, where the walking feet land (under her, not straddling)
M_RISE = 0.02        # cycles of the swing, from lift-off, the foot is still low and still sweeping back
M_LAND = 0.07        # cycles before touchdown the foot is already low and sweeping back


def _bend(r, drop, side, knee):
    """Bends the knee `knee` degrees straight back, in the plane of her stride: the shin is aimed at the
    thigh's posed direction turned about the world's side axis. A turn about the shin bone's own x (the
    source rig's knee axis is not lateral) swung the foot out, and the thigh roll that pulled it back in
    tucked the knee under her: the crossed shins and bow-legged splay of the walk."""
    if knee is None:
        return
    pose(rots=r, locs={"Hips": (0, 0, drop)})
    pb = arm.pose.bones["UpperLeg." + side]
    mw = arm.matrix_world
    t = (mw @ pb.tail - mw @ pb.head).normalized()
    a = d(knee)
    v = (t.x, t.y * math.cos(a) - t.z * math.sin(a), t.y * math.sin(a) + t.z * math.cos(a))
    _aim(r, (0, 0, drop), "LowerLeg." + side, (v[0] * SIDE[side], v[1], v[2]), side)
    r["Foot." + side] = (d(-0.5 * knee), 0, 0)


def _solve_thigh(r, drop, side, target, probe=0.0, knee=None):
    """The thigh angle (deg) that puts the ankle's forward coordinate at `target` (bisection)."""
    key = "UpperLeg." + side
    roll = r[key][2]

    def f(deg):
        r[key] = (d(deg), 0, roll)
        _bend(r, drop, side, knee)
        return _ankle(r, drop, side, 1) - target

    lo, hi = -70.0, 70.0
    flo, fhi = f(lo), f(hi)
    if flo * fhi > 0:
        best = lo if abs(flo) < abs(fhi) else hi
        r[key] = (d(best), 0, roll)
        _bend(r, drop, side, knee)
        return best
    for _ in range(22):
        mid = 0.5 * (lo + hi)
        fm = f(mid)
        if (fm > 0) == (flo > 0):
            lo, flo = mid, fm
        else:
            hi = mid
    r[key] = (d(0.5 * (lo + hi)), 0, roll)
    _bend(r, drop, side, knee)
    return 0.5 * (lo + hi)


def _solve_roll(r, drop, side, target, knee=None):
    """Rolls the thigh sideways (keeping its swing) until the ankle stands at lateral `target`."""
    key = "UpperLeg." + side
    sw_x = r[key][0]

    def f(deg):
        r[key] = (sw_x, 0, d(deg))
        _bend(r, drop, side, knee)
        return _ankle(r, drop, side, 0) - target

    lo, hi = -35.0, 35.0
    flo, fhi = f(lo), f(hi)
    if flo * fhi > 0:
        best = lo if abs(flo) < abs(fhi) else hi
        r[key] = (sw_x, 0, d(best))
        _bend(r, drop, side, knee)
        return
    for _ in range(22):
        mid = 0.5 * (lo + hi)
        fm = f(mid)
        if (fm > 0) == (flo > 0):
            lo, flo = mid, fm
        else:
            hi = mid
    r[key] = (sw_x, 0, d(0.5 * (lo + hi)))
    _bend(r, drop, side, knee)


def _sweep(tau):
    """Forward offset (m) of a foot from its standing spot, by swing phase tau in cycles (0 = lift-off,
    0.5 = touchdown). Linear at the ground speed through the whole stance and a little either side, so the
    foot never slides while it is low; a cubic that keeps that speed at both ends carries it forward."""
    v = WALK_SPEED * WALK_CYCLE                      # m per cycle
    span = 0.5 - M_RISE - M_LAND                      # cycles of free swing
    half = v * (0.5 + M_RISE + M_LAND) * 0.5
    if tau >= 0.5 - M_LAND:                           # stance, from the late swing
        return half - v * (tau - (0.5 - M_LAND))
    if tau < M_RISE:                                  # the stance's far end
        return half - v * (tau + 1.0 - (0.5 - M_LAND))
    k = (tau - M_RISE) / span
    h00, h10 = 2 * k ** 3 - 3 * k ** 2 + 1, k ** 3 - 2 * k ** 2 + k
    h01, h11 = -2 * k ** 3 + 3 * k ** 2, k ** 3 - k ** 2
    tan = -v * span
    return h00 * (-half) + h10 * tan + h01 * half + h11 * tan


def legs(r, t):
    """Walks the legs so each planted foot sweeps back at exactly the ground speed (no slide), and
    solves the hips so the planted foot stays at floor height while the other clears it (the foot-slide
    metric counts any foot within 6 cm of the floor as planted)."""
    r["UpperLeg.L"] = (0, 0, 0)
    r["UpperLeg.R"] = (0, 0, 0)
    r["Hips"] = (0, d(5 * sw(t)), d(2 * sw(t)))
    for s in ("L", "R"):
        r["LowerLeg." + s] = (0, 0, 0)
        r["Foot." + s] = (0, 0, 0)
    hips = r["Hips"]
    r["Hips"] = (0, 0, 0)
    stand_x = {s: WALK_TRACK * _ankle(r, 0.0, s, 0) for s in ("L", "R")}
    r["Hips"] = hips
    floor = _ankle_z({"Hips": r["Hips"]}, 0.0, "L")   # standing, legs straight down
    lifts, taus, f0, sign = {}, {}, {}, {}
    for s, ph in (("L", 0.5), ("R", 0.0)):
        tau = ((t + ph) % 1.0 - 0.75) % 1.0
        taus[s] = tau
        x = tau / 0.5
        u = min(1.0, x / 0.1, (1.0 - x) / 0.3) if x < 1.0 else 0.0
        lifts[s] = u * u * (3.0 - 2.0 * u)
        r["UpperLeg." + s] = (0, 0, 0)
        f0[s] = _ankle(r, 0.0, s, 1)
        r["UpperLeg." + s] = (d(10), 0, 0)
        sign[s] = -1.0 if _ankle(r, 0.0, s, 1) > f0[s] else 1.0   # forward is where the thigh angle falls
        r["UpperLeg." + s] = (0, 0, 0)
    for s in ("L", "R"):
        _solve_thigh(r, 0.0, s, f0[s] + sign[s] * _sweep(taus[s]))
        _solve_roll(r, 0.0, s, stand_x[s])
        _solve_thigh(r, 0.0, s, f0[s] + sign[s] * _sweep(taus[s]))
    straight = {s: _ankle_z(r, 0.0, s) for s in ("L", "R")}
    stance = "L" if lifts["L"] < lifts["R"] else "R"
    drop = floor - straight[stance]       # the hips sink as the legs open
    for s in ("L", "R"):
        if lifts[s] <= 0.0:
            continue
        # The smallest knee bend, past the point where bending only lowers a forward-leaning leg, that
        # puts the ankle at the lift height above the floor.
        target = floor + LIFT
        heights = []
        for deg in range(0, 121, 3):
            r["LowerLeg." + s] = (d(deg), 0, 0)
            r["Foot." + s] = (d(-0.5 * deg), 0, 0)
            heights.append(_ankle_z(r, drop, s))
        low = heights.index(min(heights))
        pick = len(heights) - 1
        for n in range(low, len(heights)):
            if heights[n] >= target:
                pick = n
                break
        # capped: a heel kicked up to her seat reads, from behind and to the side, as a thigh splayed out
        k = min(pick * 3, WALK_KNEE) * lifts[s]
        # the bent knee pulls the ankle back: swing the thigh until the ankle is where the sweep puts it
        _solve_thigh(r, drop, s, f0[s] + sign[s] * _sweep(taus[s]), knee=k)
        _solve_roll(r, drop, s, stand_x[s], knee=k)
        _solve_thigh(r, drop, s, f0[s] + sign[s] * _sweep(taus[s]), knee=k)
    return drop


def walk(t):
    r = base_idle(t)
    tc = (t * 2.0) % 1.0      # the stride cycle
    drop = legs(r, tc)
    # the trunk counter-rotates against the hips (the shoulders swing with the opposite leg), bobs on each step
    # and rocks over the planted foot; the head steadies against it, eyes on where she goes
    r["Spine"] = (d(4.0 + 4.0 * sw(tc * 2)), d(-12 * sw(tc)), d(5 * sw(tc, 0.25)))
    r["Chest"] = (d(5.0 * sw(tc * 2, 0.1)), d(-12 * sw(tc, 0.04)), d(4 * sw(tc * 2, 0.3)))
    r["Neck"] = (d(-2.0 * sw(tc * 2, 0.2)), d(8 * sw(tc, 0.06)), 0)
    r["Head"] = (d(-4.0 * sw(tc * 2, 0.3)), d(10 * sw(tc, 0.08)), d(5 * sw(tc * 2, 0.2)))
    hips = (0, 0, drop)        # the hips already bob: they sink as the legs open (moved more, the feet slide)
    # Both arms aimed hanging and swinging hard against the legs, the forearm and claws trailing a beat behind
    # the upper arm (the follow-through). Rotations on top of the rest pose kept her right forearm raised.
    for s, sgn in (("L", 1.0), ("R", -1.0)):
        a = sgn * 0.85 * sw(tc)                  # + swings the arm back
        f = sgn * 1.1 * sw(tc, 0.1)              # the forearm trails the upper arm
        g = sgn * 1.2 * sw(tc, 0.16)             # the claws trail the forearm
        dirs = [(0.2, a, -0.9), (0.12, f - 0.45, -0.85), (0.05, g - 0.4, -0.9), (0.0, g - 0.2, -1.0)]
        dirs = [Vector(v).normalized()[:] for v in dirs]
        if s == "R":
            dirs = dirs[:3]
        _aim_arm(r, hips, s, dirs)
    return r, {"Hips": hips}


SIDE = {"L": 1.0, "R": -1.0}       # +X is her left
ARM = {"L": ("UpperArm.L", "LowerArm.L", "Hand.L", "Fingers.L"), "R": ("UpperArm.R", "LowerArm.R", "Hand.R")}
ARM_TIP = {"L": "Fingers.L", "R": "Hand.R"}
CURLED = ("Fingers.L",)


def _delta(name):
    """A bone's posed armature-space rotation from its rest (the pose must be current)."""
    pb = arm.pose.bones[name]
    return (pb.matrix.to_3x3().normalized() @ rest3(name).inverted()).to_quaternion()


def _aim(r, hips, name, v, side):
    """Turns one bone (keyed FK, no solver) so it points along v, in her frame: x out to `side`, y back, z
    up. The turn is the shortest one from the bone's rest direction, inside its posed parent, so a chain
    aimed root first lands each bone exactly where its direction says, with no branch to flip to."""
    pose(rots=r, locs={"Hips": hips})
    w = arm.matrix_world.to_3x3().inverted() @ Vector((v[0] * SIDE[side], v[1], v[2]))
    local = _delta(arm.pose.bones[name].parent.name).inverted() @ w.normalized()
    rest = rest3(name)
    if name in CURLED:
        # claws only curl (palmward, about their own knuckle axis) by as much as the keyed direction bends
        # from the hand: aimed the shortest way, or signed by which side of the palm the target falls, a hand
        # twisting under them flipped them half round in a frame (a bone pop) for no visible gain
        q = Quaternion(rest.col[0].normalized(), local.angle(rest.col[1]))
    else:
        q = rest.col[1].normalized().rotation_difference(local)
    r[name] = tuple(q.to_euler("XYZ"))


def _aim_arm(r, hips, side, dirs, w=1.0):
    """Aims a whole arm (dirs: one direction a bone, shoulder out), blended from the pose r already holds by
    `w` (a slerp a bone, each child against its blended parent)."""
    for name, v in zip(ARM[side], dirs):
        before = Euler(r.get(name, (0, 0, 0)), "XYZ").to_quaternion()
        _aim(r, hips, name, v, side)
        if w < 1.0:
            r[name] = tuple(before.slerp(Euler(r[name], "XYZ").to_quaternion(), w).to_euler("XYZ"))


def _lerp(a, b, k):
    return tuple(x + (y - x) * k for x, y in zip(a, b))


def _track(t, keys):
    """Catmull-Rom through keyed values [(time, tuple)], so the motion passes its keys without stopping
    (a smoothstep between keys halts at every one of them, which read as freezes). Holds past the ends."""
    if t <= keys[0][0]:
        return keys[0][1]
    if t >= keys[-1][0]:
        return keys[-1][1]
    i = max(n for n in range(len(keys) - 1) if keys[n][0] <= t)
    (t1, p1), (t2, p2) = keys[i], keys[i + 1]
    p0 = keys[i - 1][1] if i > 0 else p1
    p3 = keys[i + 2][1] if i + 2 < len(keys) else p2
    u = (t - t1) / (t2 - t1)
    u2, u3 = u * u, u * u * u
    return tuple(0.5 * (2 * b + (-a + c) * u + (2 * a - 5 * b + 4 * c - e) * u2 + (-a + 3 * b - 3 * c + e) * u3)
                 for a, b, c, e in zip(p0, p1, p2, p3))


def _dirs(t, keys):
    """Keyed arm directions (one tuple a bone): each bone's direction through its keys, renormalised. Each
    gap is first split in four on the sphere (the normalised chord midpoint is the great-circle one): a
    spline of the raw keys cut across the chord between two far-apart directions, and renormalised, the
    arm crawled out of one key, swung most of the way in a frame or two (an elbow-flipping pop) and crawled
    into the next."""
    for _ in range(2):
        split = [keys[0]]
        for (t0, a), (t1, b) in zip(keys, keys[1:]):
            mid = tuple((Vector(u).normalized() + Vector(v).normalized()).normalized()[:] for u, v in zip(a, b))
            split += [(0.5 * (t0 + t1), mid), (t1, b)]
        keys = split
    flat = [(k, sum(v, ())) for k, v in keys]
    f = _track(t, flat)
    return [Vector(f[i:i + 3]).normalized()[:] for i in range(0, len(f), 3)]


def _arm_diag(r, hips, side):
    pose(rots=r, locs={"Hips": hips})
    mw = arm.matrix_world
    return mw @ arm.pose.bones[ARM_TIP[side]].tail - mw @ arm.pose.bones[ARM[side][0]].head


def _foot_at(r, hips, side):
    pose(rots=r, locs={"Hips": hips})
    return arm.matrix_world @ arm.pose.bones["Foot." + side].head


PLANT_ERR = []


def _plant(r, hips, side, target, quick=False, roll=d(40)):
    """Thigh swing and roll and knee bend (a three-angle leg) that put the ankle at `target`; the foot is
    kept level. `quick` starts only from the pose r holds (last frame's), for small frame-to-frame moves;
    `roll` caps the thigh's roll."""
    def f(q):
        r["UpperLeg." + side] = (q[0], 0, q[1])
        r["LowerLeg." + side] = (q[2], 0, 0)
        return _foot_at(r, hips, side) - target

    def solve(q):
        for _ in range(24):
            e = f(q)
            if e.length < 5e-4:
                break
            h = d(0.4)
            cols = []
            for i in range(3):
                qq = list(q)
                qq[i] += h
                cols.append((f(qq) - e) / h)
            jm = Matrix((cols[0], cols[1], cols[2])).transposed()
            # damped least squares: a near-straight knee makes the plain inverse blow up
            jt = jm.transposed()
            dq = (jt @ jm + Matrix.Identity(3) * 1e-4).inverted() @ (jt @ e)
            q = [q[i] - max(-0.2, min(0.2, dq[i])) for i in range(3)]
            # a hip swings, rolls a little and never turns over: a thigh rolled half round with the swing
            # turned past the vertical puts the ankle in the same spot, and the foot flipped 180 degrees
            q[0] = min(d(100), max(d(-100), q[0]))
            q[1] = min(roll, max(-roll, q[1]))
            q[2] = min(d(120), max(0.0, q[2]))
        return f(q).length, sum(abs(a - b) for a, b in zip(q, seed)), q

    starts = [[r.get("UpperLeg." + side, (0, 0, 0))[0], r.get("UpperLeg." + side, (0, 0, 0))[2],
               max(r.get("LowerLeg." + side, (0, 0, 0))[0], d(5))]]
    seed = starts[0]
    if not quick:
        starts += [[d(a), 0.0, d(k)] for a in (-30, -10, 10, 30) for k in (10, 35)]
    # of the ones that reach, the nearest last frame's (no branch hop)
    best = min((solve(list(q0)) for q0 in starts), key=lambda s: (round(s[0], 2), s[1]))
    q = best[2]
    PLANT_ERR.append(best[0])
    r["UpperLeg." + side] = (q[0], 0, q[1])
    r["LowerLeg." + side] = (q[2], 0, 0)
    r["Foot." + side] = (-(q[0] + q[2]), 0, -q[1])


def _env(t, a, b):
    return smooth((t - a) / (b - a))


STAND = {}
_IDLE_LEGS = {}


def _stand():
    if not STAND:
        for s in ("L", "R"):
            STAND[s] = _foot_at({}, (0, 0, 0), s)
    return STAND


def idle(t):
    """Breathing, a slow shift of her weight from foot to foot (the hips sway and roll over the planted
    feet), the claws never still."""
    r = base_idle(t)
    br = sw(t * 2, 0.1)
    # two deep breaths a clip (the chest heaves, the shoulders rise with it) and a slow look round
    r["Chest"] = (r["Chest"][0] + d(5.0 * br), r["Chest"][1], r["Chest"][2])
    r["Neck"] = (d(-3.0 * br), 0, d(9.0 * sw(t, 0.15)))
    r["Head"] = (r["Head"][0] + d(3.0 * br), r["Head"][1], r["Head"][2] + d(10.0 * sw(t, 0.1)))
    r["UpperArm.L"] = (r["UpperArm.L"][0] - d(3 * br), r["UpperArm.L"][1], r["UpperArm.L"][2] - d(3 * sw(t, 0.6)))
    r["UpperArm.R"] = (r["UpperArm.R"][0] - d(3 * br), r["UpperArm.R"][1], r["UpperArm.R"][2] + d(3 * sw(t, 0.1)))
    r["Fingers.L"] = (r["Fingers.L"][0] + d(10 * sw(t * 2, 0.2)), 0, r["Fingers.L"][2])
    r["Hips"] = (0, d(5.0 * sw(t)), d(3.0 * sw(t, 0.3)))
    hips = (0.05 * sw(t), 0, 0.02 * sw(t * 2) - 0.035)
    for s in ("L", "R"):
        # seeded from a soft-kneed stand every frame (not from the last frame, which may be any frame:
        # the cloth springs sample out of order), so every frame lands on the same branch
        r["UpperLeg." + s], r["LowerLeg." + s] = (d(-4), 0, 0), (d(8), 0, 0)
        _plant(r, hips, s, _stand()[s])
    return r, {"Hips": hips}


# attack_idle's reach, a bone at a time (upper arm, forearm, hand, fingers): x out, y back, z up. One full
# grab a loop, anticipation, strike, recover: drawn (both claws pulled up and back by her shoulders, the
# trunk coiled back), strike (thrown straight at your face, close together, fingers spread), clutch (the
# claws close on you, the hands meeting, trembling), recover (the arms sink to her hips), drawn again. The
# upper arm stays below her shoulder (a raised arm tears through the hood brim).
REACH_DRAWN = ((0.4, 0.35, -0.55), (0.35, -0.55, 0.75), (0.1, -0.85, 0.5), (0.0, -0.6, -0.8))
REACH_COIL = ((0.45, 0.45, -0.35), (0.3, -0.35, 0.88), (0.1, -0.55, 0.83), (0.0, -0.7, -0.7))
REACH_STRIKE = ((0.14, -0.97, 0.12), (0.04, -0.99, 0.12), (0.0, -0.99, 0.05), (0.0, -0.85, -0.5))
REACH_CLUTCH = ((0.16, -0.95, 0.06), (-0.15, -0.95, 0.12), (-0.28, -0.9, 0.0), (-0.15, -0.25, -0.95))
REACH_RECOVER = ((0.25, -0.3, -0.92), (0.25, -0.85, -0.3), (0.1, -0.9, -0.4), (0.0, -0.4, -0.9))
REACH_KEYS = [(0.0, REACH_DRAWN), (0.18, REACH_COIL), (0.32, REACH_STRIKE), (0.42, REACH_STRIKE), (0.54, REACH_CLUTCH),
              (0.7, REACH_CLUTCH), (0.84, REACH_RECOVER), (1.0, REACH_DRAWN)]
# her trunk through it (deg, + leans forward): Spine, Chest, Neck, Head pitch and the hips forward (m, - is
# forward): reared back as she draws, thrown after her claws at the strike, hunched over the clutch
REACH_TRUNK = [(0.0, (2, 0, -4, -8, 0.04)), (0.18, (-4, -6, 2, -2, 0.08)), (0.32, (24, 16, -18, -30, -0.24)),
               (0.42, (24, 16, -18, -30, -0.24)), (0.54, (20, 14, -16, -28, -0.18)), (0.7, (18, 12, -14, -26, -0.16)),
               (0.84, (8, 4, -6, -12, -0.02)), (1.0, (2, 0, -4, -8, 0.04))]
STALK_CYCLES = 4          # foot cycles a 48-frame clip: short quick steps, not the walk's long stride
STALK_SWING = 0.35        # of a cycle, the foot in the air
STALK_LIFT = 0.08
STALK_DROP = 0.09         # m the hips sink into her crouch


def _stalk_foot(tau):
    """(back offset, lift) of a stalking foot by its cycle phase tau (0 = lift-off). In stance it sweeps
    back at the ground speed (no slide); the swing is a cubic that leaves and lands at that speed."""
    cyc = 2.0 / STALK_CYCLES                       # s a cycle (the clip is 2 s at rate 1)
    sweep = WALK_SPEED * cyc * (1.0 - STALK_SWING)
    half = 0.5 * sweep
    rate = sweep / (1.0 - STALK_SWING)
    if tau >= STALK_SWING:
        return -half + rate * (tau - STALK_SWING), 0.0
    k = tau / STALK_SWING
    tan = rate * STALK_SWING
    h00, h10 = 2 * k ** 3 - 3 * k ** 2 + 1, k ** 3 - 2 * k ** 2 + k
    h01, h11 = -2 * k ** 3 + 3 * k ** 2, k ** 3 - k ** 2
    u = smooth(min(1.0, k / 0.2, (1.0 - k) / 0.3))
    return h00 * half + h10 * tan - h01 * half + h11 * tan, STALK_LIFT * u


def attack_idle(t):
    """The reach, her stalk while she sees you: sunk in a crouch, short quick planted steps, and one grab a
    loop: the claws drawn back by her shoulders, thrown at your face, clutched trembling, sunk, drawn again."""
    r = base_idle(t)
    tc = t * STALK_CYCLES
    # the hips sink, bob down onto each planted foot and sway over it
    hips = (0.02 * sw(tc), 0.0, -STALK_DROP - 0.015 * sw(tc * 2, 0.25))
    r["Hips"] = (d(6), d(4 * sw(tc)), d(3 * sw(tc, 0.25)))
    tw = 0.3 * sw(t)
    tr = _track(t, REACH_TRUNK)
    shake = 2.0 * sw(t * 12) * _env(t, 0.5, 0.56) * (1.0 - _env(t, 0.7, 0.78))   # the clutch trembles
    r["Spine"] = (d(tr[0] + 2 * sw(tc * 2)), d(-3 * tw), d(-4 * tw))
    r["Chest"] = (d(tr[1] + shake), 0, d(-5 * tw))
    r["Neck"] = (d(tr[2]), 0, d(4 * tw))
    r["Head"] = (d(tr[3] + 3 * sw(tc * 2, 0.3)), 0, d(4 * tw))
    hips = (hips[0], tr[4], hips[2] - 0.3 * max(0.0, -tr[4]))
    feet = _stand()
    for s, ph in (("L", 0.0), ("R", 0.5)):
        back, lift = _stalk_foot((tc + ph) % 1.0)
        tgt = feet[s].copy()
        tgt.x *= 0.95
        tgt.y += back
        tgt.z += lift
        # seeded from last frame's leg (a bent knee on the first), so the thigh's roll never hops from one
        # side to the other between frames: seeded from the same bent knee every frame, the two rolls that
        # reach the step's end tied, and the knee swung across in one frame
        r["UpperLeg." + s], r["LowerLeg." + s] = _REACH_LEGS.get(s, ((d(-8), 0, 0), (d(20), 0, 0)))
        # the roll held small: where the crouched stance foot passed under her it took the whole roll to the
        # cap one frame and the other way the next (the knee thrown across); a 2 cm short plant reads as nothing
        _plant(r, hips, s, tgt, roll=d(14))
        _REACH_LEGS[s] = (r["UpperLeg." + s], r["LowerLeg." + s])
    for s, lag in (("L", 0.0), ("R", 0.015)):
        dirs = _dirs(max(0.0, t - lag), REACH_KEYS)
        if s == "R":
            dirs = dirs[:2] + [Vector(_lerp(dirs[2], dirs[3], 0.4)).normalized()[:]]  # her right hand is hand and claws in one
        _aim_arm(r, hips, s, dirs)
    return r, {"Hips": hips}


LUNGE_IDLE = None
_LUNGE_LEGS = {}
_REACH_LEGS = {}

# The lunge is ONE leap, by clip time (36 frames, 1.5 s): rear 0-0.1 (she rises back, claws up and wide),
# crouch 0.1-0.26 (she sinks back and down onto both feet, claws drawn back by her shoulders), launch 0.24-0.31 (both legs drive her up and at you), airborne
# 0.31-0.6 (both feet off the floor and tucked, the claws thrown out at your face at shoulder height, never
# overhead), land 0.6-0.66 (she drops into a deep crouch a long leap on, the left foot ahead), then she holds
# you: the claws stay on you, she pants over you (the capture and the game both stop near 0.93).
LUNGE_HIPS = [(0.0, (0, 0, 0)), (0.1, (0, 0.06, 0.0)), (0.18, (0, 0.1, -0.16)), (0.26, (0, 0.15, -0.28)),
              (0.31, (0, -0.12, -0.12)), (0.38, (0, -0.45, 0.12)), (0.46, (0, -0.78, 0.2)), (0.54, (0, -1.02, 0.08)),
              (0.6, (0, -1.14, -0.14)), (0.66, (0, -1.18, -0.26)), (0.78, (0, -1.2, -0.14)), (0.9, (0, -1.2, -0.08)),
              (1.0, (0, -1.2, -0.08))]
# Spine, Chest, Neck, Head pitch (deg, + leans forward; the neck and head bend back to keep her eyes on you and
# her head up out of the hood in the crouch, but no further than the hood brim follows: bent right back the
# brim cut across her face) and the chest's twist. She rears back first (the threat), coils down, is thrown
# at you.
LUNGE_TRUNK = [(0.0, (0, 0, 0, 0, 0)), (0.1, (-8, -6, 4, 2, -6)), (0.26, (16, 10, -12, -18, 12)),
               (0.32, (12, 8, -8, -14, -4)), (0.44, (18, 12, -12, -20, -6)), (0.56, (20, 14, -12, -20, -4)),
               (0.64, (22, 16, -12, -20, -2)), (0.76, (14, 10, -10, -18, 0)), (1.0, (10, 8, -8, -16, 0))]
# reared: both claws up and wide over her, hooked (the threat); drawn: pulled back by her shoulders for the
# throw; strike: both thrown straight at your face, converging; grab: closing on you; hold.
REARED = ((0.55, 0.25, -0.8), (0.5, -0.1, 0.86), (0.15, -0.6, 0.78), (0.0, -0.75, -0.66))
COCKED = ((0.45, 0.4, -0.35), (0.3, -0.2, 0.93), (0.05, -0.7, 0.7), (0.0, -0.6, -0.8))
# the claws stay hooked through the strike: thrown open at the lens they read as a hand twice the size and
# snapped open in one frame
STRIKE = ((0.1, -0.97, 0.2), (0.0, -0.99, 0.12), (-0.05, -0.99, 0.05), (0.0, -0.85, -0.5))
GRAB = ((0.14, -0.96, 0.12), (-0.15, -0.95, 0.18), (-0.25, -0.9, 0.05), (-0.15, -0.25, -0.95))
HOLD = ((0.2, -0.93, 0.1), (-0.1, -0.93, 0.18), (-0.2, -0.9, 0.05), (-0.1, -0.35, -0.9))
LUNGE_ARMS = [(0.0, REARED), (0.1, REARED), (0.24, COCKED), (0.42, STRIKE), (0.54, STRIKE),
              (0.64, GRAB), (0.78, HOLD), (1.0, HOLD)]
# Each foot: (take-off, landing, landing spot ahead of the stand (m), height of its tuck (m)). Both push off
# together and leave the floor before the hips peak; the left lands first, a little ahead of her hips, the
# right just behind them.
LUNGE_FEET = (("L", 0.30, 0.58, 1.18 + 0.22, 0.62), ("R", 0.33, 0.62, 1.18 - 0.15, 0.55))


def _lunge_foot(t, stand, off, land, ahead, high):
    """Where a lunging foot is: planted at the stand until take-off, a tucked arc through the leap, planted
    `ahead` on from landing."""
    tgt = stand.copy()
    if t <= off:
        return tgt
    u = min(1.0, (t - off) / (land - off))
    # the feet trail the hips off the floor and kick through late (heels tucked up under her, not hanging)
    tgt.y -= ahead * smooth(u * u * (3.0 - 2.0 * u))
    tgt.z += high * math.sin(math.pi * u) ** 0.7
    return tgt


def attack(t):
    """The lunge, played once: a single leap at you, ending crouched over you a long leap on (the game then
    blends to idle where she stands)."""
    r = base_idle(0.6 * t)
    hips = _track(t, LUNGE_HIPS)
    hips = (hips[0], hips[1], hips[2] + 0.008 * sw(t * 2.5) * _env(t, 0.66, 0.8))
    tr = _track(t, LUNGE_TRUNK)
    for n, v in zip(("Spine", "Chest", "Neck", "Head"), tr[:4]):
        x, y, z = r.get(n, (0, 0, 0))
        r[n] = (x + d(v), y, z + (d(tr[4]) if n == "Chest" else 0.0))
    r["Hips"] = (d(-6 * _env(t, 0.0, 0.1) + 16 * _env(t, 0.1, 0.26) - 10 * _env(t, 0.26, 0.36) + 10 * _env(t, 0.58, 0.66)
                   - 6 * _env(t, 0.7, 0.95)),
                 0, d(-4 * _env(t, 0.12, 0.3) + 4 * _env(t, 0.44, 0.75)))
    # the held claws tremble on you, and she pants over you to the end (no dead hold)
    x, y, z = r["Chest"]
    r["Chest"] = (x + d(2.0 * sw(t * 14) * _env(t, 0.66, 0.72) + 2.5 * sw(t * 3) * _env(t, 0.66, 0.8)), y, z)
    wa = _env(t, 0.0, 0.1)
    for s in ("L", "R"):
        side_t = t if s == "L" else max(0.0, t - 0.025)      # her right hand a beat behind the left
        dirs = _dirs(side_t, LUNGE_ARMS)
        if s == "R":
            dirs = dirs[:2] + [Vector(_lerp(dirs[2], dirs[3], 0.4)).normalized()[:]]
        _aim_arm(r, hips, s, dirs, wa)
    feet = _stand()
    for s, off, land, ahead, high in LUNGE_FEET:
        tgt = _lunge_foot(t, feet[s], off, land, ahead, high)
        if s in _LUNGE_LEGS:
            r["UpperLeg." + s], r["LowerLeg." + s] = _LUNGE_LEGS[s]
        else:
            r["UpperLeg." + s], r["LowerLeg." + s] = (d(-8), 0, 0), (d(20), 0, 0)
        _plant(r, hips, s, tgt)
        _LUNGE_LEGS[s] = (r["UpperLeg." + s], r["LowerLeg." + s])
    return r, {"Hips": hips}


def _diag(name, frames, fn):
    """WITCH_DIAG=1: a line a frame of where the hips, claws (from the shoulder) and ankles are."""
    if not os.environ.get("WITCH_DIAG"):
        return
    for f in range(0, frames + 1, 2):
        PLANT_ERR.clear()
        r, locs = fn(f / frames)
        hips = locs.get("Hips", (0, 0, 0))
        cl, cr = _arm_diag(r, hips, "L"), _arm_diag(r, hips, "R")
        fl, fr = _foot_at(r, hips, "L"), _foot_at(r, hips, "R")
        print("DIAG %s f%02d hips %+.2f %+.2f %+.2f clawL %+.2f %+.2f %+.2f clawR %+.2f %+.2f %+.2f "
              "footL y%+.2f z%+.3f footR y%+.2f z%+.3f plant %.3f" % (
                  name, f, *hips, *cl, *cr, fl.y, fl.z, fr.y, fr.z, max(PLANT_ERR or [0])))


_diag("attack_idle", 48, attack_idle)
_diag("attack", 36, attack)
_LUNGE_LEGS.clear()
_IDLE_LEGS.clear()
_REACH_LEGS.clear()
clip("idle", 48, idle)
clip("walk", 30, walk)
clip("attack_idle", 48, attack_idle)
clip("attack", 36, attack, loop=False)
arm.animation_data.action = None
pose()
stop(5)

bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.gltf(filepath=os.path.abspath(DST), export_format="GLB", export_animation_mode="NLA_TRACKS",
                          export_apply=False, export_yup=True, export_image_format="NONE", export_force_sampling=True)
vs = [v.co for v in body.data.vertices]
print("DONE verts", len(vs), "faces", len(body.data.polygons))
for i, c in enumerate(EYES):
    pass
