#!/bin/bash
# ============================================================
# linux/tunnel.sh — Pocket Lab cloudflared SSH tunnel (v2.9)
#
# Uses Cloudflare Tunnel (cloudflared) as the backend.
# Tunnels over HTTPS/443 — bypasses ISP port blocks.
# No account needed — quick-tunnel mode is free & zero-config.
#
# Works as a normal user (no root/sudo required).
#
# Usage:
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh up
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh down
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh status
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh sync-port
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh install-cloudflared
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh install-bore   (legacy, kept for compat)
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh fs-bridge [start|stop|status]
# ============================================================
set -eu

BORE_ENV="${HOME}/.bore_env"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="/tmp/cloudflared-tunnel.log"

# ── cloudflared binary resolution ───────────────────────────
_cf_bin() {
  for P in \
    "${HOME}/.local/bin/cloudflared" \
    "/usr/local/bin/cloudflared" \
    "/usr/bin/cloudflared"; do
    [ -x "$P" ] && echo "$P" && return 0
  done
  command -v cloudflared 2>/dev/null || echo ""
}

# ── ~/.bore_env helpers ──────────────────────────────────────
_gh_token()  { grep '^GH_TOKEN='  "$BORE_ENV" 2>/dev/null | cut -d= -f2 || true; }

# ── Systemd user service integration ────────────────────────
_has_systemd_tunnel() {
  systemctl --user list-unit-files cloudflared-tunnel.service 2>/dev/null \
    | grep -q '^cloudflared-tunnel\.service'
}

# Extract SSH URL from cloudflared-tunnel.service journal.
# cloudflared quick-tunnel prints: "Your quick Tunnel has been created! Visit it at (it may take some time to be reachable): https://XXXXX.trycloudflare.com"
# For TCP tunnels it prints: "INF | Registered tunnel connection"
# We capture the trycloudflare.com hostname from the log.
# IMPORTANT: uses --since based on the service's last ExecMainStartTimestamp so we
# never read stale hostnames from previous service invocations.
_systemd_tunnel_url() {
  # Get the timestamp of the current/last service start so we only read fresh logs
  local SINCE
  SINCE=$(systemctl --user show cloudflared-tunnel.service \
    --property=ExecMainStartTimestamp 2>/dev/null \
    | sed 's/ExecMainStartTimestamp=//' | grep -v '^$' || echo "")
  if [ -n "$SINCE" ] && [ "$SINCE" != "n/a" ]; then
    journalctl --user -u cloudflared-tunnel.service --since="$SINCE" --no-pager 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | grep -oE '[a-z0-9-]+\.trycloudflare\.com' \
      | tail -1 || true
  else
    # Fallback: limit to last 300 lines (less reliable but safe)
    journalctl --user -u cloudflared-tunnel.service -n 300 --no-pager 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | grep -oE '[a-z0-9-]+\.trycloudflare\.com' \
      | tail -1 || true
  fi
}

