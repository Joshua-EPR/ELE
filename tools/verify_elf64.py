#!/usr/bin/env python3
"""Read-only ELF64 structural verifier for independently generated artifacts.

This tool never generates code. An optional --run executes a user-supplied
ELF on Linux x86-64; do not use that option on untrusted binaries.
"""
from __future__ import annotations

import argparse
import os
import platform
import struct
import subprocess
from pathlib import Path


def verify_elf64(blob: bytes) -> dict[str, int]:
    if len(blob) < 120 or blob[:7] != b"\x7fELF\x02\x01\x01":
        raise ValueError("not an ELF64 little-endian image")
    if blob[7:16] != b"\x00" * 9:
        raise ValueError("unexpected ELF identification padding")
    etype, machine, version = struct.unpack_from("<HHI", blob, 16)
    entry, phoff, shoff = struct.unpack_from("<QQQ", blob, 24)
    flags, ehsize, phsize, phnum = struct.unpack_from("<IHHH", blob, 48)
    if (etype, machine, version, flags, ehsize, phsize) != (2, 62, 1, 0, 64, 56):
        raise ValueError("unsupported ELF header (expect x86-64 ET_EXEC)")
    if phnum not in (1, 2):
        raise ValueError("expected one RX load segment and an optional RW data segment")
    ph_table_size = phnum * phsize
    if shoff != 0 or phoff < 64 or phoff > len(blob) - ph_table_size:
        raise ValueError("program header out of bounds")
    segments: list[tuple[int, int, int, int, int, int, int]] = []
    for i in range(phnum):
        ptype, pflags, poff, vaddr, paddr, filesz, memsz, align = struct.unpack_from(
            "<IIQQQQQQ", blob, phoff + i * phsize
        )
        expected_flags = 5 if i == 0 else 6
        if ptype != 1 or pflags != expected_flags:
            raise ValueError("expected RX code and optional RW, non-executable data PT_LOAD")
        if filesz == 0 or poff > len(blob) or filesz > len(blob) - poff or memsz != filesz:
            raise ValueError("invalid segment extent")
        if vaddr < poff or vaddr > (1 << 64) - memsz:
            raise ValueError("invalid virtual segment extent")
        if align < 4096 or align & (align - 1) or (vaddr - poff) % align:
            raise ValueError("invalid segment alignment")
        if paddr != vaddr:
            raise ValueError("unexpected physical address")
        segments.append((pflags, poff, vaddr, filesz, memsz, align, ptype))
    pflags, poff, vaddr, filesz, memsz, align, _ = segments[0]
    if not (vaddr <= entry < vaddr + filesz):
        raise ValueError("entry point is outside the loaded file segment")
    if phnum == 2:
        _, data_off, data_vaddr, data_size, _, data_align, _ = segments[1]
        code_file_end = poff + filesz
        code_mem_end = vaddr + memsz
        if data_off < code_file_end or data_vaddr < code_mem_end:
            raise ValueError("load segments overlap or are out of order")
        if data_align != align or data_vaddr - data_off != vaddr - poff:
            raise ValueError("load segments do not share the image mapping")
        if data_off % data_align or data_size % data_align:
            raise ValueError("RW data segment is not page-aligned")
    else:
        data_off = 0
        data_size = 0
    return {
        "entry": entry,
        "code_offset": poff + entry - vaddr,
        "segment_size": filesz,
        "segment_count": phnum,
        "data_offset": data_off,
        "data_size": data_size,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--run", action="store_true", help="execute on Linux x86-64 (trusted only)")
    parser.add_argument("--expected-exit", type=int, default=42)
    args = parser.parse_args()
    data = args.binary.read_bytes()
    details = verify_elf64(data)
    print(f"ELF64 válido: entry=0x{details['entry']:x}, size={len(data)}, "
          f"entry_file_offset={details['code_offset']}, "
          f"load_segments={details['segment_count']}, rw_data={details['data_size']}")
    if args.run:
        if platform.system() != "Linux" or platform.machine().lower() not in ("x86_64", "amd64"):
            parser.error("--run requires Linux x86-64")
        args.binary.chmod(args.binary.stat().st_mode | 0o100)
        result = subprocess.run([str(args.binary.resolve())], check=False, timeout=10)
        print(f"exit code: {result.returncode}")
        return 0 if result.returncode == args.expected_exit else 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
