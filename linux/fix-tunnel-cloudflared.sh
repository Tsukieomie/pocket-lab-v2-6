#!/usr/bin/env bash
# ============================================================
# linux/fix-tunnel-cloudflared.sh — Auto-fix for blocked bore ports
#
# Bore ctrl ports 2222 and 8443 are blocked on this network.
# This script switches Pocket Lab to cloudflared (HTTPS/443)
# which bypasses all standard port blocks.
#
# What it does:
#   1. Installs cloudflared binary (~60 MB, once)
#   2. Installs + enables the systemd user service
#   3. Starts the tunnel and waits for a hostname
#   4. Pushes the new hostname to bore-port.txt on GitHub
#   5. Prints the SSH proxy-jump command to connect
#
# Usage (one command):
#   bash ~/pocket-lab-v2-6/linux/fix-tunnel-cloudflared.sh
# ============================================================
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BORE_ENV="${HOME}/.bore_env"
CF_SERVICE="cloudflared-tunnel.service"
CF_SERVICE_SRC="$REPO_DIR/linux/system/cloudflared-tunnel.service"
CF_SERVICE_DST="${HOME}/.config/systemd/user/${CF_SERVICE}"
CF_BIN="${HOME}/.local/bin/cloudflared"

echo "╔══════════════════════════════════════════════════════╗"
echo "║   Pocket Lab — Switch to cloudflared tunnel         ║"
echo "║   (bore ports 2222/8443 blocked → HTTPS/443 fix)    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Stop bore if running ─────────────────────────────
echo "[1/5] Stopping bore tunnel (if running)..."
pkill -f "bore.*local.*22" 2>/dev/null && echo "  bore stopped" || echo "  bore was not running"
if systemctl --user is-active --quiet bore-tunnel.service 2>/dev/null; then
  systemctl --user stop bore-tunnel.service 2>/dev/null || true
  echo "  bore-tunnel.service stopped"
fi

# ── Step 2: Install cloudflared ──────────────────────────────
echo "[2/5] Installing cloudflared..."
mkdir -p "${HOME}/.local/bin"
if [ -x "$CF_BIN" ]; then
  echo "  Already installed: $($CF_BIN --version 2>&1 | head -1)"
else
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  CF_ARCH="amd64"  ;;
    aarch64) CF_ARCH="arm64"  ;;
    armv7l)  CF_ARCH="arm"    ;;
    *) echo "  ERROR: Unknown arch $ARCH"; exit 1 ;;
  esac
  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  echo "  Downloading $URL ..."
  curl -fsSL --progress-bar "$URL" -o "$CF_BIN"
  chmod +x "$CF_BIN"
  echo "  Installed: $($CF_BIN --version 2>&1 | head -1)"
fi

# ── Step 3: Install systemd service ──────────────────────────
echo "[3/5] Installing systemd user service..."
mkdir -p "${HOME}/.config/systemd/user"
cp "$CF_SERVICE_SRC" "$CF_SERVICE_DST"
systemctl --user daemon-reload
systemctl --user disable bore-tunnel.service 2>/dev/null && echo "  bore-tunnel.service disabled" || true
systemctl --user enable "$CF_SERVICE"
echo "  ${CF_SERVICE} enabled"

# ── Step 4: Start tunnel and wait for hostname ────────────────
echo "[4/5] Starting tunnel..."
systemctl --user restart "$CF_SERVICE"
echo "  Waiting for cloudflared hostname (up to 30s)..."
CF_HOST=""
for i in $(seq 1 30); do
  CF_HOST=$(journalctl --user -u "$CF_SERVICE" -n 500 --no-pager 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oE '[a-z0-9-]+\.trycloudflare\.com' | tail -1 || echo "")
  if [ -n "$CF_HOST" ]; then
    echo "  Hostname: $CF_HOST"
    break
  fi
  printf "  %ds...\r" "$i"
  sleep 1
done

if [ -z "$CF_HOST" ]; then
  echo ""
  echo "  WARNING: No hostname after 30s — check logs:"
  echo "    journalctl --user -u cloudflared-tunnel.service -n 50"
  exit 1
fi

# ── Step 5: Sync hostname to bore-port.txt + GitHub ──────────
echo "[5/5] Syncing hostname to repo..."
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
cat > "$REPO_DIR/bore-port.txt" << PORTFILE
port=cloudflared
host=${CF_HOST}
ssh=ssh -o ProxyCommand="cloudflared access tcp --hostname https://${CF_HOST}" user@localhost
updated=${TIMESTAMP}
machine=$(hostname)
tunnel=cloudflared
PORTFILE

git -C "$REPO_DIR" update-index --assume-unchanged bore-port.txt 2>/dev/null || true
echo "  bore-port.txt updated locally"

# Push to GitHub via gh api (mirrors tunnel.sh fix)
REPO="Tsukieomie/pocket-lab-v2-6"
FILE="bore-port.txt"
ENCODED=$(base64 -w0 < "$REPO_DIR/bore-port.txt" 2>/dev/null || base64 < "$REPO_DIR/bore-port.txt")
PUSH_OK=false

if command -v gh >/dev/null 2>&1 && gh api user --jq '.login' >/dev/null 2>&1; then
  SHA=$(gh api "repos/${REPO}/contents/${FILE}" --jq '.sha' 2>/dev/null || echo "")
  if [ -n "$SHA" ]; then
    gh api "repos/${REPO}/contents/${FILE}" -X PUT \
      -f message="tunnel: cloudflared hostname ${CF_HOST}" \
      -f content="$ENCODED" \
      -f sha="$SHA" \
      --jq '.commit.sha' >/dev/null 2>&1 && PUSH_OK=true || true
  else
    gh api "repos/${REPO}/contents/${FILE}" -X PUT \
      -f message="tunnel: cloudflared hostname ${CF_HOST}" \
      -f content="$ENCODED" \
      --jq '.commit.sha' >/dev/null 2>&1 && PUSH_OK=true || true
  fi
elif [ -f "$BORE_ENV" ]; then
  GH_TOKEN=$(grep '^GH_TOKEN=' "$BORE_ENV" | cut -d= -f2 || echo "")
  if [ -n "$GH_TOKEN" ]; then
    SHA=$(curl -sf --max-time 8 \
      -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/${REPO}/contents/${FILE}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")
    PAYLOAD="{\"message\":\"tunnel: cloudflared hostname ${CF_HOST}\",\"content\":\"${ENCODED}\""
    [ -n "$SHA" ] && PAYLOAD="${PAYLOAD},\"sha\":\"${SHA}\""
    PAYLOAD="${PAYLOAD}}"
    curl -sf --max-time 10 -X PUT \
      -H "Authorization: token $GH_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$PAYLOAD" \
      "https://api.github.com/repos/${REPO}/contents/${FILE}" > /dev/null \
      && PUSH_OK=true || true
  fi
fi

$PUSH_OK && echo "  GitHub bore-port.txt synced ✓" || echo "  GitHub push skipped (non-fatal)"

# ── Done ─────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  TUNNEL UP via cloudflared                          ║"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Hostname: ${CF_HOST}"
echo "║"
echo "║  To SSH in, Perplexity Computer will use:"
echo "║    ProxyCommand cloudflared access tcp"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Tunnel will auto-restart on reboot (systemd user service)."
echo "To check status:  systemctl --user status cloudflared-tunnel.service"
echo "To view logs:     journalctl --user -u cloudflared-tunnel.service -f"
