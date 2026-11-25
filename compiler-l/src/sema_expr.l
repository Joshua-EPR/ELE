take tokens
take sema_borrow_syntax
take sema_expr_temp
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
take sema_ops
take sema_collection_ops
take stmt_lower
take sema_builtin_union
take lir_builtin_union
take sema_match_coverage
take sema_try

// Fields omitted from a constructor take their declared default. The default
// was checked as a constant when the shape was declared
// (semaCheckFieldDefaults); here its expression is lowered at the
// construction site, in the global scope of the declaring module, exactly
// like an explicit argument. A field without default stays unseen and is
// reported by semaConstructorFinish.
flow semaConstructorDefaults(ctx: edit SemaContext, source: view Text, tree: view AstTree, decl_id: Int, seen: edit List of[Bool], slots: edit List of[Int]) {
    hold decl = view tree.declarations[decl_id]
    each i among 0..decl.d {
        hold default_id = tree.fields[decl.c + i].default_expr_id
        when seen[i] || default_id < 0 { proceed }
        hold saved_scope = ctx.scopes.current_scope
        hold saved_module = ctx.current_module
        hold saved_list = ctx.expected_list_type
        ctx.scopes.current_scope = 0
        ctx.current_module = semaDeclModule(ctx, decl_id)
        hold field_t = semaFieldType(edit ctx, source, tree, decl.c + i)
        ctx.expected_list_type = field_t
        hold ty = semaExprMode(edit ctx, source, tree, default_id, ACCESS_MOVE)
        slots[i] = lirTakeOperand(edit ctx, ty)
        seen[i] = true
        when !semTypeEquals(view ctx.types, ty, field_t) {
            hold default_expr = view tree.expressions[default_id]
            semaAddError(edit ctx, "L0003", "valor predeterminado incompatible con el tipo del campo", default_expr.start, default_expr.end)
        }
        ctx.scopes.current_scope = saved_scope
        ctx.current_module = saved_module
        ctx.expected_list_type = saved_list
    }
}

flow semaCheckConstructor(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr: view AstExpr, decl_id: Int, struct_t: Int) {
    hold decl = view tree.declarations[decl_id]
    change seen: List of[Bool] = List[]
    change slots: List of[Int] = List[]
    each i among 0..decl.d {
        seen@push(false)
        slots@push(LIR_NONE)
    }
    each i among 0..expr.d {
        hold arg = view tree.expressions[tree.extra[expr.c + i]]
        // The declared field type is the context of an empty `List[]`.
        hold field = semaNamedField(source, tree, decl_id, arg)
        when field >= 0 { ctx.expected_list_type = semaFieldType(edit ctx, source, tree, field) }
        hold ty = semaExprMode(edit ctx, source, tree, arg.c, ACCESS_MOVE)
        semaConstructorField(edit ctx, source, tree, decl_id, arg, ty, edit seen, edit slots)
    }
    semaConstructorDefaults(edit ctx, source, tree, decl_id, edit seen, edit slots)
    semaConstructorFinish(edit ctx, tree, expr, decl_id, struct_t, view seen, view slots)
}

expose flow semaCheckExpr(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int) => Int {
    give semaExprMode(edit ctx, source, tree, expr_id, ACCESS_READ)
}

// `&place` / `&mut place`: only a let initializer, a reference argument
// or a borrowed return may hold a borrow (Stage 0 rules).
flow semaBorrowExpr(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, site: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    hold is_mut = semaBorrowSyntaxKind(source, expr.b, expr.c) == 2
    when site == SITE_VAR || semaPlaceRoot(tree, expr.a) < 0 {
        semaAddError(edit ctx, "L0012", "use let para prestar una variable, campo o elemento con un origen fijo", expr.start, expr.end)
        give 7
    }
    when site == SITE_NONE {
        semaAddError(edit ctx, "L0001", "un préstamo (&, &mut) solo puede pasarse directamente como argumento a un parámetro de referencia; guardarlo o devolverlo requiere anotaciones de vida aún no implementadas", expr.start, expr.end)
        give 7
    }
    hold operand_t = semaExprMode(edit ctx, source, tree, expr.a, ACCESS_PLACE)
    hold path = ctx.expression_path
    ctx.expression_path = -1
    hold operand_place = ctx.lir.place
    // The loan starts at the borrowed place, as Stage 0 reports it.
    hold place = view tree.expressions[expr.a]
    hold ty = semaBorrowPlace(edit ctx, path, operand_t, is_mut, site, place.start, place.end)
    // The flow path of an indexed operand is its collection, but the
    // reference must point at the element: keep the place of the operand.
    when operand_place >= 0 && ctx.lir.borrowed >= 0 { ctx.lir.borrowed = operand_place }
    when site != SITE_ARG && ctx.lir.borrowed >= 0 {
        change mutable = 0
        when is_mut { mutable = 1 }
        hold referent = semaRefElem(ctx, ty)
        hold borrowed_place = ctx.lir.borrowed
        hold value = lirNew(edit ctx, referent, true, LIR_LOAN, borrowed_place, mutable, 0)
        lirSetVal(edit ctx, value)
    }
    give ty
}

// Argument for a reference parameter: an explicit borrow of the same mode
// or, for `&T`, a place that is borrowed implicitly. Returns the loan.
flow semaRefArg(ctx: edit SemaContext, source: view Text, tree: view AstTree, arg_id: Int, param_t: Int, index: Int) => Int {
    hold arg = view tree.expressions[arg_id]
    hold param_mut = semaIsMutRef(ctx, param_t)
    hold n = index + 1
    change explicit = false
    change arg_mut = false
    choose arg.kind {
        AstExprKind.Unary : {
            hold kind = semaBorrowSyntaxKind(source, arg.b, arg.c)
            when kind > 0 {
                explicit = true
                arg_mut = kind == 2
            }
        }
        _ : {}
    }
    when param_mut && !arg_mut {
        semaAddError(edit ctx, "L0001", "se esperaba un préstamo mutable (&mut) para el parámetro {n}", arg.start, arg.end)
        give -1
    }
    when !param_mut && arg_mut {
        semaAddError(edit ctx, "L0001", "el parámetro {n} es &T: pase '&' en lugar de '&mut'", arg.start, arg.end)
        give -1
    }
    change ty = 7
    when explicit {
        ctx.borrow_site = SITE_ARG
        ty = semaExprMode(edit ctx, source, tree, arg_id, ACCESS_MOVE)
    } otherwise {
        when semaPlaceRoot(tree, arg_id) < 0 {
            semaAddError(edit ctx, "L0001", "el parámetro {n} es una referencia (&T): pase una variable o un campo, que se presta automáticamente", arg.start, arg.end)
            give -1
        }
        hold operand_t = semaExprMode(edit ctx, source, tree, arg_id, ACCESS_PLACE)
        hold path = ctx.expression_path
        ctx.expression_path = -1
        ty = semaBorrowPlace(edit ctx, path, operand_t, false, SITE_ARG, arg.start, arg.end)
    }
    hold loan = ctx.pending_loan
    ctx.pending_loan = -1
    when !semTypeEquals(view ctx.types, semaRefElem(ctx, ty), semaRefElem(ctx, param_t)) {
        semaAddError(edit ctx, "L0004", "tipo incompatible en argumento", arg.start, arg.end)
    }
    give loan
}

// A value read by print or an interpolation that is not a place and not a
// literal is an owned temporary of the enclosing statement.
expose flow semaExprMode(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, mode: Int) => Int {
    ctx.expression_path = -1
    when expr_id < 0 || expr_id >= tree.expressions.length {
        give 7
    }
    // Instructions of this expression carry its start (runtime messages).
    hold outer_at = ctx.lir.at
    ctx.lir.at = tree.expressions[expr_id].start
    // A list context set by the caller belongs to this expression only when
    // it is the list literal itself (or a named argument wrapping it); it
    // never reaches unrelated subexpressions.
    hold expected_list = ctx.expected_list_type
    ctx.expected_list_type = -1
    choose tree.expressions[expr_id].kind {
        AstExprKind.ListLit : { ctx.expected_list_type = expected_list }
        AstExprKind.Named : { ctx.expected_list_type = expected_list }
        AstExprKind.Choose : { ctx.expected_list_type = expected_list }
        _ : {}
    }
    hold ty = semaInferExpr(edit ctx, source, tree, expr_id, mode)
    ctx.expected_list_type = -1
    ctx.lir.at = outer_at
    choose tree.expressions[expr_id].kind {
        AstExprKind.Name : {}
        AstExprKind.Field : {}
        AstExprKind.Index : {}
        _ : { ctx.expression_path = -1 }
    }
    give ty
}

