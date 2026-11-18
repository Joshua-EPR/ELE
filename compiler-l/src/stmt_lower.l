import tokens
import ast
import sema_types
import symbols
import scopes
import flow_cfg
import lir_build
import sema_context
import sema_drop
import sema_lower
import lir_builtin_union

// Statement lowering helpers for the semantic pass (sema_stmt.l). They run
// right after the statement's CFG events, so the instructions they emit sit
// after those events and the drop plan can be spliced around them.

// `let name = value` after FLOW_INIT: a reference binding names the
// reference variable produced by the initializer; any other binding gets
// its own variable assigned from the value.
pub fn lirLetBind(ctx: &mut SemaContext, path: Int, ty: Int, reference: Bool) {
    let value = lirTakeOperand(&mut ctx, ty)
    if reference && lirIsVar(value) {
        lirBindPath(&mut ctx.lir, path, value)
        return
    }
    let slot = lirVar(&mut ctx.lir, ty, false)
    lirBindPath(&mut ctx.lir, path, slot)
    lirAt(&mut ctx, LIR_USE, slot, value, 0, 0)
}

// `target = value` / `target op= value` after FLOW_WRITE.
pub fn lirAssign(ctx: &mut SemaContext, source: &Text, place: Int, value: Int, ty: Int, op_start: Int, op_end: Int) {
    if place < 0 { return }
    var result = value
    if op_end - op_start > 1 {
        ctx.lir.place = place
        let current = lirTakeOperand(&mut ctx, ty)
        let op = lirBinaryOp(source, op_start, op_start + 1)
        result = lirNew(&mut ctx, ty, false, LIR_BINARY, op, current, value)
    }
    lirWrite(&mut ctx, place, result)
}

// Branch condition of the current block (if, while, for).
pub fn lirCondition(ctx: &mut SemaContext) {
    let operand = lirTakeOperand(&mut ctx, 4)
    // End the block-count read before lending the LIR mutably.
    let block_count = ctx.flow.blocks.length
    lirBlocks(&mut ctx.lir, block_count)
    ctx.lir.cond[ctx.flow.current] = operand
}

// Return value of the current block, recorded before it is detached.
pub fn lirReturnAt(ctx: &mut SemaContext, value: Int, reference: Bool) {
    // End the block-count read before lending the LIR mutably.
    let block_count = ctx.flow.blocks.length
    lirBlocks(&mut ctx.lir, block_count)
    var operand = value
    if operand == LIR_NONE { operand = lirConst(&mut ctx.lir, LIR_CONST_UNIT, 0, 0, 0) }
    ctx.lir.ret[ctx.flow.current] = operand
    ctx.lir.ret_ref[ctx.flow.current] = reference
}

// Forget whatever a discarded expression left in the value channel.
pub fn lirDiscard(ctx: &mut SemaContext) {
    ctx.lir.place = -1
    ctx.lir.val = LIR_NONE
}

// `for i in start..end`: counter and limit are evaluated once; the header
// tests `counter < limit`, the body binds `i`, and the step block (also the
// target of `continue`) increments the counter.
pub fn lirForInit(ctx: &mut SemaContext, start: Int, end: Int) -> Int {
    // The limit variable is always the one right after the counter.
    let counter = lirNew(&mut ctx, 1, false, LIR_USE, start, 0, 0)
    lirNew(&mut ctx, 1, false, LIR_USE, end, 0, 0)
    return counter
}

pub fn lirForTest(ctx: &mut SemaContext, counter: Int) {
    // Do not mutate the value channel while constructing its operand.
    let comparison = lirNew(&mut ctx, 4, false, LIR_BINARY, LIR_LT, counter, counter + 1)
    ctx.lir.val = comparison
    ctx.lir.place = -1
    lirCondition(&mut ctx)
}

pub fn lirForStep(ctx: &mut SemaContext, counter: Int) {
    let one = lirConst(&mut ctx.lir, LIR_CONST_INT, 1, 0, 0)
    let next = lirNew(&mut ctx, 1, false, LIR_BINARY, LIR_ADD, counter, one)
    lirAt(&mut ctx, LIR_USE, counter, next, 0, 0)
}

