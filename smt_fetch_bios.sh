#!/usr/bin/env bash
# smt_fetch_bios.sh — Download and verify ASUS X513IA BIOS for SMT patching
#
# Downloads X513IAAS.308 from ASUS, verifies SHA256, and confirms it is
# ready for patch_apcb_smt.py.
#
# Usage:
#   bash smt_fetch_bios.sh [--output-dir /path/to/dir]
#
# Output:
#   ./X513IAAS.308         (verified BIOS binary)
#   ./X513IAAS.308.sha256  (checksum record)
#
# WARNING: This BIOS binary is for the ASUS VivoBook X513IA only.
#          Do NOT flash on any other machine.

set -eu

# SHA256 of the extracted X513IAAS.308 ROM binary (not the ZIP wrapper)
# ZIP SHA256 (X513IAAS308.zip): D67902467FD84FF2F8D107CB7FF9551AB48F00379319AC12D7FB4560CA527ACA
EXPECTED_SHA256="329BB6CD3AACA7A5C8911F891E468BBD005813648626E6C4F782850EC2E45378"
BIOS_FILENAME="X513IAAS.308"
OUT_DIR="${1:-$(pwd)}"

# Known ASUS CDN URL patterns for X513IA BIOS 308
# ASUS serves BIOSes as ZIP files containing the capsule binary
BIOS_ZIP_URLS=(
  "https://dlcdnets.asus.com/pub/ASUS/nb/Image/BIOS/103042/X513IAAS308.zip"
  "https://dlcdnets.asus.com/pub/ASUS/nb/X513IA/X513IAAS308.zip"
  "https://dlcdnets.asus.com/pub/ASUS/nb/VivoBook_ASUSLaptop/X513IA/X513IAAS308.zip"
)

echo "╔══════════════════════════════════════════════════════╗"
echo "║   X513IA BIOS Fetcher — SMT Unlock Prep             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Target: $BIOS_FILENAME"
echo "Expected SHA256: $EXPECTED_SHA256"
echo "Output dir: $OUT_DIR"
echo ""

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

# ── Check if already present and verified ───────────────────
if [ -f "$BIOS_FILENAME" ]; then
  echo "[fetch] $BIOS_FILENAME already exists — verifying..."
  ACTUAL=$(sha256sum "$BIOS_FILENAME" | awk '{print toupper($1)}')
  if [ "$ACTUAL" = "$EXPECTED_SHA256" ]; then
    echo "[fetch] SHA256 OK — already good, nothing to do."
    echo "[fetch] File: $OUT_DIR/$BIOS_FILENAME"
    exit 0
  else
    echo "[fetch] SHA256 MISMATCH — re-downloading (got $ACTUAL)"
    rm -f "$BIOS_FILENAME"
  fi
fi

# ── Try downloading ZIP from each CDN URL ───────────────────
DOWNLOADED=false
for URL in "${BIOS_ZIP_URLS[@]}"; do
  echo "[fetch] Trying: $URL"
  if curl -fsSL --max-time 120 --retry 3 -o /tmp/bios_download.zip "$URL" 2>/dev/null; then
    echo "[fetch] Download succeeded — extracting..."
    # Extract the capsule binary from ZIP
    EXTRACTED=$(unzip -l /tmp/bios_download.zip 2>/dev/null \
      | grep -i "X513IAAS\.\|\.308\|\.cap\|\.bin" \
      | grep -v "/" \
      | awk '{print $NF}' | head -1 || true)
    if [ -n "$EXTRACTED" ]; then
      unzip -o /tmp/bios_download.zip "$EXTRACTED" -d /tmp/bios_extract/ 2>/dev/null
      cp "/tmp/bios_extract/$EXTRACTED" "$BIOS_FILENAME" 2>/dev/null || \
        cp /tmp/bios_extract/*.308 "$BIOS_FILENAME" 2>/dev/null || \
        cp /tmp/bios_extract/*.bin "$BIOS_FILENAME" 2>/dev/null || true
    else
      # Try extracting everything and finding the BIOS file
      unzip -o /tmp/bios_download.zip -d /tmp/bios_extract/ 2>/dev/null
      FOUND=$(find /tmp/bios_extract/ -name "*.308" -o -name "X513IA*.cap" \
        | head -1 || true)
      [ -n "$FOUND" ] && cp "$FOUND" "$BIOS_FILENAME" || true
    fi
    rm -rf /tmp/bios_download.zip /tmp/bios_extract/
    [ -f "$BIOS_FILENAME" ] && DOWNLOADED=true && break
  else
    echo "[fetch] Failed (HTTP error or not found)"
  fi
done

# ── Manual fallback instructions ────────────────────────────
if [ "$DOWNLOADED" = false ] || [ ! -f "$BIOS_FILENAME" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  MANUAL DOWNLOAD REQUIRED                           ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
  echo "ASUS CDN URLs were unreachable or returned wrong content."
  echo ""
  echo "Manual steps:"
  echo "  1. Go to: https://www.asus.com/supportonly/X513IA/HelpDesk_BIOS/"
  echo "  2. Download BIOS version 308 (X513IAAS.308)"
  echo "  3. Unzip the downloaded file"
  echo "  4. Copy X513IAAS.308 to: $OUT_DIR/"
  echo "  5. Re-run this script to verify:"
  echo "       bash $0"
  echo ""
  echo "Then run the patcher:"
  echo "  python3 patch_apcb_smt.py X513IAAS.308"
  exit 1
fi

# ── Verify SHA256 ───────────────────────────────────────────
echo "[fetch] Verifying SHA256..."
ACTUAL=$(sha256sum "$BIOS_FILENAME" | awk '{print toupper($1)}')
if [ "$ACTUAL" = "$EXPECTED_SHA256" ]; then
  echo "[fetch] SHA256 VERIFIED ✓"
  echo "$ACTUAL  $BIOS_FILENAME" > "$BIOS_FILENAME.sha256"
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  BIOS READY — run the patcher next:                 ║"
  echo "║    python3 patch_apcb_smt.py $BIOS_FILENAME         ║"
  echo "╚══════════════════════════════════════════════════════╝"
else
  echo "[fetch] SHA256 MISMATCH!"
  echo "  Expected: $EXPECTED_SHA256"
  echo "  Got:      $ACTUAL"
  echo ""
  echo "The downloaded file does not match the known-good X513IAAS.308."
  echo "This may be a different BIOS version. Do NOT patch without verifying."
  echo ""
  echo "If this is a newer BIOS version, update EXPECTED_SHA256 in patch_apcb_smt.py"
  echo "and re-run the APCB offset analysis to confirm token 0x0076 is still at"
  echo "the same offsets (0x0029E021 primary, 0x006E6021 mirror)."
  exit 1
fi
