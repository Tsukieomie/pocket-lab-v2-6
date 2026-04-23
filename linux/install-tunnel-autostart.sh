#!/bin/bash
# ============================================================
# linux/install-tunnel-autostart.sh — Install bore auto-start
# for Pocket Lab on Linux (VivoBook / any systemd user session)
#
# What this does:
#   1. Copies bore-tunnel.service + bore-port-watcher.service
#      to ~/.config/systemd/user/
#   2. Enables + starts both services
#   3. Verifies tunnel is UP and port is in bore-port.txt
#
# Usage:
#   bash ~/pocket-lab-v2-6/linux/install-tunnel-autostart.sh
#
# Uninstall:
#   systemctl --user disable --now bore-tunnel.service bore-port-watcher.service
#   rm ~/.config/systemd/user/bore-tunnel.service
#   rm ~/.config/systemd/user/bore-port-watcher.service
# ============================================================
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
BORE_ENV="${HOME}/.bore_env"

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Pocket Lab — Linux Tunnel Auto-Start Installer     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Preflight ─────────────────────────────────────────────
if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not found — this installer requires systemd." >&2
  exit 1
fi

if ! systemctl --user status >/dev/null 2>&1; then
  echo "ERROR: systemd user session not running." >&2
  echo "  Try: loginctl enable-linger $USER" >&2
  exit 1
fi

# ── Check ~/.bore_env ─────────────────────────────────────
if [ ! -f "$BORE_ENV" ]; then
  echo "WARNING: ~/.bore_env not found."
  echo "  Creating minimal default (BORE_HOST=bore.pub, no secret)."
  echo "  Edit ~/.bore_env to customize."
  cat > "$BORE_ENV" << 'ENV'
# Pocket Lab tunnel config
# Edit these to match your setup
BORE_HOST=bore.pub
# BORE_PORT=40188       # Uncomment to pin to a specific port
# BORE_SECRET=          # Uncomment if using self-hosted bore with --secret
# GH_TOKEN=             # GitHub token for pushing port to bore-port.txt
ENV
  chmod 600 "$BORE_ENV"
  echo "  Created ~/.bore_env"
fi

# ── Check bore binary ─────────────────────────────────────
if ! command -v bore >/dev/null 2>&1 && [ ! -x "${HOME}/.local/bin/bore" ]; then
  echo "[install] bore not found — installing..."
  bash "$REPO_DIR/linux/tunnel.sh" install-bore
fi

# ── Install systemd units ─────────────────────────────────
echo "[1/3] Installing systemd user units..."
mkdir -p "$SYSTEMD_USER_DIR"

cp "$REPO_DIR/linux/system/bore-tunnel.service"         "$SYSTEMD_USER_DIR/"
cp "$REPO_DIR/linux/system/bore-port-watcher.service"   "$SYSTEMD_USER_DIR/"
echo "  Copied bore-tunnel.service"
echo "  Copied bore-port-watcher.service"

systemctl --user daemon-reload
echo "  daemon-reload: OK"

# ── Enable + start ────────────────────────────────────────
echo "[2/3] Enabling + starting services..."
systemctl --user enable bore-tunnel.service bore-port-watcher.service
systemctl --user restart bore-tunnel.service bore-port-watcher.service

# Poll for tunnel UP up to 15s
echo "[3/3] Waiting for tunnel to come up (up to 15s)..."
LIVE_PORT=""
for i in $(seq 1 15); do
  sleep 1
  LIVE_PORT=$(journalctl --user -u bore-tunnel.service -n 50 --no-pager 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oE 'remote_port=[0-9]+' | tail -1 | cut -d= -f2 || echo "")
  [ -n "$LIVE_PORT" ] && break
  printf "."
done
echo ""

if [ -n "$LIVE_PORT" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  AUTO-START INSTALLED — TUNNEL UP                   ║"
  echo "╚══════════════════════════════════════════════════════╝"
  BORE_HOST=$(grep '^BORE_HOST=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || echo "bore.pub")
  echo "  SSH: ssh -p ${LIVE_PORT} ${USER}@${BORE_HOST}"
  echo ""
  echo "  Syncing port to bore-port.txt + GitHub..."
  bash "$REPO_DIR/linux/tunnel.sh" sync-port
  echo ""
  echo "  Services:"
  echo "    bore-tunnel.service       — $(systemctl --user is-active bore-tunnel.service)"
  echo "    bore-port-watcher.service — $(systemctl --user is-active bore-port-watcher.service)"
  echo ""
  echo "  Starts automatically on next login."
  echo "══════════════════════════════════════════════════════"
else
  echo ""
  echo "WARNING: Tunnel started but no port reported yet."
  echo "  Check: journalctl --user -u bore-tunnel.service -f"
  echo "  Status: bash $REPO_DIR/linux/tunnel.sh status"
fi
