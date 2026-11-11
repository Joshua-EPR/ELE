"""Structure-only checks for the ELF verifier and new intrinsic wiring.
These do not compile ELE sources; MSVC integration tests do that.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from verify_elf64 import verify_elf64  # noqa: E402


class NativeELFVerifierTests(unittest.TestCase):
    def test_invalid_and_truncated_are_rejected(self):
        for b in [b"", b"hello world", b"\x7fELF", b"\x7fELF\x02\x01\x01" + b"\x00" * 112]:
            with self.subTest(data=b[:7]):
                with self.assertRaises(ValueError):
                    verify_elf64(b)

    def test_valid_reference_segment(self):
        import struct
        data = bytearray(4099)
        data[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHI", data, 16, 2, 62, 1)
        struct.pack_into("<QQQ", data, 24, 0x401000, 64, 0)
        struct.pack_into("<IHHH", data, 48, 0, 64, 56, 1)
        struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0x400000, 0x400000, len(data), len(data), 4096)
        data[4096:] = b"\x0f\x05\xc3"
        details = verify_elf64(bytes(data))
        self.assertEqual(details["code_offset"], 4096)

    def test_invalid_segment_range_rejected(self):
        import struct
        data = bytearray(4099)
        data[:7] = b"\x7fELF\x02\x01\x01"
        struct.pack_into("<HHI", data, 16, 2, 62, 1)
        struct.pack_into("<QQQ", data, 24, 0x401000, 64, 0)
        struct.pack_into("<IHHH", data, 48, 0, 64, 56, 1)
        struct.pack_into("<IIQQQQQQ", data, 64, 1, 5, 0, 0x400000, 0x400000, 5000, 5000, 4096)
        with self.assertRaises(ValueError):
            verify_elf64(bytes(data))

    def test_binary_output_platform_contract_wired(self):
        files = (
            "crates/l/src/lir.rs",
            "crates/l/src/sema.rs",
            "crates/l/src/cfg.rs",
            "crates/l/src/native/platform.rs",
            "crates/l/src/native/platform_object.rs",
            "crates/l/src/backend.rs",
            "crates/l/src/lir_protocol.rs",
            "compiler-l/src/native_lir_demo.l",
        )
        for path in files:
            with self.subTest(file=path):
                self.assertIn("writebytes" if path.endswith("lir_protocol.rs") else ("writeBytes" if path.endswith(".l") or path.endswith("sema.rs") or path.endswith("lir.rs") or path.endswith("cfg.rs") else "write_bytes"),
                              (ROOT / path).read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
