take tokens
take ast
take sema_types
take symbols
take scopes
take ownership_l
take flow_cfg
take loans_l
take loans_check
take sema_context
take sema_borrow
take sema_drop
take drops_plan
take drops_verify
take drops_dump
take lir_build
take lir_module
take sema_expr
take sema_stmt
take sema_const

// Register nominal declarations before resolving function signatures and
// constants. Without this pass a function using a type defined later in the
// same module, or a type exported by another dependency, is order-dependent.
flow semaCollectNominalTypes(ctx: edit SemaContext, source: view Text, tree: view AstTree) {
    each i among 0..tree.declarations.length {
        hold decl = view tree.declarations[i]
        ctx.current_module = semaDeclModule(ctx, i)
        choose decl.kind {
            AstDeclKind.Struct : {
                hold existing = scopeLookupCurrentModule(view ctx.scopes, view ctx.symbols, source, decl.a, decl.b, ctx.current_module)
                when existing >= 0 {
                    semaAddError(edit ctx, "L0002", "struct duplicado en el mismo ámbito", decl.start, decl.end)
                } otherwise {
                    hold type_id = semTypeAdd(edit ctx.types, SemTypeKind.Struct, decl.a, decl.b, -1, i)
                    hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Struct, decl.a, decl.b, type_id, ctx.scopes.current_scope, false, decl.is_public, i, decl.start, decl.end)
                    symbolSetModule(edit ctx.symbols, sym_id, ctx.current_module)
                    scopeAddSymbol(edit ctx.scopes, sym_id)
                }
            }
            AstDeclKind.Enum : {
                hold existing = scopeLookupCurrentModule(view ctx.scopes, view ctx.symbols, source, decl.a, decl.b, ctx.current_module)
                when existing >= 0 {
                    semaAddError(edit ctx, "L0002", "enum duplicado en el mismo ámbito", decl.start, decl.end)
                } otherwise {
                    hold type_id = semTypeAdd(edit ctx.types, SemTypeKind.Enum, decl.a, decl.b, -1, i)
                    hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Enum, decl.a, decl.b, type_id, ctx.scopes.current_scope, false, decl.is_public, i, decl.start, decl.end)
                    symbolSetModule(edit ctx.symbols, sym_id, ctx.current_module)
                    scopeAddSymbol(edit ctx.scopes, sym_id)
                }
            }
            AstDeclKind.Extension : {}
            _ : {}
        }
    }
}

flow semaCollectDeclarations(ctx: edit SemaContext, source: view Text, tree: view AstTree) {
    semaCollectNominalTypes(edit ctx, source, tree)
    each i among 0..tree.declarations.length {
        hold decl = view tree.declarations[i]
        ctx.current_module = semaDeclModule(ctx, i)
        choose decl.kind {
            AstDeclKind.Function : {
                when astIsMethod(tree, i) { proceed }
                hold existing = scopeLookupCurrentModule(view ctx.scopes, view ctx.symbols, source, decl.a, decl.b, ctx.current_module)
                when existing >= 0 {
                    semaAddError(edit ctx, "L0002", "función duplicada en el mismo ámbito", decl.start, decl.end)
                } otherwise {
                    change ret_t = 6
                    when decl.f >= 0 {
                        ret_t = semaResolveAstType(edit ctx, source, tree, decl.f)
                    }
                    hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Func, decl.a, decl.b, ret_t, ctx.scopes.current_scope, false, decl.is_public, i, decl.start, decl.end)
                    symbolSetModule(edit ctx.symbols, sym_id, ctx.current_module)
                    scopeAddSymbol(edit ctx.scopes, sym_id)
                }
            }
            AstDeclKind.Struct : { semaRejectLinearMembers(edit ctx, source, tree, i, false) }
            AstDeclKind.Enum : { semaRejectLinearMembers(edit ctx, source, tree, i, true) }
            AstDeclKind.Extension : {
                hold owner_t = semaResolveAstType(edit ctx, source, tree, decl.a)
                when owner_t < 0 || owner_t >= ctx.types.types.length {
                    semaAddError(edit ctx, "L0003", "tipo receptor de extend inválido", decl.start, decl.end)
                } otherwise {
                    choose ctx.types.types[owner_t].kind {
                        SemTypeKind.Struct : {}
                        _ : { semaAddError(edit ctx, "L0003", "extend requiere un shape", decl.start, decl.end) }
                    }
                }
            }
            AstDeclKind.Const : {
                hold existing = scopeLookupCurrentModule(view ctx.scopes, view ctx.symbols, source, decl.a, decl.b, ctx.current_module)
                when existing >= 0 {
                    semaAddError(edit ctx, "L0002", "constante duplicada en el mismo ámbito", decl.start, decl.end)
                } otherwise {
                    hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Const, decl.a, decl.b, 7, ctx.scopes.current_scope, false, decl.is_public, i, decl.start, decl.end)
                    symbolSetModule(edit ctx.symbols, sym_id, ctx.current_module)
                    semaConstDeclare(edit ctx, i, sym_id)
                    scopeAddSymbol(edit ctx.scopes, sym_id)
                }
            }
            AstDeclKind.Import : {
                // Local module imports and std.io.print are recognized in Stage 1.
            }
        }
    }
    // Constants may reference constants declared after them.
    semaConstEvalAll(edit ctx, source, tree)
}

