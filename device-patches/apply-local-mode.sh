#!/bin/sh
# Apply --local mode patch to pocket-lab-signed-approval.sh (device-side)
# Run once on iSH after pulling pocket-lab-v2-6.
set -eu
TARGET="/root/.pocket_lab_secure/pocket-lab-signed-approval.sh"
[ -f "$TARGET" ] || { echo "ERROR: $TARGET not found"; exit 1; }

# Check if patch already applied
grep -q "local)" "$TARGET" && { echo "Already patched."; exit 0; }

# Insert before the closing *)
PATCH='  local)
    LOCAL_FILE="${2:-/tmp/current.json}"
    LOCAL_SIG="${LOCAL_FILE}.sig"
    [ -f "$LOCAL_FILE" ] || { echo "LOCAL_FILE_MISSING: $LOCAL_FILE" >&2; exit 3; }
    [ -f "$LOCAL_SIG"  ] || { echo "LOCAL_SIG_MISSING: $LOCAL_SIG"  >&2; exit 3; }
    PUB="$SEC/pocket_lab_github_approval_secp256k1.pub"
    openssl dgst -sha256 -verify "$PUB" -signature "$LOCAL_SIG" "$LOCAL_FILE" >/dev/null \
      || { echo "LOCAL_SIG_INVALID" >&2; exit 3; }
    cp "$LOCAL_FILE" "$APPROVAL"
    verify_approval
    ;;'

# Use python3 to insert before the *) line (portable, no sed multiline needed)
python3 - "$TARGET" "$PATCH" <<'PY'
import sys
path, patch = sys.argv[1], sys.argv[2]
lines = open(path).readlines()
out = []
for line in lines:
    if line.strip().startswith('*)') and 'Usage' in ''.join(lines[lines.index(line):lines.index(line)+2]):
        out.append(patch + '\n')
    out.append(line)
open(path, 'w').writelines(out)
print("Patch applied to", path)
PY
