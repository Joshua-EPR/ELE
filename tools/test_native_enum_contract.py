"""Fixture-format smoke tests (NOT code generation or Stage 0 execution)."""
from __future__ import annotations
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIR = ROOT / 'examples'
GOOD = ['native_cfg_enum_unit.lir', 'native_cfg_enum_positive.lir',
        'native_cfg_enum_bool.lir']
BAD = ['native_cfg_enum_wrong_payload.lir', 'native_cfg_enum_wrong_variant.lir',
       'native_cfg_enum_wrong_arity.lir', 'native_cfg_enum_use_after_move.lir',
       'native_cfg_enum_uninitialized_disc.lir', 'native_cfg_enum_unknown_type.lir',
       'native_cfg_enum_bad_owned_payload.lir', 'native_cfg_enum_move_join.lir']

def decode_name(token: str) -> str:
    length, values = token.split(':', 1)
    octets = bytes(int(n) for n in values.split(','))
    assert len(octets) == int(length)
    return octets.decode('utf-8')

class NativeEnumFixtureContracts(unittest.TestCase):
    def test_fixture_files_are_present_and_use_versioned_protocol(self):
        for name in GOOD + BAD:
            with self.subTest(name=name):
                content = (DIR / name).read_text(encoding='utf-8')
                self.assertTrue(content.startswith('ELE-LIR 1\nmodule structs 0 enums 1 funcs 1 main f0\n'))
                self.assertTrue(content.endswith('\nendfunc\nend\n'))
                if 'uninitialized_disc' not in name:
                    self.assertIn('i variant ', content)
                self.assertIn('i disc ', content)

    def test_positive_fixtures_have_consistent_headers_and_instruction_counts(self):
        for name in GOOD:
            with self.subTest(name=name):
                lines = (DIR / name).read_text().splitlines()
                enum_line = lines[2].split()
                self.assertEqual(enum_line[0], 'enum')
                decode_name(enum_line[2])
                count = int(enum_line[4]); self.assertGreaterEqual(count, 2)
                for i in range(3, 3 + count):
                    row = lines[i].split()
                    self.assertEqual(row[0], 'variant')
                    decode_name(row[1]); self.assertEqual(row[2], 'types')
                    self.assertEqual(len(row[4:]), int(row[3]))
                blocks = [idx for idx, row in enumerate(lines) if row.startswith('block ')]
                for at in blocks:
                    n = int(lines[at].split()[2])
                    self.assertEqual(sum(lines[at + j + 1].startswith('i ') for j in range(n)), n)
                    self.assertTrue(lines[at+n+1].startswith('t '))

    def test_enum_ops_are_handled_in_real_backend_source(self):
        ir = (ROOT/'compiler-l/src/codegen/native_cfg_ir.l').read_text()
        types = (ROOT/'compiler-l/src/codegen/native_cfg_types.l').read_text()
        inst = (ROOT/'compiler-l/src/codegen/native_cfg_inst.l').read_text()
        emit = (ROOT/'compiler-l/src/codegen/native_cfg_emit.l').read_text()
        verify = (ROOT/'compiler-l/src/codegen/native_cfg_verify.l').read_text()
        self.assertIn('cfgReadEnum(&mut p, source, &mut r, i)', ir)
        self.assertIn('pub fn cfgReadEnum(', types)
        self.assertIn('nativeExpect(source, &mut reader, "variant")', types)
        self.assertIn('nativeEquals(source, &kind, "variant")', inst)
        self.assertIn('nativeEquals(source, &kind, "disc")', inst)
        self.assertIn('inst.kind = 7', inst)
        self.assertIn('inst.kind = 8', inst)
        self.assertIn('inst.kind == 7', emit)
        self.assertIn('inst.kind == 8', emit)
        self.assertIn('inst.kind == 8', verify)

if __name__ == '__main__': unittest.main()