// Lower a value-producing choose using the same coverage, arm tests and
// payload binding as the statement form. Each arm assigns one shared result
// slot, while flow ownership remains branch-local until the join.
flow semaChooseExpr(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr: view AstExpr, mode: Int) => Int {
    when mode == ACCESS_PLACE {
        semaAddError(edit ctx, "L0016", "choose produce un valor y no puede usarse como destino", expr.start, expr.end)
        give 7
    }
    hold expected_list = ctx.expected_list_type
    hold scrut_t = semaExprMode(edit ctx, source, tree, expr.a, ACCESS_READ)
    change scrut_path = ctx.expression_path
    hold owned_scrut = semaNeedsDrop(edit ctx, source, tree, scrut_t)
    hold scrut_place = ctx.lir.place
    hold text_in_place = scrut_t == 5 && scrut_place >= 0
    when owned_scrut && scrut_place >= 0 && !text_in_place {
        when ctx.lir.places[scrut_place].parent >= 0 || ctx.lir.vars[ctx.lir.places[scrut_place].root].is_ref {
            lirMarkUnsupported(edit ctx.lir, expr.start)
        }
    }
    change covered = false
    when scrut_t >= 0 && scrut_t < ctx.types.types.length {
        choose ctx.types.types[scrut_t].kind {
            SemTypeKind.Option : {
                when !lirBuiltinSupported(view ctx.types, view ctx.lir_module, scrut_t) { lirMarkUnsupported(edit ctx.lir, expr.start) }
                covered = semaBuiltinMatchCovered(source, tree, expr, false)
            }
            SemTypeKind.Result : {
                when !lirBuiltinSupported(view ctx.types, view ctx.lir_module, scrut_t) { lirMarkUnsupported(edit ctx.lir, expr.start) }
                covered = semaBuiltinMatchCovered(source, tree, expr, true)
            }
            SemTypeKind.Enum : {
                hold nominal = ctx.types.types[scrut_t].nominal_id
                covered = semaEnumMatchCovered(edit ctx, source, tree, expr, nominal)
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
        covered = covered || semaPrimitiveMatchCovered(edit ctx, source, tree, expr, scrut_t)
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
    semaScopeEnter(edit ctx)
    when owned_scrut && scrut_path < 0 && scrut_place < 0 {
        scrut_path = semaOwnScrutinee(edit ctx, source, tree, scrut_var, scrut_t, expr.start, expr.end)
    }
    change result_t = -1
    change result_var = -1
    each i among 0..expr.c {
        hold p_start = tree.extra[expr.b + 3 * i]
        hold p_end = tree.extra[expr.b + 3 * i + 1]
        hold arm_expr = tree.extra[expr.b + 3 * i + 2]
        hold arm_body = flowBlock(edit ctx.flow)
        hold next_test = flowBlock(edit ctx.flow)
        hold is_wildcard = lirMatchArmTest(edit ctx, source, tree, p_start, p_end, scrut_var, text_place, scrut_t, arm_body, next_test, i == expr.c - 1 && covered)
        ctx.flow.current = arm_body
        scopePush(edit ctx.scopes)
        semaScopeEnter(edit ctx)
        hold frozen_mark = ctx.frozen_symbols.length
        lirMatchArmBind(edit ctx, source, tree, p_start, p_end, scrut_var, scrut_t, scrut_path)
        hold temp_mark = ctx.pending_temps.length
        ctx.expected_list_type = expected_list
        hold value_t = semaExprMode(edit ctx, source, tree, arm_expr, ACCESS_MOVE)
        ctx.expected_list_type = -1
        when result_t < 0 {
            result_t = value_t
            when value_t >= 0 && value_t < ctx.types.types.length {
                hold value = lirTakeOperand(edit ctx, value_t)
                result_var = lirVar(edit ctx.lir, value_t, false)
                lirAt(edit ctx, LIR_USE, result_var, value, 0, 0)
            }
        } otherwise when !semTypeEquals(view ctx.types, result_t, value_t) {
            hold expected_name = semTypeName(view ctx.types, source, result_t)
            hold actual_name = semTypeName(view ctx.types, source, value_t)
            semaAddError(edit ctx, "L0003", "brazos de choose incompatibles: esperado '{expected_name}', recibido '{actual_name}'", tree.expressions[arm_expr].start, tree.expressions[arm_expr].end)
        } otherwise {
            hold value = lirTakeOperand(edit ctx, value_t)
            lirAt(edit ctx, LIR_USE, result_var, value, 0, 0)
        }
        during ctx.frozen_symbols.length > frozen_mark { ctx.frozen_symbols@pop() }
        during ctx.pending_temps.length > temp_mark {
            choose ctx.pending_temps@pop() {
                Some(path) : { flowEvent(edit ctx.flow, FLOW_DROP, path, p_end, p_end) }
                None : {}
            }
        }
        semaScopeExit(edit ctx, p_end, p_end)
        scopePop(edit ctx.scopes)
        flowLink(edit ctx.flow, join, -1)
        when is_wildcard { leave }
        ctx.flow.current = next_test
    }
    ctx.flow.current = join
    semaScopeExit(edit ctx, expr.end, expr.end)
    when result_t < 0 || result_var < 0 {
        semaAddError(edit ctx, "L0004", "choose requiere al menos un brazo exhaustivo", expr.start, expr.end)
        lirDiscard(edit ctx)
        give 7
    }
    lirSetVal(edit ctx, result_var)
    when semaNeedsDrop(edit ctx, source, tree, result_t) {
        semaTemp(edit ctx, source, tree, result_t, expr.start, expr.end)
        when ctx.pending_temps.length > 0 {
            hold path = ctx.pending_temps[ctx.pending_temps.length - 1]
            semaAccess(edit ctx, path, result_t, mode, expr.start, expr.end)
        }
    }
    give result_t
}

// Lazy Option fallback (`option ?? fallback`). The Some payload and the
// fallback meet in one result slot, with the fallback evaluated only on the
// None edge. Each arm transfers ownership directly into the shared slot.
flow semaOptionDefaultExpr(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr: view AstExpr, mode: Int) => Int {
    when mode == ACCESS_PLACE {
        semaAddError(edit ctx, "L0016", "?? produce un valor y no puede usarse como destino", expr.start, expr.end)
        give 7
    }
    hold expected_list = ctx.expected_list_type
    hold scrut_t = semaExprMode(edit ctx, source, tree, expr.a, ACCESS_READ)
    when scrut_t < 0 || scrut_t >= ctx.types.types.length {
        semaAddError(edit ctx, "L0003", "el operador ?? requiere Option<T>", expr.start, expr.end)
        lirDiscard(edit ctx)
        give 7
    }
    change is_option = false
    choose ctx.types.types[scrut_t].kind {
        SemTypeKind.Option : { is_option = true }
        _ : {}
    }
    when !is_option {
        semaAddError(edit ctx, "L0003", "el operador ?? requiere Option<T>", expr.start, expr.end)
        lirDiscard(edit ctx)
        give 7
    }
    hold payload_t = ctx.types.types[scrut_t].elem_type
    when !lirBuiltinSupported(view ctx.types, view ctx.lir_module, scrut_t) {
        lirMarkUnsupported(edit ctx.lir, expr.start)
        lirDiscard(edit ctx)
        give 7
    }
    hold owned_payload = lirBuiltinPayloadOwned(view ctx.types, view ctx.lir_module, payload_t)
    change scrut_path = ctx.expression_path
    hold scrut_place = ctx.lir.place
    hold owned_scrut = semaNeedsDrop(edit ctx, source, tree, scrut_t)
    hold scrut_var = lirMatchScrutVar(edit ctx, scrut_t)
    hold union_id = lirBuiltinRegister(edit ctx.lir_module, view ctx.types, scrut_t)
    when union_id < 0 { lirMarkUnsupported(edit ctx.lir, expr.start) }
    hold join = flowBlock(edit ctx.flow)
    hold some_block = flowBlock(edit ctx.flow)
    hold none_block = flowBlock(edit ctx.flow)
    semaScopeEnter(edit ctx)
    when owned_scrut && scrut_path < 0 && scrut_place < 0 {
        scrut_path = semaOwnScrutinee(edit ctx, source, tree, scrut_var, scrut_t, expr.start, expr.end)
    }
    hold place = lirPlaceVar(edit ctx.lir, scrut_var)
    hold tag = lirNew(edit ctx, 1, false, LIR_DISC, place, 0, 0)
    hold some_tag = lirConst(edit ctx.lir, LIR_CONST_INT, 1, expr.start, expr.end)
    hold condition = lirNew(edit ctx, 4, false, LIR_BINARY, LIR_EQ, tag, some_tag)
    ctx.lir.val = condition
    ctx.lir.place = -1
    lirCondition(edit ctx)
    flowLink(edit ctx.flow, some_block, none_block)
    hold result_var = lirVar(edit ctx.lir, payload_t, false)

    ctx.flow.current = some_block
    when owned_payload {
        semaAccess(edit ctx, scrut_path, scrut_t, ACCESS_MOVE, expr.start, expr.end)
    }
    hold union_place = lirPlaceVar(edit ctx.lir, scrut_var)
    hold payload = lirNew(edit ctx, payload_t, false, LIR_PAYLOAD, union_place, union_id, 1)
    // The extracted payload is an SSA value owned by this edge. Move it
    // straight into the shared result slot; a branch-local flow binding
    // would schedule a second drop after the value has already moved.
    lirAt(edit ctx, LIR_USE, result_var, payload, 0, 0)
    flowLink(edit ctx.flow, join, -1)

    ctx.flow.current = none_block
    scopePush(edit ctx.scopes)
    semaScopeEnter(edit ctx)
    hold temp_mark = ctx.pending_temps.length
    ctx.expected_list_type = payload_t
    hold expected_union = ctx.expected_union_type
    ctx.expected_union_type = payload_t
    hold fallback_t = semaExprMode(edit ctx, source, tree, expr.b, ACCESS_MOVE)
    ctx.expected_list_type = expected_list
    ctx.expected_union_type = expected_union
    when !semTypeEquals(view ctx.types, payload_t, fallback_t) {
        hold expected_name = semTypeName(view ctx.types, source, payload_t)
        hold actual_name = semTypeName(view ctx.types, source, fallback_t)
        semaAddError(edit ctx, "L0003", "fallback de ?? incompatible: esperado '{expected_name}', recibido '{actual_name}'", tree.expressions[expr.b].start, tree.expressions[expr.b].end)
    }
    hold fallback = lirTakeOperand(edit ctx, fallback_t)
    lirAt(edit ctx, LIR_USE, result_var, fallback, 0, 0)
    change fallback_path = -1
    each i among temp_mark..ctx.pending_temps.length {
        hold candidate = ctx.pending_temps[i]
        when lirPathVar(view ctx.lir, candidate) == fallback { fallback_path = candidate }
    }
    during ctx.pending_temps.length > temp_mark {
        choose ctx.pending_temps@pop() {
            Some(path) : {
                change event = FLOW_DROP
                when path == fallback_path { event = FLOW_MOVE }
                flowEvent(edit ctx.flow, event, path, tree.expressions[expr.b].end, tree.expressions[expr.b].end)
            }
            None : {}
        }
    }
    semaScopeExit(edit ctx, tree.expressions[expr.b].start, tree.expressions[expr.b].end)
    scopePop(edit ctx.scopes)
    flowLink(edit ctx.flow, join, -1)
    ctx.flow.current = join
    semaScopeExit(edit ctx, expr.start, expr.end)
    lirSetVal(edit ctx, result_var)
    give payload_t
}

flow semaInferExpr(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, mode: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    hold site = ctx.borrow_site
    ctx.borrow_site = SITE_NONE
    choose expr.kind {
        AstExprKind.IntLit : { give semaLiteral(edit ctx, source, tree, expr_id, 1) }
        AstExprKind.BoolLit : { give semaLiteral(edit ctx, source, tree, expr_id, 4) }
        AstExprKind.TextLit : { give semaLiteral(edit ctx, source, tree, expr_id, 5) }
        AstExprKind.UnitLit : { give semaLiteral(edit ctx, source, tree, expr_id, 6) }
        AstExprKind.Interpolate : {
            hold buffer = lirNew(edit ctx, 5, false, LIR_TEXTBUF, semaInterpCapacity(tree, expr_id), 0, 0)
            each i among 0..expr.b {
                hold part = tree.extra[expr.a + i]
                hold mark = ctx.pending_temps.length
                hold ty = semaCheckExpr(edit ctx, source, tree, part)
                semaReadTemp(edit ctx, source, tree, part, ty, mark)
                when ty < 1 || ty > 5 {
                    semaAddError(edit ctx, "L0003", "tipo no imprimible en interpolación", expr.start, expr.end)
                }
                semaAppendPart(edit ctx, tree, buffer, part, ty)
            }
            lirSetVal(edit ctx, buffer)
            give 5
        }
        AstExprKind.Name : {
            give semaNameExpr(edit ctx, source, tree, expr_id, mode, site)
        }
        AstExprKind.Binary : {
            hold lhs_t = semaCheckExpr(edit ctx, source, tree, expr.a)
            change rhs_t = 7
            hold op = source@byteAt(expr.c)
            when op == 63 {
                give semaOptionDefaultExpr(edit ctx, source, tree, expr, mode)
            }
            hold lhs = lirTakeOperand(edit ctx, lhs_t)
            change rhs = LIR_NONE
            when op == 38 || op == 124 {
                hold rhs_block = flowBlock(edit ctx.flow)
                hold join = flowBlock(edit ctx.flow)
                hold result = semaShortVar(edit ctx, lhs, op == 124)
                flowLink(edit ctx.flow, rhs_block, join)
                ctx.flow.current = rhs_block
                rhs_t = semaCheckExpr(edit ctx, source, tree, expr.b)
                hold rhs_value = lirTakeOperand(edit ctx, rhs_t)
                lirAt(edit ctx, LIR_USE, result, rhs_value, 0, 0)
                flowLink(edit ctx.flow, join, -1)
                ctx.flow.current = join
                rhs = result
            } otherwise {
                rhs_t = semaCheckExpr(edit ctx, source, tree, expr.b)
                rhs = lirTakeOperand(edit ctx, rhs_t)
            }
            give semaBinaryFinish(edit ctx, source, tree, expr_id, lhs_t, rhs_t, lhs, rhs)
        }
        AstExprKind.Unary : {
            when expr.b >= 0 && expr.b < source.byteLength {
                hold op = source@byteAt(expr.b)
                when semaBorrowSyntaxKind(source, expr.b, expr.c) > 0 {
                    give semaBorrowExpr(edit ctx, source, tree, expr_id, site)
                }
                when op == 42 {
                    semaAddError(edit ctx, "L0012", "la desreferencia explícita está fuera del subconjunto verificado de Stage 1", expr.start, expr.end)
                    give 7
                }
            }
            hold sub_t = semaCheckExpr(edit ctx, source, tree, expr.a)
            hold operand = lirTakeOperand(edit ctx, sub_t)
            give semaUnaryFinish(edit ctx, source, tree, expr_id, sub_t, operand)
        }
        AstExprKind.Call : {
            hold name_start = expr.a
            hold name_end = expr.b
            hold first_arg = expr.c
            hold arg_count = expr.d
            hold print_name = "print"
            hold name_ok = "Ok"
            hold name_err = "Err"
            hold name_some = "Some"
            when symbolNameEqualsText(source, name_start, name_end, print_name) {
                when arg_count == 1 {
                    hold arg = tree.extra[first_arg]
                    hold mark = ctx.pending_temps.length
                    hold ty = semaCheckExpr(edit ctx, source, tree, arg)
                    semaReadTemp(edit ctx, source, tree, arg, ty, mark)
                    when ty >= 1 && ty <= 5 {
                        hold printed = lirTakeArg(edit ctx, ty)
                        lirAt(edit ctx, LIR_PRINT, -1, printed, 0, 0)
                        hold unit = lirConst(edit ctx.lir, LIR_CONST_UNIT, 0, 0, 0)
                        lirSetVal(edit ctx, unit)
                        give 6
                    }
                }
                semaAddError(edit ctx, "L0004", "print requiere un argumento imprimible", expr.start, expr.end)
                give 7
            }
            change builtin_variant = -1
            when symbolNameEqualsText(source, name_start, name_end, name_ok) { builtin_variant = 0 }
            when symbolNameEqualsText(source, name_start, name_end, name_err) { builtin_variant = 1 }
            when symbolNameEqualsText(source, name_start, name_end, name_some) { builtin_variant = 2 }
            when builtin_variant >= 0 && arg_count == 1 {
                // A nested expression must not inherit the result union type
                // of its constructor's own expected destination.
                // Only a nested Option/Result payload type is propagated
                // (e.g. `Some(Ok(x))` against Option<Result<T, E>>).
                hold contextual = ctx.expected_union_type
                ctx.expected_union_type = semaBuiltinPayloadExpected(ctx, contextual, builtin_variant)
                hold arg_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_MOVE)
                hold payload = lirTakeOperand(edit ctx, arg_t)
                ctx.expected_union_type = contextual
                give semaBuiltinUnionValue(edit ctx, arg_t, payload, builtin_variant, expr.start, expr.end)
            }
            hold name_print_err = "printError"
            when symbolNameEqualsText(source, name_start, name_end, name_print_err) && arg_count == 1 {
                hold mark = ctx.pending_temps.length
                hold ty = semaCheckExpr(edit ctx, source, tree, tree.extra[first_arg])
                semaReadTemp(edit ctx, source, tree, tree.extra[first_arg], ty, mark)
                when ty == 5 || semaRefElem(ctx, ty) == 5 {
                    when ctx.lir.place < 0 {
                        when ctx.pending_temps.length == mark {
                            semaTemp(edit ctx, source, tree, 5, expr.start, expr.end)
                        }
                        hold temp_var = ctx.lir.val
                        when temp_var >= 0 { ctx.lir.place = lirPlaceVar(edit ctx.lir, temp_var) }
                    }
                    when ctx.lir.place < 0 { lirMarkUnsupported(edit ctx.lir, expr.start) }
                    change args: List of[Int] = List[]
                    args@push(lirTakeArg(edit ctx, ty))
                    semaPlatformEmit(edit ctx, LIR_PLATFORM_PRINT_ERROR, view args, 6, false)
                    give 6
                }
                semaAddError(edit ctx, "L0004", "printError requiere un argumento Text o &Text", expr.start, expr.end)
                give 7
            }
            hold name_arg_count = "processArgCount"
            when symbolNameEqualsText(source, name_start, name_end, name_arg_count) && arg_count == 0 {
                change args: List of[Int] = List[]
                semaPlatformEmit(edit ctx, 0, view args, 1, true)
                give 1
            }
            hold name_arg = "processArg"
            when symbolNameEqualsText(source, name_start, name_end, name_arg) && arg_count == 1 {
                hold ty = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_MOVE)
                when ty == 1 {
                    change args: List of[Int] = List[]
                    hold operand = lirTakeOperand(edit ctx, 1)
                    hold argument = lirArg(edit ctx.lir, false, operand, false)
                    args@push(argument)
                    hold res_t = semTypeMakeResult(edit ctx.types, 5, 1)
                    when lirBuiltinRegister(edit ctx.lir_module, view ctx.types, res_t) < 0 { lirMarkUnsupported(edit ctx.lir, expr.start) }
                    semaPlatformEmit(edit ctx, 1, view args, res_t, true)
                    give res_t
                }
                semaAddError(edit ctx, "L0004", "processArg requiere un argumento Int", expr.start, expr.end)
                give 7
            }
            hold name_read_text = "readText"
            when symbolNameEqualsText(source, name_start, name_end, name_read_text) {
                when arg_count != 2 {
                    semaAddError(edit ctx, "L0004", "readText requiere (path: &Text, max_len: Int)", expr.start, expr.end)
                    give 7
                }
                // Do not consume ctx.lir after visiting the second argument:
                // it replaces the expression channel used by the first.
                hold path_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
                when path_t != 5 {
                    semaAddError(edit ctx, "L0004", "readText requiere (path: &Text, max_len: Int)", expr.start, expr.end)
                    give 7
                }
                hold path_loan = semaPlatformArgLoan(edit ctx, path_t, expr.start, expr.end)
                hold path = ctx.lir.borrowed
                hold len_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 1], ACCESS_MOVE)
                hold len = lirTakeOperand(edit ctx, len_t)
                when len_t != 1 {
                    semaAddError(edit ctx, "L0004", "readText requiere (path: &Text, max_len: Int)", expr.start, expr.end)
                    give 7
                }
                when path < 0 || path_loan < 0 {
                    semaAddError(edit ctx, "L0016", "readText requiere un lugar Text prestable; los temporales propietarios no están soportados", expr.start, expr.end)
                    give 7
                }
                // The loan covers the full Result<Text, Int>, not only the
                // primitive success path: preserve the source through max_len.
                hold res_t = semTypeMakeResult(edit ctx.types, 5, 1)
                change loans: List of[Int] = List[]
                loans@push(path_loan)
                semaCallLoans(edit ctx, view loans, res_t, SITE_NONE, expr.start, expr.end)
                change args: List of[Int] = List[]
                hold path_arg = lirArg(edit ctx.lir, true, path, false)
                args@push(path_arg)
                hold len_arg = lirArg(edit ctx.lir, false, len, false)
                args@push(len_arg)
                // Result<Text, Int> owns its active Text (#5): a registered
                // builtin union with an atomic drop obligation.
                when lirBuiltinRegister(edit ctx.lir_module, view ctx.types, res_t) < 0 { lirMarkUnsupported(edit ctx.lir, expr.start) }
                semaPlatformEmit(edit ctx, LIR_PLATFORM_READ_TEXT, view args, res_t, true)
                give res_t
            }
            // textFromBytes(bytes: List<Int>, count: Int) => Result<Text, Int>:
            // the first `count` bytes as an owned Text (Err 1 bad count or
            // byte, Err 4 not UTF-8). The list is borrowed shared.
            hold name_text_bytes = "textFromBytes"
            when symbolNameEqualsText(source, name_start, name_end, name_text_bytes) {
                when arg_count != 2 {
                    semaAddError(edit ctx, "L0004", "textFromBytes requiere (bytes: List<Int>, cantidad: Int)", expr.start, expr.end)
                    give 7
                }
                hold bytes_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
                hold bytes_loan = semaPlatformArgLoan(edit ctx, bytes_t, expr.start, expr.end)
                hold bytes_place = ctx.lir.borrowed
                hold count_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 1], ACCESS_MOVE)
                hold count = lirTakeOperand(edit ctx, count_t)
                when !semaIsByteList(view ctx, bytes_t) || count_t != 1 {
                    semaAddError(edit ctx, "L0004", "textFromBytes requiere (bytes: List<Int>, cantidad: Int)", expr.start, expr.end)
                    give 7
                }
                when bytes_place < 0 || bytes_loan < 0 {
                    semaAddError(edit ctx, "L0016", "textFromBytes requiere un lugar List<Int> prestable", expr.start, expr.end)
                    give 7
                }
                hold text_res_t = semTypeMakeResult(edit ctx.types, 5, 1)
                change text_loans: List of[Int] = List[]
                text_loans@push(bytes_loan)
                semaCallLoans(edit ctx, view text_loans, text_res_t, SITE_NONE, expr.start, expr.end)
                change text_args: List of[Int] = List[]
                text_args@push(lirArg(edit ctx.lir, true, bytes_place, false))
                text_args@push(lirArg(edit ctx.lir, false, count, false))
                when lirBuiltinRegister(edit ctx.lir_module, view ctx.types, text_res_t) < 0 { lirMarkUnsupported(edit ctx.lir, expr.start) }
                semaPlatformEmit(edit ctx, LIR_PLATFORM_TEXT_FROM_BYTES, view text_args, text_res_t, true)
                give text_res_t
            }
            hold name_write_bytes = "writeBytes"
            when symbolNameEqualsText(source, name_start, name_end, name_write_bytes) {
                when arg_count != 2 {
                    semaAddError(edit ctx, "L0004", "writeBytes requiere (Text, List<Int>)", expr.start, expr.end)
                    give 7
                }
                // Materialize each shared loan before evaluating the next argument:
                // a plain FLOW_READ does not protect a previous argument.
                hold path_ty = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
                hold path_loan = semaPlatformArgLoan(edit ctx, path_ty, expr.start, expr.end)
                hold path = ctx.lir.borrowed
                hold bytes_ty = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 1], ACCESS_READ)
                hold bytes_loan = semaPlatformArgLoan(edit ctx, bytes_ty, expr.start, expr.end)
                hold bytes = ctx.lir.borrowed
                change loans: List of[Int] = List[]
                loans@push(path_loan)
                loans@push(bytes_loan)
                semaCallLoans(edit ctx, view loans, 1, SITE_NONE, expr.start, expr.end)
                give semaWriteBytes(edit ctx, expr.start, expr.end, path_ty, path, bytes_ty, bytes)
            }
            hold name_same_file = "sameFile"
            when symbolNameEqualsText(source, name_start, name_end, name_same_file) {
                when arg_count != 2 {
                    semaAddError(edit ctx, "L0004", "sameFile requiere (Text, Text)", expr.start, expr.end)
                    give 7
                }
                hold path_a_ty = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
                hold path_a_loan = semaPlatformArgLoan(edit ctx, path_a_ty, expr.start, expr.end)
                hold path_a = ctx.lir.borrowed
                hold path_b_ty = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 1], ACCESS_READ)
                hold path_b_loan = semaPlatformArgLoan(edit ctx, path_b_ty, expr.start, expr.end)
                hold path_b = ctx.lir.borrowed
                change loans: List of[Int] = List[]
                loans@push(path_a_loan)
                loans@push(path_b_loan)
                semaCallLoans(edit ctx, view loans, 4, SITE_NONE, expr.start, expr.end)
                give semaSameFile(edit ctx, expr.start, expr.end, path_a_ty, path_a, path_b_ty, path_b)
            }
            // Raw console input (std/io/console.l decodes it): Int in, Int out.
            hold name_console_mode = "consoleInputMode"
            when symbolNameEqualsText(source, name_start, name_end, name_console_mode) {
                when arg_count != 1 {
                    semaAddError(edit ctx, "L0004", "consoleInputMode requiere (mode: Int)", expr.start, expr.end)
                    give 7
                }
                hold mode_ty = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_MOVE)
                when mode_ty != 1 {
                    semaAddError(edit ctx, "L0004", "consoleInputMode requiere (mode: Int)", expr.start, expr.end)
                    give 7
                }
                change args: List of[Int] = List[]
                hold mode = lirTakeOperand(edit ctx, 1)
                hold mode_arg = lirArg(edit ctx.lir, false, mode, false)
                args@push(mode_arg)
                semaPlatformEmit(edit ctx, LIR_PLATFORM_CONSOLE_MODE, view args, 1, true)
                give 1
            }
            hold name_read_event = "readConsoleEvent"
            when symbolNameEqualsText(source, name_start, name_end, name_read_event) {
                when arg_count != 0 {
                    semaAddError(edit ctx, "L0004", "readConsoleEvent no recibe argumentos", expr.start, expr.end)
                    give 7
                }
                change args: List of[Int] = List[]
                semaPlatformEmit(edit ctx, LIR_PLATFORM_READ_EVENT, view args, 1, true)
                give 1
            }
            hold name_write_console = "writeConsoleBytes"
            when symbolNameEqualsText(source, name_start, name_end, name_write_console) {
                when arg_count != 1 {
                    semaAddError(edit ctx, "L0004", "writeConsoleBytes requiere (List<Int>)", expr.start, expr.end)
                    give 7
                }
                hold bytes_ty = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
                hold bytes_loan = semaPlatformArgLoan(edit ctx, bytes_ty, expr.start, expr.end)
                hold bytes = ctx.lir.borrowed
                change loans: List of[Int] = List[]
                loans@push(bytes_loan)
                semaCallLoans(edit ctx, view loans, 1, SITE_NONE, expr.start, expr.end)
                give semaWriteConsoleBytes(edit ctx, expr.start, expr.end, bytes_ty, bytes)
            }
            hold file_result = semaFileBuiltin(edit ctx, source, tree, expr.start, expr.end, name_start, name_end, first_arg, arg_count)
            when file_result != -1 { give file_result }
            hold window_result = semaWindowBuiltin(edit ctx, source, tree, expr.start, expr.end, name_start, name_end, first_arg, arg_count)
            when window_result != -1 { give window_result }
            hold clipboard_result = semaClipboardBuiltin(edit ctx, source, tree, expr.start, expr.end, name_start, name_end, first_arg, arg_count)
            when clipboard_result != -1 { give clipboard_result }
            hold sym_id = semaLookupVisible(edit ctx, source, name_start, name_end)
            when sym_id == -2 { give 7 }
            when sym_id < 0 {
                semaAddError(edit ctx, "L0001", "función no encontrada", name_start, name_end)
                give 7
            }
            hold sym = view ctx.symbols.symbols[sym_id]
            hold sym_type_id = sym.type_id
            hold decl_id = sym.decl_id
            choose sym.kind {
                SymbolKind.Struct : {
                    semaCheckConstructor(edit ctx, source, tree, expr, decl_id, sym_type_id)
                    give sym_type_id
                }
                SymbolKind.Func : {
                    when decl_id >= 0 && decl_id < tree.declarations.length {
                        semaNoteCallee(edit ctx, decl_id)
                        hold decl = view tree.declarations[decl_id]
                        hold expected_params = decl.e
                        hold first_p = decl.d
                        when arg_count != expected_params {
                            semaAddError(edit ctx, "L0004", "número incorrecto de argumentos en llamada", expr.start, expr.end)
                            give 7
                        }
                        change loans: List of[Int] = List[]
                        change args: List of[Int] = List[]
                        each a among 0..arg_count {
                            hold arg_eid = tree.extra[first_arg + a]
                            hold param = view tree.params[first_p + a]
                            hold param_t = semaResolveAstType(edit ctx, source, tree, param.type_id)
                            when semaRefElem(ctx, param_t) >= 0 {
                                loans@push(semaRefArg(edit ctx, source, tree, arg_eid, param_t, a))
                                hold place = ctx.lir.borrowed
                                hold is_mut = semaIsMutRef(ctx, param_t)
                                hold argument = lirArg(edit ctx.lir, true, place, is_mut)
                                args@push(argument)
                            } otherwise {
                                loans@push(-1)
                                ctx.expected_list_type = param_t
                                hold arg_t = semaExprMode(edit ctx, source, tree, arg_eid, ACCESS_MOVE)
                                hold operand = lirTakeOperand(edit ctx, arg_t)
                                hold argument = lirArg(edit ctx.lir, false, operand, false)
                                args@push(argument)
                                when !semTypeEquals(view ctx.types, arg_t, param_t) {
                                    semaAddError(edit ctx, "L0004", "tipo incompatible en argumento", expr.start, expr.end)
                                }
                            }
                        }
                        hold result = semaCallLoans(edit ctx, view loans, sym_type_id, site, expr.start, expr.end)
                        semaCallLower(edit ctx, decl_id, view args, sym_type_id)
                        give result
                    }
                    give sym_type_id
                }
                _ : {
                    semaAddError(edit ctx, "L0001", "el símbolo no es invocable", name_start, name_end)
                    give 7
                }
            }
        }
        AstExprKind.ListLit : {
            give semaCollectionLit(edit ctx, source, tree, expr, false)
        }
        AstExprKind.ArrayLit : {
            give semaCollectionLit(edit ctx, source, tree, expr, true)
        }
        AstExprKind.Field : {
            hold enum_t = semaEnumField(edit ctx, source, tree, expr)
            when enum_t >= 0 { give enum_t }
            hold base_t = semaExprMode(edit ctx, source, tree, expr.a, ACCESS_PLACE)
            hold parent = ctx.expression_path
            ctx.expression_path = -1
            give semaFieldFinish(edit ctx, source, tree, expr_id, mode, base_t, parent)
        }
        AstExprKind.Named : {
            ctx.borrow_site = site
            give semaExprMode(edit ctx, source, tree, expr.c, mode)
        }
        AstExprKind.MethodCall : {
            hold static_ext = semaExtensionStaticCall(edit ctx, source, tree, expr_id)
            when static_ext >= 0 { give static_ext }
            hold enum_call = semaEnumVariantCall(edit ctx, source, tree, expr)
            when enum_call >= 0 { give enum_call }
            hold base_t = semaExprMode(edit ctx, source, tree, expr.a, ACCESS_PLACE)
            hold base_place = ctx.lir.place
            hold base_path = ctx.expression_path
            ctx.expression_path = -1
            hold extension_call = semaExtensionInstanceCall(edit ctx, source, tree, expr_id, base_t, base_place, base_path)
            when extension_call >= 0 { give extension_call }
            hold first_call = expr.d
            hold count = tree.extra[first_call]
            change arg_op = LIR_NONE
            change arg_t = 0
            when count == 1 {
                arg_t = semaExprMode(edit ctx, source, tree, tree.extra[first_call + 1], ACCESS_MOVE)
                arg_op = lirTakeOperand(edit ctx, arg_t)
            }
            give semaMethodFinish(edit ctx, source, tree, expr_id, base_t, base_place, base_path, count, arg_t, arg_op)
        }
        AstExprKind.Index : {
            hold base_t = semaExprMode(edit ctx, source, tree, expr.a, ACCESS_PLACE)
            hold base_place = ctx.lir.place
            hold base_path = ctx.expression_path
            ctx.expression_path = -1
            hold idx_t = semaExprMode(edit ctx, source, tree, expr.b, ACCESS_READ)
            hold idx_op = lirTakeOperand(edit ctx, idx_t)
            give semaIndexFinish(edit ctx, source, tree, expr_id, mode, base_t, base_place, base_path, idx_t, idx_op)
        }
        AstExprKind.Match : {
            give 6
        }
        AstExprKind.Choose : {
            give semaChooseExpr(edit ctx, source, tree, expr, mode)
        }
        AstExprKind.Try : {
            hold input_t = semaExprMode(edit ctx, source, tree, expr.a, ACCESS_READ)
            hold input_path = ctx.expression_path
            hold input_place = ctx.lir.place
            give semaTryUnion(edit ctx, source, tree, expr, input_t, input_path, input_place, mode)
        }
        _ : {
            semaAddError(edit ctx, "L0016", "expresión fuera del subconjunto verificado de Stage 1", expr.start, expr.end)
            give 7
        }
    }
}

