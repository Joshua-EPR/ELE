take tokens
take ast
take sema_types
take symbols
take scopes
take flow_cfg
take loans_l
take lir_build
take sema_context
take sema_lower
take lir_builtin_union

// Locate a postfix operator between its base expression and the following
// index or method name. The AST keeps these expression spans but not the
// punctuation token itself.
flow semaPostfixOperator(source: view Text, start: Int, end: Int, symbol: Int) => Int {
    change at = start
    during at < end {
        when source@byteAt(at) == symbol { give at }
        at += 1
    }
    give -1
}

expose flow semaExpectedListElem(ctx: view SemaContext) => Int {
    hold expected = ctx.expected_list_type
    when expected >= 0 && expected < ctx.types.types.length {
        choose ctx.types.types[expected].kind {
            SemTypeKind.List : { give ctx.types.types[expected].elem_type }
            _ : {}
        }
    }
    give 0
}

expose flow semaFinishCollectionLit(ctx: edit SemaContext, expr: view AstExpr, is_array: Bool, elem_t: Int, elements: view List of[Int]) => Int {
    when semaRejectLinearElem(edit ctx, elem_t, expr.start, expr.end) { give 7 }
    when is_array {
        lirMarkUnsupported(edit ctx.lir, expr.start)
        give semTypeMakeArray(edit ctx.types, elem_t)
    }
    hold list_t = semTypeMakeList(edit ctx.types, elem_t)
    when elem_t <= 0 {
        lirMarkUnsupported(edit ctx.lir, expr.start)
        give list_t
    }
    hold list_index = lirListRegister(edit ctx.lir_module, elem_t)
    hold first = lirSequence(edit ctx, elements)
    // Preserve literal element order while ending the nested mutable borrow.
    hold value = lirNew(edit ctx, list_t, false, LIR_LIST_LIT, list_index, first, elements.length)
    lirSetVal(edit ctx, value)
    give list_t
}

flow semaMethodMutable(ctx: edit SemaContext, base_t: Int, base_path: Int, start: Int, end: Int) => Bool {
    when semaRefElem(ctx, base_t) >= 0 && !semaIsMutRef(ctx, base_t) {
        semaAddError(edit ctx, "L0001", "el método requiere un receptor mutable", start, end)
        give false
    }
    when base_path >= 0 {
        hold loan = loanOfPath(view ctx.flow, base_path)
        when loan >= 0 {
            when !loanIsMut(view ctx.flow, loan) {
                semaAddError(edit ctx, "L0001", "el método requiere un préstamo mutable", start, end)
                give false
            }
        } otherwise {
            hold sym = ctx.flow.paths[base_path].symbol
            when sym < 0 || !ctx.symbols.symbols[sym].is_mut {
                semaAddError(edit ctx, "L0006", "el método requiere una variable mutable", start, end)
                give false
            }
        }
    }
    give true
}

expose flow semaMethodFinish(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, base_t: Int, bp: Int, base_path: Int, count: Int, arg_t: Int, arg_op: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    change base_place = bp
    when base_place < 0 {
        hold h = lirValueVar(edit ctx, base_t)
        when h >= 0 { base_place = lirPlaceVar(edit ctx.lir, h) }
    }
    change inner_t = base_t
    hold ref_t = semaRefElem(ctx, base_t)
    when ref_t >= 0 { inner_t = ref_t }
    change elem_t = 0
    when inner_t >= 0 && inner_t < ctx.types.types.length {
        elem_t = ctx.types.types[inner_t].elem_type
    }
    hold name_push = "push"
    hold name_pop = "pop"
    hold name_reserve = "reserve"
    hold name_byte_at = "byteAt"
    when symbolNameEqualsText(source, expr.b, expr.c, name_push) {
        when inner_t < 0 || inner_t >= ctx.types.types.length || count != 1 || !semTypeEquals(view ctx.types, arg_t, elem_t) {
            semaAddError(edit ctx, "L0003", "push requiere List<T> y un argumento T", expr.start, expr.end)
            give 7
        }
        choose ctx.types.types[inner_t].kind {
            SemTypeKind.List : {}
            _ : { semaAddError(edit ctx, "L0003", "push requiere List<T>", expr.start, expr.end); give 7 }
        }
        when !semaMethodMutable(edit ctx, base_t, base_path, expr.start, expr.end) { give 7 }
        when base_path >= 0 { flowEvent(edit ctx.flow, FLOW_MUTATE, base_path, expr.start, expr.end) }
        when base_place >= 0 { lirAt(edit ctx, LIR_LIST_PUSH, -1, base_place, arg_op, 0) }
        // A separate statement ends the mutable loan of ctx.lir before lirSetVal.
        hold unit_value = lirConst(edit ctx.lir, LIR_CONST_UNIT, 0, 0, 0)
        lirSetVal(edit ctx, unit_value)
        give 6
    }
    when symbolNameEqualsText(source, expr.b, expr.c, name_pop) {
        when inner_t < 0 || inner_t >= ctx.types.types.length || count != 0 {
            semaAddError(edit ctx, "L0003", "pop requiere List<T> sin argumentos", expr.start, expr.end)
            give 7
        }
        choose ctx.types.types[inner_t].kind {
            SemTypeKind.List : {}
            _ : { semaAddError(edit ctx, "L0003", "pop requiere List<T>", expr.start, expr.end); give 7 }
        }
        when !semaMethodMutable(edit ctx, base_t, base_path, expr.start, expr.end) { give 7 }
        hold opt_t = semTypeMakeOption(edit ctx.types, elem_t)
        hold enum_id = lirBuiltinRegister(edit ctx.lir_module, view ctx.types, opt_t)
        when enum_id < 0 {
            lirMarkUnsupported(edit ctx.lir, expr.start)
        }
        hold dst = lirVar(edit ctx.lir, opt_t, false)
        when base_path >= 0 { flowEvent(edit ctx.flow, FLOW_MUTATE, base_path, expr.start, expr.end) }
        when base_place >= 0 { lirAt(edit ctx, LIR_LIST_POP, dst, base_place, 0, 0) }
        lirSetVal(edit ctx, dst)
        give opt_t
    }
    when symbolNameEqualsText(source, expr.b, expr.c, name_reserve) {
        when inner_t < 0 || inner_t >= ctx.types.types.length || count != 1 || arg_t != 1 {
            semaAddError(edit ctx, "L0003", "reserve requiere List<T> y un argumento Int", expr.start, expr.end)
            give 7
        }
        choose ctx.types.types[inner_t].kind {
            SemTypeKind.List : {}
            _ : { semaAddError(edit ctx, "L0003", "reserve requiere List<T>", expr.start, expr.end); give 7 }
        }
        when !semaMethodMutable(edit ctx, base_t, base_path, expr.start, expr.end) { give 7 }
        when base_path >= 0 { flowEvent(edit ctx.flow, FLOW_MUTATE, base_path, expr.start, expr.end) }
        when base_place >= 0 { lirAt(edit ctx, LIR_LIST_RESERVE, -1, base_place, arg_op, 0) }
        // A separate statement ends the mutable loan of ctx.lir before lirSetVal.
        hold unit_value = lirConst(edit ctx.lir, LIR_CONST_UNIT, 0, 0, 0)
        lirSetVal(edit ctx, unit_value)
        give 6
    }
    when symbolNameEqualsText(source, expr.b, expr.c, name_byte_at) {
        when inner_t != 5 || count != 1 || arg_t != 1 {
            semaAddError(edit ctx, "L0003", "byteAt requiere Text y un argumento Int", expr.start, expr.end)
            give 7
        }
        when base_path >= 0 { flowEvent(edit ctx.flow, FLOW_READ, base_path, expr.start, expr.end) }
        hold dst = lirVar(edit ctx.lir, 1, false)
        when base_place >= 0 {
            hold base_expr = view tree.expressions[expr.a]
            change operator_at = semaPostfixOperator(source, base_expr.end, expr.b, 64)
            when operator_at < 0 { operator_at = semaPostfixOperator(source, base_expr.end, expr.b, 46) }
            hold outer_at = ctx.lir.at
            when operator_at >= 0 { ctx.lir.at = operator_at }
            lirAt(edit ctx, LIR_BYTE_AT, dst, base_place, arg_op, 0)
            ctx.lir.at = outer_at
        }
        lirSetVal(edit ctx, dst)
        give 1
    }
    semaAddError(edit ctx, "L0001", "método no encontrado", expr.b, expr.c)
    give 7
}

