"""Builds assets/witch/witch.glb and witch_atlas.png: the scary witch, rigged and animated.

    blender -b -P tools/make_witch.py -- <Witch.glb from Sketchfab> assets/witch/witch.glb [--stage=N] [--keep=path.blend]

Source: "Witch" by Tamko Dmitry, https://sketchfab.com/3d-models/witch-0b6f69bbaa864bd78c0cfa98dabca0aa,
CC Attribution 4.0: one static mesh of a fat hooded woman with a staff and bottles. This script
  1. drops the staff and the bottles and makes her gaunt (narrow, flat bellied, long legged),
  2. adds a tattered hem and cloak edge, stringy hair, and black hollow eye sockets,
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

# ---------------------------------------------------------------- 2. tatter, hair, sockets
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

# Hair and sockets take their own swatches in the corner the staff and bottles left free.
HAIR_BOX = (0.60, 0.02, 0.74, 0.14)     # u0, v0, u1, v1
SOCKET_UV = (0.93, 0.05)
n_hair = 0
for i in range(12):
    ang = d(60 + i * 22)
    root = Vector((0.85 + 2.7 * math.sin(ang), 0.4 - 2.2 * math.cos(ang), fz(24.6) - rng.uniform(0, 1.2)))
    ln = rng.uniform(5.5, 9.5)
    w0 = 0.16
    jit = [(rng.uniform(-0.25, 0.25), rng.uniform(-0.2, 0.2)) for _ in range(6)]
    for side in (0, 1):
        rings = []
        for k in range(6):
            t = k / 5
            c = root + Vector((math.sin(ang) * 0.3 * t + jit[k][0] * t, 0.5 * t + jit[k][1] * t, -ln * t))
            w = w0 * (1 - 0.8 * t)
            rings.append((bm.verts.new(c + Vector((-w, 0, 0))), bm.verts.new(c + Vector((w, 0, 0)))))
        u0 = HAIR_BOX[0] + (HAIR_BOX[2] - HAIR_BOX[0]) * (i + 0.15) / 12
        du = (HAIR_BOX[2] - HAIR_BOX[0]) * 0.7 / 12
        for k in range(5):
            a1, b1 = rings[k]
            a2, b2 = rings[k + 1]
            f = bm.faces.new((a1, b1, b2, a2) if side == 0 else (a1, a2, b2, b1))
            f[kind_l] = HAIR
            for lp in f.loops:
                kk = k if lp.vert in (a1, b1) else k + 1
                lp[uvl].uv = (u0 + (du if lp.vert in (b1, b2) else 0.0),
                              HAIR_BOX[3] - (HAIR_BOX[3] - HAIR_BOX[1]) * kk / 5)
    n_hair += 1

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
for v in body.data.vertices:
    p = v.co
    if v.index in CAPE_V and p.z < fz(23.2) + 0.6:
        # the cape hangs off the chest (its shoulder flaps then ride up with the arms through Cape.L/R): an arm
        # weight here, cut off where the arm's weights end, tore a plate out of it when the arm rose
        g = weights(p, ["Chest", "Neck", "Spine"])
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
    for n, w in g.items():
        if w > 0.004:
            body.vertex_groups[n].add([v.index], w, "REPLACE")

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
    elif abs(p.x - 0.8) > 5.6 or v.index in ARM_SKIN:      # sleeves and hands stay on the arms
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


for n in ("LowerArm.L", "Hand.L", "Fingers.L", "Hand.R", "UpperArm.L"):
    arm.data.bones[n].inherit_scale = "NONE"
pose(
    rots={"Spine": (d(10), 0, 0), "Chest": (d(14), 0, 0), "Neck": (d(12), 0, 0), "Head": (d(-14), 0, 0),
          "UpperArm.L": (d(3), 0, d(-5)), "UpperArm.R": (d(5), 0, d(6)), "Fingers.L": (d(-22), 0, 0)},
    # long bony fingers, but a hand no bigger than her face (the source's left one was a shovel)
    scales={"UpperArm.L": (1, 1.15, 1), "LowerArm.L": (1.0, 1.25, 1.0), "Hand.L": (0.92, 0.95, 0.92),
            "Fingers.L": (1.0, 0.9, 1.0), "Hand.R": (0.86, 1.05, 0.86)},
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

W, H = base_img.size
src = np.array(base_img.pixels[:], dtype=np.float32).reshape(H, W, 4)[..., :3]   # row 0 = v 0
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
for _ in range(8):
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
lum_s = box(src_lum, 1)
detail = np.clip(lum_s / np.maximum(box(src_lum, 18), 0.02), 0.55, 1.6)
ang = np.arctan2(P[..., 1] - 0.05, P[..., 0] - 0.07)   # around her body axis, for folds

out = np.full((H, W, 3), 0.3, dtype=np.float32)
k = KINDS

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
twill = 0.5 + 0.5 * np.sin((ang * 0.32 + z) * 420.0)
col *= (0.9 + 0.1 * twill + 0.16 * (fine_n - 0.5))[..., None]
band = np.clip(1 - np.abs(z - 0.98 - 0.02 * mid_n) / 0.045, 0, 1) > 0.0
zig = np.abs(((ang * 24.0) % 2.0) - 1.0)                      # a zigzag of faded ochre thread
stitchrow = (np.abs((z - 0.98) / 0.03 - (zig - 0.5)) < 0.22) | (np.abs(np.abs(z - 0.98) - 0.04) < 0.005)
emb = band & stitchrow & (noise(P, 25, 12) > 0.3)              # worn through in places
col[m & emb] = (C(0.52, 0.4, 0.2) * (0.75 + 0.4 * fine_n[m & emb])[:, None])
hem = np.clip((0.55 + 0.25 * mid_n - z) / 0.35, 0, 1)
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

# Cloak and hood: moss-green wool fading to peat brown, deep folds, a twill weave, darned holes,
# a darker felted border at the hem and the bleached wear of the source's high spots.
m = (k == CLOAK)
col = mix(np.broadcast_to(C(0.30, 0.36, 0.16), (H, W, 3)).copy(), C(0.36, 0.25, 0.14), np.clip(lo_n * 2 - 0.5, 0, 1))
col = mix(col, C(0.22, 0.27, 0.13), np.clip((mid_n - 0.55) * 4.0, 0, 1) * 0.6)
warp = fbm(P, 3.0, 5) * 5.0
folds = 0.6 * np.sin(ang * 9.0 + warp) + 0.4 * np.sin(ang * 22.0 + warp * 1.5 + z * 4.0)
folds = np.clip(0.5 + 0.5 * folds, 0, 1)
col *= (0.62 + 0.5 * folds ** 1.2)[..., None]
twill = 0.5 + 0.5 * np.sin((P[..., 0] + P[..., 1] + z) * 380.0)
col *= (0.86 + 0.14 * twill + 0.2 * (fine_n - 0.5))[..., None]
col *= np.clip(detail, 0.7, 1.3)[..., None] ** 0.8          # the source's painted creases
wear = np.clip((detail - 1.08) * 3.0, 0, 1) * 0.45
col = mix(col, C(0.5, 0.48, 0.36), wear)
darn = (noise(P, 9, 14) > 0.82) & ((np.sin(P[..., 0] * 600) > 0.4) | (np.sin(z * 600) > 0.4))
col[m & darn] = (C(0.4, 0.33, 0.22) * (0.8 + 0.3 * fine_n[m & darn])[:, None])
border = np.clip((1.58 + 0.03 * mid_n - z) / 0.06, 0, 1)
col = mix(col, C(0.14, 0.13, 0.08), border * 0.7)
out[m] = col[m]

m = (k == HOODIN)
out[m] = (C(0.07, 0.06, 0.07) * (0.8 + 0.4 * fine_n[..., None]))[m]

# Skin (arms, hands, face): pallid grey-green, bruised purple, veined; the face keeps its painted features.
for kk, strength in ((SKIN, 0.4), (FACE, 0.65)):
    m = (k == kk)
    col = mix(np.broadcast_to(C(0.43, 0.46, 0.38), (H, W, 3)).copy(), C(0.44, 0.36, 0.44), np.clip(mid_n * 2.2 - 0.7, 0, 1))
    col = mix(col, C(0.58, 0.55, 0.48), np.clip(lo_n * 2 - 1.1, 0, 1) * 0.5)
    vein = np.clip(1 - np.abs(fbm(P, 14.0, 6, 3) - 0.5) / 0.025, 0, 1)
    col = mix(col, C(0.33, 0.33, 0.46), vein * 0.55)
    col *= (1.0 + strength * (detail - 1.0))[..., None] * (0.92 + 0.16 * fine_n)[..., None]
    out[m] = col[m]
# Nails and fingertips: the darkest skin texels are the source's nails: keep them dark and horn-yellow.
m = (k == SKIN) & (lum_s < 0.18)
out[m] = (C(0.2, 0.18, 0.1) * (0.8 + 0.4 * fine_n[..., None]))[m]

m = (k == MOUTH)
out[m] = (C(0.32, 0.07, 0.08) * np.clip(detail, 0.5, 1.3)[..., None])[m]

# Leg wraps: dirty linen over the source's stripes, browner and filthier toward the feet.
m = (k == WRAPS)
col = mix(np.broadcast_to(C(0.36, 0.31, 0.24), (H, W, 3)).copy(), C(0.22, 0.18, 0.13), np.clip(mid_n * 2 - 0.6, 0, 1))
col = mix(col, C(0.16, 0.13, 0.1), np.clip((0.35 - z) / 0.3, 0, 1) * 0.7)
col *= (detail ** 0.7)[..., None] * (0.9 + 0.2 * fine_n)[..., None]
out[m] = col[m]

m = (k == FEET)
out[m] = (C(0.27, 0.21, 0.16) * (detail ** 0.8)[..., None] * (0.85 + 0.3 * fine_n)[..., None])[m]

m = (k == BELT)
col = C(0.43, 0.2, 0.13) * (detail ** 1.2)[..., None] * (0.85 + 0.3 * mid_n)[..., None]
out[m] = col[m]

m = (k == STRANDS)
out[m] = (C(0.11, 0.11, 0.1) * (0.8 + 0.4 * fine_n[..., None]))[m]

m = (k == SOCKET) | (k == 0)
out[m] = 0.02

# Hair swatch: lank grey strands, each strip its own shade, darker at the roots.
hu0, hv0, hu1, hv1 = (int(HAIR_BOX[0] * W) - 4, int(HAIR_BOX[1] * H) - 4, int(HAIR_BOX[2] * W) + 4, int(HAIR_BOX[3] * H) + 4)
uu = np.arange(hu0, hu1)[None, :].astype(np.float32)
vv = np.arange(hv0, hv1)[:, None].astype(np.float32)
streak = noise(np.stack(np.broadcast_arrays(uu * 0.9, vv * 0.02, np.zeros_like(uu * vv)), -1), 1.0, 7)
root = np.clip((vv - hv0) / (hv1 - hv0), 0, 1)           # v up: the top of the strip is the root
g = (0.22 + 0.38 * streak) * (1.0 - 0.45 * root)
out[hv0:hv1, hu0:hu1] = np.stack([g * 0.97, g, g * 0.92], -1)
su, sv = int(SOCKET_UV[0] * W), int(SOCKET_UV[1] * H)
out[sv - 6:sv + 6, su - 6:su + 6] = 0.02

out = np.clip(out, 0, 1)
ATLAS = os.path.join(os.path.dirname(os.path.abspath(DST)), "witch_atlas.png")
Image.fromarray((out[::-1] * 255 + 0.5).astype(np.uint8), "RGB").save(ATLAS, optimize=True)
print("atlas bytes", os.path.getsize(ATLAS))
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
            "chest_x": chain(trunk, 0), "chest_z": chain(trunk, 2), "head_x": chain(head, 0), "head_z": chain(head, 2),
            "arm_l": rots.get("UpperArm.L", (0, 0, 0)), "arm_r": rots.get("UpperArm.R", (0, 0, 0))}


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
    drag = [d(5.5) * v for v in fwd]                       # radians the hem trails per m/s
    robe = _spring(drag, loop)
    hood_x = _spring([r["head_x"] + 0.6 * dg for r, dg in zip(rows, drag)], loop, w=2 * math.pi * 1.8)
    hood_z = _spring([r["head_z"] for r in rows], loop, w=2 * math.pi * 1.8)
    # the cape hangs half by the chest and half by its own weight
    cape_x = _spring([0.5 * r["chest_x"] + 1.1 * dg for r, dg in zip(rows, drag)], loop, w=2 * math.pi * 1.2)
    cape_z = _spring([r["chest_z"] for r in rows], loop, w=2 * math.pi * 1.2)
    out = []
    for f, r in enumerate(rows):
        fade = 1.0
        if not loop:       # the lunge ends on idle's first frame: the swing has settled by then
            fade = 1.0 - smooth((f / (n - 1) - 0.86) / 0.14)
        rb = robe[f] * fade
        kf = math.atan2(max(0.0, r["knee_f"] - KNEE_F0 - 0.02), 0.5)
        kb = math.atan2(max(0.0, r["knee_b"] - KNEE_B0 - 0.02), 0.5)
        hx = (hood_x[f] - r["head_x"]) * fade
        hz = (hood_z[f] - r["head_z"]) * fade
        cx = (cape_x[f] - r["chest_x"]) * fade
        cz = (cape_z[f] - r["chest_z"]) * fade
        al, ar = r["arm_l"], r["arm_r"]
        out.append({
            "Robe.F": (rb - 1.15 * kf, 0, 0),
            "Robe.B": (rb + 1.15 * kb, 0, 0),
            "Robe.L": (rb, 0, 0),
            "Robe.R": (rb, 0, 0),
            "Hood": (hx, 0, hz),
            "Cape.B": (cx, 0, cz),
            "Cape.L": (0.8 * cx, 0, cz),
            "Cape.R": (0.8 * cx, 0, cz),
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
CLOTH_AMP = {"idle": (3.0, 1), "walk": (4.0, 2), "attack_idle": (3.5, 1), "attack": (3.0, 1)}


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


def idle(t):
    return base_idle(t), {"Hips": (0, 0, 0.012 * sw(t * 2))}


STRIDE = 35
LIFT = 0.13


def _ankle(r, drop, side, axis=2):
    pose(rots=r, locs={"Hips": (0, 0, drop)})
    return (arm.matrix_world @ arm.pose.bones["Foot." + side].head)[axis]


def _ankle_z(r, drop, side):
    return _ankle(r, drop, side, 2)


WALK_SPEED = 1.3     # m/s, the speed the game plays the walk clip at (rate 1)
WALK_CYCLE = 1.25    # s, 30 frames at 24 fps
M_RISE = 0.02        # cycles of the swing, from lift-off, the foot is still low and still sweeping back
M_LAND = 0.07        # cycles before touchdown the foot is already low and sweeping back


def _solve_thigh(r, drop, side, target, probe=0.0):
    """The thigh angle (deg) that puts the ankle's forward coordinate at `target` (bisection)."""
    key = "UpperLeg." + side
    roll = r[key][2]

    def f(deg):
        r[key] = (d(deg), 0, roll)
        return _ankle(r, drop, side, 1) - target

    lo, hi = -70.0, 70.0
    flo, fhi = f(lo), f(hi)
    if flo * fhi > 0:
        best = lo if abs(flo) < abs(fhi) else hi
        r[key] = (d(best), 0, roll)
        return best
    for _ in range(22):
        mid = 0.5 * (lo + hi)
        fm = f(mid)
        if (fm > 0) == (flo > 0):
            lo, flo = mid, fm
        else:
            hi = mid
    r[key] = (d(0.5 * (lo + hi)), 0, roll)
    return 0.5 * (lo + hi)


