#!/bin/sh
# ============================================================
# ish/ish-auto-tunnel.sh — One-shot Dropbear + bore startup for iSH
#
# Wraps the manual flow the user previously ran by hand:
#
#   dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_hostkey
#   dropbear   -F -E -p 2225 -r /etc/dropbear/dropbear_ed25519_hostkey
#   bash linux/tunnel.sh up    (or: bore local 2225 --to <host> --secret ...)
#
# Idempotent and safe-by-default:
#   - Generates the Dropbear ed25519 host key only if missing.
#   - Starts Dropbear on port 2225 only if no sshd/dropbear is already
#     listening there. Existing processes are NEVER killed unless the
#     caller passes `restart`.
#   - Starts the bore tunnel via the repo-managed linux/tunnel.sh, which
#     reads ~/.bore_env for BORE_HOST / BORE_SECRET. If no secret is
#     configured and BORE_HOST is bore.pub, falls back to a public bore
#     forward of port 2225.
#   - Will NOT touch authorized_keys unless --install-key=PATH is given.
#   - Does NOT require gh / GH_TOKEN. GitHub push of bore-port.txt is
#     handled by tunnel.sh when a token is present and silently skipped
#     otherwise.
#
# Usage (from iSH Alpine host shell, not chroot):
#   sh /root/perplexity/ish/ish-auto-tunnel.sh                 # up (default)
#   sh /root/perplexity/ish/ish-auto-tunnel.sh up
#   sh /root/perplexity/ish/ish-auto-tunnel.sh status
#   sh /root/perplexity/ish/ish-auto-tunnel.sh restart         # stop + up
#   sh /root/perplexity/ish/ish-auto-tunnel.sh stop
#   sh /root/perplexity/ish/ish-auto-tunnel.sh check           # syntax + plan
#
# Optional flags (only honoured by `up` / `restart`):
#   --port=N                 SSH port for Dropbear (default 2225)
#   --install-key=PATH       Append PATH (a single pubkey file) to
#                            /root/.ssh/authorized_keys if not present.
#   --skip-tunnel            Just start Dropbear, don't run tunnel.sh.
#   --skip-dropbear          Just run tunnel.sh, don't manage Dropbear.
#
# Exit codes:
#   0  success
#   1  generic failure (see logs)
#   2  bad arguments
#   3  prerequisite missing (no apk and no bore/dropbear binary)
# ============================================================
set -eu

# ── Locate repo root (script lives in <repo>/ish/) ───────────
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
TUNNEL_SH="$REPO_DIR/linux/tunnel.sh"

# ── Defaults / config ────────────────────────────────────────
SSH_PORT=2225
HOSTKEY_DIR="/etc/dropbear"
HOSTKEY="$HOSTKEY_DIR/dropbear_ed25519_hostkey"
DROPBEAR_LOG="/tmp/dropbear-2225.log"
BORE_LOG="/tmp/bore-tunnel.log"
PORT_FILE="$REPO_DIR/bore-port.txt"

ACTION="up"
INSTALL_KEY=""
SKIP_TUNNEL=0
SKIP_DROPBEAR=0

log() { printf '[ish-auto-tunnel] %s\n' "$*"; }
warn() { printf '[ish-auto-tunnel] WARN: %s\n' "$*" >&2; }
die()  { printf '[ish-auto-tunnel] ERROR: %s\n' "$*" >&2; exit "${2:-1}"; }

# ── Parse args ───────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    up|status|restart|stop|check) ACTION="$arg" ;;
    --port=*)        SSH_PORT="${arg#--port=}" ;;
    --install-key=*) INSTALL_KEY="${arg#--install-key=}" ;;
    --skip-tunnel)   SKIP_TUNNEL=1 ;;
    --skip-dropbear) SKIP_DROPBEAR=1 ;;
    -h|--help)
      sed -n '3,40p' "$0"
      exit 0
      ;;
    *) die "unknown argument: $arg" 2 ;;
  esac
done

case "$SSH_PORT" in
  ''|*[!0-9]*) die "--port must be numeric" 2 ;;
esac