expose flow semaIndexFinish(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, mode: Int, base_t: Int, bp: Int, parent_path: Int, idx_t: Int, idx_op: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    hold base_expr = view tree.expressions[expr.a]
    hold index_expr = view tree.expressions[expr.b]
    hold bounds_at = semaPostfixOperator(source, base_expr.end, index_expr.start, 91)
    when idx_t != 1 {
        semaAddError(edit ctx, "L0003", "el índice debe ser Int", expr.start, expr.end)
        give 7
    }
    change base_place = bp
    when base_place < 0 {
        hold holder = lirValueVar(edit ctx, base_t)
        when holder >= 0 { base_place = lirPlaceVar(edit ctx.lir, holder) }
    }
    change idx_var = idx_op
    when !lirIsVar(idx_op) {
        hold v = lirVar(edit ctx.lir, 1, false)
        lirAt(edit ctx, LIR_USE, v, idx_op, 0, 0)
        idx_var = v
    }
    change elem_t = 0
    change unwrapped = base_t
    hold referent = semaRefElem(ctx, base_t)
    when referent >= 0 { unwrapped = referent }
    when unwrapped >= 0 && unwrapped < ctx.types.types.length {
        hold bt = view ctx.types.types[unwrapped]
        choose bt.kind {
            SemTypeKind.List : { elem_t = bt.elem_type }
            SemTypeKind.Array : { elem_t = bt.elem_type }
            SemTypeKind.Slice : { elem_t = bt.elem_type }
            _ : {
                semaAddError(edit ctx, "L0003", "el tipo no admite indexación", expr.start, expr.end)
                give 7
            }
        }
    }
    when elem_t > 0 && elem_t < ctx.types.types.length {
        hold element = view ctx.types.types[elem_t]
        when mode == ACCESS_MOVE && semTypeIsMove(element.kind) {
            semaAddError(edit ctx, "L0005", "no se puede mover un elemento fuera de una colección", expr.start, expr.end)
            give 7
        }
    }
    when parent_path >= 0 {
        ctx.expression_path = parent_path
        semaAccess(edit ctx, parent_path, elem_t, mode, expr.start, expr.end)
    }
    when base_place >= 0 {
        change indexed_place = -1
        when bounds_at < 0 {
            indexed_place = lirPlaceIndex(edit ctx.lir, base_place, idx_var)
        } otherwise {
            indexed_place = lirPlaceIndexAt(edit ctx.lir, base_place, idx_var, bounds_at)
        }
        lirSetPlace(edit ctx, indexed_place)
        when mode != ACCESS_PLACE && elem_t >= 0 && elem_t < ctx.types.types.length {
            hold element = view ctx.types.types[elem_t]
            when semTypeIsCopy(element.kind) {
                hold val_var = lirVar(edit ctx.lir, elem_t, false)
                lirAt(edit ctx, LIR_READ, val_var, indexed_place, 0, 0)
                lirSetVal(edit ctx, val_var)
            }
        }
    }
    give elem_t
}

