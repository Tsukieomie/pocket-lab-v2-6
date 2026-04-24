#!/bin/bash
# ============================================================
# linux/tunnel.sh — Pocket Lab SSH tunnel (v3.0)
#
# Primary backend: bore TCP → 188.93.146.98:2222
# Fallback: cloudflared quick-tunnel (HTTP only, no SSH proxy)
#
# bore tunnels pure TCP — works with standard SSH, no proxy
# command needed. SSH connect command:
#   ssh -p <port> kenny@188.93.146.98
#
# Works as a normal user (no root/sudo required).
#
# Usage:
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh up
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh down
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh status
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh sync-port
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh install-bore
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh install-cloudflared  (legacy)
#   bash ~/pocket-lab-v2-6/linux/tunnel.sh fs-bridge [start|stop|status]
# ============================================================
set -eu

BORE_ENV="${HOME}/.bore_env"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="/tmp/bore-tunnel.log"
CF_LOG="/tmp/cloudflared-tunnel.log"
PORT_HISTORY="${HOME}/.bore-port-history.log"

# ── bore defaults (overridable via ~/.bore_env) ──────────────
BORE_HOST="${BORE_HOST:-188.93.146.98}"
BORE_SECRET="${BORE_SECRET:-pocketlab2026}"
BORE_CTRL_PORT="${BORE_CTRL_PORT:-2222}"

# Source ~/.bore_env for overrides (ignore missing)
# shellcheck disable=SC1090
[ -f "$BORE_ENV" ] && set +eu && . "$BORE_ENV" && set -eu || true

# ── bore binary resolution ───────────────────────────────────
# _bore_bin [PORT] — returns best binary for given ctrl port.
# PORT defaults to BORE_CTRL_PORT, then 2222.
#
# The custom binaries (bore-custom-2222, bore-custom-8443) have their
# control port baked in — they ignore any --control-port-style flag and
# ALWAYS dial the port named in the binary. We must therefore only return
# a custom binary when its baked-in port matches the requested port; any
# other mapping would produce misleading logs (ctrl=X, actually dials Y).
_bore_bin() {
  local PORT="${1:-${BORE_CTRL_PORT:-2222}}"
  case "$PORT" in
    8443)
      [ -x "${REPO_DIR}/bore-custom-8443" ] && echo "${REPO_DIR}/bore-custom-8443" && return 0
      ;;
    2222)
      [ -x "${REPO_DIR}/bore-custom-2222" ] && echo "${REPO_DIR}/bore-custom-2222" && return 0
      ;;
    *)
      # Any other port (e.g. 443) requires the generic upstream `bore` binary
      # that supports --to HOST plus --port <ctrl>. No custom binary aliasing.
      :
      ;;
  esac
  # Generic fallbacks (upstream bore from install_bore / distro)
  for P in \
    "${HOME}/.local/bin/bore" \
    "/usr/local/bin/bore" \
    "/usr/bin/bore"; do
    [ -x "$P" ] && echo "$P" && return 0
  done
  command -v bore 2>/dev/null || echo ""
}

# ── _bore_try: attempt one bore connection on a given ctrl port ─
# Usage: _bore_try <BORE_IP> <CTRL_PORT> <SECRET_ARG> <LOG_FILE>
# Starts bore in background, polls 10s for "listening at", kills on
# failure. Prints the remote port on success, empty string on failure.
_bore_try() {
  local BORE_IP="$1" CTRL_PORT="$2" SECRET_ARG="$3" TRY_LOG="$4"
  local BIN
  BIN=$(_bore_bin "$CTRL_PORT")
  [ -z "$BIN" ] && return 1
  # Kill any existing bore process for a clean try
  pkill -f "bore.*local.*22" 2>/dev/null || true
  sleep 0.5
  : > "$TRY_LOG"
  # shellcheck disable=SC2086
  "$BIN" local 22 --to "$BORE_IP" $SECRET_ARG >> "$TRY_LOG" 2>&1 &
  local TRY_PID=$!
  local PORT=""
  for i in $(seq 1 10); do
    sleep 1
    PORT=$(grep "listening at" "$TRY_LOG" 2>/dev/null \
      | grep -oE ':[0-9]+' | tail -1 | tr -d ':' || true)
    [ -n "$PORT" ] && echo "$PORT" && return 0
    # Bail early if process already died
    kill -0 "$TRY_PID" 2>/dev/null || break
  done
  # Failed — kill the background process
  kill "$TRY_PID" 2>/dev/null || true
  return 1
}

