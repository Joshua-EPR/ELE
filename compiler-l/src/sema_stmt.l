take tokens
take ast
take sema_types
take symbols
take scopes
take flow_cfg
take loans_l
take sema_context
take sema_borrow
take sema_drop
take lir_build
take sema_lower
take stmt_lower
take sema_expr
take sema_match_coverage
take lir_builtin_union
take sema_loop_jump
take sema_stmt_values

flow semaCheckMatch(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int) {
    hold expr = view tree.expressions[expr_id]
    hold scrut_e = expr.a
    hold first_arm = expr.b
    hold arm_count = expr.c
    hold scrut_t = semaExprMode(edit ctx, source, tree, scrut_e, ACCESS_READ)
    // Move path of a place scrutinee (-1 for temporaries), consumed when an
    // arm binds a non-Copy payload (lirMatchArmBind).
    change scrut_path = ctx.expression_path
    // An owned union scrutinee must be a directly owned variable: a field
    // projection or a borrowed referent would be copied by `read`, aliasing
    // its owner (L0016, never an unchecked copy).
    hold owned_scrut = semaNeedsDrop(edit ctx, source, tree, scrut_t)
    hold scrut_place = ctx.lir.place
    // A Text scrutinee is only read (length and bytes) by literal tests, so
    // a borrowed or projected place is examined in place, never copied.
    hold text_in_place = scrut_t == 5 && scrut_place >= 0
    when owned_scrut && scrut_place >= 0 && !text_in_place {
        when ctx.lir.places[scrut_place].parent >= 0 || ctx.lir.vars[ctx.lir.places[scrut_place].root].is_ref {
            lirMarkUnsupported(edit ctx.lir, expr.start)
        }
    }
    change match_covered = false
    when scrut_t >= 0 && scrut_t < ctx.types.types.length {
        choose ctx.types.types[scrut_t].kind {
            SemTypeKind.Option : {
                when !lirBuiltinSupported(view ctx.types, view ctx.lir_module, scrut_t) { lirMarkUnsupported(edit ctx.lir, expr.start) }
                match_covered = semaBuiltinMatchCovered(source, tree, expr, false)
            }
            SemTypeKind.Result : {
                when !lirBuiltinSupported(view ctx.types, view ctx.lir_module, scrut_t) { lirMarkUnsupported(edit ctx.lir, expr.start) }
                match_covered = semaBuiltinMatchCovered(source, tree, expr, true)
            }
            SemTypeKind.Enum : {
                hold nominal = ctx.types.types[scrut_t].nominal_id
                match_covered = semaEnumMatchCovered(edit ctx, source, tree, expr, nominal)
                when nominal >= 0 && nominal < tree.declarations.length {
                    hold decl = view tree.declarations[nominal]
                    each v among decl.c..(decl.c + decl.d) {
                        hold variant = view tree.variants[v]
                        when variant.payload_count > 1 { lirMarkUnsupported(edit ctx.lir, expr.start) }
                        when variant.payload_count == 1 {
                            hold ty = semaResolveAstType(edit ctx, source, tree, tree.extra[variant.first_payload_index])
                            when ty != 1 && ty != 4 { lirMarkUnsupported(edit ctx.lir, expr.start) }
                        }
                    }
                }
            }
            _ : {}
        }
        match_covered = match_covered || semaPrimitiveMatchCovered(edit ctx, source, tree, expr, scrut_t)
    }
    change scrut_var = -1
    change text_place = -1
    when text_in_place {
        text_place = scrut_place
        lirDiscard(edit ctx)
    } otherwise {
        scrut_var = lirMatchScrutVar(edit ctx, scrut_t)
    }
    hold join = flowBlock(edit ctx.flow)
    // The scope of an owned temporary scrutinee is the whole match.
    semaScopeEnter(edit ctx)
    when owned_scrut && scrut_path < 0 && scrut_place < 0 {
        scrut_path = semaOwnScrutinee(edit ctx, source, tree, scrut_var, scrut_t, expr.start, expr.end)
    }

    each i among 0..arm_count {
        hold p_start = tree.extra[first_arm + 3 * i]
        hold p_end = tree.extra[first_arm + 3 * i + 1]
        hold body_stmt = tree.extra[first_arm + 3 * i + 2]
        hold arm_body = flowBlock(edit ctx.flow)
        hold next_test = flowBlock(edit ctx.flow)
        hold is_wildcard = lirMatchArmTest(edit ctx, source, tree, p_start, p_end, scrut_var, text_place, scrut_t, arm_body, next_test, i == arm_count - 1 && match_covered)
        ctx.flow.current = arm_body
        scopePush(edit ctx.scopes)
        semaScopeEnter(edit ctx)
        hold frozen_mark = ctx.frozen_symbols.length
        lirMatchArmBind(edit ctx, source, tree, p_start, p_end, scrut_var, scrut_t, scrut_path)
        when body_stmt >= 0 { semaCheckStmt(edit ctx, source, tree, body_stmt) }
        during ctx.frozen_symbols.length > frozen_mark { ctx.frozen_symbols@pop() }
        semaScopeExit(edit ctx, p_end, p_end)
        scopePop(edit ctx.scopes)
        flowLink(edit ctx.flow, join, -1)
        when is_wildcard { leave }
        ctx.flow.current = next_test
    }
    ctx.flow.current = join
    semaScopeExit(edit ctx, expr.end, expr.end)
}

