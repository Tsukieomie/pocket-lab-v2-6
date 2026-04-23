#!/bin/sh
# ============================================================
# mem0.sh — Pocket Lab mem0 shared library (v2.8)
#
# Source this file to get mem0_query and mem0_save functions
# with structured JSON payloads and input validation.
#
# Usage:
#   . /root/perplexity/mem0.sh
#   mem0_query "bypass procedure signing gate"
#   mem0_save_event "TUNNEL_UP" '{"host":"10.0.0.1","port":"2222"}'
# ============================================================

MEM0_API="${MEM0_API:-https://api.mem0.ai/v1}"
MEM0_AGENT="${MEM0_AGENT:-pocket-lab}"
MEM0_VERSION="${MEM0_VERSION:-v2.8}"
MEM0_ENV_FILE="${MEM0_ENV_FILE:-/root/.mem0_env}"

# Load API key from env file if not already set
_mem0_load_key() {
  if [ -z "${MEM0_API_KEY:-}" ] && [ -f "$MEM0_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$MEM0_ENV_FILE"
  fi
  if [ -z "${MEM0_API_KEY:-}" ]; then
    echo "[mem0] WARNING: MEM0_API_KEY not set — mem0 operations skipped." >&2
    return 1
  fi
  return 0
}

# ── Single-query search ─────────────────────────────────────
# Usage: mem0_query "your query string" [limit]
mem0_query() {
  _mem0_load_key || return 0
  QUERY="$1"
  LIMIT="${2:-5}"
  curl -sf --max-time 8 -X POST "$MEM0_API/memories/search/" \
    -H "Authorization: Token $MEM0_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"$QUERY\",\"agent_id\":\"$MEM0_AGENT\",\"limit\":$LIMIT}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d if isinstance(d, list) else d.get('results', [])
for i in items:
    print(' >', i.get('memory', ''))
" 2>/dev/null || echo "[mem0] query failed (offline?)" >&2
}

# ── Batched multi-topic search ──────────────────────────────
# Returns bucketed output (bypass / keys / issues / infra / ai / misc)
mem0_query_bulk() {
  _mem0_load_key || return 0
  QUERY="${1:-bypass signing keys issues tunnel ports parallel AI MCP}"
  LIMIT="${2:-10}"
  curl -sf --max-time 8 -X POST "$MEM0_API/memories/search/" \
    -H "Authorization: Token $MEM0_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"$QUERY\",\"agent_id\":\"$MEM0_AGENT\",\"limit\":$LIMIT}" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
items = d if isinstance(d, list) else d.get('results', [])
blob = {}
for i in items:
    m = i.get('memory', '')
    low = m.lower()
    if any(k in low for k in ['bypass','sign','gate','approval']):
        blob.setdefault('bypass', []).append(m[:140])
    elif any(k in low for k in ['key','manifest','secp','fingerprint','pubkey']):
        blob.setdefault('keys', []).append(m[:140])
    elif any(k in low for k in ['fail','issue','error','action','expired']):
        blob.setdefault('issues', []).append(m[:140])
    elif any(k in low for k in ['bore','tunnel','port','path','ssh','wireguard','wg']):
        blob.setdefault('infra', []).append(m[:140])
    elif any(k in low for k in ['mcp','parallel','token','dolphin','perplexity','ai']):
        blob.setdefault('ai', []).append(m[:140])
    else:
        blob.setdefault('misc', []).append(m[:140])
for section, lines in blob.items():
    print(f'  [{section.upper()}]')
    for l in lines:
        print(f'    > {l}')
" 2>/dev/null || echo "[mem0] bulk query failed (offline?)" >&2
}

# ── Structured event save ───────────────────────────────────
# Usage: mem0_save_event "EVENT_TYPE" '{"key":"value"}' [skip_if_same_as_last]
# EVENT_TYPE examples: BOOT, TUNNEL_UP, VAULT_OPEN, VAULT_LOCK, KEY_ROTATED, ERROR
mem0_save_event() {
  _mem0_load_key || return 0
  EVENT_TYPE="$1"
  PAYLOAD="${2:-{}}"
  SKIP_DUPLICATE="${3:-true}"
  LAST_STATE_FILE="/tmp/.mem0_last_${EVENT_TYPE}"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  MSG="{\"event\":\"$EVENT_TYPE\",\"ts\":\"$TS\",\"version\":\"$MEM0_VERSION\",\"data\":$PAYLOAD}"

  # Delta-only: skip if identical to last save
  if [ "$SKIP_DUPLICATE" = "true" ] && [ -f "$LAST_STATE_FILE" ]; then
    if [ "$(cat "$LAST_STATE_FILE")" = "$PAYLOAD" ]; then
      echo "[mem0] $EVENT_TYPE save skipped (no state change)" >&2
      return 0
    fi
  fi
  printf '%s' "$PAYLOAD" > "$LAST_STATE_FILE"

  curl -sf --max-time 10 -X POST "$MEM0_API/memories/" \
    -H "Authorization: Token $MEM0_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"messages\":[{\"role\":\"assistant\",\"content\":\"$MSG\"}],\"agent_id\":\"$MEM0_AGENT\",\"metadata\":{\"event\":\"$EVENT_TYPE\",\"ts\":\"$TS\",\"version\":\"$MEM0_VERSION\"}}" \
    >/dev/null 2>&1 \
  && echo "[mem0] $EVENT_TYPE saved" \
  || echo "[mem0] $EVENT_TYPE save failed (offline?)" >&2
}

# ── Free-text save (legacy compat) ─────────────────────────
# Usage: mem0_save "any text"
mem0_save() {
  _mem0_load_key || return 0
  MSG="$1"
  LAST_STATE_FILE="/tmp/.mem0_last_text"
  if [ -f "$LAST_STATE_FILE" ] && [ "$(cat "$LAST_STATE_FILE")" = "$MSG" ]; then
    echo "[mem0] text save skipped (no state change)" >&2
    return 0
  fi
  printf '%s' "$MSG" > "$LAST_STATE_FILE"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  curl -sf --max-time 10 -X POST "$MEM0_API/memories/" \
    -H "Authorization: Token $MEM0_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"messages\":[{\"role\":\"assistant\",\"content\":\"$MSG\"}],\"agent_id\":\"$MEM0_AGENT\",\"metadata\":{\"ts\":\"$TS\",\"version\":\"$MEM0_VERSION\"}}" \
    >/dev/null 2>&1 \
  && echo "[mem0] saved" \
  || echo "[mem0] save failed (offline?)" >&2
}

# ── Key rotation logger ─────────────────────────────────────
# Usage: mem0_log_rotation "old_sha" "new_sha" "actor" "reason"
mem0_log_rotation() {
  _mem0_load_key || return 0
  OLD_SHA="$1"
  NEW_SHA="$2"
  ACTOR="${3:-unknown}"
  REASON="${4:-unspecified}"
  PAYLOAD="{\"old_pubkey_sha256\":\"$OLD_SHA\",\"new_pubkey_sha256\":\"$NEW_SHA\",\"actor\":\"$ACTOR\",\"reason\":\"$REASON\"}"
  mem0_save_event "KEY_ROTATED" "$PAYLOAD" "false"
}
