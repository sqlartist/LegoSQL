"""Quick preview renderer for LegoSQL output.

Reads a CSV of cells (X,Y,Z,BrickID,Hex) -- one row per 1x1 cell, tagged with the
brick it belongs to -- and draws front / three-quarter / side views with studs and
brick outlines. Orthographic, painter's algorithm (back-to-front over a regular grid).

    python render_bricks.py cells.csv out.png [--title "..."]
"""
import argparse
import csv
import math

from PIL import Image, ImageDraw, ImageFont

STUD, LAYER = 8.0, 9.6          # mm
STUD_R, STUD_H = 2.4, 1.7       # mm
SS = 2                          # supersampling factor


def hex_rgb(h):
    h = h.strip().lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def shade(rgb, k):
    return tuple(max(0, min(255, int(c * k))) for c in rgb)


def load(path):
    cells = {}
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if len(row) < 5 or not row[0].strip().lstrip("-").isdigit():
                continue
            x, y, z, b = (int(v) for v in row[:4])
            cells[(x, y, z)] = (b, hex_rgb(row[4]))
    return cells


def render_view(cells, yaw_deg, pitch_deg, px_per_mm):
    th, ph = math.radians(yaw_deg), math.radians(pitch_deg)
    d = (math.sin(th) * math.cos(ph), math.sin(ph), math.cos(th) * math.cos(ph))   # towards camera
    r = (math.cos(th), 0.0, -math.sin(th))
    u = (d[1] * r[2] - d[2] * r[1], d[2] * r[0] - d[0] * r[2], d[0] * r[1] - d[1] * r[0])
    light = (0.35, 0.75, 0.55)
    ln = math.sqrt(sum(c * c for c in light))
    light = tuple(c / ln for c in light)

    def proj(p):
        return (p[0] * r[0] + p[1] * r[1] + p[2] * r[2], -(p[0] * u[0] + p[1] * u[1] + p[2] * u[2]))

    # bounds
    pts = []
    for (x, y, z) in cells:
        for cx in (0, 1):
            for cy in (0, 1):
                for cz in (0, 1):
                    pts.append(proj(((x + cx) * STUD, (y + cy) * LAYER, (z + cz) * STUD)))
    minx = min(p[0] for p in pts); maxx = max(p[0] for p in pts)
    miny = min(p[1] for p in pts); maxy = max(p[1] for p in pts)
    s = px_per_mm * SS
    pad = 12 * SS
    W = int((maxx - minx) * s) + 2 * pad
    H = int((maxy - miny) * s + STUD_H * 2 * s) + 2 * pad
    img = Image.new("RGB", (W, H), (255, 255, 255))
    dr = ImageDraw.Draw(img)

    def scr(p):
        q = proj(p)
        return ((q[0] - minx) * s + pad, (q[1] - miny) * s + pad + STUD_H * 2 * s)

    faces = [  # normal, neighbour offset, 4 corners in cell units
        ((1, 0, 0), [(1, 0, 0), (1, 1, 0), (1, 1, 1), (1, 0, 1)]),
        ((-1, 0, 0), [(0, 0, 0), (0, 0, 1), (0, 1, 1), (0, 1, 0)]),
        ((0, 1, 0), [(0, 1, 0), (0, 1, 1), (1, 1, 1), (1, 1, 0)]),
        ((0, -1, 0), [(0, 0, 0), (1, 0, 0), (1, 0, 1), (0, 0, 1)]),
        ((0, 0, 1), [(0, 0, 1), (1, 0, 1), (1, 1, 1), (0, 1, 1)]),
        ((0, 0, -1), [(0, 0, 0), (0, 1, 0), (1, 1, 0), (1, 0, 0)]),
    ]
    def depth(c):
        return (c[0] + .5) * STUD * d[0] + (c[1] + .5) * LAYER * d[1] + (c[2] + .5) * STUD * d[2]
    order = sorted(cells, key=depth)
    dmin, dmax = depth(order[0]), depth(order[-1])
    line_w = max(1, int(0.35 * s / 2))
    for (x, y, z) in order:
        brick, rgb = cells[(x, y, z)]
        for n, corners in faces:
            ndot = n[0] * d[0] + n[1] * d[1] + n[2] * d[2]
            if ndot <= 1e-9 or (x + n[0], y + n[1], z + n[2]) in cells:
                continue
            k = 0.62 + 0.45 * max(0.0, n[0] * light[0] + n[1] * light[1] + n[2] * light[2])
            k *= 0.55 + 0.45 * (depth((x, y, z)) - dmin) / max(1e-9, dmax - dmin)   # depth cue
            poly = [scr(((x + a) * STUD, (y + b) * LAYER, (z + c) * STUD)) for a, b, c in corners]
            dr.polygon(poly, fill=shade(rgb, k))
            # outline the edges where the neighbouring cell in this face's plane is another brick
            for i in range(4):
                a, b = corners[i], corners[(i + 1) % 4]
                mid = tuple((a[j] + b[j]) / 2 for j in range(3))
                off = tuple(int(round((mid[j] - 0.5) * 2)) if n[j] == 0 else 0 for j in range(3))
                nb = cells.get((x + off[0], y + off[1], z + off[2]))
                if nb is None or nb[0] != brick:
                    dr.line([poly[i], poly[(i + 1) % 4]], fill=shade(rgb, 0.45), width=line_w)
        # stud
        if d[1] > 0.05 and (x, y + 1, z) not in cells:
            cx, cy, cz = (x + .5) * STUD, (y + 1) * LAYER, (z + .5) * STUD
            ring = [(cx + STUD_R * math.cos(a), cz + STUD_R * math.sin(a)) for a in [i * math.pi / 12 for i in range(24)]]
            bot = [scr((p, cy, q)) for p, q in ring]
            top = [scr((p, cy + STUD_H, q)) for p, q in ring]
            side = bot + top
            # convex hull of the two ellipses (monotone chain)
            side = sorted(set(side))
            def cross(o, a, b):
                return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
            lower, upper = [], []
            for p in side:
                while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
                    lower.pop()
                lower.append(p)
            for p in reversed(side):
                while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
                    upper.pop()
                upper.append(p)
            dr.polygon(lower[:-1] + upper[:-1], fill=shade(rgb, 0.78))
            dr.polygon(top, fill=shade(rgb, 1.08), outline=shade(rgb, 0.6))
    return img.resize((W // SS, H // SS), Image.LANCZOS)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("out")
    ap.add_argument("--title", default="")
    ap.add_argument("--px", type=float, default=2.2, help="pixels per mm")
    ap.add_argument("--views", default="0,8;35,22;90,8", help="yaw,pitch pairs separated by ;")
    a = ap.parse_args()
    cells = load(a.csv)
    angles = [tuple(float(v) for v in pair.split(",")) for pair in a.views.split(";")]
    views = [render_view(cells, yaw, pitch, a.px) for yaw, pitch in angles]
    gap, top = 20, (44 if a.title else 10)
    W = sum(v.width for v in views) + gap * (len(views) + 1)
    H = max(v.height for v in views) + top + 10
    sheet = Image.new("RGB", (W, H), (255, 255, 255))
    x = gap
    for v in views:
        sheet.paste(v, (x, top + (H - top - 10 - v.height)))
        x += v.width + gap
    if a.title:
        try:
            font = ImageFont.truetype("segoeui.ttf", 22)
        except OSError:
            font = ImageFont.load_default()
        ImageDraw.Draw(sheet).text((gap, 10), a.title, fill=(40, 40, 40), font=font)
    sheet.save(a.out)
    print(f"{a.out}: {len(cells)} cells, {W}x{H}")


if __name__ == "__main__":
    main()
