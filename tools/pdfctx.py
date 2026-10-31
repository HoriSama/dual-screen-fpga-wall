import re, zlib, sys
from pathlib import Path
d = Path(sys.argv[1])
def text_of(name):
    raw = (d/name).read_bytes()
    parts=[]
    for m in re.finditer(rb"stream[\r\n]+(.*?)[\r\n]+endstream", raw, re.S):
        c=m.group(1)
        try: parts.append(zlib.decompress(c).decode("latin-1","ignore"))
        except Exception: parts.append(c.decode("latin-1","ignore"))
    return "\n".join(parts)
blob = text_of("6_EX_DEVICE.pdf")
# PDF text operators: (string) Tj  -- pull all show-text strings in order
strings = re.findall(r"\((.*?)\)\s*Tj", blob)
joined = "|".join(strings)
idx = joined.find("Card")
print("total strings:", len(strings))
seg = joined[max(0,idx-800): idx+1200] if idx>=0 else joined[:1200]
print("--- around Card ---")
print(seg[:2200])
