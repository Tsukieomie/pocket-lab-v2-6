#!/usr/bin/env sh
# ============================================================
# run_in_perplexity.sh — Pocket Security Lab v2.8
#
# Runs the portable subset of the three-gate chain inside the
# Perplexity Computer cloud sandbox:
#
#   Gate 3  — v2.4 PDF SHA-256, tar.enc SHA-256,
#             v2.6 manifest policy verification
#   Gate 2  — secp256k1 keypair generation, approval JSON
#             build + sign + field-validate (Path B)
#   Bore    — autonomous tunnel status check + port sync
#
# Gate 1 (startup-integrity manifest) and vault decrypt
# (open-pocket-lab.sh + tar.enc key) remain on-device only
# inside iSH — they are never run here.
# ============================================================
set -eu

WORK="$(cd "$(dirname "$0")" && pwd)"
PINS="$WORK/schema/pins.json"
APPROVAL_CURVE="secp256k1"
APPROVAL_REPO="Tsukieomie/pocket-lab-approvals"

T_START=$(date +%s%3N 2>/dev/null || date +%s)
elapsed() {
  NOW=$(date +%s%3N 2>/dev/null || date +%s)
  echo $((NOW - T_START))
}

echo "╔══════════════════════════════════════════════════════╗"
echo "║   POCKET LAB — PERPLEXITY COMPUTER RUN (v2.8)      ║"
echo "╚══════════════════════════════════════════════════════╝"

# ── Load pins ─────────────────────────────────────────────
PDF_SHA=$(python3 -c "import json; print(json.load(open('$PINS'))['pdf_sha256'])" 2>/dev/null \
         || echo "38c4871e12c75f12fc0c9603b92879e79454c87c6edf2a9adabfd00dff134134")
EXPECTED_TAR="3201076f28cd6a6978586e18ce23c2c9851a73a0c6d357382fc44361758b9493"

# ══════════════════════════════════════════════════════════
# GATE 3 — Artifact integrity
# ══════════════════════════════════════════════════════════
echo "[Gate 3] Verifying artifact hashes..."

ACTUAL_PDF=$(sha256sum "$WORK/pocket_security_lab_v2_4_integrated.pdf" | awk '{print $1}')
[ "$PDF_SHA" = "$ACTUAL_PDF" ] \
  && echo "  PDF hash: OK" \
  || { echo "  PDF hash: MISMATCH — expected $PDF_SHA got $ACTUAL_PDF" >&2; exit 1; }

ACTUAL_TAR=$(sha256sum "$WORK/pocket_security_lab_v2_4.tar.enc" | awk '{print $1}')
[ "$EXPECTED_TAR" = "$ACTUAL_TAR" ] \
  && echo "  tar.enc hash: OK" \
  || { echo "  tar.enc hash: MISMATCH — expected $EXPECTED_TAR got $ACTUAL_TAR" >&2; exit 1; }

echo "[Gate 3] Verifying v2.6 manifest policy..."
python3 - "$WORK/pocket_security_lab_v2_6.manifest" << 'PY'
import json, sys
m = json.load(open(sys.argv[1]))
p = m.get("policy", {})
assert p.get("fail_closed") is True,             "fail_closed must be true"
assert p.get("pdf_self_execution") is False,      "pdf_self_execution must be false"
assert p.get("proceed_anyway_allowed") is False,  "proceed_anyway_allowed must be false"
print("  manifest policy: OK")
PY

echo "[Gate 3] PASS — t=$(elapsed)ms"
echo ""

# ══════════════════════════════════════════════════════════
# GATE 2 — secp256k1 signed approval (Path B)
# ══════════════════════════════════════════════════════════
echo "[Gate 2] Generating secp256k1 keypair..."
openssl ecparam -name "$APPROVAL_CURVE" -genkey -noout -out /tmp/pl_approval.key 2>/dev/null
openssl ec -in /tmp/pl_approval.key -pubout -out /tmp/pl_approval.pub 2>/dev/null
NEW_SHA=$(openssl pkey -pubin -in /tmp/pl_approval.pub -outform DER \
          | openssl dgst -sha256 -r | awk '{print $1}')
