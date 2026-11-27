take tokens
take ast
take sema_types
take symbols
take scopes
take flow_cfg
take loans_l
take lir_build
take sema_context
take sema_drop
take sema_borrow
take sema_lower
take lir_builtin_union
take sema_const

// Non-recursive parts of expression checking and lowering, kept out of
// sema_expr.l (CORE-1 budget). Each function receives what the recursive
// walk already inferred and leaves the result in the LIR value channel.

expose flow semaLiteral(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, ty: Int) => Int {
    hold emitted = lirLiteral(edit ctx, source, tree, expr_id)
    lirSetVal(edit ctx, emitted)
    give ty
}

expose flow semaNameExpr(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, mode: Int, site: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    hold sym_id = semaLookupVisible(edit ctx, source, expr.start, expr.end)
    when sym_id == -2 { give 7 }
    when sym_id < 0 {
        hold name_none = "None"
        when symbolNameEqualsText(source, expr.start, expr.end, name_none) {
            change opt_t = semTypeMakeOption(edit ctx.types, 0)
            hold annotated = ctx.expected_union_type
            when annotated >= 0 && annotated < ctx.types.types.length {
                choose ctx.types.types[annotated].kind {
                    SemTypeKind.Option : { opt_t = annotated }
                    _ : {}
                }
            }
            hold enum_id = lirBuiltinRegister(edit ctx.lir_module, view ctx.types, opt_t)
            when enum_id < 0 {
                lirMarkUnsupported(edit ctx.lir, expr.start)
            } otherwise {
                hold emitted = lirNew(edit ctx, opt_t, false, LIR_VARIANT, enum_id, 0, LIR_NONE)
                lirSetVal(edit ctx, emitted)
            }
            give opt_t
        }
        semaAddError(edit ctx, "L0001", "identificador no declarado", expr.start, expr.end)
        give 7
    }
    change constant = false
    choose ctx.symbols.symbols[sym_id].kind {
        SymbolKind.Var : {}
        SymbolKind.Param : {}
        SymbolKind.Const : { constant = true }
        _ : {
            semaAddError(edit ctx, "L0001", "el nombre no designa un valor", expr.start, expr.end)
            give 7
        }
    }
    hold ty = ctx.symbols.symbols[sym_id].type_id
    hold path = ctx.symbols.symbols[sym_id].move_path
    when constant {
        hold emitted = semaConstOperand(edit ctx, sym_id)
        lirSetVal(edit ctx, emitted)
        give ty
    }
    hold holder = lirPathVar(view ctx.lir, path)
    hold elem = semaRefElem(ctx, ty)
    when elem >= 0 && mode != ACCESS_PLACE {
        // A reference binding is used: a borrowed return keeps the
        // reference, any other use reads the referent.
        ctx.expression_path = path
        flowEvent(edit ctx.flow, FLOW_READ, path, expr.start, expr.end)
        when site == SITE_RETURN {
            ctx.pending_loan = loanOfPath(view ctx.flow, path)
            lirSetVal(edit ctx, holder)
            give ty
        }
        hold et = view ctx.types.types[elem]
        when mode == ACCESS_MOVE && semTypeIsMove(et.kind) {
            semaAddError(edit ctx, "L0005", "no se puede mover un valor recibido por referencia", expr.start, expr.end)
        }
        hold place = lirPlaceVar(edit ctx.lir, holder)
        lirSetPlace(edit ctx, place)
        give elem
    }
    semaAccess(edit ctx, path, ty, mode, expr.start, expr.end)
    when holder >= 0 {
        hold place = lirPlaceVar(edit ctx.lir, holder)
        lirSetPlace(edit ctx, place)
    }
    give ty
}

// `a && b` / `a || b`: the result variable holds `a`, the current block
// branches on it to the block evaluating `b` (swapped for `||`).
expose flow semaShortVar(ctx: edit SemaContext, lhs: Int, is_or: Bool) => Int {
    hold result = lirNew(edit ctx, 4, false, LIR_USE, lhs, 0, 0)
    hold block_count = ctx.flow.blocks.length
    lirBlocks(edit ctx.lir, block_count)
    ctx.lir.cond[ctx.flow.current] = result
    ctx.lir.swap[ctx.flow.current] = is_or
    give result
}

