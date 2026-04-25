# Related Vulnerabilities -- CPU Microcode / Hardware Security

Companion to ENTRYSIGN_4700U.md. Covers CVEs and research that share
attack surface, exploitation primitives, or impact with EntrySign.

---

## AMD -- Direct EntrySign Family

### CVE-2024-56161 / AMD-SB-3019
- CVSS: 7.2 High
- Summary: SEV-SNP confidential computing broken by arbitrary microcode load
- Scope: Zen 1 through Zen 5 (SEV-capable)
- Fixed: RenoirPI-FP6 1.0.0.Eb (2025-01-14) for Renoir; varies by platform
- Reference: https://www.amd.com/en/resources/product-security/bulletin/amd-sb-3019.html

### CVE-2024-36347 / AMD-SB-7033
- CVSS: 6.4 Medium
- Summary: General x86 microcode signature bypass -- any Zen 1-5 with root
- Scope: All Zen 1 through Zen 5
- Reference: https://www.amd.com/en/resources/product-security/bulletin/amd-sb-7033.html

### CVE-2025-0032 / AMD-SB-4012, SB-3014, SB-5007
- CVSS: 7.2
- Summary: Improper cleanup after microcode patch loading -- information leakage
- Disclosed: August 2025
- Scope: Client (SB-4012), Server (SB-3014), Embedded (SB-5007)
- Reference: https://www.cve.org/CVERecord?id=CVE-2025-0032
- References:
    https://www.amd.com/en/resources/product-security/bulletin/amd-sb-4012.html
    https://www.amd.com/en/resources/product-security/bulletin/amd-sb-3014.html
    https://www.amd.com/en/resources/product-security/bulletin/amd-sb-5007.html

### CVE-2024-21977
- CVSS: 3.2 Low
- Summary: Microcode patch loading cleanup degrades RDRAND entropy for SEV-SNP guests
- Scope: SEV-SNP capable processors
- Note: Narrower than CVE-2024-56161; targets entropy specifically

### CVE-2025-62626 / AMD-SB-7055 -- Zen 5 RDSEED Failure
- CVSS: 7.2
- Summary: 16-bit and 32-bit RDSEED return 0 while reporting CF=1 on Zen 5
- Scope: AMD Zen 5 processors only
- Impact: Software using RDSEED r16 or RDSEED r32 generates zero seeds
  while believing RDSEED succeeded. Key generation and PRNG seeding may
  produce weak or identical output.
- Safe form: RDSEED r64 (64-bit operand size) is not affected
- Workaround: Boot with clearcpuid=rdseed to disable RDSEED advertisement
- Reference: https://www.amd.com/en/resources/product-security/bulletin/amd-sb-7055.html

---

## AMD -- Zen 2 Prior Work

### Zenbleed (CVE-2023-20593)
- CVSS: 6.5 Medium
- Researcher: Tavis Ormandy (Google)
- Summary: vzeroupper misprediction causes cross-process register file leak
- Scope: All Zen 2 -- including Ryzen 4700U
- Fixed microcode: 0x860010b for Renoir (note: pre-EntrySign baseline)
- Attack: Remote (via browser JIT, no privilege required)
- Reference: https://github.com/google/security-research/security/advisories/GHSA-v6wh-rxpg-cmm8
- Note: EntrySign enables an attacker to undo Zenbleed mitigation by loading
  a microcode patch that reverts the vzeroupper fix

### SQUIP (CVE-2021-46778)
- Scheduler Queue Usage via Interference Probing
- Scope: Zen 1, Zen 2, Zen 3
- Summary: Side-channel through scheduler queues -- leaks crypto key material
- Requires local code execution on the same physical core

---

## Intel -- Comparable Attack Classes

### Intel SGX Key Extraction (Multiple CVEs)
- SGAxe, CacheOut, PLATYPUS extracted SGX sealing keys via cache/power attacks
- Reference: https://sgx.fail
- Analogy: EntrySign breaks AMD SEV-SNP the same way SGX attacks broke
  Intel TEE guarantees -- attacker with sufficient access nullifies the
  hardware security boundary

