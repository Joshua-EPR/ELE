take float_parse
take ast
take sema_types
take symbols
take scopes
take lir_build
take sema_context
take sema_lower
take sema_borrow_syntax

// Compile-time constants (`fixed`), with Stage 0's rules (crates/l/src/
// consteval.rs and global_constants in sema.rs):
// - names, types and operators are checked first;
// - then the first non-constant operand (runtime variable, call, struct
//   constructor) is rejected (L0004; a struct constructor is L0001, as in
//   Stage 0, whose checker reports it before consteval);
// - then the value is folded: Int arithmetic is checked, overflow and
//   division or remainder by zero are L0004, `&&`/`||` short-circuit;
// - a global constant may reference any constant of its module, declared
//   before or after it; a dependency cycle is L0001, reported at the first
//   declaration whose evaluation reaches it.
// Folded values are LIR constants, substituted wherever the name is used.

// Reasons for a non-constant operand (SemaContext.const_reason).
fixed CONST_RUNTIME = 1
fixed CONST_STRUCT = 2
fixed CONST_UNSUPPORTED = 3

flow semaConstValue(state: Int, ty: Int, kind: Int, value: Int, start: Int, end: Int) => SemaConst {
    give SemaConst(state: state, decl: -1, sym: -1, ty: ty, kind: kind, value: value, start: start, end: end)
}

flow semaConstFailed() => SemaConst {
    give semaConstValue(SEMA_CONST_FAILED, 7, LIR_CONST_UNIT, 0, 0, 0)
}

flow semaConstInt(value: Int) => SemaConst {
    give semaConstValue(SEMA_CONST_READY, 1, LIR_CONST_INT, value, 0, 0)
}

flow semaConstBool(value: Bool) => SemaConst {
    change bit = 0
    when value { bit = 1 }
    give semaConstValue(SEMA_CONST_READY, 4, LIR_CONST_BOOL, bit, 0, 0)
}

// Records the first non-constant operand of the expression being checked.
flow semaConstLeaf(ctx: edit SemaContext, expr_id: Int, reason: Int) {
    when ctx.const_leaf < 0 {
        ctx.const_leaf = expr_id
        ctx.const_reason = reason
    }
}

flow semaConstPanic(ctx: edit SemaContext, start: Int, end: Int) => SemaConst {
    semaAddError(edit ctx, "L0004", "panic en const: overflow entero o división/resto por cero", start, end)
    give semaConstFailed()
}