# ── cloudflared binary resolution (legacy fallback) ─────────
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
_gh_token() { grep '^GH_TOKEN=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || true; }

# ── Systemd user service helpers ────────────────────────────
_has_systemd_bore() {
  systemctl --user list-unit-files bore-tunnel.service 2>/dev/null \
    | grep -q '^bore-tunnel\.service'
}

_has_systemd_cf() {
  systemctl --user list-unit-files cloudflared-tunnel.service 2>/dev/null \
    | grep -q '^cloudflared-tunnel\.service'
}

# Extract bore port from journal — scoped to current service invocation
_systemd_bore_port() {
  local SINCE
  SINCE=$(systemctl --user show bore-tunnel.service \
    --property=ExecMainStartTimestamp 2>/dev/null \
    | sed 's/ExecMainStartTimestamp=//' | grep -v '^$' || echo "")
  if [ -n "$SINCE" ] && [ "$SINCE" != "n/a" ]; then
    journalctl --user -u bore-tunnel.service --since="$SINCE" --no-pager 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | grep "listening at" | grep -oE ':[0-9]+' | tail -1 | tr -d ':' || true
  else
    journalctl --user -u bore-tunnel.service -n 200 --no-pager 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | grep "listening at" | grep -oE ':[0-9]+' | tail -1 | tr -d ':' || true
  fi
}

# ── push_port: write bore-port.txt and push to GitHub ───────
# Records bore host + port so Computer can SSH in directly:
#   ssh -p <port> kenny@188.93.146.98
push_port() {
  local PORT_VAL="$1"
  local TIMESTAMP
  TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local USERNAME
  USERNAME=$(whoami)

  # ── 1. Write local bore-port.txt ──
  cat > "$REPO_DIR/bore-port.txt" << PORTFILE
port=${PORT_VAL}
host=${BORE_HOST}
ssh=ssh -p ${PORT_VAL} ${USERNAME}@${BORE_HOST}
updated=${TIMESTAMP}
machine=$(hostname)
PORTFILE
  echo "[tunnel] bore-port.txt updated → port=${PORT_VAL} host=${BORE_HOST}"
  # Prevent 'git pull' conflicts — bore-port.txt is runtime state, not source.
  git -C "$REPO_DIR" update-index --assume-unchanged bore-port.txt 2>/dev/null || true

  # ── 2. Resolve GitHub token / gh CLI ──
  local GH_TOKEN=""
  GH_TOKEN=$(_gh_token)
  if [ -z "$GH_TOKEN" ] && [ -f "${HOME}/.bore-github-token" ]; then
    GH_TOKEN=$(cat "${HOME}/.bore-github-token")
  fi

  # ── 3. Push to GitHub atomically ──
  # Prefer `gh api` (Perplexity Computer connector) over raw curl+token.
  # Fall back to curl+GH_TOKEN if gh is not available.
  local REPO="Tsukieomie/pocket-lab-v2-6"
  local FILE="bore-port.txt"
  local ENCODED
  ENCODED=$(base64 -w 0 < "$REPO_DIR/bore-port.txt" 2>/dev/null || base64 < "$REPO_DIR/bore-port.txt")
  local PUSH_OK=false

  if command -v gh >/dev/null 2>&1 && gh api user --jq '.login' >/dev/null 2>&1; then
    # gh api path — works with Perplexity Computer connector token
    local SHA
    SHA=$(gh api "repos/${REPO}/contents/${FILE}" --jq '.sha' 2>/dev/null || echo "")
    if [ -n "$SHA" ]; then
      gh api "repos/${REPO}/contents/${FILE}" -X PUT \
        -f message="tunnel up: port=${PORT_VAL} @ ${TIMESTAMP}" \
        -f content="${ENCODED}" \
        -f sha="${SHA}" \
        --jq '.commit.sha' >/dev/null 2>&1 && PUSH_OK=true || true
    else
      gh api "repos/${REPO}/contents/${FILE}" -X PUT \
        -f message="tunnel up: port=${PORT_VAL} @ ${TIMESTAMP}" \
        -f content="${ENCODED}" \
        --jq '.commit.sha' >/dev/null 2>&1 && PUSH_OK=true || true
    fi
    $PUSH_OK || echo "[tunnel] gh api push failed (non-fatal) — local bore-port.txt is current"
  elif [ -n "$GH_TOKEN" ]; then
    # Raw curl fallback
    local SHA
    SHA=$(curl -sf --max-time 8 \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${REPO}/contents/${FILE}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")
    local PAYLOAD
    if [ -n "$SHA" ]; then
      PAYLOAD="{\"message\":\"tunnel up: port=${PORT_VAL} @ ${TIMESTAMP}\",\"content\":\"${ENCODED}\",\"sha\":\"${SHA}\"}"
    else
      PAYLOAD="{\"message\":\"tunnel up: port=${PORT_VAL} @ ${TIMESTAMP}\",\"content\":\"${ENCODED}\"}"
    fi
    curl -sf --max-time 10 -X PUT \
      -H "Authorization: token ${GH_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "https://api.github.com/repos/${REPO}/contents/${FILE}" > /dev/null \
      && PUSH_OK=true \
      || echo "[tunnel] GitHub push failed (non-fatal) — local bore-port.txt is current"
  else
    echo "[tunnel] No GH_TOKEN and gh CLI not available — skipping GitHub push (bore-port.txt local only)"
    return 0
  fi

  $PUSH_OK && echo "[tunnel] GitHub bore-port.txt synced ✓ (port=${PORT_VAL} host=${BORE_HOST})" || true
}

# Keep old alias
push_port_to_github() { push_port "$1"; }

# ── install-bore ─────────────────────────────────────────────
install_bore() {
  echo "[tunnel] Installing bore binary to ~/.local/bin/ ..."
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
  echo "[tunnel] Downloading $URL ..."
  curl -fsSL "$URL" -o /tmp/bore-linux.tar.gz
  tar -xzf /tmp/bore-linux.tar.gz -C /tmp
  chmod +x /tmp/bore
  mv /tmp/bore "${HOME}/.local/bin/bore"
  echo "[tunnel] bore installed: ${HOME}/.local/bin/bore"
  "${HOME}/.local/bin/bore" --version 2>/dev/null || true
}

# ── install-cloudflared (legacy) ─────────────────────────────
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
      exit 1
      ;;
  esac
  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  echo "[tunnel] Downloading $URL ..."
  curl -fsSL "$URL" -o "${HOME}/.local/bin/cloudflared"
  chmod +x "${HOME}/.local/bin/cloudflared"
  echo "[tunnel] cloudflared installed: ${HOME}/.local/bin/cloudflared"
  "${HOME}/.local/bin/cloudflared" --version
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
  install-bore)
    install_bore
    ;;

  install-cloudflared)
    install_cloudflared
    ;;

  up)
    # Kill any stale bore process first (prevents 'already running' false positive)
    if pgrep -f "bore.*local.*22" >/dev/null 2>&1; then
      echo "[tunnel] Killing stale bore process..."
      pkill -f "bore.*local.*22" 2>/dev/null || true
      sleep 1
    fi

    # ── Prefer bore-tunnel systemd service ──
    if _has_systemd_bore; then
      systemctl --user reset-failed bore-tunnel.service 2>/dev/null || true
      systemctl --user start bore-tunnel.service 2>&1 || true
      LIVE_PORT=""
      for i in $(seq 1 20); do
        LIVE_PORT=$(_systemd_bore_port)
        [ -n "$LIVE_PORT" ] && break
        sleep 1
      done
      if [ -n "$LIVE_PORT" ]; then
        echo "[tunnel] UP (systemd/bore) → ${BORE_HOST}:${LIVE_PORT}"
        echo "[tunnel] SSH: ssh -p ${LIVE_PORT} $(whoami)@${BORE_HOST}"
        push_port "$LIVE_PORT"
        fs_bridge_start
        exit 0
      else
        echo "[tunnel] bore-tunnel.service did not report a port within 20s; falling back to direct"
      fi
    fi

    # ── Direct bore invocation with port fallback ──
    # Ensure at least one bore binary is available
    if [ -z "$(_bore_bin 2222)" ] && [ -z "$(_bore_bin 8443)" ]; then
      echo "[tunnel] bore not found — installing..."
      install_bore
    fi

    # Resolve IP
    BORE_IP=$(getent ahostsv4 "${BORE_HOST}" 2>/dev/null | awk '/STREAM/{print $1; exit}' \
      || python3 -c "import socket; print(socket.getaddrinfo('${BORE_HOST}',None,socket.AF_INET)[0][4][0])" 2>/dev/null \
      || echo "${BORE_HOST}")

    SECRET_ARG=""
    [ -n "${BORE_SECRET}" ] && SECRET_ARG="--secret ${BORE_SECRET}"

    # Try control ports in order: configured port first, then 2222 → 8443.
    # Build ordered list (configured port first, deduplicated).
    # NOTE: 443 is NOT in the automatic fallback list. The shipped custom
    # bore binaries are hardcoded to 2222 and 8443; there is no 443-patched
    # binary, and falling back to 443 would either re-dial 8443 (misleading
    # logs) or require the upstream `bore` binary, which isn't guaranteed
    # to be present. If you have upstream bore installed and want to try
    # 443 as a ctrl port, set BORE_CTRL_PORT=443 in ~/.bore_env.
    CONFIGURED_PORT="${BORE_CTRL_PORT:-2222}"
    PORT_LIST="${CONFIGURED_PORT}"
    for P in 2222 8443; do
      [ "$P" != "$CONFIGURED_PORT" ] && PORT_LIST="${PORT_LIST} ${P}"
    done

    LIVE_PORT=""
    USED_PORT=""
    for TRY_PORT in $PORT_LIST; do
      # Quick TCP probe before attempting bore (saves 10s timeout)
      if ! timeout 3 bash -c "echo >/dev/tcp/${BORE_IP}/${TRY_PORT}" 2>/dev/null; then
        echo "[tunnel] ctrl port ${TRY_PORT} unreachable — skipping"
        continue
      fi
      # Skip if we don't have a binary that will actually dial this port.
      # _bore_bin only returns a custom binary when its baked-in port
      # matches, so this prevents the old 443→8443 silent aliasing bug.
      if [ -z "$(_bore_bin "$TRY_PORT")" ]; then
        echo "[tunnel] ctrl port ${TRY_PORT}: no matching bore binary — skipping"
        continue
      fi
      echo "[tunnel] Trying bore → ${BORE_HOST} ctrl=${TRY_PORT} ..."
      LIVE_PORT=$(_bore_try "$BORE_IP" "$TRY_PORT" "$SECRET_ARG" "$LOG") && USED_PORT="$TRY_PORT" && break || true
      printf '%s  ctrl=%-4s  remote=%-5s  host=%s  result=FAIL\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${TRY_PORT}" "-" "${BORE_HOST}" >> "${PORT_HISTORY}"
      echo "[tunnel] ctrl port ${TRY_PORT} failed — trying next"
    done

    if [ -n "$LIVE_PORT" ]; then
      # Persist the working port so future runs start with it
      if [ "$USED_PORT" != "${BORE_CTRL_PORT:-2222}" ]; then
        grep -v '^BORE_CTRL_PORT=' "$BORE_ENV" > /tmp/_bore_env_tmp 2>/dev/null || true
        echo "BORE_CTRL_PORT=${USED_PORT}" >> /tmp/_bore_env_tmp
        mv /tmp/_bore_env_tmp "$BORE_ENV"
        echo "[tunnel] Saved BORE_CTRL_PORT=${USED_PORT} → ${BORE_ENV}"
      fi
      # Log winning port to history file
      printf '%s  ctrl=%-4s  remote=%-5s  host=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${USED_PORT}" "${LIVE_PORT}" "${BORE_HOST}" \
        >> "${PORT_HISTORY}"
      echo "[tunnel] UP → ${BORE_HOST}:${LIVE_PORT} (ctrl=${USED_PORT})"
      echo "[tunnel] SSH: ssh -p ${LIVE_PORT} $(whoami)@${BORE_HOST}"
      push_port "$LIVE_PORT"
      fs_bridge_start
    else
      echo "[tunnel] FAILED on all ports (${PORT_LIST}) — check $LOG"
      tail -20 "$LOG"
      exit 1
    fi
    ;;

  down)
    # Stop bore systemd service if running
    if _has_systemd_bore && systemctl --user is-active --quiet bore-tunnel.service 2>/dev/null; then
      systemctl --user stop bore-tunnel.service && echo "[tunnel] Stopped (systemd/bore)." && exit 0
    fi
    # Stop cloudflared systemd service if running
    if _has_systemd_cf && systemctl --user is-active --quiet cloudflared-tunnel.service 2>/dev/null; then
      systemctl --user stop cloudflared-tunnel.service && echo "[tunnel] Stopped (systemd/cloudflared)." && exit 0
    fi
    # Kill direct bore process
    pkill -f "bore local 22" 2>/dev/null \
      && echo "[tunnel] Stopped (bore)." \
      || echo "[tunnel] Not running."
    ;;

  status)
    echo "━━━ Pocket Lab Tunnel Status ━━━"

    # ── 1. Process / systemd state ──────────────────────────
    BORE_PID=$(pgrep -f "bore.*local.*22" | head -1 || true)
    CF_PID=$(pgrep -f "cloudflared.*tcp.*22" | head -1 || true)
    SYSTEMD_BORE_STATE=""
    SYSTEMD_CF_STATE=""
    if _has_systemd_bore; then
      SYSTEMD_BORE_STATE=$(systemctl --user is-active bore-tunnel.service 2>/dev/null || echo "inactive")
    fi
    if _has_systemd_cf; then
      SYSTEMD_CF_STATE=$(systemctl --user is-active cloudflared-tunnel.service 2>/dev/null || echo "inactive")
    fi

    if [ -n "$BORE_PID" ]; then
      echo "[process]  bore      PID=${BORE_PID}  (systemd: ${SYSTEMD_BORE_STATE:-n/a})"
    elif [ -n "$SYSTEMD_BORE_STATE" ]; then
      echo "[process]  bore      PID=none  (systemd: ${SYSTEMD_BORE_STATE})"
    else
      echo "[process]  bore      DOWN"
    fi

    if [ -n "$CF_PID" ]; then
      echo "[process]  cloudflared  PID=${CF_PID}  (systemd: ${SYSTEMD_CF_STATE:-n/a})"
    fi

    # ── 2. bore-port.txt (last published state) ─────────────
    PORT_FILE="$REPO_DIR/bore-port.txt"
    if [ -f "$PORT_FILE" ]; then
      SAVED_PORT=$(grep '^port=' "$PORT_FILE" | cut -d= -f2)
      SAVED_HOST=$(grep '^host=' "$PORT_FILE" | cut -d= -f2)
      SAVED_SSH=$(grep  '^ssh='  "$PORT_FILE" | cut -d= -f2-)
      SAVED_TS=$(grep   '^updated=' "$PORT_FILE" | cut -d= -f2)
      echo "[port.txt] port=${SAVED_PORT}  host=${SAVED_HOST}  updated=${SAVED_TS}"
      echo "[port.txt] ssh → ${SAVED_SSH}"
    else
      echo "[port.txt] bore-port.txt not found"
      SAVED_PORT=""
      SAVED_HOST=""
    fi

    # ── 3. Live port from journal / log ─────────────────────
    LIVE_PORT=""
    if _has_systemd_bore && [ "$SYSTEMD_BORE_STATE" = "active" ]; then
      LIVE_PORT=$(_systemd_bore_port)
    fi
    if [ -z "$LIVE_PORT" ] && [ -f "$LOG" ]; then
      LIVE_PORT=$(grep "listening at" "$LOG" 2>/dev/null \
        | grep -oE ':[0-9]+' | tail -1 | tr -d ':' || true)
    fi
    if [ -n "$LIVE_PORT" ]; then
      echo "[live]     bore port=${LIVE_PORT}"
      if [ "${SAVED_PORT:-}" != "$LIVE_PORT" ]; then
        echo "[live]     WARNING: bore-port.txt shows port=${SAVED_PORT} but live is ${LIVE_PORT} — run: bash $0 sync-port"
      else
        echo "[live]     bore-port.txt in sync ✓"
      fi
    else
      echo "[live]     no live bore port detected"
    fi

    # ── 4. Reachability check ────────────────────────────────
    CHECK_PORT="${LIVE_PORT:-${SAVED_PORT:-}}"
    CHECK_HOST="${SAVED_HOST:-${BORE_HOST}}"
    if [ -n "$CHECK_PORT" ] && echo "$CHECK_PORT" | grep -qE '^[0-9]+$'; then
      echo "[reach]    checking ${CHECK_HOST}:${CHECK_PORT} ..."
      if timeout 5 bash -c "echo >/dev/tcp/${CHECK_HOST}/${CHECK_PORT}" 2>/dev/null; then
        echo "[reach]    ✓ TCP reachable — tunnel is live"
      else
        echo "[reach]    ✗ TCP unreachable — bore server may be down or port expired"
      fi
    else
      echo "[reach]    skipped (no numeric port available)"
    fi

    # ── 5. Last 5 bore log lines ─────────────────────────────
    if [ -f "$PORT_HISTORY" ]; then
      echo "[history]  last 10 entries in ~/.bore-port-history.log:"
      tail -10 "$PORT_HISTORY" | sed 's/^/           /'
    fi
    if [ -f "$LOG" ]; then
      echo "[log]      last 5 lines of $LOG:"
      tail -5 "$LOG" | sed 's/^/           /'
    fi
    if _has_systemd_bore && [ "$SYSTEMD_BORE_STATE" != "inactive" ]; then
      echo "[journal]  last 5 lines of bore-tunnel.service:"
      journalctl --user -u bore-tunnel.service -n 5 --no-pager 2>/dev/null \
        | sed 's/^/           /' || true
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ;;

  sync-port)
    git -C "$REPO_DIR" update-index --assume-unchanged bore-port.txt 2>/dev/null || true
    LIVE_PORT=""
    # Try systemd journal first
    if _has_systemd_bore; then
      LIVE_PORT=$(_systemd_bore_port)
    fi
    # Fallback: direct log
    if [ -z "$LIVE_PORT" ] && [ -f "$LOG" ]; then
      LIVE_PORT=$(grep "listening at" "$LOG" 2>/dev/null \
        | grep -oE ':[0-9]+' | tail -1 | tr -d ':' || true)
    fi
    if [ -n "$LIVE_PORT" ]; then
      echo "[tunnel] Syncing port ${LIVE_PORT} → bore-port.txt + GitHub..."
      push_port "$LIVE_PORT"
    else
      echo "[tunnel] Could not determine live port (is bore running?)"
      exit 1
    fi
    ;;

  diagnose)
    echo "━━━ Pocket Lab Tunnel Diagnose ━━━"
    FIXED=0
    FAILED=0

    # ── Check 1: GH_TOKEN present, readable, and has write access ──
    echo "[check 1/4] GH_TOKEN ..."

    # Helper: test a token and return a status string
    # Prints: ok | missing | no_read | no_write
    _test_token() {
      local TOK="$1"
      [ -z "$TOK" ] && echo "missing" && return
      # Read test
      local R_STATUS
      R_STATUS=$(curl -so /dev/null -w '%{http_code}' --max-time 6 \
        -H "Authorization: token ${TOK}" \
        "https://api.github.com/repos/Tsukieomie/pocket-lab-v2-6/contents/bore-port.txt")
      [ "$R_STATUS" != "200" ] && echo "no_read" && return
      # Write test (dry-run: try to get SHA, then attempt a no-op PUT with wrong SHA to see if 422 vs 403)
      local W_STATUS
      W_STATUS=$(curl -so /dev/null -w '%{http_code}' --max-time 6 -X PUT \
        -H "Authorization: token ${TOK}" \
        -H "Content-Type: application/json" \
        -d '{"message":"probe","content":"Cg==","sha":"0000000000000000000000000000000000000000"}' \
        "https://api.github.com/repos/Tsukieomie/pocket-lab-v2-6/contents/bore-port.txt")
      # 422 = wrong SHA (we have write access but SHA mismatch) — that's fine
      # 403/404/401 = no write permission
      case "$W_STATUS" in
        422|200|201) echo "ok" ;;
        *) echo "no_write" ;;
      esac
    }

    # Helper: prompt user for a new token and rotate ~/.bore_env
    _rotate_token() {
      echo "  → Open: https://github.com/settings/tokens/new?scopes=repo&description=pocket-lab-bore"
      echo "  → Create a classic token with 'repo' scope, then paste it here:"
      printf "  New GH_TOKEN: "
      read -r NEW_TOKEN
      NEW_TOKEN=$(echo "$NEW_TOKEN" | tr -d '[:space:]')
      if [ -z "$NEW_TOKEN" ]; then
        echo "  ✗ No token entered — skipping rotation"
        return 1
      fi
      # Validate new token before writing
      NEW_STATUS=$(_test_token "$NEW_TOKEN")
      if [ "$NEW_STATUS" != "ok" ]; then
        echo "  ✗ New token check failed (${NEW_STATUS}) — not saving"
        return 1
      fi
      # Rotate in ~/.bore_env
      grep -v '^GH_TOKEN=' "$BORE_ENV" > /tmp/_bore_env_tmp 2>/dev/null || true
      echo "GH_TOKEN=${NEW_TOKEN}" >> /tmp/_bore_env_tmp
      mv /tmp/_bore_env_tmp "$BORE_ENV"
      echo "  ✓ GH_TOKEN rotated in ${BORE_ENV}"
      # Re-export for rest of diagnose run
      GH_TOKEN_VAL="$NEW_TOKEN"
      return 0
    }

    GH_TOKEN_VAL=$(_gh_token)
    TOKEN_STATUS=$(_test_token "$GH_TOKEN_VAL")
    case "$TOKEN_STATUS" in
      ok)
        echo "  ✓ GH_TOKEN valid (read + write confirmed)"
        ;;
      missing)
        echo "  ✗ GH_TOKEN missing from ${BORE_ENV}"
        _rotate_token || FAILED=$((FAILED+1))
        ;;
      no_read)
        echo "  ✗ GH_TOKEN present but GitHub returned 4xx on read — token may be expired or revoked"
        _rotate_token || FAILED=$((FAILED+1))
        ;;
      no_write)
        echo "  ✗ GH_TOKEN present but has no Contents write permission"
        echo "    (fine-grained PAT without 'Contents: Read and write', or missing 'repo' scope)"
        _rotate_token || FAILED=$((FAILED+1))
        ;;
    esac

    # ── Check 2: bore binary present ────────────────────────
    echo "[check 2/4] bore binary ..."
    BORE_BIN=$(_bore_bin)
    if [ -z "$BORE_BIN" ]; then
      echo "  ✗ bore binary not found"
      echo "  → Auto-installing..."
      install_bore && BORE_BIN=$(_bore_bin) && echo "  ✓ bore installed: $BORE_BIN" || { echo "  ✗ install failed"; FAILED=$((FAILED+1)); }
    else
      echo "  ✓ bore binary: $BORE_BIN"
    fi

    # ── Check 3: bore server reachable on ctrl port ──────────
    echo "[check 3/4] bore server ${BORE_HOST}:${BORE_CTRL_PORT} ..."
    if timeout 5 bash -c "echo >/dev/tcp/${BORE_HOST}/${BORE_CTRL_PORT}" 2>/dev/null; then
      echo "  ✓ bore server reachable"
    else
      echo "  ✗ bore server ${BORE_HOST}:${BORE_CTRL_PORT} unreachable"
      echo "  → Check if Fly.io machine is running: fly status -a pocket-lab-bore"
      FAILED=$((FAILED+1))
    fi

    # ── Check 4: tunnel process + port reachability ──────────
    echo "[check 4/4] tunnel process + TCP reachability ..."
    BORE_PID=$(pgrep -f "bore.*local.*22" | head -1 || true)
    LIVE_PORT=""
    if _has_systemd_bore && systemctl --user is-active --quiet bore-tunnel.service 2>/dev/null; then
      LIVE_PORT=$(_systemd_bore_port)
    fi
    [ -z "$LIVE_PORT" ] && [ -f "$LOG" ] && \
      LIVE_PORT=$(grep "listening at" "$LOG" 2>/dev/null | grep -oE ':[0-9]+' | tail -1 | tr -d ':' || true)

    NEEDS_RESTART=false
    if [ -z "$BORE_PID" ]; then
      echo "  ✗ bore process not running"
      NEEDS_RESTART=true
    elif [ -z "$LIVE_PORT" ]; then
      echo "  ✗ bore running (PID=${BORE_PID}) but no port detected — likely stale"
      NEEDS_RESTART=true
    else
      # TCP reachability check
      SAVED_HOST=$(grep '^host=' "$REPO_DIR/bore-port.txt" 2>/dev/null | cut -d= -f2 || echo "$BORE_HOST")
      if timeout 5 bash -c "echo >/dev/tcp/${SAVED_HOST}/${LIVE_PORT}" 2>/dev/null; then
        echo "  ✓ tunnel reachable at ${SAVED_HOST}:${LIVE_PORT}"
        # Sync port.txt if out of date
        SAVED_PORT=$(grep '^port=' "$REPO_DIR/bore-port.txt" 2>/dev/null | cut -d= -f2 || echo "")
        if [ "${SAVED_PORT}" != "$LIVE_PORT" ]; then
          echo "  → bore-port.txt out of sync — resyncing..."
          push_port "$LIVE_PORT" && FIXED=$((FIXED+1))
        fi
      else
        echo "  ✗ bore running (PID=${BORE_PID}, port=${LIVE_PORT}) but TCP unreachable — stale connection"
        NEEDS_RESTART=true
      fi
    fi

    # ── Auto-fix: restart tunnel if needed ───────────────────
    if $NEEDS_RESTART; then
      echo "  → Auto-restarting tunnel..."
      # Kill stale processes
      pkill -f "bore.*local.*22" 2>/dev/null || true
      sleep 1
      # Reset failed systemd unit
      if _has_systemd_bore; then
        systemctl --user reset-failed bore-tunnel.service 2>/dev/null || true
        systemctl --user start bore-tunnel.service 2>/dev/null || true
        NEW_PORT=""
        for i in $(seq 1 20); do
          NEW_PORT=$(_systemd_bore_port)
          [ -n "$NEW_PORT" ] && break
          sleep 1
        done
      fi
      # Fallback to direct with port auto-fallback if systemd didn't work
      if [ -z "${NEW_PORT:-}" ]; then
        BORE_IP=$(getent ahostsv4 "${BORE_HOST}" 2>/dev/null | awk '/STREAM/{print $1; exit}' \
          || echo "${BORE_HOST}")
        D_SECRET_ARG=""
        [ -n "${BORE_SECRET}" ] && D_SECRET_ARG="--secret ${BORE_SECRET}"
        D_CONFIGURED="${BORE_CTRL_PORT:-2222}"
        D_PORT_LIST="${D_CONFIGURED}"
        # 443 intentionally excluded — see note above. Only try ports we
        # actually have a matching bore binary for.
        for P in 2222 8443; do
          [ "$P" != "$D_CONFIGURED" ] && D_PORT_LIST="${D_PORT_LIST} ${P}"
        done
        for TRY_PORT in $D_PORT_LIST; do
          timeout 3 bash -c "echo >/dev/tcp/${BORE_IP}/${TRY_PORT}" 2>/dev/null || continue
          if [ -z "$(_bore_bin "$TRY_PORT")" ]; then
            echo "  → ctrl=${TRY_PORT}: no matching bore binary — skipping"
            continue
          fi
          echo "  → Trying bore ctrl=${TRY_PORT} ..."
          NEW_PORT=$(_bore_try "$BORE_IP" "$TRY_PORT" "$D_SECRET_ARG" "$LOG") && \
            grep -v '^BORE_CTRL_PORT=' "$BORE_ENV" > /tmp/_bore_env_tmp 2>/dev/null || true && \
            echo "BORE_CTRL_PORT=${TRY_PORT}" >> /tmp/_bore_env_tmp && \
            mv /tmp/_bore_env_tmp "$BORE_ENV" || true
          [ -n "$NEW_PORT" ] && break || true
        done
      fi
      if [ -n "${NEW_PORT:-}" ]; then
        printf '%s  ctrl=%-4s  remote=%-5s  host=%s  result=OK(diagnose)\n' \
          "$(date '+%Y-%m-%d %H:%M:%S')" "${BORE_CTRL_PORT:-?}" "${NEW_PORT}" "${BORE_HOST}" >> "${PORT_HISTORY}"
        echo "  ✓ Tunnel restarted → ${BORE_HOST}:${NEW_PORT}"
        echo "  → SSH: ssh -p ${NEW_PORT} $(whoami)@${BORE_HOST}"
        push_port "$NEW_PORT"
        FIXED=$((FIXED+1))
      else
        echo "  ✗ Restart failed — check: bash $0 status"
        FAILED=$((FAILED+1))
      fi
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[diagnose] fixed=${FIXED}  failed=${FAILED}"
    [ "$FAILED" -eq 0 ] && echo "[diagnose] All checks passed ✓" || echo "[diagnose] Some issues need manual attention — see above"
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
    echo "Usage: $0 [up|down|status|diagnose|sync-port|install-bore|install-cloudflared|fs-bridge]"
    exit 1
    ;;
esac
