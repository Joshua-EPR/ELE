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
    if (etype, machine, version, flags, ehsize, phsize, phnum) != (2, 62, 1, 0, 64, 56, 1):
        raise ValueError("unsupported ELF header (expect x86-64 ET_EXEC and one PT_LOAD)")
    if shoff != 0 or phoff < 64 or phoff > len(blob) - 56:
        raise ValueError("program header out of bounds")
    ptype, pflags, poff, vaddr, paddr, filesz, memsz, align = struct.unpack_from(
        "<IIQQQQQQ", blob, phoff
    )
    if ptype != 1 or (pflags & 5) != 5 or (pflags & ~7) != 0:
        raise ValueError("expected an executable, readable PT_LOAD")
    if poff > len(blob) or filesz > len(blob) - poff or memsz < filesz:
        raise ValueError("invalid segment extent")
    if align < 4096 or align & (align - 1) or (vaddr - poff) % align:
        raise ValueError("invalid segment alignment")
    if not (vaddr <= entry < vaddr + filesz):
        raise ValueError("entry point is outside the loaded file segment")
    return {"entry": entry, "code_offset": poff + entry - vaddr, "segment_size": filesz}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--run", action="store_true", help="execute on Linux x86-64 (trusted only)")
    parser.add_argument("--expected-exit", type=int, default=42)
    args = parser.parse_args()
    data = args.binary.read_bytes()
    details = verify_elf64(data)
    print(f"ELF64 válido: entry=0x{details['entry']:x}, size={len(data)}, "
          f"entry_file_offset={details['code_offset']}")
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
