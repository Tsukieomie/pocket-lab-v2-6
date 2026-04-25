#!/bin/bash
# Post-reboot SMT finder
# Usage: bash ~/pocket-lab-v2-6/linux/find-smt-offset.sh
set -e

echo "=== Checking iomem=relaxed ==="
grep iomem /proc/cmdline || { echo "ERROR: iomem=relaxed not in cmdline — reboot first"; exit 1; }

echo ""
echo "=== Reading BIOS ROM via flashrom ==="
sudo flashrom -p internal -r /tmp/bios.rom 2>&1 | tail -5
ls -lh /tmp/bios.rom

echo ""
echo "=== Parsing BIOS ROM for SMT HII offset ==="
python3 /tmp/parse_hii.py
