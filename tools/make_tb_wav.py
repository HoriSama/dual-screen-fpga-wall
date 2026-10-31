"""Build a FAT32 volume that holds MUSIC.WAV for tb_wav.v.

Layout is deliberately the same shape as make_tb_fat32.py (512 B sectors,
8 sectors/cluster, 1 reserved, 2 FATs of 1 sector, root cluster 2), just with a
single 16-bit stereo WAV instead of four images.

Outputs, in wall/tb/:
  wav_img.hex        the sectors ("AA BB ..." hex, one sector per 512 bytes)
  expected_wav.hex   the 32-bit words the loader must push to SDRAM
"""
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TB = ROOT / "tb"

SEC, SPC, RSV, NFATS, FATSZ, ROOT_CLU = 512, 8, 1, 2, 1, 2
DATA_START = RSV + NFATS * FATSZ
FRAMES = 1000                      # 4000 B of PCM + 44 B header = 1 cluster


def left_of(i):
    return (i * 3) & 0xFFFF


def right_of(i):
    return (i * 5 + 7) & 0xFFFF


def make_wav():
    body = bytearray()
    for i in range(FRAMES):
        body += struct.pack("<HH", left_of(i), right_of(i))
    h = bytearray(44)
    h[0:4] = b"RIFF"
    struct.pack_into("<I", h, 4, 36 + len(body))
    h[8:12] = b"WAVE"
    h[12:16] = b"fmt "
    struct.pack_into("<I", h, 16, 16)
    struct.pack_into("<H", h, 20, 1)          # PCM
    struct.pack_into("<H", h, 22, 2)          # stereo
    struct.pack_into("<I", h, 24, 48000)
    struct.pack_into("<I", h, 28, 48000 * 4)
    struct.pack_into("<H", h, 32, 4)
    struct.pack_into("<H", h, 34, 16)
    h[36:40] = b"data"
    struct.pack_into("<I", h, 40, len(body))
    return bytes(h) + bytes(body)


def main():
    wav = make_wav()
    first = ROOT_CLU + 1
    nclu = (len(wav) + SEC * SPC - 1) // (SEC * SPC)
    assert nclu == 1, nclu
    nsec = DATA_START + (first + nclu - ROOT_CLU) * SPC
    secs = [bytearray(SEC) for _ in range(nsec)]

    bs = secs[0]
    bs[0:3] = b"\xEB\x3C\x90"
    bs[3:11] = b"MSDOS5.0"
    struct.pack_into("<H", bs, 0x0B, SEC)
    bs[0x0D] = SPC
    struct.pack_into("<H", bs, 0x0E, RSV)
    bs[0x10] = NFATS
    bs[0x15] = 0xF8
    struct.pack_into("<I", bs, 0x20, nsec)
    struct.pack_into("<I", bs, 0x24, FATSZ)
    struct.pack_into("<I", bs, 0x2C, ROOT_CLU)
    bs[0x52:0x5A] = b"FAT32   "
    bs[510], bs[511] = 0x55, 0xAA

    # file sectors
    lba = DATA_START + (first - ROOT_CLU) * SPC
    blob = wav + b"\x00" * ((-len(wav)) % SEC)
    for i in range(len(blob) // SEC):
        secs[lba + i] = bytearray(blob[i * SEC:(i + 1) * SEC])

    # FAT
    fat = bytearray(SEC)
    struct.pack_into("<I", fat, 0, 0x0FFFFFF8)
    struct.pack_into("<I", fat, 4, 0x0FFFFFFF)
    struct.pack_into("<I", fat, first * 4, 0x0FFFFFFF)
    for f in range(NFATS):
        secs[RSV + f * FATSZ] = bytearray(fat)

    # root directory: one entry, "MUSIC   WAV"
    root = secs[DATA_START + (ROOT_CLU - ROOT_CLU) * SPC]
    e = bytearray(32)
    e[0:8] = b"MUSIC   "
    e[8:11] = b"WAV"
    e[11] = 0x20
    struct.pack_into("<H", e, 20, (first >> 16) & 0xFFFF)
    struct.pack_into("<H", e, 26, first & 0xFFFF)
    struct.pack_into("<I", e, 28, len(wav))
    root[0:32] = e

    TB.mkdir(exist_ok=True)
    (TB / "wav_img.hex").write_text(
        "".join("%02X%s" % (b, "\n" if (i + 1) % 32 == 0 else " ")
                for i, b in enumerate(b for s in secs for b in s)) + "\n",
        encoding="ascii")

    words = [(right_of(i) << 16) | left_of(i) for i in range(FRAMES)]
    (TB / "expected_wav.hex").write_text(
        "".join("%08X\n" % w for w in words), encoding="ascii")

    print(f"volume {nsec} sectors, data_start={DATA_START}, MUSIC.WAV first_cluster={first}, "
          f"{nclu} cluster, {len(wav)} bytes, {FRAMES} frames")
    print(f"file sectors {lba}..{lba + len(blob)//SEC - 1}")


if __name__ == "__main__":
    main()