import tokens
import ast
import sema_types
import symbols
import scopes
import ownership_l
import flow_cfg
import loans_l
import loans_check
import sema_context
import sema_borrow
import sema_drop
import drops_plan
import drops_verify
import drops_dump
import lir_build
import lir_module
import sema_expr
import sema_stmt

// Register nominal declarations before resolving function signatures and
// constants. Without this pass a function using a type defined later in the
// same module, or a type exported by another dependency, is order-dependent.
fn semaCollectNominalTypes(ctx: &mut SemaContext, source: &Text, tree: &AstTree) {
    for i in 0..tree.declarations.length {
        let decl = &tree.declarations[i]
        ctx.current_module = semaDeclModule(ctx, i)
        match decl.kind {
            AstDeclKind.Struct => {
                let existing = scopeLookupCurrentModule(&ctx.scopes, &ctx.symbols, source, decl.a, decl.b, ctx.current_module)
                if existing >= 0 {
                    semaAddError(&mut ctx, "L0002", "struct duplicado en el mismo ámbito", decl.start, decl.end)
                } else {
                    let type_id = semTypeAdd(&mut ctx.types, SemTypeKind.Struct, decl.a, decl.b, -1, i)
                    let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Struct, decl.a, decl.b, type_id, ctx.scopes.current_scope, false, decl.is_public, i, decl.start, decl.end)
                    symbolSetModule(&mut ctx.symbols, sym_id, ctx.current_module)
                    scopeAddSymbol(&mut ctx.scopes, sym_id)
                }
            }
            AstDeclKind.Enum => {
                let existing = scopeLookupCurrentModule(&ctx.scopes, &ctx.symbols, source, decl.a, decl.b, ctx.current_module)
                if existing >= 0 {
                    semaAddError(&mut ctx, "L0002", "enum duplicado en el mismo ámbito", decl.start, decl.end)
                } else {
                    let type_id = semTypeAdd(&mut ctx.types, SemTypeKind.Enum, decl.a, decl.b, -1, i)
                    let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Enum, decl.a, decl.b, type_id, ctx.scopes.current_scope, false, decl.is_public, i, decl.start, decl.end)
                    symbolSetModule(&mut ctx.symbols, sym_id, ctx.current_module)
                    scopeAddSymbol(&mut ctx.scopes, sym_id)
                }
            }
            _ => {}
        }
    }
}

fn semaCollectDeclarations(ctx: &mut SemaContext, source: &Text, tree: &AstTree) {
    semaCollectNominalTypes(&mut ctx, source, tree)
    for i in 0..tree.declarations.length {
        let decl = &tree.declarations[i]
        ctx.current_module = semaDeclModule(ctx, i)
        match decl.kind {
            AstDeclKind.Function => {
                let existing = scopeLookupCurrentModule(&ctx.scopes, &ctx.symbols, source, decl.a, decl.b, ctx.current_module)
                if existing >= 0 {
                    semaAddError(&mut ctx, "L0002", "función duplicada en el mismo ámbito", decl.start, decl.end)
                } else {
                    var ret_t = 6
                    if decl.f >= 0 {
                        ret_t = semaResolveAstType(&mut ctx, source, tree, decl.f)
                    }
                    let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Func, decl.a, decl.b, ret_t, ctx.scopes.current_scope, false, decl.is_public, i, decl.start, decl.end)
                    symbolSetModule(&mut ctx.symbols, sym_id, ctx.current_module)
                    scopeAddSymbol(&mut ctx.scopes, sym_id)
                }
            }
            AstDeclKind.Struct => {}
            AstDeclKind.Enum => {}
            AstDeclKind.Const => {
                let existing = scopeLookupCurrentModule(&ctx.scopes, &ctx.symbols, source, decl.a, decl.b, ctx.current_module)
                if existing >= 0 {
                    semaAddError(&mut ctx, "L0002", "constante duplicada en el mismo ámbito", decl.start, decl.end)
                } else {
                    var const_t = semaConstantType(&mut ctx, source, tree, decl.d)
                    if decl.c >= 0 {
                        let annotated = semaResolveAstType(&mut ctx, source, tree, decl.c)
                        if !semTypeEquals(&ctx.types, const_t, annotated) {
                            semaAddError(&mut ctx, "L0003", "tipo incompatible en constante", decl.start, decl.end)
                        }
                        const_t = annotated
                    }
                    let sym_id = symbolAdd(&mut ctx.symbols, SymbolKind.Const, decl.a, decl.b, const_t, ctx.scopes.current_scope, false, decl.is_public, i, decl.start, decl.end)
                    symbolSetModule(&mut ctx.symbols, sym_id, ctx.current_module)
                    scopeAddSymbol(&mut ctx.scopes, sym_id)
                }
            }
            AstDeclKind.Import => {
                // Local module imports and std.io.print are recognized in Stage 1.
            }
        }
    }
}

