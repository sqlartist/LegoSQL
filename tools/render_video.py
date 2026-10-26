"""Blender script: render the LegoSQL build video from the SQL-generated script.

    blender -b --factory-startup -noaudio --python render_video.py -- script.csv out_dir
            [--res 1920x1080] [--samples 64] [--stills 120,300] [--frames 1-900] [--spin 150]

script.csv rows: ModelID,X,Y,Z,SizeX,SizeZ,Hex,T1,T2,T3  (Lego grid units; -1 = never)
A brick is visible when (frame >= T1 and frame < T2) or frame >= T3. Bricks drop in from a
few centimetres up when they appear, and lift back out before they're rewound away.
Every brick and stud is a Geometry Nodes instance, so the whole build is two point clouds.
"""
import argparse
import csv
import math
import os
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("csv")
ap.add_argument("out")
ap.add_argument("--res", default="1920x1080")
ap.add_argument("--samples", type=int, default=64)
ap.add_argument("--stills", default="", help="comma-separated frames to render as PNG stills")
ap.add_argument("--frames", default="", help="a-b: render this range of the animation")
ap.add_argument("--spin", type=int, default=150, help="frames of turntable at the end")
ap.add_argument("--fps", type=int, default=30)
ap.add_argument("--key", type=float, default=120.0, help="key light watts (the rim is 40%% of it)")
ap.add_argument("--ambient", type=float, default=0.3, help="how much the backdrop lights the bricks")
ap.add_argument("--lens", type=float, default=55.0)
a = ap.parse_args(argv)
a.out = os.path.abspath(a.out)          # Blender resolves bare relative paths against the drive root

STUD, LAYER = 0.008, 0.0096            # metres
GAP = 0.00025                          # seam between neighbouring bricks
STUD_R, STUD_H = 0.0024, 0.0017
DROP, DROP_FRAMES = 0.035, 6           # bricks fall 3.5 cm over 6 frames
NEVER = 1.0e7

# ---------------------------------------------------------------- the script from SQL Server
bricks = []
with open(a.csv, newline="") as f:
    for row in csv.reader(f):
        if len(row) < 10 or not row[0].strip().lstrip("-").isdigit():
            continue
        m, x, y, z, sx, sz = (int(v) for v in row[:6])
        t1, t2, t3 = (int(v) for v in row[7:10])
        bricks.append((m, x, y, z, sx, sz, row[6].strip(), t1, t2, t3))
print(f"{len(bricks)} bricks")

cx = (min(b[1] for b in bricks) + max(b[1] + b[4] for b in bricks)) / 2
cz = (min(b[3] for b in bricks) + max(b[3] + b[5] for b in bricks)) / 2
y0 = min(b[2] for b in bricks)
top = (max(b[2] for b in bricks) - y0 + 1) * LAYER
last = max(max(b[7], b[9]) for b in bricks) + DROP_FRAMES


def world(x, layer, z):
    """Lego grid -> Blender metres: Z up, the face looking down -Y."""
    return ((x - cx) * STUD, -(z - cz) * STUD, (layer - y0) * LAYER)


def linear(hex_):
    out = []
    for i in (0, 2, 4):
        c = int(hex_[i:i + 2], 16) / 255
        out.append(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4)
    return out + [1.0]


def t(v):
    return float(v) if v >= 0 else NEVER


# ---------------------------------------------------------------- scene
scene = bpy.context.scene
for o in list(bpy.data.objects):
    bpy.data.objects.remove(o, do_unlink=True)

scene.render.fps = a.fps
scene.frame_start, scene.frame_end = 1, last + a.spin
w, h = (int(v) for v in a.res.split("x"))
scene.render.resolution_x, scene.render.resolution_y = w, h
scene.render.resolution_percentage = 100
scene.render.engine = "CYCLES"
scene.cycles.samples = a.samples
scene.cycles.use_denoising = True
scene.render.use_persistent_data = True
scene.view_settings.view_transform = "Standard"
scene.view_settings.exposure = 0.0
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "OPTIX"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = d.type == "OPTIX"
    scene.cycles.device = "GPU"
    scene.cycles.denoiser = "OPTIX"
except Exception as e:  # fall back to CPU rather than fail
    print("GPU setup failed:", e)

# plastic: colour comes from each instance's "col" attribute
mat = bpy.data.materials.new("LegoPlastic")
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes["Principled BSDF"]
attr = nt.nodes.new("ShaderNodeAttribute")
attr.attribute_type = "INSTANCER"
attr.attribute_name = "col"
nt.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
bsdf.inputs["Roughness"].default_value = 0.3


def base_object(name, mesh_op, **kw):
    mesh_op(**kw)
    o = bpy.context.active_object
    o.name = name
    o.data.materials.append(mat)
    o.hide_render = True
    o.hide_viewport = True
    return o


