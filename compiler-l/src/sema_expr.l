import tokens
import sema_borrow_syntax
import sema_expr_temp
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
import sema_ops
import sema_collection_ops
import stmt_lower
import sema_builtin_union
import lir_builtin_union

fn semaCheckConstructor(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr: &AstExpr, decl_id: Int, struct_t: Int) {
    let decl = &tree.declarations[decl_id]
    var seen: List<Bool> = List[]
    var slots: List<Int> = List[]
    for i in 0..decl.d {
        seen.push(false)
        slots.push(LIR_NONE)
    }
    for i in 0..expr.d {
        let arg = &tree.expressions[tree.extra[expr.c + i]]
        // The declared field type is the context of an empty `List[]`.
        let field = semaNamedField(source, tree, decl_id, arg)
        if field >= 0 { ctx.expected_list_type = semaFieldType(&mut ctx, source, tree, field) }
        let ty = semaExprMode(&mut ctx, source, tree, arg.c, ACCESS_MOVE)
        semaConstructorField(&mut ctx, source, tree, decl_id, arg, ty, &mut seen, &mut slots)
    }
    semaConstructorFinish(&mut ctx, tree, expr, decl_id, struct_t, &seen, &slots)
}

pub fn semaCheckExpr(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int) -> Int {
    return semaExprMode(&mut ctx, source, tree, expr_id, ACCESS_READ)
}

// `&place` / `&mut place`: only a let initializer, a reference argument
// or a borrowed return may hold a borrow (Stage 0 rules).
fn semaBorrowExpr(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, site: Int) -> Int {
    let expr = &tree.expressions[expr_id]
    let is_mut = semaBorrowSyntaxKind(source, expr.b, expr.c) == 2
    if site == SITE_VAR || semaPlaceRoot(tree, expr.a) < 0 {
        semaAddError(&mut ctx, "L0012", "use let para prestar una variable, campo o elemento con un origen fijo", expr.start, expr.end)
        return 7
    }
    if site == SITE_NONE {
        semaAddError(&mut ctx, "L0001", "un préstamo (&, &mut) solo puede pasarse directamente como argumento a un parámetro de referencia; guardarlo o devolverlo requiere anotaciones de vida aún no implementadas", expr.start, expr.end)
        return 7
    }
    let operand_t = semaExprMode(&mut ctx, source, tree, expr.a, ACCESS_PLACE)
    let path = ctx.expression_path
    ctx.expression_path = -1
    let operand_place = ctx.lir.place
    // The loan starts at the borrowed place, as Stage 0 reports it.
    let place = &tree.expressions[expr.a]
    let ty = semaBorrowPlace(&mut ctx, path, operand_t, is_mut, site, place.start, place.end)
    // The flow path of an indexed operand is its collection, but the
    // reference must point at the element: keep the place of the operand.
    if operand_place >= 0 && ctx.lir.borrowed >= 0 { ctx.lir.borrowed = operand_place }
    if site != SITE_ARG && ctx.lir.borrowed >= 0 {
        var mutable = 0
        if is_mut { mutable = 1 }
        let referent = semaRefElem(ctx, ty)
        let borrowed_place = ctx.lir.borrowed
        let value = lirNew(&mut ctx, referent, true, LIR_LOAN, borrowed_place, mutable, 0)
        lirSetVal(&mut ctx, value)
    }
    return ty
}