fn semaConstantType(ctx: &mut SemaContext, source: &Text, tree: &AstTree, id: Int) -> Int {
    if id < 0 || id >= tree.expressions.length { return 7 }
    let expr = &tree.expressions[id]
    match expr.kind {
        AstExprKind.IntLit => { return 1 }
        AstExprKind.BoolLit => { return 4 }
        AstExprKind.TextLit => { return 5 }
        AstExprKind.UnitLit => { return 6 }
        AstExprKind.Unary => {
            if expr.b >= 0 && expr.c == expr.b + 1 && expr.b < source.byteLength && source.byteAt(expr.b) == 45 && expr.a >= 0 && expr.a < tree.expressions.length {
                match tree.expressions[expr.a].kind {
                    AstExprKind.IntLit => { return 1 }
                    _ => {}
                }
            }
            semaAddError(&mut ctx, "L0016", "la constante requiere un literal en este subconjunto", expr.start, expr.end)
            return 7
        }
        _ => {
            semaAddError(&mut ctx, "L0016", "la constante requiere un literal en este subconjunto", expr.start, expr.end)
            return 7
        }
    }
}

fn semaCheckDeclarations(ctx: &mut SemaContext, source: &Text, tree: &AstTree) {
    for i in 0..tree.declarations.length {
        let decl = &tree.declarations[i]
        match decl.kind {
            AstDeclKind.Function => {
                ctx.current_module = semaDeclModule(ctx, i)
                scopePush(&mut ctx.scopes)
                ctx.flow = flowNew()
                ctx.lir = lirFnNew()
                let errors_before = ctx.errors.length
                semaDropReset(&mut ctx)
                semaScopeEnter(&mut ctx)
                var ret_t = 6
                if decl.f >= 0 {
                    ret_t = semaResolveAstType(&mut ctx, source, tree, decl.f)
                }
                ctx.current_fn_ret_type = ret_t
                ctx.current_fn_is_async = decl.c == 1
                if ctx.current_fn_is_async {
                    semaAddError(&mut ctx, "L0016", "async fuera del subconjunto de ownership de Stage 1", decl.start, decl.end)
                }
                let first_p = decl.d
                let p_count = decl.e
                for p in 0..p_count {
                    let param = &tree.params[first_p + p]
                    let p_type = semaResolveAstType(&mut ctx, source, tree, param.type_id)
                    let scope_id = ctx.scopes.current_scope
                    let p_sym = symbolAdd(&mut ctx.symbols, SymbolKind.Param, param.name_start, param.name_end, p_type, scope_id, false, false, -1, param.start, param.end)
                    scopeAddSymbol(&mut ctx.scopes, p_sym)
                    semaInitPath(&mut ctx, p_sym, param.start, param.end)
                    let p_path = ctx.symbols.symbols[p_sym].move_path
                    let p_elem = semaRefElem(ctx, p_type)
                    if p_elem >= 0 {
                        let param_var = lirVar(&mut ctx.lir, p_elem, true)
                        lirBindPath(&mut ctx.lir, p_path, param_var)
                    } else {
                        let param_var = lirVar(&mut ctx.lir, p_type, false)
                        lirBindPath(&mut ctx.lir, p_path, param_var)
                    }
                    if p_elem >= 0 {
                        let is_mut = semaIsMutRef(ctx, p_type)
                        loanBindParam(&mut ctx.flow, p_path, p, is_mut, param.start, param.end)
                        semaOrigin(&mut ctx, p_path, -1 - p)
                    } else {
                        semaOwn(&mut ctx, source, tree, p_path, p_type, -1 - p)
                    }
                }
                ctx.lir.params = p_count
                let body_s = decl.g
                if body_s >= 0 {
                    semaCheckStmt(&mut ctx, source, tree, body_s)
                }
                // Falling off the end releases the parameters.
                semaScopeExit(&mut ctx, decl.end, decl.end)
                let checked = flowVerify(&mut ctx.flow, ret_t != 6 && ret_t != 7)
                ctx.flow_blocks += ctx.flow.blocks.length
                ctx.flow_edges += ctx.flow.predecessors.length
                ctx.flow_paths += ctx.flow.paths.length
                ctx.flow_iterations += checked.iterations
                if checked.status == 1 {
                    semaAddError(&mut ctx, "L0005", "uso de valor movido, parcialmente movido o sin inicialización segura", checked.start, checked.end)
                } else if checked.status == 2 {
                    semaAddError(&mut ctx, "L0016", "límite del análisis de flujo excedido", decl.start, decl.end)
                } else if checked.status == 3 {
                    semaAddError(&mut ctx, "L0003", "la función requiere retorno explícito en cada salida alcanzable", decl.start, decl.end)
                } else {
                    let plan = semaCheckDrops(&mut ctx, source, tree, decl.a, decl.start, decl.end)
                    semaCheckLoans(&mut ctx, source, decl.start, decl.end)
                    if ctx.errors.length == errors_before {
                        semaLirFinish(&mut ctx, source, tree, &plan, i)
                    }
                }
                scopePop(&mut ctx.scopes)
            }
            _ => {}
        }
    }
}

