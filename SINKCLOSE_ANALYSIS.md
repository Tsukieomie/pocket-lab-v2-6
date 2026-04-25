# SinkClose (CVE-2023-31315) Analysis -- Renoir 4700U

Machine: kenny-VivoBook-ASUSLaptop-X513IA-M513IA
CPU: AMD Ryzen 7 4700U (Renoir, CPUID 0x00860601)
Microcode: 0x860010d (PRE-PATCH)
Date: 2026-04-25

---

## What SinkClose Is

CVE-2023-31315, discovered by IOActive (Enrique Nissim, Krzysztof Okupski),
published August 2024. Presented at DEF CON 32.

The bug: AMD's TClose feature (a legacy compatibility mechanism in the memory
controller) improperly remaps memory when enabled. An attacker with ring 0
(kernel) access can manipulate TClose to cause the CPU's SMM entry code to
read attacker-controlled data instead of SMRAM. This allows redirection of
SMM execution to arbitrary code -- effectively ring 0 -> ring -2 escalation.

Once in SMM, the attacker can:
- Read/write/erase the SPI flash chip directly (via SPI controller MMIO BAR)
- Disable AMD ROM Armor (if present)
- Disable Platform Secure Boot
- Install a persistent firmware implant (bootkit) invisible to the OS

---

## Affected Status: X513IA.308 with Ryzen 7 4700U

### Is Renoir FP6 affected?

YES. From the AMD security bulletin (AMD-SB-7014):

    AMD Ryzen 4000 Series Mobile Processors (Renoir FP6):
    CVE-2023-31315
    Mitigation: RenoirPI-FP6 1.0.0.E (2024-08-07)

The patched AGESA PI version is RenoirPI-FP6 1.0.0.E.
ASUS X513IA.308 was released 2021-10-26, well before this patch.

### Current microcode version

    Running: 0x860010d
    SinkClose patch microcode (Renoir FP6): not publicly listed
    (AMD provides microcode fix as hot-loadable OR via OEM PI update)

### Is ASUS X513IA.308 patched?

NO. ASUS has not released a BIOS update for the X513IA since 2021-10-26
(X513IA.308). RenoirPI-FP6 1.0.0.E was released 2024-08-07 and would require
a BIOS update incorporating the new AGESA PI. ASUS has not published one.

The machine is VULNERABLE to SinkClose.

---

## Exploit Chain for SPI Flash Write (Theoretical Path)

Using SinkClose to patch BIOS without external SPI clip:

### Prerequisites
    - Ring 0 (kernel) code execution on target machine
    - Pre-SinkClose microcode (0x860010d = confirmed pre-fix)
    - No ROM Armor (not present on consumer Renoir FP6)
    - No Platform Secure Boot enforcement at SPI write level
    - AMD Platform Security Processor (PSP) SPI access controls unknown

### Step 1: Obtain ring 0 access
    Options:
    a. Load kernel module (Secure Boot is DISABLED on this machine)
       -> modprobe a custom .ko that grants ring 0
    b. Use an existing ring 0 interface (msr, mem, devmem)
       -> /dev/mem with kernel.dmesg_restrict=0
    c. Exploit a kernel vuln (overkill -- we have Secure Boot disabled)

    Simplest path: write a kernel module that calls the SinkClose trigger.

### Step 2: Enable TClose and prime SMM save state
    From the IOActive slides (Hexacon 2024):
    1. Trigger SMI once WITHOUT TClose to prime the SMM save state
       (save state contains the pointer we redirect)
    2. Enable TClose via the memory controller MMIO register
    3. Remap the SPI controller BAR to overlap with TSEG (SMM entry point)
    4. Trigger SMI again WITH TClose enabled
    5. SMM entry code reads from our remapped SPI BAR instead of SMRAM
    6. Our payload executes inside SMM

    The IOActive tooling (Platbox) implements this. Source:
    https://github.com/IOActive/Platbox (not public as of 2026-04)
    IOActive stated exploit code would be released "mid November" [2024]
    -- current public availability is unknown.

