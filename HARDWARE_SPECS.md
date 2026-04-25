# Hardware Specs — kenny-VivoBook-ASUSLaptop-X513IA-M513IA

> Last updated: 2026-04-25T09:20 UTC  
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
| Used | 4.2 GB |
| Free | 425 MB |
| Buff/cache | 10 GB |
| Available | ~10 GB |
| Swap | 7.8 GB (zram — compressed in-memory swap) |

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

## GPU

| Property | Value |
|----------|-------|
| Model | AMD Radeon Vega (Renoir integrated) |
| PCI ID | 03:00.0 |
| Type | Integrated iGPU (shares system RAM) |
| HDMI/DP Audio | AMD/ATI Renoir HDMI/DP Audio Controller (03:00.1) |

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

## Observations & Notes

- **Battery degradation:** At 68.4% health (28.8 Wh vs 42.1 Wh design), the battery has lost ~13 Wh of capacity. Recommend keeping plugged in for sustained workloads.
- **SMT disabled:** Simultaneous multithreading is off — 8 physical cores, 1 thread each. This is a deliberate security hardening choice (mitigates Spectre RSB overflow). Re-enabling would double thread count for parallelism at a minor security cost.
- **Plenty of disk space:** 740 GB free — no concerns.
- **zram swap:** 7.8 GB compressed in-memory swap is active, good for a 16 GB RAM system.
- **NVMe QLC drive:** Intel 660P uses QLC NAND — fine for general use but sustained write speeds drop under heavy load.
- **Ubuntu 26.04 + kernel 7.0:** Very current stack, released April 2026.
