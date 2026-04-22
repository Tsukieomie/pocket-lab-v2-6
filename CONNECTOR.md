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
ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=60 -i /home/user/workspace/perplexity_session -p $PORT kenny@bore.pub
```

## Restore After Wipe

If the launcher ever disappears (e.g. after a reinstall), restore it with:

```bash
git clone https://github.com/Tsukieomie/pocket-lab-v2-6.git
bash pocket-lab-v2-6/linux/install.sh
```
