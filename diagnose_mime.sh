#!/bin/bash
echo "=== MIME handler for https ==="
xdg-mime query default x-scheme-handler/https

echo "=== MIME handler for http ==="
xdg-mime query default x-scheme-handler/http

echo "=== mimeapps.list ==="
cat ~/.config/mimeapps.list | grep -i "https\|http\|firefox\|libre" 2>/dev/null

echo "=== Fixing handlers ==="
mkdir -p ~/.local/share/applications
xdg-mime default firefox.desktop x-scheme-handler/https
xdg-mime default firefox.desktop x-scheme-handler/http

# Also write directly to mimeapps.list
grep -q "x-scheme-handler/https" ~/.config/mimeapps.list 2>/dev/null || \
  sed -i '/\[Default Applications\]/a x-scheme-handler/https=firefox.desktop\nx-scheme-handler/http=firefox.desktop' ~/.config/mimeapps.list

echo "=== After fix ==="
xdg-mime query default x-scheme-handler/https
xdg-mime query default x-scheme-handler/http

echo "=== Opening mem0 directly ==="
DISPLAY=:0 firefox --new-tab https://app.mem0.ai/dashboard/api-keys &
echo "Done"
