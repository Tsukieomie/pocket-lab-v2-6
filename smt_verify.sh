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
