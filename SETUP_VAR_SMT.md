# SMT Unlock — setup_var_cv UEFI Shell Path
## ASUS X513IA / Ryzen 7 4700U (Renoir)

**Session:** 2026-04-25  
**Status:** In progress — IFR extraction needed to find AmdSetup SMT offset  
**Chosen path:** `setup_var_cv` writes directly to `AmdSetup` EFI NVRAM variable

---

## Why This Path

All other paths have been ruled out or exhausted:

| Path | Status | Reason |
|------|--------|--------|
| Smokeless UMAF | ❌ Ruled out | Causes kernel panic on Renoir (Family 17h 60h) CPUs |
| flashrom internal | ❌ Blocked | `SpiAccessMacRomEn` / `SpiHostAccessRomEn` protection active |
| fwupd capsule | ❌ Blocked | Patched BIOS not signed with ASUS keys; OsIndications bits 2+3 = False (capsule delivery not supported) |
| WMI / asus-armoury | ❌ Not exposed | Only exposes `pending_reboot`, no CPU config attributes |
| CH341A SPI flash | ⚠️ Standby | Valid path but requires hardware; skip for now |
| **setup_var_cv** | ✅ Active path | AmdSetup NVRAM variable confirmed present and writable from UEFI shell |

---

## Key Findings

### AmdSetup EFI Variable
```
Name:   AmdSetup
GUID:   3A997502-647A-4C82-998E-52EF9486A247
Size:   1375 bytes (4 EFI attributes + 1371 data bytes)
Match:  Win-Raid/BIOS-mods community IFR confirms this GUID for
        VarStore: VarStoreId 0x5000, Size: 0x138, Name: AmdSetup
```

Read variable on device:
```bash
efivar -n 3A997502-647A-4C82-998E-52EF9486A247-AmdSetup | xxd
# or
python3 -c "import os; d=open('/sys/firmware/efi/efivars/AmdSetup-3A997502-647A-4C82-998E-52EF9486A247','rb').read(); print(d.hex()); print('len:', len(d))"
```

### SMT Control Token
- APCB token: `0x0076`
- Values: `0x00` = Auto, `0x01` = Enable, `0x02` = Disable
- Current state: CPUID reports 1 thread/core — BIOS AGESA presenting HT disabled at firmware topology level
- Kernel mitigations are NOT the cause (confirmed by CPUID leaf `0x8000001E`, EBX bits [15:8] = 0)

### BIOS Version
```
Version:  X513IA.308  (dated 2021-10-26)
Download: https://dlcdnets.asus.com/pub/ASUS/nb/Image/BIOS/103042/X513IAAS308.zip
ROM SHA256: 329BB6CD3AACA7A5C8911F891E468BBD005813648626E6C4F782850EC2E45378
```
No newer ASUS BIOS available as of 2026-04-25.

### EFI Boot Environment
```
SuppressIFPatcher.efi  — already installed in EFI boot chain (prior session)
                         patches BIOS IFR at runtime to un-hide suppressed AMD CBS menus
UiApp.efi              — UEFI shell / setup browser present
BOOTX64.efi.asus-orig  — original ASUS shim backed up
```

### BIOS fwupd entry
```
Device ID:  f68381c92adae0543937c47d1aa8fbccea579b97
Version:    776
Flags:      Updatable, CryptoHashVerification, UpdateViaUEFINVRAM
```

---

## The Plan: setup_var_cv

`setup_var_cv` is a UEFI shell tool that writes to EFI NVRAM variables by offset.

### Step 1 — Find the VarOffset for SMT Control

Need IFR (Internal Form Representation) extraction from the BIOS ROM to find the exact byte offset of SMT Control inside the `AmdSetup` variable.

**Method A — ifrextract on Linux (preferred):**
```bash
# Extract setup PE32 image from BIOS ROM using UEFIExtract
git clone https://github.com/LongSoft/UEFITool
cd UEFITool && cmake . && make
./UEFIExtract X513IAAS.308 # produces X513IAAS.308.dump/

# Find the Setup module (AMI setup PE32)
find X513IAAS.308.dump -name "*.ui" | xargs grep -l -i "setup" 2>/dev/null
find X513IAAS.308.dump -name "body.bin" | head -20

# Run ifrextract on the Setup PE32 body
pip3 install ifrextract  # or: git clone https://github.com/LongSoft/IFRExtractor-RS
ifrextract body.bin setup_ifr.txt

# Search for SMT
grep -i "smt\|thread\|0x0076" setup_ifr.txt
```

**Method B — Online IFR databases:**
- Search BIOS-mods.com for `X513IA` + `AmdSetup` IFR dump
- Search Win-Raid forum for `X513IA` setup var offsets
- The VarStore GUID `3A997502-647A-4C82-998E-52EF9486A247` is confirmed — any IFR dump with this GUID applies

