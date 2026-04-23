#!/usr/bin/env bash
# Perplexity Comet via Wine — auto-detects GNOME/X11 display
export WINEPREFIX="$HOME/.wine-comet"
export WINEARCH=win64
export WINEDEBUG=-all

COMET_EXE="$WINEPREFIX/drive_c/users/kenny/AppData/Local/Perplexity/Comet/Application/comet.exe"

# Kill stale instances
pkill -f "comet.exe" 2>/dev/null; sleep 1

# Detect active X display
if [ -z "$DISPLAY" ]; then
    for d in :0 :1 :2; do
        if xdpyinfo -display "$d" &>/dev/null; then
            export DISPLAY="$d"
            break
        fi
    done
fi

# Fallback: virtual display
if [ -z "$DISPLAY" ]; then
    export DISPLAY=:99
    Xvfb :99 -screen 0 1920x1080x24 &
    sleep 2
fi

echo "Launching Comet on DISPLAY=$DISPLAY"
exec wine-stable "$COMET_EXE" --no-sandbox "$@"
