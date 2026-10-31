"""Build a minimal FAT32 volume for the wall TF loader testbench.

Produces, in wall/tb/:
  fat32_img.hex     512-byte sectors, one hex line per sector ("@LBA <hex>"),
                    for tb_tf_load.v's sector-server model to serve.
  expected_pic.hex  the 4 x 27,648 RGB565 sampled words the loader must write,
                    one hex word per line, 27,648 words per picture.
  expected_hi.hex   the 4 x 307,200 words of the 640x480 1:1 copies (C9),
                    one per picture, contiguous: picture*307,200 + y*640 + x.
  fat32_img.txt     human summary (BPB fields, directory entries, chains).

The volume is deliberately tiny but structurally real FAT32:
  512 B/sector, 8 sectors/cluster, 1 reserved sector, 2 FATs, 8 sectors/FAT,
  root cluster 2, files from cluster 3 upwards, contiguous chains.

Images are 24-bit uncompressed BMPs whose pixels are a deterministic function
of (x, y, picture index), so both expectations can be recomputed in Python and
compared word for word.

C9: ALL FOUR images are 640x480 (the real card's format), and each one differs
from the others, because the point of the four 1:1 copies is that paging through
the album must show four DIFFERENT photographs.  With four identical images a
copy landing in the wrong HI region would pass unnoticed.

Run:  python tools\\make_tb_fat32.py
"""
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TB = ROOT / "tb"

SEC = 512
SPC = 8                        # like a real card; keeps the FAT inside 8 sectors
RSV = 1
NFATS = 2
FATSZ = 8                      # sectors per FAT (1024 cluster entries; we need ~905)
ROOT_CLU = 2
DATA_START = RSV + NFATS * FATSZ

FILES = [                       # name, width, height -- all 640x480 like the card
    ("CAM1.BMP", 640, 480),
    ("CAM2.BMP", 640, 480),
    ("CAM3.BMP", 640, 480),
    ("CAM4.BMP", 640, 480),
]


