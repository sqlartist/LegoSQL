"""Blender script: save the Base Color texture of a .blend as a 24-bit BMP that T-SQL can read.

    blender -b --factory-startup -noaudio Model.blend --python extract_texture.py -- out.bmp [size]

Finds the image node wired into the Principled BSDF's "Base Color" on the first mesh's
material, scales it to size x size (default 1024) and writes it as an RGB BMP.
"""
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out_path = args[0] if args else "basecolor.bmp"
size = int(args[1]) if len(args) > 1 else 1024

mesh = next(o for o in bpy.data.objects if o.type == "MESH")
mat = mesh.data.materials[0]
link = next(l for l in mat.node_tree.links
            if l.to_node.type == "BSDF_PRINCIPLED" and l.to_socket.name == "Base Color")
src = link.from_node.image
print(f"Base Color of {mesh.name}/{mat.name} is {src.name} {tuple(src.size)}")

img = src.copy()
img.scale(size, size)
settings = bpy.context.scene.render.image_settings
settings.file_format = "BMP"
settings.color_mode = "RGB"
img.save_render(out_path, scene=bpy.context.scene)
print(f"Saved {out_path}")