pub fn lirMatchScrutVar(ctx: &mut SemaContext, scrut_t: Int) -> Int {
    let scrut_op = lirTakeOperand(&mut ctx, scrut_t)
    if lirIsVar(scrut_op) { return scrut_op }
    let v = lirVar(&mut ctx.lir, scrut_t, false)
    lirAt(&mut ctx, LIR_USE, v, scrut_op, 0, 0)
    return v
}

pub fn lirMatchArmTest(ctx: &mut SemaContext, source: &Text, tree: &AstTree, p_start: Int, p_end: Int, scrut_var: Int, scrut_t: Int, arm_body: Int, next_test: Int, is_last: Bool) -> Bool {
    // A wildcard needs no discriminant or payload binding. A proven final
    // named arm is handled by its type-specific branch below: builtin
    // Option/Result arms must still bind their payloads before entry.
    if p_end - p_start == 1 && source.byteAt(p_start) == 95 {
        flowLink(&mut ctx.flow, arm_body, -1)
        return true
    }
    var enum_decl = -1
    var elem_t = -1
    var is_option = false
    var is_result = false
    if scrut_t >= 0 && scrut_t < ctx.types.types.length {
        let st = &ctx.types.types[scrut_t]
        match st.kind {
            SemTypeKind.Enum => { enum_decl = st.nominal_id }
            SemTypeKind.Option => {
                is_option = true
                elem_t = st.elem_type
            }
            SemTypeKind.Result => {
                is_result = true
                elem_t = st.elem_type
            }
            _ => {}
        }
    }
    let name_none = "None"
    if is_option || is_result {
        let builtin_id = lirBuiltinRegister(&mut ctx.lir_module, &ctx.types, scrut_t)
        if builtin_id < 0 { lirMarkUnsupported(&mut ctx.lir, p_start) }
        var disc = -1
        if is_option && symbolNameEqualsText(source, p_start, p_end, name_none) {
            disc = 0
        } else if is_option && (p_end - p_start > 6) && source.byteAt(p_start) == 83 && source.byteAt(p_start + 1) == 111 && source.byteAt(p_start + 2) == 109 && source.byteAt(p_start + 3) == 101 && source.byteAt(p_start + 4) == 40 {
            disc = 1
        } else if is_result && (p_end - p_start > 4) && source.byteAt(p_start) == 79 && source.byteAt(p_start + 1) == 107 && source.byteAt(p_start + 2) == 40 {
            disc = 0
        } else if is_result && (p_end - p_start > 5) && source.byteAt(p_start) == 69 && source.byteAt(p_start + 1) == 114 && source.byteAt(p_start + 2) == 114 && source.byteAt(p_start + 3) == 40 {
            disc = 1
        }
        if disc >= 0 {
            if is_last {
                // Final named arm is unconditional only after strict coverage
                // proof. Its payload is read inside that arm, not here.
                flowLink(&mut ctx.flow, arm_body, -1)
            } else {
                let place = lirPlaceVar(&mut ctx.lir, scrut_var)
                let tag = lirNew(&mut ctx, 1, false, LIR_DISC, place, 0, 0)
                let target = lirConst(&mut ctx.lir, LIR_CONST_INT, disc, 0, 0)
                let cond = lirNew(&mut ctx, 4, false, LIR_BINARY, LIR_EQ, tag, target)
                ctx.lir.val = cond
                ctx.lir.place = -1
                lirCondition(&mut ctx)
                flowLink(&mut ctx.flow, arm_body, next_test)
            }
            return is_last
        }
        lirMarkUnsupported(&mut ctx.lir, p_start)
    }
    // Only the strict nominal-enum coverage proof may promote a final
    // named variant to an unconditional arm (its payload binds separately).
    if is_last && enum_decl >= 0 {
        flowLink(&mut ctx.flow, arm_body, -1)
        return true
    }
    if enum_decl >= 0 && enum_decl < tree.declarations.length {
        let decl = &tree.declarations[enum_decl]
        var variant_idx = -1
        var var_start = p_start
        var var_end = p_end
        for c in p_start..p_end {
            if source.byteAt(c) == 40 && var_end == p_end { var_end = c }
            if source.byteAt(c) == 46 && c < var_end { var_start = c + 1 }
        }
        for v in 0..decl.d {
            let variant = &tree.variants[decl.c + v]
            if symbolNamesEqual(source, variant.name_start, variant.name_end, var_start, var_end) {
                variant_idx = v
            }
        }
        if variant_idx >= 0 {
            let variant = &tree.variants[decl.c + variant_idx]
            if variant.payload_count > 1 { lirMarkUnsupported(&mut ctx.lir, p_start) }
            let scrut_place = lirPlaceVar(&mut ctx.lir, scrut_var)
            let disc_var = lirNew(&mut ctx, 1, false, LIR_DISC, scrut_place, 0, 0)
            let disc_const = lirConst(&mut ctx.lir, LIR_CONST_INT, variant_idx, 0, 0)
            let cond = lirNew(&mut ctx, 4, false, LIR_BINARY, LIR_EQ, disc_var, disc_const)
            ctx.lir.val = cond
            ctx.lir.place = -1
            lirCondition(&mut ctx)
            flowLink(&mut ctx.flow, arm_body, next_test)
            return false
        }
    }
    if enum_decl >= 0 { lirMarkUnsupported(&mut ctx.lir, p_start) }
    flowLink(&mut ctx.flow, arm_body, next_test)
    return false
}

