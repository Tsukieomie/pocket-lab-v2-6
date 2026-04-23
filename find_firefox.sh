#!/bin/bash
echo "=== Firefox processes ==="
pgrep -a firefox

echo "=== Active displays ==="
ls /tmp/.X*-lock 2>/dev/null || echo "No X locks found"

echo "=== DISPLAY env ==="
echo "Current DISPLAY: $DISPLAY"

echo "=== Trying all displays ==="
for d in :0 :1 :2; do
    DISPLAY=$d xdpyinfo &>/dev/null && echo "Display $d is active" || echo "Display $d not available"
done

echo "=== Killing old Firefox and reopening on correct display ==="
pkill firefox 2>/dev/null
sleep 1
# find active display
ACTIVE_DISPLAY=""
for d in :0 :1 :2; do
    DISPLAY=$d xdpyinfo &>/dev/null && ACTIVE_DISPLAY=$d && break
done
echo "Opening on display: $ACTIVE_DISPLAY"
DISPLAY=$ACTIVE_DISPLAY firefox https://app.mem0.ai/dashboard/api-keys &
echo "Done"