// Argument for a reference parameter: an explicit borrow of the same mode
// or, for `&T`, a place that is borrowed implicitly. Returns the loan.
fn semaRefArg(ctx: &mut SemaContext, source: &Text, tree: &AstTree, arg_id: Int, param_t: Int, index: Int) -> Int {
    let arg = &tree.expressions[arg_id]
    let param_mut = semaIsMutRef(ctx, param_t)
    let n = index + 1
    var explicit = false
    var arg_mut = false
    match arg.kind {
        AstExprKind.Unary => {
            let kind = semaBorrowSyntaxKind(source, arg.b, arg.c)
            if kind > 0 {
                explicit = true
                arg_mut = kind == 2
            }
        }
        _ => {}
    }
    if param_mut && !arg_mut {
        semaAddError(&mut ctx, "L0001", "se esperaba un préstamo mutable (&mut) para el parámetro {n}", arg.start, arg.end)
        return -1
    }
    if !param_mut && arg_mut {
        semaAddError(&mut ctx, "L0001", "el parámetro {n} es &T: pase '&' en lugar de '&mut'", arg.start, arg.end)
        return -1
    }
    var ty = 7
    if explicit {
        ctx.borrow_site = SITE_ARG
        ty = semaExprMode(&mut ctx, source, tree, arg_id, ACCESS_MOVE)
    } else {
        if semaPlaceRoot(tree, arg_id) < 0 {
            semaAddError(&mut ctx, "L0001", "el parámetro {n} es una referencia (&T): pase una variable o un campo, que se presta automáticamente", arg.start, arg.end)
            return -1
        }
        let operand_t = semaExprMode(&mut ctx, source, tree, arg_id, ACCESS_PLACE)
        let path = ctx.expression_path
        ctx.expression_path = -1
        ty = semaBorrowPlace(&mut ctx, path, operand_t, false, SITE_ARG, arg.start, arg.end)
    }
    let loan = ctx.pending_loan
    ctx.pending_loan = -1
    if !semTypeEquals(&ctx.types, semaRefElem(ctx, ty), semaRefElem(ctx, param_t)) {
        semaAddError(&mut ctx, "L0004", "tipo incompatible en argumento", arg.start, arg.end)
    }
    return loan
}

// A value read by print or an interpolation that is not a place and not a
// literal is an owned temporary of the enclosing statement.
pub fn semaExprMode(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, mode: Int) -> Int {
    ctx.expression_path = -1
    if expr_id < 0 || expr_id >= tree.expressions.length {
        return 7
    }
    // Instructions of this expression carry its start (runtime messages).
    let outer_at = ctx.lir.at
    ctx.lir.at = tree.expressions[expr_id].start
    // A list context set by the caller belongs to this expression only when
    // it is the list literal itself (or a named argument wrapping it); it
    // never reaches unrelated subexpressions.
    let expected_list = ctx.expected_list_type
    ctx.expected_list_type = -1
    match tree.expressions[expr_id].kind {
        AstExprKind.ListLit => { ctx.expected_list_type = expected_list }
        AstExprKind.Named => { ctx.expected_list_type = expected_list }
        _ => {}
    }
    let ty = semaInferExpr(&mut ctx, source, tree, expr_id, mode)
    ctx.expected_list_type = -1
    ctx.lir.at = outer_at
    match tree.expressions[expr_id].kind {
        AstExprKind.Name => {}
        AstExprKind.Field => {}
        AstExprKind.Index => {}
        _ => { ctx.expression_path = -1 }
    }
    return ty
}

