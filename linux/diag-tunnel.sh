#!/bin/bash
echo "=== cloudflared service journal (last 30 lines) ==="
journalctl --user -u cloudflared-tunnel.service -n 30 --no-pager 2>/dev/null

echo ""
echo "=== TCP reachability to Cloudflare edge 443 ==="
timeout 5 bash -c "echo >/dev/tcp/198.41.192.67/443" 2>/dev/null && echo "198.41.192.67:443 OPEN" || echo "198.41.192.67:443 BLOCKED"
timeout 5 bash -c "echo >/dev/tcp/198.41.200.193/443" 2>/dev/null && echo "198.41.200.193:443 OPEN" || echo "198.41.200.193:443 BLOCKED"

echo ""
echo "=== Trying manual cloudflared run (5s) ==="
timeout 8 ~/.local/bin/cloudflared tunnel --no-autoupdate --protocol http2 --edge-ip-version 4 \
  run --token eyJhIjoiZjdjOGUxN2U0N2IyYmE2MTIyNDg1MGQ3YmI5ODkyN2YiLCJ0IjoiODEzMmVjODQtODcyNC00YmUxLWE1ODgtOWU2MmVhNmMzNTYyIiwicyI6Ik9EYzFPR1JrWTJSaFl6TmxZV1JrWVdJMlpUSTRNalUxTkdNME5XVm1NVE0wWlRsaE1tWTFabVE0WTJZNE5tVXhOakZpTTJSak1tUXhaR016TkdVNVpBPT0ifQ== 2>&1 | tail -15 &
CF_PID=$!
sleep 7
kill $CF_PID 2>/dev/null || true
