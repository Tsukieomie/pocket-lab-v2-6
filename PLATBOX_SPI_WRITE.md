# Platbox / kernetix SPI Flash Write — Technique Notes
**Platform:** AMD Renoir (Ryzen 7 4700U), ASUS X513IA  
**Kernel:** Linux 7.0.0-14-generic (`CONFIG_STRICT_DEVMEM=y`)  
**Date:** 2026-04-25

---

## Problem Statement

Standard userspace SPI flash write paths are blocked on this machine:

| Path | Blocker |
|---|---|
| `flashrom --programmer internal` | `SpiAccessMacRomEn` flag rejection |
| `/dev/mem` mmap of `0xFEC10000` | `CONFIG_STRICT_DEVMEM=y` — MMIO regions blocked |
| `/dev/mem` mmap of `0xFEC11000` | Same |
| FCH SPI execute-opcode FIFO (old path) | SMM handler intercepts at runtime; WREN never sticks |
| ROM shadow `0xFF000000` | Read-only; writes silently discarded |

---

## Solution — kernetix_km.ko Physical Memory mmap

The [Platbox](https://github.com/PlatboxProject/Platbox) security toolkit includes `kernetix_km.ko`, a Linux kernel driver that implements a custom `mmap` handler exposing arbitrary physical memory to userspace. This bypasses `STRICT_DEVMEM` entirely since it's not `/dev/mem`.

### Driver setup
```bash
# Build is already done at:
/home/kenny/Platbox/PlatboxDrv/linux/driver/kernetix_km.ko

# Load
sudo insmod /home/kenny/Platbox/PlatboxDrv/linux/driver/kernetix_km.ko

# Verify
ls /dev/KernetixDriver0     # should exist
lsmod | grep kernetix_km    # should show loaded
```

### Mapping physical memory
```python
import os, mmap

kern_fd = os.open('/dev/KernetixDriver0', os.O_RDWR)

# Map FCH SPI MMIO (Renoir new controller at 0xFEC11000)
spi_map = mmap.mmap(
    kern_fd, 0x1000,
    mmap.MAP_SHARED,
    mmap.PROT_READ | mmap.PROT_WRITE,
    0,               # offset = physical address
    0xFEC11000       # FCH SPI base
)
```

The driver's `mmap` handler calls `ioremap()` / `remap_pfn_range()` in the kernel, so all reads and writes hit the actual MMIO registers.

---

## AMD FCH SPI Controller — Renoir Register Map

**Base address:** `0xFEC11000` (new chipset; old = `0xFEC10000`)  
**Flash chip:** GigaDevice GD25Q128 (`JEDEC 0xC8 0x60 0x18`), 16MB, 24-bit addressing

```
Offset  Size  Name          Description
------  ----  ----------    -------------------------------------------
0x00    4     SPI_Cntrl0    Control / mode / busy flags
0x04    4     RestrictedCmd Opcodes blocked by BIOS policy (check for 0x06)
0x08    4     RestrictedCmd2
0x0C    4     SPI_Cntrl1    FIFO pointer, parameters
0x14    4     CmdValue1     WREN/WRDI/RDID/RDSR opcode slots
0x18    4     CmdValue2     READ/FREAD/PageWr/ByteWr opcode slots
0x1D    1     Alt_SPI_CS    SpiProtectLock, SpiProtectEn0/1
0x45    1     CmdCode       Opcode to execute
0x47    1     CmdTrig       Write 0xFF to trigger; poll bit7=0 for done
0x48    1     TxByteCnt     Bytes to transmit (addr + data)
0x4B    1     RxByteCnt     Bytes to receive
0x4C    4     SpiStatus     bit31=SpiBusy, FifoWrPtr, FifoRdPtr
0x80    1     SPI_regx80    Addr byte[2] out / result byte 0 in
0x81    1     SPI_regx81    Addr byte[1] out / result byte 1 in
0x82    1     SPI_regx82    Addr byte[0] out / result byte 2 in
0x83+   64    FIFO          Data bytes (read results / write data)
```

---

## SPI Operation Recipes (Python, 24-bit addr mode)

```python
import struct, time

def rd8(off):   spi_map.seek(off); return struct.unpack('B', spi_map.read(1))[0]
def wr8(off,v): spi_map.seek(off); spi_map.write(struct.pack('B', v))

def wait_done():
    for _ in range(500000):
        if not (rd8(0x47) & 0x80): break   # CmdTrig bit7 clear = done
    for _ in range(500000):
        spi_map.seek(0x4C)
        if not (struct.unpack('<I', spi_map.read(4))[0] >> 31): break  # SpiBusy

def exec_cmd():
    wr8(0x47, 0xFF)   # trigger
    wait_done()

def wren():
    """Write Enable (opcode 0x06)"""
    wr8(0x45, 0x06); wr8(0x4B, 0); wr8(0x48, 0); exec_cmd()

def rdsr():
    """Read Status Register 1"""
    wr8(0x45, 0x05); wr8(0x4B, 1); wr8(0x48, 0); exec_cmd()
    return rd8(0x80)   # WEL = bit1, BUSY = bit0

def wait_not_busy(ms=2000):
    for _ in range(ms):
        if not (rdsr() & 1): return True
        time.sleep(0.001)
    return False

def read_block(addr):
    """Read 64 bytes from flash at 24-bit address"""
    wr8(0x80, (addr >> 16) & 0xFF)
    wr8(0x81, (addr >>  8) & 0xFF)
    wr8(0x82,  addr        & 0xFF)
    wr8(0x45, 0x03)    # READ
    wr8(0x48, 3)       # 3 addr bytes tx
    wr8(0x4B, 64)      # 64 bytes rx
    exec_cmd()
    spi_map.seek(0x83)
    return bytearray(spi_map.read(64))

def erase_sector(addr):
    """4KB Sector Erase at 24-bit address (~300ms)"""
    wait_not_busy(); wren()
    wr8(0x80, (addr >> 16) & 0xFF)
    wr8(0x81, (addr >>  8) & 0xFF)
    wr8(0x82,  addr        & 0xFF)
    wr8(0x45, 0x20)    # SE 4KB
    wr8(0x48, 3); wr8(0x4B, 0); exec_cmd()
    for _ in range(500):
        time.sleep(0.001)
        if not (rdsr() & 1): break

def write_block(addr, data64):
    """Page Program 64 bytes at 24-bit address"""
    wait_not_busy(); wren()
    wr8(0x80, (addr >> 16) & 0xFF)
    wr8(0x81, (addr >>  8) & 0xFF)
    wr8(0x82,  addr        & 0xFF)
    spi_map.seek(0x83)
    spi_map.write(bytes(data64))   # write 64 data bytes into FIFO
    wr8(0x45, 0x02)        # PP (Page Program)
    wr8(0x48, 3 + 64)      # 3 addr + 64 data
    wr8(0x4B, 0); exec_cmd()
```

---

## APCB Token Write — Full Example

```python
TOKEN_OFF = 0x29D821   # CfgSMTControl = 0x01 (Enable SMT)
SECTOR    = 0x29D000   # 4KB sector containing token

# 1. Read sector (64 blocks of 64 bytes)
sector = bytearray()
for i in range(64):
    sector += read_block(SECTOR + i * 64)

# 2. Patch
tok = TOKEN_OFF - SECTOR   # = 0x821
print(f"Token was: 0x{sector[tok]:02X}")
sector[tok] = 0x01

# 3. Erase + rewrite
erase_sector(SECTOR)
for i in range(64):
    write_block(SECTOR + i * 64, sector[i*64:(i+1)*64])

# 4. Verify
verify = bytearray()
for i in range(64):
    verify += read_block(SECTOR + i * 64)
assert verify[tok] == 0x01, "Write failed!"
print(f"Verified: 0x{verify[tok]:02X}")
```

---

## Gotchas

### 1. Wrong SPI base address
Old FCH = `0xFEC10000`, new FCH (Renoir+) = `0xFEC11000`. Using the wrong base gives garbage register reads.

### 2. Wrong opcodes for 32-bit addr
The GD25Q128 on this board does **not** support 4-byte address opcodes (`0x12` PP4B, `0x13` READ4). Always use standard 24-bit opcodes (`0x02` PP, `0x03` READ, `0x20` SE).

### 3. STRICT_DEVMEM blocks /dev/mem
`CONFIG_STRICT_DEVMEM=y` on kernel 7.0.x means `/dev/mem` mmap of MMIO regions returns `MAP_FAILED` or silently zeroes. Always use the kernetix fd instead.

### 4. Patch both APCB copies
The flash contains a primary APCB and a mirror. Both must be patched:
- Primary: `0x29D821`
- Mirror:  `0x6E5821`

### 5. RestrictedCmd check
Before attempting writes, read `SPI_RestrictedCmd` (`0x04`) and `SPI_RestrictedCmd2` (`0x08`). If opcode `0x06` (WREN) appears in those registers, the BIOS has blocked it in hardware and writes will never work without SMM-level access.

On this machine both registers were `0x00000000` — no opcodes blocked.

---

## References
- [Platbox GitHub](https://github.com/PlatboxProject/Platbox)
- AMD FCH SPI Controller spec (Family 17h BKDG)
- APCB token table: see `APCB_ANALYSIS.md`
- GigaDevice GD25Q128 datasheet
