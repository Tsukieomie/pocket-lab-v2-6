#!/usr/bin/env python3
"""
spi_patch.py — APCB SMT Token SPI Flash Patcher
Platform: AMD Renoir (Ryzen 7 4700U), ASUS X513IA
Requires: kernetix_km.ko loaded (/dev/KernetixDriver0 present)
Run as: sudo python3 spi_patch.py

Patches CfgSMTControl (token 0x0076) in APCB primary + mirror:
  0x29D821: 0x00 -> 0x01  (primary)
  0x6E5821: 0x00 -> 0x01  (mirror)
"""

import os, mmap, struct, time, sys

# ── Config ─────────────────────────────────────────────────────────────────
SPI_BASE    = 0xFEC11000   # New AMD FCH SPI controller (Renoir)
PAGE_SZ     = 0x1000
BLOCK       = 64           # FIFO block size

PATCHES = [
    (0x29D821, 0x29D000, "primary APCB"),
    (0x6E5821, 0x6E5000, "mirror APCB"),
]
# ───────────────────────────────────────────────────────────────────────────

kern_fd = os.open('/dev/KernetixDriver0', os.O_RDWR)
spi_map = mmap.mmap(kern_fd, PAGE_SZ, mmap.MAP_SHARED,
                    mmap.PROT_READ | mmap.PROT_WRITE, 0, SPI_BASE)

def rd8(off):
    spi_map.seek(off); return struct.unpack('B', spi_map.read(1))[0]

def wr8(off, v):
    spi_map.seek(off); spi_map.write(struct.pack('B', v))

def wait_done():
    for _ in range(500000):
        if not (rd8(0x47) & 0x80): break
    for _ in range(500000):
        spi_map.seek(0x4C)
        if not (struct.unpack('<I', spi_map.read(4))[0] >> 31): break

def exec_cmd():
    wr8(0x47, 0xFF); wait_done()

def wren():
    wr8(0x45, 0x06); wr8(0x4B, 0); wr8(0x48, 0); exec_cmd()

def rdsr():
    wr8(0x45, 0x05); wr8(0x4B, 1); wr8(0x48, 0); exec_cmd()
    return rd8(0x80)

def wait_not_busy(ms=2000):
    for _ in range(ms):
        if not (rdsr() & 1): return True
        time.sleep(0.001)
    return False

def read_block(addr):
    wr8(0x80, (addr >> 16) & 0xFF)
    wr8(0x81, (addr >>  8) & 0xFF)
    wr8(0x82,  addr        & 0xFF)
    wr8(0x45, 0x03); wr8(0x48, 3); wr8(0x4B, BLOCK)
    exec_cmd()
    spi_map.seek(0x83)
    return bytearray(spi_map.read(BLOCK))

def erase_sector(addr):
    wait_not_busy(); wren()
    wr8(0x80, (addr >> 16) & 0xFF)
    wr8(0x81, (addr >>  8) & 0xFF)
    wr8(0x82,  addr        & 0xFF)
    wr8(0x45, 0x20); wr8(0x48, 3); wr8(0x4B, 0); exec_cmd()
    for _ in range(500):
        time.sleep(0.001)
        if not (rdsr() & 1): break

def write_block(addr, data):
    wait_not_busy(); wren()
    wr8(0x80, (addr >> 16) & 0xFF)
    wr8(0x81, (addr >>  8) & 0xFF)
    wr8(0x82,  addr        & 0xFF)
    spi_map.seek(0x83); spi_map.write(bytes(data))
    wr8(0x45, 0x02); wr8(0x48, 3 + BLOCK); wr8(0x4B, 0); exec_cmd()

def read_sector(base):
    buf = bytearray()
    for i in range(4096 // BLOCK):
        buf += read_block(base + i * BLOCK)
    return buf

def write_sector(base, data):
    print(f"  Erasing 0x{base:06X}...")
    erase_sector(base)
    n = 4096 // BLOCK
    for i in range(n):
        write_block(base + i * BLOCK, data[i*BLOCK:(i+1)*BLOCK])
        if i % 16 == 0:
            print(f"  [{i}/{n}]", flush=True)


def patch_token(token_off, sector_base, label):
    print(f"\n=== Patching {label} ===")
    print(f"  Token @ 0x{token_off:06X}, sector 0x{sector_base:06X}")

    sec = read_sector(sector_base)
    tok = token_off - sector_base
    print(f"  Current value: 0x{sec[tok]:02X}")

    if sec[tok] == 0x01:
        print("  Already 0x01 — skipping")
        return True

    sec[tok] = 0x01
    write_sector(sector_base, sec)

    verify = read_sector(sector_base)
    ok = verify[tok] == 0x01
    print(f"  Verify: 0x{verify[tok]:02X} — {'OK' if ok else 'FAILED'}")
    return ok


print("=== APCB SMT Token SPI Flash Patcher ===")
print(f"SPI base:  0x{SPI_BASE:08X}")

sr = rdsr()
print(f"SR1 = 0x{sr:02X}")
wren(); time.sleep(0.005)
sr = rdsr()
print(f"SR1 after WREN = 0x{sr:02X} (WEL={(sr>>1)&1})")

if not ((sr >> 1) & 1):
    print("ERROR: WEL=0, cannot write. Check kernetix module is loaded.")
    spi_map.close(); os.close(kern_fd); sys.exit(1)

results = []
for token_off, sector_base, label in PATCHES:
    results.append(patch_token(token_off, sector_base, label))

spi_map.close()
os.close(kern_fd)

print("\n=== Summary ===")
for (tok, sec, lbl), ok in zip(PATCHES, results):
    print(f"  0x{tok:06X} ({lbl}): {'OK' if ok else 'FAILED'}")

sys.exit(0 if all(results) else 1)
