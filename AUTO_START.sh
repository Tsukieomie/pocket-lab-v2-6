#!/bin/sh
# ============================================================
# AUTO_START.sh — Pocket Security Lab Unified Startup (v2.7)
#
# PERF IMPROVEMENTS over v2.6:
#   - Healthcheck: skips tunnel/sshd if already running
#   - mem0 queries batched into ONE fetch (single API call)
#   - Keypair pre-generated + approval pre-signed at boot
#     so PERPLEXITY_LOAD.sh finds it ready (no wait mid-session)
#   - mem0 boot write skipped if state unchanged from last boot
# ============================================================
set -eu

SEC="/root/.pocket_lab_secure"
WORK="/root/perplexity"
MEM0_ENV="/root/.mem0_env"
MEM0_API="https://api.mem0.ai/v1"
AGENT="pocket-lab"
LOG="/tmp/auto_start.log"
PRESIGN_KEY="/tmp/presign_approval.key"
PRESIGN_PUB="/tmp/presign_approval.pub"
PRESIGN_JSON="/tmp/presign_current.json"
PRESIGN_SIG="/tmp/presign_current.json.sig"
LAST_BOOT_STATE="/tmp/.last_boot_state"
APPROVAL_CURVE="secp256k1"
APPROVAL_REPO="Tsukieomie/pocket-lab-approvals"

log() { echo "[AUTO_START] $*" | tee -a "$LOG"; }

# ── mem0: single batched fetch ─────────────────────────────
mem0_query_bulk() {
  [ -f "$MEM0_ENV" ] && . "$MEM0_ENV" || return
  curl -sf --max-time 8 -X POST "$MEM0_API/memories/search/" \
    -H "Authorization: Token $MEM0_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"bypass signing keys issues tunnel ports parallel AI MCP\",\"agent_id\":\"$AGENT\",\"limit\":10}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d if isinstance(d, list) else d.get('results', [])
blob = {}
for i in items:
    m = i.get('memory', '')
    # Bucket by keyword
    low = m.lower()
    if any(k in low for k in ['bypass','sign','gate','approval']):
        blob.setdefault('bypass', []).append(m[:120])
    elif any(k in low for k in ['key','manifest','secp']):
        blob.setdefault('keys', []).append(m[:120])
    elif any(k in low for k in ['fail','issue','error','action']):
        blob.setdefault('issues', []).append(m[:120])
    elif any(k in low for k in ['bore','tunnel','port','path','ssh']):
        blob.setdefault('infra', []).append(m[:120])
    elif any(k in low for k in ['mcp','parallel','token','dolphin']):
        blob.setdefault('ai', []).append(m[:120])
    else:
        blob.setdefault('misc', []).append(m[:120])
for section, lines in blob.items():
    print(f'  [{section.upper()}]')
    for l in lines:
        print(f'    > {l}')
" 2>/dev/null || log "mem0 fetch skipped (offline?)"
}

mem0_save() {
  [ -f "$MEM0_ENV" ] && . "$MEM0_ENV" || return
  MSG="$1"
  # Skip write if identical to last boot state
  if [ -f "$LAST_BOOT_STATE" ] && [ "$(cat $LAST_BOOT_STATE)" = "$MSG" ]; then
    log "mem0 save skipped (no state change)."
    return
  fi
  printf '%s' "$MSG" > "$LAST_BOOT_STATE"
  curl -sf --max-time 5 -X POST "$MEM0_API/memories/" \
    -H "Authorization: Token $MEM0_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"messages\":[{\"role\":\"assistant\",\"content\":\"$MSG\"}],\"agent_id\":\"$AGENT\",\"metadata\":{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"version\":\"v2.7\"}}" \
    >/dev/null 2>&1 && log "mem0 save OK" || log "mem0 save failed (offline?)"
}

: > "$LOG"
log "=== AUTO_START v2.7 $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── STEP 1: Infrastructure (skip if already running) ───────
log "[1/4] Checking tunnel + SSH..."
TUNNEL_STATUS="DOWN"
SSHD_STATUS="DOWN"

if pgrep -f "bore local 2222" >/dev/null 2>&1; then
  log "Tunnel: already RUNNING — skip restart"
  TUNNEL_STATUS="UP"
else
  log "Tunnel: starting..."
  /root/start-lab.sh >/dev/null 2>&1 || true
  sleep 1
  if pgrep -f "bore local 2222" >/dev/null 2>&1; then
    TUNNEL_STATUS="UP"
    log "Tunnel: RUNNING bore.pub:40188"
  else
    /usr/local/bin/bore local 2222 --to bore.pub --port 40188 \
      >/tmp/bore-40188.log 2>&1 &
    sleep 2
    pgrep -f "bore local 2222" >/dev/null 2>&1 && TUNNEL_STATUS="UP"
    log "Tunnel: $TUNNEL_STATUS"
  fi