def _solve_roll(r, drop, side, target):
    """Rolls the thigh sideways (keeping its swing) until the ankle stands at lateral `target`."""
    key = "UpperLeg." + side
    sw_x = r[key][0]

    def f(deg):
        r[key] = (sw_x, 0, d(deg))
        return _ankle(r, drop, side, 0) - target

    lo, hi = -35.0, 35.0
    flo, fhi = f(lo), f(hi)
    if flo * fhi > 0:
        best = lo if abs(flo) < abs(fhi) else hi
        r[key] = (sw_x, 0, d(best))
        return
    for _ in range(22):
        mid = 0.5 * (lo + hi)
        fm = f(mid)
        if (fm > 0) == (flo > 0):
            lo, flo = mid, fm
        else:
            hi = mid
    r[key] = (sw_x, 0, d(0.5 * (lo + hi)))


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
    stand_x = {s: _ankle(r, 0.0, s, 0) for s in ("L", "R")}
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
        k = pick * 3 * lifts[s]
        r["LowerLeg." + s] = (d(k), 0, 0)
        r["Foot." + s] = (d(-0.5 * k), 0, 0)
        # the bent knee pulls the ankle back: swing the thigh until the ankle is where the sweep puts it
        _solve_thigh(r, drop, s, f0[s] + sign[s] * _sweep(taus[s]))
        _solve_roll(r, drop, s, stand_x[s])
        _solve_thigh(r, drop, s, f0[s] + sign[s] * _sweep(taus[s]))
    return drop


