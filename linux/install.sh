#!/bin/bash
# install.sh — restore Perplexity Connect launcher + tunnel from backup
# Run: bash ~/pocket-lab-v2-6/linux/install.sh
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$REPO_DIR/.." && pwd)"

# bore-port.txt is a live runtime file updated by the tunnel on every restart.
# Two-layer protection against git pull conflicts:
#   1. skip-worktree — shields local changes from merge detection
#   2. merge=ours driver (via .gitattributes) — keeps local value on merge
# The 'ours' merge driver must be registered in git config to take effect.
if git -C "$REPO_ROOT" ls-files --error-unmatch bore-port.txt >/dev/null 2>&1; then
  git -C "$REPO_ROOT" update-index --skip-worktree bore-port.txt 2>/dev/null || true
fi
git -C "$REPO_ROOT" config merge.ours.driver true 2>/dev/null || true

# Install git hooks so every future pull auto-re-registers the driver
# and skip-worktree without needing install.sh to run again.
echo ">> Installing git hooks..."
HOOKS_SRC="$REPO_DIR/hooks"
HOOKS_DST="$REPO_ROOT/.git/hooks"
for HOOK in post-merge post-checkout; do
  SRC="$HOOKS_SRC/$HOOK"
  DST="$HOOKS_DST/$HOOK"
  if [ ! -f "$SRC" ]; then
    echo "   [skip] $HOOK not found in linux/hooks/"
    continue
  fi
  if [ ! -f "$DST" ]; then
    cp "$SRC" "$DST" && chmod +x "$DST"
    echo "   $HOOK: installed"
  elif diff -q "$SRC" "$DST" >/dev/null 2>&1; then
    echo "   $HOOK: already up to date – skipping"
  elif grep -qF "$(head -2 "$SRC" | tail -1)" "$DST" 2>/dev/null; then
    echo "   $HOOK: already present in existing hook – skipping"
  else
    printf '\n' >> "$DST" && cat "$SRC" >> "$DST"
    echo "   $HOOK: appended to existing hook"
  fi
done

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
echo ">> Installing Perplexity Computer / Comet Electron wrapper..."
# Creates ~/perplexity-linux-wrapper (source files + local Electron install)
# and installs the "Perplexity Comet" desktop launcher. Safe if node/npm
# missing — the wrapper installer will print instructions and exit non-zero
# without aborting the rest of install.sh (we tolerate failure here so that
# tunnel/ssh setup still completes on machines without Node).
if bash "$REPO_DIR/install-computer-wrapper.sh"; then
  echo "   wrapper installed ✓"
else
  echo "   WARNING: wrapper install did not complete — install node/npm and run:"
  echo "     bash $REPO_DIR/install-computer-wrapper.sh"
fi

echo ""
echo ">> Setting up ~/.ssh/authorized_keys for Perplexity Computer tunnel access..."
# NOTE: Always use ~/.ssh (not /root/.ssh) on a standard Linux account.
mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
touch "${HOME}/.ssh/authorized_keys" && chmod 600 "${HOME}/.ssh/authorized_keys"

# Source of truth: linux/security/authorized_keys in the repo.
# Each non-comment, non-empty line is merged idempotently into ~/.ssh/authorized_keys.
AUTH_KEYS_SRC="${REPO_DIR}/security/authorized_keys"
if [ -f "$AUTH_KEYS_SRC" ]; then
  ADDED=0
  while IFS= read -r LINE; do
    # Skip blank lines and comments
    [[ "$LINE" =~ ^[[:space:]]*$ ]] && continue
    [[ "$LINE" =~ ^# ]]            && continue
    # Extract the key blob (second field) for idempotent matching
    KEY_BLOB=$(echo "$LINE" | awk '{print $2}')
    if [ -z "$KEY_BLOB" ]; then continue; fi
    if grep -qF "$KEY_BLOB" "${HOME}/.ssh/authorized_keys" 2>/dev/null; then
      echo "   Already present: ...${KEY_BLOB: -16}"
    else
      echo "$LINE" >> "${HOME}/.ssh/authorized_keys"
      echo "   Added: ...${KEY_BLOB: -16}"
      ADDED=$((ADDED + 1))
    fi
  done < "$AUTH_KEYS_SRC"
  echo "   $ADDED new key(s) added from linux/security/authorized_keys"
else
  echo "   WARNING: linux/security/authorized_keys not found — skipping key install"
  echo "   (expected at: $AUTH_KEYS_SRC)"
fi

# Deduplicate on every install run so keys never accumulate.
if [ -f "${REPO_DIR}/dedup-authorized-keys.sh" ]; then
  bash "${REPO_DIR}/dedup-authorized-keys.sh"
fi

echo ""
echo ">> Pre-scanning tunnel hosts into ~/.ssh/known_hosts ..."
# Avoids interactive 'Are you sure you want to continue connecting?' prompts
# when Perplexity Computer SSHes in through the tunnel for the first time.
mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
touch "${HOME}/.ssh/known_hosts" && chmod 600 "${HOME}/.ssh/known_hosts"

_keyscan_host() {
  local HOST="$1"
  local PORT="${2:-22}"
  # Skip if all key types for this host are already present
  if ssh-keygen -F "${HOST}" -f "${HOME}/.ssh/known_hosts" >/dev/null 2>&1; then
    echo "   ${HOST}: already in known_hosts — skipping"
    return 0
  fi
  echo "   Scanning ${HOST}:${PORT} ..."
  local SCANNED
  SCANNED=$(ssh-keyscan -T 8 -p "${PORT}" -H "${HOST}" 2>/dev/null)
  if [ -n "$SCANNED" ]; then
    echo "$SCANNED" >> "${HOME}/.ssh/known_hosts"
    local COUNT
    COUNT=$(echo "$SCANNED" | wc -l)
    echo "   ${HOST}: added ${COUNT} key(s) ✓"
  else
    echo "   ${HOST}: keyscan failed (host unreachable or port blocked) — skipping"
    echo "   (SSH will prompt on first connect; run install.sh again when connected)"
  fi
}

# Hosts to pre-scan:
# - bore.pub        : legacy bore tunnel server (port 7835 for control, SSH over random port)
# - serveo.net      : fallback SSH relay (port 80/443)
# cloudflared tunnels use HTTPS termination — no SSH host key to scan for those.
for HOST in bore.pub serveo.net; do
  _keyscan_host "$HOST" 22
done

echo "   known_hosts pre-scan complete."

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