// Find a method by its nominal receiver type and receiver mode. The method
// declaration remains an ordinary Function in the shared semantic/LIR path.
flow semaExtensionFind(ctx: edit SemaContext, source: view Text, tree: view AstTree, owner_type: Int, name_start: Int, name_end: Int, receiver_mode: Int) => Int {
    when owner_type < 0 || owner_type >= ctx.types.types.length { give -1 }
    each i among 0..tree.declarations.length {
        hold ext = view tree.declarations[i]
        choose ext.kind {
            AstDeclKind.Extension : {
                hold ext_owner = semaResolveAstType(edit ctx, source, tree, ext.a)
                when ext_owner != owner_type { proceed }
                each m among 0..ext.d {
                    hold method_id = ext.c + m
                    when method_id < 0 || method_id >= tree.declarations.length { proceed }
                    hold method = view tree.declarations[method_id]
                    when method.c != receiver_mode { proceed }
                    when symbolNamesEqual(source, method.a, method.b, name_start, name_end) { give method_id }
                }
            }
            _ : {}
        }
    }
    give -1
}

flow semaExtensionRet(ctx: edit SemaContext, source: view Text, tree: view AstTree, method_id: Int) => Int {
    when method_id < 0 || method_id >= tree.declarations.length { give 7 }
    semaNoteCallee(edit ctx, method_id)
    give semaDeclRet(edit ctx, source, tree, method_id)
}