// Type of a constant expression, or 7. Reports name and type errors;
// non-constant operands are only recorded (semaConstLeaf).
flow semaConstType(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int) => Int {
    when expr_id < 0 || expr_id >= tree.expressions.length { give 7 }
    hold expr = view tree.expressions[expr_id]
    choose expr.kind {
        AstExprKind.IntLit : { give 1 }
        AstExprKind.FloatLit : { give 2 }
        AstExprKind.BoolLit : { give 4 }
        AstExprKind.TextLit : { give 5 }
        AstExprKind.UnitLit : { give 6 }
        AstExprKind.Name : { give semaConstNameType(edit ctx, source, tree, expr_id) }
        AstExprKind.Call : { give semaConstCallType(edit ctx, source, tree, expr_id) }
        AstExprKind.MethodCall : {
            semaConstLeaf(edit ctx, expr_id, CONST_RUNTIME)
            give 7
        }
        AstExprKind.GenericCall : {
            semaConstLeaf(edit ctx, expr_id, CONST_RUNTIME)
            give 7
        }
        AstExprKind.Interpolate : {
            // Folding interpolated Text is outside this subset, but its type
            // is known: uses of the constant do not cascade errors.
            semaConstLeaf(edit ctx, expr_id, CONST_UNSUPPORTED)
            give 5
        }
        AstExprKind.GenericMethodCall : {
            semaConstLeaf(edit ctx, expr_id, CONST_RUNTIME)
            give 7
        }
        AstExprKind.Unary : {
            when expr.b < 0 || expr.b >= source.byteLength { give 7 }
            when semaBorrowSyntaxKind(source, expr.b, expr.c) > 0 {
                semaConstLeaf(edit ctx, expr_id, CONST_RUNTIME)
                give 7
            }
            hold op = source@byteAt(expr.b)
            when op != 45 && op != 33 {
                semaConstLeaf(edit ctx, expr_id, CONST_UNSUPPORTED)
                give 7
            }
            hold sub = semaConstType(edit ctx, source, tree, expr.a)
            when sub < 0 || sub == 7 || sub >= ctx.types.types.length { give 7 }
            when op == 33 {
                when !semTypeEquals(view ctx.types, sub, 4) {
                    semaAddError(edit ctx, "L0003", "operador '!' requiere operando de tipo Bool", expr.start, expr.end)
                    give 7
                }
                give 4
            }
            hold st = view ctx.types.types[sub]
            when !semTypeIsNumeric(st.kind) {
                semaAddError(edit ctx, "L0003", "operador unario incompatible", expr.start, expr.end)
                give 7
            }
            give sub
        }
        AstExprKind.Binary : {
            when expr.c < 0 || expr.c >= source.byteLength { give 7 }
            when source@byteAt(expr.c) == 63 {
                semaConstLeaf(edit ctx, expr_id, CONST_UNSUPPORTED)
                give 7
            }
            hold lt = semaConstType(edit ctx, source, tree, expr.a)
            hold rt = semaConstType(edit ctx, source, tree, expr.b)
            when lt < 0 || rt < 0 || lt == 7 || rt == 7 { give 7 }
            when lt >= ctx.types.types.length || rt >= ctx.types.types.length { give 7 }
            give semaConstBinaryType(edit ctx, source, tree, expr_id, lt, rt)
        }
        _ : {
            semaConstLeaf(edit ctx, expr_id, CONST_UNSUPPORTED)
            give 7
        }
    }
}

// Operand typing rules of semaBinaryFinish, plus Unit equality (Stage 0).
flow semaConstBinaryType(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, lt: Int, rt: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    hold b0 = source@byteAt(expr.c)
    hold lk = view ctx.types.types[lt]
    hold numeric = semTypeIsNumeric(lk.kind)
    when b0 == 61 || b0 == 33 || b0 == 60 || b0 == 62 {
        hold equality = b0 == 61 || b0 == 33
        hold comparable = numeric || (equality && (lt == 4 || lt == 6))
        when !comparable || !semTypeEquals(view ctx.types, lt, rt) {
            hold l_name = semTypeName(view ctx.types, source, lt)
            hold r_name = semTypeName(view ctx.types, source, rt)
            semaAddError(edit ctx, "L0003", "comparación entre tipos incompatibles '{l_name}' y '{r_name}'", expr.start, expr.end)
            give 7
        }
        when lt == 2 {
            semaConstLeaf(edit ctx, expr_id, CONST_UNSUPPORTED)
            give 7
        }
        give 4
    }
    when b0 == 38 || b0 == 124 {
        when !semTypeEquals(view ctx.types, lt, 4) || !semTypeEquals(view ctx.types, rt, 4) {
            semaAddError(edit ctx, "L0003", "operador lógico requiere operandos de tipo Bool", expr.start, expr.end)
            give 7
        }
        give 4
    }
    when !numeric {
        hold l_name = semTypeName(view ctx.types, source, lt)
        semaAddError(edit ctx, "L0003", "operación aritmética requiere tipo numérico, no '{l_name}'", expr.start, expr.end)
        give 7
    }
    when !semTypeEquals(view ctx.types, lt, rt) {
        hold l_name = semTypeName(view ctx.types, source, lt)
        hold r_name = semTypeName(view ctx.types, source, rt)
        semaAddError(edit ctx, "L0003", "operación entre tipos numéricos distintos '{l_name}' y '{r_name}'", expr.start, expr.end)
        give 7
    }
    // The compiler folds constants with integer arithmetic only: Float
    // arithmetic is evaluated at run time, not in a `const`.
    when lt == 2 {
        semaConstLeaf(edit ctx, expr_id, CONST_UNSUPPORTED)
        give 7
    }
    give lt
}

