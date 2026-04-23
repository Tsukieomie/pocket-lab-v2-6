#!/bin/bash
# launch-computer.sh — open Perplexity Computer / Comet AI (v2.8 fixed)
# Works when launched from GNOME desktop, .desktop file, or terminal.

# ── Resolve display env from running GNOME session ───────────────────────────
if [ -z "${DISPLAY:-}" ] || [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  GNOME_PID=$(pgrep -u "$(whoami)" gnome-shell | head -1)
  if [ -n "$GNOME_PID" ]; then
    _env() { grep -z "^$1=" /proc/$GNOME_PID/environ 2>/dev/null | tr -d "\0" | cut -d= -f2-; }
    export DISPLAY="${DISPLAY:-$(_env DISPLAY)}"
    export XAUTHORITY="${XAUTHORITY:-$(_env XAUTHORITY)}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-$(_env DBUS_SESSION_BUS_ADDRESS)}"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-$(_env WAYLAND_DISPLAY)}"
  fi
fi

# Fallback defaults
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -z "${DISPLAY:-}" ] && export DISPLAY=:0
if [ -z "${XAUTHORITY:-}" ]; then
  XAUTH_CANDIDATE=$(ls /run/user/$(id -u)/.mutter-Xwaylandauth.* 2>/dev/null | head -1)
  [ -n "$XAUTH_CANDIDATE" ] && export XAUTHORITY="$XAUTH_CANDIDATE"
fi

WRAPPER="$HOME/perplexity-linux-wrapper"
ELECTRON="$WRAPPER/node_modules/electron/dist/electron"

exec "$ELECTRON" "$WRAPPER" \
  --user-data-dir="$HOME/.config/perplexity-computer" \
  --ozone-platform=x11 \
  --no-sandbox \
  "$@" >> /tmp/perplexity-launch.log 2>&1