# ── Helpers ──────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# port_listening N — true if anything is bound to :N
port_listening() {
  P="$1"
  # Try several tools — iSH usually has busybox netstat
  if have ss; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${P}\$" && return 0
  fi
  if have netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${P}\$" && return 0
  fi
  # busybox fallback
  busybox netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${P}\$" && return 0
  return 1
}

# pgrep_dropbear — robust process check on busybox (no -f on iSH pgrep)
pgrep_dropbear() {
  if have pgrep && pgrep -f "dropbear.*-p ${SSH_PORT}" >/dev/null 2>&1; then
    return 0
  fi
  ps -ef 2>/dev/null | grep -v grep | grep -q "dropbear.*-p *${SSH_PORT}" && return 0
  busybox ps 2>/dev/null | grep -v grep | grep -q "dropbear.*-p *${SSH_PORT}" && return 0
  return 1
}

# ── Package install (best-effort, never fatal in `check`) ────
ensure_pkg() {
  PKG="$1"; BIN="$2"
  have "$BIN" && return 0
  if have apk; then
    log "installing $PKG via apk..."
    apk add --no-cache "$PKG" >/dev/null 2>&1 \
      || warn "apk add $PKG failed (continuing)"
  else
    warn "no apk available and $BIN missing"
  fi
  have "$BIN"
}

ensure_dropbear() {
  ensure_pkg dropbear dropbearkey || true
  have dropbear || die "dropbear binary not available — install manually" 3
  have dropbearkey || die "dropbearkey not available — install manually" 3
}

ensure_bore() {
  # Repo ships custom bore binaries; tunnel.sh prefers them. We only
  # need bore on PATH if tunnel.sh is going to be skipped — which we
  # never do here. tunnel.sh has its own install-bore subcommand.
  return 0
}

# ── Dropbear: hostkey + start ────────────────────────────────
ensure_hostkey() {
  if [ ! -d "$HOSTKEY_DIR" ]; then
    log "creating $HOSTKEY_DIR (mode 700)"
    mkdir -p "$HOSTKEY_DIR"
    chmod 700 "$HOSTKEY_DIR" 2>/dev/null || true
  fi
  if [ -s "$HOSTKEY" ]; then
    log "host key present: $HOSTKEY"
    return 0
  fi
  log "generating Dropbear ed25519 host key..."
  dropbearkey -t ed25519 -f "$HOSTKEY" >/dev/null 2>&1 \
    || die "dropbearkey failed (see $HOSTKEY)"
  chmod 600 "$HOSTKEY" 2>/dev/null || true
  log "host key generated."
}

