"""Golden renderer for the wall scene (design reference for wall_scene.v).

Renders the 1280x480 world once, then splits it into the two 640x480 node
screens exactly the way the RTL clips them.  The RTL scene is a direct port of
``scene_rgb()`` below; keep the two in sync.

Run:  python wall/tools/render_preview.py [frame]
Writes docs/preview_world.png and docs/preview_pair.png.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
FONT = json.loads((ROOT / "tools" / "font.json").read_text())
CHARS = FONT["chars"]
GLYPHS = FONT["glyphs"]

WORLD_W, WORLD_H = 1280, 480
NODE_W = 640

C_BG = (16, 20, 28)
C_GRID = (28, 36, 48)
C_GRID_MAJOR = (40, 52, 68)
C_TITLE = (32, 40, 56)
C_OWN_A = (51, 214, 255)
C_OWN_B = (255, 154, 60)
C_SEL = (255, 255, 255)
C_SCAN = (70, 80, 95)
C_TEXT = (226, 236, 250)
C_TEXT_DIM = (140, 152, 170)
C_BOX = (8, 10, 14)


def window_record(wid, src, gx, gy, w, h, z, owner, flags=0):
    return dict(id=wid, src=src, gx=gx, gy=gy, w=w, h=h, z=z, owner=owner, flags=flags)


# default layout, identical to docs/01_spec.md 3.2
DEFAULT_WINDOWS = [
    window_record(0, 0, 40, 40, 320, 240, 0, 0, flags=0),
    window_record(1, 1, 360, 80, 320, 240, 1, 0, flags=0),
    window_record(2, 2, 600, 120, 320, 240, 2, 0, flags=0),
    window_record(3, 3, 940, 60, 320, 240, 3, 1, flags=0),
]


def owner_color(owner: int):
    return C_OWN_A if owner == 0 else C_OWN_B


def border_color(rec):
    if rec["flags"] & 0x1:
        return C_SEL
    return owner_color(rec["owner"])


def content_rgb(rec, lx, ly, anim):
    """Window-local content (lx,ly measured from the window's top-left)."""
    cw = rec["w"] - 4
    ch = rec["h"] - 16
    src = rec["src"]
    if src == 0:  # color bars, 64 px per bar
        bars = [
            (235, 235, 235),
            (235, 210, 40),
            (40, 210, 210),
            (40, 200, 60),
            (220, 60, 190),
        ]
        return bars[(lx >> 6) % len(bars)]
    if src == 1:  # 16 px checker + moving block
        base = (40, 44, 52) if (((lx >> 4) ^ (ly >> 4)) & 1) == 0 else (58, 64, 76)
        bx = (anim * 6) % max(cw - 16, 1)
        by = (anim * 3) % max(ch - 16, 1)
        if bx <= lx < bx + 16 and by <= ly < by + 16:
            return (230, 70, 60)
        return base
    if src == 2:  # gradient + diagonal
        r = (lx * 2) & 0xFF
        g = (ly * 2) & 0xFF
        b = 128
        if abs((lx * ch) - (ly * cw)) < cw * 2:
            return (255, 255, 255)
        return (r, g, b)
    # src 3: dark nav display, crosshair + ring
    cx, cy = cw // 2, ch // 2
    dx, dy = lx - cx, ly - cy
    if abs(dx) < 2 and abs(dy) < 2:
        return (255, 60, 60)
    if abs(dx) < 1:
        return (60, 220, 120)
    if abs(dy) < 1:
        return (60, 220, 120)
    d2 = dx * dx + dy * dy
    rad = min(cw, ch) // 3
    if abs(d2 - rad * rad) < rad * 2:
        return (60, 220, 120)
    return (10, 14, 18)


def window_pixel(rec, x, y, anim):
    """Return RGB for global (x,y) inside rec, or None if it does not hit."""
    if not (rec["gx"] <= x < rec["gx"] + rec["w"] and rec["gy"] <= y < rec["gy"] + rec["h"]):
        return None
    lx, ly = x - rec["gx"], y - rec["gy"]
    w, h = rec["w"], rec["h"]
    if lx < 2 or lx >= w - 2 or ly < 2 or ly >= h - 2:
        return border_color(rec)
    if ly < 14:  # title bar + 4 px src accent
        if lx < 6:
            return owner_color(rec["owner"])
        return C_TITLE
    cx, cy = lx - 2, ly - 16
    if cx < 0 or cy < 0:
        return C_TITLE
    rgb = content_rgb(rec, cx, cy, anim)
    # 2 px scan bar
    if ((anim * 7) % max(h - 16, 1)) <= cy < ((anim * 7) % max(h - 16, 1)) + 2:
        return C_SCAN
    return rgb


def text(s: str, x0: int, y0: int, px, color, box=True):
    if box:
        for by in range(y0 - 2, y0 + 10):
            for bx in range(x0 - 2, x0 + 8 * len(s) + 2):
                if 0 <= bx < WORLD_W and 0 <= by < WORLD_H:
                    px[bx, by] = C_BOX
    for i, ch in enumerate(s):
        rows = GLYPHS.get(ch, GLYPHS[" "])
        for ry, bits in enumerate(rows):
            for rx in range(8):
                if bits & (1 << (7 - rx)):
                    xx, yy = x0 + i * 8 + rx, y0 + ry
                    if 0 <= xx < WORLD_W and 0 <= yy < WORLD_H:
                        px[xx, yy] = color


def hud(px, node: int, windows, link_ok: bool, sync_ok: bool):
    sel = next((r for r in windows if r["flags"] & 0x1), None)
    if sel is None:
        sel = windows[0]
    text("WALL " + ("A" if node == 0 else "B"), 8, 8, px, owner_color(node))
    text(f"SEL {sel['id']} OWN {'A' if sel['owner'] == 0 else 'B'}", 8, 440, px, C_TEXT)
    text(f"GX {sel['gx']:04X}", 8, 456, px, C_TEXT_DIM)
    lx = 632 - 8 * 7
    text("LINK OK" if link_ok else "LINK LOS", lx, 440, px, C_TEXT if link_ok else (255, 90, 90))
    text("SYNC OK" if sync_ok else "NO SYNC", lx, 456, px, C_TEXT_DIM)


def render_world(windows, node: int | None = None, link_ok=True, sync_ok=True, anim=0):
    """Render the whole world; node=None draws HUD for both halves."""
    img = Image.new("RGB", (WORLD_W, WORLD_H), C_BG)
    px = img.load()
    order = sorted(windows, key=lambda r: (r["z"], -r["id"]))
    for y in range(WORLD_H):
        for x in range(WORLD_W):
            if x % 128 == 0 or y % 128 == 0:
                px[x, y] = C_GRID_MAJOR
            elif x % 32 == 0 or y % 32 == 0:
                px[x, y] = C_GRID
            for rec in order:
                rgb = window_pixel(rec, x, y, anim)
                if rgb is not None:
                    px[x, y] = rgb
    if node is None:
        hud(px, 0, windows, link_ok, sync_ok)
        hud(px, 1, windows, link_ok, sync_ok)
    else:
        hud(px, node, windows, link_ok, sync_ok)
    return img


def main() -> None:
    frame = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    anim = (frame >> 6) & 0x1F
    world = render_world(DEFAULT_WINDOWS, node=None, anim=anim)
    world.save(ROOT / "docs" / "preview_world.png")

    a = world.crop((0, 0, NODE_W, WORLD_H))
    b = world.crop((NODE_W, 0, WORLD_W, WORLD_H))
    pair = Image.new("RGB", (NODE_W * 2 + 8, WORLD_H), (0, 0, 0))
    pair.paste(a, (0, 0))
    pair.paste(b, (NODE_W + 8, 0))
    pair.save(ROOT / "docs" / "preview_pair.png")
    print("wrote docs/preview_world.png, docs/preview_pair.png")


if __name__ == "__main__":
    main()
