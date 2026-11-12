import sema_types
import sema_context
import sema_lower
import lir_build
import lir_builtin_union

// Concrete builtin-union value constructors. Only Int and Bool payloads
// enter native ELE-LIR today. Everything requiring owned payload drops
// still fails with L0016; no unchecked read or fake integer tag is emitted.
// variant: 0=Ok, 1=Err, 2=Some.
pub fn semaBuiltinUnionValue(ctx: &mut SemaContext, arg_t: Int, payload: Int, variant: Int, start: Int, end: Int) -> Int {
    if variant == 2 {
        let ty = semTypeMakeOption(&mut ctx.types, arg_t)
        let index = lirBuiltinRegister(&mut ctx.lir_module, &ctx.types, ty)
        if index < 0 {
            lirMarkUnsupported(&mut ctx.lir, start)
        } else {
            lirSetVal(&mut ctx, lirNew(&mut ctx, ty, false, LIR_VARIANT, index, 1, payload))
        }
        return ty
    }
    let contextual = ctx.expected_union_type
    if contextual < 0 || contextual >= ctx.types.types.length {
        lirMarkUnsupported(&mut ctx.lir, start)
        if variant == 0 { return semTypeMakeResult(&mut ctx.types, arg_t, 0) }
        return semTypeMakeResult(&mut ctx.types, 0, arg_t)
    }
    match ctx.types.types[contextual].kind {
        SemTypeKind.Result => {}
        _ => {
            lirMarkUnsupported(&mut ctx.lir, start)
            if variant == 0 { return semTypeMakeResult(&mut ctx.types, arg_t, 0) }
            return semTypeMakeResult(&mut ctx.types, 0, arg_t)
        }
    }
    var expected = ctx.types.types[contextual].elem_type
    if variant == 1 { expected = ctx.types.types[contextual].nominal_id }
    if !semTypeEquals(&ctx.types, arg_t, expected) {
        semaAddError(&mut ctx, "L0004", "tipo de payload incompatible con Result", start, end)
        return 7
    }
    let index = lirBuiltinRegister(&mut ctx.lir_module, &ctx.types, contextual)
    if index < 0 {
        lirMarkUnsupported(&mut ctx.lir, start)
    } else {
        lirSetVal(&mut ctx, lirNew(&mut ctx, contextual, false, LIR_VARIANT, index, variant, payload))
    }
    return contextual
}
