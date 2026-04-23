#!/bin/bash
# install.sh — restore Perplexity Connect launcher + tunnel from backup
# Run: bash ~/pocket-lab-v2-6/linux/install.sh
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$REPO_DIR/.." && pwd)"

# bore-port.txt is a live runtime file updated by the tunnel on every restart.
# Mark it skip-worktree so git pull never conflicts with local changes.
if git -C "$REPO_ROOT" ls-files --error-unmatch bore-port.txt >/dev/null 2>&1; then
  git -C "$REPO_ROOT" update-index --skip-worktree bore-port.txt 2>/dev/null || true
fi

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
# NOTE: Always use ~/.ssh (not /root/.ssh) on a standard Linux account.
# /root/.ssh requires sudo and is not where sshd looks for your user.
mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
touch "${HOME}/.ssh/authorized_keys" && chmod 600 "${HOME}/.ssh/authorized_keys"

# Canonical Perplexity Computer tunnel key — ONE entry, replaced not appended.
# The key blob is the source of truth; the comment is normalised to
# 'perplexity-computer-tunnel' so grep always finds it on re-runs.
PERPLEXITY_KEY_BLOB="AAAAC3NzaC1lZDI1NTE5AAAAIFJfaR3o9eJlfwwZoneTL9rAdE7oY3U50uqsZ7eRM9JS"
PERPLEXITY_PUBKEY="ssh-ed25519 ${PERPLEXITY_KEY_BLOB} perplexity-computer-tunnel"

if grep -qF "${PERPLEXITY_KEY_BLOB}" "${HOME}/.ssh/authorized_keys" 2>/dev/null; then
  echo "   Perplexity Computer pubkey already present — skipping"
else
  echo "${PERPLEXITY_PUBKEY}" >> "${HOME}/.ssh/authorized_keys"
  echo "   Added Perplexity Computer pubkey to ~/.ssh/authorized_keys"
fi

# Deduplicate on every install run so keys never accumulate.
if [ -f "$REPO_DIR/linux/dedup-authorized-keys.sh" ]; then
  bash "$REPO_DIR/linux/dedup-authorized-keys.sh"
fi

echo ">> Configuring ~/.bore_env ..."

# ── Helper: read/write individual keys in ~/.bore_env ────────────────────────
# _bore_env_get KEY        — prints current value or empty string
# _bore_env_set KEY VALUE  — upserts KEY=VALUE (adds if missing, replaces if present)
_bore_env_get() {
  grep "^${1}=" "${HOME}/.bore_env" 2>/dev/null | cut -d= -f2- || echo ""
}
_bore_env_set() {
  local KEY="$1" VAL="$2" FILE="${HOME}/.bore_env"
  if grep -q "^${KEY}=" "$FILE" 2>/dev/null; then
    sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" "$FILE"
  else
    echo "${KEY}=${VAL}" >> "$FILE"
  fi
}

# Create ~/.bore_env with defaults if it doesn't exist
if [ ! -f "${HOME}/.bore_env" ]; then
  cat > "${HOME}/.bore_env" << 'BOREENV'
BORE_HOST=bore.pub
BORE_PORT=
BORE_SECRET=
SSH_KEY_PATH=
GH_TOKEN=
BOREENV
  echo "   Created ~/.bore_env"
fi

# ── GH_TOKEN — prompt if missing or empty ────────────────────────────────────
# GH_TOKEN is required for tunnel.sh to push bore-port.txt to GitHub
# so Perplexity Computer can always find the current port.
CURRENT_TOKEN=$(_bore_env_get GH_TOKEN)
if [ -z "$CURRENT_TOKEN" ]; then
  echo ""
  echo "   ┌─────────────────────────────────────────────────────────────┐"
  echo "   │  GitHub Token required for automatic bore-port.txt sync     │"
  echo "   │                                                             │"
  echo "   │  Create one at: https://github.com/settings/tokens/new     │"
  echo "   │  Scopes needed: repo (Contents read+write)                  │"
  echo "   │                                                             │"
  echo "   │  Press Enter to skip (tunnel will work but port won't       │"
  echo "   │  auto-sync to GitHub — you'll need to run sync-port manually)│"
  echo "   └─────────────────────────────────────────────────────────────┘"
  echo ""
  if [ -t 0 ]; then
    # Running interactively — prompt
    read -r -p "   GitHub Personal Access Token (ghp_...): " INPUT_TOKEN
    if [ -n "$INPUT_TOKEN" ]; then
      _bore_env_set GH_TOKEN "$INPUT_TOKEN"
      echo "   GH_TOKEN saved to ~/.bore_env ✓"
    else
      echo "   Skipped — run: nano ~/.bore_env  to add GH_TOKEN later"
    fi
  else
    # Non-interactive (piped) — skip prompt, leave GH_TOKEN empty
    echo "   Non-interactive mode — set GH_TOKEN in ~/.bore_env manually"
  fi
else
  echo "   GH_TOKEN already set in ~/.bore_env ✓"
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
