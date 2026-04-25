#!/usr/bin/env python3
# patch_apcb_smt.py
# Patch APCB in ASUS X513IA BIOS to enable SMT on Ryzen 7 4700U
# Changes APCB token 0x0076 (CfgSMTControl) from 0x00 (Auto/Disabled) to 0x01 (Enable)
#
# Usage:
#   python3 patch_apcb_smt.py X513IAAS.308
#   Output: X513IAAS.308.smt_patched
#
# WARNING: Flashing modified BIOS can brick the machine.
# Always make a verified backup before flashing.
# Requires external SPI clip for write-back on X513IA.

import struct, sys, hashlib, os

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        h.update(f.read())
    return h.hexdigest().upper()

if len(sys.argv) < 2:
    print(f"Usage: {sys.argv[0]} <X513IAAS.308>")
    sys.exit(1)

BIOS_FILE = sys.argv[1]
OUT_FILE  = BIOS_FILE + ".smt_patched"

# SHA256 of the extracted X513IAAS.308 ROM (not the ZIP wrapper)
# ZIP SHA256 (X513IAAS308.zip from ASUS CDN): D67902467FD84FF2F8D107CB7FF9551AB48F00379319AC12D7FB4560CA527ACA
ORIGINAL_SHA256 = "329BB6CD3AACA7A5C8911F891E468BBD005813648626E6C4F782850EC2E45378"

print(f"Reading {BIOS_FILE}...")
with open(BIOS_FILE, 'rb') as f:
    bios = bytearray(f.read())

actual_sha = hashlib.sha256(bios).hexdigest().upper()
if actual_sha != ORIGINAL_SHA256:
    print(f"WARNING: SHA256 mismatch!")
    print(f"  Expected: {ORIGINAL_SHA256}")
    print(f"  Got:      {actual_sha}")
    resp = input("Continue anyway? [y/N] ")
    if resp.lower() != 'y':
        sys.exit(1)
else:
    print(f"SHA256 verified: {actual_sha}")

# APCB token 0x0076 locations:
# Token entry: [id:2][val:1][pad:2][crc:3] = 8 bytes
# val byte is at token_start + 2
# All offsets are into the full X513IAAS.308 BIOS file (16,779,264 bytes)
# BIOS file = body.bin + 0x800 capsule header; prior versions used body.bin offsets (bug)
PATCHES = [
    # (token_start, apcb_header_base, description)
    (0x0029e01f, 0x0029a800, "Primary APCB"),  # verified via byte-scan 2026-04-25
    (0x006e601f, 0x006e2800, "Mirror APCB"),   # verified via byte-scan 2026-04-25
]

for tok_start, apcb_base, desc in PATCHES:
    val_off = tok_start + 2
    
    # Verify token ID
    tok_id = struct.unpack_from('<H', bios, tok_start)[0]
    if tok_id != 0x0076:
        print(f"ERROR: Expected token 0x0076 at 0x{tok_start:08x}, found 0x{tok_id:04x}")
        sys.exit(1)
    
    old_val = bios[val_off]
    print(f"\n{desc} (token at 0x{tok_start:08x}):")
    print(f"  Token ID: 0x{tok_id:04x} (CfgSMTControl)")
    print(f"  Current value: 0x{old_val:02x} ({'Auto/Disabled' if old_val==0 else f'0x{old_val:02x}'})")
    
    if old_val == 0x01:
        print(f"  Already set to Enable (0x01) -- no change needed")
        continue
    
    bios[val_off] = 0x01
    print(f"  Patched: 0x{old_val:02x} -> 0x01 (Enable)")
    
    # Zero the APCB header checksum (offset 0x10 in APCB, 4 bytes)
    # Renoir AGESA accepts checksum=0 as "skip validation"
    cksum_off = apcb_base + 0x10
    old_cksum = struct.unpack_from('<I', bios, cksum_off)[0]
    bios[cksum_off:cksum_off+4] = b'\x00\x00\x00\x00'
    print(f"  Zeroed APCB header checksum at 0x{cksum_off:08x} (was 0x{old_cksum:08x})")

print(f"\nWriting patched BIOS to {OUT_FILE}...")
with open(OUT_FILE, 'wb') as f:
    f.write(bios)

patched_sha = hashlib.sha256(bios).hexdigest().upper()
print(f"Done.")
print(f"Patched SHA256: {patched_sha}")
print()
print("Verification:")
print(f"  python3 -c \"")
print(f"  import struct")
print(f"  d = open('{OUT_FILE}','rb').read()")
print(f"  print('Primary token 0x0076 value:', hex(d[0x0029e021]))  # BIOS file offset")
print(f"  print('Mirror token 0x0076 value:',  hex(d[0x006e6021]))  # BIOS file offset\"")
print()
print("Next step: flash with external SPI clip (CH341A + SOIC-8 clip)")
print("  flashrom -p ch341a_spi -w", OUT_FILE)
