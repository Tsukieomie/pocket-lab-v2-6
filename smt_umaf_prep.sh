#!/usr/bin/env bash
# smt_umaf_prep.sh — Prepare Smokeless UMAF USB for X513IA SMT unlock attempt
#
# Downloads the latest Smokeless_UMAF release EFI binary and writes instructions
# for creating a bootable USB. Also generates a verification checklist.
#
# Smokeless UMAF: https://github.com/DavidS95/Smokeless_UMAF
# Renoir (Family 17h Model 60h) is explicitly listed as supported.
#
# Usage:
#   bash smt_umaf_prep.sh [--usb /dev/sdX]
#
# With --usb: formats the USB and copies the EFI binary automatically.
# Without --usb: downloads the EFI and prints manual instructions.
#
# WARNING: --usb will ERASE the target device. Double-check the device path.

set -eu

USB_DEVICE="${USB_DEVICE:-}"
UMAF_REPO="DavidS95/Smokeless_UMAF"
EFI_DEST_PATH="EFI/Boot/bootx64.efi"
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/umaf_prep"

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --usb) USB_DEVICE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Smokeless UMAF USB Prep — X513IA SMT Unlock       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

mkdir -p "$OUT_DIR"

# ── Fetch latest release from GitHub ───────────────────────
echo "[umaf] Fetching latest Smokeless_UMAF release info..."

RELEASE_JSON=$(curl -fsSL \
  "https://api.github.com/repos/${UMAF_REPO}/releases/latest" 2>/dev/null || echo "{}")

TAG=$(echo "$RELEASE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tag_name','unknown'))" 2>/dev/null || echo "unknown")
echo "[umaf] Latest release: $TAG"

