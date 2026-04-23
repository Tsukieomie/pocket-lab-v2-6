#!/bin/bash
# launch-assistant.sh — open the Perplexity AI Assistant sidebar window

GNOME_PID=$(pgrep -u kenny gnome-shell | head -1)
export DISPLAY=$(grep -z '^DISPLAY=' /proc/$GNOME_PID/environ 2>/dev/null | tr -d '\0' | cut -d= -f2-)
export XAUTHORITY=$(grep -z '^XAUTHORITY=' /proc/$GNOME_PID/environ 2>/dev/null | tr -d '\0' | cut -d= -f2-)
export DBUS_SESSION_BUS_ADDRESS=$(grep -z '^DBUS_SESSION_BUS_ADDRESS=' /proc/$GNOME_PID/environ 2>/dev/null | tr -d '\0' | cut -d= -f2-)
export XDG_RUNTIME_DIR=/run/user/1000
unset WAYLAND_DISPLAY
[ -z "$DISPLAY" ] && export DISPLAY=:0
[ -z "$XAUTHORITY" ] && export XAUTHORITY=$(ls /run/user/1000/.mutter-Xwaylandauth.* 2>/dev/null | head -1)

exec "$HOME/perplexity-linux-wrapper/node_modules/electron/dist/electron" \
  "$HOME/perplexity-linux-wrapper" \
  --user-data-dir="$HOME/.config/perplexity-assistant" \
  --ozone-platform=x11 \
  --no-sandbox \
  --load-assistant
