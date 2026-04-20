#!/bin/sh
# ============================================================
# AUTO_START.sh — Pocket Security Lab Unified Startup
# Runs automatically on every iSH boot via .profile / .ashrc
#
# Order of operations:
#   1. Tunnel + SSH (infrastructure)
#   2. mem0 context load (AI orientation)
#   3. MCP parallel AI skill summary (fast execution mode)
#   4. Lab status snapshot
# ============================================================
set -eu

SEC="/root/.pocket_lab_secure"
WORK="/root/perplexity"
MEM0_ENV="/root/.mem0_env"
MEM0_API="https://api.mem0.ai/v1"
AGENT="pocket-lab"
LOG="/tmp/auto_start.log"

# ── helpers ────────────────────────────────────────────────
log() { echo "[AUTO_START] $*" | tee -a "$LOG"; }
mem0_query() {
  QUERY="$1"
  [ -f "$MEM0_ENV" ] && . "$MEM0_ENV" || return
  curl -sf --max-time 5 -X POST "$MEM0_API/memories/search/" \
    -H "Authorization: Token $MEM0_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"$QUERY\",\"agent_id\":\"$AGENT\",\"limit\":2}" \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
items=d if isinstance(d,list) else d.get('results',[])
for i in items: print(' >', i.get('memory','')[:100])
" 2>/dev/null || true
}
mem0_save() {
  [ -f "$MEM0_ENV" ] && . "$MEM0_ENV" || return
  curl -sf --max-time 5 -X POST "$MEM0_API/memories/" \
    -H "Authorization: Token $MEM0_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"messages\":[{\"role\":\"assistant\",\"content\":\"$1\"}],\"agent_id\":\"$AGENT\",\"metadata\":{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" \
    >/dev/null 2>&1 && log "mem0 save OK" || log "mem0 save failed (offline?)"
}

: > "$LOG"
log "=== AUTO_START $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# ── STEP 1: Infrastructure ─────────────────────────────────
log "[1/4] Starting tunnel + SSH..."
/root/start-lab.sh >/dev/null 2>&1 || true
sleep 1
if pgrep -f "bore local 2222" >/dev/null 2>&1; then
  log "Tunnel: RUNNING bore.pub:40188"
else
  log "Tunnel: DOWN — retrying..."
  /usr/local/bin/bore local 2222 --to bore.pub --port 40188 \
    >/tmp/bore-40188.log 2>&1 &
  sleep 2
fi
pgrep sshd >/dev/null 2>&1 && log "SSHD: RUNNING" || log "SSHD: DOWN"

# ── STEP 2: mem0 Context Load ──────────────────────────────
log "[2/4] Loading mem0 context..."
if [ -f "$MEM0_ENV" ]; then
  . "$MEM0_ENV"
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║         POCKET LAB — AI CONTEXT (mem0)              ║"
  echo "╚══════════════════════════════════════════════════════╝"

  echo "▸ BYPASS / SIGNING:"
  mem0_query "bypass procedure signing gate approval"

  echo "▸ KEY INVENTORY:"
  mem0_query "key inventory manifest signing which key"

  echo "▸ KNOWN ISSUES:"
  mem0_query "known issues GitHub Actions failures"

  echo "▸ INFRASTRUCTURE:"
  mem0_query "infrastructure ports tunnel bore paths"

  echo "▸ PARALLEL AI / MCP:"
  mem0_query "parallel AI MCP dolphin skill token optimization"

  echo "══════════════════════════════════════════════════════"
  log "mem0 context loaded."
else
  log "No .mem0_env — skipping mem0 load."
fi

# ── STEP 3: Parallel AI / MCP Skill Summary ────────────────
log "[3/4] Parallel AI skill — MCP-first mode active."
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║       PARALLEL AI SKILL (MCP-FIRST MODE)            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo " Goal: 60-75% token reduction via direct tool execution"
echo ""
echo " GitHub ops   → gh api / gh workflow run"
echo " File ops     → direct SSH cat/write (no descriptions)"
echo " Web fetch    → curl -sf (no interpretation overhead)"
echo " State track  → mem0_agent_save / mem0_agent_search"
echo " AI queries   → /root/perplexity/run.sh (iSH local)"
echo ""
echo " claude-dolphin-agent repo:"
echo "   Tsukieomie/claude-dolphin-agent"
echo "   Priority 1: github + memory + fetch + filesystem MCP"
echo "══════════════════════════════════════════════════════"

# ── STEP 4: Lab Status ─────────────────────────────────────
log "[4/4] Lab status snapshot..."
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              LAB STATUS                             ║"
echo "╚══════════════════════════════════════════════════════╝"
TAMPER=$("$SEC/tamper-alert.sh" check 2>&1 || echo "TAMPER_UNKNOWN")
echo " Tamper:  $TAMPER"

VAULT_STATUS="LOCKED"
ls /tmp/pocket_security_lab_v2_3_unlocked/*.pdf >/dev/null 2>&1 \
  && VAULT_STATUS="OPEN (auto-locks in 5 min)"
echo " Vault:   $VAULT_STATUS"

DEBIAN="NOT MOUNTED"
[ -f /mnt/debian/bin/sh ] && DEBIAN="MOUNTED (/mnt/debian)"
echo " Debian:  $DEBIAN"

echo " Tunnel:  bore.pub:40188"
echo " SSH pw:  SunTzu612 (use key auth when possible)"
echo "══════════════════════════════════════════════════════"
echo ""
echo " Say to Perplexity Computer:"
echo '   "Check mem0 pocket lab context, then open the lab"'
echo "══════════════════════════════════════════════════════"

# Save session boot event to mem0
mem0_save "AUTO_START ran at $(date -u +%Y-%m-%dT%H:%M:%SZ). Tunnel: $(pgrep -f 'bore local 2222' >/dev/null 2>&1 && echo UP || echo DOWN). Debian: $DEBIAN. Vault: $VAULT_STATUS."

log "=== AUTO_START complete ==="
