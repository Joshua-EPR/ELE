take sema_types
take sema_context
take sema_lower
take lir_build
take lir_builtin_union

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
expose flow semaBuiltinUnionValue(ctx: edit SemaContext, arg_t: Int, payload: Int, variant: Int, start: Int, end: Int) => Int {
    when semaRejectLinearElem(edit ctx, arg_t, start, end) { give 7 }
    when variant == 2 {
        hold ty = semTypeMakeOption(edit ctx.types, arg_t)
        hold index = lirBuiltinRegister(edit ctx.lir_module, view ctx.types, ty)
        when index < 0 {
            lirMarkUnsupported(edit ctx.lir, start)
        } otherwise {
            // LIR allocation and result registration must not overlap mutable borrows.
            hold value = lirNew(edit ctx, ty, false, LIR_VARIANT, index, 1, payload)
            lirSetVal(edit ctx, value)
        }
        give ty
    }
    hold contextual = ctx.expected_union_type
    when contextual < 0 || contextual >= ctx.types.types.length {
        lirMarkUnsupported(edit ctx.lir, start)
        when variant == 0 { give semTypeMakeResult(edit ctx.types, arg_t, 0) }
        give semTypeMakeResult(edit ctx.types, 0, arg_t)
    }
    choose ctx.types.types[contextual].kind {
        SemTypeKind.Result : {}
        _ : {
            lirMarkUnsupported(edit ctx.lir, start)
            when variant == 0 { give semTypeMakeResult(edit ctx.types, arg_t, 0) }
            give semTypeMakeResult(edit ctx.types, 0, arg_t)
        }
    }
    change expected = ctx.types.types[contextual].elem_type
    when variant == 1 { expected = ctx.types.types[contextual].nominal_id }
    when !semTypeEquals(view ctx.types, arg_t, expected) {
        semaAddError(edit ctx, "L0004", "tipo de payload incompatible con Result", start, end)
        give 7
    }
    hold index = lirBuiltinRegister(edit ctx.lir_module, view ctx.types, contextual)
    when index < 0 {
        lirMarkUnsupported(edit ctx.lir, start)
    } otherwise {
        hold value = lirNew(edit ctx, contextual, false, LIR_VARIANT, index, variant, payload)
        lirSetVal(edit ctx, value)
    }
    give contextual
}
