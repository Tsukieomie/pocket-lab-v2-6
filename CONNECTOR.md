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

## Vivobook — exact commands

Reference setup on `kenny@kenny-VivoBook-ASUSLaptop-X513IA-M513IA` (Ubuntu).

```bash
# 1. Clone (or pull if already cloned)
cd ~ && [ -d pocket-lab-v2-6 ] \
  && git -C pocket-lab-v2-6 pull --ff-only \
  || git clone https://github.com/Tsukieomie/pocket-lab-v2-6.git

# 2. Full Linux setup (tunnel + authorized_keys + Comet wrapper)
bash ~/pocket-lab-v2-6/linux/install.sh

# 3. Install / refresh ONLY the Perplexity Computer Electron wrapper
#    (idempotent — safe to rerun anytime main.js / preload.js change)
bash ~/pocket-lab-v2-6/linux/install-computer-wrapper.sh

# 4. Launch Perplexity Computer / Comet
bash ~/perplexity-linux-wrapper/launch-computer.sh
# or double-click ~/Desktop/Perplexity\ Comet.desktop

# 5. Bring the bore tunnel up (so Perplexity can SSH in)
bash ~/pocket-lab-v2-6/linux/tunnel.sh up
bash ~/pocket-lab-v2-6/linux/tunnel.sh status

# 6. Run the connector (pushes current bore port + opens Perplexity)
~/.local/bin/perplexity-connect.sh

# 7. List available models via the multi-provider client
python3 ~/pocket-lab-v2-6/parallel_ai.py --list-models
```

### Prerequisites

`install-computer-wrapper.sh` requires `node` and `npm`. On a fresh Vivobook:

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
```

The wrapper installer will print these hints itself and exit cleanly if
`node` / `npm` are missing — no partial install.

### Tunnel control-port note

The shipped custom bore binaries (`bore-custom-2222`, `bore-custom-8443`)
each dial a single hardcoded control port. The automatic fallback list is
`2222 → 8443` only; 443 is **not** tried unless you explicitly set
`BORE_CTRL_PORT=443` in `~/.bore_env` *and* have upstream `bore` installed
(`bash ~/pocket-lab-v2-6/linux/tunnel.sh install-bore`). This avoids the
earlier bug where logs claimed `ctrl=443` while the 8443 binary was being
invoked.

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

---

## Session Log — 2026-04-25: First Successful fs-bridge Connection

**Problem:** Perplexity Computer sandbox could not reach the machine directly.

### What was blocking us

1. **bore ports 2222 and 8443 blocked** on the local network — bore tunnel
   failed to connect outbound.
2. **Cloudflare quick tunnel** (`.trycloudflare.com`) worked on the machine
   side but resolved **IPv6-only** from Perplexity's sandbox, which has no
   IPv6 connectivity. DNS returned `fd10:aec2:5dae::` — unreachable.
3. **Named Cloudflare tunnel** (`8132ec84-8724-4be1-a588-9e62ea6c3562.cfargotunnel.com`)
   same problem — resolves IPv6-only, sandbox can't connect.
4. **localhost.run / serveo** — reverse SSH tunnels started but URL was never
   captured before the short-lived terminal capture timed out.

### What finally worked — ngrok

ngrok was already installed at `~/.local/bin/ngrok`. Running it in the
background and querying its local API returned a public HTTPS URL with proper
IPv4+IPv6 dual-stack DNS that Perplexity's sandbox could resolve and connect to.

```bash
# Start ngrok in background exposing fs-bridge
ngrok http 7779 --log=stdout &
sleep 5

# Get the public URL from ngrok's local API
curl -sf http://localhost:4040/api/tunnels \
  | python3 -c "import sys,json; t=json.load(sys.stdin)['tunnels']; print(t[0]['public_url'])"
```

URL format: `https://<hash>.ngrok-free.app`

Perplexity then calls fs-bridge directly:

```bash
TOKEN="pocketlab-bridge-2026"
HOST="https://<hash>.ngrok-free.app"

# Status check
curl -sf -H "Authorization: Bearer $TOKEN" -H "ngrok-skip-browser-warning: true" "$HOST/status"

# List home directory
curl -sf -H "Authorization: Bearer $TOKEN" -H "ngrok-skip-browser-warning: true" "$HOST/ls?path=/home/kenny"
```

> **Important:** Always add `-H "ngrok-skip-browser-warning: true"` to bypass
> ngrok's browser interstitial page on free-tier URLs.

### Setup state after this session

