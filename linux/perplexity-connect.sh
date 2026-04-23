#!/bin/bash
# perplexity-connect.sh
# Double-click launcher: gets bore port, opens Perplexity Comet (Electron wrapper),
# auto-types the port message and hits Enter — zero manual input required.

TOKEN_FILE="/home/kenny/.bore-github-token"
REPO="Tsukieomie/pocket-lab-v2-6"
FILE="bore-port.txt"
LOGFILE="/tmp/perplexity-connect.log"
WRAPPER_DIR="$HOME/perplexity-linux-wrapper"
LAUNCH_SCRIPT="$HOME/pocket-lab-v2-6/linux/launch-computer.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"; }

# ── 1. Get bore port from journal (most reliable) ───────────────────────────
PORT=$(journalctl --user -u bore-tunnel.service -b --no-pager 2>/dev/null \
       | grep -oP 'remote_port=\K[0-9]+' | tail -1)

# Fallback: read from bore-port.txt in repo
if [ -z "$PORT" ] && [ -f "$HOME/pocket-lab-v2-6/bore-port.txt" ]; then
    PORT=$(grep '^port=' "$HOME/pocket-lab-v2-6/bore-port.txt" | cut -d= -f2)
fi

if [ -z "$PORT" ]; then
    notify-send "Perplexity Comet" "bore-tunnel not running — starting it..." --icon=dialog-warning
    systemctl --user start bore-tunnel.service 2>/dev/null || \
        bash "$HOME/pocket-lab-v2-6/linux/tunnel.sh" up
    sleep 5
    PORT=$(journalctl --user -u bore-tunnel.service -b --no-pager 2>/dev/null \
           | grep -oP 'remote_port=\K[0-9]+' | tail -1)
fi

if [ -z "$PORT" ]; then
    notify-send "Perplexity Comet" "ERROR: Could not get bore port." --icon=dialog-error
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
    HTTP=$(curl -sf -w "%{http_code}" -o /dev/null -X PUT \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "https://api.github.com/repos/${REPO}/contents/${FILE}")
    log "Port $PORT pushed to GitHub (HTTP $HTTP)"
fi

# ── 3. Launch Perplexity Comet (Electron wrapper) ────────────────────────────
# Check if already running
if pgrep -f "perplexity-linux-wrapper" > /dev/null 2>&1; then
    log "Perplexity Comet already running — focusing window"
    xdotool search --name "Perplexity Computer" windowactivate --sync 2>/dev/null || true
else
    log "Launching Perplexity Comet (Electron wrapper)..."
    if [ -f "$LAUNCH_SCRIPT" ]; then
        bash "$LAUNCH_SCRIPT" &
    elif [ -d "$WRAPPER_DIR" ]; then
        # Fallback: launch directly
        GNOME_PID=$(pgrep -u kenny gnome-shell | head -1)
        export DISPLAY=$(grep -z '^DISPLAY=' /proc/$GNOME_PID/environ 2>/dev/null | tr -d '\0' | cut -d= -f2- || echo ":0")
        export XAUTHORITY=$(grep -z '^XAUTHORITY=' /proc/$GNOME_PID/environ 2>/dev/null | tr -d '\0' | cut -d= -f2-)
        export XDG_RUNTIME_DIR=/run/user/1000
        unset WAYLAND_DISPLAY
        "$HOME/perplexity-linux-wrapper/node_modules/electron/dist/electron" \
            "$WRAPPER_DIR" \
            --user-data-dir="$HOME/.config/perplexity-computer" \
            --ozone-platform=x11 \
            --no-sandbox &
    else
        notify-send "Perplexity Comet" "ERROR: perplexity-linux-wrapper not found at $WRAPPER_DIR" --icon=dialog-error
        log "ERROR: wrapper not found"
        exit 1
    fi
fi

# ── 4. Wait for Perplexity Computer window to appear (up to 20s) ─────────────
log "Waiting for Perplexity Computer window..."
WINDOW_ID=""
for i in $(seq 1 40); do
    sleep 0.5
    WINDOW_ID=$(xdotool search --name "Perplexity Computer" 2>/dev/null | tail -1)
    [ -n "$WINDOW_ID" ] && break
done

if [ -z "$WINDOW_ID" ]; then
    notify-send "Perplexity Comet" "Window not found — check if wrapper launched." --icon=dialog-warning
    log "ERROR: Perplexity Computer window not found"
    exit 1
fi

log "Window found: $WINDOW_ID"

# ── 5. Focus window and wait for it to fully load ────────────────────────────
xdotool windowactivate --sync "$WINDOW_ID"
sleep 3

# ── 6. Click the chat input and type the SSH port ────────────────────────────
# Get window geometry — click bottom-center for the chat input
GEOM=$(xdotool getwindowgeometry "$WINDOW_ID" 2>/dev/null)
WIN_X=$(echo "$GEOM" | grep -oP 'Position: \K[0-9]+')
WIN_Y=$(echo "$GEOM" | grep -oP 'Position: [0-9]+,\K[0-9]+')
WIN_W=$(echo "$GEOM" | grep -oP 'Geometry: \K[0-9]+')
WIN_H=$(echo "$GEOM" | grep -oP 'Geometry: [0-9]+x\K[0-9]+')

# Chat input is near bottom-center
CLICK_X=$((WIN_X + WIN_W / 2))
CLICK_Y=$((WIN_Y + WIN_H - 80))

xdotool mousemove "$CLICK_X" "$CLICK_Y"
xdotool click 1
sleep 0.5

SSH_MSG="My laptop bore tunnel is live: ssh -p ${PORT} kenny@bore.pub"
xdotool type --clearmodifiers --delay 20 "$SSH_MSG"
sleep 0.3
xdotool key Return

log "Sent SSH port $PORT to Perplexity Comet"
notify-send "Perplexity Comet" "Connected — bore port ${PORT} sent to chat" --icon=dialog-information