def walk(t):
    r = base_idle(t)
    drop = legs(r, t)
    r["Spine"] = (d(3.0 * sw(t * 2)), d(-8 * sw(t)), d(4 * sw(t, 0.25)))
    r["Chest"] = (d(4.0 * sw(t * 2, 0.1)), d(-6 * sw(t)), d(3 * sw(t * 2, 0.3)))
    r["Head"] = (d(4.0 * sw(t * 2, 0.3)), d(10 * sw(t)), d(5 * sw(t * 2, 0.2)))
    r["UpperArm.L"] = (d(-26 * sw(t)), 0, d(-6 + 4 * sw(t * 2)))
    r["UpperArm.R"] = (d(26 * sw(t)), 0, d(6 + 4 * sw(t * 2)))
    r["LowerArm.L"] = (d(-10 - 8 * sw(t, 0.25)), 0, 0)
    r["LowerArm.R"] = (d(-10 + 10 * sw(t, 0.25)), 0, d(8 * sw(t * 2, 0.5)))
    r["Hand.R"] = (d(20 * sw(t * 2, 0.3)), d(16 * sw(t, 0.1)), d(18 * sw(t * 2, 0.6)))
    return r, {"Hips": (0, 0, drop)}


ARM_TIP = {"L": ("Fingers.L", "UpperArm.L", "LowerArm.L"), "R": ("Hand.R", "UpperArm.R", "LowerArm.R")}
_ARM_LAST = {}


