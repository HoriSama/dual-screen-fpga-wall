"""Generate four 640x480 24-bit BMP "camera feeds" for the wall TF card.

The FPGA BMP parser (fpga_hdmi/build_src/src/storage/bmp_parser.v) only accepts
BITMAPINFOHEADER + 24-bit uncompressed + 8.3 file names in the FAT32 root, so
this script emits exactly that.

    python wall/tools/make_camera_bmps.py

Writes wall/media/CAM1.BMP .. CAM4.BMP and docs/media_preview.png.
"""
from __future__ import annotations

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 640, 480
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "media"
FONT = ImageFont.truetype("C:/Windows/Fonts/lucon.ttf", 14)


def sky(draw, top, bottom):
    for y in range(H // 2):
        t = y / (H / 2)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (W, y)], fill=c)


def stamp(draw, cam: int, note: str):
    text = f"CAM{cam:02d}  2026-10-28 03:{14 + cam:02d}:{22 + cam * 7 % 60:02d}"
    draw.rectangle([8, H - 30, 320, H - 8], fill=(0, 0, 0))
    draw.text((14, H - 29), text, fill=(230, 240, 255), font=FONT)
    draw.rectangle([W - 132, H - 30, W - 8, H - 8], fill=(0, 0, 0))
    draw.text((W - 126, H - 29), note, fill=(90, 230, 130), font=FONT)
    # small red recording dot
    draw.ellipse([W - 150, H - 24, W - 140, H - 14], fill=(220, 40, 40))


