import tokens
import ast
import sema_types
import symbols
import scopes
import flow_cfg
import loans_l
import sema_context
import sema_borrow
import sema_drop
import lir_build
import sema_lower
import stmt_lower
import sema_expr
import sema_match_coverage
import sema_loop_jump

fn semaCheckMatch(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int) {
    let expr = &tree.expressions[expr_id]
    let scrut_e = expr.a
    let first_arm = expr.b
    let arm_count = expr.c
    let scrut_t = semaExprMode(&mut ctx, source, tree, scrut_e, ACCESS_READ)
    var enum_covered = false
    if scrut_t >= 0 && scrut_t < ctx.types.types.length {
        match ctx.types.types[scrut_t].kind {
            SemTypeKind.Option => { lirMarkUnsupported(&mut ctx.lir, expr.start) }
            SemTypeKind.Result => { lirMarkUnsupported(&mut ctx.lir, expr.start) }
            SemTypeKind.Enum => {
                let nominal = ctx.types.types[scrut_t].nominal_id
                enum_covered = semaEnumMatchCovered(&mut ctx, source, tree, expr, nominal)
                if nominal >= 0 && nominal < tree.declarations.length {
                    let decl = &tree.declarations[nominal]
                    for v in decl.c..(decl.c + decl.d) {
                        let variant = &tree.variants[v]
                        if variant.payload_count > 1 { lirMarkUnsupported(&mut ctx.lir, expr.start) }
                        if variant.payload_count == 1 {
                            let ty = semaResolveAstType(&mut ctx, source, tree, tree.extra[variant.first_payload_index])
                            if ty != 1 && ty != 4 { lirMarkUnsupported(&mut ctx.lir, expr.start) }
                        }
                    }
                }
            }
            _ => {}
        }
    }
    let scrut_var = lirMatchScrutVar(&mut ctx, scrut_t)
    let join = flowBlock(&mut ctx.flow)

    for i in 0..arm_count {
        let p_start = tree.extra[first_arm + 3 * i]
        let p_end = tree.extra[first_arm + 3 * i + 1]
        let body_stmt = tree.extra[first_arm + 3 * i + 2]
        let arm_body = flowBlock(&mut ctx.flow)
        let next_test = flowBlock(&mut ctx.flow)
        let is_wildcard = lirMatchArmTest(&mut ctx, source, tree, p_start, p_end, scrut_var, scrut_t, arm_body, next_test, i == arm_count - 1 && enum_covered)
        ctx.flow.current = arm_body
        scopePush(&mut ctx.scopes)
        semaScopeEnter(&mut ctx)
        lirMatchArmBind(&mut ctx, source, tree, p_start, p_end, scrut_var, scrut_t)
        if body_stmt >= 0 { semaCheckStmt(&mut ctx, source, tree, body_stmt) }
        semaScopeExit(&mut ctx, p_end, p_end)
        scopePop(&mut ctx.scopes)
        flowLink(&mut ctx.flow, join, -1)
        if is_wildcard { break }
        ctx.flow.current = next_test
    }
    ctx.flow.current = join
}

