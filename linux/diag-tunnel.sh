#!/bin/bash
# diag-tunnel.sh — Pocket Lab tunnel diagnostics + network reachability
# Writes structured JSON log to ~/.pocket-lab-diag.log (appended, persists across reboots)
set -u

CF_BIN="${HOME}/.local/bin/cloudflared"
TUNNEL_TOKEN="eyJhIjoiZjdjOGUxN2U0N2IyYmE2MTIyNDg1MGQ3YmI5ODkyN2YiLCJ0IjoiODEzMmVjODQtODcyNC00YmUxLWE1ODgtOWU2MmVhNmMzNTYyIiwicyI6Ik9EYzFPR1JrWTJSaFl6TmxZV1JrWVdJMlpUSTRNalUxTkdNME5XVm1NVE0wWlRsaE1tWTFabVE0WTJZNE5tVXhOakZpTTJSak1tUXhaR016TkdVNVpBPT0ifQ=="
DIAG_LOG="${HOME}/.pocket-lab-diag.log"

# ── helpers ───────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}   $*${NC}"; }
fail() { echo -e "${RED}   $*${NC}"; }
warn() { echo -e "${YELLOW}  ! $*${NC}"; }

# JSON log builder — accumulated in memory, flushed at end
_J_ENTRIES=""
_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
RUN_TS=$(_ts)
HOSTNAME_VAL=$(hostname)
KERNEL=$(uname -r)
NET_IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1 || echo "unknown")

# j_add key value status — appends to _J_ENTRIES
j_add() {
  local KEY="$1" VAL="$2" ST="$3"
  # escape double quotes in value
  VAL=$(printf '%s' "$VAL" | sed 's/\\/\\\\/g; s/"/\\"/g')
  _J_ENTRIES="${_J_ENTRIES}{\"key\":\"${KEY}\",\"value\":\"${VAL}\",\"status\":\"${ST}\",\"ts\":\"$(_ts)\"},"
}

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Pocket Lab — Tunnel Diagnostics                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo "  host: $HOSTNAME_VAL  kernel: $KERNEL  iface: $NET_IFACE"
echo "  log:  $DIAG_LOG"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. NETWORK REACHABILITY
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "━━━ [1/4] Network Reachability ━━━"

ANY_443_OPEN=false
_tcp_check() {
  local IP="$1" PORT="$2" LABEL="${3:-}"
  local KEY="tcp_${IP}_${PORT}"
  [ -n "$LABEL" ] && KEY="tcp_${LABEL}_${PORT}"
  if timeout 4 bash -c "echo >/dev/tcp/${IP}/${PORT}" 2>/dev/null; then
    ok "TCP ${IP}:${PORT}${LABEL:+ ($LABEL)} — OPEN"
    j_add "$KEY" "${IP}:${PORT}" "open"
    return 0
  else
    fail "TCP ${IP}:${PORT}${LABEL:+ ($LABEL)} — BLOCKED"
    j_add "$KEY" "${IP}:${PORT}" "blocked"
    return 1
  fi
}

# Cloudflare edge IPs
for IP in 198.41.192.67 198.41.200.193; do
  _tcp_check "$IP" 443  && ANY_443_OPEN=true
  _tcp_check "$IP" 7844
done

echo ""

# DNS + argotunnel
if EDGE_IP=$(python3 -c "import socket; print(socket.getaddrinfo('region1.v2.argotunnel.com',443,socket.AF_INET)[0][4][0])" 2>/dev/null); then
  ok "DNS region1.v2.argotunnel.com → $EDGE_IP"
  j_add "dns_argotunnel" "$EDGE_IP" "ok"
  _tcp_check "$EDGE_IP" 443 "argotunnel" && ANY_443_OPEN=true
else
  fail "DNS region1.v2.argotunnel.com — failed"
  j_add "dns_argotunnel" "FAILED" "error"
fi

echo ""
_tcp_check "1.1.1.1" 443 "cloudflare-dns" && ANY_443_OPEN=true

if $ANY_443_OPEN; then
  ok "Port 443 OPEN — http2 tunnel viable"
  j_add "port_443_verdict" "open" "ok"
else
  fail "Port 443 BLOCKED — tunnel cannot connect"
  j_add "port_443_verdict" "blocked" "fail"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. CLOUDFLARED BINARY
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "━━━ [2/4] cloudflared Binary ━━━"
if [ -x "$CF_BIN" ]; then
  CF_VER="$($CF_BIN --version 2>&1 | head -1)"
  ok "$CF_BIN — $CF_VER"
  j_add "cloudflared_binary" "$CF_VER" "ok"
