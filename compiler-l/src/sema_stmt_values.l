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
import sema_loop_jump

// The independent let/var semantic path is separated to respect Stage 0
// CORE-1's strict 4096-token-per-module budget.
pub fn semaStmtLet(ctx: &mut SemaContext, source: &Text, tree: &AstTree, stmt_id: Int) -> Int {
    let stmt = &tree.statements[stmt_id]
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
            ctx.expected_union_type = -1
            if annot_t >= 0 {
                let contextual = semaResolveAstType(&mut ctx, source, tree, annot_t)
                if contextual >= 0 && contextual < ctx.types.types.length {
                    match ctx.types.types[contextual].kind {
                        SemTypeKind.Option => { ctx.expected_union_type = contextual }
                        SemTypeKind.Result => { ctx.expected_union_type = contextual }
                        _ => {}
                    }
                }
            }
            if annot_t >= 0 && val_e >= 0 && val_e < tree.expressions.length {
                match tree.expressions[val_e].kind {
                    AstExprKind.ListLit => { ctx.expected_list_type = semaResolveAstType(&mut ctx, source, tree, annot_t) }
                    _ => {}
                }
            }
            var val_type = semaExprMode(&mut ctx, source, tree, val_e, ACCESS_MOVE)
            ctx.expected_list_type = -1
            ctx.expected_union_type = -1
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
                if !loanBindReferenceRoot(&mut ctx.flow, own_path, loan) {
                    semaAddError(&mut ctx, "L0012", "vínculo de préstamo local inválido", stmt.start, stmt.end)
                }
                semaOrigin(&mut ctx, own_path, semaValueOrigin(source, tree, val_e))
            } else {
                semaOwn(&mut ctx, source, tree, own_path, val_type, semaValueOrigin(source, tree, val_e))
            }
            semaFlushTemps(&mut ctx, stmt.start, stmt.end)
    return 0
}
