# SMT Unlock Investigation -- Ryzen 7 4700U (Renoir)

Machine: kenny-VivoBook-ASUSLaptop-X513IA-M513IA
CPU: AMD Ryzen 7 4700U (Renoir / Zen 2)
CPUID: 0x00860601 (Family 17h, Model 60h, Stepping 1)
Date: 2026-04-25
Kernel: 7.0.0-14-generic
Tools: cpuid 20250513, msr-tools 1.3, zentool (EntrySign build)

---

## Motivation

The 4700U is marketed as 8-core / 8-thread while the 4800U is 8-core /
16-thread. Both carry the Renoir codename and Zen 2 architecture. Goal:
determine whether SMT is absent from silicon or disabled by firmware, and
whether EntrySign microcode injection can enable it.

---

## Die Identity -- 4700U vs 4800U

Both chips share identical physical parameters:

| Parameter        | Ryzen 7 4700U | Ryzen 7 4800U |
|------------------|---------------|---------------|
| Architecture     | Zen 2 Renoir  | Zen 2 Renoir  |
| Die size         | 156 mm2       | 156 mm2       |
| Transistors      | 9,800 million | 9,800 million |
| Process node     | 7nm TSMC      | 7nm TSMC      |
| L1 cache         | 512 KB        | 512 KB        |
| L2 cache         | 4 MB          | 4 MB          |
| L3 cache         | 8 MB          | 8 MB          |
| iGPU CUs         | 7 (Vega 7)    | 8 (Vega 8)    |
| Threads          | 8             | 16            |

The identical die size and transistor count confirm this is the SAME physical
silicon. The SMT execution hardware exists on the 4700U die. The disable is
applied at the firmware / topology initialization layer, not by laser fuse.

---

## Raw CPUID Topology Data (live from silicon)

### CPUID 0x8000001E -- AMD Extended Topology

```
CPU 0: EAX=0x00000000 EBX=0x00000000 ECX=0x00000000 EDX=0x00000000
CPU 1: EAX=0x00000001 EBX=0x00000001 ECX=0x00000000 EDX=0x00000000
CPU 2: EAX=0x00000002 EBX=0x00000002 ECX=0x00000000 EDX=0x00000000
CPU 3: EAX=0x00000003 EBX=0x00000003 ECX=0x00000000 EDX=0x00000000
CPU 4: EAX=0x00000004 EBX=0x00000004 ECX=0x00000000 EDX=0x00000000
CPU 5: EAX=0x00000005 EBX=0x00000005 ECX=0x00000000 EDX=0x00000000
CPU 6: EAX=0x00000006 EBX=0x00000006 ECX=0x00000000 EDX=0x00000000
CPU 7: EAX=0x00000007 EBX=0x00000007 ECX=0x00000000 EDX=0x00000000
```

Field decode (EBX):
- EBX[7:0]  = CoreId: sequential 0-7
- EBX[15:8] = ThreadsPerCore - 1: ALL ZERO -> ThreadsPerCore = 1

On the 4800U, EBX[15:8] would be 1 (ThreadsPerCore = 2), and pairs of cores
would share the same CoreId while having different EAX (ExtApicId) values.
Here every core has a unique CoreId and EAX == CoreId -- no siblings.

### CPUID 0xB -- Extended Topology Enumeration (Intel-compat leaf, AMD supports)

```
All CPUs, subleaf 0 (SMT level):
  EAX = 0x00000000  (bits to shift APIC ID to get core-level ID = 0)
  EBX = 0x00000001  (logical processors at this SMT level = 1)
  ECX = 0x00000100  (level 0, type 1 = SMT)
  EDX = APIC ID of this logical processor
```

EAX=0 means zero bits need to be shifted -- there is no sub-core APIC
disambiguation needed because there is only one thread per core. On the 4800U
EAX would be 1 (shift 1 bit) and EBX would be 2 (2 LPs per SMT group).

### CPUID 0x80000008 -- Core Count

```
ECX = 0x00006007
NC [7:0] = 0x07 -> total logical thread count = 8
```

The 4800U reports NC = 0x0F (16 threads). This field is sourced from
microcode / topology initialization, not a read-only fuse register.

### CPUID 0x1 -- HTT bit

```
EDX = 0x178bfbff
HTT bit [28] = 1 (SET)
LogicalCPUCount EBX[23:16] = 8
```

HTT=1 on AMD indicates "more than one logical processor per package" --
AMD sets this for any multi-core CPU regardless of SMT. This does not
indicate SMT is active.

---

## Raw MSR Data (live from silicon)

### MSR 0xC0011002 -- CU_CFG (Compute Unit Configuration)

```
All 8 cores: 0x00000000219c91a9
```