expose flow semaBinaryFinish(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, lhs_t: Int, rhs_t: Int, lhs: Int, rhs: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    hold op_len = expr.d - expr.c
    when op_len > 0 && expr.c >= 0 && expr.d <= source.byteLength {
        hold b0 = source@byteAt(expr.c)
        when lirIsComparisonOp(source, expr.c, expr.d) {
            hold lt = view ctx.types.types[lhs_t]
            hold comparable = semTypeIsNumeric(lt.kind) || (lhs_t == 4 && (b0 == 61 || b0 == 33))
            when !comparable || !semTypeEquals(view ctx.types, lhs_t, rhs_t) {
                hold l_name = semTypeName(view ctx.types, source, lhs_t)
                hold r_name = semTypeName(view ctx.types, source, rhs_t)
                semaAddError(edit ctx, "L0003", "comparación entre tipos incompatibles '{l_name}' y '{r_name}'", expr.start, expr.end)
                give 7
            }
            hold op = lirBinaryOp(source, expr.c, expr.d)
            hold emitted = lirNew(edit ctx, 4, false, LIR_BINARY, op, lhs, rhs)
            lirSetVal(edit ctx, emitted)
            give 4
        }
        when lirIsLogicalOp(source, expr.c, expr.d) {
            when !semTypeEquals(view ctx.types, lhs_t, 4) || !semTypeEquals(view ctx.types, rhs_t, 4) {
                semaAddError(edit ctx, "L0003", "operador lógico requiere operandos de tipo Bool", expr.start, expr.end)
                give 7
            }
            lirSetVal(edit ctx, rhs)
            give 4
        }
    }
    when lirBinaryOp(source, expr.c, expr.d) >= LIR_BAND && !semTypeEquals(view ctx.types, lhs_t, 1) {
        semaAddError(edit ctx, "L0003", "operador de bits o envolvente requiere operandos de tipo Int", expr.start, expr.end)
        give 7
    }
    hold lt = view ctx.types.types[lhs_t]
    when !semTypeIsNumeric(lt.kind) {
        hold l_name = semTypeName(view ctx.types, source, lhs_t)
        semaAddError(edit ctx, "L0003", "operación aritmética requiere tipo numérico, no '{l_name}'", expr.start, expr.end)
        give 7
    }
    when !semTypeEquals(view ctx.types, lhs_t, rhs_t) {
        hold l_name = semTypeName(view ctx.types, source, lhs_t)
        hold r_name = semTypeName(view ctx.types, source, rhs_t)
        semaAddError(edit ctx, "L0003", "operación entre tipos numéricos distintos '{l_name}' y '{r_name}'", expr.start, expr.end)
        give 7
    }
    hold op = lirBinaryOp(source, expr.c, expr.d)
    when lhs_t == 2 && op == LIR_REM {
        semaAddError(edit ctx, "L0016", "el operador '%' sobre Float no está soportado por el driver ELE", expr.start, expr.end)
        give 7
    }
    hold emitted = lirNew(edit ctx, lhs_t, false, LIR_BINARY, op, lhs, rhs)
    lirSetVal(edit ctx, emitted)
    give lhs_t
}

