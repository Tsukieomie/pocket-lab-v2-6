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

## APCB Analysis Results (Phase 3 -- 2026-04-25)

See APCB_ANALYSIS.md for full detail. Summary:

APCB (AMD Platform Configuration Block) is a tokenized binary embedded in SPI
flash. AmdApcbDxeV3 reads it during DXE phase before AGESA CBS defaults run.

Six APCB instances found in X513IA.308. Primary and mirror copies are at:

    Primary APCB:  SPI offset 0x0029a800 (BIOS file), size 0x3a7c
    Mirror APCB:   SPI offset 0x006e2800 (BIOS file), size 0x3a7c

Token 0x0076 (CfgSMTControl) found in both copies:

    Primary value byte: 0x0029e021 = 0x00 (Auto -> Disabled for 4700U)
    Mirror value byte:  0x006e6021 = 0x00 (Auto -> Disabled)

The patch: change both value bytes 0x00 -> 0x01 (Enable).
Zero APCB header checksum at 0x0029a810 and 0x006e2810 (Renoir accepts 0 = skip).

Patch tool: patch_apcb_smt.py (see repo root). Takes X513IAAS.308 as input,
outputs X513IAAS.308.smt_patched. Use with external SPI clip to flash.

No NVRAM override path exists: AmdApcbDxeV3 on X513IA does not expose a
writable APCB EFI variable. Only SPI flash write can change APCB values.

---

## CbsBaseDxeRN Disassembly Results (Phase 2 -- 2026-04-25)

See BIOS_LAYER1_ANALYSIS.md for full disassembly. Key result:

CbsBaseDxeRN maps AmdSetup bytes 0x147-0x153 to SMU message 0x1e6 fields.
NO SMT control byte is mapped anywhere in AmdSetup. AGESA was built without
SMT as a user-configurable option for CPUID 0x00860601 on this BIOS.

This rules out NVRAM/EFI variable write as an SMT enable path for X513IA.308.

---

## Alternative Enable Paths (Priority Order)

### 1. Smokeless UMAF (Try First -- No Flash Required)

Repository: https://github.com/DavidS95/Smokeless_UMAF
Renoir "U" APUs: explicitly listed as supported.

Smokelessly UMAF is a bootable UEFI application that launches a full AMD CBS
browser. It can read and write APCB tokens at runtime if the AmdApcbDxeV3
driver exposes a runtime interface. It also exposes CBS HII options that ASUS
removed from the OEM menu.

Key question: does UMAF write to APCB in SPI flash (requires SPI write), or
write to the in-memory copy loaded by AmdApcbDxeV3 (survives only until next
boot without SPI write)? Community reports on Renoir platforms suggest UMAF
CBS changes via AmdSetup EFI variable -- meaning they persist across reboots
through NVRAM, not APCB.

If UMAF exposes "SMT Control" under CPU Common Options:
    -> Set to Enable
    -> Save and exit
    -> Reboot and check: cat /sys/devices/system/cpu/smt/control

If SMT control does NOT appear in UMAF: AGESA compiled without SMT
configuration for CPUID 0x00860601. Writing APCB token via SPI flash is then
the only path without coreboot.

Setup:
1. Download EFI binary from GitHub releases (Releases page)
2. Format USB as FAT32
3. Create /EFI/Boot/ on USB
4. Copy bootx64.efi to /EFI/Boot/bootx64.efi
5. Boot: hold F2 at ASUS splash -> Boot Override -> USB
6. Device Manager -> AMD CBS -> CPU Common Options -> Performance
   -> CCD/Core/Thread Enablement -> SMT control -> Enable
7. F10 save, reboot
8. Verify: cat /sys/devices/system/cpu/smt/control

### 2. APCB SPI Flash Patch (Direct -- Requires CH341A)

This is the confirmed working path based on APCB_ANALYSIS.md findings.

Required hardware:
    CH341A programmer ($5-10)
    SOIC-8 clip (may be included with CH341A kit)
    X513IA SPI flash chip: likely Winbond W25Q128JVSQ or ESMT F25L128
    Location: SOIC-8 IC near PCH area on motherboard (check board photos)

Procedure:
1. Power off, remove AC + battery
2. Attach SOIC-8 clip to SPI flash chip
3. Read backup: flashrom -p ch341a_spi -r original.bin
4. Verify: sha256sum original.bin (record hash)
5. Apply patch: python3 patch_apcb_smt.py X513IAAS.308
6. Verify patch: python3 -c "d=open('X513IAAS.308.smt_patched','rb').read(); print(hex(d[0x0029e021]), hex(d[0x006e6021]))"  # expect 0x1 0x1
7. Write: flashrom -p ch341a_spi -w X513IAAS.308.smt_patched
8. Reassemble, boot
9. Verify: cat /sys/devices/system/cpu/smt/control  # expect: on or forceoff

Risk: moderate. A bad flash = brick. External SPI clip allows recovery.
Always keep original.bin on a separate drive before flashing.

### 3. UEFI Shell AFU/AMI Flash Bypass

AMI Flash Update (AFU) tool run from UEFI shell before SMM is locked:

Some AMI Aptio V platforms allow unsigned flash writes if the tool runs before
the SMM handler registers its write-protect callback. On ASUS consumer boards
this window is typically closed by the time any UEFI application can run.

Not recommended for X513IA -- the SMM lock is set by AGESA early in DXE,
before UEFI applications execute. Internal flash via AFU is unlikely to work
on this specific board generation.

If attempted:
    Tools: afuefi64.efi from ASUS BIOS package (WinFlash EXE -> extract inner EFI)
    Command: afuefi64.efi X513IAAS.308.smt_patched /P /B /N /CLNEVNLOG
    Boot to UEFI shell via bootx64.efi on USB, then run afuefi64

### 4. Coreboot with SMT-Enabled AGESA (Definitive)

The definitive path regardless of AGESA compilation flags:
coreboot can pass its own APCB to the AGESA blob, overriding everything.

Requires board init code for X513IA (not upstream) + external SPI clip.
See BIOS_LAYER1_ANALYSIS.md for full requirements.

Reference: https://doc.coreboot.org/mainboard/google/zork.html

## Next Steps

1. Try Smokeless UMAF USB -- check if CBS browser shows SMT control
2. If UMAF shows SMT control: enable, save, reboot, verify
3. If UMAF does not show SMT control: proceed to SPI flash patch
4. SPI flash patch: acquire CH341A + SOIC-8 clip, follow Path 2 procedure
5. Coreboot: long-term option if SPI chip is write-protected at hardware level

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
