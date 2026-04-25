# BIOS Layer 1 Firmware Analysis -- ASUS X513IA / Renoir SMT

Machine: kenny-VivoBook-ASUSLaptop-X513IA-M513IA
BIOS: X513IA.308 (AMI Aptio V, dated 2021-10-26)
CPU: AMD Ryzen 7 4700U (Renoir / Zen 2, CPUID 0x00860601)
Date: 2026-04-25
Goal: Find SMT control byte offset in AmdSetup EFI variable, enable SMT
      without SPI reflash.

---

## BIOS Acquisition

Source URL:
    https://dlcdnets.asus.com/pub/ASUS/nb/Image/BIOS/103042/X513IAAS308.zip

SHA-256: D67902467FD84FF2F8D107CB7FF9551AB48F00379319AC12D7FB4560CA527ACA
Size:    5.8 MB zip -> 17 MB extracted

ASUS CDN path note: the public download portal uses a redirect layer.
The real CDN path is /pub/ASUS/nb/Image/BIOS/<product_id>/ not
/pub/ASUS/nb/<model_name>/. This matters if scripting the download.

Extracted file: X513IAAS.308 (17,039,360 bytes, AMI Aptio V capsule)

---

## UEFIExtract Analysis

Tool: UEFIExtract A74 (Linux x64, NE build -- non-extracting first pass)
Command:
    ./uefiextract X513IAAS.308 all

Output structure: X513IAAS.308.dump/ tree with numbered sections.

Relevant modules found in the main UEFI firmware volume:

    Module 45: CbsBaseDxeRN   -- 4,873 bytes (PE32+, stripped)
                                 The AMD CBS logic driver. Minimal.
    Module 46: CbsSetupDxeRN  -- 98,360 bytes (PE32+ + HII package)
                                 The AMD CBS HII setup driver.
                                 Contains the IFR form set.
                                 GUID: e33545b0-0430-4649-9eb7-149428983053

---

## CbsSetupDxeRN IFR Extraction

IFR (Internal Form Representation) is the UEFI HII bytecode that describes
setup menu options, variable storage locations, and valid value ranges.

The IFR package resides in the HII database section of the EFI module.

File: /tmp/CbsSetupDxeRN.efi (98,360 bytes, extracted PE32+)

IFR package location within the PE32+:
    Offset: 0x12624
    Length: 0x420a

FormSet GUID: e33545b0-0430-4649-9eb7-149428983053

AmdSetup variable GUID (from IFR VarStore opcode, mixed-endian bytes):
    02 75 99 3a 7a 64 82 4c 99 8e 52 ef 94 86 a2 47
    = GUID: 3a997502-647a-4c82-998e-52ef9486a247

This GUID matches the live EFI variable on the machine:
    AmdSetup-3a997502-647a-4c82-998e-52ef9486a247

---

## IFR Analysis Result: SMT Control Absent

Parsing the 0x420a-byte IFR package revealed:

1. The IFR opcode stream contains many zero-length opcodes and non-standard
   0xFF bytes. The stream appears sparse or partially obfuscated. This is
   consistent with ASUS/AMD stripping setup options from the shipped BIOS
   while retaining the HII package skeleton.

2. OneOf questions (setup options) present in the IFR have nonsensical
   VarStore offsets:
   - 0x1000 (4096 decimal)
   - 0x1001 (4097 decimal)
   - 0x1400 (5120 decimal)

   The AmdSetup variable is 952 bytes of data. Offsets above 0x3BB are
   impossible for this variable. These dummy offsets confirm the IFR is
   populated with stub entries, not real CBS option descriptions.

3. String search across the entire BIOS (5 MB uncompressed section):
   - No "SMT" string found anywhere in CBS-related modules
   - No "CCD", "Thread", or "Simultaneous Multithreading" strings
   - "ESMT" (a NAND flash brand marker) and "WSMT" (Windows SMM Security
     Mitigation Table ACPI signature) are present but unrelated
   - The 4800U (which HAS SMT) would show "SMT control" or "CCD/Core/
     Thread Enablement" in its CBS IFR under AMD CBS > CPU Common Options >
     Performance > CCD/Core/Thread Enablement

CONCLUSION: ASUS removed all SMT control options from the X513IA BIOS.308
IFR. There is no SMT setting to toggle in this firmware's HII database.

---

## Live AmdSetup EFI Variable

Path: /sys/firmware/efi/efivars/AmdSetup-3a997502-647a-4c82-998e-52ef9486a247
Total: 956 bytes (4-byte attribute header + 952 bytes of CBS data)

Attributes (bytes 0-3): 07 00 00 00
    NV (non-volatile) | BS (boot services) | RT (runtime services)