expose flow semaCheckStmt(ctx: edit SemaContext, source: view Text, tree: view AstTree, stmt_id: Int) => Int {
    when stmt_id < 0 || stmt_id >= tree.statements.length {
        give 0
    }
    hold stmt = view tree.statements[stmt_id]
    ctx.lir.at = stmt.start
    choose stmt.kind {
        AstStmtKind.Let : { give semaStmtLet(edit ctx, source, tree, stmt_id) }
        AstStmtKind.Assign : {
            hold target_e = stmt.a
            hold val_e = stmt.d
            change indexed = false
            when target_e >= 0 && target_e < tree.expressions.length {
                choose tree.expressions[target_e].kind {
                    AstExprKind.Index : { indexed = true }
                    _ : {}
                }
            }
            change target_t = semaExprMode(edit ctx, source, tree, target_e, ACCESS_PLACE)
            hold target = ctx.expression_path
            hold target_place = ctx.lir.place
            lirDiscard(edit ctx)
            hold referent = semaRefElem(ctx, target_t)
            when referent >= 0 { target_t = referent }
            when target < 0 {
                semaAddError(edit ctx, "L0016", "destino de asignación no verificado", stmt.start, stmt.end)
            } otherwise {
                hold sym = ctx.flow.paths[target].symbol
                each f among 0..ctx.frozen_symbols.length {
                    when sym >= 0 && ctx.frozen_symbols[f] == sym {
                        semaAddError(edit ctx, "L0005", "no se puede modificar un valor mientras match examina sus datos", stmt.start, stmt.end)
                    }
                }
                hold loan = loanOfPath(view ctx.flow, target)
                when loan >= 0 {
                    // Writing through a reference binding requires &mut.
                    when !loanIsMut(view ctx.flow, loan) {
                        semaAddError(edit ctx, "L0001", "no se puede mutar a través de una referencia inmutable &T", stmt.start, stmt.end)
                    }
                } otherwise when !ctx.symbols.symbols[sym].is_mut {
                    semaAddError(edit ctx, "L0006", "no se puede reasignar a variable inmutable", stmt.start, stmt.end)
                }
                when stmt.c - stmt.b > 1 {
                    flowEvent(edit ctx.flow, FLOW_READ, target, stmt.start, stmt.end)
                    hold ty = view ctx.types.types[target_t]
                    when !semTypeIsNumeric(ty.kind) {
                        semaAddError(edit ctx, "L0003", "asignación compuesta requiere tipo numérico", stmt.start, stmt.end)
                    }
                }
            }
            // The written place types an empty `List[]` on the right.
            ctx.expected_list_type = target_t
            hold val_t = semaExprMode(edit ctx, source, tree, val_e, ACCESS_MOVE)
            hold value = lirTakeOperand(edit ctx, val_t)
            when target >= 0 && loanOfPath(view ctx.flow, target) >= 0 && semaNeedsDrop(edit ctx, source, tree, target_t) {
                // The old referent value is released before the write.
                flowEventData(edit ctx.flow, FLOW_DROP_REF, target, stmt.start, stmt.end, target_t)
            }
            when indexed {
                flowEvent(edit ctx.flow, FLOW_MUTATE, target, stmt.start, stmt.end)
            } otherwise {
                flowEvent(edit ctx.flow, FLOW_WRITE, target, stmt.start, stmt.end)
            }
            lirAssign(edit ctx, source, target_place, value, target_t, stmt.b, stmt.c)
            semaFlushTemps(edit ctx, stmt.start, stmt.end)
            when !semTypeEquals(view ctx.types, target_t, val_t) {
                hold exp_n = semTypeName(view ctx.types, source, target_t)
                hold act_n = semTypeName(view ctx.types, source, val_t)
                semaAddError(edit ctx, "L0003", "discrepancia de tipos en asignación: esperado '{exp_n}', recibido '{act_n}'", stmt.start, stmt.end)
            }
        }
        AstStmtKind.Return : {
            hold val_e = stmt.a
            change ret_t = 6
            hold borrowed = semaRefElem(ctx, ctx.current_fn_ret_type) >= 0
            ctx.pending_loan = -1
            when val_e >= 0 {
                when borrowed { ctx.borrow_site = SITE_RETURN }
                ctx.expected_union_type = ctx.current_fn_ret_type
                when !borrowed { ctx.expected_list_type = ctx.current_fn_ret_type }
                ret_t = semaExprMode(edit ctx, source, tree, val_e, ACCESS_MOVE)
                ctx.expected_union_type = -1
            }
            hold loan = ctx.pending_loan
            ctx.pending_loan = -1
            change value = LIR_NONE
            when val_e >= 0 { value = lirTakeOperand(edit ctx, ret_t) }
            // Leaving the function: temporaries, then every owned binding.
            semaFlushTemps(edit ctx, stmt.start, stmt.end)
            semaDropFrom(edit ctx, 0, stmt.start, stmt.end)
            lirReturnAt(edit ctx, value, borrowed)
            flowReturn(edit ctx.flow)
            when borrowed {
                semaReturnBorrow(edit ctx, ret_t, loan, stmt.start, stmt.end)
            } otherwise when !semTypeEquals(view ctx.types, ret_t, ctx.current_fn_ret_type) {
                hold exp_n = semTypeName(view ctx.types, source, ctx.current_fn_ret_type)
                hold act_n = semTypeName(view ctx.types, source, ret_t)
                semaAddError(edit ctx, "L0003", "tipo de retorno incompatible: esperado '{exp_n}', recibido '{act_n}'", stmt.start, stmt.end)
            }
        }
        AstStmtKind.If : {
            hold cond_t = semaCheckExpr(edit ctx, source, tree, stmt.a)
            when !semTypeEquals(view ctx.types, cond_t, 4) {
                semaAddError(edit ctx, "L0003", "la condición del 'if' debe ser de tipo Bool", stmt.start, stmt.end)
            }
            lirCondition(edit ctx)
            semaFlushTemps(edit ctx, stmt.start, stmt.end)
            hold then_block = flowBlock(edit ctx.flow)
            hold else_block = flowBlock(edit ctx.flow)
            hold join = flowBlock(edit ctx.flow)
            flowLink(edit ctx.flow, then_block, else_block)
            ctx.flow.current = then_block
            when stmt.b >= 0 {
                semaCheckStmt(edit ctx, source, tree, stmt.b)
            }
            flowLink(edit ctx.flow, join, -1)
            ctx.flow.current = else_block
            when stmt.c >= 0 {
                semaCheckStmt(edit ctx, source, tree, stmt.c)
            }
            flowLink(edit ctx.flow, join, -1)
            ctx.flow.current = join
        }
        AstStmtKind.While : {
            hold outer_mark = ctx.loop_mark
            ctx.loop_mark = ctx.owned_locals.length
            hold loop_header = flowLoopStart(edit ctx.flow)
            hold cond_t = semaCheckExpr(edit ctx, source, tree, stmt.a)
            when !semTypeEquals(view ctx.types, cond_t, 4) {
                semaAddError(edit ctx, "L0003", "la condición del 'while' debe ser de tipo Bool", stmt.start, stmt.end)
            }
            lirCondition(edit ctx)
            semaFlushTemps(edit ctx, stmt.start, stmt.end)
            flowLoopBody(edit ctx.flow, loop_header, true)
            semaCheckStmt(edit ctx, source, tree, stmt.b)
            flowLoopEnd(edit ctx.flow, loop_header)
            ctx.loop_mark = outer_mark
        }
        AstStmtKind.For : {
            hold start_t = semaCheckExpr(edit ctx, source, tree, stmt.c)
            hold start_v = lirTakeOperand(edit ctx, 1)
            hold end_t = semaCheckExpr(edit ctx, source, tree, stmt.d)
            // Evaluate the end operand before taking an exclusive loan for for-initialization.
            hold end_v = lirTakeOperand(edit ctx, 1)
            hold counter = lirForInit(edit ctx, start_v, end_v)
            when !semTypeEquals(view ctx.types, start_t, 1) || !semTypeEquals(view ctx.types, end_t, 1) {
                semaAddError(edit ctx, "L0003", "el rango del bucle 'for' debe ser de tipo Int", stmt.start, stmt.end)
            }
            hold outer_mark = ctx.loop_mark
            ctx.loop_mark = ctx.owned_locals.length
            hold loop_header = flowLoopStart(edit ctx.flow)
            lirForTest(edit ctx, counter)
            flowLoopBody(edit ctx.flow, loop_header, true)
            // `continue` goes to the step block, which increments.
            hold step = flowBlock(edit ctx.flow)
            ctx.flow.continue_to = step
            scopePush(edit ctx.scopes)
            semaScopeEnter(edit ctx)
            hold current_scope = ctx.scopes.current_scope
            hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Var, stmt.a, stmt.b, 1, current_scope, false, false, -1, stmt.a, stmt.b)
            scopeAddSymbol(edit ctx.scopes, sym_id)
            semaInitPath(edit ctx, sym_id, stmt.a, stmt.b)
            ctx.lir.val = counter
            hold bind_path = ctx.symbols.symbols[sym_id].move_path
            lirLetBind(edit ctx, bind_path, 1, false)
            hold body_stmt = tree.extra[stmt.e + 1]
            when body_stmt >= 0 {
                semaCheckStmt(edit ctx, source, tree, body_stmt)
            }
            semaScopeExit(edit ctx, stmt.end, stmt.end)
            scopePop(edit ctx.scopes)
            flowLink(edit ctx.flow, step, -1)
            ctx.flow.current = step
            lirForStep(edit ctx, counter)
            flowLoopEnd(edit ctx.flow, loop_header)
            ctx.loop_mark = outer_mark
        }
        AstStmtKind.ForEach : {
            hold col_e = stmt.c
            // Scope of a collection produced by the expression itself.
            semaScopeEnter(edit ctx)
            hold col_t = semaExprMode(edit ctx, source, tree, col_e, ACCESS_PLACE)
            change col_path = ctx.expression_path
            ctx.expression_path = -1
            change col_place = ctx.lir.place
            when col_place < 0 {
                hold holder = lirValueVar(edit ctx, col_t)
                when holder >= 0 {
                    col_place = lirPlaceVar(edit ctx.lir, holder)
                    // A temporary collection is owned by the loop: it lives in
                    // its own path and is released on every way out.
                    hold made = view tree.expressions[col_e]
                    hold temp = flowRoot(edit ctx.flow, -1)
                    lirBindPath(edit ctx.lir, temp, holder)
                    semaOwn(edit ctx, source, tree, temp, col_t, made.start)
                    flowEvent(edit ctx.flow, FLOW_INIT, temp, made.start, made.end)
                    col_path = temp
                }
            }
            change elem_t = 0
            change unwrapped = col_t
            hold referent = semaRefElem(ctx, col_t)
            when referent >= 0 { unwrapped = referent }
            when unwrapped >= 0 && unwrapped < ctx.types.types.length {
                hold bt = view ctx.types.types[unwrapped]
                choose bt.kind {
                    SemTypeKind.List : { elem_t = bt.elem_type }
                    SemTypeKind.Array : { elem_t = bt.elem_type }
                    SemTypeKind.Slice : { elem_t = bt.elem_type }
                    _ : {
                        semaAddError(edit ctx, "L0003", "el bucle for-in requiere una colección", stmt.start, stmt.end)
                    }
                }
            }
            // An element that owns resources cannot be copied out of the
            // collection: the loop variable is then a shared reference to the
            // element, backed by a loan of the collection (as in Stage 0), so
            // the body can neither move the element nor grow the collection.
            change by_ref = false
            when elem_t > 0 && elem_t < ctx.types.types.length {
                hold element = view ctx.types.types[elem_t]
                by_ref = semTypeIsMove(element.kind)
            }
            change loop_loan = -1
            change bind_t = elem_t
            when by_ref {
                hold col_span = view tree.expressions[col_e]
                semaBorrowPlace(edit ctx, col_path, col_t, false, SITE_LET, col_span.start, col_span.end)
                loop_loan = ctx.pending_loan
                ctx.pending_loan = -1
                bind_t = semTypeMakeRef(edit ctx.types, elem_t, false)
            }
            hold len_dst = lirVar(edit ctx.lir, 1, false)
            when col_place >= 0 {
                lirAt(edit ctx, LIR_LEN, len_dst, col_place, 0, 0)
            }
            hold start_v = lirConst(edit ctx.lir, LIR_CONST_INT, 0, 0, 0)
            hold counter = lirForInit(edit ctx, start_v, len_dst)
            hold outer_mark = ctx.loop_mark
            ctx.loop_mark = ctx.owned_locals.length
            hold loop_header = flowLoopStart(edit ctx.flow)
            lirForTest(edit ctx, counter)
            flowLoopBody(edit ctx.flow, loop_header, true)
            hold step = flowBlock(edit ctx.flow)
            ctx.flow.continue_to = step
            scopePush(edit ctx.scopes)
            semaScopeEnter(edit ctx)
            hold current_scope = ctx.scopes.current_scope
            hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Var, stmt.a, stmt.b, bind_t, current_scope, false, false, -1, stmt.a, stmt.b)
            scopeAddSymbol(edit ctx.scopes, sym_id)
            semaInitPath(edit ctx, sym_id, stmt.a, stmt.b)

            when col_place >= 0 {
                hold elem_place = lirPlaceIndex(edit ctx.lir, col_place, counter)
                when by_ref {
                    hold loan_value = lirNew(edit ctx, elem_t, true, LIR_LOAN, elem_place, 0, 0)
                    lirSetVal(edit ctx, loan_value)
                } otherwise {
                    hold elem_var = lirVar(edit ctx.lir, elem_t, false)
                    lirAt(edit ctx, LIR_READ, elem_var, elem_place, 0, 0)
                    ctx.lir.val = elem_var
                }
            }
            hold loop_path = ctx.symbols.symbols[sym_id].move_path
            lirLetBind(edit ctx, loop_path, bind_t, by_ref && loop_loan >= 0)
            when loop_loan >= 0 && !loanBindReferenceRoot(edit ctx.flow, loop_path, loop_loan) {
                semaAddError(edit ctx, "L0012", "vínculo de préstamo del bucle inválido", stmt.start, stmt.end)
            }
            hold body_stmt = stmt.d
            when body_stmt >= 0 {
                semaCheckStmt(edit ctx, source, tree, body_stmt)
            }
            semaScopeExit(edit ctx, stmt.end, stmt.end)
            scopePop(edit ctx.scopes)
            flowLink(edit ctx.flow, step, -1)
            ctx.flow.current = step
            lirForStep(edit ctx, counter)
            flowLoopEnd(edit ctx.flow, loop_header)
            ctx.loop_mark = outer_mark
            semaScopeExit(edit ctx, stmt.end, stmt.end)
        }
        AstStmtKind.Loop : {
            hold outer_mark = ctx.loop_mark
            ctx.loop_mark = ctx.owned_locals.length
            hold loop_header = flowLoopStart(edit ctx.flow)
            flowLoopBody(edit ctx.flow, loop_header, false)
            semaCheckStmt(edit ctx, source, tree, stmt.a)
            flowLoopEnd(edit ctx.flow, loop_header)
            ctx.loop_mark = outer_mark
        }
        AstStmtKind.Break : {
            hold target = ctx.flow.break_to
            hold mark = ctx.loop_mark
            when target >= 0 { semaDropFrom(edit ctx, mark, stmt.start, stmt.end) }
            semaJumpLoop(edit ctx, target, stmt.start, stmt.end)
        }
        AstStmtKind.Continue : {
            hold target = ctx.flow.continue_to
            hold mark = ctx.loop_mark
            when target >= 0 { semaDropFrom(edit ctx, mark, stmt.start, stmt.end) }
            semaJumpLoop(edit ctx, target, stmt.start, stmt.end)
        }
        AstStmtKind.Block : {
            scopePush(edit ctx.scopes)
            semaScopeEnter(edit ctx)
            hold first = stmt.a
            hold count = stmt.b
            each i among 0..count {
                hold sid = tree.extra[first + i]
                semaCheckStmt(edit ctx, source, tree, sid)
            }
            semaScopeExit(edit ctx, stmt.end, stmt.end)
            scopePop(edit ctx.scopes)
        }
        AstStmtKind.Expr : {
            hold expr_id = stmt.a
            when expr_id >= 0 && expr_id < tree.expressions.length {
                choose tree.expressions[expr_id].kind {
                    AstExprKind.Match : {
                        semaCheckMatch(edit ctx, source, tree, expr_id)
                        lirDiscard(edit ctx)
                        semaFlushTemps(edit ctx, stmt.start, stmt.end)
                        give 0
                    }
                    _ : {}
                }
            }
            hold ty = semaCheckExpr(edit ctx, source, tree, stmt.a)
            when ctx.expression_path < 0 && stmt.a >= 0 {
                // A discarded owned result is a temporary of the statement.
                semaTemp(edit ctx, source, tree, ty, tree.expressions[stmt.a].start, tree.expressions[stmt.a].end)
            }
            lirDiscard(edit ctx)
            semaFlushTemps(edit ctx, stmt.start, stmt.end)
        }
        _ : { semaAddError(edit ctx, "L0016", "sentencia fuera del subconjunto verificado de Stage 1", stmt.start, stmt.end) }
    }
    give 0
}

