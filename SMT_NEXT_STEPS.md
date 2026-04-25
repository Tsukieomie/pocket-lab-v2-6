# SMT Unlock — Automated Next Steps
## Ryzen 7 4700U / ASUS X513IA

Generated: 2026-04-25  
Status of automation: **COMPLETE** — patched BIOS ready, scripts written

> **2026-04-25 PM update:** UMAF ruled out (kernel panic on Renoir). flashrom blocked (SPI protection). fwupd capsule blocked (unsigned, OsIndications bits 2+3 = False). **Active path: `setup_var_cv` UEFI shell → write AmdSetup offset for SMT=Enable.** See [SETUP_VAR_SMT.md](SETUP_VAR_SMT.md) for full details and IFR extraction plan.

---

## Summary of What Was Done Automatically

| Step | Status | Output |
|------|--------|--------|
| Download X513IAAS.308 from ASUS CDN | ✓ Done | `X513IAAS.308` (329BB6...  SHA256 verified) |
| Fix APCB offset bug in patcher | ✓ Done | Offsets corrected to BIOS-file coordinates |
| Patch APCB token 0x0076 → 0x01 | ✓ Done | `X513IAAS.308.smt_patched` (86EB87... SHA256) |
| Build UMAF USB prep script | ✓ Done | `smt_umaf_prep.sh` |
| Build CH341A flash script | ✓ Done | `smt_flash_prep.sh` |
| Build post-flash verification | ✓ Done | `smt_verify.sh` |
| Build BIOS fetch script | ✓ Done | `smt_fetch_bios.sh` |

---

## What You Need to Do (Priority Order)

---

## PATH 1 — Smokeless UMAF (Try First, No Hardware Required)

**Risk: ZERO. If it doesn't work, nothing bad happens.**

### Step 1: Prepare USB

```bash
# Run on the X513IA (Linux) to prep a USB drive
# Replace /dev/sdX1 with your USB partition
bash smt_umaf_prep.sh

# Then copy the EFI to USB:
sudo mount /dev/sdX1 /mnt
sudo mkdir -p /mnt/EFI/Boot
sudo cp umaf_prep/bootx64.efi /mnt/EFI/Boot/bootx64.efi
sudo umount /mnt
```

### Step 2: Boot UMAF

1. Insert USB into X513IA
2. Power on, press **F2** at ASUS splash → BIOS Setup  
   OR press **F8** → Boot Menu → select USB
3. Navigate: **Device Manager → AMD CBS → CPU Common Options → Performance → CCD/Core/Thread Enablement**
4. Find **SMT Control** → change from `Auto` to **`Enable`**
5. Press **F10** → Save & Exit

### Step 3: Verify

```bash
bash smt_verify.sh
# or manually:
cat /sys/devices/system/cpu/smt/control   # expect: on
nproc                                      # expect: 16
lscpu | grep Thread                        # expect: Thread(s) per core: 2
```

### UMAF outcome decision

| Result | Action |
|--------|--------|
| `smt/control = on`, nproc = 16 | **Done — SMT unlocked via UMAF** |
| SMT Control not in UMAF menu | AGESA compiled without SMT option → go to Path 2 |
| Setting present but no change after reboot | APCB not writable from UMAF on this board → go to Path 2 |

---

## PATH 2 — SPI Flash Patch (Definitive, Requires CH341A)

**The patched BIOS is already built and verified. You just need the hardware.**

### Hardware shopping list

| Item | Notes | ~Cost |
|------|-------|-------|
| CH341A programmer | USB SPI programmer | $5–10 |
| **1.8V adapter board for CH341A** | **CRITICAL — chip is 1.8V. 3.3V will damage it.** Search "CH341A 1.8V adapter" | $3–8 |
| SOIC-8 test clip | In-circuit, no soldering needed | $5–10 (often bundled with CH341A) |

**Search terms:** "CH341A 1.8V level shifter" or "CH341A 1.8V adapter board"

### SPI chip details

```
Chip:      Winbond W25Q128JW
Voltage:   1.8V  ← CRITICAL, do NOT use 3.3V
Package:   SOIC-8
flashrom:  -c W25Q128JW
Location:  SOIC-8 near BIOS/PCH region on motherboard
```

### Flashing procedure

