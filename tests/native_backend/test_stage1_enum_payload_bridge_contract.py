"""Source-contract regressions for the Stage 1 enum payload bridge.

These tests inspect code and fixtures only; they DO NOT execute Stage 0,
compile `.l`, or verify any ELF. See the Rust integration suite for that.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

def read(path):
    return (ROOT / path).read_text(encoding="utf-8")

class EnumPayloadBridgeContract(unittest.TestCase):
    def test_stage1_preserves_payload_type_and_emits_typed_lir(self):
        module = read('compiler-l/src/lir_module.l')
        build = read('compiler-l/src/lir_build.l')
        write = read('compiler-l/src/lir_write.l')
        self.assertIn('variant_type: List<Int>', build)
        self.assertIn('ctx.lir_module.variant_type.push(payload_ty)', module)
        self.assertIn('const LIR_PAYLOAD = 23', build)
        self.assertIn('i variant v{dst} e{inst.a} {inst.b} 1 {payload}', write)
        self.assertIn('i payload v{dst} {place} e{inst.b} {inst.c}', write)

    def test_constructed_variant_checks_arity_and_primitive_types(self):
        lower = read('compiler-l/src/stmt_lower.l')
        front = read('compiler-l/src/sema_expr.l')
        self.assertIn('semaEnumVariantCall(&mut ctx, source, tree, expr)', front)
        # The enum expression stays in sema_expr: importing sema_expr from
        # stmt_lower would create a circular dependency.
        self.assertIn('fn semaEnumVariantCall(', front)
        self.assertIn('if argc != variant.payload_count', front)
        self.assertIn('if expected != 1 && expected != 4', front)
        self.assertIn('LIR_VARIANT, enum_id, v, payload', front)
        self.assertNotIn('semaExprMode(', lower)

    def test_match_bindings_are_guarded_and_scoped(self):
        lower = read('compiler-l/src/stmt_lower.l')
        front = read('compiler-l/src/sema_stmt.l')
        self.assertIn('LIR_PAYLOAD, place, enum_id, v', lower)
        self.assertIn('lirMatchArmBind(&mut ctx', front)
        self.assertIn('semaEnumMatchCovered(&mut ctx', front)
        self.assertIn('scopePush(&mut ctx.scopes)', front)
        self.assertIn('scopePop(&mut ctx.scopes)', front)

    def test_verifier_rejects_wrong_enum_variant_and_owned_payloads(self):
        verifier = read('compiler-l/src/lir_verify.l')
        builtin = read('compiler-l/src/lir_builtin_union.l')
        self.assertIn('kind == LIR_PAYLOAD', verifier)
        self.assertIn('lm.variant_type[variant]', verifier)
        self.assertIn('if !lirBuiltinPayloadOk(types, lm, payload_ty) { return 3 }', verifier)
        self.assertIn('if lirBuiltinPrimitive(ty) { return true }', builtin)
        self.assertIn('if !lirDropFreeValue(types, lm, lm.field_ty[f], depth + 1)', builtin)
        self.assertIn('if n < 0 || n > 1 { return false }', builtin)
        self.assertIn('if n == 1 && !lirBuiltinPrimitive(lm.variant_type[v])', builtin)
        self.assertIn('_ => { return false }', builtin)
        self.assertIn('types.types[enum_t].nominal_id != lm.en_decl[inst.b]', verifier)
        self.assertIn('if check && !v.defined[l.places[inst.a].root]', verifier)

    def test_real_source_fixture_is_not_manual_lir(self):
        source = read('examples/native_enum_payload_stage1.l')
        self.assertIn('choice Estado', source)
        self.assertIn('Estado@Si(40)', source)
        self.assertIn('Estado.Si(v):', source)
        self.assertIn('give sumar(v)', source)

if __name__ == '__main__':
    unittest.main()
