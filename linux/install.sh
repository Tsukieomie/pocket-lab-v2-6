#!/bin/bash
# install.sh — restore Perplexity Connect launcher + tunnel from backup
# Run: bash ~/pocket-lab-v2-6/linux/install.sh
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Installing xclip (needed for clipboard paste)..."
sudo apt-get install -y -q xclip

echo ">> Installing launcher + tunnel scripts..."
mkdir -p ~/.local/bin ~/.local/share/icons
cp "$REPO_DIR/perplexity-connect.sh" ~/.local/bin/perplexity-connect.sh
chmod +x ~/.local/bin/perplexity-connect.sh
cp "$REPO_DIR/tunnel.sh" ~/.local/bin/pocket-tunnel.sh
chmod +x ~/.local/bin/pocket-tunnel.sh

echo ">> Installing bore binary..."
bash "$REPO_DIR/tunnel.sh" install-bore

echo ">> Installing desktop icon..."
ICON_SRC=$(find /snap/perplexity-desktop/current -name "icon512.png" 2>/dev/null | head -1)
[ -n "$ICON_SRC" ] && cp "$ICON_SRC" ~/.local/share/icons/perplexity-connect.png

echo ">> Installing desktop launcher..."
cp "$REPO_DIR/Perplexity Connect.desktop" ~/Desktop/"Perplexity Connect.desktop"
chmod +x ~/Desktop/"Perplexity Connect.desktop"
gio set ~/Desktop/"Perplexity Connect.desktop" metadata::trusted true 2>/dev/null || true

echo ""
echo ">> Setting up ~/.ssh/authorized_keys for Perplexity Computer tunnel access..."
mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
PERPLEXITY_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFJfaR3o9eJlfwwZoneTL9rAdE7oY3U50uqsZ7eRM9JS perplexity-computer-tunnel"
if grep -qF "perplexity-computer-tunnel" "${HOME}/.ssh/authorized_keys" 2>/dev/null; then
  echo "   Perplexity Computer pubkey already in authorized_keys — skipping"
else
  echo "$PERPLEXITY_PUBKEY" >> "${HOME}/.ssh/authorized_keys"
  chmod 600 "${HOME}/.ssh/authorized_keys"
  echo "   Added Perplexity Computer pubkey to ~/.ssh/authorized_keys"
fi
# NOTE: Always use ~/.ssh (not /root/.ssh) on a standard Linux account.
# /root/.ssh requires sudo and is not where sshd looks for your user.

echo ">> Checking ~/.bore_env ..."
if [ ! -f "${HOME}/.bore_env" ]; then
  cat > "${HOME}/.bore_env" << 'BOREENV'
BORE_HOST=bore.pub
BORE_PORT=
BORE_SECRET=
SSH_KEY_PATH=
GH_TOKEN=
BOREENV
  echo "   Created ~/.bore_env — edit it with your BORE_HOST / BORE_SECRET / GH_TOKEN"
else
  echo "   ~/.bore_env already exists — not overwriting"
fi

echo ""
echo ">> Setting up mem0 credentials (~/.mem0_env)..."
bash "$REPO_DIR/../setup_mem0_env.sh"

echo ""
echo ">> Done."
echo ""
echo "   To start the tunnel (no sudo needed):"
echo "     pocket-tunnel.sh up"
echo "   or:"
echo "     bash ~/pocket-lab-v2-6/linux/tunnel.sh up"
echo ""
echo "   Make sure ~/.local/bin is in your PATH:"
echo '     export PATH="$HOME/.local/bin:$PATH"'
