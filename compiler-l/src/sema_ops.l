import tokens
import ast
import sema_types
import symbols
import scopes
import flow_cfg
import loans_l
import lir_build
import sema_context
import sema_drop
import sema_lower
import lir_builtin_union

// Non-recursive parts of expression checking and lowering, kept out of
// sema_expr.l (CORE-1 budget). Each function receives what the recursive
// walk already inferred and leaves the result in the LIR value channel.

pub fn semaLiteral(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, ty: Int) -> Int {
    let emitted = lirLiteral(&mut ctx, source, tree, expr_id)
    lirSetVal(&mut ctx, emitted)
    return ty
}

pub fn semaNameExpr(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, mode: Int, site: Int) -> Int {
    let expr = &tree.expressions[expr_id]
    let sym_id = semaLookupVisible(&mut ctx, source, expr.start, expr.end)
    if sym_id == -2 { return 7 }
    if sym_id < 0 {
        let name_none = "None"
        if symbolNameEqualsText(source, expr.start, expr.end, name_none) {
            var opt_t = semTypeMakeOption(&mut ctx.types, 0)
            let annotated = ctx.expected_union_type
            if annotated >= 0 && annotated < ctx.types.types.length {
                match ctx.types.types[annotated].kind {
                    SemTypeKind.Option => { opt_t = annotated }
                    _ => {}
                }
            }
            let enum_id = lirBuiltinRegister(&mut ctx.lir_module, &ctx.types, opt_t)
            if enum_id < 0 {
                lirMarkUnsupported(&mut ctx.lir, expr.start)
            } else {
                let emitted = lirNew(&mut ctx, opt_t, false, LIR_VARIANT, enum_id, 0, LIR_NONE)
                lirSetVal(&mut ctx, emitted)
            }
            return opt_t
        }
        semaAddError(&mut ctx, "L0001", "identificador no declarado", expr.start, expr.end)
        return 7
    }
    var constant = false
    match ctx.symbols.symbols[sym_id].kind {
        SymbolKind.Var => {}
        SymbolKind.Param => {}
        SymbolKind.Const => { constant = true }
        _ => {
            semaAddError(&mut ctx, "L0001", "el nombre no designa un valor", expr.start, expr.end)
            return 7
        }
    }
    let ty = ctx.symbols.symbols[sym_id].type_id
    let path = ctx.symbols.symbols[sym_id].move_path
    if constant {
        let decl = ctx.symbols.symbols[sym_id].decl_id
        let emitted = lirLiteral(&mut ctx, source, tree, tree.declarations[decl].d)
        lirSetVal(&mut ctx, emitted)
        return ty
    }
    let holder = lirPathVar(&ctx.lir, path)
    let elem = semaRefElem(ctx, ty)
    if elem >= 0 && mode != ACCESS_PLACE {
        // A reference binding is used: a borrowed return keeps the
        // reference, any other use reads the referent.
        ctx.expression_path = path
        flowEvent(&mut ctx.flow, FLOW_READ, path, expr.start, expr.end)
        if site == SITE_RETURN {
            ctx.pending_loan = loanOfPath(&ctx.flow, path)
            lirSetVal(&mut ctx, holder)
            return ty
        }
        let et = &ctx.types.types[elem]
        if mode == ACCESS_MOVE && semTypeIsMove(et.kind) {
            semaAddError(&mut ctx, "L0005", "no se puede mover un valor recibido por referencia", expr.start, expr.end)
        }
        let place = lirPlaceVar(&mut ctx.lir, holder)
        lirSetPlace(&mut ctx, place)
        return elem
    }
    semaAccess(&mut ctx, path, ty, mode, expr.start, expr.end)
    if holder >= 0 {
        let place = lirPlaceVar(&mut ctx.lir, holder)
        lirSetPlace(&mut ctx, place)
    }
    return ty
}

// `a && b` / `a || b`: the result variable holds `a`, the current block
// branches on it to the block evaluating `b` (swapped for `||`).
pub fn semaShortVar(ctx: &mut SemaContext, lhs: Int, is_or: Bool) -> Int {
    let result = lirNew(&mut ctx, 4, false, LIR_USE, lhs, 0, 0)
    let block_count = ctx.flow.blocks.length
    lirBlocks(&mut ctx.lir, block_count)
    ctx.lir.cond[ctx.flow.current] = result
    ctx.lir.swap[ctx.flow.current] = is_or
    return result
}

