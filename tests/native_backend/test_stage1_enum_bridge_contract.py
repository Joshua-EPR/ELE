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
        # Owned payloads are now admitted, but exact type, direct-value,
        # variant and move checks must remain at the protocol boundary.
        self.assertIn('fn payload_ok(', parser)
        self.assertIn('if depth > 8 {', parser)
        self.assertIn('Type::Int | Type::Bool | Type::Text | Type::List(_) => true,', parser)
        self.assertIn('|| !payload_ok(payload[0], self.structs, self.enums, 0)', parser)
        self.assertIn('self.vars[place.var] != VarTy::Value(Type::Enum(enum_id))', parser)
        self.assertIn('if place.var == d {', parser)
        self.assertIn('Proj::Payload(variant_id, 0)', parser)
        self.assertIn('fn consumed_enum(', parser)
        self.assertIn('owns(t, self.structs, self.enums, 0).then_some(place.var)', parser)
        self.assertIn('kind: InstKind::Moved(var)', parser)
        self.assertIn('acceso a variante enum inactiva', native)
        self.assertIn('enum_layout.layout.size / 8', native)

    def test_builtin_unions_lower_owned_payloads_with_strict_guards(self):
        front = src('compiler-l/src/sema_expr.l')
        binding = src('compiler-l/src/stmt_lower.l')
        union = src('compiler-l/src/lir_builtin_union.l')
        for name in ('Option', 'Result'):
            self.assertIn(f'SemTypeKind.{name}', union)
        # Both generic arms use the bounded recursive payload classifier.
        self.assertIn('fn lirPayloadValue(', union)
        self.assertIn('if depth > 8 || ty < 0 || ty >= types.types.length { return false }', union)
        self.assertIn('SemTypeKind.List => { return lirPayloadValue(types, lm, elem, depth + 1) }', union)
        self.assertIn('return lirPayloadValue(types, lm, elem, depth + 1) && lirPayloadValue(types, lm, other, depth + 1)', union)
        self.assertIn('return lirPayloadValue(types, lm, ty, 0)', union)
        self.assertIn('return lirPayloadValue(types, lm, ty, 0) && !lirDropFreeValue(types, lm, ty, 0)', union)
        # Drop-free nominal choices still cannot hide arbitrary owned payloads.
        self.assertIn('fn lirDropFreeValue(', union)
        self.assertIn('if n == 1 && !lirBuiltinPrimitive(lm.variant_type[v]) { return false }', union)
        # Extracting an owned payload moves its scrutinee, not a borrowed alias.
        self.assertIn('semaAccess(&mut ctx, scrut_path, scrut_t, ACCESS_MOVE, start, finish)', binding)
        self.assertIn('lirBuiltinEnumIndex(&ctx.lir_module, scrut_t)', binding)
        self.assertIn('LIR_PAYLOAD, place, enum_id, which', binding)
        self.assertIn('semaBuiltinUnionValue', front)
        # The separate ELE-native backend still rejects owned-enum layouts:
        # Stage 1 LIR support does not silently imply unsafe native codegen.
        types = src('compiler-l/src/codegen/native_cfg_fields.l')
        verify = src('compiler-l/src/codegen/native_cfg_verify.l')
        self.assertIn('when cfgOwnsHeap(p, payload) || cfgTypeAlign(p, payload) > 8 { give 82 }', types)
        self.assertIn('when inst.kind == 9 && cfgPayloadMoves(p, f, inst) { live[inst.place_var] = false }', verify)
        self.assertIn('lirMarkUnsupported(&mut ctx.lir, start)', src('compiler-l/src/sema_builtin_union.l'))


if __name__ == '__main__':
    unittest.main()