# ── push_port: write bore-port.txt and push to GitHub ───────
# For cloudflared we record the hostname (not a numeric port).
# The SSH connect command is:
#   ssh -o ProxyCommand='cloudflared access tcp --hostname %h' kenny@<hostname>
push_port() {
  local HOSTNAME_VAL="$1"
  local TIMESTAMP
  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local USERNAME
  USERNAME=$(whoami)

  # ── 1. Write local bore-port.txt ──
  cat > "$REPO_DIR/bore-port.txt" << PORTFILE
port=cloudflared
host=${HOSTNAME_VAL}
ssh=ssh -o ProxyCommand='cloudflared access tcp --hostname %h' ${USERNAME}@${HOSTNAME_VAL}
updated=${TIMESTAMP}
machine=$(hostname)
PORTFILE
  echo "[tunnel] bore-port.txt updated → host=${HOSTNAME_VAL}"
  # Prevent 'git pull' conflicts — bore-port.txt is runtime state, not source.
  # GitHub API is the source of truth; local copy is ephemeral.
  git -C "$REPO_DIR" update-index --assume-unchanged bore-port.txt 2>/dev/null || true

  # ── 2. Resolve GitHub token ──
  local GH_TOKEN=""
  GH_TOKEN=$(_gh_token)
  if [ -z "$GH_TOKEN" ] && [ -f "${HOME}/.bore-github-token" ]; then
    GH_TOKEN=$(cat "${HOME}/.bore-github-token")
  fi
  if [ -z "$GH_TOKEN" ]; then
    echo "[tunnel] No GH_TOKEN found — skipping GitHub push (bore-port.txt local only)"
    return 0
  fi

  # ── 3. Push to GitHub atomically ──
  local REPO="Tsukieomie/pocket-lab-v2-6"
  local FILE="bore-port.txt"
  local ENCODED
  ENCODED=$(base64 -w 0 < "$REPO_DIR/bore-port.txt" 2>/dev/null || base64 < "$REPO_DIR/bore-port.txt")
  local SHA
  SHA=$(curl -sf --max-time 8 \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${REPO}/contents/${FILE}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

  local PAYLOAD
  if [ -n "$SHA" ]; then
    PAYLOAD="{\"message\":\"tunnel up: ${HOSTNAME_VAL} @ ${TIMESTAMP}\",\"content\":\"${ENCODED}\",\"sha\":\"${SHA}\"}"
  else
    PAYLOAD="{\"message\":\"tunnel up: ${HOSTNAME_VAL} @ ${TIMESTAMP}\",\"content\":\"${ENCODED}\"}"
  fi

  local PUSH_OK=false
  curl -sf --max-time 10 -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/${REPO}/contents/${FILE}" > /dev/null \
    && PUSH_OK=true \
    || echo "[tunnel] GitHub push failed (non-fatal) — local bore-port.txt is current"

  $PUSH_OK && echo "[tunnel] GitHub bore-port.txt synced ✓ (host=${HOSTNAME_VAL})" || true
}

# Keep old alias
push_port_to_github() { push_port "$1"; }

# ── install-cloudflared ──────────────────────────────────────
install_cloudflared() {
  echo "[tunnel] Installing cloudflared to ~/.local/bin/ ..."
  mkdir -p "${HOME}/.local/bin"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  CF_ARCH="amd64"   ;;
    aarch64) CF_ARCH="arm64"   ;;
    armv7l)  CF_ARCH="arm"     ;;
    *)
      echo "[tunnel] ERROR: Unknown arch $ARCH"
      echo "[tunnel] Download manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
      exit 1
      ;;
  esac
  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  echo "[tunnel] Downloading $URL ..."
  curl -fsSL "$URL" -o "${HOME}/.local/bin/cloudflared"
  chmod +x "${HOME}/.local/bin/cloudflared"
  echo "[tunnel] cloudflared installed: ${HOME}/.local/bin/cloudflared"
  "${HOME}/.local/bin/cloudflared" --version
  echo "[tunnel] Make sure ~/.local/bin is in your PATH:"
  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
}

# ── install-bore (legacy) ────────────────────────────────────
install_bore() {
  echo "[tunnel] Installing bore binary to ~/.local/bin/ (legacy) ..."
  mkdir -p "${HOME}/.local/bin"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  BORE_TARGET="x86_64-unknown-linux-musl" ;;
    aarch64) BORE_TARGET="aarch64-unknown-linux-musl" ;;
    armv7l)  BORE_TARGET="armv7-unknown-linux-musleabihf" ;;
    *)       echo "[tunnel] ERROR: Unknown arch $ARCH"; exit 1 ;;
  esac
  BORE_VER="0.6.0"
  URL="https://github.com/ekzhang/bore/releases/download/v${BORE_VER}/bore-v${BORE_VER}-${BORE_TARGET}.tar.gz"
  curl -fsSL "$URL" -o /tmp/bore-linux.tar.gz
  tar -xzf /tmp/bore-linux.tar.gz -C /tmp
  chmod +x /tmp/bore
  mv /tmp/bore "${HOME}/.local/bin/bore"
  echo "[tunnel] bore installed: ${HOME}/.local/bin/bore"
}

# ── fs-bridge helpers ────────────────────────────────────────
_fs_bridge_pid() { pgrep -f "node.*fs-bridge/server.js" | head -1 || true; }

