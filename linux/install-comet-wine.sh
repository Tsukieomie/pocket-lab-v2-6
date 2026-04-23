#!/bin/bash
# install-comet-wine.sh — Install Perplexity Comet browser via Wine on Linux
# Run: bash ~/pocket-lab-v2-6/linux/install-comet-wine.sh
set -e

COMET_URL="https://www.perplexity.ai/download-comet"
INSTALLER_NAME="comet_installer_latest.exe"
INSTALLER_PATH="$HOME/Downloads/$INSTALLER_NAME"
WINEPREFIX_DIR="$HOME/.wine-comet"
LOG="/tmp/comet-wine-install.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

echo "╔══════════════════════════════════════════════════════╗"
echo "║     Perplexity Comet — Wine Installer               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── 1. Check / install Wine ──────────────────────────────────────────────────
if ! command -v wine >/dev/null 2>&1; then
  log "Wine not found — installing..."
  sudo dpkg --add-architecture i386
  sudo apt-get update -qq
  sudo apt-get install -y wine wine64 wine32 winetricks
else
  log "Wine found: $(wine --version)"
fi

# ── 2. Check / install winetricks ────────────────────────────────────────────
if ! command -v winetricks >/dev/null 2>&1; then
  log "Installing winetricks..."
  sudo apt-get install -y winetricks 2>/dev/null || \
    (curl -fsSL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
      -o /tmp/winetricks && sudo mv /tmp/winetricks /usr/local/bin/winetricks && \
      sudo chmod +x /usr/local/bin/winetricks)
fi

# ── 3. Set up dedicated Wine prefix for Comet ────────────────────────────────
log "Setting up Wine prefix at $WINEPREFIX_DIR ..."
export WINEPREFIX="$WINEPREFIX_DIR"
export WINEARCH=win64

# Init prefix silently
WINEPREFIX="$WINEPREFIX_DIR" WINEARCH=win64 wineboot --init 2>/dev/null || true

# Install Chromium dependencies via winetricks
log "Installing required Windows components (corefonts, vcrun2022)..."
WINEPREFIX="$WINEPREFIX_DIR" winetricks -q corefonts vcrun2022 2>/dev/null || \
  WINEPREFIX="$WINEPREFIX_DIR" winetricks -q corefonts 2>/dev/null || true

# ── 4. Download Comet installer ───────────────────────────────────────────────
if [ ! -f "$INSTALLER_PATH" ]; then
  log "Downloading Comet installer..."
  # Try official URL first
  curl -fL --progress-bar \
    "https://www.perplexity.ai/download-comet?platform=windows" \
    -o "$INSTALLER_PATH" 2>/dev/null || \
  curl -fL --progress-bar \
    "https://comet-browser.en.uptodown.com/windows/download" \
    -o "$INSTALLER_PATH" 2>/dev/null || true

  # Check if download succeeded and looks like an EXE
  if [ ! -f "$INSTALLER_PATH" ] || [ $(wc -c < "$INSTALLER_PATH") -lt 1000000 ]; then
    log "Auto-download failed — opening download page in browser..."
    xdg-open "https://www.perplexity.ai/download-comet" 2>/dev/null || true
    echo ""
    echo "  Please download the Comet Windows installer manually:"
    echo "  → https://www.perplexity.ai/download-comet"
    echo "  → Save it to: $INSTALLER_PATH"
    echo ""
    echo "  Then re-run this script."
    exit 1
  fi
else
  log "Installer already present: $INSTALLER_PATH"
fi

log "Installer size: $(du -sh "$INSTALLER_PATH" | cut -f1)"

# ── 5. Run installer ──────────────────────────────────────────────────────────
log "Running Comet installer via Wine..."
WINEPREFIX="$WINEPREFIX_DIR" wine "$INSTALLER_PATH" 2>>"$LOG" &
WINE_PID=$!

