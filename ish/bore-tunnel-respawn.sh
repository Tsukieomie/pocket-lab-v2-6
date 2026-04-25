#!/bin/sh
# ============================================================
# ish/bore-tunnel-respawn.sh — Auto-respawning bore tunnel for iSH
#
# Designed to be launched from /etc/inittab as a respawn entry
# so iSH restarts it whenever it crashes or the phone resumes.
#
# Also called directly from /etc/profile on new shell open
# (with a lock guard so only one instance runs at a time).
#
# Config: /root/.bore_env
#   BORE_HOST=bore.pub        (or your VPS IP)
#   BORE_PORT=40188           (optional, omit for random)
#   BORE_SECRET=              (optional, for self-hosted bore)
#   GH_TOKEN=                 (optional, to push port to GitHub)
#
# Usage (inittab):
#   tun:respawn:/root/perplexity/ish/bore-tunnel-respawn.sh
#
# Usage (manual):
#   sh /root/perplexity/ish/bore-tunnel-respawn.sh
# ============================================================

BORE_ENV="/root/.bore_env"
LOCK="/tmp/.bore-tunnel.lock"
PORT_FILE="/root/perplexity/bore-port.txt"
LOG="/tmp/bore-tunnel-ish.log"
APPROVAL_REPO="Tsukieomie/pocket-lab-v2-6"

# ── Load config ───────────────────────────────────────────
BORE_HOST="bore.pub"
BORE_PORT=""
BORE_SECRET=""
GH_TOKEN=""
if [ -f "$BORE_ENV" ]; then
  BORE_HOST=$(grep '^BORE_HOST=' "$BORE_ENV" | cut -d= -f2 || echo "bore.pub")
  BORE_PORT=$(grep '^BORE_PORT=' "$BORE_ENV" | cut -d= -f2 || echo "")
  BORE_SECRET=$(grep '^BORE_SECRET=' "$BORE_ENV" | cut -d= -f2 || echo "")
  GH_TOKEN=$(grep '^GH_TOKEN=' "$BORE_ENV" | cut -d= -f2 || echo "")
fi

# ── Lock guard: prevent multiple instances ────────────────
if [ -f "$LOCK" ]; then
  OLD_PID=$(cat "$LOCK" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    # Already running — exit silently
    exit 0
  fi
  rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

# ── Resolve bore binary ───────────────────────────────────
BORE_BIN=""
for b in /usr/local/bin/bore /root/.local/bin/bore; do
  [ -x "$b" ] && BORE_BIN="$b" && break
done
if [ -z "$BORE_BIN" ]; then
  echo "[bore-ish] ERROR: bore not found. Run: sh /root/perplexity/upgrade-bore-ish.sh" >&2
  exit 1
fi

# ── Build bore args ───────────────────────────────────────
PORT_ARG=""
[ -n "$BORE_PORT" ] && PORT_ARG="--port $BORE_PORT"
SECRET_ARG=""
[ -n "$BORE_SECRET" ] && SECRET_ARG="--secret $BORE_SECRET"

# ── push_port: write bore-port.txt + push to GitHub ───────
push_port() {
  local PORT="$1"
  local TS
  TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%SZ')
  local MACHINE
  MACHINE=$(cat /proc/ish/host_info 2>/dev/null | grep "Device Name" | cut -d: -f2 | tr -d ' ' || echo "iPhone-iSH")

  # Write local port file
  cat > "$PORT_FILE" << PORTFILE
port=${PORT}
host=${BORE_HOST}
ssh=ssh -p ${PORT} root@${BORE_HOST}
updated=${TS}
machine=${MACHINE}
PORTFILE
  echo "[bore-ish] bore-port.txt updated → port=${PORT}"

  # Push to GitHub if token available
  if [ -z "$GH_TOKEN" ]; then
    echo "[bore-ish] No GH_TOKEN — port saved locally only"
    return 0
  fi

  local ENCODED
  ENCODED=$(base64 < "$PORT_FILE" | tr -d '\n')
  local SHA
  SHA=$(wget -qO- \
    --header="Authorization: token ${GH_TOKEN}" \
    --header="Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${APPROVAL_REPO}/contents/bore-port.txt" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

  local PAYLOAD
  if [ -n "$SHA" ]; then
    PAYLOAD="{\"message\":\"bore port ${PORT} @ ${TS} (iSH)\",\"content\":\"${ENCODED}\",\"sha\":\"${SHA}\"}"
  else
    PAYLOAD="{\"message\":\"bore port ${PORT} @ ${TS} (iSH)\",\"content\":\"${ENCODED}\"}"
  fi

  wget -qO- \
    --header="Authorization: token ${GH_TOKEN}" \
    --header="Content-Type: application/json" \
    --post-data="$PAYLOAD" \
    --method=PUT \
    "https://api.github.com/repos/${APPROVAL_REPO}/contents/bore-port.txt" \
    > /dev/null 2>&1 \
    && echo "[bore-ish] GitHub bore-port.txt updated " \
    || echo "[bore-ish] GitHub push failed (non-fatal)"
}

# ── Main loop ─────────────────────────────────────────────
echo "[bore-ish] Starting tunnel → ${BORE_HOST} (pid $$)" | tee "$LOG"

while true; do
  # Truncate log for fresh run
  : > "$LOG"

  # Start bore in background, capture output to log
  # shellcheck disable=SC2086
  "$BORE_BIN" local 22 --to "$BORE_HOST" $PORT_ARG $SECRET_ARG \
    >> "$LOG" 2>&1 &
  BORE_PID=$!

  # Poll for remote_port up to 15s
  LIVE_PORT=""
  for i in $(seq 1 15); do
    sleep 1
    LIVE_PORT=$(grep -oE 'remote_port=[0-9]+' "$LOG" 2>/dev/null | tail -1 | cut -d= -f2 || echo "")
    [ -n "$LIVE_PORT" ] && break
  done

  if [ -n "$LIVE_PORT" ]; then
    echo "[bore-ish] UP → ${BORE_HOST}:${LIVE_PORT}"
    push_port "$LIVE_PORT"
  else
    echo "[bore-ish] WARNING: bore started (pid $BORE_PID) but no port announced yet"
  fi

  # Wait for bore to exit (crash, phone sleep, etc.)
  wait $BORE_PID 2>/dev/null
  EXIT_CODE=$?
  echo "[bore-ish] bore exited (code $EXIT_CODE) — restarting in 5s..."
  sleep 5
done
