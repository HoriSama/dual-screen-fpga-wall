import re, zlib, sys
from pathlib import Path
d = Path(sys.argv[1])
def flat(name):
    raw=(d/name).read_bytes(); parts=[]
    for m in re.finditer(rb"stream[\r\n]+(.*?)[\r\n]+endstream", raw, re.S):
        c=m.group(1)
        try: parts.append(zlib.decompress(c).decode("latin-1","ignore"))
        except Exception: parts.append(c.decode("latin-1","ignore"))
    s=re.findall(r"\((.*?)\)\s*Tj", "\n".join(parts))
    return "".join(s)
for name in ("2_FPGA.pdf","6_EX_DEVICE.pdf","4_GPIO.pdf"):
    f = flat(name)
    print("===", name, "len", len(f))
    for key in ("FPGA_SD_CLK","FPGA_SD_CMD","FPGA_SD_D0","FPGA_SD_D1","SD_CLK","SD_CMD"):
        i = f.find(key)
        count = f.count(key)
        if count:
            print(f"  {key}: count={count} at {i}")
            print("   ...", f[max(0,i-120):i+120].replace(chr(10)," "))
