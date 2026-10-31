"""Extract text with coordinates from a vector PDF and pair SD nets with FPGA balls.

Used to answer: which EG4S20BG256 ball carries FPGA_SD_CLK / CMD / D0 / D3?
The schematic (2_FPGA.pdf) draws each symbol pin as a ball label inside the
symbol body plus a net label on the wire stub, both on the same baseline, so
matching by y (and nearest x) recovers the mapping.
"""
import re
import sys
import zlib
from pathlib import Path

BALL = re.compile(r"^[A-HJ-NP-T][0-9]{1,2}$")


def page_text(pdf: Path):
    raw = pdf.read_bytes()
    chunks = []
    for m in re.finditer(rb"stream[\r\n]+(.*?)[\r\n]+endstream", raw, re.S):
        try:
            chunks.append(zlib.decompress(m.group(1)).decode("latin-1", "ignore"))
        except Exception:
            pass
    items = []  # (x, y, ch)
    for content in chunks:
        for block in re.findall(r"BT(.*?)ET", content, re.S):
            x, y = 0.0, 0.0
            for tok in re.finditer(
                r"([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+Tm"
                r"|([-\d.]+)\s+([-\d.]+)\s+Td"
                r"|\((?:\\.|[^\\()])*\)\s*Tj",
                block,
            ):
                if tok.group(6) is not None:
                    x, y = float(tok.group(5)), float(tok.group(6))
                elif tok.group(8) is not None:
                    x += float(tok.group(7))
                    y += float(tok.group(8))
                else:
                    s = tok.group(0)
                    s = s[s.index("(") + 1: s.rindex(")")]
                    s = s.replace(r"\(", "(").replace(r"\)", ")").replace(r"\\", "\\")
                    for ch in s:
                        items.append((x, y, ch))
                        x += 6.0   # advance; refines later by re-sorting
    return items


def lines(items, tol=2.0):
    rows = {}
    for x, y, ch in items:
        rows.setdefault(round(y / tol), []).append((x, ch))
    out = []
    for key, chars in rows.items():
        chars.sort()
        text = "".join(c for _, c in chars)
        out.append((key * tol, text, min(c[0] for c in chars)))
    return out


def main(pdf_path: Path):
    items = page_text(pdf_path)
    rows = lines(items)
    print(f"{pdf_path.name}: {len(items)} glyphs, {len(rows)} rows")
    targets = ["FPGA_SD_CLK", "FPGA_SD_CMD", "FPGA_SD_D0", "FPGA_SD_D1", "FPGA_SD_D2", "FPGA_SD_D3"]
    for y, text, x in sorted(rows, key=lambda r: -r[0]):
        if any(t in text for t in targets):
            print(f"y={y:8.1f} x={x:8.1f} :: {text[:120]}")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
