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

push_port_to_github() {
  local PORT="$1"
  TOKEN_FILE="${HOME}/.bore-github-token"
  [ -f "$TOKEN_FILE" ] || return 0
  GH_TOKEN=$(cat "$TOKEN_FILE")
  REPO="Tsukieomie/pocket-lab-v2-6"
  FILE="bore-port.txt"
  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  CONTENT="port=${PORT}
host=$(BORE_HOST=$(_bore_host) && echo "$BORE_HOST")
ssh=ssh -p ${PORT} $(whoami)@$(_bore_host)
updated=${TIMESTAMP}
machine=$(hostname -s)
"
  ENCODED=$(printf '%s' "$CONTENT" | base64 -w 0)
  SHA=$(curl -sf -H "Authorization: token ${GH_TOKEN}" \
    "https://api.github.com/repos/${REPO}/contents/${FILE}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")
  if [ -n "$SHA" ]; then
    PAYLOAD="{\"message\":\"bore port ${PORT} @ $(date '+%Y-%m-%d %H:%M')\",\"content\":\"${ENCODED}\",\"sha\":\"${SHA}\"}"
  else
    PAYLOAD="{\"message\":\"bore port ${PORT}\",\"content\":\"${ENCODED}\"}"
  fi
  curl -sf -X PUT \
    -H "Authorization: token ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/${REPO}/contents/${FILE}" > /dev/null \
    && echo "[tunnel] Port $PORT pushed to GitHub (bore-port.txt updated)" \
    || echo "[tunnel] GitHub push failed (non-fatal)"
}

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
      LIVE_PORT=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 || true)
      [ -n "$LIVE_PORT" ] && break
    done

    if pgrep -f "bore local 22" >/dev/null 2>&1 && [ -n "$LIVE_PORT" ]; then
      [ -z "$LIVE_PORT" ] && LIVE_PORT="$BORE_PORT"
      echo "[tunnel] UP → $BORE_HOST:$LIVE_PORT"
      echo "[tunnel] SSH command: ssh -p $LIVE_PORT $(whoami)@$BORE_HOST"
      # Update bore-port.txt in GitHub
      push_port_to_github "$LIVE_PORT"
      # Update local bore-port.txt in repo
      cat > "$REPO_DIR/bore-port.txt" << PORTFILE
port=${LIVE_PORT}
host=${BORE_HOST}
ssh=ssh -p ${LIVE_PORT} $(whoami)@${BORE_HOST}
updated=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
machine=$(hostname -s)
PORTFILE
    else
      echo "[tunnel] FAILED — check $LOG"
      cat "$LOG"
      exit 1
    fi
    ;;

  down)
    pkill -f "bore local 22 " 2>/dev/null && echo "[tunnel] Stopped." || echo "[tunnel] Not running."
    ;;

  status)
    if pgrep -f "bore local 22" >/dev/null 2>&1; then
      LIVE_PORT=$(sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -oE 'remote_port=[0-9]+' 2>/dev/null | tail -1 | cut -d= -f2 || echo "?")
      echo "[tunnel] RUNNING → $(_bore_host):$LIVE_PORT"
      echo "[tunnel] SSH: ssh -p $LIVE_PORT $(whoami)@$(_bore_host)"
    else
      echo "[tunnel] DOWN"
    fi
    ;;

  *)
    echo "Usage: $0 [up|down|status|install-bore]"
    exit 1
    ;;
esac