def _arm_tip(r, hips, side):
    pose(rots=r, locs={"Hips": hips})
    tip, up, low = ARM_TIP[side]
    pb = arm.pose.bones
    mw = arm.matrix_world
    return mw @ pb[tip].tail, mw @ pb[up].head, mw @ pb[low].head


def _arm_len(side):
    tip, up, _low = ARM_TIP[side]
    return (arm.data.bones[tip].tail_local - arm.data.bones[up].head_local).length * 0.985


def _arm_to(r, hips, side, vec):
    """Shoulder swing (forward and out) and elbow bend that put the claw tip at shoulder + vec (world, m);
    of the solutions that reach, the one nearest the last frame's, else the one whose elbow hangs lowest."""
    _tip, up, low = ARM_TIP[side]
    y0 = r.get(up, (0, 0, 0))[1]

    def f(q):
        r[up] = (q[0], q[3], q[1])
        r[low] = (q[2], 0, 0)
        tip, sh, _el = _arm_tip(r, hips, side)
        return tip - (sh + vec)

    def solve(q):
        for _ in range(40):
            e = f(q)
            if e.length < 2e-3:
                break
            h = d(0.4)
            cols = []
            for i in range(4):
                qq = list(q)
                qq[i] += h
                cols.append((f(qq) - e) / h)
            jm = np.array([tuple(c) for c in cols]).T          # 3x4: the upper arm's twist is free too
            # damped least squares: a straight arm is singular for "shorten", and a plain inverse stalled
            # there (the claw left 13-50 cm short, so the solver hopped to another branch)
            dq = jm.T @ np.linalg.solve(jm @ jm.T + np.eye(3) * 1e-3, np.array(tuple(e)))
            q = [q[i] - max(-0.25, min(0.25, dq[i])) for i in range(4)]
            q[0] = math.remainder(q[0], 2 * math.pi)
            q[1] = math.remainder(q[1], 2 * math.pi)
            q[2] = min(d(150), max(d(-150), q[2]))
            q[3] = min(y0 + d(70), max(y0 - d(70), q[3]))
        err = f(q).length
        tip, sh, el = _arm_tip(r, hips, side)
        mid = (tip + sh) * 0.5
        return round(err, 2), round(el.z - mid.z, 2), abs(q[2]), q

    starts = [[r.get(up, (0, 0, 0))[0], r.get(up, (0, 0, 0))[2], r.get(low, (0, 0, 0))[0], y0]]
    starts += [list(_ARM_LAST[side])] if side in _ARM_LAST else []
    starts += [[d(a), d(b), d(k), y0] for a in (-90, -40) for b in (0,) for k in (-50, 50)]
    starts += [[d(a), d(b), d(k), y0] for a in (-150, 0, 60) for b in (-60, 60) for k in (-90, 90)]
    sols = [solve(list(q0)) for q0 in starts]
    best = min(sols)
    last = _ARM_LAST.get(side)
    if last is not None:
        # frame to frame the arm keeps the branch it was on: two solutions that reach equally well can be
        # the upper arm turned half round, and switching between them swung it 170 degrees in a frame
        # each radian away from last frame's pose costs like 6 cm of miss: a claw a little short beats a flip
        best = min(sols, key=lambda sl: sl[0] + 0.06 * sum(abs(math.remainder(a - b, 2 * math.pi))
                                                          for a, b in zip(sl[3], last)))
    q = best[3]
    _ARM_LAST[side] = q
    r[up] = (q[0], q[3], q[1])
    r[low] = (q[2], 0, 0)