flow semaConstNameType(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    hold sym = semaLookupVisible(edit ctx, source, expr.start, expr.end)
    when sym == -2 { give 7 }
    when sym < 0 {
        hold name_none = "None"
        when symbolNameEqualsText(source, expr.start, expr.end, name_none) {
            semaConstLeaf(edit ctx, expr_id, CONST_UNSUPPORTED)
            give 7
        }
        semaAddError(edit ctx, "L0001", "identificador no declarado", expr.start, expr.end)
        give 7
    }
    hold sym_type = ctx.symbols.symbols[sym].type_id
    choose ctx.symbols.symbols[sym].kind {
        SymbolKind.Const : {}
        SymbolKind.Var : {
            semaConstLeaf(edit ctx, expr_id, CONST_RUNTIME)
            give sym_type
        }
        SymbolKind.Param : {
            semaConstLeaf(edit ctx, expr_id, CONST_RUNTIME)
            give sym_type
        }
        _ : {
            semaAddError(edit ctx, "L0001", "el nombre no designa un valor", expr.start, expr.end)
            give 7
        }
    }
    hold slot = ctx.symbols.symbols[sym].const_slot
    when slot < 0 || slot >= ctx.consts.length { give 7 }
    when ctx.consts[slot].state == SEMA_CONST_PENDING {
        semaConstEvalGlobal(edit ctx, source, tree, slot)
    }
    hold state = ctx.consts[slot].state
    when state == SEMA_CONST_ACTIVE {
        ctx.const_cycle = true
        give 7
    }
    when state == SEMA_CONST_READY { give ctx.consts[slot].ty }
    give 7
}

// A call is never constant: Stage 0 rejects functions and print as runtime
// operations and struct constructors explicitly. Other constructors (enum
// variants, Option/Result) are outside this subset.
flow semaConstCallType(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int) => Int {
    hold expr = view tree.expressions[expr_id]
    hold print_name = "print"
    when symbolNameEqualsText(source, expr.a, expr.b, print_name) {
        semaConstLeaf(edit ctx, expr_id, CONST_RUNTIME)
        give 6
    }
    hold callee = semaLookupVisible(edit ctx, source, expr.a, expr.b)
    when callee == -2 { give 7 }
    when callee >= 0 {
        hold callee_type = ctx.symbols.symbols[callee].type_id
        choose ctx.symbols.symbols[callee].kind {
            SymbolKind.Func : {
                semaConstLeaf(edit ctx, expr_id, CONST_RUNTIME)
                give callee_type
            }
            SymbolKind.Struct : {
                semaConstLeaf(edit ctx, expr_id, CONST_STRUCT)
                give callee_type
            }
            _ : {}
        }
    }
    semaConstLeaf(edit ctx, expr_id, CONST_UNSUPPORTED)
    give 7
}

