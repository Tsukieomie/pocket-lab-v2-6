#!/usr/bin/env bash
# persist-iomem-relaxed.sh
# Adds `iomem=relaxed` to GRUB_CMDLINE_LINUX_DEFAULT and runs update-grub.
# After reboot, /proc/cmdline will contain iomem=relaxed.
#
# WHY: lets userspace tools (HackRF, RTL-SDR debug, /dev/mem readers) access
# physical memory ranges normally locked down by CONFIG_STRICT_DEVMEM.
#
# SECURITY TRADE-OFF: weakens /dev/mem protection. Only enable on a
# workstation you control where you actually need it for hardware/SDR work.
#
# Idempotent: safe to re-run.
set -euo pipefail

GRUB_FILE="/etc/default/grub"
KEY="GRUB_CMDLINE_LINUX_DEFAULT"
FLAG="iomem=relaxed"

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (use sudo)"; exit 1; }
[ -f "$GRUB_FILE" ]  || { echo "ERROR: $GRUB_FILE not found"; exit 1; }

current_line="$(grep -E "^${KEY}=" "$GRUB_FILE" | head -n1 || true)"
if [ -z "$current_line" ]; then
  echo "ERROR: no ${KEY}= line in $GRUB_FILE"
  exit 1
fi
echo "Before: $current_line"

if grep -qE "^${KEY}=\".*\b${FLAG}\b.*\"" "$GRUB_FILE"; then
  echo "Already present in $GRUB_FILE — nothing to do."
else
  cp -a "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%s)"
  # Append flag inside the existing quotes
  sed -i -E "s|^(${KEY}=\")(.*)(\")$|\1\2 ${FLAG}\3|" "$GRUB_FILE"
  # Collapse accidental double spaces
  sed -i -E "s|^(${KEY}=\")  +|\1|; s| +\"$|\"|" "$GRUB_FILE"
  echo "After:  $(grep -E "^${KEY}=" "$GRUB_FILE" | head -n1)"
fi

echo
echo "Running update-grub..."
update-grub
echo
echo "Done. Reboot to apply, then verify with:"
echo "    grep iomem /proc/cmdline"
