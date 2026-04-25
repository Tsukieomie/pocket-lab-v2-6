# APCB Analysis -- SMT Control Token Discovery

Machine: kenny-VivoBook-ASUSLaptop-X513IA-M513IA
BIOS: X513IA.308 (AMI Aptio V, 2021-10-26)
CPU: AMD Ryzen 7 4700U (Renoir, CPUID 0x00860601)
Date: 2026-04-25

---

## What Is APCB

AMD Platform Configuration Block (APCB) is a structured binary embedded in
the SPI flash BIOS image. It contains a tokenized database of AMD CBS default
overrides that AGESA reads at POST before the OS boots.

APCB is the last-mile configuration layer between:
  OEM (ASUS) -> APCB token overrides -> AGESA built-in defaults -> hardware

APCB tokens override AGESA compiled-in defaults. If a token is absent or set
to Auto (0x00), AGESA uses its own default for the running CPUID. If a token
is set to a specific value, AGESA uses that value regardless of CPUID.

The AmdApcbDxeV3 driver (GUID 4D3708A0-6D9B-47D3-AD87-E80C781BC0A7) reads
the APCB from flash during DXE phase and applies it to AGESA configuration.

---

## APCB Instances in X513IA BIOS.308

Six APCB instances found in BIOS body.bin:

| BIOS body offset | Size    | Purpose |
|-----------------|---------|---------|
| 0x00296000      | 0x208   | Small APCB (shadow/backup?) |
| 0x00298000      | 0x208   | Small APCB (shadow/backup?) |
| 0x0029a000      | 0x3a7c  | PRIMARY APCB -- 14,972 bytes, full CBS token table |
| 0x006de000      | 0x208   | Mirror of 0x296000 |
| 0x006e0000      | 0x208   | Mirror of 0x298000 |
| 0x006e2000      | 0x3a7c  | Mirror of 0x29a000 (identical content) |

The two APCB copies at 0x29a000 and 0x6e2000 are byte-identical.
AMD uses mirrored APCB copies for resilience (primary + backup).

---

## APCB Token Format (V3)

Each token entry is 8 bytes:

    [TokenID : 2 bytes LE]
    [Value   : 1 byte      ]  <-- actual config value
    [Padding : 2 bytes     ]  <-- zeroes
    [CRC/Hash: 3 bytes     ]  <-- integrity check (not verified at runtime on Renoir)

Values:
    0x00 = Auto (use AGESA built-in default for this CPUID)
    0x01 = Enable / value 1
    0x02 = Disable / value 2
    0x0f = Auto (alternate sentinel, same as 0x00 in some tokens)
    0xff = Auto (alternate sentinel)

---

## SMT Control Token: 0x0076

Token ID: 0x0076 (CfgSMTControl)

Offsets (NOTE: two coordinate systems -- always use BIOS file offsets when patching):

    BIOS file (X513IAAS.308, 16,779,264 bytes) -- use these:
        Primary token start:  0x0029e01f
        Primary value byte:   0x0029e021  (token_start + 2)
        Mirror token start:   0x006e601f
        Mirror value byte:    0x006e6021

    body.bin (BIOS file minus 0x800 capsule header, for reference only):
        Primary token start:  0x0029d81f
        Primary value byte:   0x0029d821
        Mirror token start:   0x006e581f
        Mirror value byte:    0x006e5821

Relationship: BIOS file offset = body.bin offset + 0x800 (capsule header size)

Current value: 0x00 (Auto)

Raw bytes at BIOS file offset 0x0029e01f (confirmed):
    76 00 00 00 00 ef a4 62
    ^--- id=0x0076
          ^--- value=0x00 (Auto)
                         ^---^---^--- CRC bytes

AMD CBS value encoding for CfgSMTControl:
    0x00 = Auto  -> AGESA uses CPUID-based default (DISABLED for 4700U)
    0x01 = Enable -> AGESA forces SMT ON for all CCXes
    0x02 = Disable -> AGESA forces SMT OFF

The 4700U (CPUID 0x00860601) is in AGESA's "SMT disabled" default group.
Auto therefore resolves to disabled.

