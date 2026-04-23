#!/bin/bash
# ============================================================
# linux/tunnel.sh — Pocket Lab bore tunnel for Linux laptop
#
# Works as a normal user (no root/sudo required).
# Equivalent to: sh pocket_lab.sh tunnel up
# but resolves paths relative to $HOME instead of /root/
#
# Usage:
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh up
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh down
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh status
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh install-bore   # downloads bore binary to ~/.local/bin/
# ============================================================
set -eu

BORE_ENV="${HOME}/.bore_env"
BORE_BIN="${HOME}/.local/bin/bore"
# Also check system path
if command -v bore >/dev/null 2>&1; then
  BORE_BIN=$(command -v bore)
fi
LOG="/tmp/bore-tunnel-linux.log"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_bore_host() { grep '^BORE_HOST=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || echo "bore.pub"; }
_bore_port() { grep '^BORE_PORT=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || echo ""; }
_bore_secret() { grep '^BORE_SECRET=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || echo ""; }
# ── Systemd user service integration (v2.8.1) ───────────────
# If bore-tunnel.service exists as a user unit, defer to it: the service owns
# the tunnel and bore-port-watcher.service pushes port changes to GitHub.
_has_systemd_tunnel() {
  systemctl --user list-unit-files bore-tunnel.service 2>/dev/null \
    | grep -q '^bore-tunnel\.service'
}
_systemd_tunnel_port() {
  # Extract the live port from the bore-tunnel.service journal.
  # bore v0.6.x logs: "listening at bore.pub:PORT"
  # Fallback also matches legacy "remote_port=PORT" format.
  local RAW
  RAW=$(journalctl --user -u bore-tunnel.service -n 200 --no-pager 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g')
  # Primary: bore's actual output format
  echo "$RAW" | grep -oE 'bore\.pub:[0-9]+' | tail -1 | cut -d: -f2 | grep -E '^[0-9]+$' \
    || echo "$RAW" | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 | grep -E '^[0-9]+$' \
    || true
}


# ── push_port: write bore-port.txt locally + push to GitHub atomically ──────
# Called immediately after bore reports its remote_port — no watcher needed.
# Token sources (checked in order):
#   1. GH_TOKEN in ~/.bore_env
#   2. ~/.bore-github-token
push_port() {
  local PORT="$1"
  local BORE_HOST_VAL
  BORE_HOST_VAL=$(_bore_host)
  local TIMESTAMP
  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  # ── 1. Write local bore-port.txt immediately (always succeeds) ──
  cat > "$REPO_DIR/bore-port.txt" << PORTFILE
port=${PORT}
host=${BORE_HOST_VAL}
ssh=ssh -p ${PORT} $(whoami)@${BORE_HOST_VAL}
updated=${TIMESTAMP}
machine=$(hostname)
PORTFILE
  echo "[tunnel] bore-port.txt updated locally → port=${PORT}"

  # ── 2. Resolve GitHub token ──
  local GH_TOKEN=""
  GH_TOKEN=$(grep '^GH_TOKEN=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || true)
  if [ -z "$GH_TOKEN" ] && [ -f "${HOME}/.bore-github-token" ]; then
    GH_TOKEN=$(cat "${HOME}/.bore-github-token")
  fi
  if [ -z "$GH_TOKEN" ]; then
    echo "[tunnel] No GH_TOKEN found — skipping GitHub push (bore-port.txt local only)"
    echo "[tunnel] Set GH_TOKEN in ~/.bore_env to enable automatic GitHub sync"
    return 0
  fi

  # ── 3. Push to GitHub atomically (get current SHA first) ──
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
    PAYLOAD="{\"message\":\"bore port ${PORT} @ ${TIMESTAMP}\",\"content\":\"${ENCODED}\",\"sha\":\"${SHA}\"}"
  else
    PAYLOAD="{\"message\":\"bore port ${PORT} @ ${TIMESTAMP}\",\"content\":\"${ENCODED}\"}"
  fi

  local PUSH_OK=false
  curl -sf --max-time 10 -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/${REPO}/contents/${FILE}" > /dev/null \
    && PUSH_OK=true \
    || echo "[tunnel] GitHub push failed (non-fatal) — local bore-port.txt is current"

  if [ "$PUSH_OK" = false ]; then
    return 0
  fi

  # ── 4. Post-push verification — read back from GitHub raw CDN ──
  # Retry up to 5s to allow CDN propagation.
  local VERIFIED=false
  local REMOTE_PORT=""
  for _i in 1 2 3 4 5; do
    REMOTE_PORT=$(curl -sf --max-time 6 \
      "https://raw.githubusercontent.com/${REPO}/main/${FILE}?$(date +%s)" \
      | grep '^port=' | cut -d= -f2 || echo "")
    if [ "$REMOTE_PORT" = "$PORT" ]; then
      VERIFIED=true
      break
    fi
    sleep 1
  done

  if [ "$VERIFIED" = true ]; then
    echo "[tunnel] GitHub bore-port.txt verified ✓ (port=${PORT} confirmed on raw CDN)"
  else
    echo "[tunnel] WARNING: push succeeded but raw CDN returned port=${REMOTE_PORT:-<empty>} (expected ${PORT})"
    echo "[tunnel] CDN propagation may be delayed — local bore-port.txt is authoritative"
  fi
}

# Keep old name as alias for backwards compat
push_port_to_github() { push_port "$1"; }

install_bore() {
  echo "[tunnel] Installing bore binary to ~/.local/bin/ ..."
  mkdir -p "${HOME}/.local/bin"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  BORE_TARGET="x86_64-unknown-linux-musl" ;;
    aarch64) BORE_TARGET="aarch64-unknown-linux-musl" ;;
    armv7l)  BORE_TARGET="armv7-unknown-linux-musleabihf" ;;
    *)       echo "[tunnel] ERROR: Unknown arch $ARCH — download bore manually from https://github.com/ekzhang/bore/releases"; exit 1 ;;
  esac
  BORE_VER="0.6.0"
  URL="https://github.com/ekzhang/bore/releases/download/v${BORE_VER}/bore-v${BORE_VER}-${BORE_TARGET}.tar.gz"
  echo "[tunnel] Downloading $URL ..."
  curl -fsSL "$URL" -o /tmp/bore-linux.tar.gz
  tar -xzf /tmp/bore-linux.tar.gz -C /tmp
  chmod +x /tmp/bore
  mv /tmp/bore "${HOME}/.local/bin/bore"
  BORE_BIN="${HOME}/.local/bin/bore"
  echo "[tunnel] bore installed: $BORE_BIN"
  echo "[tunnel] Make sure ~/.local/bin is in your PATH:"
  echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc && source ~/.bashrc"
}

CMD="${1:-status}"

case "$CMD" in
  install-bore)
    install_bore
    ;;

  up)
    # v2.8.2: systemd path now pushes port atomically — no watcher needed
    if _has_systemd_tunnel; then
      systemctl --user start bore-tunnel.service 2>&1 || true
      # Poll up to 15s for bore to report its remote_port
      LIVE_PORT=""
      for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        LIVE_PORT=$(_systemd_tunnel_port)
        [ -n "$LIVE_PORT" ] && break
        sleep 1
      done
      if [ -n "$LIVE_PORT" ]; then
        echo "[tunnel] UP (systemd) → bore.pub:$LIVE_PORT"
        echo "[tunnel] SSH: ssh -p $LIVE_PORT $(whoami)@bore.pub"
        # Push port immediately — don't rely on bore-port-watcher.service
        push_port "$LIVE_PORT"
        exit 0
      else
        echo "[tunnel] systemd bore-tunnel.service did not report a port; falling back to manual"
      fi
    fi

    # Check bore binary
    if ! command -v bore >/dev/null 2>&1 && [ ! -x "$BORE_BIN" ]; then
      echo "[tunnel] bore not found — installing..."
      install_bore
    fi

    if pgrep -f "bore local 22" >/dev/null 2>&1; then
      echo "[tunnel] Already running."
      exit 0
    fi

    BORE_HOST=$(_bore_host)
    BORE_PORT=$(_bore_port)
    BORE_SECRET=$(_bore_secret)

    SECRET_ARG=""
    [ -n "$BORE_SECRET" ] && SECRET_ARG="--secret $BORE_SECRET"
    PORT_ARG=""
    [ -n "$BORE_PORT" ] && PORT_ARG="--port $BORE_PORT"

    echo "[tunnel] Starting: bore local 22 --to $BORE_HOST $PORT_ARG ..."
    # Truncate log so we only read the current run's remote_port
    : > "$LOG"
    # shellcheck disable=SC2086
    "$BORE_BIN" local 22 --to "$BORE_HOST" $PORT_ARG $SECRET_ARG \
      > "$LOG" 2>&1 &

    # Poll for the remote_port up to ~10s instead of a fixed sleep 3
    LIVE_PORT=""
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 1
      LIVE_PORT=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
        | grep -oE 'bore\.pub:[0-9]+' | tail -1 | cut -d: -f2 | grep -E '^[0-9]+$' || \
        sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
        | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 | grep -E '^[0-9]+$' || true)
      [ -n "$LIVE_PORT" ] && break
    done

    if pgrep -f "bore local 22" >/dev/null 2>&1 && [ -n "$LIVE_PORT" ]; then
      echo "[tunnel] UP → $BORE_HOST:$LIVE_PORT"
      echo "[tunnel] SSH command: ssh -p $LIVE_PORT $(whoami)@$BORE_HOST"
      # Write local file + push to GitHub in one step
      push_port "$LIVE_PORT"
    else
      echo "[tunnel] FAILED — check $LOG"
      cat "$LOG"
      exit 1
    fi
    ;;

  down)
    if _has_systemd_tunnel && systemctl --user is-active --quiet bore-tunnel.service; then
      systemctl --user stop bore-tunnel.service && echo "[tunnel] Stopped (systemd)." && exit 0
    fi
    pkill -f "bore local 22" 2>/dev/null && echo "[tunnel] Stopped." || echo "[tunnel] Not running."
    ;;

  status)
    # v2.8.2: prefer systemd-reported port if service is active
    if _has_systemd_tunnel && systemctl --user is-active --quiet bore-tunnel.service; then
      LIVE_PORT=$(_systemd_tunnel_port)
      [ -z "$LIVE_PORT" ] && LIVE_PORT="?"
      echo "[tunnel] RUNNING (systemd) → bore.pub:$LIVE_PORT"
      echo "[tunnel] SSH: ssh -p $LIVE_PORT $(whoami)@bore.pub"
      # Show whether bore-port.txt matches live port
      LOCAL_PORT=$(grep '^port=' "$REPO_DIR/bore-port.txt" 2>/dev/null | cut -d= -f2 || echo "unknown")
      if [ "$LOCAL_PORT" != "$LIVE_PORT" ] && [ "$LIVE_PORT" != "?" ]; then
        echo "[tunnel] WARNING: bore-port.txt has port=$LOCAL_PORT but live port is $LIVE_PORT"
        echo "[tunnel] Run: bash $0 sync-port   to fix"
      else
        echo "[tunnel] bore-port.txt in sync ✓"
      fi
      exit 0
    fi
    if pgrep -f "bore local 22" >/dev/null 2>&1; then
      LIVE_PORT=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
        | grep -oE 'bore\.pub:[0-9]+' | tail -1 | cut -d: -f2 | grep -E '^[0-9]+$' || \
        sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
        | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 | grep -E '^[0-9]+$' || echo "?")
      echo "[tunnel] RUNNING → $(_bore_host):$LIVE_PORT"
      echo "[tunnel] SSH: ssh -p $LIVE_PORT $(whoami)@$(_bore_host)"
    else
      echo "[tunnel] DOWN"
    fi
    ;;

  sync-port)
    # Manually re-read live bore port and push — useful if watcher missed it
    if _has_systemd_tunnel && systemctl --user is-active --quiet bore-tunnel.service; then
      LIVE_PORT=$(_systemd_tunnel_port)
      if [ -n "$LIVE_PORT" ]; then
        echo "[tunnel] Syncing port $LIVE_PORT → bore-port.txt + GitHub..."
        push_port "$LIVE_PORT"
      else
        echo "[tunnel] Could not read live port from systemd journal"
        exit 1
      fi
    elif pgrep -f "bore local 22" >/dev/null 2>&1; then
      LIVE_PORT=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
        | grep -oE 'bore\.pub:[0-9]+' | tail -1 | cut -d: -f2 | grep -E '^[0-9]+$' || \
        sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
        | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 | grep -E '^[0-9]+$' || true)
      if [ -n "$LIVE_PORT" ]; then
        echo "[tunnel] Syncing port $LIVE_PORT → bore-port.txt + GitHub..."
        push_port "$LIVE_PORT"
      else
        echo "[tunnel] bore is running but port not found in log"
        exit 1
      fi
    else
      echo "[tunnel] Tunnel is not running"
      exit 1
    fi
    ;;

  *)
    echo "Usage: $0 [up|down|status|sync-port|install-bore]"
    exit 1
    ;;
esac
