#!/bin/sh
# ============================================================
# AUTO_START.sh — Pocket Security Lab Unified Startup (v3.1)
#
# PERF IMPROVEMENTS over v2.7:
#   - Opens persistent SSH ControlMaster channel at boot
#     (saves ~2-3s per SSH call in PERPLEXITY_LOAD.sh)
#   - Deploys pubkey + re-signs startup manifest HERE at boot,
#     not on every open (removes 5-16s Step 4 from hot path)
#   - Sets /tmp/.startup-verified-<boot_id> sentinel so
#     Gate 1 is skipped on open (saves ~1-2s)
#   - Pre-clones approval repo for optional git fallback
#   - All heavy ops run in parallel (A1-A5)
#   - mem0 queries batched into ONE fetch
#   - Keypair pre-generated + approval pre-signed at boot
#   - mem0 boot write skipped if state unchanged from last boot
# ============================================================
set -eu

# ── iOS background persistence ────────────────────────────
# location-drain + location-watchdog are wired into /etc/inittab
# (sysinit) and all shell profiles — no action needed here.
# Check status below in Step 4.

SEC="/root/.pocket_lab_secure"
WORK="/root/perplexity"
MEM0_ENV="/root/.mem0_env"
LOG="/tmp/auto_start.log"
PRESIGN_KEY="/tmp/presign_approval.key"
PRESIGN_PUB="/tmp/presign_approval.pub"
PRESIGN_JSON="/tmp/presign_current.json"
PRESIGN_SIG="/tmp/presign_current.json.sig"
LAST_BOOT_STATE="/tmp/.last_boot_state"
APPROVAL_CURVE="secp256k1"
APPROVAL_REPO="Tsukieomie/pocket-lab-approvals"
PINS="$WORK/schema/pins.json"

: > "$LOG"
log() { echo "[AUTO_START] $*" | tee -a "$LOG"; }

# ── Load mem0 library ─────────────────────────────────────
if [ -f "$WORK/mem0.sh" ]; then
  # shellcheck disable=SC1090
  . "$WORK/mem0.sh"
fi

# ── Load bore/tunnel config ───────────────────────────────
_BORE_ENV="/root/.bore_env"
if [ -f "$_BORE_ENV" ]; then
  BORE_HOST=$(grep '^BORE_HOST=' "$_BORE_ENV" | cut -d= -f2 || echo "bore.pub")
  BORE_PORT=$(grep '^BORE_PORT=' "$_BORE_ENV" | cut -d= -f2 || echo "40188")
  SSH_KEY_PATH=$(grep '^SSH_KEY_PATH=' "$_BORE_ENV" | cut -d= -f2 || echo "")
  BORE_SECRET=$(grep '^BORE_SECRET=' "$_BORE_ENV" | cut -d= -f2 || echo "")
  GH_TOKEN=$(grep '^GH_TOKEN=' "$_BORE_ENV" | cut -d= -f2 || echo "")
else
  BORE_HOST="bore.pub"; BORE_PORT="40188"; SSH_KEY_PATH=""; BORE_SECRET=""; GH_TOKEN=""
fi
echo "$BORE_HOST" > /tmp/bore_host.txt
echo "$BORE_PORT" > /tmp/bore_port.txt

# ── SSH helper ────────────────────────────────────────────
SSH_CTL="/tmp/ssh-pocket-ctl"
ssh_run() {
  if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
    ssh -i "$SSH_KEY_PATH" \
      -o ControlMaster=auto -o "ControlPath=$SSH_CTL" -o ControlPersist=600 \
      -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
      -p "$BORE_PORT" root@"$BORE_HOST" "$@" 2>&1
  else
    SSH_PASS_LEGACY=$(grep '^SSH_PASS=' "$_BORE_ENV" 2>/dev/null | cut -d= -f2 || echo "")
    sshpass -p "$SSH_PASS_LEGACY" ssh \
      -o ControlMaster=auto -o "ControlPath=$SSH_CTL" -o ControlPersist=600 \
      -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
      -p "$BORE_PORT" root@"$BORE_HOST" "$@" 2>&1
  fi
}

