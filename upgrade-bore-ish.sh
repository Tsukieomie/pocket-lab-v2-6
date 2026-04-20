#!/bin/sh
# ============================================================
# upgrade-bore-ish.sh — Upgrade bore on iSH to v0.6.0 + secret
#
# Run this ON iSH (Alpine host, not Debian chroot).
# Replaces the old bore binary and configures secret auth.
#
# Usage:
#   sh upgrade-bore-ish.sh YOUR_VPS_IP YOUR_BORE_SECRET
# ============================================================
set -eu

# Pinned SHA-256 for the bore v0.6.0 i686 musl release asset. Verified
# upstream on 2026-04-20 via `curl -sL <url> | sha256sum`. Update whenever
# the pinned bore version changes.
BORE_SHA256_I686="8f97a4a0c015db3f28665d56e748687ec886ba627609635903742963114369d3"

VPS_IP="${1:-}"
BORE_SECRET="${2:-}"

if [ -z "$VPS_IP" ] || [ -z "$BORE_SECRET" ]; then
  echo "Usage: sh upgrade-bore-ish.sh <VPS_IP> <BORE_SECRET>"
  echo "  VPS_IP:      Your VPS IP address"
  echo "  BORE_SECRET:  The secret from setup-secure-tunnel.sh"
  exit 1
fi

echo "╔══════════════════════════════════════════════════════╗"
echo "║   POCKET LAB — BORE UPGRADE ON iSH                 ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Backup old bore binary ──────────────────────────
echo "[1/4] Backing up old bore..."
if [ -f /usr/local/bin/bore ]; then
  OLD_VER=$(/usr/local/bin/bore --version 2>/dev/null || echo "unknown")
  cp /usr/local/bin/bore /usr/local/bin/bore.bak
  echo "   Old bore ($OLD_VER) backed up to bore.bak"
else
  echo "   No existing bore found, fresh install."
fi

# ── Step 2: Download bore v0.6.0 i686 musl ──────────────────
echo "[2/4] Downloading bore v0.6.0 (i686-musl)..."
cd /tmp
curl -sL "https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-i686-unknown-linux-musl.tar.gz" -o bore-i686.tar.gz
echo "$BORE_SHA256_I686  bore-i686.tar.gz" | sha256sum -c -
tar xzf bore-i686.tar.gz
cp bore /usr/local/bin/bore
chmod +x /usr/local/bin/bore
rm -f bore bore-i686.tar.gz
echo "   Installed: $(/usr/local/bin/bore --version)"

# ── Step 3: Save tunnel config ──────────────────────────────
echo "[3/4] Saving tunnel configuration..."
cat > /root/.bore_env << EOF
# Pocket Lab Secure Tunnel Config
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
export BORE_SERVER="$VPS_IP"
export BORE_PORT="40188"
export BORE_SECRET="$BORE_SECRET"
EOF
chmod 600 /root/.bore_env
echo "   Config saved to /root/.bore_env (mode 600)"

# ── Step 4: Update start-lab.sh ─────────────────────────────
echo "[4/4] Updating start-lab.sh..."
START_LAB="/root/start-lab.sh"
if [ -f "$START_LAB" ]; then
  # Backup
  cp "$START_LAB" "${START_LAB}.bak"

  # Replace bore command (handles both old formats)
  sed -i 's|bore local 2222 --to bore.pub --port 40188.*|. /root/.bore_env \&\& bore local 2222 --to "$BORE_SERVER" --port "$BORE_PORT" --secret "$BORE_SECRET"|g' "$START_LAB"

  echo "   start-lab.sh updated (backup at start-lab.sh.bak)"
  echo "   Old: bore local 2222 --to bore.pub --port 40188"
  echo "   New: bore local 2222 --to $VPS_IP --port 40188 --secret <SECRET>"
else
  echo "   WARNING: $START_LAB not found. Create it manually:"
  echo '   . /root/.bore_env && bore local 2222 --to "$BORE_SERVER" --port "$BORE_PORT" --secret "$BORE_SECRET"'
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo " iSH UPGRADE COMPLETE"
echo ""
echo " To start tunnel:"
echo "   /root/start-lab.sh"
echo ""
echo " To test manually:"
echo "   . /root/.bore_env"
echo '   bore local 2222 --to "$BORE_SERVER" --port "$BORE_PORT" -s "$BORE_SECRET"'
echo ""
echo " Port 40188 is now SECRET-PROTECTED."
echo " No one can hijack it without knowing the secret."
echo "══════════════════════════════════════════════════════"
