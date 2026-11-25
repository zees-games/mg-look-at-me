"""Builds assets/witch/witch.glb and witch_atlas.png: the scary witch, rigged and animated.

    blender -b -P tools/make_witch.py -- <Witch.glb from Sketchfab> assets/witch/witch.glb [--stage=N] [--keep=path.blend]

Source: "Witch" by Tamko Dmitry, https://sketchfab.com/3d-models/witch-0b6f69bbaa864bd78c0cfa98dabca0aa,
CC Attribution 4.0: one static mesh of a fat hooded woman with a staff and bottles. This script
  1. drops the staff and the bottles and makes her gaunt (narrow, flat bellied, long legged),
  2. adds a tattered hem and cloak edge, stringy hair, and black hollow eye sockets,
  3. rigs her (bones weighted by distance, the mesh is not watertight), hunches her by posing the
     rig and keeping the pose as the rest pose, and stretches arms and fingers into claws,
  4. drains and darkens the texture (witch_atlas.png, the one texture the game draws her with),
  5. scales her so the top of the hood is 2.2 m (the game's HEIGHT) and keys idle, walk,
     attack_idle and attack for game/lm_witch.gd.
Facing +Z in the file (Blender -Y); the head bone is "Head".
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
    if 9.0 < z < 24.5 and y < 1.4:
        # flatten the belly and the front of the chest; the hood (z>23) stays
        f = 0.5 + 0.5 * smooth((z - 21.5) / 3.0) + 0.0 * smooth((12.0 - z) / 3.0)
        y = 1.4 + (y - 1.4) * f
    return Vector((x, y, fz(z)))


for v in bm.verts:
    v.co = warp(v.co)

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
            shred_edges.append((a, b, 2.2))
        elif fz(18.5) < mz < fz(22.6) and abs(a.co.x) < 6.5 and a.co.z > fz(17):
            shred_edges.append((a, b, 1.6))
n_shred = 0
for a, b, depth in shred_edges:
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
    for lp in f.loops:
        src = a if lp.vert in (a, t) else b
        lp[uvl].uv = src.link_loops[0][uvl].uv
    n_shred += 1
print("shreds", n_shred)

hair_uv = skin_uv(Vector((0.0, 3.0, fz(16.0))))
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
        for k in range(5):
            a1, b1 = rings[k]
            a2, b2 = rings[k + 1]
            f = bm.faces.new((a1, b1, b2, a2) if side == 0 else (a1, a2, b2, b1))
            for lp in f.loops:
                lp[uvl].uv = hair_uv
    n_hair += 1

# hollow eye sockets: dark ellipsoids over the eyes, black texels (the game lights the eyes in them)
dark_uv = skin_uv(Vector((0.1, -3.0, fz(25.2))))
EYE_IDX = []
EYES = [Vector((0.3, -3.05, fz(26.05))), Vector((1.45, -3.05, fz(26.05)))]
for c in EYES:
    geom = bmesh.ops.create_uvsphere(bm, u_segments=8, v_segments=6, radius=1.0)
    vs = [g for g in geom["verts"]]
    bm.verts.index_update()
    EYE_IDX.append([v.index for v in vs])
    for v in vs:
        v.co = c + Vector((v.co.x * 0.4, v.co.y * 0.2 + 0.18, v.co.z * 0.28))
    for f in {f for v in vs for f in v.link_faces}:
        for lp in f.loops:
            lp[uvl].uv = (0.0, 0.0)   # painted black below
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
for v in body.data.vertices:
    p = v.co
    if p.z > fz(23.2) and abs(p.x - 0.8) < 4.2 and p.y < 3.5 and p.z > fz(23.2):
        # hood, head, hair roots: the head, blended into the neck at the bottom
        w = smooth((p.z - fz(22.2)) / 1.8)
        g = {"Head": w, "Neck": 1 - w}
    else:
        if p.x > 5.0 and p.z > fz(8.5):
            names = ARML + ["Chest"]
        elif p.x < -5.0 and p.z > fz(8.5):
            names = ARMR + ["Chest"]
        elif p.z < fz(9.5) and abs(p.x) > 1.2:
            names = LEGS + ["Hips"]
        else:
            names = CORE[:3] + ["Neck"] + LEGS
        g = weights(p, names)
    for n, w in g.items():
        if w > 0.004:
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
          "UpperArm.L": (d(3), 0, d(-5)), "UpperArm.R": (d(5), 0, d(6))},
    scales={"UpperArm.L": (1, 1.15, 1), "LowerArm.L": (0.95, 1.3, 0.95), "Hand.L": (0.85, 1.3, 0.85),
            "Fingers.L": (0.7, 2.4, 0.7), "Hand.R": (1.0, 1.5, 1.0)},
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
img = base_img.copy()
img.name = "witch_atlas"
W, H = img.size
import numpy as np
px = np.array(img.pixels[:], dtype=np.float32).reshape(H, W, 4)
lum = px[..., :3] @ np.array([0.3, 0.59, 0.11], dtype=np.float32)
grey = np.stack([lum, lum, lum], -1)
px[..., :3] = (0.15 * px[..., :3] + 0.85 * grey)                   # drain
px[..., :3] *= np.array([0.78, 0.8, 0.86], dtype=np.float32)      # cold and dark
px[..., 3] = 1.0
px[0:3, 0:3, :3] = 0.0   # texel (0,0) is the socket black
img.pixels = px.ravel().tolist()
img.filepath_raw = os.path.join(os.path.dirname(os.path.abspath(DST)), "witch_atlas.png")
img.file_format = "PNG"
img.save()
try:   # shrink on disk: 128-colour dithered palette PNG (the texture is dark and near-grey)
    from PIL import Image
    _p = img.filepath_raw
    Image.open(_p).convert("RGB").quantize(128, method=Image.MEDIANCUT, dither=Image.FLOYDSTEINBERG).save(_p, optimize=True)
except ImportError:
    print("PIL missing: atlas left uncompressed")
mat = bpy.data.materials.new("Witch")
mat.use_nodes = True
tex = mat.node_tree.nodes.new("ShaderNodeTexImage")
tex.image = img
mat.node_tree.links.new(tex.outputs["Color"], mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"])
body.data.materials.clear()
body.data.materials.append(mat)
stop(4)

# ---------------------------------------------------------------- 5. clips
FPS = 30
arm.animation_data_create()


def clip(name, frames, fn, loop=True):
    act = bpy.data.actions.new(name)
    arm.animation_data.action = act
    for f in range(frames + 1):
        t = (f % frames) / frames if loop else f / frames
        rots, locs = fn(t)
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


def base_idle(t):
    return {
        "Spine": (d(4.0 * sw(t)), 0, d(3.5 * sw(t, 0.25))),
        "Chest": (d(5.0 * sw(t, 0.1)), d(4.0 * sw(t, 0.35)), 0),
        "Head": (d(4.0 * sw(t, 0.3)), d(7.0 * sw(t, 0.5)), d(4.0 * sw(t, 0.2))),
        "UpperArm.L": (d(7 * sw(t, 0.2)), 0, d(-5 * sw(t))),
        "UpperArm.R": (d(5 * sw(t, 0.4)), 0, d(5 * sw(t))),
        "Hand.L": (d(-12 * sw(t, 0.3)), 0, 0),
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
    r["LowerArm.R"] = (d(-10 + 8 * sw(t, 0.25)), 0, 0)
    return r, {"Hips": (0, 0, drop)}


def attack_idle(t):
    r = base_idle(t)
    r["UpperArm.L"] = (d(-95 + 4 * sw(t)), 0, d(-12))
    r["UpperArm.R"] = (d(-100 + 5 * sw(t, 0.3)), 0, d(14))
    r["LowerArm.L"] = (d(-20), 0, 0)
    r["LowerArm.R"] = (d(-20), 0, 0)
    r["Fingers.L"] = (d(25 * sw(t, 0.2)), 0, d(8 * sw(t)))
    r["Head"] = (d(-6 + 3 * sw(t, 0.3)), 0, d(3 * sw(t, 0.2)))
    drop = legs(r, t)
    return r, {"Hips": (0, 0, drop)}


def attack(t):
    r = attack_idle(0.0)[0]
    for n in ("UpperLeg.L", "UpperLeg.R", "LowerLeg.L", "LowerLeg.R", "Foot.L", "Foot.R", "Hips"):
        r[n] = (0, 0, 0)
    lunge = smooth(t * 2.5) * (1 - smooth((t - 0.6) / 0.4))
    r["Chest"] = (d(20 * lunge), 0, 0)
    r["Spine"] = (d(14 * lunge), 0, 0)
    r["UpperArm.L"] = (d(-95 - 35 * lunge), 0, d(-12 + 14 * lunge))
    r["UpperArm.R"] = (d(-100 - 35 * lunge), 0, d(14 - 14 * lunge))
    r["Fingers.L"] = (d(-30 * lunge), 0, 0)
    return r, {"Hips": (0, 0, 0)}


clip("idle", 60, idle)
clip("walk", 30, walk)
clip("attack_idle", 30, attack_idle)
clip("attack", 40, attack, loop=False)
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
