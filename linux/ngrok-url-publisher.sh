#!/usr/bin/env bash
# ngrok-url-publisher.sh
# Watches the local ngrok admin API (127.0.0.1:4040) and pushes the current
# public tunnel URL to ngrok-url.txt in the pocket-lab-v2-6 repo whenever
# it changes. Mirrors the legacy bore-port.txt pattern so any agent
# (Perplexity Computer, scheduled tasks, future sessions) can discover the
# live URL with a single curl to raw.githubusercontent.com.
#
# Requirements:
#   - ngrok running locally (admin API on 127.0.0.1:4040)
#   - gh CLI authenticated (gh auth status)  OR  GH_TOKEN in ~/.bore_env
#   - jq, curl
#
# Run manually:    bash ~/pocket-lab-v2-6/linux/ngrok-url-publisher.sh
# Run as service:  systemctl --user enable --now ngrok-url-publisher.service
set -euo pipefail

REPO="${REPO:-Tsukieomie/pocket-lab-v2-6}"
REPO_DIR="${REPO_DIR:-$HOME/pocket-lab-v2-6}"
URL_FILE="$REPO_DIR/ngrok-url.txt"
ADMIN_API="${ADMIN_API:-http://127.0.0.1:4040/api/tunnels}"
POLL_SECS="${POLL_SECS:-15}"
PORT="${PORT:-7779}"

# Source GH_TOKEN if present
[ -f "$HOME/.bore_env" ] && set -a && . "$HOME/.bore_env" && set +a

log() { printf '[ngrok-url-publisher] %s\n' "$*" >&2; }

get_current_url() {
  curl -sf --max-time 5 "$ADMIN_API" 2>/dev/null \
    | jq -r --argjson p "$PORT" '
        .tunnels[]
        | select(.config.addr | test(":\($p)$"))
        | .public_url
      ' 2>/dev/null \
    | head -n1
}

get_published_url() {
  [ -f "$URL_FILE" ] || return 0
  grep '^url=' "$URL_FILE" | cut -d= -f2- | head -n1
}

publish() {
  local url="$1"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  cat > "$URL_FILE" <<EOF
url=$url
updated=$now
port=$PORT
EOF

  cd "$REPO_DIR"
  # Stage + commit only if there's a real change
  if ! git diff --quiet -- ngrok-url.txt; then
    git add ngrok-url.txt
    git -c user.email="ngrok-publisher@local" \
        -c user.name="ngrok-url-publisher" \
        commit -m "tunnel: ngrok URL update — $url ($now)" >/dev/null
    if git push origin HEAD:main 2>&1 | tail -1 | log; then
      log "published $url"
    else
      log "push failed (will retry next poll)"
    fi
  fi
}

main() {
  command -v jq >/dev/null   || { log "ERROR: jq not installed"; exit 1; }
  command -v curl >/dev/null || { log "ERROR: curl not installed"; exit 1; }
  [ -d "$REPO_DIR/.git" ]    || { log "ERROR: $REPO_DIR is not a git repo"; exit 1; }

  log "watching $ADMIN_API (port $PORT) every ${POLL_SECS}s -> $URL_FILE"

  while true; do
    current="$(get_current_url || true)"
    published="$(get_published_url || true)"

    if [ -n "$current" ] && [ "$current" != "$published" ]; then
      log "change detected: '$published' -> '$current'"
      publish "$current" || log "publish failed (continuing)"
    fi
    sleep "$POLL_SECS"
  done
}

# Run once if --once, otherwise loop
if [ "${1:-}" = "--once" ]; then
  url="$(get_current_url || true)"
  [ -n "$url" ] || { log "no active ngrok tunnel on :$PORT"; exit 1; }
  publish "$url"
else
  main
fi