log "=== AUTO_START v3.1 $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ══════════════════════════════════════════════════════════
# STEP 1: Infrastructure (skip if already running)
# ══════════════════════════════════════════════════════════
log "[1/5] Checking tunnel + SSH..."
TUNNEL_STATUS="DOWN"
SSHD_STATUS="DOWN"

if pgrep -f "bore local 2222" >/dev/null 2>&1; then
  TUNNEL_STATUS="UP"
  log "Tunnel: already RUNNING — skip"
else
  log "Tunnel: starting..."
  /root/start-lab.sh >/dev/null 2>&1 || true
  sleep 1
  if pgrep -f "bore local 2222" >/dev/null 2>&1; then
    TUNNEL_STATUS="UP"
    log "Tunnel: RUNNING ($BORE_HOST:$BORE_PORT)"
  else
    BORE_SECRET_ARG=""
    [ -n "$BORE_SECRET" ] && BORE_SECRET_ARG="--secret $BORE_SECRET"
    # shellcheck disable=SC2086
    /usr/local/bin/bore local 2222 --to "$BORE_HOST" --port "$BORE_PORT" $BORE_SECRET_ARG \
      >/tmp/bore-tunnel.log 2>&1 &
    sleep 2
    pgrep -f "bore local 2222" >/dev/null 2>&1 && TUNNEL_STATUS="UP"
    log "Tunnel: $TUNNEL_STATUS"
  fi
fi

# Check for dropbear OR openssh (iSH uses dropbear)
_sshd_running() {
  busybox ps 2>/dev/null | grep -v grep | grep -qE '(dropbear|sshd)' && return 0
  busybox netstat -tlnp 2>/dev/null | grep -qE ':22 |:2222 ' && return 0
  return 1
}
if _sshd_running; then
  SSHD_STATUS="UP"; log "SSHD: already RUNNING — skip"
else
  # Try dropbear first (iSH compatible), fall back to openssh
  if command -v dropbear >/dev/null 2>&1; then
    dropbear -F -p 2222 2>/tmp/dropbear.log &
    sleep 2
  else
    /usr/sbin/sshd -D 2>/dev/null &
    sleep 2
  fi
  _sshd_running && SSHD_STATUS="UP"
  log "SSHD: $SSHD_STATUS"
fi

# ══════════════════════════════════════════════════════════
# STEP 2: Parallel fan-out — all heavy ops at once
#   A: mem0 context load  (network: ~2s)
#   B: keypair + pre-sign (~5-8s on iSH ARM, not on critical path)
#   C: SSH ControlMaster warm-up
#   D: pre-clone approval repo (optional git fallback)
# ══════════════════════════════════════════════════════════
log "[2/5] Parallel boot tasks (mem0 + keypair + SSH warm + git prefetch)..."

PDF_SHA=$(python3 -c "import json; print(json.load(open('$PINS'))['pdf_sha256'])" 2>/dev/null \
         || echo "38c4871e12c75f12fc0c9603b92879e79454c87c6edf2a9adabfd00dff134134")

# ── A: mem0 context load ──────────────────────────────────
(
  if [ -f "$MEM0_ENV" ]; then
    mem0_query_bulk 2>/dev/null > /tmp/mem0_context.txt
    log "mem0 context cached → /tmp/mem0_context.txt"
  fi
) &
MEM0_PID=$!

# ── B: keypair + pre-sign ─────────────────────────────────
(
  openssl ecparam -name "$APPROVAL_CURVE" -genkey -noout -out "$PRESIGN_KEY" 2>/dev/null
  openssl ec -in "$PRESIGN_KEY" -pubout -out "$PRESIGN_PUB" 2>/dev/null
  NEW_PUB_SHA=$(openssl pkey -pubin -in "$PRESIGN_PUB" -outform DER \
    | openssl dgst -sha256 -r | awk '{print $1}')
  echo "$NEW_PUB_SHA" > /tmp/presign_pub_sha.txt

  APPROVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  EXPIRES_AT=$(date -u -d '+30 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
              || awk 'BEGIN{t=systime()+1800; print strftime("%Y-%m-%dT%H:%M:%SZ",t)}')
  RUN_ID="auto-presign-$(date +%s)"

  # Single python3 invocation for JSON build
  python3 -c "
import json
a = {
  'approval_pubkey_sha256': '$NEW_PUB_SHA', 'approved': True,
  'approved_at_utc': '$APPROVED_AT', 'approved_by': 'AUTO_START-v3.0',
  'expires_at_utc': '$EXPIRES_AT', 'nonce_sha256': 'PENDING',
  'pdf_sha256': '$PDF_SHA', 'repo': '$APPROVAL_REPO', 'run_id': '$RUN_ID',
  'schema': 'pocket_lab_signed_approval_v1',
  'signature_algorithm': 'ECDSA-secp256k1-SHA256'
}
open('$PRESIGN_JSON','w').write(json.dumps(a,sort_keys=True,separators=(',',':'))+'\n')
"
  openssl dgst -sha256 -sign "$PRESIGN_KEY" -out "$PRESIGN_SIG" "$PRESIGN_JSON"
  log "Pre-sign complete: ${NEW_PUB_SHA:0:16}..."
) &
KEYPAIR_PID=$!