brick_base = base_object("BrickBase", bpy.ops.mesh.primitive_cube_add, size=1.0)
bev = brick_base.modifiers.new("Bevel", "BEVEL")
bev.width, bev.segments = 0.02, 2
stud_base = base_object("StudBase", bpy.ops.mesh.primitive_cylinder_add,
                        vertices=24, radius=STUD_R, depth=STUD_H)
for p in stud_base.data.polygons:
    p.use_smooth = True


def point_cloud(name, pts):
    """pts: (location, attributes dict) -> a mesh of loose vertices carrying the attributes."""
    me = bpy.data.meshes.new(name)
    me.from_pydata([p[0] for p in pts], [], [])
    for key in pts[0][1]:
        sample = pts[0][1][key]
        if key == "col":
            at = me.attributes.new(key, "FLOAT_COLOR", "POINT")
            at.data.foreach_set("color", [c for p in pts for c in p[1][key]])
        elif isinstance(sample, tuple):
            at = me.attributes.new(key, "FLOAT_VECTOR", "POINT")
            at.data.foreach_set("vector", [c for p in pts for c in p[1][key]])
        else:
            at = me.attributes.new(key, "FLOAT", "POINT")
            at.data.foreach_set("value", [p[1][key] for p in pts])
    o = bpy.data.objects.new(name, me)
    scene.collection.objects.link(o)
    return o


brick_pts, stud_pts = [], []
for m, x, y, z, sx, sz, hx, t1, t2, t3 in bricks:
    col = linear(hx)
    times = {"t1": t(t1), "t2": t(t2), "t3": t(t3)}
    brick_pts.append((world(x + sx / 2, y + 0.5, z + sz / 2),
                      dict(times, col=col, size=(sx * STUD - GAP, sz * STUD - GAP, LAYER - GAP))))
    for i in range(sx):
        for j in range(sz):
            px, py, pz = world(x + i + 0.5, y + 1, z + j + 0.5)
            stud_pts.append(((px, py, pz + STUD_H / 2), dict(times, col=col)))


# ---------------------------------------------------------------- geometry nodes
def instancer(name, base, scaled):
    ng = bpy.data.node_groups.new(name, "GeometryNodeTree")
    ng.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    ng.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    N, Lk = ng.nodes, ng.links

    def wire(sock, value):
        if isinstance(value, (int, float)):
            sock.default_value = value
        else:
            Lk.new(value, sock)

    def named(n, kind="FLOAT"):
        node = N.new("GeometryNodeInputNamedAttribute")
        node.data_type = kind
        node.inputs["Name"].default_value = n
        return node.outputs["Attribute"]

    def op(kind, x, y=None, clamp=False):
        node = N.new("ShaderNodeMath")
        node.operation = kind
        node.use_clamp = clamp
        wire(node.inputs[0], x)
        if y is not None:
            wire(node.inputs[1], y)
        return node.outputs[0]

    def compare(op, x, y):
        node = N.new("FunctionNodeCompare")
        node.data_type, node.operation = "FLOAT", op
        wire(node.inputs[0], x)
        wire(node.inputs[1], y)
        return node.outputs["Result"]

    def boolean(op, x, y):
        node = N.new("FunctionNodeBooleanMath")
        node.operation = op
        Lk.new(x, node.inputs[0])
        Lk.new(y, node.inputs[1])
        return node.outputs[0]

    gin, gout = N.new("NodeGroupInput"), N.new("NodeGroupOutput")
    frame = N.new("GeometryNodeInputSceneTime").outputs["Frame"]
    t1, t2, t3 = named("t1"), named("t2"), named("t3")

    # (frame >= T1 and frame < T2) or frame >= T3
    second = compare("GREATER_EQUAL", frame, t3)
    visible = boolean("OR",
                      boolean("AND", compare("GREATER_EQUAL", frame, t1), compare("LESS_THAN", frame, t2)),
                      second)

    info = N.new("GeometryNodeObjectInfo")
    info.inputs["Object"].default_value = base
    inst = N.new("GeometryNodeInstanceOnPoints")
    Lk.new(gin.outputs[0], inst.inputs["Points"])
    Lk.new(info.outputs["Geometry"], inst.inputs["Instance"])
    Lk.new(visible, inst.inputs["Selection"])
    if scaled:
        Lk.new(named("size", "FLOAT_VECTOR"), inst.inputs["Scale"])

    # drop in: 1 -> 0 over DROP_FRAMES after appearing (at T1, or at T3 the second time)
    appear = op("ADD", t1, op("MULTIPLY", op("SUBTRACT", t3, t1), second))
    drop_in = op("DIVIDE", op("SUBTRACT", op("ADD", appear, DROP_FRAMES), frame), DROP_FRAMES, clamp=True)
    # lift out: 0 -> 1 over DROP_FRAMES before being rewound at T2 (first life only)
    lift = op("DIVIDE", op("SUBTRACT", frame, op("SUBTRACT", t2, DROP_FRAMES)), DROP_FRAMES, clamp=True)
    lift = op("MULTIPLY", lift, compare("LESS_THAN", frame, t3))
    r = op("MAXIMUM", drop_in, lift)
    up = N.new("ShaderNodeCombineXYZ")
    Lk.new(op("MULTIPLY", op("MULTIPLY", r, r), DROP), up.inputs["Z"])

    move = N.new("GeometryNodeTranslateInstances")
    Lk.new(inst.outputs["Instances"], move.inputs["Instances"])
    Lk.new(up.outputs["Vector"], move.inputs["Translation"])
    move.inputs["Local Space"].default_value = False
    Lk.new(move.outputs["Instances"], gout.inputs[0])
    return ng


