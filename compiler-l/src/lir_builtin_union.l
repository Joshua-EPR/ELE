import sema_types
import lir_build
import sema_context

// Option/Result of *Copy primitive* payloads use the already verified
// tagged-enum representation of ELE-LIR 1. Each concrete instantiation has
// its own enum id; nominal source enums retain en_builtin == -1.
// Text, lists, user structs and borrowed/owned payloads remain unsupported
// until move-path/drop elaboration can prove them safe.
pub fn lirBuiltinPrimitive(ty: Int) -> Bool {
    return ty == 1 || ty == 4
}

pub fn lirBuiltinSupported(types: &TypeTable, ty: Int) -> Bool {
    if ty < 0 || ty >= types.types.length { return false }
    let t = &types.types[ty]
    match t.kind {
        SemTypeKind.Option => { return lirBuiltinPrimitive(t.elem_type) }
        SemTypeKind.Result => {
            return lirBuiltinPrimitive(t.elem_type) && lirBuiltinPrimitive(t.nominal_id)
        }
        _ => { return false }
    }
}

pub fn lirBuiltinEnumIndex(lm: &LirModule, ty: Int) -> Int {
    for k in 0..lm.en_builtin.length {
        if lm.en_builtin[k] == ty { return k }
    }
    return -1
}

// Register lazily as bodies introduce concrete types; final header emission
// happens after all functions have been semantically checked.
pub fn lirBuiltinRegister(lm: &mut LirModule, types: &TypeTable, ty: Int) -> Int {
    if !lirBuiltinSupported(types, ty) { return -1 }
    let existing = lirBuiltinEnumIndex(lm, ty)
    if existing >= 0 { return existing }
    let t = &types.types[ty]
    let index = lm.en_decl.length
    lm.en_decl.push(-1)
    lm.en_builtin.push(ty)
    lm.en_first.push(lm.variant_payload.length)
    lm.en_count.push(2)
    match t.kind {
        SemTypeKind.Option => {
            // None = 0 (unit), Some(T) = 1.
            lm.variant_payload.push(0)
            lm.variant_type.push(6)
            lm.variant_payload.push(1)
            lm.variant_type.push(t.elem_type)
        }
        SemTypeKind.Result => {
            // Ok(T) = 0, Err(E) = 1.
            lm.variant_payload.push(1)
            lm.variant_type.push(t.elem_type)
            lm.variant_payload.push(1)
            lm.variant_type.push(t.nominal_id)
        }
        _ => { return -1 }
    }
    return index
}

// Fixed UTF-8 byte records are protocol-safe independent of source spans.
// eN, not the printable name, is the actual identity of an instantiation.
pub fn lirBuiltinHeader(ctx: &mut SemaContext, k: Int) {
    if k < 0 || k >= ctx.lir_module.en_builtin.length { return }
    let ty = ctx.lir_module.en_builtin[k]
    if ty < 0 || ty >= ctx.types.types.length { return }
    let t = &ctx.types.types[ty]
    match t.kind {
        SemTypeKind.Option => {
            var payload = "i"
            if t.elem_type == 4 { payload = "b" }
            ctx.lir_lines.push("enum e{k} 6:79,112,116,105,111,110 variants 2")
            ctx.lir_lines.push("variant 4:78,111,110,101 types 0")
            ctx.lir_lines.push("variant 4:83,111,109,101 types 1 {payload}")
        }
        SemTypeKind.Result => {
            var ok_type = "i"
            var err_type = "i"
            if t.elem_type == 4 { ok_type = "b" }
            if t.nominal_id == 4 { err_type = "b" }
            ctx.lir_lines.push("enum e{k} 6:82,101,115,117,108,116 variants 2")
            ctx.lir_lines.push("variant 2:79,107 types 1 {ok_type}")
            ctx.lir_lines.push("variant 3:69,114,114 types 1 {err_type}")
        }
        _ => {}
    }
}
