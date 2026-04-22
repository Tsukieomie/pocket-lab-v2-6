#!/bin/bash
# install.sh — restore Perplexity Connect launcher from backup
# Run: bash ~/pocket-lab-v2-6/linux/install.sh
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Installing xclip (needed for clipboard paste)..."
sudo apt-get install -y -q xclip

echo ">> Installing launcher script..."
mkdir -p ~/.local/bin ~/.local/share/icons
cp "$REPO_DIR/perplexity-connect.sh" ~/.local/bin/perplexity-connect.sh
chmod +x ~/.local/bin/perplexity-connect.sh

echo ">> Installing desktop icon..."
ICON_SRC=$(find /snap/perplexity-desktop/current -name "icon512.png" 2>/dev/null | head -1)
[ -n "$ICON_SRC" ] && cp "$ICON_SRC" ~/.local/share/icons/perplexity-connect.png

echo ">> Installing desktop launcher..."
cp "$REPO_DIR/Perplexity Connect.desktop" ~/Desktop/"Perplexity Connect.desktop"
chmod +x ~/Desktop/"Perplexity Connect.desktop"
gio set ~/Desktop/"Perplexity Connect.desktop" metadata::trusted true 2>/dev/null || true

echo ">> Done. Double-click 'Perplexity Connect' on your desktop."