echo ""
echo "  Comet installer is running (Wine)."
echo "  Follow the on-screen installer steps."
echo "  If you see no window, check: tail -f $LOG"
echo ""
wait $WINE_PID || true

# ── 6. Find installed Comet EXE ───────────────────────────────────────────────
log "Looking for Comet executable..."
COMET_EXE=$(find "$WINEPREFIX_DIR/drive_c" -name "Comet.exe" -o -name "comet.exe" \
  2>/dev/null | head -1)

if [ -z "$COMET_EXE" ]; then
  # Common install paths
  for p in \
    "$WINEPREFIX_DIR/drive_c/Program Files/Perplexity/Comet/Application/Comet.exe" \
    "$WINEPREFIX_DIR/drive_c/Program Files (x86)/Perplexity/Comet/Application/Comet.exe" \
    "$WINEPREFIX_DIR/drive_c/users/$USER/AppData/Local/Perplexity/Comet/Application/Comet.exe"
  do
    [ -f "$p" ] && COMET_EXE="$p" && break
  done
fi

if [ -z "$COMET_EXE" ]; then
  log "Comet.exe not found yet — may still be installing. Check $WINEPREFIX_DIR/drive_c"
  COMET_EXE="$WINEPREFIX_DIR/drive_c/Program Files/Perplexity/Comet/Application/Comet.exe"
fi

log "Comet EXE: $COMET_EXE"

# ── 7. Create launcher script ─────────────────────────────────────────────────
LAUNCHER="$HOME/.local/bin/comet"
cat > "$LAUNCHER" << LAUNCHER_EOF
#!/bin/bash
# Comet (Wine) launcher
export WINEPREFIX="$WINEPREFIX_DIR"
export WINEARCH=win64
# Disable Wine debug spam
export WINEDEBUG=-all
exec wine "$COMET_EXE" "\$@"
LAUNCHER_EOF
chmod +x "$LAUNCHER"
log "Launcher created: $LAUNCHER"

# ── 8. Create desktop shortcut ────────────────────────────────────────────────
ICON_SRC=$(find "$WINEPREFIX_DIR" -name "*.png" -path "*Comet*" 2>/dev/null | head -1)
[ -z "$ICON_SRC" ] && ICON_SRC=$(find /snap/perplexity-desktop/current -name "icon512.png" 2>/dev/null | head -1)

DESKTOP_FILE="$HOME/Desktop/Perplexity Comet.desktop"
cat > "$DESKTOP_FILE" << DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Perplexity Comet
Comment=Perplexity Comet AI Browser (Wine)
Exec=$HOME/.local/bin/comet
Icon=${ICON_SRC:-utilities-terminal}
Terminal=false
Categories=Network;WebBrowser;
StartupNotify=true
DESKTOP_EOF
chmod +x "$DESKTOP_FILE"
gio set "$DESKTOP_FILE" metadata::trusted true 2>/dev/null || true
log "Desktop shortcut created: $DESKTOP_FILE"

# ── 9. Also update perplexity-connect.sh to use Comet (Wine) ─────────────────
CONNECT_SCRIPT="$HOME/.local/bin/perplexity-connect.sh"
if [ -f "$CONNECT_SCRIPT" ]; then
  sed -i "s|bash \"\$LAUNCH_SCRIPT\" &|$HOME/.local/bin/comet \&|g" "$CONNECT_SCRIPT" 2>/dev/null || true
  log "Updated perplexity-connect.sh to launch Comet (Wine)"
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo " DONE"
echo ""
echo " Launch Comet:       comet"
echo " Desktop shortcut:   ~/Desktop/Perplexity Comet"
echo " Wine prefix:        $WINEPREFIX_DIR"
echo " Log:                $LOG"
echo ""
echo " If Comet doesn't open, run:"
echo "   WINEPREFIX=$WINEPREFIX_DIR wine '$COMET_EXE'"
echo "══════════════════════════════════════════════════════"