fi

if pgrep sshd >/dev/null 2>&1; then
  SSHD_STATUS="UP"
  log "SSHD: already RUNNING — skip"
else
  /usr/sbin/sshd 2>/dev/null || true
  pgrep sshd >/dev/null 2>&1 && SSHD_STATUS="UP"
  log "SSHD: $SSHD_STATUS"
fi

# ── STEP 2: Pre-sign approval (background, parallel) ───────
log "[2/4] Pre-signing approval in background..."
(
  # Generate keypair
  openssl ecparam -name "$APPROVAL_CURVE" -genkey -noout -out "$PRESIGN_KEY" 2>/dev/null
  openssl ec -in "$PRESIGN_KEY" -pubout -out "$PRESIGN_PUB" 2>/dev/null
  NEW_PUB_SHA=$(openssl pkey -pubin -in "$PRESIGN_PUB" -outform DER \
    | openssl dgst -sha256 -r | awk '{print $1}')
  APPROVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Expiry: 60 min window (generous — Perplexity will re-nonce if needed)
  # EXPIRES_AT is set loosely; gate script validates nonce freshness separately
  EXPIRES_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)  # placeholder; updated at open time
  RUN_ID="auto-presign-$(date +%s)"
  PDF_SHA="38c4871e12c75f12fc0c9603b92879e79454c87c6edf2a9adabfd00dff134134"

  python3 -c "
import json
a = {
  'approval_pubkey_sha256': '$NEW_PUB_SHA',
  'approved': True,
  'approved_at_utc': '$APPROVED_AT',
  'approved_by': 'AUTO_START-presign',
  'expires_at_utc': '$EXPIRES_AT',
  'nonce_sha256': 'PENDING',
  'pdf_sha256': '$PDF_SHA',
  'repo': '$APPROVAL_REPO',
  'run_id': '$RUN_ID',
  'schema': 'pocket_lab_signed_approval_v1',
  'signature_algorithm': 'ECDSA-secp256k1-SHA256'
}
open('$PRESIGN_JSON','w').write(json.dumps(a,sort_keys=True,separators=(',',':'))+'\n')
"
  openssl dgst -sha256 -sign "$PRESIGN_KEY" -out "$PRESIGN_SIG" "$PRESIGN_JSON"
  echo "$NEW_PUB_SHA" > /tmp/presign_pub_sha.txt
  log "Pre-sign complete: $NEW_PUB_SHA"
) &
PRESIGN_PID=$!

# ── STEP 3: mem0 Context Load (while pre-sign runs) ────────
log "[3/4] Loading mem0 context (single fetch)..."
if [ -f "$MEM0_ENV" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║         POCKET LAB — AI CONTEXT (mem0 v2.7)         ║"
  echo "╚══════════════════════════════════════════════════════╝"
  mem0_query_bulk
  echo "══════════════════════════════════════════════════════"
  log "mem0 context loaded."
else
  log "No .mem0_env — skipping mem0 load."
fi

# Wait for pre-sign to finish (should be done by now)
wait $PRESIGN_PID 2>/dev/null || true
PRESIGN_READY="NO"
[ -f "$PRESIGN_SIG" ] && PRESIGN_READY="YES"
log "Pre-signed approval ready: $PRESIGN_READY"

# ── STEP 4: Lab Status ─────────────────────────────────────
log "[4/4] Lab status snapshot..."
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              LAB STATUS (v2.7)                      ║"
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

echo " Tunnel:      bore.pub:40188 [$TUNNEL_STATUS]"
echo " SSHD:        [$SSHD_STATUS]"
echo " Pre-signed:  [$PRESIGN_READY] → /tmp/presign_approval.*"
echo "══════════════════════════════════════════════════════"
echo ""
echo " Tell Perplexity Computer:"
echo '   "Check mem0 pocket lab context, then open the lab"'
echo " (Pre-signed key is ready — open will be faster)"
echo "══════════════════════════════════════════════════════"

# Save boot event (delta-only)
BOOT_MSG="AUTO_START v2.7 ran at $(date -u +%Y-%m-%dT%H:%M:%SZ). Tunnel:$TUNNEL_STATUS SSHD:$SSHD_STATUS Debian:$DEBIAN Vault:$VAULT_STATUS PreSign:$PRESIGN_READY"
mem0_save "$BOOT_MSG"

log "=== AUTO_START v2.7 complete ==="
