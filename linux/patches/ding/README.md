# DING Extension Patches

## settings-menu-item.patch
Adds a Settings entry to the GNOME desktop background right-click menu
(opens gnome-control-center). Applied to:
  /usr/share/gnome-shell/extensions/ding@rastersoft.com/app/desktopManager.js

**Apply:**
```bash
sudo patch /usr/share/gnome-shell/extensions/ding@rastersoft.com/app/desktopManager.js   < settings-menu-item.patch
# Then restart GNOME Shell (log out / back in on Wayland)
```

**Or copy the full patched file:**
```bash
sudo cp desktopManager.js   /usr/share/gnome-shell/extensions/ding@rastersoft.com/app/desktopManager.js
```
