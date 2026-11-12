import sema_types
import lir_build
import sema_context

// Option/Result use the already verified tagged-enum representation of
// ELE-LIR 1. Each concrete instantiation has its own enum id; nominal source
// enums retain en_builtin == -1.
//
// A payload must be DROP-FREE: Int, Bool, a nominal shape whose fields are
// recursively drop-free, or a nominal choice whose variants carry at most
// one Int/Bool payload (unit-only choices included). Text, lists, nested
// Option/Result, references and every type that owns heap storage remain
// unsupported (L0016) until move-path/drop elaboration can prove them safe.
pub fn lirBuiltinPrimitive(ty: Int) -> Bool {
    return ty == 1 || ty == 4
}

// Drop-free value of the module tables. `depth` bounds the walk so a
// malformed (recursive by-value) shape table can never loop.
fn lirDropFreeValue(types: &TypeTable, lm: &LirModule, ty: Int, depth: Int) -> Bool {
    if lirBuiltinPrimitive(ty) { return true }
    if depth > 8 || ty < 0 || ty >= types.types.length { return false }
    let decl = types.types[ty].nominal_id
    match types.types[ty].kind {
        SemTypeKind.Struct => {
            for k in 0..lm.st_decl.length {
                if lm.st_decl[k] == decl {
                    if lm.st_count[k] < 1 { return false }
                    let first = lm.st_first[k]
                    for f in first..(first + lm.st_count[k]) {
                        if !lirDropFreeValue(types, lm, lm.field_ty[f], depth + 1) { return false }
                    }
                    return true
                }
            }
            return false
        }
        SemTypeKind.Enum => {
            for k in 0..lm.en_decl.length {
                if lm.en_builtin[k] < 0 && lm.en_decl[k] == decl {
                    let first = lm.en_first[k]
                    for v in first..(first + lm.en_count[k]) {
                        let n = lm.variant_payload[v]
                        if n < 0 || n > 1 { return false }
                        if n == 1 && !lirBuiltinPrimitive(lm.variant_type[v]) { return false }
                    }
                    return true
                }
            }
            return false
        }
        _ => { return false }
    }
}

// Payload accepted by `i variant` / `i payload` of a builtin union.
pub fn lirBuiltinPayloadOk(types: &TypeTable, lm: &LirModule, ty: Int) -> Bool {
    return lirDropFreeValue(types, lm, ty, 0)
}

pub fn lirBuiltinSupported(types: &TypeTable, lm: &LirModule, ty: Int) -> Bool {
    if ty < 0 || ty >= types.types.length { return false }
    let t = &types.types[ty]
    match t.kind {
        SemTypeKind.Option => { return lirBuiltinPayloadOk(types, lm, t.elem_type) }
        SemTypeKind.Result => {
            return lirBuiltinPayloadOk(types, lm, t.elem_type) && lirBuiltinPayloadOk(types, lm, t.nominal_id)
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
    if !lirBuiltinSupported(types, lm, ty) { return -1 }
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
// `first_code`/`second_code` are the LIR type codes of variant 0 and 1
// (the unit `None` code is ignored).
pub fn lirBuiltinHeader(ctx: &mut SemaContext, k: Int, first_code: Text, second_code: Text) {
    if k < 0 || k >= ctx.lir_module.en_builtin.length { return }
    let ty = ctx.lir_module.en_builtin[k]
    if ty < 0 || ty >= ctx.types.types.length { return }
    let t = &ctx.types.types[ty]
    match t.kind {
        SemTypeKind.Option => {
            ctx.lir_lines.push("enum e{k} 6:79,112,116,105,111,110 variants 2")
            ctx.lir_lines.push("variant 4:78,111,110,101 types 0")
            ctx.lir_lines.push("variant 4:83,111,109,101 types 1 {second_code}")
        }
        SemTypeKind.Result => {
            ctx.lir_lines.push("enum e{k} 6:82,101,115,117,108,116 variants 2")
            ctx.lir_lines.push("variant 2:79,107 types 1 {first_code}")
            ctx.lir_lines.push("variant 3:69,114,114 types 1 {second_code}")
        }
        _ => {}
    }
}