ensure_root_ssh_dir() {
  HOME_DIR="${HOME:-/root}"
  SSH_DIR="$HOME_DIR/.ssh"
  AKEYS="$SSH_DIR/authorized_keys"
  [ -d "$SSH_DIR" ] || { mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR" 2>/dev/null || true; }
  [ -f "$AKEYS" ] || { : > "$AKEYS"; chmod 600 "$AKEYS" 2>/dev/null || true; }

  if [ -n "$INSTALL_KEY" ]; then
    [ -r "$INSTALL_KEY" ] || die "--install-key file not readable: $INSTALL_KEY"
    KEY_LINE=$(awk 'NF && $1 !~ /^#/ {print; exit}' "$INSTALL_KEY")
    [ -n "$KEY_LINE" ] || die "--install-key file is empty: $INSTALL_KEY"
    if grep -Fxq "$KEY_LINE" "$AKEYS" 2>/dev/null; then
      log "authorized_keys already contains key from $INSTALL_KEY"
    else
      printf '%s\n' "$KEY_LINE" >> "$AKEYS"
      chmod 600 "$AKEYS" 2>/dev/null || true
      log "appended key from $INSTALL_KEY to $AKEYS"
    fi
  fi
}

start_dropbear() {
  if pgrep_dropbear || port_listening "$SSH_PORT"; then
    log "Dropbear already listening on :$SSH_PORT — leaving alone"
    return 0
  fi
  log "starting Dropbear on :$SSH_PORT ..."
  # -F = foreground so we can detach manually
  # -E = stderr to terminal (we redirect to log)
  # -r = host key
  # -p = listen port
  # Run detached so this script can return.
  ( dropbear -F -E -p "$SSH_PORT" -r "$HOSTKEY" >"$DROPBEAR_LOG" 2>&1 ) &
  DBP_PID=$!
  # Give it a moment to bind
  i=0
  while [ "$i" -lt 5 ]; do
    sleep 1
    if port_listening "$SSH_PORT"; then
      log "Dropbear up (pid $DBP_PID) — listening on :$SSH_PORT"
      return 0
    fi
    kill -0 "$DBP_PID" 2>/dev/null || break
    i=$((i + 1))
  done
  warn "Dropbear did not bind :$SSH_PORT within 5s — see $DROPBEAR_LOG"
  return 1
}

stop_dropbear() {
  if have pkill; then
    pkill -f "dropbear.*-p *${SSH_PORT}" 2>/dev/null || true
  else
    PIDS=$(ps -ef 2>/dev/null | grep -v grep | grep "dropbear.*-p *${SSH_PORT}" | awk '{print $2}')
    [ -n "$PIDS" ] && kill $PIDS 2>/dev/null || true
  fi
  log "Dropbear stop signal sent (port $SSH_PORT)"
}

# ── Bore tunnel via repo-managed tunnel.sh ──────────────────
start_tunnel() {
  if [ ! -r "$TUNNEL_SH" ]; then
    warn "tunnel.sh not found at $TUNNEL_SH — skipping bore"
    return 0
  fi
  # tunnel.sh forwards port 22 by default. We want :$SSH_PORT instead.
  # Override via BORE_LOCAL_PORT if tunnel.sh supports it; else fall
  # back to a direct bore invocation when ~/.bore_env supplies a
  # secret (manual-flow parity).
  if grep -q 'BORE_LOCAL_PORT' "$TUNNEL_SH" 2>/dev/null; then
    log "starting tunnel via tunnel.sh (BORE_LOCAL_PORT=$SSH_PORT) ..."
    BORE_LOCAL_PORT="$SSH_PORT" bash "$TUNNEL_SH" up || warn "tunnel.sh up returned non-zero"
    return 0
  fi
  # Fallback: direct bore call so we don't have to patch tunnel.sh.
  BORE_ENV="${HOME:-/root}/.bore_env"
  BORE_HOST=""; BORE_SECRET=""
  if [ -r "$BORE_ENV" ]; then
    BORE_HOST=$(grep '^BORE_HOST=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || true)
    BORE_SECRET=$(grep '^BORE_SECRET=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || true)
  fi
  [ -n "$BORE_HOST" ] || BORE_HOST="bore.pub"
  BORE_BIN=""
  for b in /usr/local/bin/bore "${HOME:-/root}/.local/bin/bore" \
           "$REPO_DIR/bore-custom-2222"; do
    [ -x "$b" ] && BORE_BIN="$b" && break
  done
  if [ -z "$BORE_BIN" ]; then
    warn "no bore binary — run: bash $TUNNEL_SH install-bore"
    return 0
  fi
  # If host requires a secret and we don't have one, refuse to start
  # an unauthenticated attempt that we know will fail.
  case "$BORE_HOST" in
    bore.pub) ;;  # public, no secret needed
    *)
      if [ -z "$BORE_SECRET" ]; then
        warn "BORE_HOST=$BORE_HOST requires BORE_SECRET in $BORE_ENV — bore not started"
        warn "set BORE_SECRET=... in ~/.bore_env, or use --skip-tunnel"
        return 0
      fi
      ;;
  esac
  SECRET_ARG=""
  [ -n "$BORE_SECRET" ] && SECRET_ARG="--secret $BORE_SECRET"
  log "starting bore: $BORE_BIN local $SSH_PORT --to $BORE_HOST ..."
  # shellcheck disable=SC2086
  ( "$BORE_BIN" local "$SSH_PORT" --to "$BORE_HOST" $SECRET_ARG \
      >"$BORE_LOG" 2>&1 ) &
  sleep 3
  LIVE_PORT=$(sed 's/\x1b\[[0-9;]*m//g' "$BORE_LOG" 2>/dev/null \
              | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 || true)
  if [ -n "$LIVE_PORT" ]; then
    log "bore up — remote_port=$LIVE_PORT host=$BORE_HOST"
    cat > "$PORT_FILE" <<EOF
port=${LIVE_PORT}
host=${BORE_HOST}
ssh=ssh -p ${LIVE_PORT} root@${BORE_HOST}
updated=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
machine=$(hostname 2>/dev/null || echo iSH)
EOF
    log "wrote $PORT_FILE"
  else
    warn "bore started but no remote_port observed — see $BORE_LOG"
  fi
}

stop_tunnel() {
  if have pkill; then
    pkill -f "bore.*local.*${SSH_PORT}" 2>/dev/null || true
  fi
  log "bore stop signal sent"
}

# ── Status report ───────────────────────────────────────────
report_status() {
  echo "── ish-auto-tunnel status ──"
  if pgrep_dropbear || port_listening "$SSH_PORT"; then
    echo "Dropbear: UP on :$SSH_PORT"
  else
    echo "Dropbear: DOWN"
  fi
  if have pgrep && pgrep -f "bore.*local.*${SSH_PORT}" >/dev/null 2>&1; then
    echo "bore:     RUNNING"
  elif have pgrep && pgrep -f 'bore.*local' >/dev/null 2>&1; then
    echo "bore:     RUNNING (different local port)"
  else
    echo "bore:     not running"
  fi
  if [ -r "$PORT_FILE" ]; then
    echo "── $PORT_FILE ──"
    cat "$PORT_FILE"
  fi
  if [ -r "$BORE_LOG" ]; then
    LIVE_PORT=$(sed 's/\x1b\[[0-9;]*m//g' "$BORE_LOG" 2>/dev/null \
                | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 || true)
    BORE_ENV="${HOME:-/root}/.bore_env"
    HOST=$(grep '^BORE_HOST=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || echo bore.pub)
    [ -n "$LIVE_PORT" ] && echo "Connect: ssh -p $LIVE_PORT root@$HOST"
  fi
}

# ── check: syntax + plan only, no side effects ──────────────
do_check() {
  log "syntax check: this script"
  sh -n "$0" && log "OK"
  if [ -r "$TUNNEL_SH" ]; then
    log "syntax check: $TUNNEL_SH"
    bash -n "$TUNNEL_SH" && log "OK"
  fi
  log "plan:"
  if [ -s "$HOSTKEY" ]; then HK_NOTE='(present)'; else HK_NOTE='(would generate)'; fi
  echo "  - host key: $HOSTKEY $HK_NOTE"
  if pgrep_dropbear || port_listening "$SSH_PORT"; then
    DB_NOTE='leave running'
  else
    DB_NOTE='start'
  fi
  echo "  - Dropbear: would $DB_NOTE on :$SSH_PORT"
  echo "  - bore:     would invoke $TUNNEL_SH up (or fallback bore on :$SSH_PORT)"
}

# ── Main ────────────────────────────────────────────────────
case "$ACTION" in
  check)
    do_check
    ;;
  status)
    report_status
    ;;
  stop)
    stop_tunnel
    [ "$SKIP_DROPBEAR" -eq 1 ] || stop_dropbear
    ;;
  restart)
    stop_tunnel
    [ "$SKIP_DROPBEAR" -eq 1 ] || stop_dropbear
    sleep 1
    [ "$SKIP_DROPBEAR" -eq 1 ] || { ensure_dropbear; ensure_hostkey; ensure_root_ssh_dir; start_dropbear; }
    [ "$SKIP_TUNNEL"   -eq 1 ] || start_tunnel
    report_status
    ;;
  up)
    [ "$SKIP_DROPBEAR" -eq 1 ] || { ensure_dropbear; ensure_hostkey; ensure_root_ssh_dir; start_dropbear; }
    [ "$SKIP_TUNNEL"   -eq 1 ] || start_tunnel
    report_status
    ;;
  *)
    die "unknown action: $ACTION" 2
    ;;
esac
