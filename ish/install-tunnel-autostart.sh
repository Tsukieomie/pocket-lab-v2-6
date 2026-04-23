#!/bin/sh
# ============================================================
# ish/install-tunnel-autostart.sh — Install bore auto-start for iSH
#
# Run this ONCE inside iSH (Alpine host shell, not chroot).
#
# What this does:
#   1. Adds respawn entry to /etc/inittab (for boot/resume)
#   2. Adds auto-start block to /etc/profile (for new shells)
#   3. Starts the tunnel immediately
#
# Usage:
#   sh /root/perplexity/ish/install-tunnel-autostart.sh
#
# Uninstall:
#   sed -i '/bore-tunnel-respawn/d' /etc/inittab
#   sed -i '/Pocket Lab: auto-start bore tunnel/,+4d' /etc/profile
# ============================================================
set -eu

REPO_DIR="/root/perplexity"
RESPAWN_SCRIPT="$REPO_DIR/ish/bore-tunnel-respawn.sh"
BORE_ENV="/root/.bore_env"

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Pocket Lab — iSH Tunnel Auto-Start Installer      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Verify bore binary ─────────────────────────────────────
if ! command -v bore >/dev/null 2>&1 && [ ! -x /usr/local/bin/bore ]; then
  echo "ERROR: bore not found." >&2
  echo "  Run: sh $REPO_DIR/upgrade-bore-ish.sh <VPS_IP_or_bore.pub> <SECRET>" >&2
  exit 1
fi
BORE_VER=$(bore --version 2>/dev/null || echo "unknown")
echo "  bore: $BORE_VER"

# ── Verify respawn script is executable ───────────────────
if [ ! -f "$RESPAWN_SCRIPT" ]; then
  echo "ERROR: $RESPAWN_SCRIPT not found." >&2
  echo "  Make sure pocket-lab-v2-6 is cloned at /root/perplexity" >&2
  exit 1
fi
chmod +x "$RESPAWN_SCRIPT"

# ── Check ~/.bore_env ─────────────────────────────────────
if [ ! -f "$BORE_ENV" ]; then
  echo "WARNING: /root/.bore_env not found — creating minimal default."
  cat > "$BORE_ENV" << 'ENV'
BORE_HOST=bore.pub
# BORE_PORT=40188
# BORE_SECRET=
# GH_TOKEN=
ENV
  chmod 600 "$BORE_ENV"
  echo "  Created /root/.bore_env — edit to add GH_TOKEN for GitHub sync"
fi

# ── 1. /etc/inittab respawn entry ─────────────────────────
echo "[1/2] Adding inittab respawn entry..."
INITTAB_MARKER="bore-tunnel-respawn"
if grep -q "$INITTAB_MARKER" /etc/inittab 2>/dev/null; then
  echo "  Already present in /etc/inittab — skipping"
else
  echo "" >> /etc/inittab
  echo "# Pocket Lab — bore tunnel auto-respawn" >> /etc/inittab
  echo "tun:respawn:$RESPAWN_SCRIPT" >> /etc/inittab
  echo "  Added to /etc/inittab ✓"
  # Tell init to re-read inittab
  kill -HUP 1 2>/dev/null || true
fi

# ── 2. /etc/profile auto-start block ──────────────────────
echo "[2/2] Adding /etc/profile auto-start block..."
PROFILE_MARKER="Pocket Lab: auto-start bore tunnel"
if grep -q "$PROFILE_MARKER" /etc/profile 2>/dev/null; then
  echo "  Already present in /etc/profile — skipping"
else
  cat >> /etc/profile << PROFILE

# ── $PROFILE_MARKER ──
if [ -f $RESPAWN_SCRIPT ]; then
  if ! pgrep -f bore-tunnel-respawn > /dev/null 2>&1; then
    sh $RESPAWN_SCRIPT &
  fi
fi
PROFILE
  echo "  Added to /etc/profile ✓"
fi

# ── 3. Start now ──────────────────────────────────────────
echo ""
echo "[live] Starting tunnel now..."
if pgrep -f bore-tunnel-respawn > /dev/null 2>&1; then
  echo "  Already running."
else
  sh "$RESPAWN_SCRIPT" &
  sleep 6
fi

# Check port
LIVE_PORT=$(grep -oE 'remote_port=[0-9]+' /tmp/bore-tunnel-ish.log 2>/dev/null | tail -1 | cut -d= -f2 || echo "")
if [ -n "$LIVE_PORT" ]; then
  BORE_HOST=$(grep '^BORE_HOST=' "$BORE_ENV" 2>/dev/null | cut -d= -f2 || echo "bore.pub")
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║  AUTO-START INSTALLED — TUNNEL UP                   ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo "  SSH: ssh -p $LIVE_PORT root@$BORE_HOST"
  echo "  Log: cat /tmp/bore-tunnel-ish.log"
  echo "  Starts automatically on iSH open + iSH resume."
  echo "══════════════════════════════════════════════════════"
else
  echo ""
  echo "  Tunnel starting... check: cat /tmp/bore-tunnel-ish.log"
fi
