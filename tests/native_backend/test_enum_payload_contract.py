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
        self.assertIn('nativeEquals(source, view kind, "payload")', ir)
        self.assertIn('when inst.kind == 9', ir)
        self.assertIn('inst.kind == 9', verify)
        # Scope the contract to the payload-emission branch: the place may
        # now be a local slot OR a reference parameter (at.base).
        payload_part = emit.split('} otherwise when inst.kind == 9 {', 1)[1].split('} otherwise when inst.kind == 16 {', 1)[0]
        tag_read = 'x64LoadMem64(edit code, 0, at.base, owner)'
        compare = 'x64CmpReg(edit code, 0, 1)'
        guard = 'fix.bad_variant_at@push(x64ConditionalPlaceholder(edit code, false))'
        self.assertIn(tag_read, payload_part)
        self.assertIn(compare, payload_part)
        self.assertIn(guard, payload_part)
        self.assertLess(payload_part.index(tag_read), payload_part.index(compare))
        self.assertLess(payload_part.index(compare), payload_part.index(guard))
        # Both Bool and Int payload reads must happen AFTER the checked tag.
        for read in (
            'x64LoadMem8(edit code, 0, at.base, owner + 8)',
            'x64LoadMem64(edit code, 0, at.base, owner + 8)',
        ):
            with self.subTest(read=read):
                self.assertIn(read, payload_part)
                self.assertLess(payload_part.index(guard), payload_part.index(read))
        self.assertIn('x64PatchRelative(edit code, fix.bad_variant_at[i], bad_variant_handler)', emit)

if __name__ == '__main__': unittest.main()
