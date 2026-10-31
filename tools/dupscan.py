"""dupscan.py -- find signals declared BOTH at module scope and inside a generate
block of the same module.

That pattern is legal Verilog (the inner declaration shadows the outer one) and
ModelSim follows the standard, but TD resolved an `assign` that sat in the
generate block to the OUTER, undriven copy -- simulation passed and node B ran
with fade_gain == 0 (black pictures).  Run this after adding RTL:

    python tools/dupscan.py        # prints nothing when clean
"""
import re, glob, os
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rtl")
decl = re.compile(r"^(\s*)(reg|wire)\b([^=;]*)(?:=[^;]*)?;")
def names(body):
    body = re.sub(r"//.*", "", body)
    body = re.sub(r"\[[^\]]*\]", " ", body)
    return [t for t in re.split(r"[^A-Za-z0-9_$]+", body) if t and not t.isdigit()
            and t not in ("reg", "wire", "signed", "unsigned")]
for f in sorted(glob.glob(os.path.join(root, "*.v"))):
    src = open(f, encoding="utf-8", errors="replace").read().splitlines()
    cur = None; top = {}; inner = {}; res = []
    def flush():
        if cur:
            for n in sorted(set(top) & set(inner)):
                res.append((cur, n, top[n], inner[n]))
        return {}, {}
    for i, line in enumerate(src, 1):
        m = re.match(r"^\s*module\s+(\w+)", line)
        if m:
            flush()
            cur = m.group(1); top = {}; inner = {}
            continue
        m = decl.match(line)
        if not m:
            continue
        dst = top if len(m.group(1)) <= 4 else inner
        for n in names(m.group(3)):
            dst.setdefault(n, i)
    flush()
    if res:
        print(os.path.basename(f))
        for mod, n, t, i in res:
            print("   %-20s %-16s module:%s block:%s" % (mod, n, t, i))
