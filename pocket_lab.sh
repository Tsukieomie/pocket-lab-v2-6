#!/bin/sh
# ============================================================
# pocket_lab.sh — Pocket Security Lab v2.8 Unified Entrypoint
#
# Single command to control the entire lab.
#
# Usage:
#   pocket_lab.sh open          — full 3-gate open (safe, verified)
#   pocket_lab.sh lock          — securely wipe plaintext from /tmp
#   pocket_lab.sh status        — full system status snapshot
#   pocket_lab.sh verify        — run all integrity checks without opening
#   pocket_lab.sh tunnel up     — start bore tunnel (WireGuard-native)
#   pocket_lab.sh tunnel down   — kill bore tunnel
#   pocket_lab.sh tunnel status — show tunnel state
#   pocket_lab.sh mem0 sync     — query + display all mem0 context
#   pocket_lab.sh mem0 save     — save current state to mem0
#   pocket_lab.sh rotate-key    — generate new approval keypair + push
#   pocket_lab.sh boot          — full AUTO_START sequence
#   pocket_lab.sh help          — show this message
# ============================================================
set -eu

WORK="/root/perplexity"
SEC="/root/.pocket_lab_secure"
PINS="$WORK/schema/pins.json"
BORE_ENV="/root/.bore_env"

# Load mem0 library
if [ -f "$WORK/mem0.sh" ]; then
  # shellcheck disable=SC1090
  . "$WORK/mem0.sh"
fi

# Load pins
_pdf_sha() {
  python3 -c "import json; print(json.load(open('$PINS'))['pdf_sha256'])" 2>/dev/null \
    || echo "38c4871e12c75f12fc0c9603b92879e79454c87c6edf2a9adabfd00dff134134"
}

_bore_host() {
  grep '^BORE_HOST=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || echo "bore.pub"
}

_bore_port() {
  grep '^BORE_PORT=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || echo "40188"
}

# ────────────────────────────────────────────────────────────
CMD="${1:-help}"
SUB="${2:-}"

