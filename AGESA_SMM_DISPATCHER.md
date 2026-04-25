# AGESA SMM Dispatcher Analysis -- Phase 5 Continuation

## Module Identification

### FV2 Large PE32 @ FV2+0xb7d0c (45,504 bytes)
- Architecture: x64 PE32+
- Subsystem: 0xb (EFI Application)
- ImageBase: 0x0
- CodeSize: 0x79a0 (31,136 bytes)
- Text section: rawoff=0x2a0, rawsz=0x79a0
- Strings: FabricAllocateMmio v3, APOB, AGESA_TP, PPTable fan parameters, SMU feature flags
- Identity: **AMD Power Management DXE module** (SMU/DPTC/FabricMmio -- NOT a primary SMM handler)
- CPUID check: Family17h Model60h (0x00660F00 mask against CPUID leaf 0x80000001)

### MSR Operations in FV2+0xb7d0c
| File Offset | Op | MSR | Name | Purpose |
|-------------|-----|-----|------|---------|
| 0x445b | RDMSR | 0xC001001F | SYS_CFG | Read system config |
| 0x4483 | WRMSR | 0xC001001F | SYS_CFG | Write system config |
| 0x44b7 | RDMSR | 0xC0010063 | IorrMask | Read IORR mask |
| 0x44d4 | RDMSR | 0xC0010063 | IorrMask | Second IORR read |
| 0x451a | RDMSR | 0x1 | CPUID_1 | CPUID via RDMSR |
| 0x505a | RDMSR | 0xC0010058 | CPUID_7 override | CPU feature |
| 0x71cc | RDMSR | 0x1b | IA32_APIC_BASE | BSP check |
| 0x730c | RDMSR | 0xC00110A2 | MCA_CTL_MASK_LS | MCA config |
| 0x7337 | WRMSR | 0xC00110A2 | MCA_CTL_MASK_LS | MCA init |
| 0x7bfd | RDMSR | 0xC001100A | PSPADDR | Read PSP BAR |
| 0x7c07 | WRMSR | 0xC001100A | PSPADDR | Write PSP BAR |

**Note:** This module does NOT write SMMAddr, SMMMask, or HWCR. It is the power management
DXE driver, not the SMM setup module.

---

## CcxSmm Module @ FV2+0x7295c (0xc940 bytes) -- THE SMM SETUP MODULE

This is the actual AMD CCX (Core Complex) SMM driver that sets up TSEG protection.

### MSR Operations (selected critical ones)
| Blob Offset | Op | MSR | Name | Notes |
|------------|-----|-----|------|-------|
| 0x7a62 | RDMSR | 0xC0010113 | SMMMask/TClose | Read before clear |
| 0x7a76 | WRMSR | 0xC0010113 | SMMMask/TClose | AND 0xFFFFFFFC (clear bits[1:0]) |
| 0x7b76 | RDMSR | 0xC0010113 | SMMMask/TClose | Read before set |
| 0x7b8a | WRMSR | 0xC0010113 | SMMMask/TClose | OR 0x3 (set bits[1:0]) |
| 0x7b9a | RDMSR | 0xC0010015 | HWCR | Read before SmmLock |
| 0x7bb2 | WRMSR | 0xC0010015 | HWCR | OR 0x80000001 (SmmLock+bit31) |
| 0x7ea1 | WRMSR | 0xC0010112 | SMMAddr | Initial TSEG base |
| 0x7eb3 | WRMSR | 0xC0010113 | SMMMask | Initial TSEG mask |
| 0x1caa | RDMSR | 0xC0010015 | HWCR | S3 resume SmmLock check |
| 0x1cbf | WRMSR | 0xC0010015 | HWCR | S3 SmmLock restore |

### SMMMask Bit Operations (CRITICAL for SinkClose)

```
Function: TClose_Clear (power-down preparation):
  RDMSR  0xC0010113       ; Read SMMMask
  AND RAX, 0xFFFFFFFC     ; Clear bits[1:0] = clears TSEG_EN[0] + AValid[1]
  WRMSR  0xC0010113       ; Write back

Function: TClose_Set + SmmLock (boot/S3 resume finalization):
  RDMSR  0xC0010113       ; Read SMMMask
  OR  RAX, 0x3            ; Set bits[1:0] = TSEG_EN[0] + AValid[1]
  WRMSR  0xC0010113       ; Write back (TClose bit[3] NOT touched by BIOS)
  -- conditional on SmmLock flag:
  RDMSR  0xC0010015       ; Read HWCR
  OR  RAX, 0x80000001     ; Set SmmLock[0] + bit[31]
  WRMSR  0xC0010015       ; Write HWCR -- LOCKS SMM

Function: Init_SMMAddr_SMMMask (initial setup):
  MOV ECX, 0xC0010112     ; SMMAddr
  WRMSR                   ; Write TSEG base from AGESA struct
  MOV ECX, 0xC0010113     ; SMMMask
  WRMSR                   ; Write TSEG mask from AGESA struct
```

