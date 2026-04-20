#!/bin/sh
# ============================================================
# STATUS_V2_6.sh — Pocket Security Lab unified status
# ============================================================
set -eu

FAILED=0

run_check() {
  # run_check <label> <command...>
  label=$1
  shift
  if ! "$@"; then
    echo "FAIL: $label"
    FAILED=$((FAILED + 1))
  fi
}

echo "============================================================"
echo " POCKET SECURITY LAB v2.6 — UNIFIED STATUS"
echo "============================================================"
echo ""
echo "--- Tamper status ---"
run_check "tamper-alert" /root/.pocket_lab_secure/tamper-alert.sh status
echo ""
echo "--- Lab integrity (v2.3) ---"
run_check "verify-pocket-lab (v2.3)" /root/.pocket_lab_secure/verify-pocket-lab.sh
echo ""
echo "--- v2.4 PDF verify ---"
run_check "verify v2.4 PDF" /root/perplexity/verify_pocket_lab_v2_4.sh
echo ""
echo "--- v2.6 manifest verify ---"
run_check "verify v2.6 manifest" /root/perplexity/verify_pocket_lab_v2_6.sh
echo ""
echo "--- GitHub signed approval status ---"
if [ -f /root/.pocket_lab_secure/signed-approval-config ]; then
  # shellcheck disable=SC1091
  . /root/.pocket_lab_secure/signed-approval-config
  run_check "signed-approval status" /root/.pocket_lab_secure/pocket-lab-signed-approval.sh status
else
  echo "FAIL: signed-approval-config missing"
  FAILED=$((FAILED + 1))
fi
echo ""
echo "--- Tunnel (bore.pub:40188) ---"
if pgrep -f "bore local 2222" >/dev/null 2>&1; then
  echo "TUNNEL_RUNNING"
else
  echo "FAIL: TUNNEL_DOWN — run /root/start-lab.sh"
  FAILED=$((FAILED + 1))
fi
echo ""
echo "--- Temporary plaintext ---"
if ls /tmp/pocket_security_lab_v2_3_unlocked/ 2>/dev/null; then
  echo "LAB OPEN — remember to lock!"
else
  echo "Locked (no plaintext present)"
fi
echo "============================================================"

if [ "$FAILED" -gt 0 ]; then
  echo "STATUS: $FAILED check(s) failed"
  exit 1
fi
echo "STATUS: all checks passed"