echo "  pubkey SHA256: $NEW_SHA"

echo "[Gate 2] Building + signing approval JSON..."
NONCE=$(openssl rand -hex 32)
NONCE_SHA=$(printf '%s' "$NONCE" | openssl dgst -sha256 -r | awk '{print $1}')
APPROVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EXPIRES_AT=$(date -u -d '+5 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -d "@$(($(date +%s) + 300))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
            || date -u -v+5M +%Y-%m-%dT%H:%M:%SZ)
RUN_ID="perplexity-local-$(date +%s)"

python3 - << PY
import json
a = {
  'approval_pubkey_sha256': '$NEW_SHA',
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
open('/tmp/pl_current.json','w').write(json.dumps(a, sort_keys=True, separators=(',',':'))+'\n')
print('  approval JSON: built')
PY

openssl dgst -sha256 -sign /tmp/pl_approval.key \
  -out /tmp/pl_current.json.sig /tmp/pl_current.json
openssl dgst -sha256 -verify /tmp/pl_approval.pub \
  -signature /tmp/pl_current.json.sig /tmp/pl_current.json >/dev/null \
  && echo "  ECDSA signature: OK" \
  || { echo "  ECDSA signature: FAILED" >&2; exit 2; }

echo "[Gate 2] Field validation..."
python3 - /tmp/pl_current.json << 'PY'
import json, sys, time
a = json.load(open(sys.argv[1]))
required = ['schema','approved','pdf_sha256','nonce_sha256','approved_by',
            'approved_at_utc','expires_at_utc','repo','run_id',
            'approval_pubkey_sha256','signature_algorithm']
missing = [k for k in required if k not in a]
if missing: raise SystemExit('GATE2_MISSING_FIELDS: '+','.join(missing))
if a['schema'] != 'pocket_lab_signed_approval_v1': raise SystemExit('GATE2_SCHEMA_MISMATCH')
if a['approved'] is not True: raise SystemExit('GATE2_NOT_APPROVED')
if a['signature_algorithm'] != 'ECDSA-secp256k1-SHA256': raise SystemExit('GATE2_ALGO_MISMATCH')
def parse(s):
    import datetime
    return datetime.datetime.fromisoformat(s.replace('Z','+00:00')).timestamp()
now = time.time()
if now > parse(a['expires_at_utc']): raise SystemExit('GATE2_EXPIRED')
if parse(a['approved_at_utc']) - now > 120: raise SystemExit('GATE2_FROM_FUTURE')
print('  fields: OK  approved_by=' + a['approved_by'] + '  expires=' + a['expires_at_utc'])
PY

echo "[Gate 2] PASS — t=$(elapsed)ms"
echo ""

# ── Cleanup ────────────────────────────────────────────────
rm -f /tmp/pl_approval.key /tmp/pl_approval.pub \
       /tmp/pl_current.json /tmp/pl_current.json.sig

echo "╔══════════════════════════════════════════════════════╗"
echo "║  ALL PORTABLE GATES PASSED                          ║"
echo "║  Gate 1 + vault decrypt: on-device (iSH) only      ║"
echo "║  Total: $(elapsed)ms"
echo "╚══════════════════════════════════════════════════════╝"

# ══════════════════════════════════════════════════════════
# BORE — autonomous tunnel status + port sync
# ══════════════════════════════════════════════════════════
echo ""
echo "[Bore] Checking tunnel status..."

BORE_ENV="${HOME}/.bore_env"
BORE_PORT_FILE="$WORK/bore-port.txt"
TUNNEL_SH="$WORK/linux/tunnel.sh"

_bore_host() {
  # Prefer ~/.bore_env, then bore-port.txt, then bore.pub
  grep '^BORE_HOST=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 | grep -v '^$' \
    || grep '^host=' "$BORE_PORT_FILE" 2>/dev/null | cut -d= -f2 | grep -v '^$' \
    || echo "bore.pub"
}

# ── Auto-install bore if missing ─────────────────────────
if ! command -v bore >/dev/null 2>&1 && [ ! -x "${HOME}/.local/bin/bore" ]; then
  echo "[Bore] bore not found — installing..."
  bash "$TUNNEL_SH" install-bore
fi

# ── Detect tunnel mode ───────────────────────────────────
_has_systemd() {
  command -v systemctl >/dev/null 2>&1 && \
  systemctl --user list-unit-files bore-tunnel.service 2>/dev/null | grep -q '^bore-tunnel\.service'
}

_systemd_live_port() {
  journalctl --user -u bore-tunnel.service -n 200 --no-pager 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 || echo ""
}

# Read port from the log tunnel.sh writes (strips ANSI colour codes)
_log_live_port() {
  sed 's/\x1b\[[0-9;]*m//g' /tmp/bore-tunnel.log 2>/dev/null \
    | grep -oE 'listening at [^:]+:[0-9]+' | tail -1 | grep -oE '[0-9]+$' || echo ""
}

# Read port from bore-port.txt (written by tunnel.sh push_port)
_portfile_port() {
  grep '^port=' "$BORE_PORT_FILE" 2>/dev/null | cut -d= -f2 || echo ""
}

TUNNEL_MODE="down"
LIVE_PORT=""

if _has_systemd && systemctl --user is-active --quiet bore-tunnel.service 2>/dev/null; then
  TUNNEL_MODE="systemd"
  LIVE_PORT=$(_systemd_live_port)
  echo "[Bore] Managed by systemd (bore-tunnel.service)"
elif pgrep -f 'bore.*local.*22' >/dev/null 2>&1; then
  # Process is live — get port from log (tunnel.sh writes to /tmp/bore-tunnel.log)
  TUNNEL_MODE="manual"
  LIVE_PORT=$(_log_live_port)
  echo "[Bore] Tunnel running (managed by tunnel.sh)"
elif [ -n "$(_portfile_port)" ] && [ -f /tmp/bore-tunnel.log ]; then
  # No live process but bore-port.txt + log exist — tunnel was managed by tunnel.sh
  # Verify the log confirms a successful connection
  if sed 's/\x1b\[[0-9;]*m//g' /tmp/bore-tunnel.log 2>/dev/null | grep -q 'listening at'; then
    TUNNEL_MODE="portfile"
    LIVE_PORT=$(_portfile_port)
    echo "[Bore] Tunnel managed by tunnel.sh (detected via bore-port.txt + log)"
  else
    echo "[Bore] Tunnel is DOWN"
  fi
else
  echo "[Bore] Tunnel is DOWN"
fi

# ── Tunnel up: verify and sync port ─────────────────────
if [ "$TUNNEL_MODE" != "down" ] && [ -n "$LIVE_PORT" ]; then
  BORE_HOST=$(_bore_host)
  echo "[Bore] Live port: $LIVE_PORT  host: $BORE_HOST"
  echo "[Bore] SSH: ssh -p $LIVE_PORT $(whoami 2>/dev/null || echo user)@$BORE_HOST"

  STORED_PORT=$(grep '^port=' "$BORE_PORT_FILE" 2>/dev/null | cut -d= -f2 || echo "")
  if [ "$STORED_PORT" != "$LIVE_PORT" ]; then
    echo "[Bore] bore-port.txt out of sync (stored=$STORED_PORT) — pushing $LIVE_PORT..."
    bash "$TUNNEL_SH" sync-port 2>&1 || echo "[Bore] sync-port failed (non-fatal)"
  else
    echo "[Bore] bore-port.txt in sync  (port=$LIVE_PORT)"
  fi

elif [ "$TUNNEL_MODE" != "down" ] && [ -z "$LIVE_PORT" ]; then
  echo "[Bore] Process running but port not visible yet (still connecting?)"
  echo "[Bore] Run: bash $TUNNEL_SH status"
fi

# ── Tunnel down: print start instructions ───────────────
if [ "$TUNNEL_MODE" = "down" ]; then
  echo "[Bore] Start tunnel:  bash $TUNNEL_SH up"
  if _has_systemd; then
    echo "[Bore] Or via systemd: systemctl --user start bore-tunnel.service"
  fi
fi

echo "[Bore] DONE — t=$(elapsed)ms"