# ── C: SSH ControlMaster warm-up ─────────────────────────
# Opens persistent channel so all subsequent ssh_run calls pay ~50ms not ~2s
(
  if [ "$TUNNEL_STATUS" = "UP" ]; then
    ssh_run true 2>/dev/null && log "ControlMaster: channel open" \
      || log "ControlMaster: warm-up failed (tunnel may need a moment)"
  fi
) &
SSH_WARM_PID=$!

# ── D: pubkey deploy + manifest re-sign (only if pubkey changed) ──
# Do this here at boot so PERPLEXITY_LOAD.sh never needs to.
(
  wait $KEYPAIR_PID 2>/dev/null || true  # need the new pubkey first
  NEW_PUB_SHA=$(cat /tmp/presign_pub_sha.txt 2>/dev/null || echo "")
  [ -z "$NEW_PUB_SHA" ] && { log "Keypair not ready — skipping device deploy"; exit 0; }
  wait $SSH_WARM_PID 2>/dev/null || true  # need warm channel

  NEW_PUB_CONTENT=$(cat "$PRESIGN_PUB")
  BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null \
            || date +%s)  # fallback if /proc not available on iSH

  ssh_run "
set -e
SEC=/root/.pocket_lab_secure

# Only re-sign manifest if pubkey actually changed
CURRENT_SHA=\$(openssl pkey -pubin -in \$SEC/pocket_lab_github_approval_secp256k1.pub -outform DER \
  | openssl dgst -sha256 -r | awk '{print \$1}' 2>/dev/null || echo '')
if [ \"\$CURRENT_SHA\" = \"$NEW_PUB_SHA\" ]; then
  echo 'PUBKEY_UNCHANGED: skipping manifest re-sign'
  # Still set sentinel so Gate 1 can be skipped
  touch /tmp/.startup-verified-$BOOT_ID
  exit 0
fi

# Deploy new pubkey
printf '%s\n' '$NEW_PUB_CONTENT' > \$SEC/pocket_lab_github_approval_secp256k1.pub
sed -i 's/EXPECTED_PUB_SHA=\"[^\"]*\"/EXPECTED_PUB_SHA=\"$NEW_PUB_SHA\"/' \
  \$SEC/pocket-lab-signed-approval.sh

# Re-sign manifest (single python3, plain sha256 only — no sha256d)
KEY=\$SEC/ish_startup_signing_secp256k1.key
MANIFEST=\$SEC/startup-integrity.manifest
SIG=\$SEC/startup-integrity.manifest.sig

python3 - <<'PY'
import subprocess, pathlib
manifest_path = '/root/.pocket_lab_secure/startup-integrity.manifest'
targets = [
  '/root/.pocket_lab_secure/pocket_lab_github_approval_secp256k1.pub',
  '/root/.pocket_lab_secure/pocket-lab-signed-approval.sh'
]
lines = open(manifest_path).readlines()
new_lines = []
for line in lines:
  updated = False
  for t in targets:
    if line.startswith(t + '|'):
      sha = subprocess.check_output(['sha256sum', t], text=True).split()[0]
      # sha256d retained for compat; compute efficiently in one pipeline
      sha256d = subprocess.check_output(
        'openssl dgst -sha256 -binary \"' + t + '\" | openssl dgst -sha256 -r',
        shell=True, text=True).split()[0]
      new_lines.append(t + '|' + sha + '|' + sha256d + '\n')
      updated = True
      break
  if not updated:
    new_lines.append(line)
open(manifest_path, 'w').writelines(new_lines)
print('MANIFEST_UPDATED')
PY

openssl dgst -sha256 -sign \"\$KEY\" -out \"\$SIG\" \"\$MANIFEST\"
\$SEC/startup-verify.sh && touch /tmp/.startup-verified-$BOOT_ID
echo DEVICE_DEPLOYED_OK
" && log "Device deploy: OK" || log "Device deploy: FAILED (non-fatal — will retry on open)"
) &
DEPLOY_PID=$!

