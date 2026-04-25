# PSP SPI Architecture: AmdApcbDxeV3 Deep Disassembly

## Summary

Phase 5 complete disassembly of `AmdApcbDxeV3.pe32` (43,392 bytes, extracted from X513IAAS.308) reveals the complete APCB write-back architecture. The driver does NOT write SPI flash directly. All writes are proxied through the Platform Security Processor (PSP) via SMM communication.

## AmdApcbDxeV3 File Information

- Source: `/home/user/workspace/X513IAAS308_extracted/X513IAAS.308` (ASUS X513IA BIOS v3.08)
- PE32 size: 43,392 bytes
- Sections: `.text` (code), `.xdata` (exception tables), `.reloc`
- Total CALL instructions: 646
- WRMSR instructions: 4 (at PE offsets 0x157f, 0x15ac, 0x6d07, 0x78c7)
- RDMSR instructions: 8 (at PE offsets 0x1557, 0x15b3, 0x15d0, 0x1616, 0x1a43, 0x6b9c, 0x6cdc, 0x78bd)

## MSR Register Map (from disassembly)

| PE Offset | Op | ECX (MSR addr) | Name | Purpose |
|-----------|-----|----------------|------|---------|
| 0x1557 | RDMSR | 0xC001001F | SYS_CFG | System configuration |
| 0x157f | WRMSR | 0xC001001F | SYS_CFG | System configuration write |
| 0x15ac | WRMSR | (from EBX) | - | Follow-on SYS_CFG write |
| 0x15b3 | RDMSR | 0xC0010063 | - | Additional MSR read |
| 0x6b9c | RDMSR | 0x0000001B | IA32_APIC_BASE | Detect BSP during PSP BAR init |
| 0x6cdc | RDMSR | 0xC001100A | PSPADDR | Read current PSP MMIO base |
| 0x6d07 | WRMSR | 0xC001100A | PSPADDR | Write PSP MMIO base to MSR |
| 0x78bd | RDMSR | 0xC001100A | PSPADDR | Runtime read of PSP MMIO base |
| 0x78c7 | WRMSR | 0xC001100A | PSPADDR | Runtime set/lock PSP MMIO |

## PSPADDR MSR (0xC001100A)

The AMD Platform Security Processor MMIO base address is stored in MSR `0xC001100A`.

- The function `PspBarInitEarlyV2` at PE offset ~0x6b90 sets this up:
  1. Read `IA32_APIC_BASE` (MSR 0x1B) to identify BSP
  2. Call `FabricAllocateMmio v3` to allocate a MMIO window (below 4G, non-PCI device)
  3. Read current PSPADDR MSR -- if already set, skip
  4. Write allocated MMIO base to PSPADDR MSR
  5. Publish address to physical memory: `0xF00000B8` (low 32 bits), `0xF00000BC` (high 32 bits)

- At boot, `AmdApcbDxeV3` reads this MSR to know where PSP MMIO lives
- The runtime function at PE offset 0x78b0 reads/writes PSPADDR with bit manipulation:
  - `AND RAX, 0xFFFFFFFFFFFFFFFE` -- clear bit 0
  - `OR RAX, 1` -- set bit 0 (enable/lock flag)
  - This suggests bit 0 is a PSP MMIO enable/access control bit

## Full APCB Write-Back Call Chain

