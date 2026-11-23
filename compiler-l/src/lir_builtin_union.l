take sema_types
take lir_build
take sema_context

// Option/Result use the already verified tagged-enum representation of
// ELE-LIR 1. Each concrete instantiation has its own enum id; nominal source
// enums retain en_builtin == -1.
//
// A payload is either DROP-FREE (Int, Bool, a nominal shape whose fields are
// recursively drop-free, or a nominal choice whose variants carry at most
// one Int/Bool payload) or OWNED (#5): Text, List<T>, a nested Option/Result
// or a shape whose fields are, recursively, lowerable payloads. An owned
// payload is MOVED into `i variant` (the source becomes moved); the union
// then carries one atomic drop obligation for its active payload; an owned
// `i payload` moves the payload out and consumes the whole union. Nominal
// choices with owned payloads, references, floats and by-value cycles stay
// unsupported (L0016).
expose flow lirBuiltinPrimitive(ty: Int) => Bool {
    give ty == 1 || ty == 4
}

// Drop-free value of the module tables. `depth` bounds the walk so a
// malformed (recursive by-value) shape table can never loop.
flow lirDropFreeValue(types: view TypeTable, lm: view LirModule, ty: Int, depth: Int) => Bool {
    when lirBuiltinPrimitive(ty) { give true }
    when depth > 8 || ty < 0 || ty >= types.types.length { give false }
    hold decl = types.types[ty].nominal_id
    choose types.types[ty].kind {
        SemTypeKind.Struct : {
            each k among 0..lm.st_decl.length {
                when lm.st_decl[k] == decl {
                    when lm.st_count[k] < 1 { give false }
                    hold first = lm.st_first[k]
                    each f among first..(first + lm.st_count[k]) {
                        when !lirDropFreeValue(types, lm, lm.field_ty[f], depth + 1) { give false }
                    }
                    give true
                }
            }
            give false
        }
        SemTypeKind.Enum : {
            each k among 0..lm.en_decl.length {
                when lm.en_builtin[k] < 0 && lm.en_decl[k] == decl {
                    hold first = lm.en_first[k]
                    each v among first..(first + lm.en_count[k]) {
                        hold n = lm.variant_payload[v]
                        when n < 0 || n > 1 { give false }
                        when n == 1 && !lirBuiltinPrimitive(lm.variant_type[v]) { give false }
                    }
                    give true
                }
            }
            give false
        }
        _ : { give false }
    }
}

// Lowerable payload: drop-free, or owned as described above. `depth`
// bounds the walk (nested unions, list elements, shape fields).
flow lirPayloadValue(types: view TypeTable, lm: view LirModule, ty: Int, depth: Int) => Bool {
    when lirDropFreeValue(types, lm, ty, 0) { give true }
    when depth > 8 || ty < 0 || ty >= types.types.length { give false }
    hold elem = types.types[ty].elem_type
    hold other = types.types[ty].nominal_id
    choose types.types[ty].kind {
        SemTypeKind.Text : { give true }
        SemTypeKind.List : { give lirPayloadValue(types, lm, elem, depth + 1) }
        SemTypeKind.Option : { give lirPayloadValue(types, lm, elem, depth + 1) }
        SemTypeKind.Result : {
            give lirPayloadValue(types, lm, elem, depth + 1) && lirPayloadValue(types, lm, other, depth + 1)
        }
        SemTypeKind.Struct : {
            each k among 0..lm.st_decl.length {
                when lm.st_decl[k] == other {
                    when lm.st_count[k] < 1 { give false }
                    hold first = lm.st_first[k]
                    each f among first..(first + lm.st_count[k]) {
                        when !lirPayloadValue(types, lm, lm.field_ty[f], depth + 1) { give false }
                    }
                    give true
                }
            }
            give false
        }
        _ : { give false }
    }
}

// Payload accepted by `i variant` / `i payload` of a builtin union.
expose flow lirBuiltinPayloadOk(types: view TypeTable, lm: view LirModule, ty: Int) => Bool {
    give lirPayloadValue(types, lm, ty, 0)
}

// Payload that owns heap storage: extracting it moves it out of the union.
expose flow lirBuiltinPayloadOwned(types: view TypeTable, lm: view LirModule, ty: Int) => Bool {
    give lirPayloadValue(types, lm, ty, 0) && !lirDropFreeValue(types, lm, ty, 0)
}

