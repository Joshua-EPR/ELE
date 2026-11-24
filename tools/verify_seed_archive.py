#!/usr/bin/env python3
"""Verify and extract one versioned ELE bootstrap seed."""
from __future__ import annotations

import argparse
import hashlib
import json
import struct
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SEEDS = ROOT / "scripts" / "bootstrap" / "seeds"
MANIFEST_PATH = SEEDS / "manifest.json"


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def verify_image(data: bytes, target: str) -> None:
    if target == "elf":
        if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01":
            raise ValueError("seed is not a little-endian ELF64 image")
        if data[7:16] != b"\x00" * 9:
            raise ValueError("ELF seed has invalid identification padding")
        elf_type, machine, version = struct.unpack_from("<HHI", data, 16)
        if elf_type not in (2, 3) or machine != 62 or version != 1:
            raise ValueError("ELF seed must be an x86-64 ET_EXEC or ET_DYN image")
        return

    if target == "pe":
        if len(data) < 64 or data[:2] != b"MZ":
            raise ValueError("seed is missing the DOS MZ header")
        pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
        if pe_offset < 64 or pe_offset > len(data) - 24 or data[pe_offset : pe_offset + 4] != b"PE\0\0":
            raise ValueError("seed is missing a bounded PE signature")
        machine, section_count = struct.unpack_from("<HH", data, pe_offset + 4)
        optional_size = struct.unpack_from("<H", data, pe_offset + 20)[0]
        optional = pe_offset + 24
        if machine != 0x8664 or not 1 <= section_count <= 96:
            raise ValueError("PE seed must be AMD64 with a valid section count")
        if optional_size < 112 or optional > len(data) - optional_size:
            raise ValueError("PE optional header is truncated")
        if struct.unpack_from("<H", data, optional)[0] != 0x20B:
            raise ValueError("PE seed is not PE32+")
        return
    raise ValueError(f"unknown target {target!r}")


def verify_seed_archive(
    archive_path: Path,
    target: str,
    manifest: dict | None = None,
) -> bytes:
    manifest = manifest or json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    try:
        record = manifest["targets"][target]
    except (KeyError, TypeError) as exc:
        raise ValueError(f"manifest has no seed for target {target!r}") from exc

    archive = archive_path.read_bytes()
    if _sha256(archive) != record["archive_sha256"]:
        raise ValueError("seed archive SHA-256 does not match the pinned manifest")
    try:
        with zipfile.ZipFile(archive_path) as bundle:
            expected = {record["seed_file"], record["seed_file"] + ".sha256"}
            if set(bundle.namelist()) != expected:
                raise ValueError("seed archive contains unexpected or missing members")
            seed = bundle.read(record["seed_file"])
            checksum = bundle.read(record["seed_file"] + ".sha256").decode("ascii").strip()
    except (OSError, zipfile.BadZipFile, UnicodeDecodeError, RuntimeError) as exc:
        raise ValueError(f"cannot read seed archive: {exc}") from exc

    if len(seed) != record["seed_size"]:
        raise ValueError("seed byte length does not match the pinned manifest")
    if _sha256(seed) != record["seed_sha256"]:
        raise ValueError("seed SHA-256 does not match the pinned manifest")
    checksum_fields = checksum.split()
    if not checksum_fields or checksum_fields[0].lower() != record["seed_sha256"]:
        raise ValueError("seed archive's checksum file does not match the pinned manifest")
    verify_image(seed, target)
    return seed


def extract_seed(target: str, output: Path, archive_path: Path | None = None) -> Path:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    record = manifest["targets"][target]
    archive_path = archive_path or SEEDS / record["archive"]
    if output.exists():
        raise FileExistsError(f"refusing to overwrite seed output {output}")
    seed = verify_seed_archive(archive_path, target, manifest)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(seed)
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=("elf", "pe"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = extract_seed(args.target, args.output)
    except (OSError, ValueError, KeyError) as exc:
        parser.error(str(exc))
    record = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))["targets"][args.target]
    print(f"verified {record['format']} {record['architecture']} seed: {result}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
