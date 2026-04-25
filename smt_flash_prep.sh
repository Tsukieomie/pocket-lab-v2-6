#!/usr/bin/env bash
# smt_flash_prep.sh — CH341A SPI flash procedure for X513IA SMT APCB patch
#
# This script:
#   1. Verifies the patched BIOS is ready (from patch_apcb_smt.py)
#   2. Checks flashrom + CH341A programmer availability
#   3. Reads the current SPI flash (backup)
#   4. Writes the patched BIOS
#
# Hardware required:
#   - CH341A programmer (USB)
#   - 1.8V level shifter / adapter board (CRITICAL — chip is 1.8V not 3.3V)
#   - SOIC-8 test clip
#   - Laptop powered off, battery removed
#
# Chip: Winbond W25Q128JW (1.8V, SOIC-8)
# flashrom chip ID: W25Q128JW_DTR or W25Q128JW
#
# Usage (read-only check):
#   bash smt_flash_prep.sh --check
#
# Usage (backup only):
#   bash smt_flash_prep.sh --backup
#
# Usage (full: backup + write patched BIOS):
#   bash smt_flash_prep.sh --flash

set -eu

BIOS_ORIG="X513IAAS.308"
BIOS_PATCHED="X513IAAS.308.smt_patched"
BACKUP_FILE="bios_backup_$(date +%Y%m%d_%H%M%S).bin"
PROGRAMMER="ch341a_spi"
CHIP="W25Q128JW"         # flashrom chip name for Winbond W25Q128JW 1.8V

# SHA256 of the extracted X513IAAS.308 ROM binary (not the ZIP)
EXPECTED_ORIG_SHA="329BB6CD3AACA7A5C8911F891E468BBD005813648626E6C4F782850EC2E45378"

MODE="${1:---check}"

echo "╔══════════════════════════════════════════════════════╗"
echo "║   CH341A SPI Flash Procedure — X513IA SMT Unlock    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Mode: $MODE"
echo "Programmer: $PROGRAMMER"
echo "Chip: $CHIP (Winbond W25Q128JW 1.8V)"
echo ""

# ── Prerequisite checks ─────────────────────────────────────
echo "=== Prerequisites ==="

# flashrom
if command -v flashrom >/dev/null 2>&1; then
  FLASHROM_VER=$(flashrom --version 2>&1 | head -1 || true)
  echo "  flashrom: $FLASHROM_VER ✓"
else
  echo "  flashrom: NOT FOUND"
  echo "  Install: sudo apt install flashrom"
  if [ "$MODE" != "--check" ]; then exit 1; fi
fi

# CH341A connected?
CH341_PRESENT=false
if lsusb 2>/dev/null | grep -qi "1a86:5512\|ch341\|CH341"; then
  echo "  CH341A USB: DETECTED ✓"
  CH341_PRESENT=true
elif [ "$MODE" = "--check" ]; then
  echo "  CH341A USB: NOT DETECTED (connect programmer via USB)"
else
  echo "  CH341A USB: NOT DETECTED — aborting"
  exit 1
fi

# Patched BIOS present?
if [ -f "$BIOS_PATCHED" ]; then
  PATCHED_SHA=$(sha256sum "$BIOS_PATCHED" | awk '{print toupper($1)}')
  echo "  Patched BIOS: $BIOS_PATCHED ✓"
  echo "    SHA256: $PATCHED_SHA"
  
  # Spot-check patch at known offsets
  python3 - "$BIOS_PATCHED" << 'PY'
import sys
d = open(sys.argv[1], 'rb').read()
pri = d[0x0029e021]
mir = d[0x006e6021]
pri_ck = int.from_bytes(d[0x0029a810:0x0029a814], 'little')
mir_ck = int.from_bytes(d[0x006e2810:0x006e2814], 'little')
print(f"    Primary token 0x0076:  0x{pri:02x} ({'Enable ✓' if pri==1 else 'WRONG - expected 0x01'})")
print(f"    Mirror token 0x0076:   0x{mir:02x} ({'Enable ✓' if mir==1 else 'WRONG - expected 0x01'})")
print(f"    Primary APCB cksum:    0x{pri_ck:08x} ({'zeroed ✓' if pri_ck==0 else 'NOT ZEROED - re-run patcher'})")
print(f"    Mirror APCB cksum:     0x{mir_ck:08x} ({'zeroed ✓' if mir_ck==0 else 'NOT ZEROED - re-run patcher'})")
if pri != 1 or mir != 1 or pri_ck != 0 or mir_ck != 0:
    print("  PATCH VERIFICATION FAILED — do not flash")
    sys.exit(1)
PY
  PATCHED_READY=true
else
  echo "  Patched BIOS: NOT FOUND ($BIOS_PATCHED)"
  echo "    Run: python3 patch_apcb_smt.py $BIOS_ORIG"
  PATCHED_READY=false
  if [ "$MODE" = "--flash" ]; then exit 1; fi
fi

echo ""

