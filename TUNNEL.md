# Tunnel — Canonical Reference

> **When the user says "tunnel" / "start the tunnel" / "let's tunnel", this is what they mean.**
> Perplexity Computer: read this file first before suggesting bore, ngrok, cloudflared, or anything else.

---

## TL;DR

The current production tunnel exposes **fs-bridge** (HTTP, port `7779`) on the laptop via **ngrok**, so Perplexity Computer can read/list files and run shell commands on the laptop remotely.

```
Perplexity Computer ──HTTPS──▶ ngrok-free.app ──▶ 127.0.0.1:7779 (fs-bridge, Node.js)
                                    Authorization: Bearer $FS_BRIDGE_TOKEN
```

It is **not** an SSH tunnel. It is **not** bore. Both exist in this repo for legacy reasons but are no longer the default path.

---

## What "tunnel" means in this repo

| Term | Meaning |
|---|---|
| **the tunnel** (default) | ngrok HTTP tunnel → `127.0.0.1:7779` (fs-bridge) on the Linux laptop |
| **bore tunnel** | Legacy: SSH over bore.pub on port 22 / 2222. Still in `linux/tunnel.sh` but superseded |
| **cloudflared tunnel** | Alternative to ngrok for fs-bridge. Same destination (`:7779`), different transport. See `linux/system/cloudflared-tunnel.service` |
| **WireGuard tunnel** | Self-hosted bore over WG VPS (see README §WireGuard). Optional, not default |

If the user says **"start the tunnel"** with no other context → start the ngrok → fs-bridge tunnel.

---

## Start the tunnel (laptop)

```sh
# 1. Make sure fs-bridge is running on :7779
pgrep -f 'fs-bridge/server.js' >/dev/null \
  || ( cd ~/pocket-lab-v2-6/linux/fs-bridge \
       && set -a && . ~/.bore_env && set +a \
       && nohup node server.js > ~/fs-bridge.log 2>&1 & )

# 2. Start ngrok pointing at fs-bridge
ngrok http 7779 --log=stdout &
sleep 5

# 3. Print the public URL
curl -sf http://localhost:4040/api/tunnels \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['tunnels'][0]['public_url'])"
```

Stop:
```sh
pkill -f 'ngrok http 7779'
```

Status:
```sh
curl -sf http://localhost:4040/api/tunnels \
  | python3 -m json.tool 2>/dev/null \
  || echo "ngrok not running"
pgrep -af 'fs-bridge/server.js' || echo "fs-bridge not running"
```

---

## Authentication

All fs-bridge requests require:

```
Authorization: Bearer $FS_BRIDGE_TOKEN
```

`FS_BRIDGE_TOKEN` lives in `~/.bore_env` only. **Never committed**, never pasted into chat without rotating after.

### Rotate token (do this any time it might be exposed)

```sh
NEW_TOKEN=$(openssl rand -hex 16)
if grep -q '^FS_BRIDGE_TOKEN=' ~/.bore_env 2>/dev/null; then
  sed -i "s|^FS_BRIDGE_TOKEN=.*|FS_BRIDGE_TOKEN=$NEW_TOKEN|" ~/.bore_env
else
  echo "FS_BRIDGE_TOKEN=$NEW_TOKEN" >> ~/.bore_env
fi
chmod 600 ~/.bore_env
pkill -f 'fs-bridge/server.js'
sleep 1
( cd ~/pocket-lab-v2-6/linux/fs-bridge \
  && set -a && . ~/.bore_env && set +a \
  && nohup node server.js > ~/fs-bridge.log 2>&1 & )
echo "New token: $NEW_TOKEN"
```

---

## fs-bridge endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/status` | health, version, home, `exec_allow` flag, uptime |
| GET | `/ls?path=<dir>` | directory listing (JSON) |
| GET | `/read?path=<file>` | file contents |
| POST | `/write` | write file (body: `{path, content}`) — if enabled |
| POST | `/exec` | run shell command — gated by `EXEC_ALLOW=true` in `~/.bore_env` |