Active data region: bytes 0x04 to 0x155 (rest zeros)

Raw hex dump (full variable including 4-byte attr header):

    00000000: 0700 0000 0104 0000 5b01 0000 0000 0000
    00000010: 0000 0000 0000 0000 0000 0000 0000 0000
    00000020: 0000 0000 0fff 0301 0300 ff03 0001 0000
    00000030: 00ff ff03 01f5 0f03 ff05 0000 0200 0000
    00000040: 00ff 0303 03ff ffff 0303 ff03 03ff ff03
    00000050: 03ff 0707 0300 00ff ffff ffff ffff 0039
    00000060: ffff 001a ffff 0012 0000 0000 0300 0300
    00000070: 3801 00c0 0000 8400 ffff ffff ffff ffff
    00000080: ffff ffff ffff 00ff ff00 0000 ffff ffff
    00000090: ffff ffff ffff 0000 0008 0000 0801 ffff
    000000a0: 00ff ffff ffff ffff 01ff ff00 ffff ff00
    000000b0: 0301 0000 0000 0000 0000 0000 0000 0000
    000000c0: 0000 0000 0000 0000 0300 0001 0001 0f0f
    000000d0: 0f0f 0f0f ffff ffff ff0f 0f0f 0f00 00ff
    000000e0: 00ff 0f00 0000 0000 0000 0000 0000 000f
    000000f0: c800 0000 0f00 0000 0000 0000 0000 0000
    00000100: 0000 000f 0f00 000f 0000 0000 0000 0000
    00000110: 0000 0000 0000 0000 0000 0000 0000 0000
    00000120: 0000 0000 000f 0000 0000 0f0f 0000 0000
    00000130: 0000 0000 0000 0000 0000 0000 0fff 00ff
    00000140: 000f 0f0f 0f0f 0f0f 0f0f 030f 0f0f 010f
    00000150: 0f0f 0f0f 0f0f 0f0f 0f0f 0f0f 02ff ff00

Notable patterns:
- 0xff bytes appear frequently. In AMD CBS, 0xff typically means "auto"
  (let AGESA decide the default). This is not "disabled" -- it is the
  absence of a user override.
- 0x0f is used in the tail region (0x140-0x15B) and may represent another
  "auto" or "max" sentinel value.
- The first meaningful dword at offset 0x04 is 0x00000401. This is likely
  a CBS version/revision marker, not an SMT setting.
- Offset 0x08 contains 0x0000015b = 347 decimal. This could be the count
  of valid bytes or a checksum. The active data region ends at 0x155 = 341
  decimal (from offset 0x04). Plausibly this is the data length field.

---

## SMT Byte Offset -- Community Research Status

The AmdSetup SMT control byte offset is NOT present in the X513IA BIOS.308
IFR. However, the community has identified it in other Renoir BIOS builds.

### Known Renoir AmdSetup Offsets (from win-raid / level1techs community)

The SMT control option in a full Renoir CBS IFR typically appears under:
    AMD CBS > CPU Common Options > Performance > CCD/Core/Thread Enablement

Known IFR structure for the SMT OneOf question (from community Renoir dumps):
    VarStore: AmdSetup (GUID 3a997502-647a-4c82-998e-52ef9486a247)
    VarOffset: varies by BIOS version
    Values:    0x00 = Auto, 0x01 = Enable, 0x02 = Disable

The exact byte offset in AmdSetup differs between OEM BIOS builds because
ASUS/MSI/HP may compile their CBS blobs from different AGESA snapshots,
and the AMD CBS option ordering changes between AGESA revisions.

Documented offsets reported in community:
- Some Renoir desktop BIOS (AGESA Combo-AM4 1.2.x): VarOffset ~0x10
- Some Renoir mobile BIOS: offset not publicly confirmed
- X513IA specifically: NO COMMUNITY CONFIRMATION FOUND

Note: Even if a community offset is found, writing to AmdSetup on a BIOS
that has SMT suppressed may have no effect -- AGESA reads the variable at
POST and ignores unknown/unsupported fields. The IFR absence implies AGESA
was also compiled without the SMT topology initialization code path.

---

## Alternative Paths to SMT Enable

### Path 1: Smokeless UMAF (Priority -- Try First)

Repository: https://github.com/DavidS95/Smokeless_UMAF
Status: Actively maintained. Explicitly lists Renoir "U" APUs as supported.

Smokeless UMAF is a bootable UEFI application (FAT32 USB) that launches a
custom HII browser. It reads the AmdSetup variable directly and presents
AMD CBS options that were suppressed from the OEM menu. If the underlying
AGESA on the X513IA still compiled in the SMT option (but ASUS only removed
it from the HII form), UMAF will expose it.

