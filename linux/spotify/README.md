# Spotify Ad Removal

## Two-layer approach
1. **SpotX-Bash** — patches xpui.spa (the UI bundle) to remove ad slots in the client
2. **Hosts blocks** — DNS-level block of ad delivery/tracking servers

## SpotX (re-apply after Spotify update)
```bash
sudo bash <(curl -sSL https://raw.githubusercontent.com/SpotX-Official/SpotX-Bash/main/spotx.sh) -P /usr/share/spotify
```
Backup is at: /usr/share/spotify/Apps/xpui.spa.bak

## Hosts blocks
```bash
sudo cat linux/spotify/spotify-ad-hosts.txt >> /etc/hosts
```

## Note
After a Spotify auto-update, xpui.spa will be replaced — re-run SpotX.
To prevent auto-updates:
```bash
sudo chmod 000 /etc/apt/sources.list.d/spotify.list
```

## Auto-update locked (applied)
```bash
sudo chmod 000 /etc/apt/sources.list.d/spotify.list
```
Spotify is pinned at 1.2.84.476 — apt cannot update it. SpotX patch is permanent.

To re-enable updates later:
```bash
sudo chmod 644 /etc/apt/sources.list.d/spotify.list
```
