#!/usr/bin/env python3
"""Generate the MNtfs DMG background at 1x and 2x (Retina)."""
import math
from PIL import Image, ImageDraw

W, H = 660, 430          # logical window content size
APP_X, APP_Y = 170, 200  # icon centers (must match the AppleScript)
APPS_X = 490
ICON = 128

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def dashed_polygon(draw, pts, color, width, dash, gap, closed=True):
    """Stroke a polygon/polyline with a dashed pen (PIL has none)."""
    segs = list(zip(pts, pts[1:] + ([pts[0]] if closed else [])))
    phase = 0.0
    for (x0, y0), (x1, y1) in segs:
        seg_len = math.hypot(x1 - x0, y1 - y0)
        if seg_len == 0:
            continue
        dx, dy = (x1 - x0) / seg_len, (y1 - y0) / seg_len
        d = 0.0
        while d < seg_len:
            on = (phase % (dash + gap)) < dash
            step = min(dash if on else gap, seg_len - d,
                       (dash + gap) - (phase % (dash + gap)))
            if step <= 0:
                step = 1.0
            if on:
                draw.line([(x0 + dx * d, y0 + dy * d),
                           (x0 + dx * (d + step), y0 + dy * (d + step))],
                          fill=color, width=width)
            d += step
            phase += step

def render(scale):
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h), (240, 242, 245))
    px = img.load()
    top, bot = (247, 248, 250), (231, 234, 238)   # very soft vertical gradient
    for y in range(h):
        c = lerp(top, bot, y / (h - 1))
        for x in range(w):
            px[x, y] = c
    draw = ImageDraw.Draw(img)

    # Dashed block arrow, centered between the two icons, pointing right.
    cx, cy = 330 * scale, (APP_Y - 8) * scale
    s = scale
    def P(dx, dy):
        return (cx + dx * s, cy + dy * s)
    arrow = [
        P(-34, -13), P(12, -13), P(12, -27), P(40, 0),
        P(12, 27), P(12, 13), P(-34, 13),
    ]
    dashed_polygon(draw, arrow, (150, 156, 163), max(2, round(2.4 * s)),
                   dash=9 * s, gap=6 * s)

    img.save(OUT % scale)

import os
_HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(_HERE, "bg_%dx.png")
render(1)
render(2)
print("wrote", OUT % 1, "and", OUT % 2)
print("now: tiffutil -cathidpicheck %s %s -out %s"
      % (OUT % 1, OUT % 2, os.path.join(_HERE, "background.tiff")))