### Step 3: SMM payload -- patch APCB in flash
    Once in SMM, the SPI controller is fully accessible at ring -2.
    SpiAccessMacRomEn hardware lock is enforced by SMM; being IN SMM
    bypasses our own enforcement.

    SMM payload actions:
    1. Locate SPI controller MMIO base (FCH_SPI_BASE: typically 0xFEC10000)
    2. Enable SPI write: write SPI_CNTL_ENABLE to SPI_STATUS register
    3. Erase sector containing primary APCB (0x29A000 in body.bin space)
    4. Write patched APCB (with token 0x0076 = 0x01) back to that sector
    5. Erase sector containing mirror APCB (0x6E2000)
    6. Write patched mirror APCB
    7. Return from SMM cleanly (restore save state)

    Sector erase granularity for W25Q128: 4KB sectors
    APCB primary at body 0x29A000, size 0x3A7C -- fits in sectors 0x29A000-0x29E000
    Erase: sectors 0x29A000 and 0x29E000 (two 4KB sectors)
    Write patched data back

### Step 4: Reboot
    Normal reboot. AGESA reads patched APCB from flash, sees CfgSMTControl=0x01,
    initializes SMT, presents 16 threads to OS.

---

## SinkClose vs External SPI Clip: Comparison

| Factor | SinkClose | External SPI Clip |
|--------|-----------|-------------------|
| Hardware cost | $0 | $8-15 (CH341A kit) |
| Risk of damage | Low (software, reversible) | Low (physical, recoverable) |
| Complexity | Very high (SMM payload dev) | Low (flashrom commands) |
| Time to implement | Weeks (custom kernel module + SMM payload) | Hours (hardware + procedure) |
| Public tooling | Not yet released | flashrom, fully supported |
| Recovery if bad | Must reflash with clip anyway | Clip is recovery method |
| Reproducibility | Fragile (timing-dependent) | Deterministic |

CONCLUSION: External SPI clip is the correct path. SinkClose is interesting
as a research angle (confirms the machine is exploitable at ring -2) but
is not a practical shortcut over the CH341A approach.

---

## SinkClose as Verification Tool

Before ordering hardware, you can verify the machine is pre-SinkClose-patch
with a microcode check, confirming the software path is theoretically available:

    # Current microcode
    grep microcode /proc/cpuinfo | head -1
    # microcode : 0x860010d

    # SinkClose patch for Renoir FP6 mobile:
    # RenoirPI-FP6 1.0.0.E microcode component (exact hex unknown)
    # Comparison: if your microcode < patched version, you are vulnerable

    # Also confirm TClose is present (it is on all Renoir):
    rdmsr 0xC0010111  # MSRC001_0111 -- SMM TSeg base
    rdmsr 0xC0010112  # MSRC001_0112 -- SMM TSeg base address
    rdmsr 0xC0010113  # MSRC001_0113 -- SMM TSeg mask

The presence of MSRC001_0112 and _0113 (accessible from ring 0 on AMD,
unlike Intel) confirms TClose infrastructure is present.

---

## ROM Armor Status

ROM Armor is AMD's SPI write protection feature separate from SMM lock.
If ROM Armor is enabled, even SMM code cannot write to SPI flash without
going through the PSP.

On the X513IA (consumer Renoir laptop, released 2020-2021):
- ROM Armor was not a standard feature for this era
- The flashrom error "SpiAccessMacRomEn = 0" is the standard BIOS SMM lock,
  NOT ROM Armor. ROM Armor would present differently.
- CSO Online (2024-08-09): "ROM Armor is a newer feature and does not exist
  in most computers impacted by the vulnerability"

Assessment: ROM Armor is NOT present on this machine.
SinkClose would have full SPI write access from SMM.

---

## Platbox / IOActive Tooling

The IOActive researchers developed "Platbox" for testing SinkClose:
    https://github.com/IOActive/Platbox

As of this writing the SinkClose exploit code has not been publicly released
(IOActive said "mid November [2024]" at Hexacon). The Platbox repo contains
SMM entry / debugging infrastructure but not the full TClose trigger chain.

Alternatives to watch:
- https://github.com/skysafe/reblog -- hardware security research tools
- AMD AMDiOUtils -- internal tool, not public
- Any community follow-on to the DEF CON talk

---

## Conclusion

The X513IA is confirmed vulnerable to SinkClose. The exploit path to SPI
flash write from ring 0 is theoretically clear:

1. Ring 0 via kernel module (Secure Boot disabled, already have root)
2. TClose manipulation to get SMM code execution  
3. SPI controller direct access from SMM
4. Patch APCB, reboot -- SMT enabled

This is a weeks-long development effort without published tooling.
External SPI clip achieves the same result in hours.

The practical recommendation remains: CH341A + 1.8V adapter + SOIC-8 clip.
SinkClose is documented here as a confirmed alternative path for the record.

---

## References

- IOActive SinkClose paper: https://ioactive.com/event/def-con-talk-amd-sinkclose-universal-ring-2-privilege-escalation/
- IOActive Hexacon 2024 slides: https://2024.hexacon.fr/slides/IOActive-AMD_Sinkclose-Universal_Ring_2_Privilege_Escalation.pdf
- AMD security bulletin: https://www.amd.com/en/resources/product-security/bulletin/amd-sb-7014.html
- Platbox tooling: https://github.com/IOActive/Platbox
- WIRED coverage: https://www.wired.com/story/amd-chip-sinkclose-flaw/

---

## Phase 5 Update: AmdApcbDxeV3 PSP Architecture (Deep Disassembly)

### APCB Write-Back Uses PSP Proxy -- Not Direct FCH SPI BAR

Full disassembly of AmdApcbDxeV3.pe32 (43,392 bytes) reveals:

- FCH SPI BAR 0xFEC10000 is **not directly referenced** in this driver
- All APCB write-backs route through: `AmdPspWriteBackApcbShadowCopy` -> `AmdPspFlashAccLibDxe` -> `gPspFlashAccSmmCommReadyProtocol` -> PSP C2P mailbox -> PSP ARM core -> SPI
- PSP MMIO base set via MSR `0xC001100A` (PSPADDR) by `PspBarInitEarlyV2`
- PSP validates write addresses against BIOS Directory Table -- APCB region is whitelisted, arbitrary regions are not

### Two SPI Write Paths from SMM

1. **PSP proxy path** (AGESA): gated by BDT whitelist, but APCB IS whitelisted
2. **FCH SPI BAR direct path** (Platbox technique): bypasses PSP, only gated by `AltSPICS.SpiProtectLock`

### Platbox SinkClose PoC Released

Commit `2bc0d2b` on November 12, 2024 added:
- `pocs/AmdSinkclose/sinkclose.cpp` (1,350 lines) -- full ring-0 to SMM exploit
- `pocs/AmdSinkclose/sinkclose.s` (157 lines) -- 32-bit entry shellcode
- Linux kernel driver updated in `PlatboxDrv/linux/driver/kernetix.c`

### TClose Bit Location

`TClose` = bit 3 of MSRC001_0113 (SMMMask). Setting it redirects SMRAM accesses to MMIO.

From Platbox sinkclose.cpp:
```c
void set_tclose_for_core(UINT32 core_id) {
    UINT64 tseg_mask = 0;
    do_read_msr_for_core(core_id, AMD_MSR_SMM_TSEG_MASK, &tseg_mask);
    tseg_mask = tseg_mask | (0b11 << 2);  // set TClose[3] and AClose[2]
    do_write_msr_for_core(core_id, AMD_MSR_SMM_TSEG_MASK, tseg_mask);
}
```

Core 1 cleanup (clear TClose, or triple-fault crashes system):
```asm
mov ecx, 0xc0010113
rdmsr
and eax, 0xfffffff3   ; clear TClose[3] and AClose[2]
wrmsr
```

### SPI Lock Verification Required

Critical open question: is `AltSPICS.SpiProtectLock` (FCH SPI BAR offset 0x1D, bit 5) set on X513IA?
- If 0: FCH direct SPI write from SMM is possible (SPIRestrictedCmd can be cleared)
- If 1: must use PSP proxy path (still works for APCB region)

Verify by reading 0xFEC1001D from ring-0 (/dev/mem or Platbox).

### ROM Armor

NOT present on Renoir FP6 (Family 17h Model 60h). ROM Armor was introduced in later FCH generations (roughly Cezanne era). This platform uses the older SPIRestrictedCmd mechanism.

See full analysis: `PSP_SPI_ARCHITECTURE.md`, `SINKCLOSE_EXPLOIT_CHAIN.md`