# ── Check mode: just print status and exit ──────────────────
if [ "$MODE" = "--check" ]; then
  echo "=== Hardware Setup Reminder ==="
  echo ""
  echo "  CRITICAL: X513IA SPI chip is 1.8V (Winbond W25Q128JW)"
  echo "  A standard CH341A runs at 3.3V and WILL DAMAGE the chip."
  echo "  You MUST use a 1.8V level shifter adapter board."
  echo ""
  echo "  Required hardware:"
  echo "    - CH341A programmer (USB)"
  echo "    - 1.8V adapter board for CH341A (replaces the ZIF/SOIC socket)"
  echo "    - SOIC-8 test clip"
  echo ""
  echo "  Physical setup:"
  echo "    1. Power off X513IA completely"
  echo "    2. Remove AC adapter"
  echo "    3. Remove battery (unscrew back panel)"
  echo "    4. Locate SPI flash chip (SOIC-8 near BIOS region)"
  echo "       Look for: W25Q128JW markings, near PCH / EC area"
  echo "    5. Attach SOIC-8 clip to chip"
  echo "    6. Connect CH341A + 1.8V adapter"
  echo "    7. Connect CH341A to laptop via USB"
  echo "    8. Run: bash smt_flash_prep.sh --backup"
  echo ""
  echo "  Chip location reference:"
  echo "    Board: ASUS VivoBook X513IA (M513IA)"
  echo "    Photos: search 'X513IA motherboard SPI flash' on BIOS-MODS forums"
  echo ""
  exit 0
fi

# ── Backup mode ─────────────────────────────────────────────
if [ "$MODE" = "--backup" ] || [ "$MODE" = "--flash" ]; then
  echo "=== Reading SPI Flash (backup) ==="
  echo "Reading chip 3 times to verify consistency..."
  
  for i in 1 2 3; do
    echo "  Read $i/3..."
    sudo flashrom -p "$PROGRAMMER" -c "$CHIP" -r "/tmp/bios_read_${i}.bin" 2>&1 \
      | grep -v "^Found\|^No EEPROM\|^Calibrating\|^SFDP\|^JEDEC" || true
  done
  
  # Compare all three reads
  SHA1=$(sha256sum /tmp/bios_read_1.bin | awk '{print $1}')
  SHA2=$(sha256sum /tmp/bios_read_2.bin | awk '{print $1}')
  SHA3=$(sha256sum /tmp/bios_read_3.bin | awk '{print $1}')
  
  if [ "$SHA1" = "$SHA2" ] && [ "$SHA2" = "$SHA3" ]; then
    echo "  All 3 reads consistent ✓"
    cp /tmp/bios_read_1.bin "$BACKUP_FILE"
    BACKUP_SHA=$(sha256sum "$BACKUP_FILE" | awk '{print toupper($1)}')
    echo "  Backup saved: $BACKUP_FILE"
    echo "  Backup SHA256: $BACKUP_SHA"
    echo "$BACKUP_SHA  $BACKUP_FILE" > "$BACKUP_FILE.sha256"
    
    if [ "$BACKUP_SHA" = "$EXPECTED_ORIG_SHA" ]; then
      echo "  Matches known-good X513IAAS.308 SHA256 ✓"
    else
      echo "  SHA256 does NOT match known-good X513IAAS.308"
      echo "  This may be a different BIOS version — VERIFY before proceeding"
      echo "  Expected: $EXPECTED_ORIG_SHA"
      echo "  Got:      $BACKUP_SHA"
    fi
  else
    echo "  ERROR: Reads are inconsistent!"
    echo "    Read 1: $SHA1"
    echo "    Read 2: $SHA2"
    echo "    Read 3: $SHA3"
    echo "  Check clip connection and retry."
    exit 1
  fi
  
  rm -f /tmp/bios_read_1.bin /tmp/bios_read_2.bin /tmp/bios_read_3.bin
  echo ""
fi

# ── Flash mode ──────────────────────────────────────────────
if [ "$MODE" = "--flash" ]; then
  if [ "$PATCHED_READY" != "true" ]; then
    echo "ERROR: Patched BIOS not ready — cannot flash"
    exit 1
  fi
  
  echo "=== Writing Patched BIOS ==="
  echo ""
  echo "  About to write: $BIOS_PATCHED"
  echo "  To chip:        $CHIP via $PROGRAMMER"
  echo ""
  echo "  This will take 2-5 minutes. DO NOT disconnect anything."
  echo ""
  echo "Press ENTER to begin flashing or Ctrl+C to abort..."
  read -r _
  
  echo "  Flashing..."
  sudo flashrom -p "$PROGRAMMER" -c "$CHIP" -w "$BIOS_PATCHED" 2>&1
  
  echo ""
  echo "  Verifying write..."
  sudo flashrom -p "$PROGRAMMER" -c "$CHIP" -v "$BIOS_PATCHED" 2>&1
  
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  FLASH COMPLETE                                     ║"
  echo "║                                                     ║"
  echo "║  1. Remove SOIC-8 clip                             ║"
  echo "║  2. Reassemble laptop (battery + back panel)       ║"
  echo "║  3. Boot and verify:                               ║"
  echo "║       bash smt_verify.sh                           ║"
  echo "║                                                     ║"
  echo "║  If machine does not boot: re-attach clip, flash   ║"
  echo "║  original backup ($BACKUP_FILE)                     ║"
  echo "║    flashrom -p ch341a_spi -c W25Q128JW -w $BACKUP_FILE  ║"
  echo "╚══════════════════════════════════════════════════════╝"
fi