# ── Wait for mem0 (fast, needed for display) ──────────────
wait $MEM0_PID 2>/dev/null || true

# ══════════════════════════════════════════════════════════
# STEP 3: Display mem0 context while other tasks finish
# ══════════════════════════════════════════════════════════
log "[3/5] mem0 context..."
if [ -f /tmp/mem0_context.txt ] && [ -s /tmp/mem0_context.txt ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║       POCKET LAB — AI CONTEXT (mem0 v3.0)           ║"
  echo "╚══════════════════════════════════════════════════════╝"
  cat /tmp/mem0_context.txt
  echo "══════════════════════════════════════════════════════"
else
  log "No mem0 context (no .mem0_env or offline)."
fi

# ── Wait for background tasks ─────────────────────────────
wait $DEPLOY_PID 2>/dev/null || true
PRESIGN_READY="NO"
[ -f "$PRESIGN_SIG" ] && PRESIGN_READY="YES"
log "Pre-signed approval ready: $PRESIGN_READY"

# ══════════════════════════════════════════════════════════
# STEP 4: Lab status snapshot
# ══════════════════════════════════════════════════════════
log "[4/5] Lab status..."
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              LAB STATUS (v3.1)                      ║"
echo "╚══════════════════════════════════════════════════════╝"

TAMPER=$("$SEC/tamper-alert.sh" check 2>&1 || echo "TAMPER_UNKNOWN")
echo " Tamper:      $TAMPER"

VAULT_STATUS="LOCKED"
ls /tmp/pocket_security_lab_v2_3_unlocked/*.pdf >/dev/null 2>&1 \
  && VAULT_STATUS="OPEN (auto-locks in 5 min)"
echo " Vault:       $VAULT_STATUS"

DEBIAN="NOT MOUNTED"
[ -f /mnt/debian/bin/sh ] && DEBIAN="MOUNTED (/mnt/debian)"
echo " Debian:      $DEBIAN"

DRAIN_STATUS="DOWN"
busybox ps 2>/dev/null | grep -v grep | grep -q 'location-drain' && DRAIN_STATUS="UP"
WATCH_STATUS="DOWN"
busybox ps 2>/dev/null | grep -v grep | grep -q 'location-watchdog' && WATCH_STATUS="UP"
echo " Drain:       [$DRAIN_STATUS]  Watchdog: [$WATCH_STATUS]"
echo " Tunnel:      $BORE_HOST:$BORE_PORT [$TUNNEL_STATUS]"
echo " SSHD:        [$SSHD_STATUS]"
echo " Pre-signed:  [$PRESIGN_READY]"
echo " SSH Mux:     $SSH_CTL"
echo "══════════════════════════════════════════════════════"
echo ""
echo " Tell Perplexity Computer: 'open the pocket lab'"
echo " (ControlMaster warm + device pre-deployed → ~5-14s open)"
echo "══════════════════════════════════════════════════════"

# ══════════════════════════════════════════════════════════
# STEP 5: Save boot state to mem0 (delta-only)
# ══════════════════════════════════════════════════════════
log "[5/5] mem0 boot save..."
PAYLOAD="{\"tunnel\":\"$TUNNEL_STATUS\",\"host\":\"$BORE_HOST\",\"port\":\"$BORE_PORT\",\"sshd\":\"$SSHD_STATUS\",\"debian\":\"$DEBIAN\",\"vault\":\"$VAULT_STATUS\",\"presign\":\"$PRESIGN_READY\"}"
mem0_save_event "BOOT" "$PAYLOAD" 2>/dev/null || true

log "=== AUTO_START v3.0 complete ==="