case "$CMD" in

  open)
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║           POCKET LAB — OPENING (v2.8)               ║"
    echo "╚══════════════════════════════════════════════════════╝"
    mem0_save_event "VAULT_OPEN_ATTEMPT" '{"gate":"starting"}' false 2>/dev/null || true
    exec "$WORK/OPEN_POCKET_LAB_V2_6.sh"
    ;;

  lock)
    echo "[lock] Wiping plaintext vault..."
    UNLOCK_DIR="/tmp/pocket_security_lab_v2_3_unlocked"
    if [ -d "$UNLOCK_DIR" ]; then
      find "$UNLOCK_DIR" -type f -exec shred -uz {} \; 2>/dev/null || rm -rf "$UNLOCK_DIR"
      rm -rf "$UNLOCK_DIR"
      echo "[lock] Vault wiped: $UNLOCK_DIR"
      mem0_save_event "VAULT_LOCKED" '{}' false 2>/dev/null || true
    else
      echo "[lock] Already locked (no plaintext present)."
    fi
    ;;

  status)
    sh "$WORK/STATUS_V2_6.sh"
    ;;

  verify)
    echo "[verify] Running full integrity chain..."
    sh "$WORK/verify_pocket_lab_v2_6.sh"
    ;;

  tunnel)
    case "$SUB" in
      up)
        if pgrep -f "bore local 2222" >/dev/null 2>&1; then
          echo "[tunnel] Already running."
        else
          BORE_HOST=$(_bore_host)
          BORE_PORT=$(_bore_port)
          BORE_SECRET=$(grep '^BORE_SECRET=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || echo "")
          SECRET_ARG=""
          [ -n "$BORE_SECRET" ] && SECRET_ARG="--secret $BORE_SECRET"
          # shellcheck disable=SC2086
          /usr/local/bin/bore local 2222 --to "$BORE_HOST" --port "$BORE_PORT" $SECRET_ARG \
            >/tmp/bore-tunnel.log 2>&1 &
          sleep 2
          pgrep -f "bore local 2222" >/dev/null 2>&1 \
            && echo "[tunnel] UP → $BORE_HOST:$BORE_PORT" \
            || echo "[tunnel] FAILED — check /tmp/bore-tunnel.log"
          mem0_save_event "TUNNEL_UP" "{\"host\":\"$BORE_HOST\",\"port\":\"$BORE_PORT\"}" 2>/dev/null || true
        fi
        ;;
      down)
        pkill -f "bore local 2222" 2>/dev/null && echo "[tunnel] Stopped." || echo "[tunnel] Not running."
        mem0_save_event "TUNNEL_DOWN" '{}' false 2>/dev/null || true
        ;;
      status|"")
        if pgrep -f "bore local 2222" >/dev/null 2>&1; then
          echo "[tunnel] RUNNING → $(_bore_host):$(_bore_port)"
        else
          echo "[tunnel] DOWN"
        fi
        ;;
      *)
        echo "Usage: $0 tunnel [up|down|status]" >&2; exit 2 ;;
    esac
    ;;

  mem0)
    case "$SUB" in
      sync|"")
        echo "╔══════════════════════════════════════════════════════╗"
        echo "║           POCKET LAB — MEM0 CONTEXT                 ║"
        echo "╚══════════════════════════════════════════════════════╝"
        mem0_query_bulk
        echo "══════════════════════════════════════════════════════"
        ;;
      save)
        BORE_HOST=$(_bore_host); BORE_PORT=$(_bore_port)
        VAULT="LOCKED"
        ls /tmp/pocket_security_lab_v2_3_unlocked/*.pdf >/dev/null 2>&1 && VAULT="OPEN"
        TUNNEL="DOWN"
        pgrep -f "bore local 2222" >/dev/null 2>&1 && TUNNEL="UP"
        mem0_save_event "STATUS_SNAPSHOT" \
          "{\"vault\":\"$VAULT\",\"tunnel\":\"$TUNNEL\",\"host\":\"$BORE_HOST\",\"port\":\"$BORE_PORT\"}" \
          false
        ;;
      *)
        echo "Usage: $0 mem0 [sync|save]" >&2; exit 2 ;;
    esac
    ;;

  rotate-key)
    echo "[rotate-key] Generating fresh secp256k1 approval keypair..."
    NEW_KEY="/tmp/rotate_approval.key"
    NEW_PUB="/tmp/rotate_approval.pub"
    openssl ecparam -name secp256k1 -genkey -noout -out "$NEW_KEY"
    openssl ec -in "$NEW_KEY" -pubout -out "$NEW_PUB" 2>/dev/null
    OLD_SHA=$(python3 -c "import json; print(json.load(open('$PINS'))['approval_pubkey_sha256'])" 2>/dev/null || echo "unknown")
    NEW_SHA=$(openssl pkey -pubin -in "$NEW_PUB" -outform DER | openssl dgst -sha256 -r | awk '{print $1}')
    echo "[rotate-key] Old pubkey: $OLD_SHA"
    echo "[rotate-key] New pubkey: $NEW_SHA"
    echo ""
    echo "Next steps:"
    echo "  1. Push $NEW_PUB to pocket-lab-approvals/keys/pocket_lab_github_approval_secp256k1.pub"
    echo "  2. Update schema/pins.json approval_pubkey_sha256 = $NEW_SHA"
    echo "  3. Update device: cp $NEW_PUB $SEC/pocket_lab_github_approval_secp256k1.pub"
    echo "  4. Append to approvals/.rotation-history"
    mem0_log_rotation "$OLD_SHA" "$NEW_SHA" "manual-rotate" "operator-initiated" 2>/dev/null || true
    ;;

  boot)
    exec sh "$WORK/AUTO_START.sh"
    ;;

  help|--help|-h|"")
    echo ""
    echo "  Pocket Security Lab v2.8 — Unified Entrypoint"
    echo ""
    echo "  Commands:"
    echo "    open           Full 3-gate open (Gate1: integrity, Gate2: signed approval, Gate3: verify)"
    echo "    lock           Securely wipe plaintext vault from /tmp"
    echo "    status         System status (tunnel, vault, tamper, signing)"
    echo "    verify         Run all integrity checks without opening"
    echo "    tunnel up      Start bore tunnel (WireGuard-native, bore.pub fallback)"
    echo "    tunnel down    Kill bore tunnel"
    echo "    tunnel status  Show tunnel state"
    echo "    mem0 sync      Query and display all mem0 context (bucketed)"
    echo "    mem0 save      Save current state snapshot to mem0"
    echo "    rotate-key     Generate fresh approval keypair + rotation guidance"
    echo "    boot           Run full AUTO_START.sh boot sequence"
    echo "    help           Show this message"
    echo ""
    echo "  Config files:"
    echo "    /root/.bore_env          — BORE_HOST, BORE_PORT, BORE_SECRET, SSH_KEY_PATH"
    echo "    /root/.mem0_env          — MEM0_API_KEY"
    echo "    $WORK/schema/pins.json   — pdf_sha256, pubkey fingerprint, TTL policy"
    echo ""
    ;;

  *)
    echo "Unknown command: $CMD" >&2
    echo "Run: $0 help" >&2
    exit 2
    ;;
esac