expose flow lirBuiltinSupported(types: view TypeTable, lm: view LirModule, ty: Int) => Bool {
    when ty < 0 || ty >= types.types.length { give false }
    choose types.types[ty].kind {
        SemTypeKind.Option : { give lirPayloadValue(types, lm, ty, 0) }
        SemTypeKind.Result : { give lirPayloadValue(types, lm, ty, 0) }
        _ : { give false }
    }
}

flow lirBuiltinRegisterNested(lm: edit LirModule, types: view TypeTable, ty: Int) {
    when ty < 0 || ty >= types.types.length { give }
    change nested = false
    choose types.types[ty].kind {
        SemTypeKind.Option : { nested = true }
        SemTypeKind.Result : { nested = true }
        _ : {}
    }
    when !nested { give }
    // A failed nested registration leaves its code `?`: rejected (L0016).
    hold index = lirBuiltinRegister(edit lm, types, ty)
    when index < 0 { give }
}

expose flow lirBuiltinEnumIndex(lm: view LirModule, ty: Int) => Int {
    each k among 0..lm.en_builtin.length {
        when lm.en_builtin[k] == ty { give k }
    }
    give -1
}

// Register lazily as bodies introduce concrete types; final header emission
// happens after all functions have been semantically checked.
expose flow lirBuiltinRegister(lm: edit LirModule, types: view TypeTable, ty: Int) => Int {
    when !lirBuiltinSupported(types, lm, ty) { give -1 }
    hold existing = lirBuiltinEnumIndex(lm, ty)
    when existing >= 0 { give existing }
    // Nested unions are registered first, so a payload code `eK` always
    // names an enum declared before the one that contains it.
    lirBuiltinRegisterNested(edit lm, types, types.types[ty].elem_type)
    choose types.types[ty].kind {
        SemTypeKind.Result : { lirBuiltinRegisterNested(edit lm, types, types.types[ty].nominal_id) }
        _ : {}
    }
    hold t = view types.types[ty]
    hold index = lm.en_decl.length
    lm.en_decl@push(-1)
    lm.en_builtin@push(ty)
    lm.en_first@push(lm.variant_payload.length)
    lm.en_count@push(2)
    choose t.kind {
        SemTypeKind.Option : {
            // None = 0 (unit), Some(T) = 1.
            lm.variant_payload@push(0)
            lm.variant_type@push(6)
            lm.variant_payload@push(1)
            lm.variant_type@push(t.elem_type)
        }
        SemTypeKind.Result : {
            // Ok(T) = 0, Err(E) = 1.
            lm.variant_payload@push(1)
            lm.variant_type@push(t.elem_type)
            lm.variant_payload@push(1)
            lm.variant_type@push(t.nominal_id)
        }
        _ : { give -1 }
    }
    give index
}

// Fixed UTF-8 byte records are protocol-safe independent of source spans.
// eN, not the printable name, is the actual identity of an instantiation.
// `first_code`/`second_code` are the LIR type codes of variant 0 and 1
// (the unit `None` code is ignored).
expose flow lirBuiltinHeader(ctx: edit SemaContext, k: Int, first_code: Text, second_code: Text) {
    when k < 0 || k >= ctx.lir_module.en_builtin.length { give }
    hold ty = ctx.lir_module.en_builtin[k]
    when ty < 0 || ty >= ctx.types.types.length { give }
    hold t = view ctx.types.types[ty]
    choose t.kind {
        SemTypeKind.Option : {
            ctx.lir_lines@push("enum e{k} 6:79,112,116,105,111,110 variants 2")
            ctx.lir_lines@push("variant 4:78,111,110,101 types 0")
            ctx.lir_lines@push("variant 4:83,111,109,101 types 1 {second_code}")
        }
        SemTypeKind.Result : {
            ctx.lir_lines@push("enum e{k} 6:82,101,115,117,108,116 variants 2")
            ctx.lir_lines@push("variant 2:79,107 types 1 {first_code}")
            ctx.lir_lines@push("variant 3:69,114,114 types 1 {second_code}")
        }
        _ : {}
    }
}
