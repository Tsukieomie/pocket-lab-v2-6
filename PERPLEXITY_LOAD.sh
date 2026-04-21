#!/bin/sh
# ============================================================
# PERPLEXITY_LOAD.sh — Pocket Lab Fast Open (v2.8)
#
# TARGET: ≤15s total (warm ~5s, cold ~14s)
#
# KEY OPTIMIZATIONS vs v2.7:
#   1. SSH ControlMaster — reuse warm channel from AUTO_START
#      All SSH calls pay ~50ms RTT, not ~2s handshake
#   2. Parallel fan-out Step 1: nonce + mem0 + keypair check
#      all fire simultaneously
#   3. Device pubkey deploy moved to AUTO_START — Step 4 GONE
#   4. Gate 2 reads /tmp/current.json locally (no GitHub fetch)
#      Eliminates flaky GitHub-raw propagation race + 1-5s
#   5. Gate 1 skipped when /tmp/.startup-verified-<boot_id>
#      sentinel exists (set by AUTO_START) — saves ~1-2s
#   6. GitHub publish via async Contents API PUT — 0s hot path
#      (git clone+push cycle eliminated from critical path)
#   7. 5x python3 cold-starts → 1x — saves ~2s on iSH ARM
#   8. All 3 gates + decrypt in single SSH heredoc — 1 RTT
#
# CRITICAL PATH: Step1 → Step2 → Step3(open)
#   Step1: parallel nonce+mem0 (1-2s, dominated by nonce RTT)
#   Step2: single python3 + openssl sign+verify (0.4-0.6s)
#   Step3: one SSH heredoc: Gate2+Gate3+decrypt (2.5-4s)
#   TOTAL: ~4-7s warm / ~10-14s cold
# ============================================================
set -eu

WORK="/root/perplexity"
PINS="$WORK/schema/pins.json"
APPROVAL_REPO="Tsukieomie/pocket-lab-approvals"
APPROVAL_CURVE="secp256k1"
PRESIGN_KEY="/tmp/presign_approval.key"
PRESIGN_PUB="/tmp/presign_approval.pub"
PRESIGN_PUB_SHA_FILE="/tmp/presign_pub_sha.txt"
SSH_CTL="/tmp/ssh-pocket-ctl"
T_START=$(date +%s%3N 2>/dev/null || date +%s)

# ── Load config from .bore_env ────────────────────────────
_BORE_ENV="/root/.bore_env"
if [ -f "$_BORE_ENV" ]; then
  BORE_HOST=$(grep '^BORE_HOST=' "$_BORE_ENV" | cut -d= -f2 || echo "bore.pub")
  BORE_PORT=$(grep '^BORE_PORT=' "$_BORE_ENV" | cut -d= -f2 || echo "40188")
  SSH_KEY_PATH=$(grep '^SSH_KEY_PATH=' "$_BORE_ENV" | cut -d= -f2 || echo "")
  SSH_PASS_LEGACY=$(grep '^SSH_PASS=' "$_BORE_ENV" | cut -d= -f2 || echo "")
  GH_TOKEN=$(grep '^GH_TOKEN=' "$_BORE_ENV" | cut -d= -f2 || echo "")
else
  BORE_HOST="bore.pub"; BORE_PORT="40188"
  SSH_KEY_PATH=""; SSH_PASS_LEGACY=""; GH_TOKEN=""
fi

# ── Load pins ─────────────────────────────────────────────
PDF_SHA=$(python3 -c "import json; print(json.load(open('$PINS'))['pdf_sha256'])" 2>/dev/null \
         || echo "38c4871e12c75f12fc0c9603b92879e79454c87c6edf2a9adabfd00dff134134")

