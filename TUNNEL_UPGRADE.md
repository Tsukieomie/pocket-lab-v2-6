# Pocket Lab Tunnel Upgrade — Secure Self-Hosted Bore

## Problem

bore.pub is a **public relay** — anyone can claim any port. When iSH backgrounds
and the tunnel drops, another user can grab port 40188. This is exactly what happened:
an Ubuntu machine (`OpenSSH_10.2p1 Ubuntu-2ubuntu3`) hijacked the port.

## Solution: Self-Hosted Bore Server with Secret Authentication

Run your own `bore server` on a $3-5/mo VPS with `--secret` flag.
No one can connect without the shared secret. Port hijacking becomes impossible.

### Why bore (self-hosted) over alternatives?

| Tool | i686 musl binary | Auth support | Binary size | Complexity |
|------|-------------------|-------------|-------------|------------|
| **bore (self-hosted)** |  2.5 MB static |  `--secret` HMAC | 2.5 MB | Low — same CLI you already use |
| chisel |  10 MB static |  `--auth` | 10 MB | Medium — different CLI |
| rathole |  No i386 build |  token | N/A | Medium — TOML config |
| SSH reverse tunnel |  (already have SSH) |  key-based | 0 (built-in) | Low — but needs VPS sshd |

**Recommendation:** Self-hosted bore — same tool, same workflow, just add `--secret`.

---

## Architecture

```
┌─────────────┐       ┌──────────────────────┐       ┌─────────────────────┐
│ iSH (iPhone)│──────▶│  Your VPS (bore srv) │◀──────│ Perplexity Computer │
│ bore client │ :7835 │  bore server -s KEY  │ :SSH  │ ssh -p PORT         │
│ + sshd :2222│       │  expose :40188       │       │                     │
└─────────────┘       └──────────────────────┘       └─────────────────────┘
                      Secret-authenticated tunnel
                      No one else can claim your port
```

---

## Setup Guide

### Part 1: VPS Setup (one-time, ~10 min)

Any cheap VPS works: DigitalOcean ($4/mo), Hetzner ($3.79/mo), Vultr ($3.50/mo), etc.

```sh
# On VPS (Ubuntu/Debian):
# 1. Download bore server binary
curl -sL https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-unknown-linux-musl.tar.gz | tar xz
sudo mv bore /usr/local/bin/

# 2. Generate a strong secret
BORE_SECRET=$(openssl rand -hex 32)
echo "Your bore secret: $BORE_SECRET"
echo "SAVE THIS — you'll need it on iSH and in PERPLEXITY_LOAD.sh"

# 3. Create systemd service
sudo tee /etc/systemd/system/bore.service << 'EOF'
[Unit]
Description=Bore Tunnel Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/bore server --secret ${BORE_SECRET} --min-port 40000 --max-port 40100
Environment=BORE_SECRET=REPLACE_WITH_YOUR_SECRET
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 4. Edit the service file to insert your secret
sudo sed -i "s/REPLACE_WITH_YOUR_SECRET/$BORE_SECRET/" /etc/systemd/system/bore.service

# 5. Enable and start
sudo systemctl daemon-reload
sudo systemctl enable bore
sudo systemctl start bore
sudo systemctl status bore

# 6. Open firewall ports
sudo ufw allow 7835/tcp   # bore control port
sudo ufw allow 40000:40100/tcp  # tunnel port range
```

### Part 2: Upgrade bore on iSH (one-time)

```sh
# On iSH (run in Alpine host, NOT chroot):
# 1. Download i686 musl bore binary
cd /tmp
curl -sL https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-i686-unknown-linux-musl.tar.gz | tar xz
cp bore /usr/local/bin/bore
chmod +x /usr/local/bin/bore

# 2. Save the secret
echo 'export BORE_SECRET="YOUR_SECRET_HERE"' >> /root/.bore_env

# 3. Verify
bore --version
```

### Part 3: Update start-lab.sh

Replace the bore command in `/root/start-lab.sh`:

```sh
# OLD (public bore.pub, no auth):
# bore local 2222 --to bore.pub --port 40188

# NEW (your VPS, with secret):
. /root/.bore_env
bore local 2222 --to YOUR_VPS_IP --port 40188 --secret "$BORE_SECRET"
```

### Part 4: Update PERPLEXITY_LOAD.sh

```sh
# Change these lines:
BORE_HOST="YOUR_VPS_IP"    # was: bore.pub
BORE_PORT="40188"           # same port, now protected
# SSH_PASS stays the same
```

---

## Alternative: Pure SSH Reverse Tunnel (No bore needed)

If you already have a VPS, you can skip bore entirely:

```sh
# On iSH:
ssh -R 40188:localhost:2222 -N -o ServerAliveInterval=30 tunneluser@YOUR_VPS_IP

# On Perplexity Computer:
ssh -p 40188 root@YOUR_VPS_IP
```

Pros: No extra binary needed, SSH is already on iSH.
Cons: Slightly more fragile reconnection, needs autossh or a loop.

---

## Alternative: Chisel (if you prefer HTTP tunneling)

Chisel has a linux_386 build (10 MB) and supports auth:

```sh
# On VPS:
chisel server --port 8080 --reverse --auth user:password

# On iSH:
chisel client YOUR_VPS_IP:8080 R:40188:127.0.0.1:2222 --auth user:password
```

---

## Quick Comparison

| Approach | Port hijack safe | Reconnect | Binary needed | Monthly cost |
|----------|-----------------|-----------|---------------|-------------|
| bore.pub (current) |  NO | Manual | bore (already have) | Free |
| **Self-hosted bore** |  YES | Manual | bore (upgrade to v0.6.0) | $3-5/mo |
| SSH reverse tunnel |  YES | autossh/loop | None (built-in) | $3-5/mo |
| Chisel |  YES | Auto-retry | chisel 386 (10 MB) | $3-5/mo |