```
Runtime event (S3 resume, DIMM retraining, etc.)
  |
  v
ApcbRTBCallBack (PE offset ~0x8558 string)
  |
  v
AmdPspWriteBackApcbShadowCopy (entry logged at PE 0x82ee)
  |
  +-- Check 1: RecoveryFlag set? -> EXIT (0x8318/0x8350 strings)
  |
  +-- Check 2: Data different from SPI copy? (0x8420 string)
  |            -> NO CHANGE: bypass SPI write (0x84ce string)
  |
  +-- Check 3: APCB writes allowed at priority level? (0x8ab0 string)
  |
  +-- Path A: InSmm == TRUE
  |     Allocate temp buffer in SMRAM (0x8000 string)
  |     SmmInstallProtocolInterface(gPspFlashAccSmmCommReadyProtocol)
  |     -> signal to OutSmm handler that SMM comm is ready
  |
  +-- Path B: OutSmm == FALSE (DXE phase)
        Locate gPspFlashAccSmmCommReadyProtocol
          -> fail: "AmdPspFlashAccLibDxe locate gPspFlashAccSmmCommReadyProtocol fail"
          -> success: continue
        Locate SmmCommunicationProtocol
          -> fail: "AmdPspFlashAccLibDxe locate SmmCommunicationProtocol fail"
        Call PspWriteFlash(FlashAddr, Size, Buffer)
          Log: "PspWriteFlash [%x] %x %x %x" (0x9bf0)
          Log: "Updating SPI %x %x %x" (0x7f50)
          -> Write via PSP MMIO mailbox (C2P mailbox at PSPADDR + offset)
          -> PSP ARM core receives command, performs SPI erase/write
          PspEraseFlash(FlashAddr, Size)
            Log: "PspEraseFlash [%x] %x %x" (0x9c10)
```

## PSP SPI Gate Analysis

The key question: does the PSP validate flash write addresses, or proxy blindly?

**Answer: PSP validates against BIOS Directory Table entries.**

From AMD PSP architecture documentation and coreboot integration guide:
- The PSP uses a BIOS Directory Table (BDT) embedded in SPI flash
- BDT entry type `0x63` = APOB data NV (non-volatile APCB output block)
- BDT entry type `0x62` = BIOS reset image
- The PSP C2P mailbox flash write command includes a flash offset
- PSP firmware checks this offset against allowed BDT regions before writing
- Regions NOT in the BDT will be rejected

**Consequence for SinkClose SPI write via PSP proxy:**
- Writing APCB regions: ALLOWED (APCB is in BDT as writable NV data)
- Writing arbitrary BIOS code regions: BLOCKED by PSP
- Writing PSP firmware regions: BLOCKED (signed, encrypted, no writeback path)

**However: there is a direct FCH SPI BAR path that bypasses PSP entirely.**

## FCH SPI BAR Direct Write Path

The AMD Fusion Controller Hub SPI controller sits at MMIO `0xFEC10000`.

From the Platbox/IOActive research and `amd_spi.cpp`:

```
FCH SPI BAR = 0xFEC10000

Key registers:
  SPIx00 (0xFEC10000) = SPI_Cntrl0
    bit 23: SpiHostAccessRomEn (write-0-only, clears to block MAC ROM access)
    bit 22: SpiAccessMacRomEn  (SMM-only writeable)

  SPIx04 (0xFEC10004) = SPIRestrictedCmd
    bytes [31:24][23:16][15:8][7:0] = up to 4 blocked SPI opcodes

  SPIx08 (0xFEC10008) = SPIRestrictedCmd2
    same format, 4 more blocked opcodes

  SPIx1D (0xFEC1001D) = AltSPICS
    bit 3: SpiProtectEn0  (enable ROM protect range 0)
    bit 4: SpiProtectEn1  (enable ROM protect range 1)
    bit 5: SpiProtectLock (write-once -- locks SpiProtectEn bits)
    bit 6: lock_spi_cs    (CS lock)
```

From BIOS analysis of X513IAAS.308:
- `0xFEC10004` (SPIRestrictedCmd): **0 direct references** found in BIOS binary
- `0xFEC1001D` (AltSPICS): **0 direct references** found in BIOS binary
- `0xFEC10000` appears only in GCD memory map entries (not boot script writes)
- This means SPI protection registers are configured by FCH init code at early boot, not via S3 boot script

