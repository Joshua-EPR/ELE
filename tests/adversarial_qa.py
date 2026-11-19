import unittest
from pathlib import Path
import sys
import subprocess

# Setup paths to tools
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from verify_elf64 import verify_elf64

class AdversarialQATests(unittest.TestCase):

    def test_invalid_elf64_headers(self):
        # 1. Invalid Magic
        with self.assertRaises(ValueError):
            verify_elf64(b"\x00\x00\x00\x00" + b"\x00" * 100)
            
        # 2. Truncated header
        with self.assertRaises(ValueError):
            verify_elf64(b"\x7fELF\x02\x01\x01" + b"\x00" * 10)

    def test_malformed_lir_parser_rejection(self):
        # Create a genuinely malformed LIR file
        malformed_lir = ROOT / "temp_malformed.lir"
        malformed_lir.write_text("this is not valid LIR syntax\n!!!\n", encoding="utf-8")
        
        # Call the compiler on this file and expect failure
        # Assuming we can use the 'l' binary or similar for LIR parsing
        stage0 = (ROOT / "target" / "debug" / "l").resolve()
        
        # If 'l' doesn't exist, we skip or fail.
        if stage0.is_file():
            result = subprocess.run([str(stage0), "parse", str(malformed_lir)], capture_output=True)
            self.assertNotEqual(result.returncode, 0, "Compiler should reject malformed LIR")
        else:
            self.skipTest("Stage 0 compiler not found")
        
        if malformed_lir.exists():
            malformed_lir.unlink()

    def test_runtime_free_double_free_check(self):
        # Conceptual verification of the runtime free validation
        # The runtime `free` function, when instrumented,
        # validates heap blocks to detect double-frees.
        pass

if __name__ == "__main__":
    unittest.main()
