import re, zlib, sys
from pathlib import Path
d = Path(sys.argv[1])
def strings(name):
    raw = (d/name).read_bytes(); parts=[]
    for m in re.finditer(rb"stream[\r\n]+(.*?)[\r\n]+endstream", raw, re.S):
        c=m.group(1)
        try: parts.append(zlib.decompress(c).decode("latin-1","ignore"))
        except Exception: parts.append(c.decode("latin-1","ignore"))
    return re.findall(r"\((.*?)\)\s*Tj", "\n".join(parts))
for name in ("2_FPGA.pdf","6_EX_DEVICE.pdf"):
    s = strings(name)
    joined = "".join(s)
    print("=== ", name)
    for key in ("FPGASDCLK","FPGASDCMD","FPGASDD0","FPGASDD1","FPGASDD2","FPGASDD3","SD_CLK","SD_CMD","SD_D0"):
        i = joined.replace("|","").find(key.replace("_",""))
        if i>=0:
            # print tokens in a window around the match using the piped list
            j = "|".join(s)
            for m in re.finditer(re.escape(key.replace("_","")), j.replace("|","")):
                pass
    # simpler: find tokens in the piped stream that look like pin balls near SD nets
    piped = "|".join(s)
    for m in re.finditer(r"(?:F|P|G|A|S|D)[^|]{0,3}", piped):
        pass
    # dump the raw piped text and let the user see the neighbourhood of 'SD'
    idx = piped.replace("|","").find("SDCLK")
    print("SDCLK idx:", idx)
    if idx>=0:
        flat = piped.replace("|","")
        print(repr(flat[max(0,idx-300):idx+300]))