flow semaExtensionStaticCall(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    hold base = view tree.expressions[expr.a]
    choose base.kind {
        AstExprKind.Name : {}
        _ : { give -1 }
    }
    hold sym_id = semaLookupVisible(edit ctx, source, base.start, base.end)
    when sym_id < 0 { give -1 }
    choose ctx.symbols.symbols[sym_id].kind {
        SymbolKind.Struct : {}
        _ : { give -1 }
    }
    hold owner_type = ctx.symbols.symbols[sym_id].type_id
    hold method_id = semaExtensionFind(edit ctx, source, tree, owner_type, expr.b, expr.c, 2)
    when method_id < 0 { give -1 }
    hold method = view tree.declarations[method_id]
    hold first = expr.d
    hold count = tree.extra[first]
    when count != method.e {
        semaAddError(edit ctx, "L0004", "número incorrecto de argumentos en llamada", expr.start, expr.end)
        give 7
    }
    change loans: List of[Int] = List[]
    change args: List of[Int] = List[]
    each a among 0..count {
        hold arg_id = tree.extra[first + a + 1]
        hold param = view tree.params[method.d + a]
        hold param_t = semaResolveAstType(edit ctx, source, tree, param.type_id)
        when semaRefElem(ctx, param_t) >= 0 {
            hold arg_loan = semaRefArg(edit ctx, source, tree, arg_id, param_t, a)
            hold arg_place = ctx.lir.borrowed
            hold arg_mut = semaIsMutRef(ctx, param_t)
            loans@push(arg_loan)
            hold arg = lirArg(edit ctx.lir, true, arg_place, arg_mut)
            args@push(arg)
        } otherwise {
            loans@push(-1)
            ctx.expected_list_type = param_t
            hold actual = semaExprMode(edit ctx, source, tree, arg_id, ACCESS_MOVE)
            hold operand = lirTakeOperand(edit ctx, actual)
            args@push(lirArg(edit ctx.lir, false, operand, false))
            when !semTypeEquals(view ctx.types, actual, param_t) {
                semaAddError(edit ctx, "L0004", "tipo incompatible en argumento", expr.start, expr.end)
            }
        }
    }
    hold ret_t = semaExtensionRet(edit ctx, source, tree, method_id)
    hold call_site = ctx.borrow_site
    hold call_start = expr.start
    hold call_end = expr.end
    hold result = semaCallLoans(edit ctx, view loans, ret_t, call_site, call_start, call_end)
    semaCallLower(edit ctx, method_id, view args, ret_t)
    give result
}