expose flow semaUnaryFinish(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, sub_t: Int, operand: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    when expr.b >= 0 && expr.b < source.byteLength {
        hold b0 = source@byteAt(expr.b)
        when b0 == 33 {
            when !semTypeEquals(view ctx.types, sub_t, 4) {
                semaAddError(edit ctx, "L0003", "operador '!' requiere operando de tipo Bool", expr.start, expr.end)
                give 7
            }
            hold emitted = lirNew(edit ctx, 4, false, LIR_UNARY, LIR_NOT, operand, 0)
            lirSetVal(edit ctx, emitted)
            give 4
        }
        when b0 == 126 {
            when !semTypeEquals(view ctx.types, sub_t, 1) {
                semaAddError(edit ctx, "L0003", "operador '~' requiere operando de tipo Int", expr.start, expr.end)
                give 7
            }
            hold emitted = lirNew(edit ctx, 1, false, LIR_UNARY, LIR_BNOT, operand, 0)
            lirSetVal(edit ctx, emitted)
            give 1
        }
        hold ty = view ctx.types.types[sub_t]
        when b0 == 45 && semTypeIsNumeric(ty.kind) {
            hold emitted = lirNew(edit ctx, sub_t, false, LIR_UNARY, LIR_NEG, operand, 0)
            lirSetVal(edit ctx, emitted)
            give sub_t
        }
    }
    semaAddError(edit ctx, "L0003", "operador unario incompatible", expr.start, expr.end)
    give 7
}

// `base.field` once the base was inferred as a place (`parent` path) or a
// value (left in the LIR channel).
expose flow semaFieldFinish(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, mode: Int, base_type: Int, parent: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    change base_t = base_type
    hold referent = semaRefElem(ctx, base_t)
    when referent >= 0 { base_t = referent }
    when parent < 0 && semaNeedsDrop(edit ctx, source, tree, base_t) {
        semaAddError(edit ctx, "L0016", "proyección de un valor temporal propietario fuera del subconjunto de Stage 1", expr.start, expr.end)
        give 7
    }
    change base_place = ctx.lir.place
    when base_place < 0 {
        hold holder = lirValueVar(edit ctx, base_t)
        when holder >= 0 { base_place = lirPlaceVar(edit ctx.lir, holder) }
    }
    hold name_len = "length"
    hold name_cap = "capacity"
    hold name_byte_len = "byteLength"
    when base_t >= 0 && base_t < ctx.types.types.length {
        hold bt = view ctx.types.types[base_t]
        choose bt.kind {
            SemTypeKind.Struct : {
                hold decl_id = bt.nominal_id
                when decl_id >= 0 && decl_id < tree.declarations.length {
                    hold field = semaFindField(source, tree, decl_id, expr.b, expr.c)
                    when field >= 0 {
                        hold ty = semaFieldType(edit ctx, source, tree, field)
                        when parent >= 0 {
                            hold path = flowField(edit ctx.flow, parent, field)
                            semaAccess(edit ctx, path, ty, mode, expr.start, expr.end)
                        }
                        when base_place >= 0 {
                            // Compute the field and its place before mutating the result channel.
                            hold field_offset = field - tree.declarations[decl_id].c
                            hold field_place = lirPlaceField(edit ctx.lir, base_place, field_offset)
                            lirSetPlace(edit ctx, field_place)
                        }
                        give ty
                    }
                }
            }
            SemTypeKind.List : {
                when symbolNameEqualsText(source, expr.b, expr.c, name_len) || symbolNameEqualsText(source, expr.b, expr.c, name_cap) {
                    when parent >= 0 { flowEvent(edit ctx.flow, FLOW_READ, parent, expr.start, expr.end) }
                    when base_place >= 0 {
                        when symbolNameEqualsText(source, expr.b, expr.c, name_cap) {
                            hold emitted = lirNew(edit ctx, 1, false, LIR_CAP, base_place, 0, 0)
                            lirSetVal(edit ctx, emitted)
                        } otherwise {
                            hold emitted = lirNew(edit ctx, 1, false, LIR_LEN, base_place, 0, 0)
                            lirSetVal(edit ctx, emitted)
                        }
                    }
                    give 1
                }
            }
            SemTypeKind.Array : {
                when symbolNameEqualsText(source, expr.b, expr.c, name_len) {
                    when parent >= 0 { flowEvent(edit ctx.flow, FLOW_READ, parent, expr.start, expr.end) }
                    when base_place >= 0 {
                        hold emitted = lirNew(edit ctx, 1, false, LIR_LEN, base_place, 0, 0)
                        lirSetVal(edit ctx, emitted)
                    }
                    give 1
                }
            }
            SemTypeKind.Slice : {
                when symbolNameEqualsText(source, expr.b, expr.c, name_len) {
                    when parent >= 0 { flowEvent(edit ctx.flow, FLOW_READ, parent, expr.start, expr.end) }
                    when base_place >= 0 {
                        hold emitted = lirNew(edit ctx, 1, false, LIR_LEN, base_place, 0, 0)
                        lirSetVal(edit ctx, emitted)
                    }
                    give 1
                }
            }
            SemTypeKind.Text : {
                when symbolNameEqualsText(source, expr.b, expr.c, name_byte_len) {
                    when parent >= 0 { flowEvent(edit ctx.flow, FLOW_READ, parent, expr.start, expr.end) }
                    when base_place >= 0 {
                        hold emitted = lirNew(edit ctx, 1, false, LIR_LEN, base_place, 0, 0)
                        lirSetVal(edit ctx, emitted)
                    }
                    give 1
                }
            }
            _ : {}
        }
    }
    semaAddError(edit ctx, "L0001", "campo desconocido o proyección no verificada", expr.start, expr.end)
    give 7
}