def _shoulder_x(side):
    return arm.data.bones[ARM_TIP[side][1]].head_local.x


def _toward(side, x, y, z, frac):
    """A world vector from her shoulder: (x out to that side, y back, z up), `frac` of the arm's length."""
    v = Vector((x * (1.0 if _shoulder_x(side) > 0 else -1.0), y, z)).normalized()
    return v * (frac * _arm_len(side))


def reach(t):
    """attack_idle, the walk while she sees you: both claws out at your face, one thrusting at full stretch
    while the other draws back to her chest and clutches, the shoulders twisting into each reach. One reach per
    hand per cycle; the arms are aimed (IK), not posed, so the claw arrives where she is looking."""
    r = base_idle(t)
    rl = 0.5 + 0.5 * sw(t)            # 1 = her left arm at full reach
    rr = 1.0 - rl
    r["Spine"] = (d(8 + 2 * sw(t * 2)), d(-3 * sw(t)), d(-7 * sw(t)))
    r["Chest"] = (d(8 + 2 * sw(t * 2, 0.1)), 0, d(-9 * sw(t)))
    r["Neck"] = (d(-4), 0, 0)
    r["Head"] = (d(-12 + 3 * sw(t * 2, 0.3)), 0, d(10 * sw(t)))
    r["Hand.L"] = (d(12 * rl - 10 * rr), 0, 0)
    r["Fingers.L"] = (d(25 * rl - 60 * rr), 0, 0)
    r["Hand.R"] = (d(-15 * rl + 20 * rr), d(10 * rl), 0)
    return r, {"L": rl, "R": rr}


