#!/bin/bash
# apply-tdp.sh — Ryzen 7 4700U TDP profiles
#
# Called by ryzenadj-tdp.service on boot and by 71-ryzenadj-ac.rules
# on AC/battery transitions.
#
# Profiles:
#   ac      slow=35W  fast=45W  tctl=105°C  (plugged in — full headroom)
#   battery slow=15W  fast=20W  tctl=95°C   (on battery — sustain efficiency)
#   default ac profile when called with no args or from service

set -euo pipefail

modprobe ryzen_smu 2>/dev/null || true

# Wait for ryzen_smu to settle — poll instead of fixed sleep
for i in $(seq 1 10); do
  ryzenadj --info >/dev/null 2>&1 && break
  sleep 0.5
done

# Detect AC/battery if no arg given
PROFILE="${1:-}"
if [ -z "$PROFILE" ]; then
  AC_ONLINE=$(cat /sys/class/power_supply/AC*/online 2>/dev/null | head -1 || echo "1")
  [ "$AC_ONLINE" = "1" ] && PROFILE="ac" || PROFILE="battery"
fi

case "$PROFILE" in
  ac)
    ryzenadj \
      --slow-limit=35000 \
      --fast-limit=45000 \
      --tctl-temp=105 \
      --vrm-current=55000 \
      --vrmsoc-current=35000 \
      --vrmmax-current=55000 \
      --vrmsocmax-current=35000 \
      && echo "tdp_applied: ac  slow=35W fast=45W tctl=105C" \
      || echo "ryzenadj_failed: ac profile"
    ;;
  battery)
    ryzenadj \
      --slow-limit=15000 \
      --fast-limit=20000 \
      --tctl-temp=95 \
      --vrm-current=40000 \
      --vrmsoc-current=25000 \
      --vrmmax-current=40000 \
      --vrmsocmax-current=25000 \
      && echo "tdp_applied: battery  slow=15W fast=20W tctl=95C" \
      || echo "ryzenadj_failed: battery profile"
    ;;
  *)
    echo "Usage: apply-tdp.sh [ac|battery]" >&2
    exit 1
    ;;
esac