Adjacent tokens (context):

    0x006c  val=0x00  (unknown)
    0x0076  val=0x00  CfgSMTControl = Auto -> Disabled
    0x0177  val=0x01  (unknown, val=1 = enabled for something)
    0x007b  val=0x03  (CCD count? = 3? or cluster mode = 3?)
    0x007d  val=0x00  (unknown)
    0x0084  val=0x00  Auto_token

---

## No APCB NVRAM Override Variable

Live machine EFI variables (all AMD-related):
    AMD_PBS_SETUP-a339d746...  (Platform Boot Settings -- NOT topology)
    AMD_RAID-fe26a894...        (RAID config -- irrelevant)
    AmdAcpiVar-79941ecd...      (ACPI table pointer -- irrelevant)
    AmdSetup-3a997502...        (CBS HII settings -- SMT absent, see BIOS_LAYER1_ANALYSIS.md)

NO APCB override NVRAM variable exists. The AmdApcbDxeV3 driver on the
X513IA does not expose an NVRAM-writable APCB override path. APCB can only
be changed by writing directly to SPI flash.

---

## The APCB Patch

To enable SMT, change ONE byte in each APCB copy (BIOS file offsets):

    PRIMARY APCB:
        BIOS file offset: 0x0029e021  (value byte of token 0x0076)
        Current byte:     0x00  (Auto -> Disabled)
        Target byte:      0x01  (Enable)
        Header checksum:  0x0029a810  (zero this after patching)

    MIRROR APCB:
        BIOS file offset: 0x006e6021  (value byte of token 0x0076)
        Current byte:     0x00
        Target byte:      0x01
        Header checksum:  0x006e2810  (zero this after patching)

After patching, the APCB CRC bytes for each token should ideally be updated.
However, Renoir AGESA (at least in this BIOS version) does not validate
per-token CRC at runtime -- it validates the APCB header checksum only.

The header checksum is at APCB_base+0x10 (4 bytes). Renoir AGESA accepts
checksum=0x00000000 as "skip validation" (confirmed in community testing).
The current header checksum value is 0x000000ae in both copies.

---

## Patch Script

```python
#!/usr/bin/env python3
# patch_apcb_smt.py -- patch APCB in X513IA BIOS to enable SMT
# WARNING: This modifies the BIOS binary. Use only on a verified copy.
# Requires external SPI clip to write back to flash.

import struct, sys, hashlib

BIOS_FILE = "X513IAAS.308"
OUT_FILE  = "X513IAAS.308.smt_patched"

# Offsets are into the full BIOS file (X513IAAS.308, 16,779,264 bytes)
# BIOS file offset = body.bin offset + 0x800 (capsule header)
APCB_SMT_OFFSETS = [
    0x0029e01f,   # primary APCB token start (BIOS file offset)
    0x006e601f,   # mirror APCB token start  (BIOS file offset)
]
# Header checksum field: APCB_base + 0x10 (4 bytes, zero to skip validation)
APCB_HDR_CKSUM = [
    0x0029a810,   # primary APCB header checksum (BIOS file offset)
    0x006e2810,   # mirror APCB header checksum  (BIOS file offset)
]
APCB_SIZES = [
    0x3a7c,       # primary
    0x3a7c,       # mirror
]
APCB_BASES = [
    0x0029a800,   # BIOS file offset
    0x006e2800,   # BIOS file offset
]

with open(BIOS_FILE, 'rb') as f:
    bios = bytearray(f.read())

print(f"BIOS size: {len(bios)} bytes")

for i, (tok_off, cksum_off, apcb_base, apcb_size) in enumerate(
        zip(APCB_SMT_OFFSETS, APCB_HDR_CKSUM, APCB_BASES, APCB_SIZES)):
    val_off = tok_off + 2  # value byte is 2 bytes into the 8-byte token entry
    old_val = bios[val_off]
    print(f"APCB[{i}] token 0x0076 at body[0x{tok_off:08x}]: value=0x{old_val:02x}")
    
    if old_val == 0x01:
        print(f"  Already set to Enable -- skipping")
        continue
    
    bios[val_off] = 0x01
    print(f"  Patched: 0x{old_val:02x} -> 0x01 (Enable)")
    
    # Recompute APCB header checksum
    # AMD APCB V3 header checksum: sum of all bytes in APCB, with checksum field
    # zeroed, must equal stored checksum (or AGESA accepts 0x00000000 as "skip")
    # Safest: zero the checksum field (AGESA on Renoir skips validation if 0)
    print(f"  Zeroing APCB header checksum at 0x{cksum_off:08x}")
    bios[cksum_off:cksum_off+4] = b'\x00\x00\x00\x00'

with open(OUT_FILE, 'wb') as f:
    f.write(bios)

print(f"\nPatched BIOS written to {OUT_FILE}")
print(f"SHA256: {hashlib.sha256(bios).hexdigest().upper()}")
print()
print("Next steps:")
print("1. Verify patch: python3 -c \"d=open('X513IAAS.308.smt_patched','rb').read(); print(hex(d[0x0029e021]), hex(d[0x006e6021]))\"  # should be 0x1 0x1")
print("2. Flash with external SPI clip (ch341a or similar)")
print("3. Reboot and check: cat /sys/devices/system/cpu/smt/control")
```