def _reach_vec(side, k):
    out = _toward(side, 0.35, -1.0, -0.15, 0.55)       # drawn back to the chest, claw curled
    full = _toward(side, 0.3, -1.0, 0.18, 0.95)       # at full stretch, up at your face
    return out.lerp(full, smooth(k))


def attack_idle(t):
    r, k = reach(t)
    drop = legs(r, t)
    for s in ("L", "R"):
        _arm_to(r, (0, 0, drop), s, _reach_vec(s, k[s]))
    return r, {"Hips": (0, 0, drop)}


def _foot_at(r, hips, side):
    pose(rots=r, locs={"Hips": hips})
    return arm.matrix_world @ arm.pose.bones["Foot." + side].head


def _plant(r, hips, side, target):
    """Thigh swing and knee bend (a two-bone leg in her sagittal plane) that put the ankle at target's
    forward and height coordinates; the foot is kept level."""
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
            if abs(jm.determinant()) < 1e-10:
                break
            dq = jm.inverted() @ e
            q = [q[i] - max(-0.2, min(0.2, dq[i])) for i in range(3)]
            q[2] = min(d(120), max(0.0, q[2]))
        return f(q).length, q[2], q

    # several starts (a knee that folds the shin up behind her is a solution too, so the bent-least
    # of the ones that reach is kept)
    starts = [[r["UpperLeg." + side][0], r["UpperLeg." + side][2], max(r["LowerLeg." + side][0], d(5))]]
    starts += [[d(a), 0.0, d(k)] for a in (-30, -10, 10, 30) for k in (10, 35)]
    best = min((solve(list(q0)) for q0 in starts), key=lambda s: (round(s[0], 2), s[1]))
    q = best[2]
    r["UpperLeg." + side] = (q[0], 0, q[1])
    r["LowerLeg." + side] = (q[2], 0, 0)
    r["Foot." + side] = (-(q[0] + q[2]), 0, -q[1])