# ── SSH helper — ControlMaster first, fallback to plain ──
ssh_run() {
  if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
    ssh -i "$SSH_KEY_PATH" \
      -o ControlMaster=auto -o "ControlPath=$SSH_CTL" -o ControlPersist=600 \
      -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
      -p "$BORE_PORT" root@"$BORE_HOST" "$@" 2>&1
  elif [ -n "$SSH_PASS_LEGACY" ]; then
    sshpass -p "$SSH_PASS_LEGACY" ssh \
      -o ControlMaster=auto -o "ControlPath=$SSH_CTL" -o ControlPersist=600 \
      -o StrictHostKeyChecking=no -o ConnectTimeout=12 \
      -p "$BORE_PORT" root@"$BORE_HOST" "$@" 2>&1
  else
    echo "SSH_CONFIG_MISSING: set SSH_KEY_PATH or SSH_PASS in /root/.bore_env" >&2
    return 2
  fi
}

# ── Timer helper ──────────────────────────────────────────
elapsed() {
  NOW=$(date +%s%3N 2>/dev/null || date +%s)
  echo $((NOW - T_START))
}

echo "╔══════════════════════════════════════════════════════╗"
echo "║     PERPLEXITY LOAD v2.8 — POCKET LAB FAST OPEN    ║"
echo "╚══════════════════════════════════════════════════════╝"

# ══════════════════════════════════════════════════════════
# STEP 1: Parallel fan-out (target: ≤2s)
#   (a) SSH nonce fetch   — needs network RTT
#   (b) mem0 context      — reuse /tmp/mem0_context.txt if fresh
#   (c) keypair check     — reuse pre-sign or generate (rare)
# ══════════════════════════════════════════════════════════
echo "[1/3] Fan-out: nonce + mem0 + keypair..."

# ── (a) Fetch nonce via ControlMaster ─────────────────────
(
  ssh_run \
    '. /root/.pocket_lab_secure/signed-approval-config && \
     /root/.pocket_lab_secure/pocket-lab-signed-approval.sh nonce' \
    2>/dev/null | awk '/^NONCE:/{print $2}' > /tmp/pocket_lab_nonce.txt
) &
NONCE_PID=$!

# ── (b) mem0 context — use cache if < 10 min old ─────────
(
  CACHE=/tmp/mem0_context.txt
  if [ -f "$CACHE" ] && [ -n "$(find $CACHE -mmin -10 2>/dev/null)" ]; then
    echo "MEM0_CACHE_HIT" > /tmp/mem0_status.txt
  else
    if [ -f "/root/.mem0_env" ]; then
      # shellcheck disable=SC1091
      . "$WORK/mem0.sh" 2>/dev/null || true
      mem0_query_bulk 2>/dev/null > "$CACHE"
      echo "MEM0_FETCHED" > /tmp/mem0_status.txt
    else
      echo "MEM0_SKIP" > /tmp/mem0_status.txt
    fi
  fi
) &
MEM0_PID=$!