flow semaExtensionInstanceCall(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, base_t: Int, base_place: Int, base_path: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    change owner_t = base_t
    hold referent = semaRefElem(ctx, owner_t)
    when referent >= 0 { owner_t = referent }
    when owner_t < 0 || owner_t >= ctx.types.types.length { give -1 }
    choose ctx.types.types[owner_t].kind {
        SemTypeKind.Struct : {}
        _ : { give -1 }
    }
    change method_id = semaExtensionFind(edit ctx, source, tree, owner_t, expr.b, expr.c, 0)
    when method_id < 0 { method_id = semaExtensionFind(edit ctx, source, tree, owner_t, expr.b, expr.c, 1) }
    when method_id < 0 { give -1 }
    hold method = view tree.declarations[method_id]
    hold mutable = method.c == 1
    change recv_path = base_path
    change recv_place = base_place
    when !mutable && base_path < 0 && base_place < 0 && referent < 0 {
        // The receiver is a call result: keep it in a temporary.
        hold base_expr = view tree.expressions[expr.a]
        recv_path = semaReceiverTemp(edit ctx, source, tree, owner_t, base_expr.start, base_expr.end)
        recv_place = lirPathPlace(edit ctx, recv_path)
    }
    when recv_path < 0 || recv_place < 0 {
        semaAddError(edit ctx, "L0012", "un método requiere un receptor que sea un lugar", expr.start, expr.end)
        give 7
    }
    hold receiver_ref_t = semaBorrowPlace(edit ctx, recv_path, owner_t, mutable, SITE_ARG, expr.start, expr.end)
    hold receiver_loan = ctx.pending_loan
    ctx.pending_loan = -1
    hold receiver_place = ctx.lir.borrowed
    hold first = expr.d
    hold count = tree.extra[first]
    when count != method.e {
        semaAddError(edit ctx, "L0004", "número incorrecto de argumentos en llamada", expr.start, expr.end)
        give 7
    }
    change loans: List of[Int] = List[]
    change args: List of[Int] = List[]
    loans@push(receiver_loan)
    args@push(lirArg(edit ctx.lir, true, receiver_place, mutable))
    each a among 0..count {
        hold arg_id = tree.extra[first + a + 1]
        hold param = view tree.params[method.d + a]
        hold param_t = semaResolveAstType(edit ctx, source, tree, param.type_id)
        when semaRefElem(ctx, param_t) >= 0 {
            hold arg_loan = semaRefArg(edit ctx, source, tree, arg_id, param_t, a + 1)
            hold arg_place = ctx.lir.borrowed
            hold arg_mut = semaIsMutRef(ctx, param_t)
            loans@push(arg_loan)
            hold arg = lirArg(edit ctx.lir, true, arg_place, arg_mut)
            args@push(arg)
        } otherwise {
            loans@push(-1)
            ctx.expected_list_type = param_t
            hold actual = semaExprMode(edit ctx, source, tree, arg_id, ACCESS_MOVE)
            hold operand = lirTakeOperand(edit ctx, actual)
            args@push(lirArg(edit ctx.lir, false, operand, false))
            when !semTypeEquals(view ctx.types, actual, param_t) {
                semaAddError(edit ctx, "L0004", "tipo incompatible en argumento", expr.start, expr.end)
            }
        }
    }
    hold ret_t = semaExtensionRet(edit ctx, source, tree, method_id)
    hold call_site = ctx.borrow_site
    hold call_start = expr.start
    hold call_end = expr.end
    hold result = semaCallLoans(edit ctx, view loans, ret_t, call_site, call_start, call_end)
    semaCallLower(edit ctx, method_id, view args, ret_t)
    ctx.pending_loan = -1
    give result
}