pub fn semaBinaryFinish(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, lhs_t: Int, rhs_t: Int, lhs: Int, rhs: Int) -> Int {
    let expr = &tree.expressions[expr_id]
    let op_len = expr.d - expr.c
    if op_len > 0 && expr.c >= 0 && expr.d <= source.byteLength {
        let b0 = source.byteAt(expr.c)
        if b0 == 61 || b0 == 33 || b0 == 60 || b0 == 62 {
            let lt = &ctx.types.types[lhs_t]
            let comparable = semTypeIsNumeric(lt.kind) || (lhs_t == 4 && (b0 == 61 || b0 == 33))
            if !comparable || !semTypeEquals(&ctx.types, lhs_t, rhs_t) {
                let l_name = semTypeName(&ctx.types, source, lhs_t)
                let r_name = semTypeName(&ctx.types, source, rhs_t)
                semaAddError(&mut ctx, "L0003", "comparación entre tipos incompatibles '{l_name}' y '{r_name}'", expr.start, expr.end)
                return 7
            }
            let op = lirBinaryOp(source, expr.c, expr.d)
            let emitted = lirNew(&mut ctx, 4, false, LIR_BINARY, op, lhs, rhs)
            lirSetVal(&mut ctx, emitted)
            return 4
        }
        if b0 == 38 || b0 == 124 {
            if !semTypeEquals(&ctx.types, lhs_t, 4) || !semTypeEquals(&ctx.types, rhs_t, 4) {
                semaAddError(&mut ctx, "L0003", "operador lógico requiere operandos de tipo Bool", expr.start, expr.end)
                return 7
            }
            lirSetVal(&mut ctx, rhs)
            return 4
        }
    }
    let lt = &ctx.types.types[lhs_t]
    if !semTypeIsNumeric(lt.kind) {
        let l_name = semTypeName(&ctx.types, source, lhs_t)
        semaAddError(&mut ctx, "L0003", "operación aritmética requiere tipo numérico, no '{l_name}'", expr.start, expr.end)
        return 7
    }
    if !semTypeEquals(&ctx.types, lhs_t, rhs_t) {
        let l_name = semTypeName(&ctx.types, source, lhs_t)
        let r_name = semTypeName(&ctx.types, source, rhs_t)
        semaAddError(&mut ctx, "L0003", "operación entre tipos numéricos distintos '{l_name}' y '{r_name}'", expr.start, expr.end)
        return 7
    }
    let op = lirBinaryOp(source, expr.c, expr.d)
    let emitted = lirNew(&mut ctx, lhs_t, false, LIR_BINARY, op, lhs, rhs)
    lirSetVal(&mut ctx, emitted)
    return lhs_t
}

pub fn semaUnaryFinish(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, sub_t: Int, operand: Int) -> Int {
    let expr = &tree.expressions[expr_id]
    if expr.b >= 0 && expr.b < source.byteLength {
        let b0 = source.byteAt(expr.b)
        if b0 == 33 {
            if !semTypeEquals(&ctx.types, sub_t, 4) {
                semaAddError(&mut ctx, "L0003", "operador '!' requiere operando de tipo Bool", expr.start, expr.end)
                return 7
            }
            let emitted = lirNew(&mut ctx, 4, false, LIR_UNARY, LIR_NOT, operand, 0)
            lirSetVal(&mut ctx, emitted)
            return 4
        }
        let ty = &ctx.types.types[sub_t]
        if b0 == 45 && semTypeIsNumeric(ty.kind) {
            let emitted = lirNew(&mut ctx, sub_t, false, LIR_UNARY, LIR_NEG, operand, 0)
            lirSetVal(&mut ctx, emitted)
            return sub_t
        }
    }
    semaAddError(&mut ctx, "L0003", "operador unario incompatible", expr.start, expr.end)
    return 7
}