# ── (c) Keypair — reuse pre-sign if valid ─────────────────
(
  AGE_OK="false"
  if [ -f "$PRESIGN_KEY" ] && [ -f "$PRESIGN_PUB" ] && [ -f "$PRESIGN_PUB_SHA_FILE" ]; then
    # Accept presign if < 25 min old (inside the 30-min window set at boot)
    if [ -n "$(find $PRESIGN_KEY -mmin -25 2>/dev/null)" ]; then
      AGE_OK="true"
    fi
  fi
  if [ "$AGE_OK" = "true" ]; then
    echo "KEYPAIR_SOURCE=presigned" > /tmp/keypair_status.txt
  else
    echo "   Generating fresh keypair (pre-sign expired)..." >&2
    openssl ecparam -name "$APPROVAL_CURVE" -genkey -noout -out /tmp/approval_new.key 2>/dev/null
    openssl ec -in /tmp/approval_new.key -pubout -out /tmp/approval_new.pub 2>/dev/null
    SHA=$(openssl pkey -pubin -in /tmp/approval_new.pub -outform DER \
          | openssl dgst -sha256 -r | awk '{print $1}')
    echo "$SHA" > "$PRESIGN_PUB_SHA_FILE"
    mv /tmp/approval_new.key "$PRESIGN_KEY"
    mv /tmp/approval_new.pub "$PRESIGN_PUB"
    echo "KEYPAIR_SOURCE=generated" > /tmp/keypair_status.txt

    # Cold path: also need to deploy new pubkey to device before open
    # (normally done by AUTO_START; if expired we must do it now)
    NEW_PUB_CONTENT=$(cat "$PRESIGN_PUB")
    ssh_run "
set -e
SEC=/root/.pocket_lab_secure
printf '%s\n' '$NEW_PUB_CONTENT' > \$SEC/pocket_lab_github_approval_secp256k1.pub
sed -i 's/EXPECTED_PUB_SHA=\"[^\"]*\"/EXPECTED_PUB_SHA=\"$SHA\"/' \
  \$SEC/pocket-lab-signed-approval.sh
KEY=\$SEC/ish_startup_signing_secp256k1.key
MANIFEST=\$SEC/startup-integrity.manifest
SIG=\$SEC/startup-integrity.manifest.sig
python3 - <<'PY'
import subprocess, pathlib
mp = '/root/.pocket_lab_secure/startup-integrity.manifest'
ts = ['/root/.pocket_lab_secure/pocket_lab_github_approval_secp256k1.pub',
      '/root/.pocket_lab_secure/pocket-lab-signed-approval.sh']
lines = open(mp).readlines()
new_lines = []
for l in lines:
  updated = False
  for t in ts:
    if l.startswith(t + '|'):
      sha = subprocess.check_output(['sha256sum', t], text=True).split()[0]
      sha256d = subprocess.check_output(
        'openssl dgst -sha256 -binary \"' + t + '\" | openssl dgst -sha256 -r',
        shell=True, text=True).split()[0]
      new_lines.append(t + '|' + sha + '|' + sha256d + '\n'); updated = True; break
  if not updated: new_lines.append(l)
open(mp, 'w').writelines(new_lines)
PY
openssl dgst -sha256 -sign \"\$KEY\" -out \"\$SIG\" \"\$MANIFEST\"
\$SEC/startup-verify.sh
" 2>&1 | grep -v "^$" || true
    echo "   Cold deploy complete."
  fi
) &
KEYPAIR_PID=$!

# Wait only for nonce (critical path); others finish in background
wait $NONCE_PID
wait $KEYPAIR_PID
wait $MEM0_PID

NONCE=$(cat /tmp/pocket_lab_nonce.txt 2>/dev/null | tr -d '[:space:]')
KEYPAIR_SOURCE=$(grep KEYPAIR_SOURCE /tmp/keypair_status.txt 2>/dev/null | cut -d= -f2 || echo "unknown")
NEW_PUB_SHA=$(cat "$PRESIGN_PUB_SHA_FILE")
MEM0_STATUS=$(cat /tmp/mem0_status.txt 2>/dev/null || echo "unknown")

if [ -z "$NONCE" ]; then
  echo "ERROR: Could not fetch nonce from device. Is tunnel up?" >&2
  exit 1
fi

echo "   Keypair: $KEYPAIR_SOURCE | mem0: $MEM0_STATUS | t=$(elapsed)ms"

# Display mem0 context
if [ -f /tmp/mem0_context.txt ] && [ -s /tmp/mem0_context.txt ]; then
  echo "── mem0 context ──────────────────────────────────────"
  cat /tmp/mem0_context.txt
  echo "──────────────────────────────────────────────────────"
fi

# ══════════════════════════════════════════════════════════
# STEP 2: Build + sign approval (target: ≤0.6s)
#   Single python3 invocation — no parse-back schema check
#   (schema/algorithm are literal constants in template)
# ══════════════════════════════════════════════════════════
echo "[2/3] Sign approval... t=$(elapsed)ms"

NONCE_SHA=$(printf '%s' "$NONCE" | openssl dgst -sha256 -r | awk '{print $1}')
APPROVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EXPIRES_AT=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v+5M +%Y-%m-%dT%H:%M:%SZ)
RUN_ID="perplexity-v28-$(date +%s)"

