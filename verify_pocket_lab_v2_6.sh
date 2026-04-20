#!/usr/bin/env sh
# Pocket Security Lab v2.6 — unified verifier
set -eu
WORK=/root/perplexity
SEC=/root/.pocket_lab_secure

fail() { echo "VERIFY_FAIL: $*" >&2; exit 1; }

# Step 1: verify v2.4 artifacts (the active encrypted bundle)
echo "[1/3] Verifying v2.4 PDF and encrypted archive..."
/root/perplexity/verify_pocket_lab_v2_4.sh || fail "v2.4 PDF verify failed"

# Step 2: verify v2.6 manifest signature
echo "[2/3] Verifying v2.6 manifest signature..."
PUB="$SEC/pocket_lab_secp256k1.pub"
MANIFEST="$WORK/pocket_security_lab_v2_6.manifest"
SIG="$WORK/pocket_security_lab_v2_6.manifest.sig"
[ -f "$MANIFEST" ] || fail "v2.6 manifest missing"
[ -f "$SIG" ] || fail "v2.6 signature missing"
openssl dgst -sha256 -verify "$PUB" -signature "$SIG" "$MANIFEST" >/dev/null 2>&1 \
  || fail "v2.6 manifest signature invalid"

# Step 3: verify policy fields
echo "[3/3] Verifying v2.6 policy..."
python3 - "$MANIFEST" << PY
import json, sys
m = json.load(open(sys.argv[1]))
p = m.get("policy", {})
assert p.get("fail_closed") is True, "fail_closed must be true"
assert p.get("pdf_self_execution") is False, "pdf_self_execution must be false"
assert p.get("proceed_anyway_allowed") is False, "proceed_anyway_allowed must be false"
print("VERIFY_OK: v2.6 manifest policy valid")
PY

echo "VERIFY_OK: Pocket Security Lab v2.6 — all checks passed"