def pixel(x, y, w, h, pid=0):
    """Deterministic test pixel: distinct in every channel AND per picture.

    The per-picture terms matter: with four identical photographs a 1:1 copy
    written into the wrong HI region would look correct to the testbench.
    """
    r = ((x * 255) // max(1, w - 1) + pid * 48) & 0xFF
    g = ((y * 255) // max(1, h - 1) + pid * 24) & 0xFF
    b = ((x // 8 + y // 8 + pid) & 1) * 255
    return r, g, b


def make_bmp(w, h, pid=0):
    row_bytes = (w * 3 + 3) & ~3
    pad = row_bytes - w * 3
    body = bytearray()
    for y in range(h - 1, -1, -1):          # bottom-up, like every real BMP
        row = bytearray()
        for x in range(w):
            r, g, b = pixel(x, y, w, h, pid)
            row += bytes((b, g, r))
        row += b"\x00" * pad
        body += row
    hdr = bytearray(54)
    hdr[0:2] = b"BM"
    struct.pack_into("<I", hdr, 2, 54 + len(body))
    struct.pack_into("<I", hdr, 10, 54)
    struct.pack_into("<I", hdr, 14, 40)
    struct.pack_into("<i", hdr, 18, w)
    struct.pack_into("<i", hdr, 22, h)
    struct.pack_into("<H", hdr, 26, 1)
    struct.pack_into("<H", hdr, 28, 24)
    struct.pack_into("<I", hdr, 30, 0)
    struct.pack_into("<I", hdr, 34, len(body))
    return bytes(hdr) + bytes(body)


def thumb(bmp_w, bmp_h, pid=0):
    """The 192x144 area of the sampled bank this image should produce.

    Only used for the summary line in fat32_img.txt; the authoritative sampled
    expectation is the DDA mirror further down (expected_pic.hex), which matches
    the RTL's fractional sampler exactly.
    """
    # hi-res sampler: 192 columns x 144 rows
    sx = max(1, bmp_w // 192)
    sy = max(1, bmp_h // 144)
    out = [0] * 6912
    for m in range(72):
        for e in range(min(192, bmp_w)):
            if e % 2:
                continue
            c = e // 2
            if c >= 96:
                break
            r, g, b = pixel(e * sx, 2 * m * sy, bmp_w, bmp_h, pid)
            out[m * 96 + c] = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
    return out


def main():
    imgs = [(n, w, h, make_bmp(w, h, pid)) for pid, (n, w, h) in enumerate(FILES)]
    # layout pre-pass: clusters are handed out from ROOT_CLU+1 upwards
    plan, clu = [], ROOT_CLU + 1
    for name, w, h, data in imgs:
        nclu = (len(data) + SEC * SPC - 1) // (SEC * SPC)
        plan.append((name, w, h, data, clu, nclu))
        clu += nclu
    nsec = DATA_START + (clu - 2) * SPC + 1
    secs = [bytearray(SEC) for _ in range(nsec)]

    # ---- boot sector --------------------------------------------------
    bs = secs[0]
    bs[0:3] = b"\xEB\x3C\x90"
    bs[3:11] = b"MSDOS5.0"
    struct.pack_into("<H", bs, 0x0B, SEC)
    bs[0x0D] = SPC
    struct.pack_into("<H", bs, 0x0E, RSV)
    bs[0x10] = NFATS
    struct.pack_into("<H", bs, 0x11, 0)          # root entries (0 for FAT32)
    struct.pack_into("<H", bs, 0x13, 0)          # total sectors 16 (0 for FAT32)
    bs[0x15] = 0xF8
    struct.pack_into("<H", bs, 0x16, 0)          # FAT size 16 (0 for FAT32)
    struct.pack_into("<I", bs, 0x20, nsec)
    struct.pack_into("<I", bs, 0x24, FATSZ)
    struct.pack_into("<I", bs, 0x2C, ROOT_CLU)
    struct.pack_into("<H", bs, 0x30, 1)
    struct.pack_into("<H", bs, 0x32, 6)
    bs[0x52:0x5A] = b"FAT32   "
    bs[510] = 0x55
    bs[511] = 0xAA

    # ---- place files after the root cluster ---------------------------
    # A cluster is SPC sectors, so the file must be written across
    # nclu*SPC consecutive sectors starting at its first cluster's LBA.  The
    # first version sliced one 512-byte chunk per *cluster* and wrote them to
    # consecutive sectors, which left 7 of every 8 sectors zero: the volume
    # looked fine to a boot-sector/BPB check (and even to the directory scan)
    # but a correct FAT32 reader saw a truncated file.  tb_tf_load caught it as
    # "thumbnail matches for 10 rows, then all black".
    entries = []
    for name, w, h, data, clu, nclu in plan:
        lba = DATA_START + (clu - 2) * SPC
        blob = bytes(data) + b"\x00" * ((-len(data)) % SEC)
        assert len(blob) <= nclu * SPC * SEC, (name, len(blob), nclu * SPC * SEC)
        for i in range(len(blob) // SEC):
            secs[lba + i] = bytearray(blob[i * SEC:(i + 1) * SEC])
        entries.append((name, clu, nclu, len(data)))

    # ---- FAT: contiguous chains ---------------------------------------
    fat = bytearray(SEC * FATSZ)
    struct.pack_into("<I", fat, 0, 0x0FFFFFF8)
    struct.pack_into("<I", fat, 4, 0x0FFFFFFF)
    for _, first, nclu, _ in entries:
        for i in range(nclu):
            c = first + i
            v = 0x0FFFFFFF if i == nclu - 1 else c + 1
            struct.pack_into("<I", fat, c * 4, v)
    for f in range(NFATS):
        for s in range(FATSZ):
            secs[RSV + f * FATSZ + s] = bytearray(fat[s * SEC:(s + 1) * SEC])

    # ---- root directory ----------------------------------------------
    root = secs[DATA_START + (ROOT_CLU - 2) * SPC]
    off = 0
    for name, first, nclu, size in entries:
        e = bytearray(32)
        base, ext = name.split(".")
        e[0:8] = base.upper().ljust(8).encode()
        e[8:11] = ext.upper().ljust(3).encode()
        e[11] = 0x20                              # archive
        struct.pack_into("<H", e, 20, (first >> 16) & 0xFFFF)
        struct.pack_into("<H", e, 26, first & 0xFFFF)
        struct.pack_into("<I", e, 28, size)
        root[off:off + 32] = e
        off += 32

    # ---- write the image ---------------------------------------------
    TB.mkdir(exist_ok=True)
    def hexof(sectors):
        return "".join("%02X%s" % (b, "\n" if (i + 1) % 32 == 0 else " ")
                       for i, b in enumerate(b for s in sectors for b in s)) + "\n"

    (TB / "fat32_img.hex").write_text(hexof(secs), encoding="ascii")

    # ---- second image: the same volume behind an MBR partition table ----
    # This is the layout the real A-board card turned out to have (partition
    # type 0x0C starting at LBA 32), and its LBA 0 has no boot code at all --
    # which is why "LBA 0 is all zeroes" did not mean "empty card".
    PART_LBA = 32
    mbr_base = [bytearray(SEC) for _ in range(PART_LBA)]
    m = mbr_base[0]
    struct.pack_into("<I", m, 440, 0xFFA31DE4)    # disk signature
    e = bytearray(16)
    e[0] = 0x00                                   # not bootable
    e[1:4] = b"\x00\x21\x00"                      # CHS start (not used by us)
    e[4] = 0x0C                                   # FAT32 LBA
    e[5:8] = b"\xD5\xE8\xAD"                      # CHS end
    struct.pack_into("<I", e, 8, PART_LBA)        # first LBA of the volume
    struct.pack_into("<I", e, 12, nsec)           # sectors in the partition
    m[446:462] = e
    m[510] = 0x55
    m[511] = 0xAA
    (TB / "fat32_mbr.hex").write_text(hexof(mbr_base + secs), encoding="ascii")

    exp = []
    for pid, ((name, w, h, data), (n2, first, nclu, size)) in enumerate(
            zip([(n, w, h, d) for n, w, h, d in imgs], entries)):
        assert name == n2
        exp.extend(thumb(w, h, pid))

    # ---- sampled 192x144 expectation: what wall_tf_load pushes to SDRAM ----
    # pic_base[i] + row*192 + col, RGB565, for the sampled pixels only; the rest
    # of the 192x144 block is never written and stays "x" (don't care).
    pic = ["x"] * (4 * 27648)
    for pid, (name, w, h, data) in enumerate([(n, w, h, d) for n, w, h, d in imgs]):
        # Mirror the RTL's FRACTIONAL (DDA) sampler -- see the DDA block in
        # wall_tf_load.v.  Row 0 is kept unconditionally (sel_first); each row's
        # END decides the NEXT row, with racc starting at 0.
        racc = 0
        kept = [0]
        for i in range(h - 1):
            rs = racc + 144
            if rs >= h:
                kept.append(i + 1)
                racc = rs - h
            else:
                racc = rs
        n_kept = len(kept)
        for idx, i in enumerate(kept):
            bank_row = n_kept - 1 - idx
            y = h - 1 - i                      # BMP file row i is y = h-1-i
            ca = max(0, w - 192)
            k = 0
            for x in range(w):
                cs = ca + 192
                if cs >= w:
                    if k < 192:
                        r, g, b = pixel(x, y, w, h, pid)
                        word = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
                        pic[pid * 27648 + bank_row * 192 + k] = "%05X" % word
                        k += 1
                    ca = cs - w
                else:
                    ca = cs
    (TB / "expected_pic.hex").write_text("\n".join(pic) + "\n", encoding="ascii")

    # ---- 1:1 copies (C2/C9): 640x480 RGB565 for EVERY picture --------------
    # Contiguous in SDRAM: picture*307200 + y*640 + x.  The RTL only writes words
    # that exist (px < 640, hi_y < 480), so anything outside the source image
    # stays "x" = never written.  With four 640x480 files nothing is "x", which
    # is exactly what makes the word-for-word check meaningful.
    hi = []
    for pid, (name, w, h, data) in enumerate([(n, w, h, d) for n, w, h, d in imgs]):
        for y in range(480):
            for x in range(640):
                if x < w and y < h:
                    r, g, b = pixel(x, y, w, h, pid)
                    hi.append("%05X" % (((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)))
                else:
                    hi.append("x")
    (TB / "expected_hi.hex").write_text("\n".join(hi) + "\n", encoding="ascii")
    print("expected_hi.hex:", len(hi), "words (4 x 640x480, 1:1)")

    print("expected_pic.hex:", len(pic), "words (x = never written)")

    # ---- self check --------------------------------------------------
    lines = [
        f"volume: {nsec} sectors, {SEC} B/sector, {SPC} sec/cluster, "
        f"rsv={RSV}, nfats={NFATS}, fat_size={FATSZ}, root_cluster={ROOT_CLU}",
        f"data_start (LBA) = {DATA_START}",
        "files:",
    ]
    for name, first, nclu, size in entries:
        lines.append(f"  {name}: first_cluster={first} clusters={nclu} size={size}")
    lines.append(f"expected bank words: {len(exp)} (4 x 6912 summary only)")
    lines.append(f"expected 1:1 words : {len(hi)} (4 x 307200)")
    (TB / "fat32_img.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))

    # verify by decoding what we just wrote, with independent code
    raw = (TB / "fat32_img.hex").read_text(encoding="ascii").strip()
    img = bytes.fromhex(raw)
    assert len(img) == nsec * SEC, (len(img), nsec * SEC)
    bps = struct.unpack_from("<H", img, 0x0B)[0]
    fatsz = struct.unpack_from("<I", img, 0x24)[0]
    rootc = struct.unpack_from("<I", img, 0x2C)[0]
    assert (bps, fatsz, rootc) == (SEC, FATSZ, ROOT_CLU)
    assert img[510:512] == b"\x55\xAA"
    rd = img[DATA_START * SEC:(DATA_START + 1) * SEC]
    names = []
    for i in range(16):
        e = rd[i * 32:(i + 1) * 32]
        if e[0] == 0:
            break
        names.append(e[0:8].decode().strip() + "." + e[8:11].decode().strip())
    assert names == ["CAM1.BMP", "CAM2.BMP", "CAM3.BMP", "CAM4.BMP"], names
    print("SELF-CHECK PASS: boot sector, directory and chains decode as intended")


if __name__ == "__main__":
    main()
