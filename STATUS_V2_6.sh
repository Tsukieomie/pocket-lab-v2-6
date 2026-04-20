#!/usr/bin/env sh
echo "============================================================"
echo " POCKET SECURITY LAB v2.6 — UNIFIED STATUS"
echo "============================================================"
echo ""
echo "--- Tamper status ---"
/root/.pocket_lab_secure/tamper-alert.sh status 2>&1 || true
echo ""
echo "--- Lab integrity (v2.3) ---"
/root/.pocket_lab_secure/verify-pocket-lab.sh 2>&1 || true
echo ""
echo "--- v2.4 PDF verify ---"
/root/perplexity/verify_pocket_lab_v2_4.sh 2>&1 || true
echo ""
echo "--- v2.6 manifest verify ---"
/root/perplexity/verify_pocket_lab_v2_6.sh 2>&1 || true
echo ""
echo "--- GitHub signed approval status ---"
. /root/.pocket_lab_secure/signed-approval-config
/root/.pocket_lab_secure/pocket-lab-signed-approval.sh status 2>&1 || true
echo ""
echo "--- Tunnel (bore.pub:40188) ---"
pgrep -f "bore local 2222" >/dev/null 2>&1 && echo "TUNNEL_RUNNING" || echo "TUNNEL_DOWN — run /root/start-lab.sh"
echo ""
echo "--- Temporary plaintext ---"
ls /tmp/pocket_security_lab_v2_3_unlocked/ 2>/dev/null && echo "LAB OPEN — remember to lock!" || echo "Locked (no plaintext present)"
echo "============================================================"