// Value of an expression accepted by semaConstType.
flow semaConstFold(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int) => SemaConst {
    when expr_id < 0 || expr_id >= tree.expressions.length { give semaConstFailed() }
    hold expr = view tree.expressions[expr_id]
    choose expr.kind {
        AstExprKind.IntLit : { give semaConstInt(expr.a) }
        AstExprKind.FloatLit : { give semaConstValue(SEMA_CONST_READY, 2, LIR_CONST_FLOAT, expr.a, 0, 0) }
        AstExprKind.BoolLit : { give semaConstBool(expr.a != 0) }
        AstExprKind.UnitLit : { give semaConstValue(SEMA_CONST_READY, 6, LIR_CONST_UNIT, 0, 0, 0) }
        AstExprKind.TextLit : {
            // The literal token includes its quotes (see lirLiteral).
            change start = expr.start
            change end = expr.end
            when end - start >= 2 && source@byteAt(start) == 34 {
                start += 1
                end -= 1
            }
            give semaConstValue(SEMA_CONST_READY, 5, LIR_CONST_TEXT, 0, start, end)
        }
        AstExprKind.Name : {
            hold sym = semaLookupVisible(edit ctx, source, expr.start, expr.end)
            when sym < 0 { give semaConstFailed() }
            hold slot = ctx.symbols.symbols[sym].const_slot
            when slot < 0 || slot >= ctx.consts.length { give semaConstFailed() }
            hold c = view ctx.consts[slot]
            when c.state != SEMA_CONST_READY { give semaConstFailed() }
            give semaConstValue(SEMA_CONST_READY, c.ty, c.kind, c.value, c.start, c.end)
        }
        AstExprKind.Unary : {
            hold sub = semaConstFold(edit ctx, source, tree, expr.a)
            when sub.state != SEMA_CONST_READY { give sub }
            when source@byteAt(expr.b) == 33 { give semaConstBool(sub.value == 0) }
            // Only a negated Float literal is a constant Float (sign flip).
            when sub.ty == 2 { give semaConstValue(SEMA_CONST_READY, 2, LIR_CONST_FLOAT, floatBitsNegate(sub.value), 0, 0) }
            hold min = -9223372036854775807 - 1
            when sub.value == min { give semaConstPanic(edit ctx, expr.start, expr.end) }
            give semaConstInt(0 - sub.value)
        }
        AstExprKind.Binary : {
            hold op = source@byteAt(expr.c)
            hold left = semaConstFold(edit ctx, source, tree, expr.a)
            when left.state != SEMA_CONST_READY { give left }
            when op == 38 && left.value == 0 { give semaConstBool(false) }
            when op == 124 && left.value != 0 { give semaConstBool(true) }
            hold right = semaConstFold(edit ctx, source, tree, expr.b)
            when right.state != SEMA_CONST_READY { give right }
            when op == 38 || op == 124 { give semaConstBool(right.value != 0) }
            hold code = lirBinaryOp(source, expr.c, expr.d)
            when left.ty == 1 {
                hold result = semaConstIntOp(code, left.value, right.value)
                when result.state != SEMA_CONST_READY { give semaConstPanic(edit ctx, expr.start, expr.end) }
                give result
            }
            when (left.ty == 4 || left.ty == 6) && (code == LIR_EQ || code == LIR_NE) {
                give semaConstBool((left.value == right.value) == (code == LIR_EQ))
            }
            semaAddError(edit ctx, "L0004", "operación constante inválida", expr.start, expr.end)
            give semaConstFailed()
        }
        _ : { give semaConstFailed() }
    }
}

// Checked Int operation (Rust checked_* semantics); FAILED on overflow and
// on division or remainder by zero.
flow semaConstIntOp(code: Int, x: Int, y: Int) => SemaConst {
    hold max = 9223372036854775807
    hold min = -9223372036854775807 - 1
    when code == LIR_ADD {
        when (y > 0 && x > max - y) || (y < 0 && x < min - y) { give semaConstFailed() }
        give semaConstInt(x + y)
    }
    when code == LIR_SUB {
        when (y < 0 && x > max + y) || (y > 0 && x < min + y) { give semaConstFailed() }
        give semaConstInt(x - y)
    }
    when code == LIR_MUL {
        change overflow = false
        when x > 0 {
            when y > 0 {
                overflow = x > max / y
            } otherwise {
                overflow = y < min / x
            }
        } otherwise {
            when y > 0 {
                overflow = x < min / y
            } otherwise {
                overflow = x != 0 && y < max / x
            }
        }
        when overflow { give semaConstFailed() }
        give semaConstInt(x * y)
    }
    when code == LIR_DIV || code == LIR_REM {
        when y == 0 || (x == min && y == -1) { give semaConstFailed() }
        when code == LIR_DIV { give semaConstInt(x / y) }
        give semaConstInt(x % y)
    }
    when code == LIR_EQ { give semaConstBool(x == y) }
    when code == LIR_NE { give semaConstBool(x != y) }
    when code == LIR_LT { give semaConstBool(x < y) }
    when code == LIR_LE { give semaConstBool(x <= y) }
    when code == LIR_GT { give semaConstBool(x > y) }
    give semaConstBool(x >= y)
}