// A shape field or choice payload of a linear type is rejected (see
// semaRejectLinearElem): its owner's drop could not close it.
flow semaRejectLinearMembers(ctx: edit SemaContext, source: view Text, tree: view AstTree, d: Int, is_enum: Bool) {
    hold first = tree.declarations[d].c
    hold count = tree.declarations[d].d
    each m among first..(first + count) {
        when is_enum {
            hold payload = tree.variants[m].first_payload_index
            each k among 0..tree.variants[m].payload_count {
                hold pt = semaResolveAstType(edit ctx, source, tree, tree.extra[payload + k])
                semaRejectLinearElem(edit ctx, pt, tree.declarations[d].start, tree.declarations[d].end)
            }
        } otherwise {
            hold ft = semaFieldType(edit ctx, source, tree, m)
            semaRejectLinearElem(edit ctx, ft, tree.fields[m].start, tree.fields[m].end)
        }
    }
}

flow semaCheckDeclarations(ctx: edit SemaContext, source: view Text, tree: view AstTree) {
    each i among 0..tree.declarations.length {
        hold decl = view tree.declarations[i]
        choose decl.kind {
            AstDeclKind.Function : {
                ctx.current_module = semaDeclModule(ctx, i)
                scopePush(edit ctx.scopes)
                ctx.flow = flowNew()
                ctx.lir = lirFnNew()
                hold errors_before = ctx.errors.length
                semaDropReset(edit ctx)
                semaScopeEnter(edit ctx)
                change ret_t = 6
                when decl.f >= 0 {
                    ret_t = semaResolveAstType(edit ctx, source, tree, decl.f)
                }
                ctx.current_fn_ret_type = ret_t
                hold is_method = astIsMethod(tree, i)
                ctx.current_fn_is_async = (!is_method && decl.c == 1) || (is_method && decl.c == 3)
                when ctx.current_fn_is_async {
                    semaAddError(edit ctx, "L0016", "async fuera del subconjunto de ownership de Stage 1", decl.start, decl.end)
                }
                hold first_p = decl.d
                hold p_count = decl.e
                change receiver_count = 0
                when is_method && decl.c < 2 {
                    hold owner_ast = astMethodOwnerType(view tree, i)
                    hold owner_t = semaResolveAstType(edit ctx, source, tree, owner_ast)
                    hold receiver_t = semTypeMakeRef(edit ctx.types, owner_t, decl.c == 1)
                    hold recv_start = semaMethodReceiverStart(source, tree, decl.g, decl.a)
                    hold recv_end = recv_start + 4
                    hold recv_sym = symbolAdd(edit ctx.symbols, SymbolKind.Param, recv_start, recv_end, receiver_t, ctx.scopes.current_scope, false, false, -1, recv_start, recv_end)
                    scopeAddSymbol(edit ctx.scopes, recv_sym)
                    semaInitPath(edit ctx, recv_sym, recv_start, recv_end)
                    hold recv_path = ctx.symbols.symbols[recv_sym].move_path
                    hold recv_elem = semaRefElem(ctx, receiver_t)
                    hold recv_var = lirVar(edit ctx.lir, recv_elem, true)
                    lirBindPath(edit ctx.lir, recv_path, recv_var)
                    hold recv_mut = semaIsMutRef(ctx, receiver_t)
                    loanBindParam(edit ctx.flow, recv_path, 0, recv_mut, recv_start, recv_end)
                    semaOrigin(edit ctx, recv_path, -1)
                    receiver_count = 1
                }
                each p among 0..p_count {
                    hold param = view tree.params[first_p + p]
                    hold p_type = semaResolveAstType(edit ctx, source, tree, param.type_id)
                    hold scope_id = ctx.scopes.current_scope
                    hold p_sym = symbolAdd(edit ctx.symbols, SymbolKind.Param, param.name_start, param.name_end, p_type, scope_id, false, false, -1, param.start, param.end)
                    scopeAddSymbol(edit ctx.scopes, p_sym)
                    semaInitPath(edit ctx, p_sym, param.start, param.end)
                    hold p_path = ctx.symbols.symbols[p_sym].move_path
                    hold p_elem = semaRefElem(ctx, p_type)
                    when p_elem >= 0 {
                        hold param_var = lirVar(edit ctx.lir, p_elem, true)
                        lirBindPath(edit ctx.lir, p_path, param_var)
                    } otherwise {
                        hold param_var = lirVar(edit ctx.lir, p_type, false)
                        lirBindPath(edit ctx.lir, p_path, param_var)
                    }
                    when p_elem >= 0 {
                        hold is_mut = semaIsMutRef(ctx, p_type)
                        loanBindParam(edit ctx.flow, p_path, p + receiver_count, is_mut, param.start, param.end)
                        semaOrigin(edit ctx, p_path, -1 - p - receiver_count)
                    } otherwise {
                        semaOwn(edit ctx, source, tree, p_path, p_type, -1 - p - receiver_count)
                    }
                }
                ctx.lir.params = p_count + receiver_count
                hold body_s = decl.g
                when body_s >= 0 {
                    semaCheckStmt(edit ctx, source, tree, body_s)
                }
                // Falling off the end releases the parameters.
                semaScopeExit(edit ctx, decl.end, decl.end)
                ctx.flow.linear_types = semTypeLinearIds(view ctx.types)
                hold checked = flowVerify(edit ctx.flow, ret_t != 6 && ret_t != 7)
                ctx.flow_blocks += ctx.flow.blocks.length
                ctx.flow_edges += ctx.flow.predecessors.length
                ctx.flow_paths += ctx.flow.paths.length
                ctx.flow_iterations += checked.iterations
                when checked.status == 1 {
                    semaAddError(edit ctx, "L0005", "uso de valor movido, parcialmente movido o sin inicialización segura", checked.start, checked.end)
                } otherwise when checked.status == 2 {
                    semaAddError(edit ctx, "L0016", "límite del análisis de flujo excedido", decl.start, decl.end)
                } otherwise when checked.status == 3 {
                    semaAddError(edit ctx, "L0003", "la función requiere retorno explícito en cada salida alcanzable", decl.start, decl.end)
                } otherwise {
                    when checked.status == 4 {
                        hold leaked_name = semTypeLinearName(view ctx.types, checked.linear)
                        hold closer = semTypeCloser(view ctx.types, checked.linear)
                        hold leak_message = "{leaked_name} abierto al salir del ámbito: ciérralo con {closer} o muévelo (posible fuga del recurso)"
                        semaAddError(edit ctx, "L0005", leak_message, checked.start, checked.end)
                    } otherwise {
                    hold plan = semaCheckDrops(edit ctx, source, tree, decl.a, decl.start, decl.end)
                    semaCheckLoans(edit ctx, source, decl.start, decl.end)
                    when ctx.errors.length == errors_before {
                        semaLirFinish(edit ctx, source, tree, view plan, i)
                    }
                    }
                }
                scopePop(edit ctx.scopes)
            }
            _ : {}
        }
    }
}