def _env(t, a, b):
    return smooth((t - a) / (b - a))


LUNGE_IDLE = None


def attack(t):
    """The lunge, played once (the game plays it whole, then blends to idle): she gathers (sinks, rears
    back, claws cocked behind her), drives off the back foot a long step at you with both claws, grabs,
    holds, and steps back to her idle stance (the last frame is idle's first, so the blend is seamless)."""
    global LUNGE_IDLE
    if LUNGE_IDLE is None:
        LUNGE_IDLE = base_idle(0.0)
        pose()
        hang = {}
        for s in ("L", "R"):
            tip, sh, _el = _arm_tip(dict(LUNGE_IDLE), (0, 0, 0), s)
            hang[s] = tip - sh
        pose()
        LUNGE_IDLE = (LUNGE_IDLE, {s: _foot_at({}, (0, 0, 0), s) for s in ("L", "R")}, hang)
    r = dict(LUNGE_IDLE[0])
    feet = LUNGE_IDLE[1]
    gather = _env(t, 0.0, 0.26) * (1 - _env(t, 0.26, 0.4))
    strike = _env(t, 0.24, 0.4) * (1 - _env(t, 0.64, 0.96))
    grab = _env(t, 0.36, 0.46) * (1 - _env(t, 0.62, 0.86))
    step = _env(t, 0.24, 0.42) * (1 - _env(t, 0.62, 0.92))

    def add(n, dx=0.0, dy=0.0, dz=0.0):
        x, y, z = r.get(n, (0, 0, 0))
        r[n] = (x + d(dx), y + d(dy), z + d(dz))

    add("Spine", -9 * gather + 14 * strike)
    add("Chest", -12 * gather + 16 * strike, 0, 6 * gather)
    add("Neck", 6 * gather - 6 * strike)
    add("Head", 10 * gather - 22 * strike)
    add("Hand.L", 20 * gather - 15 * strike)
    add("Fingers.L", 28 * gather + 18 * strike * (1 - grab) - 70 * grab)
    add("Hand.R", 25 * gather - 30 * grab)
    hips = (0.0, -0.38 * strike + 0.05 * gather, -0.07 * gather - 0.1 * strike)
    # the claws: cocked up and back beside her head, driven straight out at you, then clawing in
    # always aimed, from the hang her idle holds (so the first and last frames are the idle pose and the
    # solver never jumps branch where the aim switches on or off); cocked wide
    # and forward, not behind her (no reachable branch there)
    for s in ("L", "R"):
        if t <= 1e-6:
            _ARM_LAST[s] = [r.get(ARM_TIP[s][1], (0, 0, 0))[0], r.get(ARM_TIP[s][1], (0, 0, 0))[2],
                            r.get(ARM_TIP[s][2], (0, 0, 0))[0], r.get(ARM_TIP[s][1], (0, 0, 0))[1]]
        v = LUNGE_IDLE[2][s]
        v = v.lerp(_toward(s, 0.5, -0.5, 0.25, 0.75), gather)
        v = v.lerp(_toward(s, 0.1, -1.0, 0.12, 0.97), strike)
        v = v.lerp(_toward(s, 0.04, -1.0, 0.0, 0.72), grab)
        _arm_to(r, hips, s, v)
    for s in ("L", "R"):
        r["UpperLeg." + s] = (0, 0, 0)
        r["LowerLeg." + s] = (d(5), 0, 0)
    lead = feet["L"].copy()
    lead.y -= 0.6 * step
    lead.z += 0.36 * step * (1 - step)            # the lifted arc of the stride, 9 cm at its height
    _plant(r, hips, "L", lead)
    _plant(r, hips, "R", feet["R"])
    return r, {"Hips": hips}


clip("idle", 48, idle)
clip("walk", 30, walk)
_ARM_LAST.clear()
clip("attack_idle", 30, attack_idle)
_ARM_LAST.clear()
clip("attack", 32, attack, loop=False)
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