// Capacity hint of an interpolation buffer: literal bytes plus 20 per
// interpolated value (Stage 0 uses a similar estimate).
expose flow semaInterpCapacity(tree: view AstTree, expr_id: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    change capacity = 0
    each i among 0..expr.b {
        hold part = view tree.expressions[tree.extra[expr.a + i]]
        choose part.kind {
            AstExprKind.TextLit : { capacity += part.end - part.start }
            _ : { capacity += 20 }
        }
    }
    give capacity
}

// Append one part to an interpolation buffer; empty text segments vanish.
expose flow semaAppendPart(ctx: edit SemaContext, tree: view AstTree, buffer: Int, part: Int, ty: Int) {
    hold expr = view tree.expressions[part]
    choose expr.kind {
        AstExprKind.TextLit : {
            when expr.end <= expr.start {
                lirTakeOperand(edit ctx, ty)
                give
            }
        }
        _ : {}
    }
    // Consuming the argument must finish before the LIR append mutates ctx.
    hold arg = lirTakeArg(edit ctx, ty)
    lirAt(edit ctx, LIR_APPEND, buffer, arg, 0, 0)
}

// Call instruction into a new variable of the result type (a reference
// variable for a borrowed result).
expose flow semaCallLower(ctx: edit SemaContext, decl_id: Int, args: view List of[Int], ret_t: Int) {
    hold first = lirSequence(edit ctx, args)
    hold elem = semaRefElem(ctx, ret_t)
    change ty = ret_t
    when elem >= 0 { ty = elem }
    // Snapshot callee index before creating a new instruction via &mut ctx.
    hold callee = ctx.lir_func_index[decl_id]
    hold emitted = lirNew(edit ctx, ty, elem >= 0, LIR_CALL, callee, first, args.length)
    lirSetVal(edit ctx, emitted)
}

// Borrow a stable platform argument like an ordinary &T call parameter.
// The loan remains live through argument evaluation and is used at call close.
expose flow semaPlatformArgLoan(ctx: edit SemaContext, ty: Int, start: Int, end: Int) => Int {
    hold place = ctx.lir.place
    hold path = ctx.expression_path
    ctx.lir.borrowed = -1
    when place < 0 || path < 0 { give -1 }
    semaBorrowPlace(edit ctx, path, ty, false, SITE_ARG, start, end)
    give ctx.pending_loan
}

// The exclusive form, for fileRead's destination list: the runtime stores
// into its elements, so no other access may overlap the call.
expose flow semaPlatformArgLoanEdit(ctx: edit SemaContext, ty: Int, start: Int, end: Int) => Int {
    hold place = ctx.lir.place
    hold path = ctx.expression_path
    ctx.lir.borrowed = -1
    when place < 0 || path < 0 { give -1 }
    semaBorrowPlace(edit ctx, path, ty, true, SITE_ARG, start, end)
    give ctx.pending_loan
}

