# ish/ — iSH Auto-Tunnel Files

Pocket Lab bore tunnel auto-start for **iSH on iPhone**.

## One-Line Install

Run inside iSH (Alpine host shell, not chroot):

```sh
sh /root/perplexity/ish/install-tunnel-autostart.sh
```

## What It Does

| File | Purpose |
|------|---------|
| `bore-tunnel-respawn.sh` | Main loop: starts bore, detects port, pushes to GitHub, auto-restarts on exit |
| `install-tunnel-autostart.sh` | One-time installer: wires into `/etc/inittab` + `/etc/profile` |
| `inittab-tunnel.fragment` | The exact inittab line added (for reference) |
| `profile-tunnel.fragment` | The exact profile block added (for reference) |

## How Auto-Start Works

Two layers for maximum reliability on iOS:

1. **`/etc/inittab` respawn** — busybox init restarts the tunnel whenever it exits. Fires on iSH launch and after phone resume.
2. **`/etc/profile` guard** — fires if init hasn't started it yet when a new shell opens.

## Verify

```sh
ps | grep bore                     # check bore process is running
cat /tmp/bore-tunnel-ish.log       # see live port + status
cat /root/perplexity/bore-port.txt # confirm port was written
```

## Uninstall

```sh
sed -i '/bore-tunnel-respawn/d' /etc/inittab
# Remove the profile block (3 lines starting with "Pocket Lab: auto-start")
pkill -f bore-tunnel-respawn
```
