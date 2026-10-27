"""Prepare the clown hallucination's model: blender -b -P tools/make_clown.py -- <Da-Clown.glb> assets/clown/clown.glb [--pose=0..1]

Source: Sketchfab "Da-Clown #StylizedBustChallenge" by Nwilly_art, CC Attribution (credit in README).
It is one rigless bust. This splits the two eyeballs into their own meshes (origins at their
centres, so a script can aim them) and skins the lower face to one bone, "jaw", hinged behind the
cheek, so the mouth opens without tearing the chin off the neck. Metres, face toward +Z in Godot.
--pose renders nothing; it only opens the jaw that far (0..1) before exporting, for a look.
"""
import bpy, sys, bmesh, math
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:]
src, dst = argv[0], argv[1]
pose = next((float(a.split("=")[1]) for a in argv if a.startswith("--pose=")), 0.0)
S = 0.0017
HINGE = Vector((55, 40, 318))   # source units: behind the cheek, at the mouth's height
MOUTH_TOP, MOUTH_FADE = 300.0, 345.0   # jaw weight 1 below the first, 0 above the second
FRONT_FULL, FRONT_NONE = -40.0, 25.0   # and 1 in front of the first, 0 behind the second

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
for o in meshes:
    mw = o.matrix_world.copy()
    o.parent = None
    o.data.transform(mw)
    o.matrix_world = o.matrix_world.Identity(4)
for o in list(bpy.data.objects):
    if o.type != "MESH":
        bpy.data.objects.remove(o)

by = {o.name: o for o in meshes}
body = by["Body_body_0"]; hair = by["Hair_hair_0"]; bow = by["Plane.001_Material.002_0"]; eyes = by["Body.001_Eyes_0"]
body.name = "Body"; hair.name = "Hair"; bow.name = "Bow"

# Skin weights: the lower front of the head component only (the torso is a separate island).
bm = bmesh.new(); bm.from_mesh(body.data); bm.verts.ensure_lookup_table()
head = set()
seen = set()
for v in bm.verts:
    if v.index in seen: continue
    st = [v]; seen.add(v.index); comp = []
    while st:
        x = st.pop(); comp.append(x)
        for e in x.link_edges:
            w = e.other_vert(x)
            if w.index not in seen: seen.add(w.index); st.append(w)
    cz = sum(x.co.z for x in comp) / len(comp)
    if cz > 300: head.update(x.index for x in comp)

def smooth(t): t = max(0.0, min(1.0, t)); return t * t * (3 - 2 * t)

vg = body.vertex_groups.new(name="jaw")
for i in head:
    p = bm.verts[i].co
    wz = smooth((MOUTH_FADE - p.z) / (MOUTH_FADE - MOUTH_TOP))
    wy = smooth((FRONT_NONE - p.y) / (FRONT_NONE - FRONT_FULL))
    w = wz * wy
    if w > 0.002: vg.add([i], w, "REPLACE")
bm.free()

# Eyes: one mesh per loose part, origin at its centre.
bpy.context.view_layer.objects.active = eyes
for o in bpy.data.objects: o.select_set(o is eyes)
bpy.ops.object.mode_set(mode="EDIT"); bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.separate(type="LOOSE"); bpy.ops.object.mode_set(mode="OBJECT")
pair = sorted([o for o in bpy.data.objects if o.name.startswith("Body.001_Eyes")], key=lambda o: o.location.x)
for o, name in zip(pair, ["EyeA", "EyeB"]):
    o.name = name
    bpy.context.view_layer.objects.active = o
    for q in bpy.data.objects: q.select_set(q is o)
    bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")

# Scale to metres, origin at the bust's middle on its bottom.
from mathutils import Matrix
for o in bpy.data.objects:
    if o.type != "MESH": continue
    if o.name.startswith("Eye"):
        o.location = (o.location - Vector((50, 0, 0))) * S
        o.data.transform(Matrix.Scale(S, 4))
    else:
        o.data.transform(Matrix.Scale(S, 4) @ Matrix.Translation((-50, 0, 0)))

arm = bpy.data.armatures.new("ClownRig"); rig = bpy.data.objects.new("ClownRig", arm)
bpy.context.scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
b = arm.edit_bones.new("jaw")
hinge = (HINGE - Vector((50, 0, 0))) * S
b.head = hinge; b.tail = hinge + Vector((0.04, 0, 0))
bpy.ops.object.mode_set(mode="OBJECT")
body.parent = rig
mod = body.modifiers.new("Armature", "ARMATURE"); mod.object = rig
if pose > 0:
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="POSE")
    rig.pose.bones["jaw"].rotation_mode = "XYZ"
    rig.pose.bones["jaw"].rotation_euler = (math.radians(35) * pose, 0, 0)
    bpy.ops.object.mode_set(mode="OBJECT")
for o in bpy.data.objects:
    if o.type == "MESH" and o is not body:
        o.parent = None

bpy.ops.export_scene.gltf(filepath=dst, export_format="GLB", export_skins=True, export_animations=False,
    export_image_format="JPEG", export_jpeg_quality=88, export_apply=False)
print("EXPORTED", dst)
