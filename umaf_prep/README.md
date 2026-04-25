# Smokeless UMAF — Pre-extracted EFI files

Source: https://github.com/DavidS95/Smokeless_UMAF/raw/main/UniversalAMDFormBrowser.zip  
Extracted: 2026-04-25

## USB Setup

Format a USB drive as FAT32, then copy these files:

```
USB root/
├── DisplayEngine.efi
├── SetupBrowser.efi
├── UiApp.efi
└── EFI/
    └── Boot/
        └── bootx64.efi   ← UEFI boot entry point
```

Quick copy (Linux):
```bash
sudo mount /dev/sdX1 /mnt
sudo cp -r . /mnt/
sudo umount /mnt
```

## Boot

- Press F2 at ASUS splash → Boot Override → USB  
  OR press F8 → select USB from boot menu

## Navigation for SMT

Device Manager → AMD CBS → CPU Common Options →  
Performance → CCD/Core/Thread Enablement → **SMT Control → Enable**

F10 → Save & Exit → reboot → run `bash smt_verify.sh`
