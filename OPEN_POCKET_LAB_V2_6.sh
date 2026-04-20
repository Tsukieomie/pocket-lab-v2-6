#!/usr/bin/env sh
# Pocket Security Lab v2.6 opener
# Gate 1: startup integrity + tamper check
# Gate 2: signed GitHub approval (no token needed)
# Gate 3: v2.6 unified verify
# Then: unlocks v2.3 encrypted bundle (the live vault)
set -eu
SEC=/root/.pocket_lab_secure

echo "[Gate 1] Startup verify + tamper check..."
"$SEC/startup-verify.sh"
"$SEC/tamper-alert.sh" check

echo "[Gate 2] Signed GitHub approval..."
. "$SEC/signed-approval-config"
"$SEC/pocket-lab-signed-approval.sh" check

echo "[Gate 3] v2.6 unified verify..."
/root/perplexity/verify_pocket_lab_v2_6.sh

echo "[Unlock] Opening lab..."
exec /root/.pocket_lab_secure/open-pocket-lab.sh "$@"