### Plundervolt (CVE-2019-11157)
- CVSS: 7.9
- Summary: Undervolting corrupts SGX enclave computation, enables key recovery
- Scope: Intel 6th-10th gen (SGX-capable)
- Relevance: Demonstrates that hardware-level attacks (voltage / microcode)
  can bypass software isolation models that assume hardware integrity

### Spectre v2 (CVE-2017-5715) -- AMD Zen 2 Variant
- Scope: Zen 2 is affected by Spectre v2 (retpoline-resistant variant BHI)
- Reference: https://www.notebookcheck.net/Spectre-CPU-vulnerability-yet-again-discovered.html
- EntrySign intersection: a microcode patch could disable AMD's Spectre
  mitigations (IBRS, STIBP, SSBD) by patching the WRMSR handlers for the
  relevant MSRs, re-enabling the original Spectre variants

### SLAM (2023, Vrije Universiteit Amsterdam)
- Summary: Spectre-based Linear Address Masking attack; bypasses ASLR on
  future CPUs with LAM/UAI features
- Not currently applicable to Zen 2 but included as forward-looking context

---

## Microcode Research / Tooling

### 39C3 -- The Angry Path to Zen (December 2025)
- Researchers: Benjamin Kollenda et al.
- Conference: 39th Chaos Communication Congress
- Summary: Physical ROM extraction via electron microscope, full Zen 1/2
  microcode ISA disassembly, XXTEA decryption algorithm recovery
- Tools: https://github.com/AngryUEFI
- Reference: https://media.ccc.de/v/39c3-the-angry-path-to-zen-amd-zen-microcode-tools-and-insights

### zentool (Google Security Research)
- AMD Zen microcode manipulation: view, edit, resign, load
- Supports Zen 1 through Zen 4
- Reference: https://github.com/google/security-research/tree/master/pocs/cpus/entrysign/zentool

### Rowhammer (CVE-2015-0565 and descendants)
- Not directly related to microcode, but shares the "physical hardware
  security assumption violated by software" attack class
- DRAM bit-flip attacks bypass OS memory isolation
- EntrySign + Rowhammer: combined attack could load microcode that assists
  in DRAM address manipulation for more reliable Rowhammer exploitation

---

## Attack Chains Enabled by EntrySign

### Chain 1: SEV-SNP VM Escape
1. Attacker gains root on host hypervisor (or is malicious cloud operator)
2. Load adversarial microcode into one core of an SEV-SNP guest via EntrySign
3. Microcode patch intercepts cryptographic operations (RDRAND, AES-NI)
4. Extract guest private keys or force predictable key generation
5. Decrypt guest data without access to guest memory

### Chain 2: Linux Entropy Poisoning
1. Attacker has root on a local machine (pre-compromise)
2. Load microcode that makes RDRAND return attacker-controlled values
3. /dev/urandom entropy pool is influenced by poisoned RDRAND
4. Subsequent key generation (SSH host keys on reboot, TLS ephemeral keys)
  may be weakened or attacker-predictable

### Chain 3: Spectre Re-enablement
1. Load microcode patch that modifies IBRS/STIBP/SSBD WRMSR handling
2. Spectre mitigations are silently disabled without OS awareness
3. Use Spectre v2 to read kernel memory from userspace
4. Combined: root privileges not required after initial microcode load step

### Chain 4: KASLR Defeat + Persistence
1. Load microcode that patches the RDTSC or RDRAND handler to leak
  physmap-adjacent address information
2. Use leaked info to bypass KASLR without /proc/kcore access
3. Load further microcode without requiring kptr_restrict bypass

---

## References

- AMD EntrySign blog: https://www.amd.com/en/blogs/2025/addressing-microcode-signature-vulnerabilities.html
- Ubuntu tracker: https://ubuntu.com/security/vulnerabilities/entrysign
- oss-sec disclosure: https://seclists.org/oss-sec/2025/q1/176
- NVD CVE-2024-56161: https://nvd.nist.gov/vuln/detail/CVE-2024-56161
- SGX.fail: https://sgx.fail
- RDRAND / Linux entropy: https://lwn.net/Articles/760584/
- Torvalds on RDRAND (2013): https://news.ycombinator.com/item?id=6359892