// Checks and folds the value of a constant declared at `start`..`end`.
// The result carries the declared type (the annotation when present).
expose flow semaConstDefine(ctx: edit SemaContext, source: view Text, tree: view AstTree, value_id: Int, type_ast: Int, start: Int, end: Int) => SemaConst {
    hold errors_before = ctx.errors.length
    hold saved_leaf = ctx.const_leaf
    hold saved_reason = ctx.const_reason
    ctx.const_leaf = -1
    ctx.const_reason = 0
    hold ty = semaConstType(edit ctx, source, tree, value_id)
    hold leaf = ctx.const_leaf
    hold reason = ctx.const_reason
    ctx.const_leaf = saved_leaf
    ctx.const_reason = saved_reason
    change declared = ty
    change ok = ctx.errors.length == errors_before
    when type_ast >= 0 {
        declared = semaResolveAstType(edit ctx, source, tree, type_ast)
        when ok && ty != 7 && !semTypeEquals(view ctx.types, ty, declared) {
            semaAddError(edit ctx, "L0003", "tipo incompatible en constante", start, end)
            ok = false
        }
    }
    when ok && leaf >= 0 {
        hold leaf_start = tree.expressions[leaf].start
        hold leaf_end = tree.expressions[leaf].end
        when reason == CONST_RUNTIME {
            semaAddError(edit ctx, "L0004", "const requiere expresión constante; variables runtime y llamadas no permitidas", leaf_start, leaf_end)
        } otherwise when reason == CONST_STRUCT {
            semaAddError(edit ctx, "L0001", "const requiere expresión constante; constructores de struct no permitidos aquí", leaf_start, leaf_end)
        } otherwise {
            semaAddError(edit ctx, "L0016", "expresión fuera del subconjunto de constantes de ELE", leaf_start, leaf_end)
        }
        ok = false
    }
    when !ok || ty == 7 {
        give semaConstValue(SEMA_CONST_FAILED, declared, LIR_CONST_UNIT, 0, 0, 0)
    }
    hold folded = semaConstFold(edit ctx, source, tree, value_id)
    when folded.state != SEMA_CONST_READY {
        give semaConstValue(SEMA_CONST_FAILED, declared, LIR_CONST_UNIT, 0, 0, 0)
    }
    give semaConstValue(SEMA_CONST_READY, declared, folded.kind, folded.value, folded.start, folded.end)
}

// Stores `result` in `slot` and types the constant's symbol.
flow semaConstStore(ctx: edit SemaContext, slot: Int, result: view SemaConst) {
    ctx.consts[slot].state = result.state
    ctx.consts[slot].ty = result.ty
    ctx.consts[slot].kind = result.kind
    ctx.consts[slot].value = result.value
    ctx.consts[slot].start = result.start
    ctx.consts[slot].end = result.end
    hold sym = ctx.consts[slot].sym
    when sym >= 0 && sym < ctx.symbols.symbols.length {
        ctx.symbols.symbols[sym].type_id = result.ty
    }
}

flow semaConstEvalGlobal(ctx: edit SemaContext, source: view Text, tree: view AstTree, slot: Int) {
    hold decl_id = ctx.consts[slot].decl
    when decl_id < 0 || decl_id >= tree.declarations.length { give }
    hold decl = view tree.declarations[decl_id]
    ctx.consts[slot].state = SEMA_CONST_ACTIVE
    hold saved_module = ctx.current_module
    ctx.current_module = semaDeclModule(ctx, decl_id)
    hold result = semaConstDefine(edit ctx, source, tree, decl.d, decl.c, decl.start, decl.end)
    ctx.current_module = saved_module
    semaConstStore(edit ctx, slot, view result)
}