// `base.field` once the base was inferred as a place (`parent` path) or a
// value (left in the LIR channel).
pub fn semaFieldFinish(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, mode: Int, base_type: Int, parent: Int) -> Int {
    let expr = &tree.expressions[expr_id]
    var base_t = base_type
    let referent = semaRefElem(ctx, base_t)
    if referent >= 0 { base_t = referent }
    if parent < 0 && semaNeedsDrop(&mut ctx, source, tree, base_t) {
        semaAddError(&mut ctx, "L0016", "proyección de un valor temporal propietario fuera del subconjunto de Stage 1", expr.start, expr.end)
        return 7
    }
    var base_place = ctx.lir.place
    if base_place < 0 {
        let holder = lirValueVar(&mut ctx, base_t)
        if holder >= 0 { base_place = lirPlaceVar(&mut ctx.lir, holder) }
    }
    let name_len = "length"
    let name_cap = "capacity"
    let name_byte_len = "byteLength"
    if base_t >= 0 && base_t < ctx.types.types.length {
        let bt = &ctx.types.types[base_t]
        match bt.kind {
            SemTypeKind.Struct => {
                let decl_id = bt.nominal_id
                if decl_id >= 0 && decl_id < tree.declarations.length {
                    let field = semaFindField(source, tree, decl_id, expr.b, expr.c)
                    if field >= 0 {
                        let ty = semaFieldType(&mut ctx, source, tree, field)
                        if parent >= 0 {
                            let path = flowField(&mut ctx.flow, parent, field)
                            semaAccess(&mut ctx, path, ty, mode, expr.start, expr.end)
                        }
                        if base_place >= 0 {
                            // Compute the field and its place before mutating the result channel.
                            let field_offset = field - tree.declarations[decl_id].c
                            let field_place = lirPlaceField(&mut ctx.lir, base_place, field_offset)
                            lirSetPlace(&mut ctx, field_place)
                        }
                        return ty
                    }
                }
            }
            SemTypeKind.List => {
                if symbolNameEqualsText(source, expr.b, expr.c, name_len) || symbolNameEqualsText(source, expr.b, expr.c, name_cap) {
                    if parent >= 0 { flowEvent(&mut ctx.flow, FLOW_READ, parent, expr.start, expr.end) }
                    if base_place >= 0 {
                        if symbolNameEqualsText(source, expr.b, expr.c, name_cap) {
                            let emitted = lirNew(&mut ctx, 1, false, LIR_CAP, base_place, 0, 0)
                            lirSetVal(&mut ctx, emitted)
                        } else {
                            let emitted = lirNew(&mut ctx, 1, false, LIR_LEN, base_place, 0, 0)
                            lirSetVal(&mut ctx, emitted)
                        }
                    }
                    return 1
                }
            }
            SemTypeKind.Array => {
                if symbolNameEqualsText(source, expr.b, expr.c, name_len) {
                    if parent >= 0 { flowEvent(&mut ctx.flow, FLOW_READ, parent, expr.start, expr.end) }
                    if base_place >= 0 {
                        let emitted = lirNew(&mut ctx, 1, false, LIR_LEN, base_place, 0, 0)
                        lirSetVal(&mut ctx, emitted)
                    }
                    return 1
                }
            }
            SemTypeKind.Slice => {
                if symbolNameEqualsText(source, expr.b, expr.c, name_len) {
                    if parent >= 0 { flowEvent(&mut ctx.flow, FLOW_READ, parent, expr.start, expr.end) }
                    if base_place >= 0 {
                        let emitted = lirNew(&mut ctx, 1, false, LIR_LEN, base_place, 0, 0)
                        lirSetVal(&mut ctx, emitted)
                    }
                    return 1
                }
            }
            SemTypeKind.Text => {
                if symbolNameEqualsText(source, expr.b, expr.c, name_byte_len) {
                    if parent >= 0 { flowEvent(&mut ctx.flow, FLOW_READ, parent, expr.start, expr.end) }
                    if base_place >= 0 {
                        let emitted = lirNew(&mut ctx, 1, false, LIR_LEN, base_place, 0, 0)
                        lirSetVal(&mut ctx, emitted)
                    }
                    return 1
                }
            }
            _ => {}
        }
    }
    semaAddError(&mut ctx, "L0001", "campo desconocido o proyección no verificada", expr.start, expr.end)
    return 7
}