flow semaCollectionLit(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr: view AstExpr, is_array: Bool) => Int {
    hold first = expr.a
    hold count = expr.b
    change elem_t = 0
    when !is_array { elem_t = semaExpectedListElem(ctx) }
    ctx.expected_list_type = -1
    hold elem_context = elem_t
    change elements: List of[Int] = List[]
    each i among 0..count {
        // Each element gets the element type as its own (nested) context.
        ctx.expected_list_type = elem_context
        hold ti = semaExprMode(edit ctx, source, tree, tree.extra[first + i], ACCESS_MOVE)
        when elem_t == 0 { elem_t = ti }
        when !semTypeEquals(view ctx.types, elem_t, ti) {
            semaAddError(edit ctx, "L0003", "elementos heterogéneos en colección", expr.start, expr.end)
        }
        elements@push(lirTakeOperand(edit ctx, ti))
    }
    give semaFinishCollectionLit(edit ctx, expr, is_array, elem_t, view elements)
}

// A qualified enum variant constructor is parsed as a MethodCall on an
// enum name. Never type-check the enum name as a runtime object.
// Return -1 when this is an ordinary method call.
flow semaEnumVariantCall(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr: view AstExpr) => Int {
    when expr.a < 0 || expr.a >= tree.expressions.length { give -1 }
    hold base = view tree.expressions[expr.a]
    choose base.kind {
        AstExprKind.Name : {}
        _ : { give -1 }
    }
    hold sym_id = semaLookupVisible(edit ctx, source, base.start, base.end)
    when sym_id < 0 { give -1 }
    choose ctx.symbols.symbols[sym_id].kind {
        SymbolKind.Enum : {}
        _ : { give -1 }
    }
    hold decl_id = ctx.symbols.symbols[sym_id].decl_id
    hold enum_ty = ctx.symbols.symbols[sym_id].type_id
    when decl_id < 0 || decl_id >= tree.declarations.length { give 7 }
    hold decl = view tree.declarations[decl_id]
    hold first = expr.d
    hold argc = tree.extra[first]
    each v among 0..decl.d {
        hold variant = view tree.variants[decl.c + v]
        when !symbolNamesEqual(source, variant.name_start, variant.name_end, expr.b, expr.c) { proceed }
        when argc != variant.payload_count {
            semaAddError(edit ctx, "L0004", "cantidad de argumentos incorrecta para la variante", expr.start, expr.end)
            give 7
        }
        when argc > 1 {
            semaAddError(edit ctx, "L0016", "Stage 1 solo admite un payload primitivo por variante", expr.start, expr.end)
            give 7
        }
        change payload = LIR_NONE
        when argc == 1 {
            hold expected = semaResolveAstType(edit ctx, source, tree, tree.extra[variant.first_payload_index])
            hold actual = semaExprMode(edit ctx, source, tree, tree.extra[first + 1], ACCESS_MOVE)
            when expected != actual {
                semaAddError(edit ctx, "L0004", "tipo incompatible de payload de enum", expr.start, expr.end)
                give 7
            }
            when expected != 1 && expected != 4 && expected != 5 {
                semaAddError(edit ctx, "L0016", "payload propietario fuera del subconjunto nativo verificado", expr.start, expr.end)
                give 7
            }
            payload = lirTakeOperand(edit ctx, actual)
        }
        change enum_id = -1
        each k among 0..ctx.lir_module.en_decl.length {
            when ctx.lir_module.en_decl[k] == decl_id { enum_id = k }
        }
        when enum_id < 0 { lirMarkUnsupported(edit ctx.lir, expr.start); give 7 }
        hold value = lirNew(edit ctx, enum_ty, false, LIR_VARIANT, enum_id, v, payload)
        lirSetVal(edit ctx, value)
        give enum_ty
    }
    semaAddError(edit ctx, "L0001", "variante de enum no encontrada", expr.start, expr.end)
    give 7
}