for name, pts, base, scaled in (("Bricks", brick_pts, brick_base, True), ("Studs", stud_pts, stud_base, False)):
    o = point_cloud(name, pts)
    mod = o.modifiers.new("Instance", "NODES")
    mod.node_group = instancer(name + "GN", base, scaled)
print(f"{len(brick_pts)} brick instances, {len(stud_pts)} studs, frames 1-{scene.frame_end}")

# ---------------------------------------------------------------- studio: white sweep, soft light
# The camera sees a bright backdrop; the bricks are lit by a much dimmer version of it.
world_ = bpy.data.worlds.new("Studio")
world_.use_nodes = True
wn = world_.node_tree.nodes
bg = wn["Background"]
bg.inputs["Color"].default_value = (1, 1, 1, 1)
bg.inputs["Strength"].default_value = a.ambient
backdrop = wn.new("ShaderNodeBackground")
backdrop.inputs["Color"].default_value = (0.92, 0.92, 0.93, 1)
backdrop.inputs["Strength"].default_value = 1.0
mix = wn.new("ShaderNodeMixShader")
is_camera = wn.new("ShaderNodeLightPath").outputs["Is Camera Ray"]
world_.node_tree.links.new(is_camera, mix.inputs["Fac"])
world_.node_tree.links.new(bg.outputs[0], mix.inputs[1])
world_.node_tree.links.new(backdrop.outputs[0], mix.inputs[2])
world_.node_tree.links.new(mix.outputs[0], wn["World Output"].inputs["Surface"])
scene.world = world_

bpy.ops.mesh.primitive_plane_add(size=30, location=(0, 0, 0))
floor = bpy.context.active_object
floor.is_shadow_catcher = True

for name, loc, power, size in (("Key", (-1.6, -2.0, 2.4), a.key, 1.6), ("Rim", (1.8, 1.6, 1.6), a.key * 0.4, 1.2)):
    light = bpy.data.lights.new(name, "AREA")
    light.energy, light.size = power, size
    lo = bpy.data.objects.new(name, light)
    lo.location = loc
    scene.collection.objects.link(lo)
    track = lo.constraints.new("TRACK_TO")
    target = bpy.data.objects.new(name + "Target", None)
    target.location = (0, 0, top * 0.5)
    scene.collection.objects.link(target)
    track.target = target

# ---------------------------------------------------------------- camera: a slow orbit, then a spin
pivot = bpy.data.objects.new("Pivot", None)
pivot.location = (0, 0, top * 0.45)
scene.collection.objects.link(pivot)
cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
cam.data.lens = a.lens
cam.location = (0, -2.05, 0)
cam.rotation_euler = (math.radians(90), 0, 0)      # look along +Y, at the pivot
cam.parent = pivot
scene.collection.objects.link(cam)
scene.camera = cam

bpy.context.preferences.edit.keyframe_new_interpolation_type = "LINEAR"
for frame, yaw, elev in ((1, -40, 30), (last, 35, 26), (last + a.spin, 35 + 360, 18)):
    pivot.rotation_euler = (math.radians(-elev), 0, math.radians(yaw))
    pivot.keyframe_insert("rotation_euler", frame=frame)

# ---------------------------------------------------------------- render
os.makedirs(a.out, exist_ok=True)
if a.stills:
    scene.render.image_settings.file_format = "PNG"
    for fr in (int(v) for v in a.stills.split(",")):
        scene.frame_set(fr)
        scene.render.filepath = os.path.join(a.out, f"still_{fr:04d}.png")
        bpy.ops.render.render(write_still=True)
        print("wrote", scene.render.filepath)
else:
    if a.frames:
        scene.frame_start, scene.frame_end = (int(v) for v in a.frames.split("-"))
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = os.path.join(a.out, "frame_")
    scene.render.use_overwrite = False          # re-running carries on where it stopped
    scene.render.use_placeholder = True
    bpy.ops.render.render(animation=True)
print("done")