// The first `this` Name node is the source key for the hidden receiver
// parameter. Methods that do not refer to `this` use their name as an
// unreachable synthetic key; it remains scoped to that function.
flow semaMethodReceiverStart(source: view Text, tree: view AstTree, body_id: Int, fallback: Int) => Int {
    change body_start = 0
    change body_end = source.byteLength
    when body_id >= 0 && body_id < tree.statements.length {
        body_start = tree.statements[body_id].start
        body_end = tree.statements[body_id].end
    }
    each i among 0..tree.expressions.length {
        hold expr = view tree.expressions[i]
        change is_name = false
        choose expr.kind {
            AstExprKind.Name : { is_name = true }
            _ : {}
        }
        when is_name && expr.start >= body_start && expr.end <= body_end && expr.end - expr.start == 4 {
            when source@byteAt(expr.start) == 116 && source@byteAt(expr.start + 1) == 104 && source@byteAt(expr.start + 2) == 105 && source@byteAt(expr.start + 3) == 115 {
                give expr.start
            }
        }
    }
    give fallback
}

// Drop plan of the function (drops_plan.l), proven by drops_verify.l. A
// rejected plan is an internal compiler error, not a user diagnostic.
flow semaCheckDrops(ctx: edit SemaContext, source: view Text, tree: view AstTree, name: Int, start: Int, end: Int) => DropPlan {
    change plan = dropElaborate(view ctx.flow)
    when ctx.drop_fault > 0 { dropInjectFault(view ctx.flow, edit plan, ctx.drop_fault) }
    ctx.drop_ops += plan.ops.length
    ctx.drop_flags += plan.flag_paths.length
    ctx.drop_count += plan.drops
    hold verdict = dropVerify(view ctx.flow, view plan)
    ctx.drop_iterations += verdict.iterations
    when verdict.status != 0 {
        hold code = verdict.status
        when ctx.lir.unsupported >= 0 {
            // An unsupported lowering (notably Option/Result match) may not
            // have a complete drop plan. It must fail as unsupported source,
            // while a bad plan in the supported subset remains an ICE.
            hold unsupported = ctx.lir.unsupported
            semaAddError(edit ctx, "L0016", "construcción fuera del subconjunto de la LIR v1 de ELE", unsupported, unsupported)
        } otherwise {
            semaAddError(edit ctx, "ICE", "error interno del compilador: plan de drops inválido (regla {code})", start, end)
        }
    }
    when ctx.dump_drops {
        dropDump(view ctx.flow, view plan, source, tree, name)
    }
    give plan
}