// ---- File streams (P0-B) ---------------------------------------------------

flow semaFileOp(source: view Text, name_start: Int, name_end: Int) => Int {
    hold n_open = "fileOpen"
    hold n_read = "fileRead"
    hold n_write = "fileWrite"
    hold n_seek = "fileSeek"
    hold n_size = "fileSize"
    hold n_flush = "fileFlush"
    hold n_close = "fileClose"
    hold n_status = "fileStatus"
    when symbolNameEqualsText(source, name_start, name_end, n_open) { give LIR_PLATFORM_FILE_OPEN }
    when symbolNameEqualsText(source, name_start, name_end, n_read) { give LIR_PLATFORM_FILE_READ }
    when symbolNameEqualsText(source, name_start, name_end, n_write) { give LIR_PLATFORM_FILE_WRITE }
    when symbolNameEqualsText(source, name_start, name_end, n_seek) { give LIR_PLATFORM_FILE_SEEK }
    when symbolNameEqualsText(source, name_start, name_end, n_size) { give LIR_PLATFORM_FILE_SIZE }
    when symbolNameEqualsText(source, name_start, name_end, n_flush) { give LIR_PLATFORM_FILE_FLUSH }
    when symbolNameEqualsText(source, name_start, name_end, n_close) { give LIR_PLATFORM_FILE_CLOSE }
    when symbolNameEqualsText(source, name_start, name_end, n_status) { give LIR_PLATFORM_FILE_STATUS }
    give -1
}

flow semaFileUsage(op: Int) => Text {
    when op == LIR_PLATFORM_FILE_OPEN { give "fileOpen requiere (ruta: Text, modo: Int)" }
    when op == LIR_PLATFORM_FILE_READ { give "fileRead requiere (archivo: File, destino: List<Int> mutable, máximo: Int)" }
    when op == LIR_PLATFORM_FILE_WRITE { give "fileWrite requiere (archivo: File, bytes: List<Int>, cantidad: Int)" }
    when op == LIR_PLATFORM_FILE_SEEK { give "fileSeek requiere (archivo: File, desplazamiento: Int, origen: Int)" }
    when op == LIR_PLATFORM_FILE_CLOSE { give "fileClose requiere (archivo: File), que se consume" }
    give "la operación requiere (archivo: File)"
}

flow semaIsByteList(ctx: view SemaContext, ty: Int) => Bool {
    when ty < 8 || ty >= ctx.types.types.length { give false }
    choose ctx.types.types[ty].kind {
        SemTypeKind.List : { give ctx.types.types[ty].elem_type == 1 }
        _ : { give false }
    }
}

// The file builtins: fileOpen produces the linear File; fileClose consumes
// it (a move, so later use or a second close is a use-after-move); every
// other operation borrows it shared for the call. Returns -1 when the
// callee is not a file builtin.
flow semaFileBuiltin(ctx: edit SemaContext, source: view Text, tree: view AstTree, start: Int, end: Int, name_start: Int, name_end: Int, first_arg: Int, arg_count: Int) => Int {
    hold op = semaFileOp(source, name_start, name_end)
    when op < 0 { give -1 }
    change arity = 1
    when op == LIR_PLATFORM_FILE_OPEN { arity = 2 }
    when op == LIR_PLATFORM_FILE_READ || op == LIR_PLATFORM_FILE_WRITE || op == LIR_PLATFORM_FILE_SEEK { arity = 3 }
    hold usage = semaFileUsage(op)
    when arg_count != arity {
        semaAddError(edit ctx, "L0004", usage, start, end)
        give 7
    }
    hold file_t = semTypeMakeFile(edit ctx.types)
    change args: List of[Int] = List[]
    change loans: List of[Int] = List[]
    change res_t = 1
    when op == LIR_PLATFORM_FILE_OPEN {
        hold path_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
        hold path_loan = semaPlatformArgLoan(edit ctx, path_t, start, end)
        hold path = ctx.lir.borrowed
        hold mode_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 1], ACCESS_MOVE)
        hold mode = lirTakeOperand(edit ctx, mode_t)
        when path_t != 5 || mode_t != 1 {
            semaAddError(edit ctx, "L0004", usage, start, end)
            give 7
        }
        when path < 0 || path_loan < 0 {
            semaAddError(edit ctx, "L0016", "fileOpen requiere un lugar Text prestable", start, end)
            give 7
        }
        loans@push(path_loan)
        args@push(lirArg(edit ctx.lir, true, path, false))
        args@push(lirArg(edit ctx.lir, false, mode, false))
        res_t = file_t
    } otherwise when op == LIR_PLATFORM_FILE_CLOSE {
        hold close_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_MOVE)
        hold file = lirTakeOperand(edit ctx, close_t)
        when !semTypeIsFile(view ctx.types, close_t) {
            semaAddError(edit ctx, "L0004", usage, start, end)
            give 7
        }
        args@push(lirArg(edit ctx.lir, false, file, false))
    } otherwise {
        hold f_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
        hold f_loan = semaPlatformArgLoan(edit ctx, f_t, start, end)
        hold f_place = ctx.lir.borrowed
        when !semTypeIsFile(view ctx.types, f_t) {
            semaAddError(edit ctx, "L0004", usage, start, end)
            give 7
        }
        when f_place < 0 || f_loan < 0 {
            semaAddError(edit ctx, "L0016", "la operación requiere un lugar File prestable", start, end)
            give 7
        }
        loans@push(f_loan)
        args@push(lirArg(edit ctx.lir, true, f_place, false))
        when op == LIR_PLATFORM_FILE_READ || op == LIR_PLATFORM_FILE_WRITE {
            hold is_read = op == LIR_PLATFORM_FILE_READ
            hold b_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 1], ACCESS_READ)
            change b_loan = -1
            when is_read { b_loan = semaPlatformArgLoanEdit(edit ctx, b_t, start, end) }
            otherwise { b_loan = semaPlatformArgLoan(edit ctx, b_t, start, end) }
            hold b_place = ctx.lir.borrowed
            hold n_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 2], ACCESS_MOVE)
            hold n = lirTakeOperand(edit ctx, n_t)
            when !semaIsByteList(view ctx, b_t) || n_t != 1 {
                semaAddError(edit ctx, "L0004", usage, start, end)
                give 7
            }
            when b_place < 0 || b_loan < 0 {
                semaAddError(edit ctx, "L0016", "la operación requiere un lugar List<Int> prestable", start, end)
                give 7
            }
            loans@push(b_loan)
            args@push(lirArg(edit ctx.lir, true, b_place, is_read))
            args@push(lirArg(edit ctx.lir, false, n, false))
        } otherwise when op == LIR_PLATFORM_FILE_SEEK {
            hold o_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 1], ACCESS_MOVE)
            hold offset = lirTakeOperand(edit ctx, o_t)
            hold w_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 2], ACCESS_MOVE)
            hold whence = lirTakeOperand(edit ctx, w_t)
            when o_t != 1 || w_t != 1 {
                semaAddError(edit ctx, "L0004", usage, start, end)
                give 7
            }
            args@push(lirArg(edit ctx.lir, false, offset, false))
            args@push(lirArg(edit ctx.lir, false, whence, false))
        }
    }
    semaCallLoans(edit ctx, view loans, res_t, SITE_NONE, start, end)
    semaPlatformEmit(edit ctx, op, view args, res_t, true)
    give res_t
}