// Registers the top-level constant `decl_id`, named by symbol `sym`; its
// value is computed by semaConstEvalAll once every name is declared.
expose flow semaConstDeclare(ctx: edit SemaContext, decl_id: Int, sym: Int) {
    hold slot = ctx.consts.length
    ctx.consts@push(SemaConst(state: SEMA_CONST_PENDING, decl: decl_id, sym: sym, ty: 7, kind: LIR_CONST_UNIT, value: 0, start: 0, end: 0))
    ctx.symbols.symbols[sym].const_slot = slot
}

expose flow semaConstEvalAll(ctx: edit SemaContext, source: view Text, tree: view AstTree) {
    hold saved_module = ctx.current_module
    each slot among 0..ctx.consts.length {
        when ctx.consts[slot].decl >= 0 && ctx.consts[slot].state == SEMA_CONST_PENDING {
            ctx.const_cycle = false
            semaConstEvalGlobal(edit ctx, source, tree, slot)
            when ctx.const_cycle {
                hold decl = view tree.declarations[ctx.consts[slot].decl]
                semaAddError(edit ctx, "L0001", "dependencia circular entre constantes", decl.start, decl.end)
                ctx.const_cycle = false
            }
        }
    }
    ctx.current_module = saved_module
}

// Local `fixed NAME[: T] = value`: evaluated, then bound in the current
// scope (Stage 0 binds after evaluating). It emits no instruction.
expose flow semaStmtConst(ctx: edit SemaContext, source: view Text, tree: view AstTree, stmt_id: Int) {
    hold stmt = view tree.statements[stmt_id]
    hold existing = scopeLookupCurrent(view ctx.scopes, view ctx.symbols, source, stmt.a, stmt.b)
    when existing >= 0 {
        semaAddError(edit ctx, "L0002", "constante duplicada en el mismo ámbito", stmt.start, stmt.end)
        give
    }
    hold result = semaConstDefine(edit ctx, source, tree, stmt.d, stmt.c, stmt.start, stmt.end)
    hold sym = symbolAdd(edit ctx.symbols, SymbolKind.Const, stmt.a, stmt.b, result.ty, ctx.scopes.current_scope, false, false, -1, stmt.start, stmt.end)
    hold slot = ctx.consts.length
    ctx.consts@push(SemaConst(state: result.state, decl: -1, sym: sym, ty: result.ty, kind: result.kind, value: result.value, start: result.start, end: result.end))
    ctx.symbols.symbols[sym].const_slot = slot
    scopeAddSymbol(edit ctx.scopes, sym)
}

// LIR operand of a use of constant symbol `sym`, or LIR_NONE when its
// evaluation failed (already diagnosed).
expose flow semaConstOperand(ctx: edit SemaContext, sym: Int) => Int {
    hold slot = ctx.symbols.symbols[sym].const_slot
    when slot < 0 || slot >= ctx.consts.length { give LIR_NONE }
    when ctx.consts[slot].state != SEMA_CONST_READY { give LIR_NONE }
    hold kind = ctx.consts[slot].kind
    hold value = ctx.consts[slot].value
    hold start = ctx.consts[slot].start
    hold end = ctx.consts[slot].end
    give lirConst(edit ctx.lir, kind, value, start, end)
}

// True when `expr_id` names a constant (assignment target check).
expose flow semaConstNamed(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int) => Bool {
    when expr_id < 0 || expr_id >= tree.expressions.length { give false }
    hold expr = view tree.expressions[expr_id]
    choose expr.kind {
        AstExprKind.Name : {}
        _ : { give false }
    }
    hold sym = scopeLookupAllVisible(view ctx.scopes, view ctx.symbols, source, expr.start, expr.end, ctx.current_module, view ctx.module_access, ctx.module_count)
    when sym < 0 { give false }
    choose ctx.symbols.symbols[sym].kind {
        SymbolKind.Const : { give true }
        _ : { give false }
    }
}