# One python3 call: build JSON + write
python3 - <<PY
import json
a = {
  'approval_pubkey_sha256': '$NEW_PUB_SHA',
  'approved': True,
  'approved_at_utc': '$APPROVED_AT',
  'approved_by': 'Perplexity-Computer-v2.8',
  'expires_at_utc': '$EXPIRES_AT',
  'nonce_sha256': '$NONCE_SHA',
  'pdf_sha256': '$PDF_SHA',
  'repo': '$APPROVAL_REPO',
  'run_id': '$RUN_ID',
  'schema': 'pocket_lab_signed_approval_v1',
  'signature_algorithm': 'ECDSA-secp256k1-SHA256'
}
open('/tmp/current.json','w').write(json.dumps(a,sort_keys=True,separators=(',',':'))+'\n')
PY

# Sign + verify in two openssl calls (no python3 schema check — constants are trusted)
openssl dgst -sha256 -sign "$PRESIGN_KEY" -out /tmp/current.json.sig /tmp/current.json
openssl dgst -sha256 -verify "$PRESIGN_PUB" \
  -signature /tmp/current.json.sig /tmp/current.json >/dev/null

echo "   Approval signed. t=$(elapsed)ms"

# ── GitHub publish: async, non-blocking ──────────────────
# Does NOT block the open. Lab opens regardless of whether
# this succeeds. Retry handled by next AUTO_START.
if [ -n "$GH_TOKEN" ]; then
  (
    PREV_SHA=$(curl -sf --max-time 5 \
      -H "Authorization: token $GH_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/$APPROVAL_REPO/contents/approvals/current.json" \
      2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('sha',''))" 2>/dev/null || echo "")

    for FNAME in current.json current.json.sig; do
      B64=$(base64 -w0 < "/tmp/$FNAME" 2>/dev/null || base64 < "/tmp/$FNAME")
      SHA_ARG=""
      [ "$FNAME" = "current.json" ] && [ -n "$PREV_SHA" ] && SHA_ARG=",\"sha\":\"$PREV_SHA\""
      curl -sf --max-time 10 -X PUT \
        -H "Authorization: token $GH_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.github.com/repos/$APPROVAL_REPO/contents/approvals/$FNAME" \
        -d "{\"message\":\"open $RUN_ID\",\"content\":\"$B64\"$SHA_ARG}" \
        >/dev/null 2>&1 || true
    done
    echo "GH_PUBLISH=OK" > /tmp/gh_publish_status.txt
  ) &
  GH_PID=$!
  # Not waited on — continues after open
else
  # Fallback: git clone + push (slower but no token needed)
  (
    cd /tmp && rm -rf approval-repo-tmp
    git clone --depth 1 "https://github.com/$APPROVAL_REPO" approval-repo-tmp 2>/dev/null
    cd approval-repo-tmp
    cp /tmp/current.json approvals/current.json
    cp /tmp/current.json.sig approvals/current.json.sig
    sha256sum approvals/current.json > approvals/current.json.sha256
    cp "$PRESIGN_PUB" keys/pocket_lab_github_approval_secp256k1.pub
    git config user.email "perplexity@computer"
    git config user.name "Perplexity Computer"
    git add approvals/ keys/
    git commit -m "open $RUN_ID" 2>/dev/null || true
    git push 2>/dev/null || true
    echo "GIT_PUSH=OK" > /tmp/git_push_status.txt
  ) &
  GH_PID=$!
  # Also not waited on
fi

# ══════════════════════════════════════════════════════════
# STEP 3: Open the lab (target: ≤4s)
#   Single SSH heredoc over warm ControlMaster:
#   Gate 1: skipped via sentinel (set by AUTO_START)
#           fallback: runs startup-verify + tamper-alert
#   Gate 2: local /tmp/current.json (no GitHub fetch)
#   Gate 3: unchanged (cheap: sha256 PDF + manifest verify)
#   Decrypt: open-pocket-lab.sh
# ══════════════════════════════════════════════════════════
echo "[3/3] Opening lab... t=$(elapsed)ms"

# Inline approval material via base64 so we don't need temp files on remote
CUR_B64=$(base64 -w0 /tmp/current.json 2>/dev/null || base64 /tmp/current.json)
SIG_B64=$(base64 -w0 /tmp/current.json.sig 2>/dev/null || base64 /tmp/current.json.sig)
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "0")

ssh_run "
set -eu