def scene_parking():
    img = Image.new("RGB", (W, H), (30, 34, 40))
    d = ImageDraw.Draw(img)
    sky(d, (36, 44, 66), (96, 92, 110))
    # asphalt with perspective
    d.polygon([(0, 250), (W, 250), (W, H), (0, H)], fill=(52, 54, 58))
    for i in range(-4, 14):
        x_top = W / 2 + i * 22
        x_bot = W / 2 + i * 78
        d.line([(x_top, 250), (x_bot, H)], fill=(190, 190, 180), width=2)
    # horizon strip
    d.line([(0, 250), (W, 250)], fill=(120, 118, 110), width=3)
    # lamp post
    d.rectangle([560, 120, 566, 300], fill=(70, 72, 76))
    d.ellipse([540, 104, 586, 128], fill=(255, 240, 180))
    for r, a in ((90, 30), (150, 16), (220, 8)):
        d.ellipse([563 - r, 116 - r // 2, 563 + r, 116 + r // 2], outline=(255, 240, 180))
    # cars (simple boxes with windshields)
    random.seed(7)
    spots = [(120, 300, (150, 40, 40)), (250, 330, (40, 80, 160)), (400, 360, (200, 200, 205)),
             (520, 390, (60, 120, 90)), (40, 420, (170, 150, 40))]
    for (x, y, col) in spots:
        w = 96
        h = 46
        d.rounded_rectangle([x, y, x + w, y + h], radius=8, fill=col)
        d.rectangle([x + 10, y + 6, x + w - 10, y + 20], fill=(30, 40, 55))
        d.ellipse([x + 8, y + h - 8, x + 26, y + h + 6], fill=(16, 16, 18))
        d.ellipse([x + w - 26, y + h - 8, x + w - 8, y + h + 6], fill=(16, 16, 18))
    stamp(d, 1, "REC OK")
    return img


def scene_corridor():
    img = Image.new("RGB", (W, H), (44, 46, 50))
    d = ImageDraw.Draw(img)
    # perspective walls / floor / ceiling
    d.polygon([(0, 0), (W, 0), (470, 170), (170, 170)], fill=(74, 76, 82))      # ceiling
    d.polygon([(0, H), (W, H), (470, 210), (170, 210)], fill=(58, 58, 62))      # floor
    d.polygon([(0, 0), (170, 170), (170, 210), (0, H)], fill=(96, 92, 88))      # left wall
    d.polygon([(W, 0), (470, 170), (470, 210), (W, H)], fill=(80, 78, 76))      # right wall
    # far door
    d.rectangle([290, 168, 350, 212], fill=(28, 30, 34))
    d.rectangle([296, 174, 344, 206], fill=(120, 140, 150))
    # doors along the walls
    for i, x in enumerate((60, 118)):
        d.polygon([(x, 150 + i * 6), (x + 34, 158 + i * 6), (x + 34, 250 + i * 10), (x, 262 + i * 10)],
                  fill=(70, 58, 46))
    for i, x in enumerate((560, 500)):
        d.polygon([(x, 150 + i * 6), (x - 34, 158 + i * 6), (x - 34, 250 + i * 10), (x, 262 + i * 10)],
                  fill=(62, 54, 46))
    # ceiling lights
    for y in (40, 90, 140):
        d.ellipse([290 - y // 3, y, 350 + y // 3, y + 10], fill=(250, 245, 210))
    # floor reflection
    for y in range(212, H, 8):
        a = (y - 212) / (H - 212)
        d.line([(0, y), (W, y)], fill=(58 + int(20 * a), 58 + int(20 * a), 62 + int(20 * a)))
    stamp(d, 2, "REC OK")
    return img


def scene_server():
    img = Image.new("RGB", (W, H), (18, 20, 26))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 60], fill=(24, 26, 32))
    # racks: two rows with perspective
    for side in (-1, 1):
        for k in range(4):
            x0 = W / 2 + side * (60 + k * 78)
            top = 60 + k * 8
            bottom = 420 - k * 6
            w = 62 - k * 6
            d.polygon([(x0 - w, top), (x0 + w, top), (x0 + w, bottom), (x0 - w, bottom)],
                      fill=(34 + k * 4, 36 + k * 4, 44 + k * 4))
            # rack units
            for u in range(6):
                y = top + 14 + u * 46
                d.rectangle([x0 - w + 6, y, x0 + w - 6, y + 30], fill=(22, 24, 30))
                for i in range(4):
                    col = (60, 220, 90) if (u + i + k) % 3 else (230, 180, 60)
                    d.rectangle([x0 - w + 12 + i * 10, y + 8, x0 - w + 16 + i * 10, y + 12], fill=col)
    # aisle floor
    d.polygon([(0, 420), (W, 420), (W, H), (0, H)], fill=(30, 32, 38))
    for y in range(430, H, 12):
        d.line([(0, y), (W, y)], fill=(36, 38, 46))
    stamp(d, 3, "REC OK")
    return img


def scene_city():
    img = Image.new("RGB", (W, H), (10, 12, 26))
    d = ImageDraw.Draw(img)
    sky(d, (12, 14, 34), (44, 30, 60))
    # moon
    d.ellipse([520, 50, 570, 100], fill=(240, 240, 220))
    d.ellipse([534, 44, 584, 94], fill=(16, 18, 40))
    random.seed(11)
    x = 0
    while x < W:
        bw = random.randint(40, 90)
        bh = random.randint(90, 260)
        y0 = 300 - bh
        d.rectangle([x, y0, x + bw, 320], fill=(14, 16, 26))
        for wy in range(y0 + 10, 310, 16):
            for wx in range(x + 8, x + bw - 8, 14):
                if random.random() < 0.45:
                    c = (250, 220, 150) if random.random() < 0.7 else (150, 210, 250)
                    d.rectangle([wx, wy, wx + 6, wy + 8], fill=c)
        x += bw + random.randint(6, 18)
    # ground / road
    d.polygon([(0, 320), (W, 320), (W, H), (0, H)], fill=(20, 22, 30))
    for i in range(6):
        d.polygon([(0, 340 + i * 22), (W, 336 + i * 22), (W, 348 + i * 22), (0, 352 + i * 22)],
                  fill=(26 + i * 3, 28 + i * 3, 38 + i * 3))
    # car trails (long exposure)
    for k in range(3):
        y = 380 + k * 26
        d.line([(40 + k * 30, y), (600 - k * 20, y - 4)], fill=(220, 120, 90), width=3)
        d.line([(60 + k * 20, y + 8), (620 - k * 30, y + 4)], fill=(120, 180, 240), width=3)
    stamp(d, 4, "REC OK")
    return img


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    scenes = [scene_parking, scene_corridor, scene_server, scene_city]
    thumbs = []
    for i, fn in enumerate(scenes, start=1):
        img = fn()
        path = OUT / f"CAM{i}.BMP"
        img.save(path, "BMP")          # PIL writes 24-bit BITMAPINFOHEADER BMP
        thumbs.append(img)
        print(f"wrote {path} ({path.stat().st_size} bytes)")
    sheet = Image.new("RGB", (W * 2 + 12, H * 2 + 12), (0, 0, 0))
    for idx, im in enumerate(thumbs):
        sheet.paste(im, ((idx % 2) * (W + 12), (idx // 2) * (H + 12)))
    sheet.save(ROOT / "docs" / "media_preview.png")
    print(f"wrote {ROOT / 'docs' / 'media_preview.png'}")


if __name__ == "__main__":
    main()
