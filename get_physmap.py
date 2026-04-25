#!/usr/bin/env python3
# Read page_offset_base (physmap base) from /proc/kcore.
# Requires root. Used by run_entrysign_poc.sh.
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
if not addr:
    print("NOT_FOUND")
    exit(1)
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
print("SEG_NOT_FOUND")
exit(1)
