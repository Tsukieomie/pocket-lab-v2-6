# Hardware Specs — kenny-VivoBook-ASUSLaptop-X513IA-M513IA

> Last updated: 2026-04-25T10:56 UTC  
> Gathered via fs-bridge exec over ngrok tunnel

---

## CPU

| Property | Value |
|----------|-------|
| Model | AMD Ryzen 7 4700U with Radeon Graphics |
| Architecture | Zen 2 (Renoir), x86_64 |
| Cores / Threads | 8 cores / 8 threads (SMT disabled) |
| Base clock | 1.4 GHz |
| Max boost | 2.0 GHz reported (hardware boost up to ~3.4 GHz) |
| L1 cache | 512 KiB (256 KiB d + 256 KiB i) |
| L2 cache | 4 MiB (8 × 512 KiB) |
| L3 cache | 8 MiB (2 × 4 MiB) |
| Virtualization | AMD-V |
| Instruction extensions | AVX2, AES-NI, SHA, FMA, SSE4.2, CLWB |
| NUMA | 1 node (all 8 cores) |

**Security mitigations active:**
- Spectre v1/v2 mitigated (retpolines + IBPB)
- Speculative Store Bypass disabled via prctl
- Retbleed: untrained return thunk
- SMT disabled (mitigates Spec RSB overflow)

---

## Memory

| Property | Value |
|----------|-------|
| Total RAM | 16 GB |
| Used | ~4.2 GB |
| Buff/cache | ~10 GB |
| Available | ~10 GB |
| Swap | 7.8 GB (zram lz4 — compressed in-memory swap) |

---

## Storage

| Property | Value |
|----------|-------|
| Drive | Intel SSD 660P Series |
| Interface | NVMe PCIe |
| Total capacity | 953.9 GB |
| Partitions | `/dev/nvme0n1p1` — 1 GB EFI boot · `/dev/nvme0n1p2` — 952.8 GB root |
| Used | 150 GB |
| Free | 740 GB |

---

## GPU — Ryzen 7 4700U iGPU (Renoir / Vega)

| Property | Value |
|----------|-------|
| Model | AMD Radeon Vega (Renoir integrated) — `gfx90c` |
| ROCm name | `gfx900` (via HSA_OVERRIDE_GFX_VERSION=9.0.0) |
| PCI ID | 03:00.0 |
| Type | Integrated iGPU — UMA (shares system RAM) |
| VRAM (current) | **512 MB** — BIOS default UMA carve-out |
| VRAM (after reboot) | **2048 MB** — modprobe config applied 2026-04-25 |
| GTT (GPU-accessible system RAM) | 8 GB |
| HDMI/DP Audio | AMD/ATI Renoir HDMI/DP Audio Controller (03:00.1) |

### GPU Software Stack (as of 2026-04-25)

| Component | Status |
|-----------|--------|
| amdgpu kernel driver |  loaded, KFD node `renoir` visible |
| `/dev/kfd` |  present |
| `/dev/dri/renderD128` |  present |
| ROCm 6.3 runtime |  installed (`rocm-language-runtime`, `hip-runtime-amd`, `libhsa-runtime64-1`) |
| rocminfo GPU detection |  `AMD Radeon Graphics / Device Type: GPU / gfx900` |
| HSA_OVERRIDE_GFX_VERSION |  `9.0.0` — set in `/etc/environment` |
| Ollama systemd GPU override |  `/etc/systemd/system/ollama.service.d/gpu.conf` |
| kenny in `render` group |  added |
| Ollama GPU offload (live) |  **CPU-only until reboot** — VRAM too small (512 MB < model sizes) |
| Ollama GPU offload (post-reboot) |  Expected — dolphin (1.9 GB) fits in 2 GB VRAM |

### VRAM Expansion — Applied 2026-04-25

The iGPU UMA frame buffer was expanded from 512 MB → 2 GB via:

```
/etc/modprobe.d/amdgpu-vram.conf:
  options amdgpu vramlimit=2048
  options amdgpu gttsize=4096
```

- `iomem=relaxed` added to `GRUB_CMDLINE_LINUX_DEFAULT`
- initramfs rebuilt (`update-initramfs -u -k all`)
- GRUB updated (`update-grub`)
- **Takes effect on next reboot**