// Bind a payload only in the matching arm. This produces an explicit checked
// `payload` operation, never an unchecked `read` of the enum. Int/Bool are
// copied; any other lowerable payload (lirBuiltinPayloadOk) is moved out of
// the scrutinee, which is consumed. An owned payload (Text, List<T>, nested
// union, owner-bearing shape) becomes an owned binding with its own drop;
// the scrutinee must then be a direct owned variable (semaCheckMatch gives
// temporaries one), so the consumed union is never dropped again.
pub fn lirMatchArmBind(ctx: &mut SemaContext, source: &Text, tree: &AstTree, p_start: Int, p_end: Int, scrut_var: Int, scrut_t: Int, scrut_path: Int) {
    if scrut_t < 0 || scrut_t >= ctx.types.types.length { return }
    // Primitive builtin unions reuse the exact checked LIR_PAYLOAD protocol
    // of nominal enums. Never bind before testing the active tag.
    let st = &ctx.types.types[scrut_t]
    var builtin = false
    var which = -1
    var start = -1
    var payload_ty = -1
    match st.kind {
        SemTypeKind.Option => {
            builtin = true
            if p_end - p_start > 6 && source.byteAt(p_start) == 83 && source.byteAt(p_start + 4) == 40 {
                which = 1
                start = p_start + 5
                payload_ty = st.elem_type
            }
        }
        SemTypeKind.Result => {
            builtin = true
            if p_end - p_start > 4 && source.byteAt(p_start) == 79 && source.byteAt(p_start + 2) == 40 {
                which = 0
                start = p_start + 3
                payload_ty = st.elem_type
            } else if p_end - p_start > 5 && source.byteAt(p_start) == 69 && source.byteAt(p_start + 3) == 40 {
                which = 1
                start = p_start + 4
                payload_ty = st.nominal_id
            }
        }
        _ => {}
    }
    if builtin {
        if start < 0 { return }
        let finish = p_end - 1
        if source.byteAt(finish) != 41 { lirMarkUnsupported(&mut ctx.lir, p_start); return }
        if finish == start + 1 && source.byteAt(start) == 95 { return }
        // Binding a non-Copy payload by value MOVES it out of the scrutinee
        // (as in Stage 0): the whole union is consumed, so a later use of the
        // scrutinee is a use after move, and moving out of a borrowed
        // scrutinee is rejected (L0005). Primitive payloads stay copies.
        if payload_ty >= 0 && payload_ty < ctx.types.types.length && !lirBuiltinPrimitive(payload_ty) {
            semaAccess(&mut ctx, scrut_path, scrut_t, ACCESS_MOVE, start, finish)
            // The examined place stays frozen for the whole arm: assigning
            // it there is rejected like in Stage 0 (semaCheckMatch unfreezes).
            if scrut_path >= 0 && scrut_path < ctx.flow.paths.length && ctx.flow.paths[scrut_path].symbol >= 0 {
                let frozen = ctx.flow.paths[scrut_path].symbol
                ctx.frozen_symbols.push(frozen)
            }
        }
        // The binding's instructions carry the position of its pattern
        // (the final arm emits no discriminant test of its own).
        ctx.lir.at = p_start
        if !lirBuiltinPayloadOk(&ctx.types, &ctx.lir_module, payload_ty) || !lirBuiltinSupported(&ctx.types, &ctx.lir_module, scrut_t) {
            // Stage 1 ownership must still see the source-level pattern
            // binder for non-native unions (e.g. Result<Int, LexError>).
            // The LIR remains explicitly unsupported: no unchecked payload
            // read, coercion, or fabricated value can reach the backend.
            lirMarkUnsupported(&mut ctx.lir, p_start)
            let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Var, start, finish, payload_ty, ctx.scopes.current_scope, false, false, -1, start, finish)
            scopeAddSymbol(&mut ctx.scopes, sym_id)
            semaInitPath(&mut ctx, sym_id, start, finish)
            return
        }
        let enum_id = lirBuiltinEnumIndex(&ctx.lir_module, scrut_t)
        if enum_id < 0 { lirMarkUnsupported(&mut ctx.lir, p_start); return }
        let owned = lirBuiltinPayloadOwned(&ctx.types, &ctx.lir_module, payload_ty)
        // Moving an owned payload out needs a tracked, directly owned union.
        if owned && (scrut_path < 0 || scrut_var < 0 || scrut_var >= ctx.lir.vars.length || ctx.lir.vars[scrut_var].is_ref) {
            lirMarkUnsupported(&mut ctx.lir, p_start)
        }
        let place = lirPlaceVar(&mut ctx.lir, scrut_var)
        let value = lirNew(&mut ctx, payload_ty, false, LIR_PAYLOAD, place, enum_id, which)
        let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Var, start, finish, payload_ty, ctx.scopes.current_scope, false, false, -1, start, finish)
        scopeAddSymbol(&mut ctx.scopes, sym_id)
        semaInitPath(&mut ctx, sym_id, start, finish)
        lirSetVal(&mut ctx, value)
        // A move-path snapshot must precede the exclusive borrow of ctx.
        let bind_path = ctx.symbols.symbols[sym_id].move_path
        lirLetBind(&mut ctx, bind_path, payload_ty, false)
        // The moved-out payload is an owned binding: dropped at the end of
        // its arm unless moved on (return, call, constructor).
        if owned { semaOwn(&mut ctx, source, tree, bind_path, payload_ty, start) }
        return
    }
    match ctx.types.types[scrut_t].kind {
        SemTypeKind.Enum => {}
        _ => { return }
    }
    let decl_id = ctx.types.types[scrut_t].nominal_id
    if decl_id < 0 || decl_id >= tree.declarations.length { return }
    let decl = &tree.declarations[decl_id]
    var open = -1
    var name_start = p_start
    for i in p_start..p_end {
        if source.byteAt(i) == 40 && open < 0 { open = i }
        if source.byteAt(i) == 46 && open < 0 { name_start = i + 1 }
    }
    if open < 0 { return }
    if p_end <= open + 2 || source.byteAt(p_end - 1) != 41 {
        lirMarkUnsupported(&mut ctx.lir, p_start)
        return
    }
    let binding_start = open + 1
    let binding_end = p_end - 1
    if binding_end == binding_start + 1 && source.byteAt(binding_start) == 95 { return }
    for j in binding_start..binding_end {
        let b = source.byteAt(j)
        let letter = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
        let digit = (b >= 48 && b <= 57) && j > binding_start
        if !letter && !digit { lirMarkUnsupported(&mut ctx.lir, p_start); return }
    }
    for v in 0..decl.d {
        let variant = &tree.variants[decl.c + v]
        if !symbolNamesEqual(source, variant.name_start, variant.name_end, name_start, open) { continue }
        if variant.payload_count != 1 {
            lirMarkUnsupported(&mut ctx.lir, p_start)
            return
        }
        let ty = semaResolveAstType(&mut ctx, source, tree, tree.extra[variant.first_payload_index])
        if ty != 1 && ty != 4 {
            lirMarkUnsupported(&mut ctx.lir, p_start)
            return
        }
        var enum_id = -1
        for k in 0..ctx.lir_module.en_decl.length {
            if ctx.lir_module.en_decl[k] == decl_id { enum_id = k }
        }
        if enum_id < 0 { lirMarkUnsupported(&mut ctx.lir, p_start); return }
        let place = lirPlaceVar(&mut ctx.lir, scrut_var)
        let value = lirNew(&mut ctx, ty, false, LIR_PAYLOAD, place, enum_id, v)
        let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Var, binding_start, binding_end, ty, ctx.scopes.current_scope, false, false, -1, binding_start, binding_end)
        scopeAddSymbol(&mut ctx.scopes, sym_id)
        semaInitPath(&mut ctx, sym_id, binding_start, binding_end)
        lirSetVal(&mut ctx, value)
        let bind_path = ctx.symbols.symbols[sym_id].move_path
        lirLetBind(&mut ctx, bind_path, ty, false)
        return
    }
    lirMarkUnsupported(&mut ctx.lir, p_start)
}

