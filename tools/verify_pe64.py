#!/usr/bin/env python3
"""Read-only structural verifier for x86-64 PE32+ executable images.

This checks the image format only. It does not generate or execute code.
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path


IMAGE_FILE_MACHINE_AMD64 = 0x8664
IMAGE_FILE_EXECUTABLE_IMAGE = 0x0002
IMAGE_FILE_DLL = 0x2000
IMAGE_NT_OPTIONAL_HDR64_MAGIC = 0x20B
IMAGE_SCN_MEM_EXECUTE = 0x20000000
IMAGE_SCN_MEM_READ = 0x40000000
IMAGE_SCN_MEM_WRITE = 0x80000000
IMAGE_SCN_CNT_CODE = 0x00000020
IMAGE_NUMBEROF_DIRECTORY_ENTRIES = 16


def _range_ok(offset: int, size: int, limit: int) -> bool:
    return offset >= 0 and size >= 0 and offset <= limit and size <= limit - offset


def _power_of_two(value: int) -> bool:
    return value > 0 and (value & (value - 1)) == 0


def verify_pe64(blob: bytes) -> dict[str, int]:
    """Validate a PE32+ AMD64 console executable and return entry metadata."""
    if len(blob) < 64 or blob[:2] != b"MZ":
        raise ValueError("not a PE image with a DOS header")
    pe_offset = struct.unpack_from("<I", blob, 0x3C)[0]
    if pe_offset < 64 or not _range_ok(pe_offset, 24, len(blob)):
        raise ValueError("PE header is out of bounds")
    if blob[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise ValueError("missing PE signature")

    coff = pe_offset + 4
    machine, section_count, _timestamp, _symptr, _symcount, optional_size, characteristics = (
        struct.unpack_from("<HHIIIHH", blob, coff)
    )
    if machine != IMAGE_FILE_MACHINE_AMD64:
        raise ValueError("image is not AMD64")
    if not 1 <= section_count <= 96:
        raise ValueError("invalid section count")
    if not (characteristics & IMAGE_FILE_EXECUTABLE_IMAGE) or characteristics & IMAGE_FILE_DLL:
        raise ValueError("expected an executable image, not a DLL")

    optional = coff + 20
    if optional_size < 112 or not _range_ok(optional, optional_size, len(blob)):
        raise ValueError("optional header is truncated")
    magic = struct.unpack_from("<H", blob, optional)[0]
    if magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC:
        raise ValueError("optional header is not PE32+")
    entry_rva, _base_of_code = struct.unpack_from("<II", blob, optional + 16)
    image_base = struct.unpack_from("<Q", blob, optional + 24)[0]
    section_alignment, file_alignment = struct.unpack_from("<II", blob, optional + 32)
    size_of_image, size_of_headers = struct.unpack_from("<II", blob, optional + 56)
    subsystem = struct.unpack_from("<H", blob, optional + 68)[0]
    dll_characteristics = struct.unpack_from("<H", blob, optional + 70)[0]
    directory_count = struct.unpack_from("<I", blob, optional + 108)[0]
    if directory_count > IMAGE_NUMBEROF_DIRECTORY_ENTRIES:
        raise ValueError("too many data directories")
    if optional_size < 112 + directory_count * 8:
        raise ValueError("data directory table exceeds optional header")
    if section_alignment < file_alignment or not _power_of_two(section_alignment) or not _power_of_two(file_alignment):
        raise ValueError("invalid section or file alignment")
    if file_alignment < 512 or file_alignment > 65536:
        raise ValueError("file alignment is outside the PE range")
    if section_alignment < 4096 and section_alignment != file_alignment:
        raise ValueError("low-alignment image has different file and section alignments")
    if size_of_headers == 0 or size_of_headers % file_alignment or size_of_headers > len(blob):
        raise ValueError("invalid header extent")
    if size_of_image == 0 or size_of_image % section_alignment:
        raise ValueError("invalid image size")
    if image_base == 0 or image_base % 65536:
        raise ValueError("invalid image base")

    section_table = optional + optional_size
    table_size = section_count * 40
    if not _range_ok(section_table, table_size, len(blob)):
        raise ValueError("section table is out of bounds")
    if section_table + table_size > size_of_headers:
        raise ValueError("section table exceeds SizeOfHeaders")

    sections: list[tuple[int, int, int, int, int, int]] = []
    for index in range(section_count):
        offset = section_table + index * 40
        virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from("<IIII", blob, offset + 8)
        section_chars = struct.unpack_from("<I", blob, offset + 36)[0]
        if virtual_address == 0 or virtual_address % section_alignment:
            raise ValueError(f"section {index} has an invalid RVA")
        if raw_size:
            if raw_offset < size_of_headers or raw_offset % file_alignment or raw_size % file_alignment:
                raise ValueError(f"section {index} has invalid raw alignment")
            if not _range_ok(raw_offset, raw_size, len(blob)):
                raise ValueError(f"section {index} raw data is out of bounds")
        elif raw_offset != 0:
            raise ValueError(f"section {index} has an offset without raw data")
        extent = max(virtual_size, raw_size)
        if extent == 0 or virtual_address + extent > size_of_image:
            raise ValueError(f"section {index} exceeds SizeOfImage")
        sections.append((virtual_address, extent, raw_offset, raw_size, section_chars, index))

    for i, left in enumerate(sections):
        for right in sections[i + 1 :]:
            if left[0] < right[0] + right[1] and right[0] < left[0] + left[1]:
                raise ValueError("virtual sections overlap")
            if left[3] and right[3] and left[2] < right[2] + right[3] and right[2] < left[2] + left[3]:
                raise ValueError("raw section data overlaps")

    entry = None
    for rva, extent, raw_offset, raw_size, chars, index in sections:
        if rva <= entry_rva < rva + min(extent, raw_size):
            if not (chars & IMAGE_SCN_MEM_EXECUTE) or not (chars & IMAGE_SCN_CNT_CODE):
                raise ValueError("entry point is not in executable code")
            entry = (raw_offset + entry_rva - rva, index)
            break
    if entry is None:
        raise ValueError("entry point is outside raw-backed sections")

    directories = optional + 112
    for index in range(directory_count):
        rva, size = struct.unpack_from("<II", blob, directories + index * 8)
        if (rva == 0) != (size == 0):
            raise ValueError(f"data directory {index} has only one of RVA and size")
        if not size:
            continue
        if index == 4:  # IMAGE_DIRECTORY_ENTRY_SECURITY uses a file offset.
            if not _range_ok(rva, size, len(blob)):
                raise ValueError("certificate table is out of bounds")
            continue
        mapped = False
        for sec_rva, _extent, raw_offset, raw_size, _chars, _sec_index in sections:
            if sec_rva <= rva and size <= raw_size - (rva - sec_rva):
                mapped = True
                break
        if not mapped:
            raise ValueError(f"data directory {index} is outside raw-backed section data")

    return {
        "entry_rva": entry_rva,
        "entry_file_offset": entry[0],
        "entry_section": entry[1],
        "image_base": image_base,
        "section_count": section_count,
        "size_of_image": size_of_image,
        "subsystem": subsystem,
        "dll_characteristics": dll_characteristics,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    details = verify_pe64(args.binary.read_bytes())
    print(
        f"PE32+ válido: entry RVA=0x{details['entry_rva']:x}, "
        f"sections={details['section_count']}, size={args.binary.stat().st_size}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