fn semaCheckStmt(ctx: &mut SemaContext, source: &Text, tree: &AstTree, stmt_id: Int) -> Int {
    if stmt_id < 0 || stmt_id >= tree.statements.length {
        return 0
    }
    let stmt = &tree.statements[stmt_id]
    ctx.lir.at = stmt.start
    match stmt.kind {
        AstStmtKind.Let => {
            let is_mut = stmt.c == 1
            let annot_t = stmt.d
            let val_e = stmt.e
            let existing = scopeLookupCurrent(&ctx.scopes, &ctx.symbols, source, stmt.a, stmt.b)
            if existing >= 0 {
                semaAddError(&mut ctx, "L0002", "variable duplicada en el mismo ámbito", stmt.start, stmt.end)
                return 0
            }
            ctx.borrow_site = SITE_LET
            if is_mut { ctx.borrow_site = SITE_VAR }
            ctx.pending_loan = -1
            ctx.expected_list_type = -1
            if annot_t >= 0 && val_e >= 0 && val_e < tree.expressions.length {
                match tree.expressions[val_e].kind {
                    AstExprKind.ListLit => { ctx.expected_list_type = semaResolveAstType(&mut ctx, source, tree, annot_t) }
                    _ => {}
                }
            }
            var val_type = semaExprMode(&mut ctx, source, tree, val_e, ACCESS_MOVE)
            ctx.expected_list_type = -1
            let loan = ctx.pending_loan
            ctx.pending_loan = -1
            if annot_t >= 0 {
                let expected = semaResolveAstType(&mut ctx, source, tree, annot_t)
                if loan >= 0 && !semTypeEquals(&ctx.types, val_type, expected) {
                    match tree.expressions[val_e].kind {
                        AstExprKind.Call => {
                            semaAddError(&mut ctx, "L0013", "el resultado prestado requiere let y una anotación de referencia compatible", stmt.start, stmt.end)
                        }
                        _ => {
                            semaAddError(&mut ctx, "L0012", "la anotación debe coincidir con el modo & o &mut del préstamo", stmt.start, stmt.end)
                        }
                    }
                } else if semaRefElem(ctx, expected) >= 0 && loan < 0 {
                    semaAddError(&mut ctx, "L0012", "una referencia local se inicializa con un préstamo de un lugar", stmt.start, stmt.end)
                } else if !semTypeEquals(&ctx.types, val_type, expected) {
                    let exp_n = semTypeName(&ctx.types, source, expected)
                    let act_n = semTypeName(&ctx.types, source, val_type)
                    semaAddError(&mut ctx, "L0003", "discrepancia de tipos en 'let': esperado '{exp_n}', recibido '{act_n}'", stmt.start, stmt.end)
                } else {
                    val_type = expected
                }
            }
            let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Var, stmt.a, stmt.b, val_type, ctx.scopes.current_scope, is_mut, false, -1, stmt.start, stmt.end)
            scopeAddSymbol(&mut ctx.scopes, sym_id)
            semaInitPath(&mut ctx, sym_id, stmt.start, stmt.end)
            let own_path = ctx.symbols.symbols[sym_id].move_path
            lirLetBind(&mut ctx, own_path, val_type, loan >= 0)
            if loan >= 0 {
                loanBind(&mut ctx.flow, own_path, loan)
                semaOrigin(&mut ctx, own_path, semaValueOrigin(source, tree, val_e))
            } else {
                semaOwn(&mut ctx, source, tree, own_path, val_type, semaValueOrigin(source, tree, val_e))
            }
            semaFlushTemps(&mut ctx, stmt.start, stmt.end)
        }
        AstStmtKind.Assign => {
            let target_e = stmt.a
            let val_e = stmt.d
            var indexed = false
            if target_e >= 0 && target_e < tree.expressions.length {
                match tree.expressions[target_e].kind {
                    AstExprKind.Index => { indexed = true }
                    _ => {}
                }
            }
            var target_t = semaExprMode(&mut ctx, source, tree, target_e, ACCESS_PLACE)
            let target = ctx.expression_path
            let target_place = ctx.lir.place
            lirDiscard(&mut ctx)
            let referent = semaRefElem(ctx, target_t)
            if referent >= 0 { target_t = referent }
            if indexed && semaNeedsDrop(&mut ctx, source, tree, target_t) {
                semaAddError(&mut ctx, "L0016", "reemplazo de elemento propietario aún no verificado", stmt.start, stmt.end)
            }
            if target < 0 {
                semaAddError(&mut ctx, "L0016", "destino de asignación no verificado", stmt.start, stmt.end)
            } else {
                let sym = ctx.flow.paths[target].symbol
                let loan = loanOfPath(&ctx.flow, target)
                if loan >= 0 {
                    // Writing through a reference binding requires &mut.
                    if !loanIsMut(&ctx.flow, loan) {
                        semaAddError(&mut ctx, "L0001", "no se puede mutar a través de una referencia inmutable &T", stmt.start, stmt.end)
                    }
                } else if !ctx.symbols.symbols[sym].is_mut {
                    semaAddError(&mut ctx, "L0006", "no se puede reasignar a variable inmutable", stmt.start, stmt.end)
                }
                if stmt.c - stmt.b > 1 {
                    flowEvent(&mut ctx.flow, FLOW_READ, target, stmt.start, stmt.end)
                    let ty = &ctx.types.types[target_t]
                    if !semTypeIsNumeric(ty.kind) {
                        semaAddError(&mut ctx, "L0003", "asignación compuesta requiere tipo numérico", stmt.start, stmt.end)
                    }
                }
            }
            let val_t = semaExprMode(&mut ctx, source, tree, val_e, ACCESS_MOVE)
            let value = lirTakeOperand(&mut ctx, val_t)
            if target >= 0 && loanOfPath(&ctx.flow, target) >= 0 && semaNeedsDrop(&mut ctx, source, tree, target_t) {
                // The old referent value is released before the write.
                flowEventData(&mut ctx.flow, FLOW_DROP_REF, target, stmt.start, stmt.end, target_t)
            }
            if indexed {
                flowEvent(&mut ctx.flow, FLOW_MUTATE, target, stmt.start, stmt.end)
            } else {
                flowEvent(&mut ctx.flow, FLOW_WRITE, target, stmt.start, stmt.end)
            }
            lirAssign(&mut ctx, source, target_place, value, target_t, stmt.b, stmt.c)
            semaFlushTemps(&mut ctx, stmt.start, stmt.end)
            if !semTypeEquals(&ctx.types, target_t, val_t) {
                let exp_n = semTypeName(&ctx.types, source, target_t)
                let act_n = semTypeName(&ctx.types, source, val_t)
                semaAddError(&mut ctx, "L0003", "discrepancia de tipos en asignación: esperado '{exp_n}', recibido '{act_n}'", stmt.start, stmt.end)
            }
        }
        AstStmtKind.Return => {
            let val_e = stmt.a
            var ret_t = 6
            let borrowed = semaRefElem(ctx, ctx.current_fn_ret_type) >= 0
            ctx.pending_loan = -1
            if val_e >= 0 {
                if borrowed { ctx.borrow_site = SITE_RETURN }
                ret_t = semaExprMode(&mut ctx, source, tree, val_e, ACCESS_MOVE)
            }
            let loan = ctx.pending_loan
            ctx.pending_loan = -1
            var value = LIR_NONE
            if val_e >= 0 { value = lirTakeOperand(&mut ctx, ret_t) }
            // Leaving the function: temporaries, then every owned binding.
            semaFlushTemps(&mut ctx, stmt.start, stmt.end)
            semaDropFrom(&mut ctx, 0, stmt.start, stmt.end)
            lirReturnAt(&mut ctx, value, borrowed)
            flowReturn(&mut ctx.flow)
            if borrowed {
                semaReturnBorrow(&mut ctx, ret_t, loan, stmt.start, stmt.end)
            } else if !semTypeEquals(&ctx.types, ret_t, ctx.current_fn_ret_type) {
                let exp_n = semTypeName(&ctx.types, source, ctx.current_fn_ret_type)
                let act_n = semTypeName(&ctx.types, source, ret_t)
                semaAddError(&mut ctx, "L0003", "tipo de retorno incompatible: esperado '{exp_n}', recibido '{act_n}'", stmt.start, stmt.end)
            }
        }
        AstStmtKind.If => {
            let cond_t = semaCheckExpr(&mut ctx, source, tree, stmt.a)
            if !semTypeEquals(&ctx.types, cond_t, 4) {
                semaAddError(&mut ctx, "L0003", "la condición del 'if' debe ser de tipo Bool", stmt.start, stmt.end)
            }
            lirCondition(&mut ctx)
            semaFlushTemps(&mut ctx, stmt.start, stmt.end)
            let then_block = flowBlock(&mut ctx.flow)
            let else_block = flowBlock(&mut ctx.flow)
            let join = flowBlock(&mut ctx.flow)
            flowLink(&mut ctx.flow, then_block, else_block)
            ctx.flow.current = then_block
            if stmt.b >= 0 {
                semaCheckStmt(&mut ctx, source, tree, stmt.b)
            }
            flowLink(&mut ctx.flow, join, -1)
            ctx.flow.current = else_block
            if stmt.c >= 0 {
                semaCheckStmt(&mut ctx, source, tree, stmt.c)
            }
            flowLink(&mut ctx.flow, join, -1)
            ctx.flow.current = join
        }
        AstStmtKind.While => {
            let outer_mark = ctx.loop_mark
            ctx.loop_mark = ctx.owned_locals.length
            let loop_header = flowLoopStart(&mut ctx.flow)
            let cond_t = semaCheckExpr(&mut ctx, source, tree, stmt.a)
            if !semTypeEquals(&ctx.types, cond_t, 4) {
                semaAddError(&mut ctx, "L0003", "la condición del 'while' debe ser de tipo Bool", stmt.start, stmt.end)
            }
            lirCondition(&mut ctx)
            semaFlushTemps(&mut ctx, stmt.start, stmt.end)
            flowLoopBody(&mut ctx.flow, loop_header, true)
            semaCheckStmt(&mut ctx, source, tree, stmt.b)
            flowLoopEnd(&mut ctx.flow, loop_header)
            ctx.loop_mark = outer_mark
        }
        AstStmtKind.For => {
            let start_t = semaCheckExpr(&mut ctx, source, tree, stmt.c)
            let start_v = lirTakeOperand(&mut ctx, 1)
            let end_t = semaCheckExpr(&mut ctx, source, tree, stmt.d)
            let counter = lirForInit(&mut ctx, start_v, lirTakeOperand(&mut ctx, 1))
            if !semTypeEquals(&ctx.types, start_t, 1) || !semTypeEquals(&ctx.types, end_t, 1) {
                semaAddError(&mut ctx, "L0003", "el rango del bucle 'for' debe ser de tipo Int", stmt.start, stmt.end)
            }
            let outer_mark = ctx.loop_mark
            ctx.loop_mark = ctx.owned_locals.length
            let loop_header = flowLoopStart(&mut ctx.flow)
            lirForTest(&mut ctx, counter)
            flowLoopBody(&mut ctx.flow, loop_header, true)
            // `continue` goes to the step block, which increments.
            let step = flowBlock(&mut ctx.flow)
            ctx.flow.continue_to = step
            scopePush(&mut ctx.scopes)
            semaScopeEnter(&mut ctx)
            let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Var, stmt.a, stmt.b, 1, ctx.scopes.current_scope, false, false, -1, stmt.a, stmt.b)
            scopeAddSymbol(&mut ctx.scopes, sym_id)
            semaInitPath(&mut ctx, sym_id, stmt.a, stmt.b)
            ctx.lir.val = counter
            lirLetBind(&mut ctx, ctx.symbols.symbols[sym_id].move_path, 1, false)
            let body_stmt = tree.extra[stmt.e + 1]
            if body_stmt >= 0 {
                semaCheckStmt(&mut ctx, source, tree, body_stmt)
            }
            semaScopeExit(&mut ctx, stmt.end, stmt.end)
            scopePop(&mut ctx.scopes)
            flowLink(&mut ctx.flow, step, -1)
            ctx.flow.current = step
            lirForStep(&mut ctx, counter)
            flowLoopEnd(&mut ctx.flow, loop_header)
            ctx.loop_mark = outer_mark
        }
        AstStmtKind.ForEach => {
            let col_e = stmt.c
            let col_t = semaExprMode(&mut ctx, source, tree, col_e, ACCESS_PLACE)
            var col_place = ctx.lir.place
            if col_place < 0 {
                let holder = lirValueVar(&mut ctx, col_t)
                if holder >= 0 { col_place = lirPlaceVar(&mut ctx.lir, holder) }
            }
            var elem_t = 0
            var unwrapped = col_t
            let referent = semaRefElem(ctx, col_t)
            if referent >= 0 { unwrapped = referent }
            if unwrapped >= 0 && unwrapped < ctx.types.types.length {
                let bt = &ctx.types.types[unwrapped]
                match bt.kind {
                    SemTypeKind.List => { elem_t = bt.elem_type }
                    SemTypeKind.Array => { elem_t = bt.elem_type }
                    SemTypeKind.Slice => { elem_t = bt.elem_type }
                    _ => {
                        semaAddError(&mut ctx, "L0003", "el bucle for-in requiere una colección", stmt.start, stmt.end)
                    }
                }
            }
            let len_dst = lirVar(&mut ctx.lir, 1, false)
            if col_place >= 0 {
                lirAt(&mut ctx, LIR_LEN, len_dst, col_place, 0, 0)
            }
            let start_v = lirConst(&mut ctx.lir, LIR_CONST_INT, 0, 0, 0)
            let counter = lirForInit(&mut ctx, start_v, len_dst)
            let outer_mark = ctx.loop_mark
            ctx.loop_mark = ctx.owned_locals.length
            let loop_header = flowLoopStart(&mut ctx.flow)
            lirForTest(&mut ctx, counter)
            flowLoopBody(&mut ctx.flow, loop_header, true)
            let step = flowBlock(&mut ctx.flow)
            ctx.flow.continue_to = step
            scopePush(&mut ctx.scopes)
            semaScopeEnter(&mut ctx)
            let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Var, stmt.a, stmt.b, elem_t, ctx.scopes.current_scope, false, false, -1, stmt.a, stmt.b)
            scopeAddSymbol(&mut ctx.scopes, sym_id)
            semaInitPath(&mut ctx, sym_id, stmt.a, stmt.b)

            if col_place >= 0 {
                let elem_place = lirPlaceIndex(&mut ctx.lir, col_place, counter)
                let elem_var = lirVar(&mut ctx.lir, elem_t, false)
                lirAt(&mut ctx, LIR_READ, elem_var, elem_place, 0, 0)
                ctx.lir.val = elem_var
            }
            lirLetBind(&mut ctx, ctx.symbols.symbols[sym_id].move_path, elem_t, false)
            let body_stmt = stmt.d
            if body_stmt >= 0 {
                semaCheckStmt(&mut ctx, source, tree, body_stmt)
            }
            semaScopeExit(&mut ctx, stmt.end, stmt.end)
            scopePop(&mut ctx.scopes)
            flowLink(&mut ctx.flow, step, -1)
            ctx.flow.current = step
            lirForStep(&mut ctx, counter)
            flowLoopEnd(&mut ctx.flow, loop_header)
            ctx.loop_mark = outer_mark
        }
        AstStmtKind.Loop => {
            let outer_mark = ctx.loop_mark
            ctx.loop_mark = ctx.owned_locals.length
            let loop_header = flowLoopStart(&mut ctx.flow)
            flowLoopBody(&mut ctx.flow, loop_header, false)
            semaCheckStmt(&mut ctx, source, tree, stmt.a)
            flowLoopEnd(&mut ctx.flow, loop_header)
            ctx.loop_mark = outer_mark
        }
        AstStmtKind.Break => {
            if ctx.flow.break_to >= 0 { semaDropFrom(&mut ctx, ctx.loop_mark, stmt.start, stmt.end) }
            semaJumpLoop(&mut ctx, ctx.flow.break_to, stmt.start, stmt.end)
        }
        AstStmtKind.Continue => {
            if ctx.flow.continue_to >= 0 { semaDropFrom(&mut ctx, ctx.loop_mark, stmt.start, stmt.end) }
            semaJumpLoop(&mut ctx, ctx.flow.continue_to, stmt.start, stmt.end)
        }
        AstStmtKind.Block => {
            scopePush(&mut ctx.scopes)
            semaScopeEnter(&mut ctx)
            let first = stmt.a
            let count = stmt.b
            for i in 0..count {
                let sid = tree.extra[first + i]
                semaCheckStmt(&mut ctx, source, tree, sid)
            }
            semaScopeExit(&mut ctx, stmt.end, stmt.end)
            scopePop(&mut ctx.scopes)
        }
        AstStmtKind.Expr => {
            let expr_id = stmt.a
            if expr_id >= 0 && expr_id < tree.expressions.length {
                match tree.expressions[expr_id].kind {
                    AstExprKind.Match => {
                        semaCheckMatch(&mut ctx, source, tree, expr_id)
                        lirDiscard(&mut ctx)
                        semaFlushTemps(&mut ctx, stmt.start, stmt.end)
                        return 0
                    }
                    _ => {}
                }
            }
            let ty = semaCheckExpr(&mut ctx, source, tree, stmt.a)
            if ctx.expression_path < 0 && stmt.a >= 0 {
                // A discarded owned result is a temporary of the statement.
                semaTemp(&mut ctx, source, tree, ty, tree.expressions[stmt.a].start, tree.expressions[stmt.a].end)
            }
            lirDiscard(&mut ctx)
            semaFlushTemps(&mut ctx, stmt.start, stmt.end)
        }
        _ => { semaAddError(&mut ctx, "L0016", "sentencia fuera del subconjunto verificado de Stage 1", stmt.start, stmt.end) }
    }
    return 0
}