pub fn semaConstructorField(ctx: &mut SemaContext, source: &Text, tree: &AstTree, decl_id: Int, arg: &AstExpr, ty: Int, seen: &mut List<Bool>, slots: &mut List<Int>) {
    let decl = &tree.declarations[decl_id]
    let field = semaNamedField(source, tree, decl_id, arg)
    if field < 0 || seen[field - decl.c] {
        semaAddError(&mut ctx, "L0004", "campo inválido o duplicado en constructor", arg.start, arg.end)
    } else {
        seen[field - decl.c] = true
        slots[field - decl.c] = lirTakeOperand(&mut ctx, ty)
        let expected = semaFieldType(&mut ctx, source, tree, field)
        if !semTypeEquals(&ctx.types, ty, expected) {
            semaAddError(&mut ctx, "L0004", "tipo incompatible en campo del constructor", arg.start, arg.end)
        }
    }
}

pub fn semaConstructorFinish(ctx: &mut SemaContext, tree: &AstTree, expr: &AstExpr, decl_id: Int, struct_t: Int, seen: &List<Bool>, slots: &List<Int>) {
    let decl = &tree.declarations[decl_id]
    for i in 0..decl.d {
        if !seen[i] {
            semaAddError(&mut ctx, "L0004", "el constructor requiere todos sus campos explícitos", expr.start, expr.end)
            return
        }
    }
    let first = lirSequence(&mut ctx, slots)
    // Preserve slot order and register the completed struct only afterward.
    let struct_index = ctx.lir_struct_index[decl_id]
    let value = lirNew(&mut ctx, struct_t, false, LIR_STRUCT, struct_index, first, slots.length)
    lirSetVal(&mut ctx, value)
}

