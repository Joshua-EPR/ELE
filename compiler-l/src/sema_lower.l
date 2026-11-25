take tokens
take ast
take sema_types
take symbols
take flow_cfg
take lir_build
take sema_context

// Lowering helpers used by the semantic pass. Every expression leaves its
// result in the value channel of `ctx.lir`: either a place (a variable or
// a field of one, possibly behind a reference) or an operand (a variable or
// a constant). Consumers turn the channel into what they need, following
// Stage 0 block LIR conventions:
// - an operand reads a Copy place (`Read`) and moves an owned variable;
// - print and interpolation take Text places by reference (no move).

expose flow lirAt(ctx: edit SemaContext, kind: Int, dst: Int, a: Int, b: Int, c: Int) {
    hold outer_at = ctx.lir.at
    when kind == LIR_READ || kind == LIR_STORE || kind == LIR_LOAN {
        hold bounds_at = lirPlaceBoundsAt(view ctx.lir, a)
        when bounds_at >= 0 { ctx.lir.at = bounds_at }
    }
    lirEmit(edit ctx.lir, kind, dst, a, b, c, ctx.flow.current, ctx.flow.events.length)
    ctx.lir.at = outer_at
}

// New variable assigned by one instruction; returns it as an operand.
expose flow lirNew(ctx: edit SemaContext, ty: Int, is_ref: Bool, kind: Int, a: Int, b: Int, c: Int) => Int {
    hold slot = lirVar(edit ctx.lir, ty, is_ref)
    lirAt(edit ctx, kind, slot, a, b, c)
    give slot
}

expose flow lirSetVal(ctx: edit SemaContext, operand: Int) {
    ctx.lir.val = operand
    ctx.lir.place = -1
}

expose flow lirSetPlace(ctx: edit SemaContext, place: Int) {
    ctx.lir.place = place
    ctx.lir.val = LIR_NONE
}

// Consume the value channel as an operand of type `ty`.
expose flow lirTakeOperand(ctx: edit SemaContext, ty: Int) => Int {
    hold place = ctx.lir.place
    when place >= 0 {
        ctx.lir.place = -1
        hold slot = ctx.lir.places[place].root
        when ctx.lir.places[place].parent < 0 && slot >= 0 && !ctx.lir.vars[slot].is_ref { give slot }
        give lirNew(edit ctx, ty, false, LIR_READ, place, 0, 0)
    }
    hold operand = ctx.lir.val
    ctx.lir.val = LIR_NONE
    give operand
}

// Consume the channel as a print/append argument.
expose flow lirTakeArg(ctx: edit SemaContext, ty: Int) => Int {
    when ctx.lir.place >= 0 && ty == 5 {
        hold place = ctx.lir.place
        ctx.lir.place = -1
        give lirArg(edit ctx.lir, true, place, false)
    }
    hold operand = lirTakeOperand(edit ctx, ty)
    give lirArg(edit ctx.lir, false, operand, false)
}

// The channel as a variable (constants are materialized). Used to give an
// owned temporary a variable the drop plan can name.
expose flow lirValueVar(ctx: edit SemaContext, ty: Int) => Int {
    when ctx.lir.place >= 0 { give -1 }
    change operand = ctx.lir.val
    when operand == LIR_NONE { give -1 }
    when !lirIsVar(operand) {
        operand = lirNew(edit ctx, ty, false, LIR_USE, operand, 0, 0)
        ctx.lir.val = operand
    }
    give operand
}

// Constant operand of a literal expression, or LIR_NONE.
expose flow lirLiteral(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int) => Int {
    when expr_id < 0 || expr_id >= tree.expressions.length { give LIR_NONE }
    hold expr = view tree.expressions[expr_id]
    choose expr.kind {
        AstExprKind.IntLit : { give lirConst(edit ctx.lir, LIR_CONST_INT, expr.a, 0, 0) }
        AstExprKind.BoolLit : { give lirConst(edit ctx.lir, LIR_CONST_BOOL, expr.a, 0, 0) }
        AstExprKind.UnitLit : { give lirConst(edit ctx.lir, LIR_CONST_UNIT, 0, 0, 0) }
        AstExprKind.Unary : {
            when expr.b >= 0 && expr.c == expr.b + 1 && expr.b < source.byteLength && source@byteAt(expr.b) == 45 && expr.a >= 0 && expr.a < tree.expressions.length {
                choose tree.expressions[expr.a].kind {
                    AstExprKind.IntLit : {
                        // Negating Int.MIN overflows: leave it to the runtime trap.
                        when tree.expressions[expr.a].a == -9223372036854775807 - 1 { give LIR_NONE }
                        give lirConst(edit ctx.lir, LIR_CONST_INT, 0 - tree.expressions[expr.a].a, 0, 0)
                    }
                    _ : {}
                }
            }
            give LIR_NONE
        }
        AstExprKind.TextLit : {
            // A whole literal token includes its quotes; a segment of an
            // interpolated text does not.
            change start = expr.start
            change end = expr.end
            when end - start >= 2 && source@byteAt(start) == 34 {
                start += 1
                end -= 1
            }
            give lirConst(edit ctx.lir, LIR_CONST_TEXT, 0, start, end)
        }
        _ : { give LIR_NONE }
    }
}

// LIR place of a move path: its root variable and field chain.
expose flow lirPathPlace(ctx: edit SemaContext, path: Int) => Int {
    when path < 0 || path >= ctx.flow.paths.length { give -1 }
    hold parent = ctx.flow.paths[path].parent
    when parent < 0 {
        hold slot = lirPathVar(view ctx.lir, path)
        when slot < 0 { give -1 }
        give lirPlaceVar(edit ctx.lir, slot)
    }
    hold base = lirPathPlace(edit ctx, parent)
    when base < 0 { give -1 }
    give lirPlaceField(edit ctx.lir, base, ctx.lir_field_local[ctx.flow.paths[path].field])
}

// Store `operand` into `place`: plain variables are assigned, projections
// and referents are stored through.
expose flow lirWrite(ctx: edit SemaContext, place: Int, operand: Int) {
    when place < 0 { give }
    hold slot = ctx.lir.places[place].root
    when ctx.lir.places[place].parent < 0 && !ctx.lir.vars[slot].is_ref {
        lirAt(edit ctx, LIR_USE, slot, operand, 0, 0)
    } otherwise {
        lirAt(edit ctx, LIR_STORE, -1, place, operand, 0)
    }
}

// Binary operator encoded by the source bytes of an operator token.
expose flow lirBinaryOp(source: view Text, start: Int, end: Int) => Int {
    hold b0 = source@byteAt(start)
    hold two = end - start >= 2
    when b0 == 43 { give LIR_ADD }
    when b0 == 45 { give LIR_SUB }
    when b0 == 42 { give LIR_MUL }
    when b0 == 47 { give LIR_DIV }
    when b0 == 37 { give LIR_REM }
    when b0 == 61 { give LIR_EQ }
    when b0 == 33 { give LIR_NE }
    when b0 == 60 && two { give LIR_LE }
    when b0 == 60 { give LIR_LT }
    when b0 == 62 && two { give LIR_GE }
    give LIR_GT
}

// Copy a list of argument or operand ids contiguously; returns the first.
expose flow lirSequence(ctx: edit SemaContext, items: view List of[Int]) => Int {
    hold first = ctx.lir.operands.length
    each i among 0..items.length { ctx.lir.operands@push(items[i]) }
    give first
}