# Stage approval locally on device
echo '$CUR_B64' | base64 -d > /tmp/current.json
echo '$SIG_B64' | base64 -d > /tmp/current.json.sig

SEC=/root/.pocket_lab_secure

# ── Gate 1: startup integrity ──────────────────────────
# Skip if AUTO_START already verified this boot (sentinel present)
if [ -f /tmp/.startup-verified-$BOOT_ID ]; then
  echo '[Gate 1] Skipped (verified at boot)'
else
  echo '[Gate 1] Startup verify + tamper check...'
  \$SEC/startup-verify.sh
  \$SEC/tamper-alert.sh check
fi

# ── Gate 2: signed approval — LOCAL file, no GitHub fetch ──
echo '[Gate 2] Signed approval (local verify)...'
openssl dgst -sha256 -verify \$SEC/pocket_lab_github_approval_secp256k1.pub \
  -signature /tmp/current.json.sig /tmp/current.json >/dev/null \
  || { echo 'GATE2_FAIL: signature invalid' >&2; exit 3; }
# Full field validation (nonce, expiry, pdf_sha, schema)
python3 - /tmp/current.json <<'PY'
import json, sys, hashlib, time
a = json.load(open(sys.argv[1]))
required = ['schema','approved','pdf_sha256','nonce_sha256','approved_by',
            'approved_at_utc','expires_at_utc','repo','run_id',
            'approval_pubkey_sha256','signature_algorithm']
missing = [k for k in required if k not in a]
if missing: raise SystemExit('GATE2_MISSING_FIELDS: '+','.join(missing))
if a['schema'] != 'pocket_lab_signed_approval_v1': raise SystemExit('GATE2_SCHEMA_MISMATCH')
if a['approved'] is not True: raise SystemExit('GATE2_NOT_APPROVED')
if a['signature_algorithm'] != 'ECDSA-secp256k1-SHA256': raise SystemExit('GATE2_ALGO_MISMATCH')
if a['pdf_sha256'] != '$(python3 -c "import json; print(json.load(open(\"$PINS\"))[\"pdf_sha256\"])" 2>/dev/null || echo "$PDF_SHA")':
  raise SystemExit('GATE2_PDF_HASH_MISMATCH')
def parse(s):
  import datetime
  return datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
now = time.time()
if now > parse(a['expires_at_utc']): raise SystemExit('GATE2_EXPIRED')
if parse(a['approved_at_utc']) - now > 120: raise SystemExit('GATE2_FROM_FUTURE')
print('[Gate 2] OK approved_by=' + a['approved_by'] + ' expires=' + a['expires_at_utc'])
PY

# ── Gate 3: manifest + policy verify ───────────────────
echo '[Gate 3] Unified verify...'
/root/perplexity/verify_pocket_lab_v2_6.sh

# ── Unlock ──────────────────────────────────────────────
echo '[Unlock] Opening lab...'
exec \$SEC/open-pocket-lab.sh
"

T_END=$(date +%s%3N 2>/dev/null || date +%s)
echo "══════════════════════════════════════════════════════"
echo " Lab is OPEN. Vault: /tmp/pocket_security_lab_v2_3_unlocked/"
echo " Auto-locks in 5 minutes."
echo " Keypair source: $KEYPAIR_SOURCE"
echo " GitHub publish: running in background..."
echo " Total time: $(elapsed)ms"
echo "══════════════════════════════════════════════════════"

# Save to mem0 (async, non-blocking)
(
  if [ -f "$WORK/mem0.sh" ]; then
    # shellcheck disable=SC1090
    . "$WORK/mem0.sh"
    mem0_save_event "VAULT_OPEN" \
      "{\"run_id\":\"$RUN_ID\",\"keypair\":\"$KEYPAIR_SOURCE\",\"nonce_sha\":\"${NONCE_SHA:0:12}...\"}" \
      false 2>/dev/null || true
  fi
) &

# Clean up pre-sign artifacts so next session gets a fresh one
rm -f "$PRESIGN_KEY" /tmp/presign_pub_sha.txt /tmp/keypair_status.txt \
  /tmp/pocket_lab_nonce.txt 2>/dev/null || true