| Component | State |
|-----------|-------|
| `FS_BRIDGE_TOKEN` in `~/.bore_env` | `pocketlab-bridge-2026` |
| fs-bridge systemd service | enabled, running on port 7779 |
| SSH public key in `~/.ssh/authorized_keys` | `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM+3/rpnm/k11njemu1GahGWqHYlWKGuJLnS5QrLM6Sr perplexity-computer` |
| ngrok | installed at `~/.local/bin/ngrok` |
| Named Cloudflare tunnel | configured but IPv6-only from sandbox — not usable without a domain |

### Reconnect procedure for next session

```bash
# 1. Start fs-bridge
bash ~/pocket-lab-v2-6/linux/tunnel.sh fs-bridge start

# 2. Start ngrok and get URL
ngrok http 7779 --log=stdout &
sleep 5
curl -sf http://localhost:4040/api/tunnels \
  | python3 -c "import sys,json; t=json.load(sys.stdin)['tunnels']; print(t[0]['public_url'])"

# 3. Paste the ngrok URL into Perplexity Computer
# Token: pocketlab-bridge-2026
```

### Root cause — IPv6-only network

The Vivobook is on an **IPv6-only network** (public IP: `2600:8805:a21c:5900:...`).
Perplexity's sandbox is **IPv4-only**. Any tunnel that only advertises an IPv6
address in DNS will fail. ngrok's free tier provides dual-stack DNS and works.

**Long-term fix:** Add a domain to Cloudflare and create a DNS CNAME record
pointing to the named tunnel — that gives a stable, permanent, dual-stack
hostname that doesn't change between sessions.
---

## Session Log — 2026-04-25 (later): Portable Gates + Sandbox-Side Bore

Run from the Perplexity Computer cloud sandbox (IPv4, ephemeral) — *not* the Vivobook.

### `run_in_perplexity.sh` — full pass

| Gate | Result | Time |
|------|--------|------|
| Gate 3 — PDF SHA-256 + tar.enc SHA-256 + v2.6 manifest policy | PASS | 48 ms |
| Gate 2 — secp256k1 keypair, signed approval JSON, field validation | PASS | 134 ms (Path B) |
| Total portable | PASS | 137 ms |

Approval pubkey for this run: `2b6bcbd89f89f6d7d16204e06623153881f0ce18869c30bbabc080cd55593e5c`
(ephemeral — Path B keys are not persisted from cloud sandbox).

### Bore from the sandbox side

- `bore` binary auto-installed by `linux/tunnel.sh install-bore` → `~/.local/bin/bore` (v0.6.0)
- Control-port fallback worked as designed: `2222 FAIL → 8443 OK`
- Tunnel came up at `188.93.146.98:40003` (ctrl=8443), TCP-reachable, `bore-port.txt` synced locally
- `BORE_CTRL_PORT=8443` was persisted to `~/.bore_env` automatically

### fs-bridge from the sandbox

`linux/tunnel.sh up` also tries to start fs-bridge. It **failed** (expected) because:

```
[fs-bridge] ERROR: FS_BRIDGE_TOKEN not set in ~/.bore_env
```

The cloud sandbox is ephemeral and has no `FS_BRIDGE_TOKEN` in its `~/.bore_env` — and even if it did, exposing a sandbox-local fs-bridge isn't useful: the canonical fs-bridge lives on the Vivobook (see ngrok findings above).

### Why we did **not** push `bore-port.txt` to GitHub

Live remote `bore-port.txt` at the time of this session was the **Vivobook's cloudflared entry**:

```
port=cloudflared
host=people-modification-metropolitan-sources.trycloudflare.com
machine=kenny-VivoBook-ASUSLaptop-X513IA-M513IA
updated=2026-04-25T06:21:16Z
```

Pushing the sandbox's bore endpoint (`188.93.146.98:40003`) would have overwritten the Vivobook's entry with a tunnel that:
- dies as soon as the sandbox shuts down (ephemeral),
- points at a sandbox SSH daemon, not at the Vivobook,
- would mislead the next Perplexity session into SSH-ing to the wrong host.

**Decision: cancelled the push.** `bore-port.txt` must only ever be updated from the host the user actually wants Perplexity to reach (currently the Vivobook).

### Recommendation — add a guard

`linux/tunnel.sh sync-port` (and the `perplexity-connect.sh` launcher) should refuse to push `bore-port.txt` from a host where `machine` differs from the value already on `main`, unless `--force` is passed. Prevents accidental overwrites from cloud sandboxes / borrowed laptops.

### Sandbox vs. Vivobook — when to use which

| Task | Run from |
|------|----------|
| Portable gate verification (`run_in_perplexity.sh`) | Cloud sandbox — by design |
| Vault decrypt, Gate 1 startup integrity | iSH on-device only |
| `bore-port.txt` updates, fs-bridge | Vivobook (the canonical reachable host) |
| Quick file ops on the Vivobook | Vivobook fs-bridge via ngrok URL |
