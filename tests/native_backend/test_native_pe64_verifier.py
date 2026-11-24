"""Structure-only tests for the PE32+ verifier."""
from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from verify_pe64 import verify_pe64  # noqa: E402


def reference_pe() -> bytearray:
    """One-section AMD64 console PE32+ image with a raw-backed entry point."""
    pe_offset = 0x80
    optional_size = 240
    section_table = pe_offset + 4 + 20 + optional_size
    image = bytearray(0x400)
    image[:2] = b"MZ"
    struct.pack_into("<I", image, 0x3C, pe_offset)
    image[pe_offset : pe_offset + 4] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", image, pe_offset + 4,
                     0x8664, 1, 0, 0, 0, optional_size, 0x0022)
    opt = pe_offset + 24
    struct.pack_into("<H", image, opt, 0x20B)
    struct.pack_into("<II", image, opt + 16, 0x1000, 0x1000)
    struct.pack_into("<Q", image, opt + 24, 0x140000000)
    struct.pack_into("<II", image, opt + 32, 0x1000, 0x200)
    struct.pack_into("<II", image, opt + 56, 0x2000, 0x200)
    struct.pack_into("<HH", image, opt + 68, 3, 0x8160)
    struct.pack_into("<I", image, opt + 108, 16)
    section = section_table
    image[section : section + 8] = b".text\0\0\0"
    struct.pack_into("<IIII", image, section + 8, 3, 0x1000, 0x200, 0x200)
    struct.pack_into("<I", image, section + 36, 0x60000020)
    image[0x200:0x203] = b"\x31\xc0\xc3"
    return image


class NativePE64VerifierTests(unittest.TestCase):
    def test_valid_reference_image_reports_entry(self):
        details = verify_pe64(bytes(reference_pe()))
        self.assertEqual(details["entry_rva"], 0x1000)
        self.assertEqual(details["entry_file_offset"], 0x200)
        self.assertEqual(details["section_count"], 1)
        self.assertEqual(details["subsystem"], 3)

    def test_invalid_and_truncated_images_are_rejected(self):
        for data in (b"", b"hello world", b"MZ", bytes(reference_pe()[:0x100])):
            with self.subTest(data=data[:8]):
                with self.assertRaises(ValueError):
                    verify_pe64(data)

    def test_wrong_machine_and_non_pe32plus_are_rejected(self):
        image = reference_pe()
        struct.pack_into("<H", image, 0x84, 0x14C)
        with self.assertRaisesRegex(ValueError, "AMD64"):
            verify_pe64(bytes(image))
        image = reference_pe()
        struct.pack_into("<H", image, 0x98, 0x10B)
        with self.assertRaisesRegex(ValueError, r"PE32\+"):
            verify_pe64(bytes(image))

    def test_entry_must_be_inside_raw_backed_executable_code(self):
        image = reference_pe()
        struct.pack_into("<I", image, 0x98 + 16, 0x1200)
        with self.assertRaisesRegex(ValueError, "entry point"):
            verify_pe64(bytes(image))

    def test_section_raw_extent_and_directory_are_checked(self):
        image = reference_pe()
        struct.pack_into("<I", image, 0x188 + 20, 0x400)
        with self.assertRaisesRegex(ValueError, "out of bounds"):
            verify_pe64(bytes(image))
        image = reference_pe()
        struct.pack_into("<II", image, 0x98 + 112, 0x1FFF, 2)
        with self.assertRaisesRegex(ValueError, "data directory"):
            verify_pe64(bytes(image))


if __name__ == "__main__":
    unittest.main()