---

## Flash Write Path

The X513IA SPI flash is hardware write-protected:
    flashrom v1.6.0 reports: SpiAccessMacRomEn = 0 (write disabled)
    The BIOS lock is set by AGESA during POST via SMM SMI handler.

Options to write the patched BIOS:

### Option A: External SPI Clip (most reliable)
1. Power off laptop, remove battery
2. Locate SPI flash chip on motherboard (typically SOIC-8, near PCH)
   -- ASUS X513IA SPI chip: likely Winbond W25Q128 or ESMT F25L128
3. Attach CH341A programmer with SOIC-8 clip
4. Read chip first: `flashrom -p ch341a_spi -r original_backup.bin`
5. Verify SHA256 matches known-good BIOS
6. Write patched BIOS: `flashrom -p ch341a_spi -w X513IAAS.308.smt_patched`
7. Remove clip, reassemble, boot

### Option B: UEFI Shell flashrom (if write-protect can be bypassed)
Some ASUS BIOSes allow write from UEFI shell before SMM lock activates:
1. Boot to UEFI shell (USB with Shell.efi)
2. Run: `fpt.efi -f X513IAAS.308.smt_patched -y` (Intel FPT equivalent)
   -- AMD systems may use: `afudos.efi` or `AMIFlash.efi`
   -- ASUS provides `WinFlash` -- not available in shell
3. This may or may not bypass the SMM write lock on this platform

### Option C: Smokeless UMAF (test first -- no flash required)
If Smokeless UMAF exposes CfgSMTControl as a CBS option, it may be able to
set the APCB token override at runtime without SPI flash access.
This is the lowest-risk option and should be tried before any flash attempt.

---

## Summary

The SMT control mechanism on the X513IA is now fully mapped:

| Layer | Component | SMT Status | Notes |
|-------|-----------|------------|-------|
| Silicon | Die | PRESENT | Same die as 4800U |
| AGESA CBS default | CPUID table | DISABLED | 4700U SKU = no SMT |
| APCB token 0x0076 | SPI flash @ 0x0029e021 (BIOS file) | Auto (0x00) | Must be 0x01 |
| AmdSetup EFI var | NVRAM | NOT MAPPED | No SMT byte exposed |
| HII IFR | BIOS menu | ABSENT | ASUS removed option |
| OS kernel | smt/control | notsupported | Downstream of firmware |

The single byte change needed:
  BIOS file offset 0x0029e021: 0x00 -> 0x01  (primary)
  BIOS file offset 0x006e6021: 0x00 -> 0x01  (mirror)
  (body.bin offsets are 0x800 less: 0x0029d821 and 0x006e5821)

---

## References

- AMD APCB V3 format: internal AMD documentation (not public)
- Community APCB research: https://github.com/DavidS95/Smokeless_UMAF
- AMD Renoir CBS token IDs: reverse-engineered from multiple OEM BIOSes
- APCB token 0x0076 identified via CBS IFR cross-reference (community)
- flashrom SPI write protection: https://flashrom.org/Write_protection
