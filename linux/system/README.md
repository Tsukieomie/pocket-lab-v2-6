# Linux System Files — kenny-VivoBook (Ubuntu 26.04)

## Power Management Stack

### ppd-shim.service
Replaces  with a lightweight Python shim that exposes
the same D-Bus interface but drives  underneath.

**Install:**
```bash
sudo cp ppd-shim.py /usr/local/libexec/ppd-shim.py
sudo cp ppd-shim.service /etc/systemd/system/ppd-shim.service
sudo systemctl daemon-reload
sudo systemctl enable --now ppd-shim.service
```

### legacy-power-mode.sh
Drives CPU governor + GPU power level for performance / balanced / power-saver.

**Install:**
```bash
sudo cp legacy-power-mode.sh /usr/local/libexec/legacy-power-mode.sh
sudo chmod +x /usr/local/libexec/legacy-power-mode.sh
```

### ryzenadj-tdp.service + apply-tdp.sh
Applies Ryzen 7 4700U TDP on every boot:
- slow-limit = 35W (sustained)
- fast-limit = 45W (burst)
- tctl-temp = 95°C

**Install:**
```bash
sudo cp apply-tdp.sh /usr/local/bin/apply-tdp.sh
sudo chmod +x /usr/local/bin/apply-tdp.sh
sudo cp ryzenadj-tdp.service /etc/systemd/system/ryzenadj-tdp.service
sudo systemctl daemon-reload
sudo systemctl enable --now ryzenadj-tdp.service
```
