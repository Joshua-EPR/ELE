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
            AstDeclKind.Const : {
                hold existing = scopeLookupCurrentModule(view ctx.scopes, view ctx.symbols, source, decl.a, decl.b, ctx.current_module)
                when existing >= 0 {
                    semaAddError(edit ctx, "L0002", "constante duplicada en el mismo ámbito", decl.start, decl.end)
                } otherwise {
                    change const_t = semaConstantType(edit ctx, source, tree, decl.d)
                    when decl.c >= 0 {
                        hold annotated = semaResolveAstType(edit ctx, source, tree, decl.c)
                        when !semTypeEquals(view ctx.types, const_t, annotated) {
                            semaAddError(edit ctx, "L0003", "tipo incompatible en constante", decl.start, decl.end)
                        }
                        const_t = annotated
                    }
                    hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Const, decl.a, decl.b, const_t, ctx.scopes.current_scope, false, decl.is_public, i, decl.start, decl.end)
                    symbolSetModule(edit ctx.symbols, sym_id, ctx.current_module)
                    scopeAddSymbol(edit ctx.scopes, sym_id)
                }
            }
            AstDeclKind.Import : {
                // Local module imports and std.io.print are recognized in Stage 1.
            }
        }
    }
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

flow semaConstantType(ctx: edit SemaContext, source: view Text, tree: view AstTree, id: Int) => Int {
    when id < 0 || id >= tree.expressions.length { give 7 }
    hold expr = view tree.expressions[id]
    choose expr.kind {
        AstExprKind.IntLit : { give 1 }
        AstExprKind.BoolLit : { give 4 }
        AstExprKind.TextLit : { give 5 }
        AstExprKind.UnitLit : { give 6 }
        AstExprKind.Unary : {
            when expr.b >= 0 && expr.c == expr.b + 1 && expr.b < source.byteLength && source@byteAt(expr.b) == 45 && expr.a >= 0 && expr.a < tree.expressions.length {
                choose tree.expressions[expr.a].kind {
                    AstExprKind.IntLit : { give 1 }
                    _ : {}
                }
            }
            semaAddError(edit ctx, "L0016", "la constante requiere un literal en este subconjunto", expr.start, expr.end)
            give 7
        }
        _ : {
            semaAddError(edit ctx, "L0016", "la constante requiere un literal en este subconjunto", expr.start, expr.end)
            give 7
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
                ctx.current_fn_is_async = decl.c == 1
                when ctx.current_fn_is_async {
                    semaAddError(edit ctx, "L0016", "async fuera del subconjunto de ownership de Stage 1", decl.start, decl.end)
                }
                hold first_p = decl.d
                hold p_count = decl.e
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
                        loanBindParam(edit ctx.flow, p_path, p, is_mut, param.start, param.end)
                        semaOrigin(edit ctx, p_path, -1 - p)
                    } otherwise {
                        semaOwn(edit ctx, source, tree, p_path, p_type, -1 - p)
                    }
                }
                ctx.lir.params = p_count
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