// Capacity hint of an interpolation buffer: literal bytes plus 20 per
// interpolated value (Stage 0 uses a similar estimate).
pub fn semaInterpCapacity(tree: &AstTree, expr_id: Int) -> Int {
    let expr = &tree.expressions[expr_id]
    var capacity = 0
    for i in 0..expr.b {
        let part = &tree.expressions[tree.extra[expr.a + i]]
        match part.kind {
            AstExprKind.TextLit => { capacity += part.end - part.start }
            _ => { capacity += 20 }
        }
    }
    return capacity
}

// Append one part to an interpolation buffer; empty text segments vanish.
pub fn semaAppendPart(ctx: &mut SemaContext, tree: &AstTree, buffer: Int, part: Int, ty: Int) {
    let expr = &tree.expressions[part]
    match expr.kind {
        AstExprKind.TextLit => {
            if expr.end <= expr.start {
                lirTakeOperand(&mut ctx, ty)
                return
            }
        }
        _ => {}
    }
    // Consuming the argument must finish before the LIR append mutates ctx.
    let arg = lirTakeArg(&mut ctx, ty)
    lirAt(&mut ctx, LIR_APPEND, buffer, arg, 0, 0)
}

// Call instruction into a new variable of the result type (a reference
// variable for a borrowed result).
pub fn semaCallLower(ctx: &mut SemaContext, decl_id: Int, args: &List<Int>, ret_t: Int) {
    let first = lirSequence(&mut ctx, args)
    let elem = semaRefElem(ctx, ret_t)
    var ty = ret_t
    if elem >= 0 { ty = elem }
    // Snapshot callee index before creating a new instruction via &mut ctx.
    let callee = ctx.lir_func_index[decl_id]
    let emitted = lirNew(&mut ctx, ty, elem >= 0, LIR_CALL, callee, first, args.length)
    lirSetVal(&mut ctx, emitted)
}

// writeBytes borrows the two stable places for the duration of the platform
// operation. It must never move or duplicate the List<Int> heap owner.
// The LIR verifier independently requires two immutable ref arguments.
pub fn semaWriteBytes(ctx: &mut SemaContext, start: Int, end: Int, path_ty: Int, path: Int, bytes_ty: Int, bytes: Int) -> Int {
    var valid_list = false
    if bytes_ty >= 0 && bytes_ty < ctx.types.types.length {
        let elem = &ctx.types.types[bytes_ty]
        match elem.kind {
            SemTypeKind.List => { valid_list = elem.elem_type == 1 }
            _ => {}
        }
    }
    if path_ty != 5 || !valid_list {
        semaAddError(&mut ctx, "L0004", "writeBytes requiere (Text, List<Int>)", start, end)
        return 7
    }
    if path < 0 || bytes < 0 {
        // A temporary owner needs explicit lifetime/drop elaboration. Do not
        // emit an unchecked by-value platform argument as an ersatz loan.
        semaAddError(&mut ctx, "L0016", "writeBytes requiere lugares prestables para Text y List<Int>", start, end)
        return 7
    }
    var args: List<Int> = List[]
    let path_arg = lirArg(&mut ctx.lir, true, path, false)
    args.push(path_arg)
    let bytes_arg = lirArg(&mut ctx.lir, true, bytes, false)
    args.push(bytes_arg)
    semaPlatformEmit(&mut ctx, LIR_PLATFORM_WRITE_BYTES, &args, 1, true)
    return 1
}

pub fn semaPlatformEmit(ctx: &mut SemaContext, op: Int, args: &List<Int>, res_t: Int, ret_val: Bool) {
    let first = lirSequence(&mut ctx, args)
    let res_var = lirVar(&mut ctx.lir, res_t, false)
    lirAt(&mut ctx, LIR_PLATFORM, res_var, op, first, args.length)
    if ret_val {
        lirSetVal(&mut ctx, res_var)
    } else {
        let emitted = lirConst(&mut ctx.lir, LIR_CONST_UNIT, 0, 0, 0)
        lirSetVal(&mut ctx, emitted)
    }
}