fs_bridge_start() {
  if [ -n "$(_fs_bridge_pid)" ]; then echo "[fs-bridge] Already running."; return 0; fi
  if systemctl --user list-unit-files fs-bridge.service 2>/dev/null | grep -q '^fs-bridge'; then
    systemctl --user start fs-bridge.service && echo "[fs-bridge] Started (systemd)." && return 0
  fi
  BRIDGE="$REPO_DIR/linux/fs-bridge/server.js"
  if [ ! -f "$BRIDGE" ]; then echo "[fs-bridge] ERROR: $BRIDGE not found"; return 1; fi
  if ! command -v node &>/dev/null; then echo "[fs-bridge] ERROR: node not found"; return 1; fi
  node "$BRIDGE" >> /tmp/fs-bridge.log 2>&1 &
  sleep 1
  PID=$(_fs_bridge_pid)
  if [ -n "$PID" ]; then
    echo "[fs-bridge] Started (pid=$PID) on 127.0.0.1:7779"
  else
    echo "[fs-bridge] FAILED — check /tmp/fs-bridge.log"; return 1
  fi
}

fs_bridge_stop() {
  if systemctl --user is-active --quiet fs-bridge.service 2>/dev/null; then
    systemctl --user stop fs-bridge.service && echo "[fs-bridge] Stopped (systemd)." && return 0
  fi
  PID=$(_fs_bridge_pid)
  if [ -n "$PID" ]; then kill "$PID" && echo "[fs-bridge] Stopped (pid=$PID)."; else echo "[fs-bridge] Not running."; fi
}