fn semaInferExpr(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, mode: Int) -> Int {
    let expr = &tree.expressions[expr_id]
    let site = ctx.borrow_site
    ctx.borrow_site = SITE_NONE
    match expr.kind {
        AstExprKind.IntLit => { return semaLiteral(&mut ctx, source, tree, expr_id, 1) }
        AstExprKind.BoolLit => { return semaLiteral(&mut ctx, source, tree, expr_id, 4) }
        AstExprKind.TextLit => { return semaLiteral(&mut ctx, source, tree, expr_id, 5) }
        AstExprKind.UnitLit => { return semaLiteral(&mut ctx, source, tree, expr_id, 6) }
        AstExprKind.Interpolate => {
            let buffer = lirNew(&mut ctx, 5, false, LIR_TEXTBUF, semaInterpCapacity(tree, expr_id), 0, 0)
            for i in 0..expr.b {
                let part = tree.extra[expr.a + i]
                let mark = ctx.pending_temps.length
                let ty = semaCheckExpr(&mut ctx, source, tree, part)
                semaReadTemp(&mut ctx, source, tree, part, ty, mark)
                if ty < 1 || ty > 5 {
                    semaAddError(&mut ctx, "L0003", "tipo no imprimible en interpolación", expr.start, expr.end)
                }
                semaAppendPart(&mut ctx, tree, buffer, part, ty)
            }
            lirSetVal(&mut ctx, buffer)
            return 5
        }
        AstExprKind.Name => {
            return semaNameExpr(&mut ctx, source, tree, expr_id, mode, site)
        }
        AstExprKind.Binary => {
            let lhs_t = semaCheckExpr(&mut ctx, source, tree, expr.a)
            var rhs_t = 7
            let op = source.byteAt(expr.c)
            if op == 63 {
                semaAddError(&mut ctx, "L0016", "operación de Option fuera del subconjunto verificado", expr.start, expr.end)
                return 7
            }
            let lhs = lirTakeOperand(&mut ctx, lhs_t)
            var rhs = LIR_NONE
            if op == 38 || op == 124 {
                let rhs_block = flowBlock(&mut ctx.flow)
                let join = flowBlock(&mut ctx.flow)
                let result = semaShortVar(&mut ctx, lhs, op == 124)
                flowLink(&mut ctx.flow, rhs_block, join)
                ctx.flow.current = rhs_block
                rhs_t = semaCheckExpr(&mut ctx, source, tree, expr.b)
                let rhs_value = lirTakeOperand(&mut ctx, rhs_t)
                lirAt(&mut ctx, LIR_USE, result, rhs_value, 0, 0)
                flowLink(&mut ctx.flow, join, -1)
                ctx.flow.current = join
                rhs = result
            } else {
                rhs_t = semaCheckExpr(&mut ctx, source, tree, expr.b)
                rhs = lirTakeOperand(&mut ctx, rhs_t)
            }
            return semaBinaryFinish(&mut ctx, source, tree, expr_id, lhs_t, rhs_t, lhs, rhs)
        }
        AstExprKind.Unary => {
            if expr.b >= 0 && expr.b < source.byteLength {
                let op = source.byteAt(expr.b)
                if semaBorrowSyntaxKind(source, expr.b, expr.c) > 0 {
                    return semaBorrowExpr(&mut ctx, source, tree, expr_id, site)
                }
                if op == 42 {
                    semaAddError(&mut ctx, "L0012", "la desreferencia explícita está fuera del subconjunto verificado de Stage 1", expr.start, expr.end)
                    return 7
                }
            }
            let sub_t = semaCheckExpr(&mut ctx, source, tree, expr.a)
            let operand = lirTakeOperand(&mut ctx, sub_t)
            return semaUnaryFinish(&mut ctx, source, tree, expr_id, sub_t, operand)
        }
        AstExprKind.Call => {
            let name_start = expr.a
            let name_end = expr.b
            let first_arg = expr.c
            let arg_count = expr.d
            let print_name = "print"
            let name_ok = "Ok"
            let name_err = "Err"
            let name_some = "Some"
            if symbolNameEqualsText(source, name_start, name_end, print_name) {
                if arg_count == 1 {
                    let arg = tree.extra[first_arg]
                    let mark = ctx.pending_temps.length
                    let ty = semaCheckExpr(&mut ctx, source, tree, arg)
                    semaReadTemp(&mut ctx, source, tree, arg, ty, mark)
                    if ty >= 1 && ty <= 5 {
                        let printed = lirTakeArg(&mut ctx, ty)
                        lirAt(&mut ctx, LIR_PRINT, -1, printed, 0, 0)
                        let unit = lirConst(&mut ctx.lir, LIR_CONST_UNIT, 0, 0, 0)
                        lirSetVal(&mut ctx, unit)
                        return 6
                    }
                }
                semaAddError(&mut ctx, "L0004", "print requiere un argumento imprimible", expr.start, expr.end)
                return 7
            }
            var builtin_variant = -1
            if symbolNameEqualsText(source, name_start, name_end, name_ok) { builtin_variant = 0 }
            if symbolNameEqualsText(source, name_start, name_end, name_err) { builtin_variant = 1 }
            if symbolNameEqualsText(source, name_start, name_end, name_some) { builtin_variant = 2 }
            if builtin_variant >= 0 && arg_count == 1 {
                // A nested expression must not inherit the result union type
                // of its constructor's own expected destination.
                // Only a nested Option/Result payload type is propagated
                // (e.g. `Some(Ok(x))` against Option<Result<T, E>>).
                let contextual = ctx.expected_union_type
                ctx.expected_union_type = semaBuiltinPayloadExpected(ctx, contextual, builtin_variant)
                let arg_t = semaExprMode(&mut ctx, source, tree, tree.extra[first_arg], ACCESS_MOVE)
                let payload = lirTakeOperand(&mut ctx, arg_t)
                ctx.expected_union_type = contextual
                return semaBuiltinUnionValue(&mut ctx, arg_t, payload, builtin_variant, expr.start, expr.end)
            }
            let name_print_err = "printError"
            if symbolNameEqualsText(source, name_start, name_end, name_print_err) && arg_count == 1 {
                let mark = ctx.pending_temps.length
                let ty = semaCheckExpr(&mut ctx, source, tree, tree.extra[first_arg])
                semaReadTemp(&mut ctx, source, tree, tree.extra[first_arg], ty, mark)
                if ty == 5 || semaRefElem(ctx, ty) == 5 {
                    if ctx.lir.place < 0 {
                        if ctx.pending_temps.length == mark {
                            semaTemp(&mut ctx, source, tree, 5, expr.start, expr.end)
                        }
                        let temp_var = ctx.lir.val
                        if temp_var >= 0 {
                            ctx.lir.place = lirPlaceVar(&mut ctx.lir, temp_var)
                        }
                    }
                    if ctx.lir.place < 0 { lirMarkUnsupported(&mut ctx.lir, expr.start) }
                    var args: List<Int> = List[]
                    args.push(lirTakeArg(&mut ctx, ty))
                    semaPlatformEmit(&mut ctx, LIR_PLATFORM_PRINT_ERROR, &args, 6, false)
                    return 6
                }
                semaAddError(&mut ctx, "L0004", "printError requiere un argumento Text o &Text", expr.start, expr.end)
                return 7
            }
            let name_arg_count = "processArgCount"
            if symbolNameEqualsText(source, name_start, name_end, name_arg_count) && arg_count == 0 {
                var args: List<Int> = List[]
                semaPlatformEmit(&mut ctx, 0, &args, 1, true)
                return 1
            }
            let name_arg = "processArg"
            if symbolNameEqualsText(source, name_start, name_end, name_arg) && arg_count == 1 {
                let ty = semaExprMode(&mut ctx, source, tree, tree.extra[first_arg], ACCESS_MOVE)
                if ty == 1 {
                    var args: List<Int> = List[]
                    let operand = lirTakeOperand(&mut ctx, 1)
                    let argument = lirArg(&mut ctx.lir, false, operand, false)
                    args.push(argument)
                    let res_t = semTypeMakeResult(&mut ctx.types, 5, 1)
                    if lirBuiltinRegister(&mut ctx.lir_module, &ctx.types, res_t) < 0 { lirMarkUnsupported(&mut ctx.lir, expr.start) }
                    semaPlatformEmit(&mut ctx, 1, &args, res_t, true)
                    return res_t
                }
                semaAddError(&mut ctx, "L0004", "processArg requiere un argumento Int", expr.start, expr.end)
                return 7
            }
            let name_read_text = "readText"
            if symbolNameEqualsText(source, name_start, name_end, name_read_text) {
                if arg_count != 2 {
                    semaAddError(&mut ctx, "L0004", "readText requiere (path: &Text, max_len: Int)", expr.start, expr.end)
                    return 7
                }
                // Do not consume ctx.lir after visiting the second argument:
                // it replaces the expression channel used by the first.
                let path_t = semaExprMode(&mut ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
                if path_t != 5 {
                    semaAddError(&mut ctx, "L0004", "readText requiere (path: &Text, max_len: Int)", expr.start, expr.end)
                    return 7
                }
                let path_loan = semaPlatformArgLoan(&mut ctx, path_t, expr.start, expr.end)
                let path = ctx.lir.borrowed
                let len_t = semaExprMode(&mut ctx, source, tree, tree.extra[first_arg + 1], ACCESS_MOVE)
                let len = lirTakeOperand(&mut ctx, len_t)
                if len_t != 1 {
                    semaAddError(&mut ctx, "L0004", "readText requiere (path: &Text, max_len: Int)", expr.start, expr.end)
                    return 7
                }
                if path < 0 || path_loan < 0 {
                    semaAddError(&mut ctx, "L0016", "readText requiere un lugar Text prestable; los temporales propietarios no están soportados", expr.start, expr.end)
                    return 7
                }
                var loans: List<Int> = List[]
                loans.push(path_loan)
                semaCallLoans(&mut ctx, &loans, 1, SITE_NONE, expr.start, expr.end)
                var args: List<Int> = List[]
                let path_arg = lirArg(&mut ctx.lir, true, path, false)
                args.push(path_arg)
                let len_arg = lirArg(&mut ctx.lir, false, len, false)
                args.push(len_arg)
                let res_t = semTypeMakeResult(&mut ctx.types, 5, 1)
                // Result<Text, Int> owns its active Text (#5): a registered
                // builtin union with an atomic drop obligation.
                if lirBuiltinRegister(&mut ctx.lir_module, &ctx.types, res_t) < 0 { lirMarkUnsupported(&mut ctx.lir, expr.start) }
                semaPlatformEmit(&mut ctx, LIR_PLATFORM_READ_TEXT, &args, res_t, true)
                return res_t
            }
            let name_write_bytes = "writeBytes"
            if symbolNameEqualsText(source, name_start, name_end, name_write_bytes) {
                if arg_count != 2 {
                    semaAddError(&mut ctx, "L0004", "writeBytes requiere (Text, List<Int>)", expr.start, expr.end)
                    return 7
                }
                // Materialize each shared loan before evaluating the next argument:
                // a plain FLOW_READ does not protect a previous argument.
                let path_ty = semaExprMode(&mut ctx, source, tree, tree.extra[first_arg], ACCESS_READ)
                let path_loan = semaPlatformArgLoan(&mut ctx, path_ty, expr.start, expr.end)
                let path = ctx.lir.borrowed
                let bytes_ty = semaExprMode(&mut ctx, source, tree, tree.extra[first_arg + 1], ACCESS_READ)
                let bytes_loan = semaPlatformArgLoan(&mut ctx, bytes_ty, expr.start, expr.end)
                let bytes = ctx.lir.borrowed
                var loans: List<Int> = List[]
                loans.push(path_loan)
                loans.push(bytes_loan)
                semaCallLoans(&mut ctx, &loans, 1, SITE_NONE, expr.start, expr.end)
                return semaWriteBytes(&mut ctx, expr.start, expr.end, path_ty, path, bytes_ty, bytes)
            }
            let sym_id = semaLookupVisible(&mut ctx, source, name_start, name_end)
            if sym_id == -2 { return 7 }
            if sym_id < 0 {
                semaAddError(&mut ctx, "L0001", "función no encontrada", name_start, name_end)
                return 7
            }
            let sym = &ctx.symbols.symbols[sym_id]
            let sym_type_id = sym.type_id
            let decl_id = sym.decl_id
            match sym.kind {
                SymbolKind.Struct => {
                    semaCheckConstructor(&mut ctx, source, tree, expr, decl_id, sym_type_id)
                    return sym_type_id
                }
                SymbolKind.Func => {
                    if decl_id >= 0 && decl_id < tree.declarations.length {
                        let decl = &tree.declarations[decl_id]
                        let expected_params = decl.e
                        let first_p = decl.d
                        if arg_count != expected_params {
                            semaAddError(&mut ctx, "L0004", "número incorrecto de argumentos en llamada", expr.start, expr.end)
                            return 7
                        }
                        var loans: List<Int> = List[]
                        var args: List<Int> = List[]
                        for a in 0..arg_count {
                            let arg_eid = tree.extra[first_arg + a]
                            let param = &tree.params[first_p + a]
                            let param_t = semaResolveAstType(&mut ctx, source, tree, param.type_id)
                            if semaRefElem(ctx, param_t) >= 0 {
                                loans.push(semaRefArg(&mut ctx, source, tree, arg_eid, param_t, a))
                                let place = ctx.lir.borrowed
                                let is_mut = semaIsMutRef(ctx, param_t)
                                let argument = lirArg(&mut ctx.lir, true, place, is_mut)
                                args.push(argument)
                            } else {
                                loans.push(-1)
                                ctx.expected_list_type = param_t
                                let arg_t = semaExprMode(&mut ctx, source, tree, arg_eid, ACCESS_MOVE)
                                let operand = lirTakeOperand(&mut ctx, arg_t)
                                let argument = lirArg(&mut ctx.lir, false, operand, false)
                                args.push(argument)
                                if !semTypeEquals(&ctx.types, arg_t, param_t) {
                                    semaAddError(&mut ctx, "L0004", "tipo incompatible en argumento", expr.start, expr.end)
                                }
                            }
                        }
                        let result = semaCallLoans(&mut ctx, &loans, sym_type_id, site, expr.start, expr.end)
                        semaCallLower(&mut ctx, decl_id, &args, sym_type_id)
                        return result
                    }
                    return sym_type_id
                }
                _ => {
                    semaAddError(&mut ctx, "L0001", "el símbolo no es invocable", name_start, name_end)
                    return 7
                }
            }
        }
        AstExprKind.ListLit => {
            return semaCollectionLit(&mut ctx, source, tree, expr, false)
        }
        AstExprKind.ArrayLit => {
            return semaCollectionLit(&mut ctx, source, tree, expr, true)
        }
        AstExprKind.Field => {
            let enum_t = semaEnumField(&mut ctx, source, tree, expr)
            if enum_t >= 0 { return enum_t }
            let base_t = semaExprMode(&mut ctx, source, tree, expr.a, ACCESS_PLACE)
            let parent = ctx.expression_path
            ctx.expression_path = -1
            return semaFieldFinish(&mut ctx, source, tree, expr_id, mode, base_t, parent)
        }
        AstExprKind.Named => {
            ctx.borrow_site = site
            return semaExprMode(&mut ctx, source, tree, expr.c, mode)
        }
        AstExprKind.MethodCall => {
            let enum_call = semaEnumVariantCall(&mut ctx, source, tree, expr)
            if enum_call >= 0 { return enum_call }
            let base_t = semaExprMode(&mut ctx, source, tree, expr.a, ACCESS_PLACE)
            let base_place = ctx.lir.place
            let base_path = ctx.expression_path
            ctx.expression_path = -1
            let first_call = expr.d
            let count = tree.extra[first_call]
            var arg_op = LIR_NONE
            var arg_t = 0
            if count == 1 {
                arg_t = semaExprMode(&mut ctx, source, tree, tree.extra[first_call + 1], ACCESS_MOVE)
                arg_op = lirTakeOperand(&mut ctx, arg_t)
            }
            return semaMethodFinish(&mut ctx, source, tree, expr_id, base_t, base_place, base_path, count, arg_t, arg_op)
        }
        AstExprKind.Index => {
            let base_t = semaExprMode(&mut ctx, source, tree, expr.a, ACCESS_PLACE)
            let base_place = ctx.lir.place
            let base_path = ctx.expression_path
            ctx.expression_path = -1
            let idx_t = semaExprMode(&mut ctx, source, tree, expr.b, ACCESS_READ)
            let idx_op = lirTakeOperand(&mut ctx, idx_t)
            return semaIndexFinish(&mut ctx, source, tree, expr_id, mode, base_t, base_place, base_path, idx_t, idx_op)
        }
        AstExprKind.Match => {
            return 6
        }
        _ => {
            semaAddError(&mut ctx, "L0016", "expresión fuera del subconjunto verificado de Stage 1", expr.start, expr.end)
            return 7
        }
    }
}

fn semaCollectionLit(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr: &AstExpr, is_array: Bool) -> Int {
    let first = expr.a
    let count = expr.b
    var elem_t = 0
    if !is_array { elem_t = semaExpectedListElem(ctx) }
    ctx.expected_list_type = -1
    let elem_context = elem_t
    var elements: List<Int> = List[]
    for i in 0..count {
        // Each element gets the element type as its own (nested) context.
        ctx.expected_list_type = elem_context
        let ti = semaExprMode(&mut ctx, source, tree, tree.extra[first + i], ACCESS_MOVE)
        if elem_t == 0 { elem_t = ti }
        if !semTypeEquals(&ctx.types, elem_t, ti) {
            semaAddError(&mut ctx, "L0003", "elementos heterogéneos en colección", expr.start, expr.end)
        }
        elements.push(lirTakeOperand(&mut ctx, ti))
    }
    return semaFinishCollectionLit(&mut ctx, expr, is_array, elem_t, &elements)
}

// A qualified enum variant constructor is parsed as a MethodCall on an
// enum name. Never type-check the enum name as a runtime object.
// Return -1 when this is an ordinary method call.
fn semaEnumVariantCall(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr: &AstExpr) -> Int {
    if expr.a < 0 || expr.a >= tree.expressions.length { return -1 }
    let base = &tree.expressions[expr.a]
    match base.kind {
        AstExprKind.Name => {}
        _ => { return -1 }
    }
    let sym_id = semaLookupVisible(&mut ctx, source, base.start, base.end)
    if sym_id < 0 { return -1 }
    match ctx.symbols.symbols[sym_id].kind {
        SymbolKind.Enum => {}
        _ => { return -1 }
    }
    let decl_id = ctx.symbols.symbols[sym_id].decl_id
    let enum_ty = ctx.symbols.symbols[sym_id].type_id
    if decl_id < 0 || decl_id >= tree.declarations.length { return 7 }
    let decl = &tree.declarations[decl_id]
    let first = expr.d
    let argc = tree.extra[first]
    for v in 0..decl.d {
        let variant = &tree.variants[decl.c + v]
        if !symbolNamesEqual(source, variant.name_start, variant.name_end, expr.b, expr.c) { continue }
        if argc != variant.payload_count {
            semaAddError(&mut ctx, "L0004", "cantidad de argumentos incorrecta para la variante", expr.start, expr.end)
            return 7
        }
        if argc > 1 {
            semaAddError(&mut ctx, "L0016", "Stage 1 solo admite un payload primitivo por variante", expr.start, expr.end)
            return 7
        }
        var payload = LIR_NONE
        if argc == 1 {
            let expected = semaResolveAstType(&mut ctx, source, tree, tree.extra[variant.first_payload_index])
            let actual = semaExprMode(&mut ctx, source, tree, tree.extra[first + 1], ACCESS_MOVE)
            if expected != actual {
                semaAddError(&mut ctx, "L0004", "tipo incompatible de payload de enum", expr.start, expr.end)
                return 7
            }
            if expected != 1 && expected != 4 {
                semaAddError(&mut ctx, "L0016", "payload propietario fuera del subconjunto nativo verificado", expr.start, expr.end)
                return 7
            }
            payload = lirTakeOperand(&mut ctx, actual)
        }
        var enum_id = -1
        for k in 0..ctx.lir_module.en_decl.length {
            if ctx.lir_module.en_decl[k] == decl_id { enum_id = k }
        }
        if enum_id < 0 { lirMarkUnsupported(&mut ctx.lir, expr.start); return 7 }
        let value = lirNew(&mut ctx, enum_ty, false, LIR_VARIANT, enum_id, v, payload)
        lirSetVal(&mut ctx, value)
        return enum_ty
    }
    semaAddError(&mut ctx, "L0001", "variante de enum no encontrada", expr.start, expr.end)
    return 7
}