// writeBytes borrows the two stable places for the duration of the platform
// operation. It must never move or duplicate the List<Int> heap owner.
// The LIR verifier independently requires two immutable ref arguments.
expose flow semaWriteBytes(ctx: edit SemaContext, start: Int, end: Int, path_ty: Int, path: Int, bytes_ty: Int, bytes: Int) => Int {
    change valid_list = false
    when bytes_ty >= 0 && bytes_ty < ctx.types.types.length {
        hold elem = view ctx.types.types[bytes_ty]
        choose elem.kind {
            SemTypeKind.List : { valid_list = elem.elem_type == 1 }
            _ : {}
        }
    }
    when path_ty != 5 || !valid_list {
        semaAddError(edit ctx, "L0004", "writeBytes requiere (Text, List<Int>)", start, end)
        give 7
    }
    when path < 0 || bytes < 0 {
        // A temporary owner needs explicit lifetime/drop elaboration. Do not
        // emit an unchecked by-value platform argument as an ersatz loan.
        semaAddError(edit ctx, "L0016", "writeBytes requiere lugares prestables para Text y List<Int>", start, end)
        give 7
    }
    change args: List of[Int] = List[]
    hold path_arg = lirArg(edit ctx.lir, true, path, false)
    args@push(path_arg)
    hold bytes_arg = lirArg(edit ctx.lir, true, bytes, false)
    args@push(bytes_arg)
    semaPlatformEmit(edit ctx, LIR_PLATFORM_WRITE_BYTES, view args, 1, true)
    give 1
}

expose flow semaWriteConsoleBytes(ctx: edit SemaContext, start: Int, end: Int, bytes_ty: Int, bytes: Int) => Int {
    change valid_list = false
    when bytes_ty >= 0 && bytes_ty < ctx.types.types.length {
        hold elem = view ctx.types.types[bytes_ty]
        choose elem.kind {
            SemTypeKind.List : { valid_list = elem.elem_type == 1 }
            _ : {}
        }
    }
    when !valid_list {
        semaAddError(edit ctx, "L0004", "writeConsoleBytes requiere (List<Int>)", start, end)
        give 7
    }
    when bytes < 0 {
        semaAddError(edit ctx, "L0016", "writeConsoleBytes requiere un lugar prestable", start, end)
        give 7
    }
    change args: List of[Int] = List[]
    args@push(lirArg(edit ctx.lir, true, bytes, false))
    semaPlatformEmit(edit ctx, LIR_PLATFORM_WRITE_CONSOLE, view args, 1, true)
    give 1
}

expose flow semaSameFile(ctx: edit SemaContext, start: Int, end: Int, path_a_ty: Int, path_a: Int, path_b_ty: Int, path_b: Int) => Int {
    when path_a_ty != 5 || path_b_ty != 5 {
        semaAddError(edit ctx, "L0004", "sameFile requiere (Text, Text)", start, end)
        give 7
    }
    when path_a < 0 || path_b < 0 {
        semaAddError(edit ctx, "L0016", "sameFile requiere lugares prestables para Text", start, end)
        give 7
    }
    change args: List of[Int] = List[]
    hold a_arg = lirArg(edit ctx.lir, true, path_a, false)
    args@push(a_arg)
    hold b_arg = lirArg(edit ctx.lir, true, path_b, false)
    args@push(b_arg)
    // 0 = different, 1 = same, 2 = identity could not be established.
    semaPlatformEmit(edit ctx, 5, view args, 1, true)
    give 1
}

expose flow semaPlatformEmit(ctx: edit SemaContext, op: Int, args: view List of[Int], res_t: Int, ret_val: Bool) {
    hold first = lirSequence(edit ctx, args)
    hold res_var = lirVar(edit ctx.lir, res_t, false)
    lirAt(edit ctx, LIR_PLATFORM, res_var, op, first, args.length)
    when ret_val {
        lirSetVal(edit ctx, res_var)
    } otherwise {
        hold emitted = lirConst(edit ctx.lir, LIR_CONST_UNIT, 0, 0, 0)
        lirSetVal(edit ctx, emitted)
    }
}

