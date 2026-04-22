#!/bin/bash
# perplexity-connect.sh
# Double-click launcher: gets bore port, opens Perplexity, auto-types
# the port message and hits Enter — zero manual input required.

TOKEN_FILE="/home/kenny/.bore-github-token"
REPO="Tsukieomie/pocket-lab-v2-6"
FILE="bore-port.txt"
LOGFILE="/var/log/bore-port-push.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"; }

# ── 1. Get bore port from journal (most reliable) ───────────────────────────
PORT=$(journalctl -u bore-tunnel.service -b --no-pager 2>/dev/null \
       | grep -oP 'remote_port=\K[0-9]+' | tail -1)

if [ -z "$PORT" ]; then
    notify-send "Perplexity Connect" "bore-tunnel not running — starting it..." --icon=dialog-warning
    /usr/local/bin/bore local 22 --to bore.pub &
    sleep 5
    PORT=$(journalctl -u bore-tunnel.service -b --no-pager 2>/dev/null \
           | grep -oP 'remote_port=\K[0-9]+' | tail -1)
fi

if [ -z "$PORT" ]; then
    notify-send "Perplexity Connect" "ERROR: Could not get bore port." --icon=dialog-error
    log "ERROR: Could not get bore port"
    exit 1
fi

log "Launcher: port $PORT"

# ── 2. Push fresh port to GitHub ─────────────────────────────────────────────
if [ -f "$TOKEN_FILE" ]; then
    GH_TOKEN=$(cat "$TOKEN_FILE")
    TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    CONTENT="port=${PORT}
host=bore.pub
ssh=ssh -p ${PORT} kenny@bore.pub
updated=${TIMESTAMP}
machine=$(hostname -s)
"
    ENCODED=$(printf '%s' "$CONTENT" | base64 -w 0)
    SHA=$(curl -sf -H "Authorization: token ${GH_TOKEN}" \
        "https://api.github.com/repos/${REPO}/contents/${FILE}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")
    PAYLOAD="{\"message\":\"bore port ${PORT} @ $(date '+%Y-%m-%d %H:%M')\",\"content\":\"${ENCODED}\",\"sha\":\"${SHA}\"}"
    [ -z "$SHA" ] && PAYLOAD="{\"message\":\"bore port ${PORT}\",\"content\":\"${ENCODED}\"}"
    curl -sf -X PUT \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "https://api.github.com/repos/${REPO}/contents/${FILE}" > /dev/null
    log "Port $PORT pushed to GitHub"
fi

# ── 3. Launch Perplexity desktop app ─────────────────────────────────────────
snap run perplexity-desktop 2>/dev/null &
SNAP_PID=$!

# ── 4. Wait for Perplexity window to appear (up to 20s) ──────────────────────
log "Waiting for Perplexity window..."
WINDOW_ID=""
for i in $(seq 1 40); do
    sleep 0.5
    WINDOW_ID=$(xdotool search --name "Perplexity" 2>/dev/null | tail -1)
    [ -n "$WINDOW_ID" ] && break
done

if [ -z "$WINDOW_ID" ]; then
    notify-send "Perplexity Connect" "Perplexity window not found. Open it manually." --icon=dialog-warning
    log "ERROR: Perplexity window not found"
    exit 1
fi

log "Window found: $WINDOW_ID"

# ── 5. Focus window and wait for it to fully load ────────────────────────────
xdotool windowactivate --sync "$WINDOW_ID"
sleep 3

# ── 6. Click the chat input area (bottom center of window) ───────────────────
# Get window geometry
GEOM=$(xdotool getwindowgeometry "$WINDOW_ID" 2>/dev/null)
WIN_X=$(echo "$GEOM" | grep -oP 'Position: \K[0-9]+')
WIN_Y=$(echo "$GEOM" | grep -oP 'Position: [0-9]+,\K[0-9]+')
WIN_W=$(echo "$GEOM" | grep -oP 'Geometry: \K[0-9]+')
WIN_H=$(echo "$GEOM" | grep -oP 'Geometry: [0-9]+x\K[0-9]+')

# Click ~85% down, horizontally centered (chat input box)
CLICK_X=$((WIN_X + WIN_W / 2))
CLICK_Y=$((WIN_Y + WIN_H * 85 / 100))

xdotool mousemove "$CLICK_X" "$CLICK_Y"
xdotool click 1
sleep 0.5

# ── 7. Type the message and send ─────────────────────────────────────────────
MSG="My bore tunnel is listening at bore.pub:${PORT} — please reconnect SSH and continue our session."

# Use xclip to paste (avoids xdotool mistyping special chars)
echo -n "$MSG" | xclip -selection clipboard
xdotool key ctrl+a          # select all existing text first
xdotool key Delete           # clear it
sleep 0.2
xdotool key ctrl+v           # paste message
sleep 0.3
xdotool key Return           # send

log "Message sent to Perplexity: bore.pub:${PORT}"
notify-send "Perplexity Connect" "Connected — bore.pub:${PORT} sent to Perplexity" --icon=utilities-terminal
