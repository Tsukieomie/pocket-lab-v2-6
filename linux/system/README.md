# Linux System Files — kenny-VivoBook (Ubuntu 26.04)

## Power Management Stack

### ppd-shim.service + ppd-shim.py
Replaces power-profiles-daemon with a lightweight shim exposing the same D-Bus interface.
```bash
sudo cp ppd-shim.py /usr/local/libexec/ppd-shim.py
sudo cp ppd-shim.service /etc/systemd/system/ppd-shim.service
sudo systemctl daemon-reload && sudo systemctl enable --now ppd-shim.service
```

### legacy-power-mode.sh
Drives CPU governor + GPU power level for performance/balanced/power-saver.
```bash
sudo cp legacy-power-mode.sh /usr/local/libexec/legacy-power-mode.sh
sudo chmod +x /usr/local/libexec/legacy-power-mode.sh
```

### ryzenadj-tdp.service + apply-tdp.sh
Applies Ryzen 7 4700U TDP on every boot: slow=35W, fast=45W, tctl=95°C
```bash
sudo cp apply-tdp.sh /usr/local/bin/apply-tdp.sh && sudo chmod +x /usr/local/bin/apply-tdp.sh
sudo cp ryzenadj-tdp.service /etc/systemd/system/ryzenadj-tdp.service
sudo systemctl daemon-reload && sudo systemctl enable --now ryzenadj-tdp.service
```

## Battery Health

### 60-battery-threshold.rules + battery-threshold.conf
Caps charging at 80% to slow capacity degradation (battery currently at 61% health / 328 cycles).
```bash
sudo cp 60-battery-threshold.rules /etc/udev/rules.d/
sudo cp battery-threshold.conf /etc/tmpfiles.d/
sudo udevadm control --reload-rules
sudo systemd-tmpfiles --create /etc/tmpfiles.d/battery-threshold.conf
```

## Network

### wifi-powersave-off.conf
Removes WiFi powersave conflict (two conflicting conf files → undefined behavior).
```bash
sudo rm -f /etc/NetworkManager/conf.d/default-wifi-powersave-on.conf
sudo cp wifi-powersave-off.conf /etc/NetworkManager/conf.d/
sudo systemctl reload NetworkManager
```

## Memory

### zramswap.conf
Enables 4GB lz4-compressed zram swap at priority 100 (faster than NVMe file swap).
```bash
sudo apt install zram-tools
sudo cp zramswap.conf /etc/default/zramswap
sudo systemctl enable --now zramswap
```

## Network (BBR)

### 99-network-perf.conf → /etc/sysctl.d/
BBR congestion control, TCP fast-open, tuned rmem/wmem, vfs_cache_pressure=50.


## Journal

### 99-journal-size.conf → /etc/systemd/journald.conf.d/
Caps journal at 100MB, 2-week retention, compression on.


## NVMe

### 61-nvme-tuning.rules → /etc/udev/rules.d/
Bumps read-ahead from 128KB → 2MB for sequential workloads.


## Power / Lid

### 99-logind-power.conf → /etc/systemd/logind.conf.d/
Lid close = suspend, external power = screen lock, idle suspend after 30min.


## Disabled Services (no hardware present)

