#!/bin/bash
# install-computer-wrapper.sh — create/update ~/perplexity-linux-wrapper
#
# Installs the Electron wrapper that Perplexity Comet / Computer expects at
# $HOME/perplexity-linux-wrapper, copies the source files from the repo's
# linux/ directory, installs Electron locally via npm, and refreshes the
# launch scripts and desktop entries.
#
# Idempotent: safe to run multiple times. Preserves existing node_modules
# unless missing; reinstalls only when electron isn't present.
#
# Usage:
#   bash ~/pocket-lab-v2-6/linux/install-computer-wrapper.sh
#
# Requires: node + npm (checked; clear message if missing). No sudo.

set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER_DIR="${HOME}/perplexity-linux-wrapper"
ELECTRON_VER="${ELECTRON_VER:-30.0.9}"

echo "[wrapper] Target: ${WRAPPER_DIR}"
echo "[wrapper] Source: ${REPO_DIR}"

# ── 1. Pre-flight: node + npm ────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[wrapper] ERROR: node and/or npm not found.

Install Node.js 18+ on Ubuntu/Vivobook with one of:
  sudo apt-get install -y nodejs npm
or (recommended, newer):
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs

Then rerun: bash ~/pocket-lab-v2-6/linux/install-computer-wrapper.sh
EOF
  exit 1
fi

NODE_VER="$(node --version 2>/dev/null || echo unknown)"
echo "[wrapper] node: ${NODE_VER}, npm: $(npm --version 2>/dev/null || echo unknown)"

# ── 2. Create wrapper dir ────────────────────────────────────────────────────
mkdir -p "${WRAPPER_DIR}"

# ── 3. Copy source files ─────────────────────────────────────────────────────
copy_if_exists() {
  local src="$1" dst="$2"
  if [ -f "$src" ]; then
    cp "$src" "$dst"
    chmod "${3:-644}" "$dst"
    echo "   copied: $(basename "$src")"
  else
    echo "   [skip] $(basename "$src") not present in repo"
  fi
}

echo "[wrapper] Installing source files..."
copy_if_exists "${REPO_DIR}/main.js"             "${WRAPPER_DIR}/main.js"          644
copy_if_exists "${REPO_DIR}/preload.js"          "${WRAPPER_DIR}/preload.js"       644
copy_if_exists "${REPO_DIR}/assistant.html"      "${WRAPPER_DIR}/assistant.html"   644
copy_if_exists "${REPO_DIR}/launch-computer.sh"  "${WRAPPER_DIR}/launch-computer.sh"  755
copy_if_exists "${REPO_DIR}/launch-assistant.sh" "${WRAPPER_DIR}/launch-assistant.sh" 755

# Optional icon assets (if any .png/.ico exist next to main.js)
for EXT in png ico svg; do
  for ICON in "${REPO_DIR}"/*."${EXT}"; do
    [ -f "$ICON" ] || continue
    cp "$ICON" "${WRAPPER_DIR}/"
    echo "   copied icon: $(basename "$ICON")"
  done
done

# ── 4. Minimal package.json ──────────────────────────────────────────────────
PKG_JSON="${WRAPPER_DIR}/package.json"
if [ ! -f "$PKG_JSON" ]; then
  cat > "$PKG_JSON" <<EOF
{
  "name": "perplexity-linux-wrapper",
  "version": "1.0.0",
  "description": "Electron wrapper for Perplexity Comet / Computer on Linux",
  "main": "main.js",
  "private": true,
  "scripts": {
    "start": "electron ."
  },
  "devDependencies": {
    "electron": "^${ELECTRON_VER}"
  }
}
EOF
  echo "[wrapper] Created package.json (electron ^${ELECTRON_VER})"
else
  echo "[wrapper] package.json already present — leaving intact"
fi

# ── 5. Install Electron locally (only if missing or broken) ─────────────────
ELECTRON_BIN="${WRAPPER_DIR}/node_modules/electron/dist/electron"
if [ -x "$ELECTRON_BIN" ]; then
  echo "[wrapper] Electron already installed at ${ELECTRON_BIN}"
else
  echo "[wrapper] Installing Electron via npm (this may take a minute)..."
  (
    cd "${WRAPPER_DIR}"
    # --no-audit --no-fund keeps output clean; --omit=optional for slow mirrors
    npm install --no-audit --no-fund --omit=optional
  )
  if [ -x "$ELECTRON_BIN" ]; then
    echo "[wrapper] Electron installed "
  else
    echo "[wrapper] WARNING: Electron binary not found at ${ELECTRON_BIN}"
    echo "[wrapper] Check: cd ${WRAPPER_DIR} && npm install"
    exit 1
  fi
fi

# ── 6. Refresh launch scripts (in case they're newer in repo) ───────────────
# (already copied above; launch-computer.sh / launch-assistant.sh are chmod 755)

# ── 7. Install desktop entries ───────────────────────────────────────────────
install_desktop() {
  local name="$1" src="$2" exec_path="$3"
  local dst="${HOME}/Desktop/${name}.desktop"
  local apps_dst="${HOME}/.local/share/applications/${name}.desktop"
  mkdir -p "${HOME}/Desktop" "${HOME}/.local/share/applications"
  if [ -f "$src" ]; then
    # Rewrite Exec= line to point at the installed wrapper's launch script so
    # the desktop entry is correct regardless of the current user name.
    sed -E "s|^Exec=.*$|Exec=${exec_path}|" "$src" > "$dst"
    chmod +x "$dst"
    cp "$dst" "$apps_dst"
    gio set "$dst" metadata::trusted true 2>/dev/null || true
    echo "   installed desktop: ${name}"
  else
    echo "   [skip] ${name}.desktop not present in repo"
  fi
}

echo "[wrapper] Installing desktop launchers..."
install_desktop "Perplexity Comet" \
  "${REPO_DIR}/Perplexity Comet.desktop" \
  "${WRAPPER_DIR}/launch-computer.sh"

# ── 8. Done ──────────────────────────────────────────────────────────────────
echo ""
echo "[wrapper] Done."
echo "   Wrapper : ${WRAPPER_DIR}"
echo "   Launch  : ${WRAPPER_DIR}/launch-computer.sh"
echo "   Assist. : ${WRAPPER_DIR}/launch-assistant.sh"
echo "   Desktop : ~/Desktop/Perplexity Comet.desktop"
echo ""
echo "   Test:"
echo "     bash ${WRAPPER_DIR}/launch-computer.sh"
