"""Sanity check: splat every triangle centre of the OBJ, coloured from the texture via its UVs,
onto a front-on image (nearest-to-camera wins). If the UVs match the texture, it looks like a face."""
import sys
import numpy as np
from PIL import Image

obj, tex, out = sys.argv[1], sys.argv[2], sys.argv[3]
V, T, F = [], [], []
with open(obj) as f:
    for line in f:
        if line.startswith('v '):
            V.append(line.split()[1:4])
        elif line.startswith('vt '):
            T.append(line.split()[1:3])
        elif line.startswith('f '):
            c = [p.split('/') for p in line.split()[1:4]]
            F.append([int(c[0][0]), int(c[1][0]), int(c[2][0]), int(c[0][1]), int(c[1][1]), int(c[2][1])])
V = np.array(V, float); T = np.array(T, float); F = np.array(F) - 1
C = V[F[:, :3]].mean(axis=1)            # triangle centres
UV = T[F[:, 3:]].mean(axis=1)
img = np.asarray(Image.open(tex).convert('RGB'))
H, W = img.shape[:2]
px = np.clip((UV[:, 0] % 1) * W, 0, W - 1).astype(int)
py = np.clip((1 - UV[:, 1] % 1) * H, 0, H - 1).astype(int)   # image rows count down
col = img[py, px]
res = 900
x0, x1, y0, y1 = C[:, 0].min(), C[:, 0].max(), C[:, 1].min(), C[:, 1].max()
s = (res - 1) / (y1 - y0)
ix = ((C[:, 0] - x0) * s).astype(int); iy = ((y1 - C[:, 1]) * s).astype(int)
Wd = ix.max() + 1
order = np.argsort(C[:, 2])             # far first, near last overwrites
canvas = np.full((res, Wd, 3), 255, np.uint8)
canvas[iy[order], ix[order]] = col[order]
Image.fromarray(canvas).save(out)
print(out, canvas.shape)
