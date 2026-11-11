"""Fixture/protocol consistency checks only, NOT compilation of ELE code.

Stage 0 integration and real ELF execution are in crates/l/tests/native_struct_cfg_l.rs.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def encoded(text: str) -> str:
    data = text.encode('utf-8')
    return f"{len(data)}:" + ','.join(str(b) for b in data)


class NativeStructProtocolFixtures(unittest.TestCase):
    def test_valid_fixture_matches_provisional_ele_lir_1(self):
        lines = (ROOT / 'examples/native_cfg_struct_copy.lir').read_text().splitlines()
        self.assertEqual(lines[:2], ['ELE-LIR 1', 'module structs 1 funcs 1 main f0'])
        self.assertEqual(lines[2], f'struct s0 {encoded("Pair")} fields 3')
        self.assertEqual(lines[3:6], [
            f'field {encoded("left")} i',
            f'field {encoded("flag")} b',
            f'field {encoded("right")} i',
        ])
        header = lines[6].split()
        self.assertEqual(header[-2:], ['blocks', '1'])
        declared = int(lines[6].split('vars ')[1].split()[0])
        self.assertEqual(lines[7:7+declared], [
            'var v0 val s0', 'var v1 val s0', 'var v2 val i',
            'var v3 val b', 'var v4 val i', 'var v5 val i', 'var v6 val i',
        ])
        block = lines[7+declared]
        self.assertEqual(block, 'block 0 8')
        instructions = lines[8+declared:16+declared]
        self.assertEqual(len(instructions), 8)
        self.assertEqual(instructions[0], 'i struct v0 s0 3 ci19 cb1 ci20')
        self.assertEqual(instructions[4], 'i store p1.2 ci22')
        self.assertEqual(lines[-3:], ['t return v6', 'endfunc', 'end'])

    def test_invalid_fixtures_cover_distinct_error_paths(self):
        fixtures = {
            'native_cfg_struct_wrong_field.lir': 'i read v2 p1.3',
            'native_cfg_struct_wrong_type.lir': 'i struct v0 s0 3 cb1 cb1 ci20',
            'native_cfg_struct_uninitialized.lir': 'i read v2 p0.0',
            'native_cfg_struct_bad_store.lir': 'i store p1.2 cb1',
            'native_cfg_struct_bad_owner.lir': f'field {encoded("right")} t',
            'native_cfg_struct_bad_call.lir': 'i call v0 f1 0',
        }
        for name, fragment in fixtures.items():
            with self.subTest(name=name):
                self.assertIn(fragment, (ROOT / 'examples' / name).read_text())

    def test_stage1_source_includes_real_nominal_field_access(self):
        src = (ROOT / 'examples/native_cfg_real_struct.l').read_text()
        self.assertIn('shape Pair', src)
        self.assertIn('pair.flag', src)
        self.assertIn('pair.left', src)
        self.assertIn('pair.right', src)
        test = (ROOT / 'crates/l/tests/native_struct_cfg_l.rs').read_text()
        self.assertIn('"--emit-lir"', test)
        self.assertIn('generate(&file)', test)

if __name__ == '__main__':
    unittest.main()
