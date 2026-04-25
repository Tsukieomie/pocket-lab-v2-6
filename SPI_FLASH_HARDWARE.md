# SPI Flash Hardware -- X513IA BIOS Chip Identification

Machine: kenny-VivoBook-ASUSLaptop-X513IA-M513IA
BIOS: X513IA.308 (AMI Aptio V, 2021-10-26)
CPU: AMD Ryzen 7 4700U (Renoir FP6 socket)
Date: 2026-04-25

---

## Flash Chip Size

BIOS file: 16,779,264 bytes (16MB + 0x800 EFI capsule header)
Body.bin:  16,777,216 bytes = exactly 16MB = 128Mbit

This is a 128Mbit SPI NOR flash chip in SOIC-8 package.

---

## JEDEC IDs Embedded in BIOS

The BIOS image contains JEDEC manufacturer/device ID bytes that identify
which chips the firmware was built to run on:

    Offset 0x0077b608: EF 70 18  -> Winbond W25Q128JW (1.8V, 128Mbit)
    Offset 0x0077b60a: EF 70 18  -> Winbond W25Q128JW (1.8V, 128Mbit)
    Offset 0x00adc284: C8 40 18  -> GigaDevice GD25Q128 (3.3V, 128Mbit)

The W25Q128JW JEDEC ID (EF 70 18) appears TWICE while GD25Q128 appears once.
The dual W25Q128JW hit suggests the primary flash chip is Winbond 1.8V.
The GD25Q128 hit may be an alternative/fallback in the flashrom detection table.

---

## Chip Identification -- Physical Verification Required

YOU MUST READ THE CHIP MARKINGS WITH MAGNIFICATION BEFORE ORDERING HARDWARE.

Winbond W25Q128 part number decoder:

    W25Q128 J V SQ
             ^ ^
             | +-- package: SQ=SOIC-8, IQ=WSON-8
             +---- voltage: J=3.3V, F=1.8V, JW=1.8V (JW variant)

    W25Q128JW** = 1.8V  (JEDEC: EF 70 18) -- LIKELY based on BIOS evidence
    W25Q128FW** = 1.8V  (JEDEC: EF 60 18)
    W25Q128JV** = 3.3V  (JEDEC: EF 40 18)

Common chips on ASUS Renoir FP6 boards:
    Winbond W25Q128JWSQ   (1.8V, SOIC-8)  -- most likely
    Winbond W25Q128FWSQ   (1.8V, SOIC-8)  -- possible
    Winbond W25Q128JVSQ   (3.3V, SOIC-8)  -- less likely on FP6

---

## Physical Location on X513IA Motherboard

Standard SOIC-8 location conventions for ASUS AMD FP6 laptops:

1. Remove bottom cover (10 Phillips screws)
2. The SPI flash chip is an 8-pin IC (SOIC-8) near the APU/PCH area
3. Look for: small rectangular IC with 8 legs, often with colored dot on pin 1
4. On ASUS FP6 boards it is typically near the battery connector area
5. Use phone macro lens or magnifier to read chip markings

How to identify with multimeter (power off, no battery):
- Pin 8 (VCC) should read 1.8V or 3.3V when board is powered
- Do NOT power on while clip is attached -- use clip with power off

---

## CH341A Hardware Requirements

### If chip is 1.8V (W25Q128JW** or W25Q128FW**) -- LIKELY
    Required: CH341A programmer + 1.8V adapter board
    DO NOT use standard CH341A directly on 1.8V chip -- will damage chip
    
    Kit to order (covers all cases):
    "CH341A USB Programmer + SOIC-8 clip + 1.8V adapter"
    Search: "CH341A 1.8V SOIC8 programmer kit"
    Cost: ~$8-15 shipped
    
    The 1.8V adapter:
    - Plugs between CH341A and chip (or clip)
    - Level-shifts 3.3V CH341A signals to 1.8V
    - Has its own 1.8V LDO regulator
    - Provides correct VCC to chip

### If chip is 3.3V (W25Q128JV**)
    Standard CH341A works BUT: many CH341A boards have a hardware defect
    where they output 5V instead of 3.3V on IO lines. Always mod or verify.
    
    Safer: CH341A v1.6+ (has voltage select switch)
    
    Flashrom command for 3.3V:
        flashrom -p ch341a_spi -r backup.bin
        flashrom -p ch341a_spi -w X513IAAS.308.smt_patched

    Flashrom command for 1.8V (after connecting 1.8V adapter):
        Same commands -- flashrom detects chip automatically

---

## CLIP Procedure (power-off, in-circuit)

1. Fully power off -- hold power button 10 seconds
2. Remove AC adapter AND laptop battery (disconnect battery cable)
3. Locate SPI flash chip on motherboard (see above)
4. Identify pin 1 (dot/notch marking on chip)
5. Attach SOIC-8 clip -- red wire to pin 1
6. If 1.8V chip: connect 1.8V adapter between clip and CH341A
7. Connect CH341A to USB on a second Linux machine
8. Test connection: sudo flashrom -p ch341a_spi
9. Read backup: sudo flashrom -p ch341a_spi -r original_$(date +%Y%m%d).bin
10. Verify backup size: ls -la *.bin  # expect 16777216 bytes
11. SHA256 the backup: sha256sum original_$(date +%Y%m%d).bin  # save this
12. Write patched: sudo flashrom -p ch341a_spi -w X513IAAS.308.smt_patched
13. Verify write: sudo flashrom -p ch341a_spi -v X513IAAS.308.smt_patched
14. Disconnect clip, reassemble, test boot

If flashrom cannot detect chip:
- Check clip alignment (pin 1 to pin 1)
- Try: sudo flashrom -p ch341a_spi -c W25Q128JW  (force chip model)
- Try: sudo flashrom -p ch341a_spi -c W25Q128FW
- Try: sudo flashrom -p ch341a_spi -c W25Q128.V  (generic)
- Reconnect clip, ensure battery is disconnected, retry

---

## Risk Assessment

    Risk level: MODERATE
    
    Mitigations:
    - External clip allows recovery even from a corrupted flash
    - Backup before write (step 9 above)
    - Verify after write (step 13 above)
    - patch_apcb_smt.py is minimal -- changes 2 bytes + zeros 2 checksums
    
    Worst case: flash goes wrong -> re-flash from backup (external clip)
    There is no permanent brick risk with external clip available.

---

## References

- Winbond W25Q128JW datasheet: https://www.winbond.com/resource-files/w25q128jw%20revf%2003272018%20plus.pdf
- flashrom chip database: https://www.flashrom.org/Supported_hardware
- CH341A guide: https://winraid.level1techs.com/t/guide-flash-bios-with-ch341a-programmer/32948
- ASUS VivoBook M513 disassembly: https://laptopmedia.com/highlights/inside-asus-vivobook-15-m513-disassembly-and-upgrade-options/