pub fn semaEnumField(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr: &AstExpr) -> Int {
    if expr.a < 0 || expr.a >= tree.expressions.length { return -1 }
    match tree.expressions[expr.a].kind {
        AstExprKind.Name => {}
        _ => { return -1 }
    }
    let base_expr = &tree.expressions[expr.a]
    let sym_id = semaLookupVisible(&mut ctx, source, base_expr.start, base_expr.end)
    if sym_id < 0 { return -1 }
    match ctx.symbols.symbols[sym_id].kind {
        SymbolKind.Enum => {}
        _ => { return -1 }
    }
    let decl_id = ctx.symbols.symbols[sym_id].decl_id
    if decl_id >= 0 && decl_id < tree.declarations.length {
        let decl = &tree.declarations[decl_id]
        for v in 0..decl.d {
            let variant = &tree.variants[decl.c + v]
            if symbolNamesEqual(source, variant.name_start, variant.name_end, expr.b, expr.c) {
                let ty = ctx.symbols.symbols[sym_id].type_id
                var enum_id = -1
                for k in 0..ctx.lir_module.en_decl.length {
                    if ctx.lir_module.en_decl[k] == decl_id { enum_id = k }
                }
                if enum_id < 0 || variant.payload_count > 0 {
                    // Payload variants require typed construction from their
                    // call arguments, not the unit-variant field syntax.
                    lirMarkUnsupported(&mut ctx.lir, expr.start)
                } else {
                    let result = lirNew(&mut ctx, ty, false, LIR_VARIANT, enum_id, v, LIR_NONE)
                    lirSetVal(&mut ctx, result)
                }
                return ty
            }
        }
    }
    semaAddError(&mut ctx, "L0001", "variante de enum no encontrada", expr.start, expr.end)
    return 7
}
