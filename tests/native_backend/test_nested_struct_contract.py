"""Protocol/fixture checks ONLY; the real native backend is exercised by
crates/l/tests/native_nested_struct_l.rs using Stage0.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def e(name):
    raw = name.encode("ascii")
    return str(len(raw)) + ":" + ",".join(str(b) for b in raw)

class NestedStructFixtureContract(unittest.TestCase):
    def test_declarations_and_copy_instruction_sequence(self):
        fixture = (ROOT / "examples/native_cfg_nested_copy.lir").read_text().splitlines()
        self.assertEqual(fixture[0], "ELE-LIR 1")
        self.assertEqual(fixture[1], "module structs 2 funcs 1 main f0")
        self.assertEqual(fixture[2], f"struct s0 {e('Inner')} fields 2")
        self.assertEqual(fixture[5], f"struct s1 {e('Outer')} fields 2")
        self.assertEqual(fixture[6], f"field {e('inner')} s0")
        self.assertEqual(fixture[7], f"field {e('extra')} i")
        self.assertIn("i struct v2 s1 2 v0 ci20", fixture)
        self.assertIn("i store p2.0 v1", fixture)
        self.assertIn("i use v3 v2", fixture)
        self.assertIn("var v4 val i", fixture)
        self.assertIn("i read v4 p3.0.0", fixture)
        self.assertIn("i binary v6 add v4 v5", fixture)
        self.assertIn("i read v7 p3.0.1", fixture)
        self.assertIn("t branch v7 1 2", fixture)
        self.assertEqual(fixture[-3:], ["t return ci0", "endfunc", "end"])
        idx=fixture.index("block 0 9")
        self.assertEqual(fixture[idx+10], "t branch v7 1 2")

    def test_false_branch_fixture_differs_only_at_bool_field(self):
        ok=(ROOT / "examples/native_cfg_nested_copy.lir").read_text()
        inactive=(ROOT / "examples/native_cfg_nested_inactive.lir").read_text()
        self.assertEqual(inactive,ok.replace("i struct v1 s0 2 ci22 cb1", "i struct v1 s0 2 ci22 cb0"))

    def test_negative_fixtures_are_not_identical_to_valid(self):
        ok=(ROOT / "examples/native_cfg_nested_copy.lir").read_text()
        for name in (
            "native_cfg_nested_bad_forward.lir",
            "native_cfg_nested_bad_store_type.lir",
            "native_cfg_nested_bad_uninit.lir",
            "native_cfg_nested_bad_owner.lir",
            "native_cfg_nested_bad_read_struct.lir",
            "native_cfg_nested_use_after_move.lir",
            "native_cfg_nested_double_move.lir",
        ):
            with self.subTest(name=name):
                bad=(ROOT / "examples" / name).read_text()
                self.assertNotEqual(ok,bad)
                self.assertIn("ELE-LIR 1\n",bad)

    def test_move_across_branch_join_has_a_struct_use_on_only_one_path(self):
        lines=(ROOT / "examples/native_cfg_nested_move_join.lir").read_text().splitlines()
        self.assertIn("i use v1 v0",lines)
        self.assertIn("t branch cb1 1 2",lines)
        self.assertIn("t jump 3",lines)
        self.assertIn("i read v2 p0.0",lines)

    def test_codegen_recursive_copy_has_byte_and_word_cases(self):
        code=(ROOT / "compiler-l/src/codegen/native_cfg_emit.l").read_text()
        self.assertIn("fn cfgCopyValue(", code)
        self.assertIn("x64LoadMem64(&mut code, 0, 5, src_disp)", code)
        self.assertIn("x64LoadMem8(&mut code, 0, 5, src_disp)", code)
        self.assertIn("cfgCopyValue(&mut code, p, member.ty,",code)
        self.assertIn("cfgCopyValue(&mut code, p, ty, cfgVarBase",code)
        verifier=(ROOT / "compiler-l/src/codegen/native_cfg_verify.l").read_text()
        self.assertIn("fn cfgMoves(",verifier)
        self.assertIn("fn cfgTakeOperand(",verifier)
        self.assertIn("live[op.value] = false",verifier)

if __name__ == "__main__":
    unittest.main()
