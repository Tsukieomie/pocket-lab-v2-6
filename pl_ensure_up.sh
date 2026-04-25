#!/usr/bin/env bash
# pl_ensure_up.sh — Pocket Lab v2.6 keep-alive
# Called at the start of every Perplexity Computer turn.
# Idempotent: safe to run when already up.
set -eu

export PATH="$HOME/.local/bin:$PATH"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BORE_ENV="$HOME/.bore_env"
LOG=/tmp/bore-tunnel.log

# ── 1. Provision bore binary if missing ─────────────────────
if ! command -v bore >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/bore" ]; then
  echo "[pl_ensure_up] bore missing — installing..."
  bash "$REPO/linux/tunnel.sh" install-bore
fi

# ── 2. Provision ~/.bore_env if missing ─────────────────────
if [ ! -f "$BORE_ENV" ]; then
  echo "[pl_ensure_up] ~/.bore_env missing — rebuilding..."
  GH_TOKEN_VAL=$(gh auth token 2>/dev/null || true)
  FS_BRIDGE_TOKEN_VAL=$(openssl rand -hex 32)
  cat > "$BORE_ENV" << EOF
BORE_HOST=188.93.146.98
BORE_SECRET=pocketlab2026
BORE_CTRL_PORT=8443
GH_TOKEN=${GH_TOKEN_VAL}
FS_BRIDGE_TOKEN=${FS_BRIDGE_TOKEN_VAL}
EOF
  echo "[pl_ensure_up] ~/.bore_env written"
fi

# ── 3. Check if bore tunnel is actually alive ────────────────
BORE_PID=$(pgrep -f "bore.*local.*22" | head -1 || true)
LIVE_PORT=""
if [ -n "$BORE_PID" ]; then
  LIVE_PORT=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null \
    | grep "listening at" | grep -oE ':[0-9]+' | tail -1 | tr -d ':' || true)
fi

if [ -z "$BORE_PID" ] || [ -z "$LIVE_PORT" ]; then
  echo "[pl_ensure_up] Tunnel down — restarting..."
  # Kill any stale bore processes
  pkill -f "bore.*local.*22" 2>/dev/null || true
  sleep 0.3

  # Bring tunnel up
  bash "$REPO/linux/tunnel.sh" up 2>&1
  sleep 1

  # Read new port
  LIVE_PORT=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null \
    | grep "listening at" | grep -oE ':[0-9]+' | tail -1 | tr -d ':' || true)

  if [ -n "$LIVE_PORT" ]; then
    echo "[pl_ensure_up] Tunnel UP → 188.93.146.98:${LIVE_PORT}"

    # Push new port to GitHub
    CONTENT=$(base64 -w 0 < "$REPO/bore-port.txt" 2>/dev/null \
             || base64 < "$REPO/bore-port.txt")
    SHA=$(gh api repos/Tsukieomie/pocket-lab-v2-6/contents/bore-port.txt \
          --jq '.sha' 2>/dev/null || echo "")
    if [ -n "$SHA" ]; then
      gh api repos/Tsukieomie/pocket-lab-v2-6/contents/bore-port.txt \
        -X PUT \
        -f message="chore: bore-port.txt → port=${LIVE_PORT} [auto]" \
        -f content="$CONTENT" \
        -f sha="$SHA" \
        --jq '.commit.sha' >/dev/null 2>&1 \
      && echo "[pl_ensure_up] GitHub synced → port=${LIVE_PORT}" \
      || echo "[pl_ensure_up] GitHub sync failed (non-fatal)"
    fi
  else
    echo "[pl_ensure_up] WARNING: tunnel started but port not visible yet"
  fi
else
  echo "[pl_ensure_up] Tunnel OK → 188.93.146.98:${LIVE_PORT}"
fi

# ── 4. Ensure fs-bridge is running ──────────────────────────
FS_PID=$(pgrep -f "node.*fs-bridge/server.js" | head -1 || true)
if [ -z "$FS_PID" ]; then
  echo "[pl_ensure_up] fs-bridge down — restarting..."
  node "$REPO/linux/fs-bridge/server.js" >> /tmp/fs-bridge.log 2>&1 &
  sleep 1
  FS_PID=$(pgrep -f "node.*fs-bridge/server.js" | head -1 || true)
  [ -n "$FS_PID" ] \
    && echo "[pl_ensure_up] fs-bridge started (pid=$FS_PID)" \
    || echo "[pl_ensure_up] WARNING: fs-bridge failed to start"
else
  echo "[pl_ensure_up] fs-bridge OK (pid=$FS_PID)"
fi

echo "[pl_ensure_up] DONE"