>  `exec_allow:true` means the bearer token grants **shell-as-kenny** on the laptop. Treat the token like an SSH key.

---

## What Perplexity Computer should do when asked to "tunnel"

### From the laptop (starting / managing)

1. Confirm the laptop side is up:
   - `pgrep -af 'fs-bridge/server.js'`
   - `curl -sf http://localhost:4040/api/tunnels` (ngrok admin API)
2. If both are running, fetch the public URL from the ngrok admin API and report it.
3. If fs-bridge is down, start it (commands above).
4. If ngrok is down, start it pointing at `:7779` (commands above).
5. **Do not** start a `bore` tunnel, an `ngrok tcp 22` tunnel, or any SSH-based tunnel unless the user explicitly says "ssh tunnel" or "bore".

### From a remote agent (using the tunnel)

**Discovery — where to find the live URL:**

```sh
# The active ngrok URL is auto-published to the repo (see ngrok-url.txt below).
URL=$(curl -sf https://raw.githubusercontent.com/Tsukieomie/pocket-lab-v2-6/main/ngrok-url.txt \
      | grep '^url=' | cut -d= -f2-)
echo "$URL"
```

The token is **never** in the repo — the user provides it inline (or rotates one for the session per the procedure above).

**Health check (one-liner):**

```sh
curl -sf -H "Authorization: Bearer $TOKEN" "$URL/status" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('ok' if d.get('ok') else 'down')"
```

**Read a file:**
```sh
curl -sS -H "Authorization: Bearer $TOKEN" "$URL/read?path=/home/kenny/.bashrc"
```

**List a directory:**
```sh
curl -sS -H "Authorization: Bearer $TOKEN" "$URL/ls?path=/home/kenny"
```

**Run a shell command (canonical use case — `/exec`):**
```sh
curl -sS -H "Authorization: Bearer $TOKEN" \
     -H "ngrok-skip-browser-warning: true" \
     -H "Content-Type: application/json" \
     -X POST -d '{"cmd":"uname -a"}' \
     "$URL/exec" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['stdout'])"
```

> Always send `ngrok-skip-browser-warning: true` on free-tier ngrok URLs to avoid the HTML interstitial.

---

## Decision log — why ngrok + fs-bridge over bore + SSH

| Concern | bore + SSH (legacy) | ngrok + fs-bridge (current) |
|---|---|---|
| Setup on iPhone | required iSH + sshd + key deploy | not needed — laptop only |
| Auth | SSH key | Bearer token in ~/.bore_env |
| Granularity | full shell | scoped HTTP endpoints (ls/read/exec) |
| Public exposure | TCP port on bore.pub | HTTPS URL, ngrok-managed |
| Rotation | regenerate ssh keypair | `openssl rand -hex 16` + restart |
| Audit | sshd logs | fs-bridge structured logs |

---

## ngrok-url.txt — auto-published tunnel address

Mirrors the legacy `bore-port.txt` pattern. A laptop-side watcher writes the current public ngrok URL to `ngrok-url.txt` and pushes it to the repo whenever it changes, so any agent (this one, future sessions, scheduled tasks) can find the live URL with a single `curl` to `raw.githubusercontent.com`.

File format:
```
url=https://xxxx-xx-xx-xx-xx.ngrok-free.app
updated=2026-04-25T07:01:17Z
port=7779
```

Publisher script: `linux/ngrok-url-publisher.sh`
Systemd unit: `linux/system/ngrok-url-publisher.service`

---

## Related files

- `linux/fs-bridge/server.js` — the HTTP service
- `linux/fs-bridge/.env` (or `~/.bore_env`) — token + config
- `linux/system/fs-bridge.service` — systemd unit
- `linux/system/cloudflared-tunnel.service` — cloudflared alternative
- `linux/ngrok-url-publisher.sh` — pushes ngrok URL to repo
- `linux/system/ngrok-url-publisher.service` — watcher unit
- `linux/tunnel.sh` — legacy bore tunnel control
- `CONNECTOR.md` — Perplexity Computer connection details