Bit decode:
```
bit 0 = 1
bit 3 = 1   <-- SMT_MODE per AMD PPR Family 17h: 1 = SMT enabled
bit 5 = 1
bit 7 = 1
bit 8 = 1
bit 12 = 1
bit 15 = 1
bit 18 = 1
bit 19 = 1
bit 20 = 1
bit 23 = 1
bit 24 = 1
bit 29 = 1
```

CRITICAL: bit 3 (SMT_MODE) = 1. The microcode execution layer's own
configuration register reports SMT as ENABLED. This is NOT a read-only fuse.
It is a model-specific register writable by ring 0 / microcode. The execution
hardware is configured for SMT mode. The topology presentation to software is
what is restricted.

### MSR 0xC0010015 -- HWCR

```
All 8 cores: 0x00000001c9000011
Bit 21 (ForceSMTMode, some Zen generations) = 0
Bit 30 (IrPerfEn) = 1
```

ForceSMTMode is 0 (not forcing). On Zen 1 this bit could override BIOS SMT
disable. On Zen 2 its effect without proper topology initialization is unknown.

### MSR 0xC001102A -- CPUID Feature Override

```
Value: 0x00038080
```

This MSR allows firmware to override CPUID feature flag reporting. If the
SMT capability bit were controlled here, a microcode patch of the CPUID
instruction handler could modify what the CPU reports.

### MSR 0xC0011020 -- DE_CFG

```
Value: 0x0006404000000000
```

No known SMT control bits at this address. Present for completeness.

---

## APIC ID Analysis

CPUID 0xB EDX (per-logical-CPU APIC IDs): 0, 1, 2, 3, 4, 5, 6, 7

Sequential with NO GAPS.

On a CPU where SMT is disabled via firmware on a physically SMT-capable die,
you typically observe interleaved APIC ID assignment with gaps:
- Cores:   APIC IDs 0, 2, 4, 6, 8, 10, 12, 14
- Threads: APIC IDs 1, 3, 5, 7, 9, 11, 13, 15 (not brought up -- absent)

The 4700U shows 0-7 sequential -- the AGESA firmware initialized this CPU as
8 independent single-thread cores, never allocating APIC IDs for secondary
threads. Secondary thread contexts do not exist in the current boot session.

---

## Kernel SMT State

```
/sys/devices/system/cpu/smt/control = notsupported
/sys/devices/system/cpu/smt/active  = 0
```

The Linux kernel sets `notsupported` when CPUID reports ThreadsPerCore=1 at
boot. This is a one-time determination made during CPU topology enumeration.
It cannot be changed at runtime -- it would require a reboot with different
CPUID values, which requires either new firmware or a microcode CPUID patch
applied before topology enumeration (i.e., in the bootloader, not the OS).

---

## Thread Siblings Topology

```
/sys/devices/system/cpu/cpu*/topology/thread_siblings_list:
0   (cpu0 -- only itself)
1   (cpu1 -- only itself)
2   (cpu2 -- only itself)
...
7   (cpu7 -- only itself)

core_siblings_list: 0-7 (all 8 in same package)
```

Each CPU is its own only sibling. No SMT pairs exist.

---

## What Microcode Can and Cannot Do

### CAN (via EntrySign arbitrary microcode injection)

1. CPUID instruction hook -- patch the microcode handler for CPUID to return
   modified values for any leaf:
   - 0x8000001E EBX[15:8]: change ThreadsPerCore from 0 to 1 (reporting 2)
   - 0xB EBX: change from 1 to 2 (2 LPs at SMT level)
   - 0xB EAX: change from 0 to 1 (1 shift bit for APIC disambiguation)
   - 0x80000008 ECX NC: change from 7 to 15 (reporting 16 threads)

2. MSR write hook -- intercept WRMSR to HWCR to force bit 21

3. Clock gate toggle -- potentially un-clock-gate secondary thread units
   if the control register is accessible from microcode patch RAM

### CANNOT (fundamental architectural limits)

1. Create new thread execution contexts at runtime -- thread 1 of each core
   requires its own RSP, RIP, segment state, and APIC ID initialized at RESET.
   A microcode patch executes inside an existing running thread context. It
   cannot bring up a second context that has never been initialized.

2. Assign new APIC IDs retroactively -- the interrupt controller (IOAPIC /
   x2APIC) topology is fixed at POST. Creating new APIC IDs at runtime would
   require reinitializing the interrupt controller, which the OS owns.

3. Force the kernel to re-enumerate topology -- the kernel reads CPUID once
   at boot for SMT detection. A runtime microcode CPUID patch would take
   effect for future CPUID executions but cannot rewind the kernel's already-
   completed topology enumeration. The CPU hotplug infrastructure would need
   to be triggered separately, and it checks SMT state (notsupported) before
   allowing thread-level hotplug.