**SPI Write Unlock Procedure from SMM (Platbox technique):**
```c
// From PlatboxLib/src/amd/amd_spi.cpp
// 1. Map FCH SPI BAR
volatile SPI* spi_base = (volatile SPI*) 0xFEC10000;

// 2. Temporarily clear SPIRestrictedCmd to unblock WREN (0x06)
DWORD saved_cmd  = spi_base->SPI_RestrictedCmd;
DWORD saved_cmd2 = spi_base->SPI_RestrictedCmd2;
spi_base->SPI_RestrictedCmd  = 0x00000000;
spi_base->SPI_RestrictedCmd2 = 0x00000000;

// 3. Send WREN + sector erase + page program via SPI controller FIFO
amd_spi_write_enable(spi_base);    // WREN opcode 0x06
amd_spi_erase_4k_block(spi_base, target_addr);  // SE opcode 0x20
amd_spi_write_page(spi_base, target_addr, data, len);

// 4. Restore restricted cmds
spi_base->SPI_RestrictedCmd  = saved_cmd;
spi_base->SPI_RestrictedCmd2 = saved_cmd2;
```

**This works from SMM IF: `SpiProtectLock` (SPIx01D bit 5) is NOT set.**

If SpiProtectLock is set (write-once): SPIRestrictedCmd registers are permanently frozen and cannot be cleared even from SMM. This is the primary SPI write protection on consumer Renoir platforms.

**Need to verify on X513IA:** Read `0xFEC1001D` byte from ring-0 (via Platbox or /dev/mem).

## ROM Armor Status on X513IA

From IOActive research:
- ROM Armor = AMD's replacement for SPIRestrictedCmd, provides hardware-enforced region protection
- Implemented in newer FCH (post-Renoir era, approximately Cezanne/Van Gogh onwards)
- Renoir FP6 (Family 17h Model 60h) uses the older SPIRestrictedCmd mechanism, NOT ROM Armor
- **ROM Armor is NOT present on X513IA / Renoir FP6**

This means the SPI protection model on this platform is:
1. SPIRestrictedCmd/SPIRestrictedCmd2 -- opcode blocking (can be cleared from SMM if not locked)
2. ROM Protect ranges D14F3x50-5C -- PCI config space, address range protection
3. AltSPICS SpiProtectLock -- lock bit for the above

## PSP Flash Access SMM Communication Protocol

The `gPspFlashAccSmmCommReadyProtocol` is an AMD-internal GUID used to coordinate APCB writeback between DXE and SMM phases:

- DXE driver (`AmdApcbDxeV3`) runs OutSmm
- SMM handler (`AmdApcbDxeV3` re-entrant path) runs InSmm
- SMM handler installs `gPspFlashAccSmmCommReadyProtocol` to signal readiness
- DXE driver locates this protocol, then uses `EFI_SMM_COMMUNICATION_PROTOCOL` to invoke SMM handler
- SMM handler calls `PspWriteFlash` via PSP MMIO mailbox

**Key finding:** The PSP mailbox flash write IS gated by BDT region whitelist. But the FCH SPI BAR direct path (used by Platbox SinkClose PoC) bypasses PSP entirely and only requires SPIRestrictedCmd not be locked.

## Practical Implications for SMT Enable via SinkClose

If SinkClose gives SMM code execution on this platform:

| Target | Via PSP proxy | Via FCH SPI BAR direct |
|--------|--------------|----------------------|
| APCB region (0x29A000/0x6E2000) | ALLOWED (in BDT) | ALLOWED if SpiProtectLock=0 |
| BIOS code regions | BLOCKED by PSP | ALLOWED if SpiProtectLock=0 |
| Arbitrary flash | BLOCKED by PSP | ALLOWED if SpiProtectLock=0 |

For SMT enable (patch APCB token 0x0076):
- PSP proxy path: viable, APCB is in BDT whitelist
- FCH direct path: viable if SpiProtectLock=0 (needs verification)
- Recommended: check SpiProtectLock first; use whichever is available