**Method C — Brute force scan of AmdSetup variable:**
```bash
# On the device — compare AmdSetup before/after toggling a known setting in BIOS
# (e.g. toggle a visible setting, note changed byte offset)
python3 - <<'PY'
d = open('/sys/firmware/efi/efivars/AmdSetup-3A997502-647A-4C82-998E-52EF9486A247','rb').read()
print(f"Size: {len(d)} bytes")
print(f"Attrs: {d[:4].hex()}")
print(f"Data hex:")
for i in range(0, len(d[4:]), 16):
    chunk = d[4+i:4+i+16]
    print(f"  {i:04x}: {chunk.hex()}")
PY
```

### Step 2 — Write SMT=Enable via setup_var_cv

Once the offset is known (call it `0xOFFS`):

```sh
# Boot to UEFI shell (USB with shell.efi, or use existing UiApp.efi)
# In UEFI shell:
setup_var_cv AmdSetup 0xOFFS 0x1 0x01
# Arguments: <VarName> <Offset> <Width> <Value>
# Width=0x1 (1 byte), Value=0x01 (SMT Enable)
```

Download setup_var_cv:
- https://github.com/datasone/setup_var.efi/releases
- Binary: `setup_var_cv.efi`

### Step 3 — Verify

After reboot:
```bash
cat /sys/devices/system/cpu/smt/control   # expect: on
nproc                                      # expect: 8 (4700U has 8 threads)
lscpu | grep -E "Thread|Core|Socket"
grep -c ^processor /proc/cpuinfo          # expect: 8
```

### Alternative: Direct efivar write from Linux (no reboot needed)

If offset is confirmed, can attempt direct write from running OS:
```bash
# CAUTION: wrong offset can corrupt BIOS settings
# Make a backup first:
cp /sys/firmware/efi/efivars/AmdSetup-3A997502-647A-4C82-998E-52EF9486A247 /tmp/AmdSetup.bak

# Write single byte at offset (4 bytes attrs + offset into data):
python3 - <<'PY'
import struct, os, shutil

EFIVAR = '/sys/firmware/efi/efivars/AmdSetup-3A997502-647A-4C82-998E-52EF9486A247'
OFFSET = None  # <-- fill in from IFR extraction
SMT_ENABLE = 0x01

d = bytearray(open(EFIVAR, 'rb').read())
print(f"Current byte at offset {OFFSET+4}: {d[OFFSET+4]:#04x}")
# d[OFFSET+4] = SMT_ENABLE
# open(EFIVAR, 'wb').write(bytes(d))
# print("Written. Reboot to apply.")
PY
```

---

## IFR Extraction Status

Session 2026-04-25 (morning): BIOS ROM downloaded, IFR extraction started but session ended before offset was identified.

**TODO:**
- [ ] Run UEFIExtract on `X513IAAS.308` to dump firmware volumes
- [ ] Find Setup PE32 module (contains AMD CBS IFR)
- [ ] Run ifrextract / IFRExtractor on Setup PE32 body
- [ ] Grep output for `SMT`, `Thread`, `0x0076`
- [ ] Record VarOffset → update this doc
- [ ] Deploy `setup_var_cv.efi` to EFI partition alongside existing `SuppressIFPatcher.efi`
- [ ] Boot UEFI shell, run `setup_var_cv AmdSetup <offset> 0x1 0x01`
- [ ] Reboot, verify `nproc` = 8

---

## Community References for AmdSetup Offsets

| Resource | URL |
|----------|-----|
| Win-Raid AmdSetup guide | https://winraid.level1techs.com/t/guide-how-to-patch-ami-uefi-bios/30627 |
| BIOS-mods X513IA thread | https://www.bios-mods.com/forum/ (search X513IA) |
| setup_var.efi releases | https://github.com/datasone/setup_var.efi/releases |
| IFRExtractor-RS | https://github.com/LongSoft/IFRExtractor-RS |
| UEFITool NE | https://github.com/LongSoft/UEFITool/releases |
| AMD CBS VarStore GUID | `3A997502-647A-4C82-998E-52EF9486A247` (confirmed on X513IA) |

---

## Session Log

| Date | Finding |
|------|---------|
| 2026-04-25 AM | CPUID confirms HT disabled at firmware level (not kernel mitigation) |
| 2026-04-25 AM | AmdSetup EFI var confirmed: GUID `3A997502...`, 1375 bytes |
| 2026-04-25 AM | UMAF ruled out: kernel panic on Renoir |
| 2026-04-25 AM | flashrom blocked: SpiAccessMacRomEn active |
| 2026-04-25 AM | fwupd capsule blocked: unsigned + OsIndications bits 2/3 = False |
| 2026-04-25 AM | SuppressIFPatcher.efi confirmed in EFI boot chain |
| 2026-04-25 AM | BIOS ROM downloaded: X513IAAS.308 SHA256 verified |
| 2026-04-25 AM | IFR extraction started, session ended before offset found |
| 2026-04-25 PM | Findings saved to repo; IFR extraction is next step |
