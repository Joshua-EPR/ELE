"""Text-contract checks only; they do not compile .l or execute ELF."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
FILES = [
    "native_cfg_enum_payload_int.lir", "native_cfg_enum_payload_bool.lir",
    "native_cfg_enum_payload_branch.lir",
    "native_cfg_option_some.lir", "native_cfg_option_none.lir",
    "native_cfg_result_ok.lir", "native_cfg_result_err.lir",
    "native_cfg_enum_payload_wrong_active.lir", "native_cfg_enum_payload_wrong_enum.lir",
    "native_cfg_enum_payload_wrong_variant.lir", "native_cfg_enum_payload_unit_variant.lir",
    "native_cfg_enum_payload_type_mismatch.lir", "native_cfg_enum_payload_uninitialized.lir",
    "native_cfg_enum_payload_use_after_move.lir",
]

class PayloadContractTests(unittest.TestCase):
    def test_new_fixtures_have_one_payload_instruction_and_correct_counts(self):
        for filename in FILES:
            with self.subTest(filename=filename):
                text = (ROOT / "examples" / filename).read_text(encoding="utf-8")
                lines = text.splitlines()
                self.assertEqual(lines[0], "ELE-LIR 1")
                self.assertTrue(lines[-2:] == ["endfunc", "end"])
                expected_payloads = 2 if "result_" in filename else 1
                self.assertEqual(sum(line.startswith("i payload ") for line in lines), expected_payloads)
                for i, line in enumerate(lines):
                    if line.startswith("block "):
                        count = int(line.split()[2])
                        self.assertTrue(all(l.startswith('i ') for l in lines[i+1:i+1+count]))
                        self.assertTrue(lines[i+1+count].startswith('t '))

    def test_backend_checks_tag_before_reading_payload(self):
        ir = (ROOT/'compiler-l/src/codegen/native_cfg_inst.l').read_text()
        emit = (ROOT/'compiler-l/src/codegen/native_cfg_emit.l').read_text()
        verify = (ROOT/'compiler-l/src/codegen/native_cfg_verify.l').read_text()
        self.assertIn('nativeEquals(source, &kind, "payload")', ir)
        self.assertIn('if inst.kind == 9', ir)
        self.assertIn('inst.kind == 9', verify)
        payload_part = emit[emit.index('} else if inst.kind == 9 {'):]
        self.assertLess(payload_part.index('x64CmpReg'), payload_part.index('x64LoadMem8'))
        self.assertLess(payload_part.index('bad_variant_at.push'), payload_part.index('x64LoadMem64(&mut code, 0, 5, owner + 8)'))
        self.assertIn('x64PatchRelative(&mut code, bad_variant_at[i], bad_variant_handler)', emit)

if __name__ == '__main__': unittest.main()
