import re, sys
sys.path.insert(0, r"tools")
from pdf_coords import page_text, lines
from pathlib import Path
items = page_text(Path(r"E:\HX4S20C\HX4S20_Contest_202606\3_原理图\开发板原理图\2_FPGA.pdf"))
rows = lines(items, tol=1.5)
for y, text, x in sorted(rows, key=lambda r: -r[0]):
    if 500 <= y <= 640:
        print(f"y={y:7.1f} :: {text[:110]}")
