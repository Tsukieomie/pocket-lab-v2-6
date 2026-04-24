#!/bin/bash
# diag-tunnel.sh — Pocket Lab tunnel diagnostics + network reachability
set -u

CF_BIN="${HOME}/.local/bin/cloudflared"
TUNNEL_TOKEN="eyJhIjoiZjdjOGUxN2U0N2IyYmE2MTIyNDg1MGQ3YmI5ODkyN2YiLCJ0IjoiODEzMmVjODQtODcyNC00YmUxLWE1ODgtOWU2MmVhNmMzNTYyIiwicyI6Ik9EYzFPR1JrWTJSaFl6TmxZV1JrWVdJMlpUSTRNalUxTkdNME5XVm1NVE0wWlRsaE1tWTFabVE0WTJZNE5tVXhOakZpTTJSak1tUXhaR016TkdVNVpBPT0ifQ=="

# ── colour helpers ────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
fail() { echo -e "${RED}  ✗ $*${NC}"; }
warn() { echo -e "${YELLOW}  ! $*${NC}"; }

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Pocket Lab — Tunnel Diagnostics                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. NETWORK REACHABILITY — runs BEFORE anything else
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "━━━ [1/4] Network Reachability ━━━"

# Cloudflare edge IPs (Argo Tunnel edge nodes)
CF_EDGES="198.41.192.67 198.41.200.193 104.16.0.0 162.159.192.0"
PORTS="443 7844"

ANY_443_OPEN=false
for IP in $CF_EDGES; do
  for PORT in $PORTS; do
    if timeout 4 bash -c "echo >/dev/tcp/${IP}/${PORT}" 2>/dev/null; then
      ok "TCP ${IP}:${PORT} — OPEN"
      [ "$PORT" = "443" ] && ANY_443_OPEN=true
    else
      fail "TCP ${IP}:${PORT} — BLOCKED"
    fi
  done
done

echo ""
# DNS resolution check
if python3 -c "import socket; socket.getaddrinfo('region1.v2.argotunnel.com', 443, socket.AF_INET)" 2>/dev/null; then
  EDGE_IP=$(python3 -c "import socket; print(socket.getaddrinfo('region1.v2.argotunnel.com',443,socket.AF_INET)[0][4][0])")
  ok "DNS region1.v2.argotunnel.com → $EDGE_IP"
  # Test TCP to resolved IP
  if timeout 4 bash -c "echo >/dev/tcp/${EDGE_IP}/443" 2>/dev/null; then
    ok "TCP ${EDGE_IP}:443 (argotunnel) — OPEN"
    ANY_443_OPEN=true
  else
    fail "TCP ${EDGE_IP}:443 (argotunnel) — BLOCKED"
  fi
else
  fail "DNS resolution for region1.v2.argotunnel.com failed"
fi

echo ""
# General internet check
if timeout 4 bash -c "echo >/dev/tcp/1.1.1.1/443" 2>/dev/null; then
  ok "TCP 1.1.1.1:443 (Cloudflare public DNS) — OPEN"
else
  fail "TCP 1.1.1.1:443 — BLOCKED (severe network issue)"
fi

if $ANY_443_OPEN; then
  ok "Port 443 is OPEN — http2 tunnel should work"
else
  fail "Port 443 appears BLOCKED — tunnel cannot connect"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. CLOUDFLARED BINARY CHECK
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "━━━ [2/4] cloudflared Binary ━━━"
if [ -x "$CF_BIN" ]; then
  ok "$CF_BIN — $($CF_BIN --version 2>&1 | head -1)"
else
  fail "cloudflared not found at $CF_BIN"
  warn "Install: curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o $CF_BIN && chmod +x $CF_BIN"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. SERVICE JOURNAL
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "━━━ [3/4] cloudflared-tunnel.service Journal (last 30 lines) ━━━"
journalctl --user -u cloudflared-tunnel.service -n 30 --no-pager 2>/dev/null   | sed 's/\x1b\[[0-9;]*m//g'

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. LIVE TEST — manual run with full output
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "━━━ [4/4] Live cloudflared Run (8s capture) ━━━"
echo "    protocol=http2  edge-ip-version=4"
echo ""
$CF_BIN tunnel --no-autoupdate --protocol http2 --edge-ip-version 4   run --token "$TUNNEL_TOKEN" 2>&1 &
CF_PID=$!
sleep 8
kill $CF_PID 2>/dev/null || true
wait $CF_PID 2>/dev/null || true

echo ""
echo "━━━ Done ━━━"
