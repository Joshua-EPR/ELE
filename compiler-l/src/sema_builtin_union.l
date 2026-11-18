import sema_types
import sema_context
import sema_lower
import lir_build
import lir_builtin_union

// Expected union type of a constructor's payload: the payload type of
// `contextual` for this variant when it is itself an Option/Result, else -1.
// The outer expected type is never inherited by the payload expression.
expose flow semaBuiltinPayloadExpected(ctx: view SemaContext, contextual: Int, variant: Int) => Int {
    when contextual < 0 || contextual >= ctx.types.types.length { give -1 }
    change inner = -1
    choose ctx.types.types[contextual].kind {
        SemTypeKind.Option : { when variant == 2 { inner = ctx.types.types[contextual].elem_type } }
        SemTypeKind.Result : {
            when variant == 0 { inner = ctx.types.types[contextual].elem_type }
            when variant == 1 { inner = ctx.types.types[contextual].nominal_id }
        }
        _ : {}
    }
    when inner < 0 || inner >= ctx.types.types.length { give -1 }
    choose ctx.types.types[inner].kind {
        SemTypeKind.Option : { give inner }
        SemTypeKind.Result : { give inner }
        _ : { give -1 }
    }
}

// Concrete builtin-union value constructors (variant: 0=Ok, 1=Err, 2=Some).
// The payload operand was evaluated with ACCESS_MOVE, so an owned payload
// (Text, List<T>, nested union, owner-bearing shape) is moved into the
// union and the source path becomes moved; the union value then carries
// the drop obligation of its active payload. No unchecked read or fake
// integer tag is emitted; unsupported payloads keep failing with L0016.
pub fn semaBuiltinUnionValue(ctx: &mut SemaContext, arg_t: Int, payload: Int, variant: Int, start: Int, end: Int) -> Int {
    if variant == 2 {
        let ty = semTypeMakeOption(&mut ctx.types, arg_t)
        let index = lirBuiltinRegister(&mut ctx.lir_module, &ctx.types, ty)
        if index < 0 {
            lirMarkUnsupported(&mut ctx.lir, start)
        } else {
            // LIR allocation and result registration must not overlap mutable borrows.
            let value = lirNew(&mut ctx, ty, false, LIR_VARIANT, index, 1, payload)
            lirSetVal(&mut ctx, value)
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
        let value = lirNew(&mut ctx, contextual, false, LIR_VARIANT, index, variant, payload)
        lirSetVal(&mut ctx, value)
    }
    return contextual
}
