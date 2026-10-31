import re, zlib, sys
from pathlib import Path
d = Path(sys.argv[1])
for pdf in sorted(d.glob("*.pdf")):
    raw = pdf.read_bytes()
    parts = []
    for m in re.finditer(rb"stream[\r\n]+(.*?)[\r\n]+endstream", raw, re.S):
        c = m.group(1)
        try: parts.append(zlib.decompress(c).decode("latin-1","ignore"))
        except Exception: parts.append(c.decode("latin-1","ignore"))
    blob = "\n".join(parts)
    toks = sorted(set(re.findall(r"[A-Za-z0-9_]{2,20}", blob)))
    hit = [t for t in toks if re.search(r"(SD_|TF_|CARD|DAT[0-9]|SCLK|MISO|MOSI)", t, re.I)][:15]
    print(pdf.name, "chars", len(blob), "hits", hit, flush=True)