# Find the EFI asset URL
EFI_URL=$(echo "$RELEASE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assets = d.get('assets', [])
for a in assets:
    name = a.get('name','').lower()
    if name.endswith('.efi') or 'umaf' in name or 'bootx64' in name:
        print(a['browser_download_url'])
        break
" 2>/dev/null || echo "")

# Fallback: try zip asset
if [ -z "$EFI_URL" ]; then
  ZIP_URL=$(echo "$RELEASE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for a in d.get('assets', []):
    name = a.get('name','').lower()
    if name.endswith('.zip'):
        print(a['browser_download_url'])
        break
" 2>/dev/null || echo "")
  if [ -n "$ZIP_URL" ]; then
    echo "[umaf] Downloading ZIP: $ZIP_URL"
    curl -fsSL -L --max-time 120 --retry 3 -o /tmp/umaf.zip "$ZIP_URL"
    unzip -o /tmp/umaf.zip -d /tmp/umaf_extract/ 2>/dev/null
    FOUND_EFI=$(find /tmp/umaf_extract/ -iname "*.efi" | head -1 || true)
    if [ -n "$FOUND_EFI" ]; then
      cp "$FOUND_EFI" "$OUT_DIR/bootx64.efi"
      echo "[umaf] EFI extracted: $OUT_DIR/bootx64.efi"
    fi
    rm -rf /tmp/umaf.zip /tmp/umaf_extract/
  fi
elif [ -n "$EFI_URL" ]; then
  echo "[umaf] Downloading EFI: $EFI_URL"
  curl -fsSL -L --max-time 120 --retry 3 -o "$OUT_DIR/bootx64.efi" "$EFI_URL"
  echo "[umaf] EFI downloaded: $OUT_DIR/bootx64.efi"
fi

# ── Report if EFI is ready ──────────────────────────────────
if [ ! -f "$OUT_DIR/bootx64.efi" ]; then
  echo "[umaf] WARNING: Could not download EFI automatically."
  echo "[umaf] Manual download:"
  echo "  https://github.com/DavidS95/Smokeless_UMAF/releases/latest"
  echo "  Download the .efi or .zip, place bootx64.efi at: $OUT_DIR/"
  EFI_READY=false
else
  EFI_SIZE=$(ls -lh "$OUT_DIR/bootx64.efi" | awk '{print $5}')
  EFI_SHA=$(sha256sum "$OUT_DIR/bootx64.efi" | awk '{print $1}')
  echo "[umaf] EFI ready — size: $EFI_SIZE  sha256: ${EFI_SHA:0:16}..."
  EFI_READY=true
fi

# ── Write to USB if device specified ───────────────────────
if [ -n "$USB_DEVICE" ] && [ "$EFI_READY" = true ]; then
  echo ""
  echo "[umaf] USB device specified: $USB_DEVICE"
  echo "[umaf] WARNING: This will ERASE $USB_DEVICE"
  echo ""
  
  # Safety check
  if ! lsblk "$USB_DEVICE" >/dev/null 2>&1; then
    echo "[umaf] ERROR: Device $USB_DEVICE not found"
    exit 1
  fi
  
  echo "Press ENTER to continue or Ctrl+C to abort..."
  read -r _
  
  echo "[umaf] Formatting $USB_DEVICE as FAT32..."
  sudo mkfs.vfat -F 32 -n "UMAF" "$USB_DEVICE"
  
  MOUNT_POINT="/tmp/umaf_usb"
  mkdir -p "$MOUNT_POINT"
  sudo mount "$USB_DEVICE" "$MOUNT_POINT"
  
  sudo mkdir -p "$MOUNT_POINT/EFI/Boot"
  sudo cp "$OUT_DIR/bootx64.efi" "$MOUNT_POINT/EFI/Boot/bootx64.efi"
  
  sync
  sudo umount "$MOUNT_POINT"
  rmdir "$MOUNT_POINT"
  
  echo "[umaf] USB prepared at $USB_DEVICE"
fi

# ── Print manual USB instructions ──────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  USB SETUP (manual)                                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "1. Format a USB drive as FAT32"
echo "2. Create directory: /EFI/Boot/ on the USB"
echo "3. Copy EFI file:"
echo "   Source:  $OUT_DIR/bootx64.efi"
echo "   Dest:    /EFI/Boot/bootx64.efi"
echo ""
echo "   Quick copy (Linux, replace sdX1 with your USB partition):"
echo "   sudo mount /dev/sdX1 /mnt && sudo mkdir -p /mnt/EFI/Boot"
echo "   sudo cp $OUT_DIR/bootx64.efi /mnt/EFI/Boot/"
echo "   sudo umount /mnt"
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  BOOT + NAVIGATION SEQUENCE                         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "1. Hold F2 at ASUS splash screen -> enter BIOS Setup"
echo "2. Go to: Boot -> Boot Override -> [your USB drive]"
echo "   OR: press F8 at ASUS splash for boot menu -> select USB"
echo "3. UMAF will load — navigate with arrow keys + Enter"
echo "4. Path: Device Manager"
echo "         -> AMD CBS"
echo "         -> CPU Common Options"
echo "         -> Performance"
echo "         -> CCD/Core/Thread Enablement"
echo "         -> SMT Control"
echo "            [ ] Auto   <- currently selected"
echo "            [ ] Enable <- SELECT THIS"
echo "            [ ] Disable"
echo "5. Press F10 -> Save & Exit"
echo "6. Machine reboots normally"
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  VERIFICATION (run after reboot)                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  cat /sys/devices/system/cpu/smt/control"
echo "  # Expected: 'on' or 'forceoff' (either means SMT was enabled in BIOS)"
echo "  # Still 'notsupported' = UMAF did not expose SMT control (go to SPI path)"
echo ""
echo "  lscpu | grep -E 'Thread|Core|Socket'"
echo "  # Expected: Thread(s) per core: 2  Core(s) per socket: 8  -> 16 threads"
echo ""
echo "  nproc"
echo "  # Expected: 16"
echo ""

# ── Write a reusable verification script ────────────────────
cat > "$(dirname "${BASH_SOURCE[0]}")/smt_verify.sh" << 'VERIFY'
#!/usr/bin/env bash
# smt_verify.sh — Verify SMT unlock status on Ryzen 7 4700U
# Run after UMAF or BIOS flash attempt
set -eu

echo "=== SMT Verification — $(date) ==="
echo ""

SMT_CTL=$(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo "unknown")
echo "smt/control: $SMT_CTL"

case "$SMT_CTL" in
  on)
    echo "STATUS: SMT ENABLED AND ACTIVE ✓"
    echo "  -> 16 threads should be visible"
    ;;
  forceoff)
    echo "STATUS: SMT ENABLED IN BIOS but forced off by kernel cmdline"
    echo "  -> Remove 'nosmt' or 'mitigations=off' from kernel params if unintentional"
    ;;
  notsupported)
    echo "STATUS: SMT NOT ENABLED — BIOS still reports single-thread"
    echo "  -> UMAF did not expose/apply SMT control, or settings not saved"
    echo "  -> Proceed to SPI flash path (CH341A + patch_apcb_smt.py)"
    ;;
  *)
    echo "STATUS: Unknown smt/control value: $SMT_CTL"
    ;;
esac

echo ""
echo "--- CPU topology ---"
lscpu | grep -E "^Thread|^Core\(s\)|^Socket|^CPU\(s\)" || true

echo ""
echo "--- Thread count ---"
echo "nproc: $(nproc)"

echo ""
echo "--- Microcode version ---"
grep -m1 microcode /proc/cpuinfo || true
echo "  (Fixed version is 0x860010f — current machine had 0x860010d)"

echo ""
echo "--- Thread siblings (first 2 CPUs) ---"
for cpu in 0 1; do
  SIB=$(cat /sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list 2>/dev/null || echo "N/A")
  echo "  CPU ${cpu} thread siblings: $SIB"
done
VERIFY

chmod +x "$(dirname "${BASH_SOURCE[0]}")/smt_verify.sh"
echo "[umaf] Also wrote: smt_verify.sh (run on machine after reboot)"
echo ""
echo "[umaf] DONE"
