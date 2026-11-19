"""Adversarial checks for the ELF64 structural verifier (tools/verify_elf64.py).

Each negative case starts from a header that the verifier ACCEPTS (asserted by
``test_reference_image_is_accepted``) and corrupts exactly one field, so every
rejection is attributable to the property under test and must carry that
property's specific diagnostic. A blob that is rejected for an unrelated reason
(for example a wrong magic number) does not count as coverage.

This suite does not cover runtime ownership or LIR parsing; those live in the
Rust integration tests under crates/l/tests.
"""
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from verify_elf64 import verify_elf64  # noqa: E402

MAGIC = b"\x7fELF\x02\x01\x01"
VADDR = 0x400000
SIZE = 4099
ENTRY = VADDR + 4096


def reference_image() -> bytearray:
    """Smallest image shape the verifier accepts: one R+X PT_LOAD at offset 0."""
    data = bytearray(SIZE)
    data[:7] = MAGIC
    struct.pack_into("<HHI", data, 16, 2, 62, 1)  # ET_EXEC, x86-64, EV_CURRENT
    struct.pack_into("<QQQ", data, 24, ENTRY, 64, 0)  # entry, phoff, shoff
    struct.pack_into("<IHHH", data, 48, 0, 64, 56, 1)  # flags, ehsize, phentsize, phnum
    struct.pack_into(
        "<IIQQQQQQ", data, 64, 1, 5, 0, VADDR, VADDR, SIZE, SIZE, 4096
    )  # PT_LOAD, R+X, offset 0, vaddr, paddr, filesz, memsz, align
    data[4096:] = b"\x0f\x05\xc3"
    return data


class AdversarialQATests(unittest.TestCase):
    def assert_rejected(self, blob, diagnostic):
        with self.assertRaisesRegex(ValueError, diagnostic):
            verify_elf64(bytes(blob))

    def test_reference_image_is_accepted(self):
        # Positive control: without it every negative below could pass
        # vacuously (this file previously used b"\\x7f..." literals, so every
        # "negative" was rejected by the magic check alone).
        details = verify_elf64(bytes(reference_image()))
        self.assertEqual(details["entry"], ENTRY)
        self.assertEqual(details["code_offset"], 4096)
        self.assertEqual(details["segment_size"], SIZE)

    def test_invalid_magic(self):
        blob = reference_image()
        blob[1:4] = b"ELG"
        self.assert_rejected(blob, "not an ELF64 little-endian image")

    def test_escaped_magic_literal_is_not_elf(self):
        # Regression for the original suite: a backslash-escaped literal is
        # text, not the 0x7f byte.
        blob = reference_image()
        blob[:7] = b"\\x7fELF"
        self.assert_rejected(blob, "not an ELF64 little-endian image")

    def test_truncated_header(self):
        self.assert_rejected(reference_image()[:119], "not an ELF64 little-endian image")

    def test_nonzero_identification_padding(self):
        blob = reference_image()
        blob[9] = 1
        self.assert_rejected(blob, "unexpected ELF identification padding")

    def test_unsupported_machine(self):
        blob = reference_image()
        struct.pack_into("<H", blob, 18, 3)  # EM_386, not x86-64
        self.assert_rejected(blob, "unsupported ELF header")

    def test_shared_object_type_is_rejected(self):
        blob = reference_image()
        struct.pack_into("<H", blob, 16, 3)  # ET_DYN
        self.assert_rejected(blob, "unsupported ELF header")

    def test_section_header_table_is_rejected(self):
        blob = reference_image()
        struct.pack_into("<Q", blob, 40, 128)
        self.assert_rejected(blob, "program header out of bounds")

    def test_program_header_past_end_of_file(self):
        blob = reference_image()
        struct.pack_into("<Q", blob, 32, SIZE - 55)
        self.assert_rejected(blob, "program header out of bounds")

    def test_non_executable_segment(self):
        blob = reference_image()
        struct.pack_into("<I", blob, 68, 6)  # R+W, no X
        self.assert_rejected(blob, "expected an executable, readable PT_LOAD")

    def test_segment_larger_than_file(self):
        blob = reference_image()
        struct.pack_into("<Q", blob, 96, SIZE + 1)  # p_filesz
        self.assert_rejected(blob, "invalid segment extent")

    def test_misaligned_segment(self):
        blob = reference_image()
        struct.pack_into("<Q", blob, 112, 4097)  # p_align, not a power of two
        self.assert_rejected(blob, "invalid segment alignment")

    def test_entry_outside_loaded_segment(self):
        blob = reference_image()
        struct.pack_into("<Q", blob, 24, VADDR + SIZE)
        self.assert_rejected(blob, "entry point is outside the loaded file segment")


if __name__ == "__main__":
    unittest.main()
