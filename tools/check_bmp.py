"""Validate BMP files against what fpga_hdmi's bmp_parser.v accepts.

    python wall/tools/check_bmp.py wall/media/*.BMP

Checks the exact fields the RTL latches: 'BM' magic, BITMAPINFOHEADER size,
24 bpp, no compression, plane count, data offset and consistency of the pixel
byte count with width*height*3 (rows padded to 4 bytes).
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path


def check(path: Path) -> bool:
    data = path.read_bytes()
    ok = True
    problems = []

    if len(data) < 54:
        return False
    magic = data[0:2]
    fsize = struct.unpack_from("<I", data, 2)[0]
    data_off = struct.unpack_from("<I", data, 10)[0]
    hdr_size = struct.unpack_from("<I", data, 14)[0]
    w = struct.unpack_from("<i", data, 18)[0]
    h = struct.unpack_from("<i", data, 22)[0]
    planes = struct.unpack_from("<H", data, 26)[0]
    bpp = struct.unpack_from("<H", data, 28)[0]
    comp = struct.unpack_from("<I", data, 30)[0]
    img_size = struct.unpack_from("<I", data, 34)[0]

    if magic != b"BM":
        problems.append(f"magic {magic!r} != b'BM'")
    if hdr_size != 40:
        problems.append(f"biSize {hdr_size} != 40 (BITMAPINFOHEADER)")
    if planes != 1:
        problems.append(f"biPlanes {planes} != 1")
    if bpp != 24:
        problems.append(f"biBitCount {bpp} != 24 (parser requires 24)")
    if comp != 0:
        problems.append(f"biCompression {comp} != 0 (uncompressed only)")
    if w <= 0 or abs(h) == 0:
        problems.append(f"bad dimensions {w}x{h}")

    row_bytes = ((w * 3 + 3) // 4) * 4
    expect = data_off + row_bytes * abs(h)
    if fsize != len(data):
        problems.append(f"file size field {fsize} != actual {len(data)}")
    if len(data) < expect:
        problems.append(f"truncated: need {expect} bytes, have {len(data)}")
    if img_size not in (0, row_bytes * abs(h)):
        problems.append(f"biSizeImage {img_size} != {row_bytes * abs(h)}")
    if data_off != 54:
        problems.append(f"pixel data starts at {data_off} (parser assumes header 54)")

    print(f"{path.name}: {w}x{h} {'bottom-up' if h > 0 else 'top-down'} "
          f"{bpp}bpp comp={comp} data_off={data_off} size={len(data)}")
    for p in problems:
        print(f"   !! {p}")
        ok = False
    if ok:
        print("   OK for bmp_parser.v")
    return ok


if __name__ == "__main__":
    files = [Path(p) for p in sys.argv[1:]]
    if not files:
        files = sorted((Path(__file__).resolve().parents[1] / "media").glob("*.BMP"))
    good = sum(check(f) for f in files)
    print(f"\n{good}/{len(files)} files are FPGA-ready")
    sys.exit(0 if good == len(files) else 1)