// ---- Native windows (P0-D) -----------------------------------------------

// Native clipboard transfers UTF-8 bytes in List<Int>. The read loan is
// exclusive and the backend commits the list only after a complete read.
flow semaClipboardBuiltin(ctx: edit SemaContext, source: view Text, tree: view AstTree, start: Int, end: Int, name_start: Int, name_end: Int, first_arg: Int, arg_count: Int) => Int {
    change op = -1
    hold write_name = "clipboardWriteBytes"
    hold read_name = "clipboardReadBytes"
    when symbolNameEqualsText(source, name_start, name_end, write_name) { op = LIR_PLATFORM_CLIPBOARD_WRITE }
    when symbolNameEqualsText(source, name_start, name_end, read_name) { op = LIR_PLATFORM_CLIPBOARD_READ }
    when op < 0 { give -1 }
    when arg_count != 2 {
        semaAddError(edit ctx, "L0004", "clipboard requiere (List<Int>, Int)", start, end)
        give 7
    }
    hold b_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
    change b_loan = -1
    when op == LIR_PLATFORM_CLIPBOARD_READ { b_loan = semaPlatformArgLoanEdit(edit ctx, b_t, start, end) }
    otherwise { b_loan = semaPlatformArgLoan(edit ctx, b_t, start, end) }
    hold b_place = ctx.lir.borrowed
    hold n_t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + 1], ACCESS_MOVE)
    hold n = lirTakeOperand(edit ctx, n_t)
    when !semaIsByteList(view ctx, b_t) || n_t != 1 {
        semaAddError(edit ctx, "L0004", "clipboard requiere (List<Int>, Int)", start, end)
        give 7
    }
    when b_place < 0 || b_loan < 0 {
        semaAddError(edit ctx, "L0016", "clipboard requiere un lugar List<Int> prestable", start, end)
        give 7
    }
    change loans: List of[Int] = List[]
    loans@push(b_loan)
    semaCallLoans(edit ctx, view loans, 1, SITE_NONE, start, end)
    change args: List of[Int] = List[]
    args@push(lirArg(edit ctx.lir, true, b_place, op == LIR_PLATFORM_CLIPBOARD_READ))
    args@push(lirArg(edit ctx.lir, false, n, false))
    semaPlatformEmit(edit ctx, op, view args, 1, true)
    give 1
}

flow semaWindowOp(source: view Text, name_start: Int, name_end: Int) => Int {
    hold n_open = "windowOpen"
    hold n_status = "windowStatus"
    hold n_next = "windowNext"
    hold n_fill = "windowFill"
    hold n_text = "windowText"
    hold n_present = "windowPresent"
    hold n_send = "windowSend"
    hold n_pixel = "windowPixel"
    hold n_close = "windowClose"
    when symbolNameEqualsText(source, name_start, name_end, n_open) { give LIR_PLATFORM_WINDOW_OPEN }
    when symbolNameEqualsText(source, name_start, name_end, n_status) { give LIR_PLATFORM_WINDOW_STATUS }
    when symbolNameEqualsText(source, name_start, name_end, n_next) { give LIR_PLATFORM_WINDOW_NEXT }
    when symbolNameEqualsText(source, name_start, name_end, n_fill) { give LIR_PLATFORM_WINDOW_FILL }
    when symbolNameEqualsText(source, name_start, name_end, n_text) { give LIR_PLATFORM_WINDOW_TEXT }
    when symbolNameEqualsText(source, name_start, name_end, n_present) { give LIR_PLATFORM_WINDOW_PRESENT }
    when symbolNameEqualsText(source, name_start, name_end, n_send) { give LIR_PLATFORM_WINDOW_SEND }
    when symbolNameEqualsText(source, name_start, name_end, n_pixel) { give LIR_PLATFORM_WINDOW_PIXEL }
    when symbolNameEqualsText(source, name_start, name_end, n_close) { give LIR_PLATFORM_WINDOW_CLOSE }
    hold n_cell = "windowCell"
    hold n_text_bytes = "windowTextBytes"
    when symbolNameEqualsText(source, name_start, name_end, n_cell) { give LIR_PLATFORM_WINDOW_CELL }
    when symbolNameEqualsText(source, name_start, name_end, n_text_bytes) { give LIR_PLATFORM_WINDOW_TEXT_BYTES }
    give -1
}

flow semaWindowUsage(op: Int) => Text {
    when op == LIR_PLATFORM_WINDOW_OPEN { give "windowOpen requiere (título: Text, ancho: Int, alto: Int)" }
    when op == LIR_PLATFORM_WINDOW_FILL { give "windowFill requiere (ventana: Window, x: Int, y: Int, ancho: Int, alto: Int, rgb: Int)" }
    when op == LIR_PLATFORM_WINDOW_TEXT { give "windowText requiere (ventana: Window, x: Int, y: Int, texto: Text, rgb: Int)" }
    when op == LIR_PLATFORM_WINDOW_SEND { give "windowSend requiere (ventana: Window, mensaje: Int, wparam: Int, lparam: Int)" }
    when op == LIR_PLATFORM_WINDOW_PIXEL { give "windowPixel requiere (ventana: Window, x: Int, y: Int)" }
    when op == LIR_PLATFORM_WINDOW_CLOSE { give "windowClose requiere (ventana: Window), que se consume" }
    when op == LIR_PLATFORM_WINDOW_TEXT_BYTES { give "windowTextBytes requiere (ventana: Window, x: Int, y: Int, bytes: List<Int>, cantidad: Int, rgb: Int)" }
    give "la operación requiere (ventana: Window)"
}

// The window builtins, checked and lowered from the shared resource table
// (lir_build.l): windowOpen produces the linear Window, windowClose
// consumes it (a move), every other operation borrows it shared for the
// call. Returns -1 when the callee is not a window builtin.
flow semaWindowBuiltin(ctx: edit SemaContext, source: view Text, tree: view AstTree, start: Int, end: Int, name_start: Int, name_end: Int, first_arg: Int, arg_count: Int) => Int {
    hold op = semaWindowOp(source, name_start, name_end)
    when op < 0 { give -1 }
    when arg_count != lirResourceArity(op) {
        semaAddError(edit ctx, "L0004", semaWindowUsage(op), start, end)
        give 7
    }
    hold window_t = semTypeMakeWindow(edit ctx.types)
    change args: List of[Int] = List[]
    change loans: List of[Int] = List[]
    each i among 0..arg_count {
        hold kind = lirResourceArgKind(op, i)
        when kind == 0 || kind == 5 {
            hold t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + i], ACCESS_MOVE)
            hold operand = lirTakeOperand(edit ctx, t)
            when (kind == 0 && t != 1) || (kind == 5 && !semTypeIsWindow(view ctx.types, t)) {
                semaAddError(edit ctx, "L0004", semaWindowUsage(op), start, end)
                give 7
            }
            args@push(lirArg(edit ctx.lir, false, operand, false))
        } otherwise {
            hold t = semaExprMode(edit ctx, source, tree, tree.extra[first_arg + i], ACCESS_READ)
            hold loan = semaPlatformArgLoan(edit ctx, t, start, end)
            hold place = ctx.lir.borrowed
            when (kind == 1 && !semTypeIsWindow(view ctx.types, t)) || (kind == 4 && t != 5) || (kind == 2 && !semaIsByteList(view ctx, t)) {
                semaAddError(edit ctx, "L0004", semaWindowUsage(op), start, end)
                give 7
            }
            when place < 0 || loan < 0 {
                semaAddError(edit ctx, "L0016", "la operación requiere un lugar prestable (Window o Text)", start, end)
                give 7
            }
            loans@push(loan)
            args@push(lirArg(edit ctx.lir, true, place, false))
        }
    }
    change res_t = 1
    when lirResourceOpens(op) { res_t = window_t }
    semaCallLoans(edit ctx, view loans, res_t, SITE_NONE, start, end)
    semaPlatformEmit(edit ctx, op, view args, res_t, true)
    give res_t
}
