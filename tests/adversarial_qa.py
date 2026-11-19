"""Adversarial smoke checks for the existing ELF64 structural verifier.

This suite intentionally does not claim to cover runtime ownership or LIR parsing.
Those require separate executable test harnesses and regression fixtures.
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from verify_elf64 import verify_elf64


class AdversarialQATests(unittest.TestCase):
    def assert_rejected(self, blob):
        with self.assertRaises(ValueError):
            verify_elf64(blob)

    def test_invalid_magic(self):
        self.assert_rejected(b"\\x00\\x00\\x00\\x00" + b"\\x00" * 120)

    def test_truncated_header(self):
        self.assert_rejected(b"\\x7fELF\\x02\\x01\\x01" + b"\\x00" * 10)

    def test_unsupported_machine(self):
        blob = bytearray(128)
        blob[:7] = b"\\x7fELF\\x02\\x01\\x01"
        blob[16:18] = (2).to_bytes(2, "little")
        blob[18:20] = (3).to_bytes(2, "little")  # i386, not x86_64
        blob[20:24] = (1).to_bytes(4, "little")
        self.assert_rejected(bytes(blob))


if __name__ == "__main__":
    unittest.main()