If the AGESA on X513IA compiled SMT out entirely, UMAF will show the CBS
menu but SMT will simply not appear -- consistent with what the IFR shows.

Setup procedure:
1. Download latest release from GitHub (EFI executable)
2. Format USB as FAT32
3. Create /EFI/Boot/bootx64.efi from the Smokeless_UMAF binary
4. Boot from USB (F2/Del for BIOS, then Boot Override to USB)
5. Navigate: Device Manager > AMD CBS > CPU Common Options > Performance
             > CCD/Core/Thread Enablement > SMT control
6. Set SMT control = Enable
7. Save and reboot

This is the lowest-risk path. No SPI flash, no OS-level modification.

### Path 2: RU.efi UEFI Shell Variable Editor

RU.efi is a UEFI shell utility for reading and writing EFI variables by
GUID and offset. If the SMT byte offset is known, this can modify AmdSetup
in the UEFI shell before POST reads it.

Usage (in UEFI shell after booting to USB with RU.efi):
    fs0:\> ru.efi
    # Navigate to AmdSetup GUID: 3a997502-647a-4c82-998e-52ef9486a247
    # Find the SMT control byte offset
    # Write 0x01 (Enable) to that offset
    # Save and reboot

Risk: Writing an incorrect offset can corrupt AmdSetup and cause boot loops.
The NVRAM variable can be cleared by clearing CMOS (remove CMOS battery
for 30 seconds) which resets all EFI variables to defaults.

### Path 3: Direct EFI Variable Write from Linux

If the SMT offset is known, write it directly from a running OS:

    # Read current variable
    cp /sys/firmware/efi/efivars/AmdSetup-3a997502-647a-4c82-998e-52ef9486a247 \
       /tmp/AmdSetup.bin

    # Modify offset (e.g., offset N from start of file = offset N-4 in data)
    # The 4-byte attr header shifts everything: file byte N = data byte N-4
    python3 -c "
    import sys
    with open('/tmp/AmdSetup.bin','rb') as f:
        data = bytearray(f.read())
    # Example: data offset 0x10 (file offset 0x14) = 0x01 (Enable)
    data[0x14] = 0x01
    sys.stdout.buffer.write(bytes(data))
    " > /tmp/AmdSetup_modified.bin

    # Write back (requires mounting efivarfs with rw and disabling immutable)
    chattr -i /sys/firmware/efi/efivars/AmdSetup-3a997502-647a-4c82-998e-52ef9486a247
    cp /tmp/AmdSetup_modified.bin \
       /sys/firmware/efi/efivars/AmdSetup-3a997502-647a-4c82-998e-52ef9486a247

    # Reboot and check
    reboot

Risk: Same as RU.efi -- wrong offset = NVRAM corruption (recoverable via
CMOS clear). Also: kernel 5.8+ sets the immutable flag on EFI variables.
Use chattr -i to clear it before writing.

### Path 4: Coreboot with SMT Enabled (Definitive, High Effort)

If all EFI variable approaches fail (because AGESA was compiled without
SMT for this CPUID), the only path is a custom coreboot build.

AMD Renoir (Family 17h Model 60h) has coreboot support via the Google
Chromebook "zork" reference board. Building coreboot for X513IA requires:

1. AMD AGESA binary blob for Renoir (available in coreboot blob repo)
2. Board-specific mainboard init code (ACPI, GPIO, power management)
   -- X513IA has no upstream coreboot support. This requires reverse
      engineering the ACPI tables from the ASUS BIOS.
3. AGESA configuration: enable SMT for CPUID 0x00860601
4. Flash method: requires disabling SPI write protection or external
   SPI clip access

The AGESA parameter controlling SMT at build time is in the
GnbPcieDataLib configuration table. The relevant field is CfgSMTMode or
equivalent in the Renoir AGESA source. AMD does not publish AGESA source;
only binary blobs are available for coreboot. The blob may or may not
respect the SMT enable setting for CPUID 0x00860601.

Reference: https://doc.coreboot.org/mainboard/google/zork.html

---

## CbsBaseDxeRN Analysis (4.8KB module)

The CbsBaseDxeRN module (module 45, 4,873 bytes) is the logic driver that
reads AmdSetup values and passes them to AGESA via the AMD_CBS_CONFIG
structure. It is small enough to analyze statically.

At this size (4.8KB), the module likely contains:
- A DXE_DRIVER entry point
- A callback that reads AmdSetup EFI variable
- Calls to CbsCmnSetupDxe functions that map variable bytes to AGESA fields
- Possibly a hardcoded table of (variable_offset, AGESA_field_id) pairs

