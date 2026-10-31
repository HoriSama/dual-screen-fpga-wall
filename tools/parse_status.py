"""Decode wall-node status frames captured with tools/read_status.ps1.

Byte map lives in wall/rtl/wall_status_tx.v.  Frame: 34 bytes, starts with
'W' 'L', byte 31 is 'Z', ends 0x0D 0x0A.

    python tools/parse_status.py ..\\.tmp\\com6.bin ..
"""
import sys
from pathlib import Path

NLEN = 34


def frames(buf):
    i = 0
    while i + NLEN <= len(buf):
        if buf[i] == 0x57 and buf[i + 1] == 0x4C and buf[i + 31] == 0x5A \
                and buf[i + 32] == 0x0D and buf[i + 33] == 0x0A:
            yield buf[i:i + NLEN]
            i += NLEN
        else:
            i += 1


def decode(f):
    u16 = lambda a: (f[a] << 8) | f[a + 1]
    return dict(
        node=chr(f[2]),
        link_ok=f[3] & 1,
        sync_ok=(f[3] >> 1) & 1,
        frozen=(f[3] >> 2) & 1,
        drag=(f[3] >> 3) & 1,
        sel=f[4],
        gx=(f[5] << 8) | f[6],
        ok=u16(7),
        err=u16(9),
        sd_vcnt=f[11],
        sd_retried=f[12] & 1,
        sd_read_end=(f[12] >> 1) & 1,
        sd_init_done=(f[12] >> 2) & 1,
        vlocked=f[13] & 1,
        vready=(f[13] >> 1) & 1,
        sup_state=(f[13] >> 4) & 3,
        rec_cnt=f[14],
        pll_rst=f[15],
        stage_gx=u16(16),
        rst_cnt=f[18],
        sd_state=f[20] & 0x0F,
        frame_cnt=u16(21),
        sd_b0=f[23],
        win_w=u16(24),
        win_h=u16(26),
        sdram_err=u16(28),
        sdram_done=f[30] & 1,
        sdram_fail=(f[30] >> 1) & 1,
    )


for name in sys.argv[1:]:
    buf = Path(name).read_bytes()
    fr = [decode(f) for f in frames(buf)]
    print(f"=== {name}: {len(buf)} bytes, {len(fr)} frames")
    if not fr:
        print("  no frame -- first 64 bytes:", buf[:64].hex(" "))
        continue
    for k in ("node", "link_ok", "sync_ok", "sel", "gx", "stage_gx", "win_w", "win_h",
              "vlocked", "vready", "sup_state", "rst_cnt", "pll_rst", "rec_cnt",
              "ok", "err", "sdram_done", "sdram_fail", "sdram_err",
              "sd_init_done", "sd_state", "sd_vcnt", "sd_read_end", "sd_retried", "sd_b0"):
        vals = sorted({d[k] for d in fr})
        print(f"  {k:14s} = {vals if len(vals) > 1 else vals[0]}")
    fc = [d["frame_cnt"] for d in fr]
    print(f"  frame_cnt      : {fc[0]} -> {fc[-1]}")