### SMMMask Register Bit Layout (AMD PPR 55570, Family17h)
```
Bit[63:32] = reserved
Bit[31:17] = TValid  (TSEG valid mask upper bits)
Bit[16:4]  = TSeg_Mask (address mask)
Bit[3]     = TClose  -- SINKCLOSE VULNERABILITY BIT
Bit[2]     = AClose
Bit[1]     = AValid
Bit[0]     = TSEG_EN
```

**BIOS sets bits [1:0] only. Bit[3] (TClose) is NEVER set by BIOS.**
**CVE-2023-31315 exploits: WRMSR to bit[3] is not blocked even when SmmLock=1.**

### SmmLock Write Guard
The HWCR WRMSR is guarded by `cmpb [data+0x40dd], 0` -- a flag in the .data section.
If this flag is 0 (disabled), SmmLock is NOT written. This allows debug/test builds
to run without locking SMM. Production BIOS always sets this flag.

---

## FCH SPI BAR Protection Setup

### What BIOS Does NOT Do
Scanning the entire BIOS binary (16MB), FV1, FV2 decompressed:
- Zero direct writes to 0xFEC10004 (SPIRestrictedCmd)
- Zero direct writes to 0xFEC1001D (AltSPICS/SpiProtectLock)
- Zero WRMSR with SMMAddr/SMMMask in PEI or SEC phase

### Conclusion
FCH SPI BAR protection registers are initialized by:
1. **FCH ROM code** -- hardcoded in the FCH silicon ROM, runs before x86 code
2. **AGESA PSP** -- configured via PSP ARM firmware (FV4/PSP partition)
3. Not in the UEFI DXE/PEI phase at all

The S3 boot script references `R S3 SAVE Script: Address 0x%08x` indicate that
SPI BAR MMIO state is saved/restored across S3 via boot script, but the
initial configuration is not visible in the x86 UEFI code.

---

## AltSPICS (0xFEC1001D) Hardware Read Procedure

**Cannot be performed from KVM sandbox (agent runs on Intel Xeon VM).**
Must be executed on actual kenny-VivoBook-ASUSLaptop-X513IA hardware.

### Method 1: devmem2 (simplest)
```bash
# Install devmem2 if not present
sudo apt install devmem2

# Read AltSPICS register (byte access)
sudo devmem2 0xFEC1001D b

# Expected values:
# Bit[5] = SpiProtectLock
#   0x00 = SpiProtectLock clear -> SPI write protection NOT locked
#   0x20 = SpiProtectLock set  -> cannot clear RestrictedCmd from OS
```

### Method 2: /dev/mem + Python
```python
import mmap, struct
with open('/dev/mem', 'rb') as f:
    # FCH SPI BAR = 0xFEC10000, size = 0x100
    mm = mmap.mmap(f.fileno(), 0x100,
                   mmap.MAP_SHARED, mmap.PROT_READ,
                   offset=0xFEC10000)
    altspics = mm[0x1d]  # AltSPICS at offset 0x1D
    print(f"AltSPICS (0xFEC1001D) = 0x{altspics:02x}")
    spi_protect_lock = (altspics >> 5) & 1
    print(f"SpiProtectLock bit[5] = {spi_protect_lock}")
    # Also read SPIRestrictedCmd
    restr = struct.unpack('<I', mm[4:8])[0]
    print(f"SPIRestrictedCmd (0xFEC10004) = 0x{restr:08x}")
    # If bit 4 = 1: WREN (0x06) blocked
    # If bit 5 = 1: WRDI blocked
    # If bit 7 = 1: RDSR blocked
    mm.close()
```

### Method 3: Platbox IOCTL_READ_IO_PORT (via kernetix driver)
```c
// Use IOCTL_READ_IO_PORT -- actually reads MMIO via /dev/mem mmap
// OR: use IOCTL mechanism with physical address read through driver
```

### Prerequisite for /dev/mem access
```bash
# Check iomem_guard kernel config
cat /proc/cmdline | grep iomem
# Must NOT have: iomem=strict
# If strict: add iomem=relaxed to GRUB_CMDLINE_LINUX in /etc/default/grub
# Then: sudo update-grub && reboot
```

### What to Look For
```
AltSPICS (0xFEC1001D):
  Bit[5] = SpiProtectLock
    0 -> SPI write protection is software-configurable from SMM
         SinkClose path can clear RestrictedCmd -> direct SPI write
    1 -> SPI write protection is locked (write-once already set)
         Must use PSP proxy path for APCB write-back

SPIRestrictedCmd (0xFEC10004):
  If 0x00000000 -> No opcodes blocked, direct SPI access possible
  If non-zero   -> Some opcodes blocked (typical for production BIOS)
```