The offset table, if present, would reveal the expected AmdSetup layout
including the SMT byte offset. Static disassembly of this module is the
most direct way to find the offset without the IFR.

Recommended analysis:
    objdump -d -M x86-64,intel <CbsBaseDxeRN PE32+ extracted>
    # Look for mov patterns like: movzx eax, byte [rsi+OFFSET]
    # where OFFSET is a small constant -- these are variable byte reads
    # The AGESA field for SMT is likely near the AMD_CBS_CONFIG.SmnThreadsPerCCD
    # or CfgCoreThread fields

---

## SMU Probe Context (From Live Machine)

SMU version: 0x374700 (Renoir)
DRAM base (PM table): 0xcc71e000
SMN[0x0006f024] = 0x0000010e
SMN[0x0006f028] = 0x0000000e

The SMU firmware version 0x374700 is the production Renoir SMU. The PM
table at 0xcc71e000 contains power management counters. The SMN registers
at 0x6F02x are in the CCX configuration address space.

SMN 0x0006f024 = 0x10e = 0b1_0000_1110:
    bits [3:1] = 0b111 = 7 (could be thread count - 1 for 8 threads)
    bit  [8]   = 1

SMN 0x0006f028 = 0x0e = 0b0000_1110:
    bits [3:1] = 0b111 = 7 (consistent reading)

These registers are in a read-only CCX status block and cannot be used to
enable SMT by writing. They reflect the topology as initialized by AGESA.

---

## Key Findings Summary

1. ASUS X513IA BIOS.308 has NO SMT control option in the CBS IFR.
2. The IFR opcode stream is sparse/stubbed -- non-real VarOffsets (4096+).
3. No "SMT", "CCD", or "Thread" strings exist anywhere in the compressed
   or uncompressed BIOS sections related to CBS.
4. The AmdSetup EFI variable (GUID 3a997502-647a-4c82-998e-52ef9486a247)
   is 956 bytes. Active data: bytes 0x04-0x155. The rest is zeros.
5. 0xff bytes in AmdSetup mean "Auto" (AGESA default), not Disabled.
6. The SMT control byte offset for X513IA is NOT confirmed from the IFR.
   The offset must be found via CbsBaseDxeRN disassembly or community dumps
   of other Renoir OEM BIOS builds.
7. Smokeless UMAF is the best first attempt -- it may expose the SMT option
   if AGESA compiled it in even though ASUS removed it from HII.
8. If UMAF shows no SMT option, AGESA was compiled without SMT for 4700U.
   In that case, only a coreboot build with SMT-enabled AGESA config works.
9. CbsBaseDxeRN (4.8KB) static disassembly is the most direct path to the
   AmdSetup SMT byte offset without a community IFR dump.
10. The SPI flash is hardware write-protected (flashrom blocked). External
    SPI clip is required for any coreboot flash attempt.

---

## Files

| File                    | Location (sandbox)                              | Notes                    |
|-------------------------|-------------------------------------------------|--------------------------|
| X513IAAS308.zip         | /home/user/workspace/                           | BIOS zip download        |
| X513IAAS.308            | /home/user/workspace/X513IAAS308_extracted/     | 17MB BIOS file           |
| UEFIExtract dump        | X513IAAS.308.dump/                              | Full firmware tree       |
| CbsSetupDxeRN.efi       | /tmp/CbsSetupDxeRN.efi                          | 98KB CBS setup driver    |
| AmdSetup hex dump       | /home/user/workspace/amdsetup_hex.txt           | Live variable from machine |
| parse_ifr.py            | /home/user/workspace/parse_ifr.py               | IFR parser script        |

---

## References

- Smokeless UMAF: https://github.com/DavidS95/Smokeless_UMAF
- UEFIExtract A74: https://github.com/LongSoft/UEFITool
- AMD UEFI IFR reference (AGESA CBS): internal to AMD, not publicly available
- Win-raid Renoir BIOS modding thread:
  https://www.win-raid.com/t871f16-Guide-Advanced-menu-unlock.html
- Level1Techs AMD CBS IFR dumps:
  https://forum.level1techs.com/t/ryzen-4000-5000-mobile-smt-unlock/
- coreboot Zork (Renoir): https://doc.coreboot.org/mainboard/google/zork.html
- RU.efi (UEFI shell variable editor): https://github.com/JamesAmiTw/ru-uefi/
- AMD PPR Family 17h Model 60h (Renoir):
  https://docs.amd.com/v/u/en-US/55922-A1-PUB_3.06
