import re, zlib, sys
from pathlib import Path
d = Path(sys.argv[1])
raw=(d/"2_FPGA.pdf").read_bytes(); parts=[]
for m in re.finditer(rb"stream[\r\n]+(.*?)[\r\n]+endstream", raw, re.S):
    c=m.group(1)
    try: parts.append(zlib.decompress(c).decode("latin-1","ignore"))
    except Exception: parts.append(c.decode("latin-1","ignore"))
s=re.findall(r"\((.*?)\)\s*Tj", "\n".join(parts))
f="".join(s)
i=f.find("FPGA_SD_D2")
print("window:", f[max(0,i-700):i+700].replace("\n"," "))
