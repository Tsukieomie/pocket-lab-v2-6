#!/usr/bin/env sh
set -eu

PDF_PATH="${1:-/root/perplexity/pocket_security_lab_v2_4_integrated.pdf}"
MANIFEST="${2:-/root/perplexity/pocket_security_lab_v2_4.manifest}"
SIG="${3:-/root/perplexity/pocket_security_lab_v2_4.manifest.sig}"
PUB="${4:-/root/.pocket_lab_secure/ish_startup_signing_secp256k1.pub}"

if [ ! -f "$PDF_PATH" ] || [ ! -f "$MANIFEST" ] || [ ! -f "$SIG" ] || [ ! -f "$PUB" ]; then
  echo "VERIFY_FAIL: missing PDF, manifest, signature, or public key" >&2; exit 2
fi

openssl dgst -sha256 -verify "$PUB" -signature "$SIG" "$MANIFEST" >/dev/null 2>&1 \
  || { echo "VERIFY_FAIL: signature invalid" >&2; exit 3; }

PDF_SHA="$(sha256sum "$PDF_PATH" | awk "{print \$1}")"
PDF_SHA2="$(openssl dgst -sha256 -binary "$PDF_PATH" | openssl dgst -sha256 -r | awk "{print \$1}")"

python3 - "$MANIFEST" "$PDF_SHA" "$PDF_SHA2" <<'PY'
import json, sys, hmac
manifest_path, sha, sha2 = sys.argv[1:]
m = json.load(open(manifest_path))
policy = m.get("policy", {})
required = {
    "pdf_self_execution": False, "fail_closed": True,
    "trust_on_first_use": False, "skip_flags_allowed": False,
    "private_keys_in_bundle": False, "hash_prefix_match_allowed": False,
    "proceed_anyway_allowed": False,
}
for key, expected in required.items():
    if policy.get(key) is not expected:
        raise SystemExit(f"VERIFY_FAIL: policy {key} is {policy.get(key)!r}, expected {expected!r}")
pdf = next((a for a in m.get("artifacts", []) if a.get("path") == "pocket_security_lab_v2_4_integrated.pdf"), None)
if not pdf:
    raise SystemExit("VERIFY_FAIL: manifest missing v2.4 PDF artifact")
if not hmac.compare_digest(pdf.get("sha256",""), sha):
    raise SystemExit("VERIFY_FAIL: PDF SHA-256 mismatch")
if not hmac.compare_digest(pdf.get("sha256d",""), sha2):
    raise SystemExit("VERIFY_FAIL: PDF double-SHA-256 mismatch")
print("VERIFY_OK: v2.4 PDF matches signed manifest and hardened policy")
PY
