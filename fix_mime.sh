#!/bin/bash
# Fix LibreOffice hijacking .ai URLs
xdg-mime default firefox.desktop x-scheme-handler/https
xdg-mime default firefox.desktop x-scheme-handler/http
update-desktop-database ~/.local/share/applications/ 2>/dev/null
echo "Done. Opening mem0..."
DISPLAY=:0 firefox https://app.mem0.ai/dashboard/api-keys &
