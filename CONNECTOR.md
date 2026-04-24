# Perplexity Connect — Bore Port Connector

## How it works

Every boot, `bore-port-push.service` reads the bore tunnel port from the
systemd journal and pushes it to `bore-port.txt` in this repo via the
GitHub API. This file is the live bridge between this machine and a
Perplexity Computer session.

## bore-port.txt (live)

Always contains the current bore port:
```
port=XXXXX
host=bore.pub
ssh=ssh -p XXXXX kenny@bore.pub
updated=<ISO timestamp>
machine=kenny-VivoBook-ASUSLaptop-X513IA-M513IA
```

Raw URL (Perplexity checks this to reconnect):
https://raw.githubusercontent.com/Tsukieomie/pocket-lab-v2-6/main/bore-port.txt

## Desktop Launcher

`Perplexity Connect.desktop` lives on the desktop. Double-clicking it:
1. Reads current bore port from the systemd journal
2. Pushes fresh port to this repo (bore-port.txt)
3. Opens Perplexity desktop app with "reconnect" pre-typed
4. User hits Enter — Perplexity checks bore-port.txt and SSH connects

## Files

| File | Location | Purpose |
|------|----------|---------|
| `bore-port.txt` | repo root | Live port — updated on every boot + every launcher click |
| `perplexity-connect.sh` | repo root + `~/.local/bin/` | Launcher script |
| `bore-port-push.sh` | `/usr/local/bin/` | Systemd boot-time port pusher |
| `bore-port-push.service` | `/etc/systemd/system/` | Runs after bore-tunnel starts |

## Reconnect command (for Perplexity agent)

```bash
PORT=$(curl -sf https://raw.githubusercontent.com/Tsukieomie/pocket-lab-v2-6/main/bore-port.txt | grep ^port | cut -d= -f2)
ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=60 -i /home/user/.ssh/pocket_lab_perplexity -p $PORT kenny@bore.pub
```

> **Key path note:** The Perplexity Computer private key is stored at `/home/user/.ssh/pocket_lab_perplexity` in the cloud sandbox. The matching public key lives in [`keys/perplexity_computer_ed25519.pub`](keys/perplexity_computer_ed25519.pub) and must be in `~/.ssh/authorized_keys` on the Linux machine (kenny's home dir, not /root).

## Restore After Wipe

If the launcher ever disappears (e.g. after a reinstall), restore it with:

```bash
git clone https://github.com/Tsukieomie/pocket-lab-v2-6.git
bash pocket-lab-v2-6/linux/install.sh
```

---

## Filesystem Bridge (fs-bridge)

A localhost HTTP server on the Linux laptop that gives Perplexity Computer
direct read/write/exec access to the local filesystem — routed over the
existing bore SSH tunnel. No new open ports.

### Port

`7779` (localhost only — never exposed externally)

### Setup (one-time)

```bash
# 1. Add token to ~/.bore_env
echo 'FS_BRIDGE_TOKEN=<random-32-char-secret>' >> ~/.bore_env

# Optional: enable shell exec (needed for running commands remotely)
echo 'FS_BRIDGE_EXEC_ALLOW=1' >> ~/.bore_env

# 2. Install systemd unit
mkdir -p ~/.config/systemd/user
cp ~/pocket-lab-v2-6/linux/system/fs-bridge.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now fs-bridge.service

# 3. Verify
bash ~/pocket-lab-v2-6/linux/tunnel.sh fs-bridge status
```

### API (called from Perplexity Computer via SSH)

All requests require `Authorization: Bearer <FS_BRIDGE_TOKEN>`.

| Method | Route | Description |
|--------|-------|-------------|
| GET | `/status` | Health check + uptime |
| GET | `/ls?path=<dir>&hidden=1` | List directory |
| GET | `/read?path=<file>&encoding=utf8\|base64` | Read file |
| GET | `/stat?path=<path>` | File/dir metadata |
| POST | `/write` | Write file `{path, content, encoding?}` |
| POST | `/mkdir` | Create directory `{path}` |
| DELETE | `/delete?path=<file>` | Delete file |
| POST | `/exec` | Run command `{cmd, args?, cwd?, timeout_ms?}` — requires `FS_BRIDGE_EXEC_ALLOW=1` |

### Perplexity Computer reconnect + fs-bridge call pattern

```bash
# Read the current bore port
PORT=$(curl -sf https://raw.githubusercontent.com/Tsukieomie/pocket-lab-v2-6/main/bore-port.txt | grep ^port | cut -d= -f2)
TOKEN=<FS_BRIDGE_TOKEN>

# List home directory
ssh -o StrictHostKeyChecking=no -p $PORT kenny@188.93.146.98 \
  "curl -sf -H 'Authorization: Bearer $TOKEN' http://localhost:7779/ls?path=/home/kenny"

# Read a file
ssh -o StrictHostKeyChecking=no -p $PORT kenny@188.93.146.98 \
  "curl -sf -H 'Authorization: Bearer $TOKEN' 'http://localhost:7779/read?path=/home/kenny/pocket-lab-v2-6/bore-port.txt'"

# Write a file
ssh -o StrictHostKeyChecking=no -p $PORT kenny@188.93.146.98 \
  "curl -sf -X POST -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
   -d '{\"path\":\"/home/kenny/test.txt\",\"content\":\"hello from Comet\"}' \
   http://localhost:7779/write"

# Run a command (exec must be enabled)
ssh -o StrictHostKeyChecking=no -p $PORT kenny@188.93.146.98 \
  "curl -sf -X POST -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' \
   -d '{\"cmd\":\"df -h\"}' http://localhost:7779/exec"
```

### Security notes

- Server binds only to `127.0.0.1` — never reachable from the internet
- All paths constrained to `$HOME` (same guard as the Electron wrapper)
- Token stored in `~/.bore_env` (not committed to this repo)
- `exec` disabled by default; enable only when needed with `FS_BRIDGE_EXEC_ALLOW=1`
- Log: `/tmp/fs-bridge.log`