// Kernel intrinsic named by the callee span, or -1. `cpu` / `mem` say which
// of nucleo.cpu / nucleo.mem the current module took; a name of a module
// not taken is an ordinary (user) flow name.
expose flow semaIntrinsicCode(source: view Text, start: Int, end: Int, cpu: Bool, mem: Bool) => Int {
    change first = 31
    change last = 109
    each op among first..(last + 1) {
        hold in_mem = (op >= 41 && op <= 51) || op == 85 || op == 86
        when (in_mem && mem) || (!in_mem && cpu) {
            hold name = semaIntrinsicName(op)
            when symbolNameEqualsText(source, start, end, name) { give op }
        }
    }
    give -1
}

// Source name of an intrinsic code.
expose flow semaIntrinsicName(op: Int) => Text {
    when op == 41 { give "leer8" }
    when op == 42 { give "leer16" }
    when op == 43 { give "leer32" }
    when op == 44 { give "leer64" }
    when op == 45 { give "escribir8" }
    when op == 46 { give "escribir16" }
    when op == 47 { give "escribir32" }
    when op == 48 { give "escribir64" }
    when op == 56 { give "leerCr0" }
    when op == 57 { give "leerCr2" }
    when op == 58 { give "leerCr3" }
    when op == 59 { give "leerCr4" }
    when op == 60 { give "escribirCr0" }
    when op == 61 { give "escribirCr3" }
    when op == 62 { give "escribirCr4" }
    when op == 66 { give "recargarSegmentos" }
    when op == 71 { give "stubInterrupcion" }
    when op == 72 { give "leerRflags" }
    when op == 74 { give "xmmCero" }
    when op == 75 { give "xmmCargar" }
    when op == 76 { give "xmmGuardar" }
    when op == 77 { give "xmmDifundir" }
    when op == 78 { give "xmmCopiar" }
    when op == 79 { give "xmmMultiplicar" }
    when op == 80 { give "xmmSumar" }
    when op == 81 { give "xmmMulSumar4" }
    when op == 82 { give "xmmDifundirEn" }
    when op == 83 { give "leerRsp" }
    when op == 84 { give "xmmMulSumar4M" }
    when op == 85 { give "leerF32" }
    when op == 86 { give "escribirF32" }
    when op == 87 { give "bitsDeFloat" }
    when op == 88 { give "floatDeBits" }
    when op == 89 { give "raizF" }
    when op == 90 { give "xmmRestar" }
    when op == 91 { give "xmmDividir" }
    when op == 92 { give "xmmMaximo" }
    when op == 93 { give "xmmMinimo" }
    when op == 94 { give "xmmRaiz" }
    when op == 95 { give "xmmY" }
    when op == 96 { give "xmmYNo" }
    when op == 97 { give "xmmO" }
    when op == 98 { give "xmmOExclusivo" }
    when op == 99 { give "xmmAEnteros" }
    when op == 100 { give "xmmAFlotantes" }
    when op == 101 { give "xmmSumarEnteros" }
    when op == 102 { give "xmmRestarEnteros" }
    when op == 103 { give "xmmDesplazarIzq" }
    when op == 104 { give "xmmComparar" }
    when op == 105 { give "xmmBarajar" }
    when op == 106 { give "xmmCargarEscalar" }
    when op == 107 { give "xmmGuardarEscalar" }
    when op == 108 { give "xmmTruncarAEnteros" }
    when op == 109 { give "xmmDesplazarDer" }
    give lirIntrinsicName(op)
}

// Little-endian word of bytes[at..at+8) (missing bytes are 0), as the
// signed Int with the same 64-bit pattern.
expose flow semaPackWord(bytes: view List of[Int], at: Int) => Int {
    change value = 0
    change scale = 1
    each i among 0..7 {
        when at + i < bytes.length { value += bytes[at + i] * scale }
        scale = scale * 256
    }
    when at + 7 < bytes.length {
        hold top = bytes[at + 7]
        when top >= 128 {
            value += (top - 256) * scale
        } otherwise {
            value += top * scale
        }
    }
    give value
}

expose flow semaModuleIn(modules: view List of[Int], owner: Int) => Bool {
    each i among 0..modules.length {
        when modules[i] == owner { give true }
    }
    give false
}
