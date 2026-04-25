# ish/ — iSH Auto-Tunnel Files

Pocket Lab bore tunnel auto-start for **iSH on iPhone**, plus the
`pocket-*` helper toolkit for managing a stable Dropbear + bore
tunnel from the Alpine host shell.

## What's Here

| File | Purpose |
|------|---------|
| `pocket-connect` | Start/restart/stop a single Dropbear + bore session for a chosen `POCKET_SSH_PORT` |
| `pocket-status` | Print listeners, processes, recent logs, and the current SSH command |
| `pocket-stop` | Stop the managed Dropbear + bore for the chosen port |
| `pocket-watch` | Watchdog that keeps `pocket-connect` healthy and writes the live SSH line to `/tmp/pocket-current-ssh` |
| `pocket-auto` | Convenience launcher: brings the tunnel up and starts the watchdog in one command |
| `install-pocket-helpers.sh` | Copies the `pocket-*` scripts into `/usr/local/bin` |
| `ish-auto-tunnel.sh` | One-shot: ensures Dropbear host key + Dropbear on `:2225` + bore via `linux/tunnel.sh`. Safe to re-run. |
| `bore-tunnel-respawn.sh` | Original respawn loop used by inittab-based auto-start |
| `install-tunnel-autostart.sh` | One-time installer wiring the respawn loop into `/etc/inittab` + `/etc/profile` |
| `inittab-tunnel.fragment`, `profile-tunnel.fragment` | Reference snippets installed by `install-tunnel-autostart.sh` |

The `pocket-*` scripts are POSIX `sh`. They are designed for iSH/BusyBox and
account for limitations such as `netstat` not exposing the listener PID.

## One-Time Setup

On the iSH (Alpine) host shell — **not** the chroot:

```sh
# 1. Clone the repo somewhere stable
git clone https://github.com/Tsukieomie/pocket-lab-v2-6 /root/pocket-lab-v2-6
cd /root/pocket-lab-v2-6

# 2. Install Dropbear and bore (Alpine packages dropbear; bore is upstream)
apk add --no-cache dropbear net-tools
#   If apk does not have a `bore` package, fetch a static binary and put it
#   at /usr/local/bin/bore. pocket-connect also looks in ~/.local/bin/bore.

# 3. Install the helpers into /usr/local/bin
sh ish/install-pocket-helpers.sh
```

## Authorize an SSH Public Key (without committing it)

Authorized keys are device-private and must **not** be committed.
On the iSH host, append the key directly:

```sh
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Paste the single-line public key (ed25519/rsa) you trust:
printf '%s\n' "ssh-ed25519 AAAA... comment" >> /root/.ssh/authorized_keys
```

Or, if the key is already on disk somewhere on the device:

```sh
sh ish/ish-auto-tunnel.sh --install-key=/path/to/key.pub up
```

`ish-auto-tunnel.sh --install-key=PATH` appends the line only if it is not
already present, so it is safe to re-run.

The repo's `keys/perplexity_computer_ed25519.pub` is the **public** key for
the Perplexity Computer agent and is safe to commit. **Never** commit
`/root/.ssh/authorized_keys`, host keys, or any private key.

## Start the Stable Tunnel

The end-to-end flow we landed on uses port `2232` locally and `bore.pub` as
the public bore server:

```sh
POCKET_SSH_PORT=2232 POCKET_BORE_SERVER=bore.pub pocket-connect restart
pocket-watch start
```

`pocket-connect restart` ensures Dropbear is listening on `:2232`, starts a
fresh `bore local 2232 --to bore.pub`, parses the `listening at host:port`
line out of the bore log, and writes the current SSH command to
`bore-port.txt` in `POCKET_ROOT_DIR`.

`pocket-watch start` runs a small loop that checks every ~25 s that the
listener and bore are still healthy, restarts them if not, and refreshes the
SSH line in `/tmp/pocket-current-ssh` (and copies it to `bore-port.txt`).

You can do both in one step:

```sh
POCKET_SSH_PORT=2232 POCKET_BORE_SERVER=bore.pub pocket-auto start
```

## Check Status / Find the Current SSH Command

```sh
pocket-status                       # listeners, processes, recent logs
pocket-watch status                 # watchdog state + last known SSH line
cat /tmp/pocket-current-ssh         # latest ssh line written by the watchdog
cat bore-port.txt                   # same, copied into the repo working tree
```

`bore-port.txt` looks like:

```
port=31545
host=bore.pub
ssh=ssh -p 31545 root@bore.pub
updated=2026-04-25T18:09:17Z
machine=iPhone-iSH
local_port=2232
```

The example port `31545` was a runtime value from one specific session.
**Bore external ports rotate every reconnect.** Do not commit them as
secrets or as a hard-coded default — always read them from
`bore-port.txt` / `/tmp/pocket-current-ssh` at the moment you connect.
The repo's `.gitignore` excludes `bore-port.txt` and `/tmp/pocket-*` for
this reason.

## Stop

```sh
pocket-watch stop
pocket-stop                          # kills the managed Dropbear + bore for $POCKET_SSH_PORT
# or
pocket-auto stop
```

## Notes on iSH / BusyBox Quirks

- `netstat` on iSH frequently shows `-` in the process column even for
  processes you own. `pocket-connect` treats "port is listening **and** at
  least one Dropbear process exists" as healthy rather than failing.
- Alpine's `apk` may not ship `bore`. `pocket-connect` does **not** call
  `apk add bore`; it accepts `bore` from `$PATH`, `/usr/local/bin/bore`, or
  `~/.local/bin/bore`, and warns if none are present.
- `pocket-watch` records the bore PID at `/tmp/pocket-bore-${SSH_PORT}.pid`
  and only treats the tunnel as healthy if that PID is alive (with a
  fallback to `ps | grep [b]ore`).

## Original inittab-based auto-start

The older respawn flow is still here for users who prefer init-managed
auto-start instead of the watchdog:

```sh
sh ish/install-tunnel-autostart.sh
```

This wires `/etc/inittab` (busybox respawn) and `/etc/profile` (shell-time
guard) to keep `bore-tunnel-respawn.sh` running. Verify with:

```sh
ps | grep bore
cat /tmp/bore-tunnel-ish.log
cat /root/perplexity/bore-port.txt
```

Uninstall:

```sh
sed -i '/bore-tunnel-respawn/d' /etc/inittab
# Remove the profile block (3 lines starting with "Pocket Lab: auto-start")
pkill -f bore-tunnel-respawn
```

## One-Shot Dropbear + bore (port 2225)

```sh
sh ish/ish-auto-tunnel.sh           # up (default)
sh ish/ish-auto-tunnel.sh status
sh ish/ish-auto-tunnel.sh restart   # only this stops procs
sh ish/ish-auto-tunnel.sh check     # syntax + plan, no side effects
```

Generates `/etc/dropbear/dropbear_ed25519_hostkey` only if missing, starts
Dropbear on `:2225` only if nothing is already there, and delegates the
bore tunnel to `linux/tunnel.sh` (which reads `~/.bore_env` for
`BORE_HOST` / `BORE_SECRET`). Does **not** modify `authorized_keys` unless
invoked with `--install-key=PATH`.