else
  fail "cloudflared not found at $CF_BIN"
  j_add "cloudflared_binary" "NOT_FOUND" "fail"
  warn "Install: curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o $CF_BIN && chmod +x $CF_BIN"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. SERVICE JOURNAL
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "━━━ [3/4] cloudflared-tunnel.service Journal (last 30 lines) ━━━"
JOURNAL=$(journalctl --user -u cloudflared-tunnel.service -n 30 --no-pager 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
echo "$JOURNAL"

# Extract key signals from journal
CF_CONNECTED=false
CF_ERR=""
if echo "$JOURNAL" | grep -q "Connection registered"; then
  CF_CONNECTED=true
  j_add "service_connection" "registered" "ok"
elif echo "$JOURNAL" | grep -q "quic.*operation not permitted"; then
  CF_ERR="quic_blocked"
  j_add "service_connection" "quic_blocked" "fail"
elif echo "$JOURNAL" | grep -q "http2.*error\|http2.*fail"; then
  CF_ERR="http2_error"
  j_add "service_connection" "http2_error" "fail"
elif echo "$JOURNAL" | grep -qiE "error|fail|ERR"; then
  CF_ERR=$(echo "$JOURNAL" | grep -iE "ERR|error" | tail -1 | sed 's/.*ERR //' | cut -c1-120)
  j_add "service_connection" "$CF_ERR" "fail"
else
  j_add "service_connection" "unknown" "warn"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. LIVE RUN TEST
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "━━━ [4/4] Live cloudflared Run (8s capture) ━━━"
echo "    protocol=http2  edge-ip-version=4"
echo ""

LIVE_LOG=$(mktemp)
$CF_BIN tunnel --no-autoupdate --protocol http2 --edge-ip-version 4   run --token "$TUNNEL_TOKEN" > "$LIVE_LOG" 2>&1 &
CF_PID=$!
sleep 8
kill $CF_PID 2>/dev/null || true
wait $CF_PID 2>/dev/null || true

LIVE_OUT=$(cat "$LIVE_LOG")
rm -f "$LIVE_LOG"
echo "$LIVE_OUT"

# Extract verdict from live run
LIVE_STATUS="unknown"
if echo "$LIVE_OUT" | grep -q "Connection registered"; then
  LIVE_STATUS="connected"
  ok "Live run: CONNECTED"
elif echo "$LIVE_OUT" | grep -q "Initial protocol http2"; then
  LIVE_STATUS="http2_started_no_conn"
  warn "Live run: http2 started but no connection registered in 8s"
else
  LIVE_STATUS="failed"
  fail "Live run: failed to connect"
fi
# Capture last error line
LIVE_ERR=$(echo "$LIVE_OUT" | grep -iE "ERR|error" | tail -1 | sed 's/.*ERR //' | cut -c1-120 || echo "")
j_add "live_run_status" "$LIVE_STATUS" "$([ $LIVE_STATUS = connected ] && echo ok || echo fail)"
[ -n "$LIVE_ERR" ] && j_add "live_run_last_error" "$LIVE_ERR" "info"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# FLUSH JSON LOG
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Remove trailing comma and wrap in object
_J_ENTRIES="${_J_ENTRIES%,}"

python3 - << PY
import json, os

log_path = os.path.expanduser("~/.pocket-lab-diag.log")
entry = {
    "run_at": "",
    "host": "",
    "kernel": "",
    "net_iface": "",
    "results": []
}

# Parse shell-built entries
raw = """"""
for part in raw.split("},{"):
    part = part.strip().strip("{}")
    try:
        obj = json.loads("{" + part + "}")
        entry["results"].append(obj)
    except Exception:
        pass

# Read existing log (NDJSON — one JSON object per line)
existing = []
if os.path.exists(log_path):
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    existing.append(json.loads(line))
                except Exception:
                    pass

# Keep last 50 runs max
existing.append(entry)
existing = existing[-50:]

with open(log_path, "w") as f:
    for e in existing:
        f.write(json.dumps(e) + "\n")

print(f"\n  JSON log written → {log_path}  ({len(existing)} runs total)")

# Print summary of this run
fails = [r for r in entry["results"] if r.get("status") in ("fail","error","blocked")]
if fails:
    print(f"  FAILURES ({len(fails)}):")
    for r in fails:
        print(f"    [{r['status']}] {r['key']}: {r['value']}")
else:
    print("  No failures detected.")
PY

echo ""
echo "━━━ Done — log: $DIAG_LOG ━━━"
