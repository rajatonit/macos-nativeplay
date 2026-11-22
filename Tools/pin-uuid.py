#!/usr/bin/env python3
"""Overwrites the LC_UUID of a thin 64-bit Mach-O with a fixed value.

macOS's Local Network privacy identifies an app by its executable's UUID, and the linker
generates a new one on every build, so each rebuild silently loses the permission.
Pinning the UUID keeps the approval valid across rebuilds. Run before code signing.

Usage: pin-uuid.py <executable> <name-to-derive-uuid-from>
"""
import struct
import sys
import uuid

LC_UUID = 0x1B
MH_MAGIC_64 = 0xFEEDFACF

path, name = sys.argv[1], sys.argv[2]
fixed = uuid.uuid5(uuid.NAMESPACE_DNS, name).bytes

with open(path, "r+b") as f:
    header = f.read(32)
    magic, _, _, _, ncmds, _, _, _ = struct.unpack("<IiiIIIII", header)
    if magic != MH_MAGIC_64:
        sys.exit(f"{path}: not a thin 64-bit Mach-O")
    offset = 32
    for _ in range(ncmds):
        f.seek(offset)
        cmd, size = struct.unpack("<II", f.read(8))
        if cmd == LC_UUID:
            f.seek(offset + 8)
            f.write(fixed)
            print(f"pinned executable UUID to {uuid.UUID(bytes=fixed)}")
            break
        offset += size
    else:
        sys.exit(f"{path}: no LC_UUID found")