```bash
# Step 1: Check prerequisites
bash smt_flash_prep.sh --check

# Step 2: Power off laptop, remove battery, attach SOIC-8 clip + CH341A + 1.8V adapter
# Connect CH341A to another computer via USB

# Step 3: Read + backup (verify clip is good)
bash smt_flash_prep.sh --backup
# This reads 3x, compares, saves bios_backup_TIMESTAMP.bin
# Keep this file on a separate drive!

# Step 4: Flash patched BIOS
bash smt_flash_prep.sh --flash
# Will ask for confirmation before writing

# Step 5: Remove clip, reassemble, boot
# Step 6: Verify on the machine
bash smt_verify.sh
```

### Manual flashrom commands (if script not available on programmer machine)

```bash
# Check chip is detected
flashrom -p ch341a_spi

# Backup (do 3x, compare SHA256)
flashrom -p ch341a_spi -c W25Q128JW -r bios_backup.bin

# Flash
flashrom -p ch341a_spi -c W25Q128JW -w X513IAAS.308.smt_patched

# Verify
flashrom -p ch341a_spi -c W25Q128JW -v X513IAAS.308.smt_patched
```

### Recovery (if machine doesn't boot after flash)

```bash
# Re-attach clip, flash original backup
flashrom -p ch341a_spi -c W25Q128JW -w bios_backup_TIMESTAMP.bin
```

---

## Patch Verification (Sanity Check Before Flashing)

```bash
python3 -c "
d = open('X513IAAS.308.smt_patched','rb').read()
print('Primary token 0x0076:', hex(d[0x0029e021]))   # expect: 0x1
print('Mirror token 0x0076: ', hex(d[0x006e6021]))   # expect: 0x1
import struct
pri_ck = struct.unpack_from('<I', d, 0x0029a810)[0]
mir_ck = struct.unpack_from('<I', d, 0x006e2810)[0]
print('Primary APCB cksum:  ', hex(pri_ck))           # expect: 0x0 (zeroed)
print('Mirror APCB cksum:   ', hex(mir_ck))           # expect: 0x0 (zeroed)
"
```

Expected output:
```
Primary token 0x0076: 0x1
Mirror token 0x0076:  0x1
Primary APCB cksum:   0x0
Mirror APCB cksum:    0x0
```

---

## File Checksums

| File | SHA256 |
|------|--------|
| `X513IAAS.308` (original ROM) | `329BB6CD3AACA7A5C8911F891E468BBD005813648626E6C4F782850EC2E45378` |
| `X513IAAS308.zip` (ASUS CDN) | `D67902467FD84FF2F8D107CB7FF9551AB48F00379319AC12D7FB4560CA527ACA` |
| `X513IAAS.308.smt_patched` | `86EB879F53D56142984E9683BA47B633AE219B67A86B66675C59C75483D0F57F` |

---

## EntrySign Mitigation (Do This Now, Regardless of SMT)

The machine runs microcode `0x860010d` which is vulnerable to CVE-2024-56161. Apply the OS-level partial mitigation immediately:

```bash
sudo apt install amd64-microcode
sudo update-initramfs -u
sudo reboot
cat /proc/cpuinfo | grep microcode
# Expect: 0x860010f (OS-patched)
```

Note: This only partially mitigates EntrySign — it does not fix the BIOS-level signature verification flaw. Full fix requires ASUS to ship a BIOS update with RenoirPI-FP6 1.0.0.Eb, which they have not done as of 2026-04-25.

---

## PATH 3 — Coreboot (Long-term, Most Definitive)

- Build coreboot with Renoir AGESA blob and SMT enabled
- Reference board: [Google Zork (coreboot)](https://doc.coreboot.org/mainboard/google/zork.html)
- Requires board-specific ACPI tables for X513IA (not upstream)
- Requires external SPI flash for write-back (same CH341A from Path 2)
- Skip for now unless Path 2 fails due to SPI write protection at hardware level

---

## Scripts Reference

| Script | Purpose | Usage |
|--------|---------|-------|
| `smt_fetch_bios.sh` | Download + verify X513IAAS.308 from ASUS CDN | `bash smt_fetch_bios.sh` |
| `patch_apcb_smt.py` | Patch APCB token 0x0076 → Enable | `python3 patch_apcb_smt.py X513IAAS.308` |
| `smt_umaf_prep.sh` | Download UMAF EFI + USB instructions | `bash smt_umaf_prep.sh [--usb /dev/sdX1]` |
| `smt_flash_prep.sh` | CH341A backup + flash procedure | `bash smt_flash_prep.sh [--check\|--backup\|--flash]` |
| `smt_verify.sh` | Verify SMT unlock after reboot | `bash smt_verify.sh` |
| `pl_ensure_up.sh` | Bore tunnel + fs-bridge keep-alive | `bash pl_ensure_up.sh` |
