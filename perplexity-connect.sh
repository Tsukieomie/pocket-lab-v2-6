#!/bin/bash
# Perplexity Connect Launcher
# Double-click this to: refresh bore port on GitHub, then open Perplexity
# with "reconnect" pre-filled. Just hit Enter — that's it.

TOKEN_FILE="/home/kenny/.bore-github-token"
REPO="Tsukieomie/pocket-lab-v2-6"
FILE="bore-port.txt"
LOGFILE="/var/log/bore-port-push.log"

# ── 1. Get current port from journal ────────────────────────────────────────
PORT=$(journalctl -u bore-tunnel.service -b --no-pager 2>/dev/null \
       | grep -oP 'remote_port=\K[0-9]+' | tail -1)

if [ -z "$PORT" ]; then
    notify-send "Perplexity Connect" "bore-tunnel not running. Starting it now..." --icon=dialog-warning
    /usr/local/bin/bore local 22 --to bore.pub &
    sleep 4
    PORT=$(journalctl -u bore-tunnel.service -b --no-pager 2>/dev/null \
           | grep -oP 'remote_port=\K[0-9]+' | tail -1)
fi

if [ -z "$PORT" ]; then
    notify-send "Perplexity Connect" "Could not get bore port. Check bore-tunnel service." --icon=dialog-error
    exit 1
fi

# ── 2. Push fresh port to GitHub ─────────────────────────────────────────────
if [ -f "$TOKEN_FILE" ]; then
    GH_TOKEN=$(cat "$TOKEN_FILE")
    TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    HOSTNAME=$(hostname -s)
    CONTENT="port=${PORT}
host=bore.pub
ssh=ssh -p ${PORT} kenny@bore.pub
updated=${TIMESTAMP}
machine=${HOSTNAME}
"
    ENCODED=$(printf '%s' "$CONTENT" | base64 -w 0)
    SHA=$(curl -sf -H "Authorization: token ${GH_TOKEN}" \
        "https://api.github.com/repos/${REPO}/contents/${FILE}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

    if [ -n "$SHA" ]; then
        PAYLOAD="{\"message\":\"bore port ${PORT} @ $(date '+%Y-%m-%d %H:%M')\",\"content\":\"${ENCODED}\",\"sha\":\"${SHA}\"}"
    else
        PAYLOAD="{\"message\":\"bore port ${PORT} @ $(date '+%Y-%m-%d %H:%M')\",\"content\":\"${ENCODED}\"}"
    fi

    curl -sf -X PUT \
        -H "Authorization: token ${GH_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        "https://api.github.com/repos/${REPO}/contents/${FILE}" > /dev/null

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Launcher: port ${PORT} pushed to GitHub" >> "$LOGFILE"
fi

# ── 3. Open Perplexity with "reconnect" pre-typed ────────────────────────────
# URL-encode the message
MSG="reconnect"
ENCODED_MSG=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$MSG")
URL="https://www.perplexity.ai/?q=${ENCODED_MSG}&focus=internet"

# Open in Perplexity desktop snap app
snap run perplexity-desktop "$URL" 2>/dev/null &

notify-send "Perplexity Connect" "Port ${PORT} pushed to GitHub. Perplexity is opening..." --icon=utilities-terminal
