#!/bin/bash
# Auto-triggered by post-merge git hook when Vivobook pulls this repo
# Reconnects bore tunnel to the new sandbox bore server

set -e
BORE_ENV="$HOME/.bore_env"
LOG="/tmp/reconnect.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

# Read new bore server address from bore-port.txt
BORE_SERVER=$(grep '^bore_server=' "$(dirname "$0")/bore-port.txt" | cut -d= -f2)
BORE_SECRET=$(grep '^bore_secret=' "$(dirname "$0")/bore-port.txt" | cut -d= -f2)
BORE_HOST=$(echo "$BORE_SERVER" | cut -d: -f1)
BORE_CTRL=$(echo "$BORE_SERVER" | cut -d: -f2)

log "Reconnecting to bore server: $BORE_HOST (ctrl:$BORE_CTRL)"

# Update ~/.bore_env
if [ -f "$BORE_ENV" ]; then
  sed -i "s/^BORE_HOST=.*/BORE_HOST=$BORE_HOST/" "$BORE_ENV" 2>/dev/null || \
    echo "BORE_HOST=$BORE_HOST" >> "$BORE_ENV"
  sed -i "s/^BORE_SECRET=.*/BORE_SECRET=$BORE_SECRET/" "$BORE_ENV" 2>/dev/null || \
    echo "BORE_SECRET=$BORE_SECRET" >> "$BORE_ENV"
fi

# Kill existing bore client and restart pointing at new server
pkill -f "bore local" 2>/dev/null || true
sleep 1

# Start bore client pointing at this sandbox's bore server
# Expose local SSH port 22
nohup bore local 22 \
  --to "$BORE_HOST" \
  --port 7835 \
  --secret "$BORE_SECRET" \
  > /tmp/bore-sandbox-tunnel.log 2>&1 &

log "Bore client started (PID $!)"
log "Waiting for port assignment..."
sleep 4

# Extract assigned port from bore log
ASSIGNED=$(grep -oE 'remote_port=[0-9]+' /tmp/bore-sandbox-tunnel.log | tail -1 | cut -d= -f2)
log "Assigned remote port: $ASSIGNED"

# Push port back to GitHub bore-port.txt
if [ -n "$GH_TOKEN" ] || [ -f "$HOME/.bore-github-token" ]; then
  TOKEN="${GH_TOKEN:-$(cat $HOME/.bore-github-token 2>/dev/null)}"
  CONTENT="port=${ASSIGNED}
host=${BORE_HOST}
ssh=ssh -p ${ASSIGNED} $(whoami)@${BORE_HOST}
updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
machine=$(hostname -s)
status=connected"
  ENCODED=$(printf '%s' "$CONTENT" | base64 -w 0)
  SHA=$(curl -sf -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/Tsukieomie/pocket-lab-v2-6/contents/bore-port.txt" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")
  PAYLOAD="{\"message\":\"sandbox reconnect port $ASSIGNED\",\"content\":\"$ENCODED\",\"sha\":\"$SHA\"}"
  curl -sf -X PUT \
    -H "Authorization: token $TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "https://api.github.com/repos/Tsukieomie/pocket-lab-v2-6/contents/bore-port.txt" >/dev/null
  log "bore-port.txt updated on GitHub with port $ASSIGNED"
fi

echo "RECONNECT_DONE port=$ASSIGNED"
