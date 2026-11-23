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
take sema_loop_jump

// The independent let/var semantic path is separated to respect Stage 0
// CORE-1's strict 4096-token-per-module budget.
expose flow semaStmtLet(ctx: edit SemaContext, source: view Text, tree: view AstTree, stmt_id: Int) => Int {
    hold stmt = view tree.statements[stmt_id]
            hold is_mut = stmt.c == 1
            hold annot_t = stmt.d
            hold val_e = stmt.e
            hold existing = scopeLookupCurrent(view ctx.scopes, view ctx.symbols, source, stmt.a, stmt.b)
            when existing >= 0 {
                semaAddError(edit ctx, "L0002", "variable duplicada en el mismo ámbito", stmt.start, stmt.end)
                give 0
            }
            ctx.borrow_site = SITE_LET
            when is_mut { ctx.borrow_site = SITE_VAR }
            ctx.pending_loan = -1
            ctx.expected_list_type = -1
            ctx.expected_union_type = -1
            when annot_t >= 0 {
                hold contextual = semaResolveAstType(edit ctx, source, tree, annot_t)
                when contextual >= 0 && contextual < ctx.types.types.length {
                    choose ctx.types.types[contextual].kind {
                        SemTypeKind.Option : { ctx.expected_union_type = contextual }
                        SemTypeKind.Result : { ctx.expected_union_type = contextual }
                        _ : {}
                    }
                }
            }
            when annot_t >= 0 && val_e >= 0 && val_e < tree.expressions.length {
                choose tree.expressions[val_e].kind {
                    AstExprKind.ListLit : { ctx.expected_list_type = semaResolveAstType(edit ctx, source, tree, annot_t) }
                    _ : {}
                }
            }
            change val_type = semaExprMode(edit ctx, source, tree, val_e, ACCESS_MOVE)
            ctx.expected_list_type = -1
            ctx.expected_union_type = -1
            hold loan = ctx.pending_loan
            ctx.pending_loan = -1
            when annot_t >= 0 {
                hold expected = semaResolveAstType(edit ctx, source, tree, annot_t)
                when loan >= 0 && !semTypeEquals(view ctx.types, val_type, expected) {
                    choose tree.expressions[val_e].kind {
                        AstExprKind.Call : {
                            semaAddError(edit ctx, "L0013", "el resultado prestado requiere let y una anotación de referencia compatible", stmt.start, stmt.end)
                        }
                        _ : {
                            semaAddError(edit ctx, "L0012", "la anotación debe coincidir con el modo & o &mut del préstamo", stmt.start, stmt.end)
                        }
                    }
                } otherwise when semaRefElem(ctx, expected) >= 0 && loan < 0 {
                    semaAddError(edit ctx, "L0012", "una referencia local se inicializa con un préstamo de un lugar", stmt.start, stmt.end)
                } otherwise when !semTypeEquals(view ctx.types, val_type, expected) {
                    hold exp_n = semTypeName(view ctx.types, source, expected)
                    hold act_n = semTypeName(view ctx.types, source, val_type)
                    semaAddError(edit ctx, "L0003", "discrepancia de tipos en 'let': esperado '{exp_n}', recibido '{act_n}'", stmt.start, stmt.end)
                } otherwise {
                    val_type = expected
                }
            }
            hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Var, stmt.a, stmt.b, val_type, ctx.scopes.current_scope, is_mut, false, -1, stmt.start, stmt.end)
            scopeAddSymbol(edit ctx.scopes, sym_id)
            semaInitPath(edit ctx, sym_id, stmt.start, stmt.end)
            hold own_path = ctx.symbols.symbols[sym_id].move_path
            lirLetBind(edit ctx, own_path, val_type, loan >= 0)
            when loan >= 0 {
                when !loanBindReferenceRoot(edit ctx.flow, own_path, loan) {
                    semaAddError(edit ctx, "L0012", "vínculo de préstamo local inválido", stmt.start, stmt.end)
                }
                semaOrigin(edit ctx, own_path, semaValueOrigin(source, tree, val_e))
            } otherwise {
                semaOwn(edit ctx, source, tree, own_path, val_type, semaValueOrigin(source, tree, val_e))
            }
            semaFlushTemps(edit ctx, stmt.start, stmt.end)
    give 0
}