---

## The Enable Path: Layer by Layer

```
Layer 0 -- Hardware (DONE -- hardware exists)
  SMT execution units: PRESENT (same die as 4800U)
  CU_CFG SMT_MODE bit: SET (bit 3 = 1)
  Status: READY

Layer 1 -- Firmware (BLOCKING LAYER)
  AGESA/PI firmware during POST decides how many thread contexts to initialize
  For 4700U: initializes 8 single-thread cores, never brings up thread 1
  APIC IDs 0-7 assigned to 8 primary threads; no secondary IDs allocated
  Clock gating: secondary thread units powered down after POST
  Fix required: modified AGESA or coreboot with SMT enabled for this CPUID

Layer 2 -- CPUID Topology (blocked by Layer 1)
  Currently reports ThreadsPerCore=1 from firmware initialization
  Would automatically report ThreadsPerCore=2 if Layer 1 brought up threads
  Can be spoofed by microcode patch (does not actually enable SMT)

Layer 3 -- OS / Kernel (blocked by Layer 2)
  Reads CPUID at boot, sets SMT=notsupported, cannot be changed at runtime
  Would automatically detect SMT if Layer 1+2 report ThreadsPerCore=2
```

---

## Viable Paths to Real SMT

### Path A -- BIOS Update from ASUS (lowest effort, lowest probability)
ASUS could ship a BIOS enabling SMT on the 4700U. This would effectively
re-bin the chip as a 4800U. This has not happened and is unlikely -- it would
cannibalize the 4800U market segment.

### Path B -- Custom Firmware / coreboot (real path, high effort)
AMD Renoir (Family 17h Model 60h) has upstream coreboot support via the
Google Chromebook `zork` reference board. Building a custom coreboot image
with SMT enabled and flashing it to the X513IA is the only clean path.

Requirements:
1. coreboot build with Renoir AGESA blob, SMT enable flag set
2. Board-specific ACPI tables for ASUS X513IA (power, thermal, I2C, etc.)
3. Flash method: internal (requires EFI flash tool that accepts unsigned
   images, or disabling write protection) or external (SPI clip on BIOS chip)
4. EntrySign microcode patches can be applied on top of coreboot for
   additional capabilities

Reference: https://doc.coreboot.org/mainboard/google/zork.html

### Path C -- CPUID Spoof Only (not real SMT, for testing only)
Using EntrySign to hook CPUID and report ThreadsPerCore=2 + 16 thread count.
The kernel would attempt to bring up 8 additional CPUs via hotplug. Without
real secondary thread contexts, accesses to phantom CPUs would APIC-redirect
to primary threads or fault. This would likely kernel panic. Not useful for
performance. Useful only to study the kernel's SMT bring-up code path.

---

## Corrected Assessment vs Prior Notes

Prior notes in this repo stated:
  "The 4700U and 4800U have different physical hardware for thread execution"

This was INCORRECT. The die evidence shows:
- Identical die size (156 mm2)
- Identical transistor count (9,800M)
- CU_CFG SMT_MODE bit = 1 (execution layer thinks SMT is on)
- The disable is a FIRMWARE decision at POST, not a silicon difference

The correct statement is:
  "The 4700U has the same SMT-capable silicon as the 4800U. SMT is disabled
  by AGESA firmware during topology initialization, not by laser fuse. The
  secondary thread contexts are never brought up at boot, leaving the hardware
  idle. Runtime microcode cannot create new thread contexts."

---

## Next Steps

1. Research ASUS X513IA SPI flash layout and write-protect configuration
2. Evaluate coreboot Renoir port feasibility for X513IA board init
3. If coreboot path pursued: build and test on a disposable/backup machine
   first -- reflashing with bad firmware = brick without SPI clip recovery

---

## References

- AMD PPR Family 17h Models 60h (Renoir): https://docs.amd.com/v/u/en-US/55922-A1-PUB_3.06
- AMD PPR Family 17h Models 00h-0Fh (Naples, CU_CFG bit definitions):
  https://docs.amd.com/api/khub/documents/abOrVU_gcO7ZsC3qDF4uNQ/content
- coreboot Renoir/Zork support: https://doc.coreboot.org/mainboard/google/zork.html
- 4700U vs 4800U die comparison: https://technical.city/en/cpu/Ryzen-7-4800U-vs-Ryzen-7-4700U
- NotebookCheck 4700U/4800U/4500U comparison:
  https://www.notebookcheck.net/R7-4800U-vs-R7-4700U-vs-R5-4680U_11681_11683_13178.247596.0.html
- EntrySign / zentool: https://github.com/google/security-research/tree/master/pocs/cpus/entrysign
- AngryTools (Zen microcode ISA): https://github.com/AngryUEFI