Post-reboot verify:
```sh
cat /sys/class/drm/card1/device/mem_info_vram_total
# Expected: 2147483648 (2 GB)
```

### Ollama Local Models

| Model | Size | GPU fit (512 MB) | GPU fit (2 GB) |
|-------|------|-------------------|-----------------|
| `nchapman/dolphin3.0-qwen2.5:latest` | 1.9 GB |  |  |
| `mistral:latest` | 4.4 GB |  |  (needs ≥4 GB) |

### Renoir iGPU Notes

- Renoir is `gfx90c` — **not on ROCm's official support list** but works with `HSA_OVERRIDE_GFX_VERSION=9.0.0`
- ROCm 6.3 `noble` repo is the correct one for Ubuntu 26.04 (6.1 noble does not exist)
- Ubuntu 26.04 ships its own `rocminfo 7.1.1` which conflicts with ROCm's version — install `rocm-language-runtime hip-runtime-amd libhsa-runtime64-1` individually, not `rocm-hip-runtime` meta-package
- ryzenadj requires `iomem=relaxed` kernel param — added to GRUB, takes effect on reboot
- Secure Boot: **disabled** — no signing required for custom module params

---

## Network

| Property | Value |
|----------|-------|
| Wi-Fi | Intel Wi-Fi 6 AX200 (802.11ax) |
| PCI ID | 01:00.0 |

---

## Battery

| Property | Value |
|----------|-------|
| Vendor | ASUSTeK |
| Model | ASUS Battery |
| Current charge | 88% |
| Current energy | 25.4 Wh |
| Full charge capacity | 28.8 Wh |
| Design capacity | 42.1 Wh |
| **Battery health** | **68.4%** — degraded (~31% capacity lost) |
| Voltage | 11.85 V |
| Draw at time of reading | 0.18 W (near idle) |
| State | Discharging |

---

## Other PCI Devices

| PCI ID | Device |
|--------|--------|
| 03:00.2 | AMD Platform Security Processor (PSP) |
| 03:00.3 | AMD Renoir USB 3.1 controller |
| 03:00.4 | AMD Renoir USB 3.1 controller |
| 03:00.6 | AMD Ryzen HD Audio Controller |
| 04:00.0/1 | AMD FCH SATA Controller (AHCI) |
| 00:14.0 | AMD FCH SMBus Controller |

---

## Operating System

| Property | Value |
|----------|-------|
| OS | Ubuntu 26.04 LTS "Resolute" |
| Kernel | Linux 7.0.0-14-generic |
| Build | SMP PREEMPT_DYNAMIC, 2026-04-13 |
| Architecture | x86_64 |

---

## Session Log — 2026-04-25

- Cloned `pocket-lab-v2-6` repo fresh, pulled 11 commits from origin
- Established ngrok → fs-bridge tunnel (port 7779), token rotated
- Diagnosed Ollama running 100% CPU — root cause: no ROCm, 512 MB VRAM
- Installed ROCm 6.3 runtime (fixed noble repo + package conflict)
- Applied HSA_OVERRIDE_GFX_VERSION=9.0.0 for Renoir gfx90c
- Configured Ollama systemd GPU override
- Expanded VRAM to 2 GB via amdgpu modprobe config + GRUB + initramfs rebuild
- **Pending reboot** to activate 2 GB VRAM and enable dolphin GPU offload

---

## Observations & Notes

- **Battery degradation:** At 68.4% health (28.8 Wh vs 42.1 Wh design). Keep plugged in for sustained AI workloads.
- **SMT disabled:** Deliberate security hardening. Re-enabling (`echo on > /sys/devices/system/cpu/smt/control`) doubles thread count for inference at minor security cost.
- **ROCm + Renoir:** Fully working once VRAM ≥ model size. Dolphin (1.9 GB) will GPU-offload after reboot. Mistral (4.4 GB) remains CPU-only unless a smaller quantized variant is pulled.
- **NVMe QLC:** Intel 660P sustained write speeds degrade under heavy load — avoid model training on this drive.
- **GTT fallback:** Even without BIOS VRAM change, amdgpu can use up to 8 GB of system RAM as GTT for GPU ops — but Ollama's layer offload requires dedicated VRAM, not GTT.
