take ast
take sema_types
take flow_cfg
take sema_context
take sema_drop
take lir_build
take sema_lower
take stmt_lower
take lir_builtin_union

// Lower Option<T>? and Result<T, E>? with the same tagged-union operations as
// `choose`. The empty/error edge returns from the current function; the value
// edge joins with T.
expose flow semaTryUnion(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr: view AstExpr, input_t: Int, input_path: Int, input_place: Int, mode: Int) => Int {
    when mode == ACCESS_PLACE {
        semaAddError(edit ctx, "L0016", "el operador ? produce un valor y no puede usarse como destino", expr.start, expr.end)
        give 7
    }

    when input_t < 0 || input_t >= ctx.types.types.length {
        lirDiscard(edit ctx)
        give 7
    }
    hold input_kind = view ctx.types.types[input_t].kind
    change input_is_result = false
    change input_is_option = false
    choose input_kind {
        SemTypeKind.Result : { input_is_result = true }
        SemTypeKind.Option : { input_is_option = true }
        _ : {}
    }
    when !input_is_result && !input_is_option {
        semaAddError(edit ctx, "L0003", "el operador ? requiere Option o Result", expr.start, expr.end)
        lirDiscard(edit ctx)
        give 7
    }
    hold return_t = ctx.current_fn_ret_type
    when return_t < 0 || return_t >= ctx.types.types.length {
        semaAddError(edit ctx, "L0003", "el operador ? requiere que la función devuelva Option o Result", expr.start, expr.end)
        lirDiscard(edit ctx)
        give 7
    }
    change return_is_result = false
    change return_is_option = false
    choose ctx.types.types[return_t].kind {
        SemTypeKind.Result : { return_is_result = true }
        SemTypeKind.Option : { return_is_option = true }
        _ : {}
    }
    when (input_is_result && !return_is_result) || (input_is_option && !return_is_option) {
        semaAddError(edit ctx, "L0003", "el operador ? requiere que la función devuelva el mismo tipo de unión que la expresión", expr.start, expr.end)
        lirDiscard(edit ctx)
        give 7
    }

    hold input_ok_t = ctx.types.types[input_t].elem_type
    hold input_err_t = ctx.types.types[input_t].nominal_id
    hold return_err_t = ctx.types.types[return_t].nominal_id
    when input_is_result && !semTypeEquals(view ctx.types, input_err_t, return_err_t) {
        semaAddError(edit ctx, "L0003", "el tipo de error de ? debe coincidir con el Result de retorno", expr.start, expr.end)
        lirDiscard(edit ctx)
        give 7
    }
    when !lirBuiltinSupported(view ctx.types, view ctx.lir_module, input_t) || !lirBuiltinSupported(view ctx.types, view ctx.lir_module, return_t) {
        lirMarkUnsupported(edit ctx.lir, expr.start)
        lirDiscard(edit ctx)
        give 7
    }
    hold input_enum = lirBuiltinRegister(edit ctx.lir_module, view ctx.types, input_t)
    hold return_enum = lirBuiltinRegister(edit ctx.lir_module, view ctx.types, return_t)
    when input_enum < 0 || return_enum < 0 {
        lirMarkUnsupported(edit ctx.lir, expr.start)
        lirDiscard(edit ctx)
        give 7
    }

    // The union is consumed on both branches. A temporary gets an explicit
    // move path so its active payload is never dropped after extraction.
    hold input_var = lirMatchScrutVar(edit ctx, input_t)
    hold input_owned = semaNeedsDrop(edit ctx, source, tree, input_t)
    change scrut_path = input_path
    when input_owned && input_place >= 0 {
        when ctx.lir.places[input_place].parent >= 0 || ctx.lir.vars[ctx.lir.places[input_place].root].is_ref {
            lirMarkUnsupported(edit ctx.lir, expr.start)
        }
    }
    when input_owned && input_path < 0 && input_place < 0 {
        scrut_path = semaOwnScrutinee(edit ctx, source, tree, input_var, input_t, expr.start, expr.end)
    }

    hold scrut_place = lirPlaceVar(edit ctx.lir, input_var)
    hold tag = lirNew(edit ctx, 1, false, LIR_DISC, scrut_place, 0, 0)
    change success_variant = 0
    change failure_variant = 1
    change success_tag = 0
    when input_is_option {
        success_variant = 1
        failure_variant = 0
        success_tag = 1
    }
    hold ok_tag = lirConst(edit ctx.lir, LIR_CONST_INT, success_tag, 0, 0)
    hold is_ok = lirNew(edit ctx, 4, false, LIR_BINARY, LIR_EQ, tag, ok_tag)
    hold ok_block = flowBlock(edit ctx.flow)
    hold err_block = flowBlock(edit ctx.flow)
    hold join = flowBlock(edit ctx.flow)
    ctx.lir.val = is_ok
    ctx.lir.place = -1
    lirCondition(edit ctx)
    flowLink(edit ctx.flow, ok_block, err_block)

    ctx.flow.current = err_block
    change propagated = LIR_NONE
    when input_is_result {
        hold err_payload = lirNew(edit ctx, input_err_t, false, LIR_PAYLOAD, scrut_place, input_enum, failure_variant)
        when scrut_path >= 0 {
            when !input_owned || lirBuiltinPayloadOwned(view ctx.types, view ctx.lir_module, input_err_t) {
                semaAccess(edit ctx, scrut_path, input_t, ACCESS_MOVE, expr.start, expr.end)
            } otherwise {
                flowEvent(edit ctx.flow, FLOW_DROP, scrut_path, expr.start, expr.end)
            }
        }
        propagated = lirNew(edit ctx, return_t, false, LIR_VARIANT, return_enum, failure_variant, err_payload)
    } otherwise {
        when scrut_path >= 0 {
            when input_owned { flowEvent(edit ctx.flow, FLOW_DROP, scrut_path, expr.start, expr.end) }
            otherwise { semaAccess(edit ctx, scrut_path, input_t, ACCESS_MOVE, expr.start, expr.end) }
        }
        propagated = lirNew(edit ctx, return_t, false, LIR_VARIANT, return_enum, failure_variant, LIR_NONE)
    }
    semaFlushTemps(edit ctx, expr.start, expr.end)
    semaDropFrom(edit ctx, 0, expr.start, expr.end)
    lirReturnAt(edit ctx, propagated, false)
    flowReturn(edit ctx.flow)

    ctx.flow.current = ok_block
    hold ok_payload = lirNew(edit ctx, input_ok_t, false, LIR_PAYLOAD, scrut_place, input_enum, success_variant)
    when scrut_path >= 0 {
        when !input_owned || lirBuiltinPayloadOwned(view ctx.types, view ctx.lir_module, input_ok_t) {
            semaAccess(edit ctx, scrut_path, input_t, ACCESS_MOVE, expr.start, expr.end)
        } otherwise {
            flowEvent(edit ctx.flow, FLOW_DROP, scrut_path, expr.start, expr.end)
        }
    }
    flowLink(edit ctx.flow, join, -1)
    ctx.flow.current = join
    lirSetVal(edit ctx, ok_payload)
    when semaNeedsDrop(edit ctx, source, tree, input_ok_t) {
        hold temp_mark = ctx.pending_temps.length
        semaTemp(edit ctx, source, tree, input_ok_t, expr.start, expr.end)
        when ctx.pending_temps.length > temp_mark {
            hold path = ctx.pending_temps[ctx.pending_temps.length - 1]
            semaAccess(edit ctx, path, input_ok_t, mode, expr.start, expr.end)
        }
    }
    give input_ok_t
}