// Drop plan of the function (drops_plan.l), proven by drops_verify.l. A
// rejected plan is an internal compiler error, not a user diagnostic.
fn semaCheckDrops(ctx: &mut SemaContext, source: &Text, tree: &AstTree, name: Int, start: Int, end: Int) -> DropPlan {
    var plan = dropElaborate(&ctx.flow)
    if ctx.drop_fault > 0 { dropInjectFault(&ctx.flow, &mut plan, ctx.drop_fault) }
    ctx.drop_ops += plan.ops.length
    ctx.drop_flags += plan.flag_paths.length
    ctx.drop_count += plan.drops
    let verdict = dropVerify(&ctx.flow, &plan)
    ctx.drop_iterations += verdict.iterations
    if verdict.status != 0 {
        let code = verdict.status
        if ctx.lir.unsupported >= 0 {
            // An unsupported lowering (notably Option/Result match) may not
            // have a complete drop plan. It must fail as unsupported source,
            // while a bad plan in the supported subset remains an ICE.
            let unsupported = ctx.lir.unsupported
            semaAddError(&mut ctx, "L0016", "construcción fuera del subconjunto de la LIR v1 de ELE", unsupported, unsupported)
        } else {
            semaAddError(&mut ctx, "ICE", "error interno del compilador: plan de drops inválido (regla {code})", start, end)
        }
    }
    if ctx.dump_drops {
        dropDump(&ctx.flow, &plan, source, tree, name)
    }
    return plan
}

// Liveness and exclusivity of the function's loans (loans_check.l).
fn semaCheckLoans(ctx: &mut SemaContext, source: &Text, start: Int, end: Int) {
    let checked = loanVerify(&mut ctx.flow)
    ctx.flow_loans += ctx.flow.loans.length
    ctx.loan_iterations += checked.iterations
    if checked.status == LOAN_LIMIT {
        semaAddError(&mut ctx, "L0016", "límite del análisis de préstamos excedido", start, end)
    } else if checked.status == LOAN_CONFLICT {
        let origin = ctx.flow.loans[checked.loan].start
        let line = loanLineAt(source, origin)
        let col = loanColAt(source, origin)
        let use_line = loanLineAt(source, checked.witness)
        let use_col = loanColAt(source, checked.witness)
        semaAddError(&mut ctx, "L0012", "préstamo incompatible con este acceso. Préstamo iniciado en {line}:{col}, uso vivo en {use_line}:{use_col}. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.", checked.start, checked.end)
    }
}

pub fn semaAnalyze(ctx: &mut SemaContext, source: &Text, tree: &AstTree) {
    semaCheckRefTypes(&mut ctx, tree)
    semaCollectDeclarations(&mut ctx, source, tree)
    semaLirSetup(&mut ctx, source, tree)
    semaCheckDeclarations(&mut ctx, source, tree)
    semaLirComplete(&mut ctx, source, tree)
}