// Liveness and exclusivity of the function's loans (loans_check.l).
flow semaCheckLoans(ctx: edit SemaContext, source: view Text, start: Int, end: Int) {
    hold checked = loanVerify(edit ctx.flow)
    ctx.flow_loans += ctx.flow.loans.length
    ctx.loan_iterations += checked.iterations
    when checked.status == LOAN_LIMIT {
        semaAddError(edit ctx, "L0016", "límite del análisis de préstamos excedido", start, end)
    } otherwise when checked.status == LOAN_CONFLICT {
        hold origin = ctx.flow.loans[checked.loan].start
        hold line = loanLineAt(source, origin)
        hold col = loanColAt(source, origin)
        hold use_line = loanLineAt(source, checked.witness)
        hold use_col = loanColAt(source, checked.witness)
        semaAddError(edit ctx, "L0012", "préstamo incompatible con este acceso. Préstamo iniciado en {line}:{col}, uso vivo en {use_line}:{use_col}. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.", checked.start, checked.end)
    }
}

expose flow semaAnalyze(ctx: edit SemaContext, source: view Text, tree: view AstTree) {
    semaCheckRefTypes(edit ctx, tree)
    semaCollectDeclarations(edit ctx, source, tree)
    semaLirSetup(edit ctx, source, tree)
    semaCheckDeclarations(edit ctx, source, tree)
    semaLirComplete(edit ctx, source, tree)
}
