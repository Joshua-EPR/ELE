"""Static regression contracts for the ELE-LIR enum interop increment.

These tests deliberately do NOT claim to compile Stage 1 or run Rust/MSVC.
Those checks live in crates/l/tests/lir_payload_protocol.rs and
crates/l/tests/native_enum_stage1_l.rs.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def src(name):
    return (ROOT / name).read_text(encoding='utf-8')


class Stage1EnumBridgeContract(unittest.TestCase):
    def test_decl_table_and_type_name_agree(self):
        module = src('compiler-l/src/lir_module.l')
        emitter = src('compiler-l/src/lir_emit.l')
        self.assertIn('en_decl.push(d)', module)
        self.assertIn('enum e{k} {name} variants {count}', module)
        self.assertIn('return "e{k}"', emitter)
        self.assertIn('"module structs {structs}"', module)

    def test_emitter_never_forges_enum_as_int(self):
        front = src('compiler-l/src/stmt_lower.l')
        writer = src('compiler-l/src/lir_write.l')
        self.assertIn('LIR_VARIANT, enum_id, v, LIR_NONE', front)
        self.assertIn('LIR_DISC, scrut_place, 0, 0', front)
        self.assertIn('i variant v{dst} e{inst.a} {inst.b} 0', writer)
        self.assertIn('i disc v{dst} {place}', writer)

    def test_payload_parser_is_strict_and_native_guard_exists(self):
        parser = src('crates/l/src/lir_protocol.rs')
        native = src('crates/l/src/native.rs')
        self.assertIn('"payload" => {', parser)
        self.assertIn('Type::Int | Type::Bool', parser)
        self.assertIn('Proj::Payload(variant_id, 0)', parser)
        self.assertIn('acceso a variante enum inactiva', native)
        self.assertIn('enum_layout.layout.size / 8', native)

    def test_builtin_unions_only_lower_primitive_payloads(self):
        front = src('compiler-l/src/sema_expr.l')
        binding = src('compiler-l/src/stmt_lower.l')
        union = src('compiler-l/src/lir_builtin_union.l')
        for name in ('Option', 'Result'):
            self.assertIn(f'SemTypeKind.{name}', union)
        self.assertIn('lirBuiltinPrimitive(t.elem_type)', union)
        self.assertIn('lirBuiltinPrimitive(t.nominal_id)', union)
        self.assertIn('lirMarkUnsupported(&mut ctx.lir, start)', src('compiler-l/src/sema_builtin_union.l'))
        self.assertIn('lirBuiltinEnumIndex(&ctx.lir_module, scrut_t)', binding)
        self.assertIn('LIR_PAYLOAD, place, enum_id, which', binding)
        self.assertIn('semaBuiltinUnionValue', front)


if __name__ == '__main__':
    unittest.main()