fs_bridge_status() {
  PID=$(_fs_bridge_pid)
  if [ -n "$PID" ]; then
    PORT=$(ss -tlnp 2>/dev/null | grep "$PID" | grep -oE '127\.0\.0\.1:[0-9]+' | head -1 | cut -d: -f2 || echo "7779")
    echo "[fs-bridge] RUNNING (pid=$PID, port=${PORT:-7779})"
    TOKEN_VAL=$(grep '^FS_BRIDGE_TOKEN=' "${HOME}/.bore_env" 2>/dev/null | cut -d= -f2 || echo "")
    if [ -n "$TOKEN_VAL" ]; then
      STATUS=$(curl -sf -H "Authorization: Bearer $TOKEN_VAL" http://127.0.0.1:7779/status 2>/dev/null || echo "{}")
      echo "[fs-bridge] Health: $STATUS"
    fi
  else
    echo "[fs-bridge] DOWN"
  fi
}

# ── Main ─────────────────────────────────────────────────────
CMD="${1:-status}"

case "$CMD" in
  install-cloudflared)
    install_cloudflared
    ;;

  install-bore)
    install_bore
    ;;

  up)
    # Prefer systemd if service is installed
    if _has_systemd_tunnel; then
      systemctl --user start cloudflared-tunnel.service 2>&1 || true
      # Poll up to 20s for cloudflared to print the trycloudflare.com hostname
      LIVE_HOST=""
      for i in $(seq 1 20); do
        LIVE_HOST=$(_systemd_tunnel_url)
        [ -n "$LIVE_HOST" ] && break
        sleep 1
      done
      if [ -n "$LIVE_HOST" ]; then
        echo "[tunnel] UP (systemd) → ${LIVE_HOST}"
        echo "[tunnel] SSH: ssh -o ProxyCommand='cloudflared access tcp --hostname %h' $(whoami)@${LIVE_HOST}"
        push_port "$LIVE_HOST"
        exit 0
      else
        echo "[tunnel] cloudflared-tunnel.service did not report a hostname within 20s; falling back"
      fi
    fi

    # Direct invocation
    CF_BIN=$(_cf_bin)
    if [ -z "$CF_BIN" ]; then
      echo "[tunnel] cloudflared not found — installing..."
      install_cloudflared
      CF_BIN="${HOME}/.local/bin/cloudflared"
    fi

    if pgrep -f "cloudflared.*tcp.*22" >/dev/null 2>&1; then
      echo "[tunnel] Already running."
      exit 0
    fi

    echo "[tunnel] Starting cloudflared TCP tunnel for SSH (port 22)..."
    : > "$LOG"
    "$CF_BIN" tunnel --url tcp://localhost:22 >> "$LOG" 2>&1 &

    # Poll up to 30s for trycloudflare.com hostname
    LIVE_HOST=""
    for i in $(seq 1 30); do
      sleep 1
      LIVE_HOST=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
        | grep -oE '[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
      [ -n "$LIVE_HOST" ] && break
    done

    if pgrep -f "cloudflared.*tcp.*22" >/dev/null 2>&1 && [ -n "$LIVE_HOST" ]; then
      echo "[tunnel] UP → ${LIVE_HOST}"
      echo "[tunnel] SSH: ssh -o ProxyCommand='cloudflared access tcp --hostname %h' $(whoami)@${LIVE_HOST}"
      push_port "$LIVE_HOST"
    else
      echo "[tunnel] FAILED — check $LOG"
      tail -30 "$LOG"
      exit 1
    fi
    ;;

  down)
    if _has_systemd_tunnel && systemctl --user is-active --quiet cloudflared-tunnel.service 2>/dev/null; then
      systemctl --user stop cloudflared-tunnel.service && echo "[tunnel] Stopped (systemd)." && exit 0
    fi
    pkill -f "cloudflared.*tcp.*22" 2>/dev/null \
      && echo "[tunnel] Stopped." \
      || echo "[tunnel] Not running."
    ;;

  status)
    if _has_systemd_tunnel && systemctl --user is-active --quiet cloudflared-tunnel.service 2>/dev/null; then
      LIVE_HOST=$(_systemd_tunnel_url)
      [ -z "$LIVE_HOST" ] && LIVE_HOST="(hostname pending)"
      echo "[tunnel] RUNNING (systemd) → ${LIVE_HOST}"
      echo "[tunnel] SSH: ssh -o ProxyCommand='cloudflared access tcp --hostname %h' $(whoami)@${LIVE_HOST}"
      LOCAL_HOST=$(grep '^host=' "$REPO_DIR/bore-port.txt" 2>/dev/null | cut -d= -f2 || echo "unknown")
      if [ "$LOCAL_HOST" != "$LIVE_HOST" ]; then
        echo "[tunnel] WARNING: bore-port.txt has host=${LOCAL_HOST} but live host is ${LIVE_HOST}"
        echo "[tunnel] Run: bash $0 sync-port"
      else
        echo "[tunnel] bore-port.txt in sync ✓"
      fi
      exit 0
    fi
    if pgrep -f "cloudflared.*tcp.*22" >/dev/null 2>&1; then
      LIVE_HOST=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
        | grep -oE '[a-z0-9-]+\.trycloudflare\.com' | tail -1 || echo "?")
      echo "[tunnel] RUNNING → ${LIVE_HOST}"
      echo "[tunnel] SSH: ssh -o ProxyCommand='cloudflared access tcp --hostname %h' $(whoami)@${LIVE_HOST}"
    else
      echo "[tunnel] DOWN"
    fi
    ;;

  sync-port)
    # Silence git-pull conflicts on bore-port.txt for future pulls
    git -C "$REPO_DIR" update-index --assume-unchanged bore-port.txt 2>/dev/null || true
    # Try journal first (works whether called manually or from ExecStartPost)
    LIVE_HOST=$(_systemd_tunnel_url)
    # Fallback: scan the direct-launch log file
    if [ -z "$LIVE_HOST" ] && [ -f "$LOG" ]; then
      LIVE_HOST=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
        | grep -oE '[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)
    fi
    if [ -n "$LIVE_HOST" ]; then
      echo "[tunnel] Syncing host ${LIVE_HOST} → bore-port.txt + GitHub..."
      push_port "$LIVE_HOST"
    else
      echo "[tunnel] Could not determine live hostname (is cloudflared running?)"
      exit 1
    fi
    ;;

  fs-bridge-start)  fs_bridge_start  ;;
  fs-bridge-stop)   fs_bridge_stop   ;;
  fs-bridge-status) fs_bridge_status ;;

  fs-bridge)
    SUBCMD="${2:-status}"
    case "$SUBCMD" in
      start)  fs_bridge_start  ;;
      stop)   fs_bridge_stop   ;;
      status) fs_bridge_status ;;
      *) echo "Usage: $0 fs-bridge [start|stop|status]"; exit 1 ;;
    esac
    ;;

  *)
    echo "Usage: $0 [up|down|status|sync-port|install-cloudflared|install-bore|fs-bridge]"
    exit 1
    ;;
esac
