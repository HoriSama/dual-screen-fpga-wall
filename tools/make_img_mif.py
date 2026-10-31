from pathlib import Path
from PIL import Image
W, H = 96, 72
ROOT = Path(__file__).resolve().parents[1]
MEDIA = ROOT / "media"
def q(px):
    r, g, b = px[:3]
    return ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
words = []
for nm in ["CAM1", "CAM2", "CAM3", "CAM4"]:
    im = Image.open(MEDIA / (nm + ".BMP")).convert("RGB").resize((W, H), Image.LANCZOS)
    words += [q(im.getpixel((x, y))) for y in range(H) for x in range(W)]
DEPTH = 32768
words += [0] * (DEPTH - len(words))
lines = ["WIDTH=12;", "DEPTH=%d;" % DEPTH, "ADDRESS_RADIX=UNS;", "DATA_RADIX=HEX;", "", "CONTENT BEGIN"]
lines += ["%d  : %03X;" % (i, w) for i, w in enumerate(words)]
lines += ["END;"]
(ROOT / "rtl" / "wall_img.mif").write_text("\n".join(lines) + "\n", encoding="ascii")
print("mif words:", len(words))
