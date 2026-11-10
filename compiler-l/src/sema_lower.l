import tokens
import ast
import sema_types
import symbols
import flow_cfg
import lir_build
import sema_context

// Lowering helpers used by the semantic pass. Every expression leaves its
// result in the value channel of `ctx.lir`: either a place (a variable or
// a field of one, possibly behind a reference) or an operand (a variable or
// a constant). Consumers turn the channel into what they need, following
// Stage 0 block LIR conventions:
// - an operand reads a Copy place (`Read`) and moves an owned variable;
// - print and interpolation take Text places by reference (no move).

fn lirAt(ctx: &mut SemaContext, kind: Int, dst: Int, a: Int, b: Int, c: Int) {
    lirEmit(&mut ctx.lir, kind, dst, a, b, c, ctx.flow.current, ctx.flow.events.length)
}

// New variable assigned by one instruction; returns it as an operand.
fn lirNew(ctx: &mut SemaContext, ty: Int, is_ref: Bool, kind: Int, a: Int, b: Int, c: Int) -> Int {
    let slot = lirVar(&mut ctx.lir, ty, is_ref)
    lirAt(&mut ctx, kind, slot, a, b, c)
    return slot
}

fn lirSetVal(ctx: &mut SemaContext, operand: Int) {
    ctx.lir.val = operand
    ctx.lir.place = -1
}

fn lirSetPlace(ctx: &mut SemaContext, place: Int) {
    ctx.lir.place = place
    ctx.lir.val = LIR_NONE
}

// Consume the value channel as an operand of type `ty`.
fn lirTakeOperand(ctx: &mut SemaContext, ty: Int) -> Int {
    let place = ctx.lir.place
    if place >= 0 {
        ctx.lir.place = -1
        let slot = ctx.lir.places[place].root
        if ctx.lir.places[place].parent < 0 && slot >= 0 && !ctx.lir.vars[slot].is_ref { return slot }
        return lirNew(&mut ctx, ty, false, LIR_READ, place, 0, 0)
    }
    let operand = ctx.lir.val
    ctx.lir.val = LIR_NONE
    return operand
}

// Consume the channel as a print/append argument.
fn lirTakeArg(ctx: &mut SemaContext, ty: Int) -> Int {
    if ctx.lir.place >= 0 && ty == 5 {
        let place = ctx.lir.place
        ctx.lir.place = -1
        return lirArg(&mut ctx.lir, true, place, false)
    }
    let operand = lirTakeOperand(&mut ctx, ty)
    return lirArg(&mut ctx.lir, false, operand, false)
}

// The channel as a variable (constants are materialized). Used to give an
// owned temporary a variable the drop plan can name.
fn lirValueVar(ctx: &mut SemaContext, ty: Int) -> Int {
    if ctx.lir.place >= 0 { return -1 }
    var operand = ctx.lir.val
    if operand == LIR_NONE { return -1 }
    if !lirIsVar(operand) {
        operand = lirNew(&mut ctx, ty, false, LIR_USE, operand, 0, 0)
        ctx.lir.val = operand
    }
    return operand
}

// Constant operand of a literal expression, or LIR_NONE.
fn lirLiteral(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int) -> Int {
    if expr_id < 0 || expr_id >= tree.expressions.length { return LIR_NONE }
    let expr = &tree.expressions[expr_id]
    match expr.kind {
        AstExprKind.IntLit => { return lirConst(&mut ctx.lir, LIR_CONST_INT, expr.a, 0, 0) }
        AstExprKind.BoolLit => { return lirConst(&mut ctx.lir, LIR_CONST_BOOL, expr.a, 0, 0) }
        AstExprKind.UnitLit => { return lirConst(&mut ctx.lir, LIR_CONST_UNIT, 0, 0, 0) }
        AstExprKind.Unary => {
            if expr.b >= 0 && expr.c == expr.b + 1 && expr.b < source.byteLength && source.byteAt(expr.b) == 45 && expr.a >= 0 && expr.a < tree.expressions.length {
                match tree.expressions[expr.a].kind {
                    AstExprKind.IntLit => {
                        return lirConst(&mut ctx.lir, LIR_CONST_INT, 0 - tree.expressions[expr.a].a, 0, 0)
                    }
                    _ => {}
                }
            }
            return LIR_NONE
        }
        AstExprKind.TextLit => {
            // A whole literal token includes its quotes; a segment of an
            // interpolated text does not.
            var start = expr.start
            var end = expr.end
            if end - start >= 2 && source.byteAt(start) == 34 {
                start += 1
                end -= 1
            }
            return lirConst(&mut ctx.lir, LIR_CONST_TEXT, 0, start, end)
        }
        _ => { return LIR_NONE }
    }
}

// LIR place of a move path: its root variable and field chain.
fn lirPathPlace(ctx: &mut SemaContext, path: Int) -> Int {
    if path < 0 || path >= ctx.flow.paths.length { return -1 }
    let parent = ctx.flow.paths[path].parent
    if parent < 0 {
        let slot = lirPathVar(&ctx.lir, path)
        if slot < 0 { return -1 }
        return lirPlaceVar(&mut ctx.lir, slot)
    }
    let base = lirPathPlace(&mut ctx, parent)
    if base < 0 { return -1 }
    return lirPlaceField(&mut ctx.lir, base, ctx.lir_field_local[ctx.flow.paths[path].field])
}

// Store `operand` into `place`: plain variables are assigned, projections
// and referents are stored through.
fn lirWrite(ctx: &mut SemaContext, place: Int, operand: Int) {
    if place < 0 { return }
    let slot = ctx.lir.places[place].root
    if ctx.lir.places[place].parent < 0 && !ctx.lir.vars[slot].is_ref {
        lirAt(&mut ctx, LIR_USE, slot, operand, 0, 0)
    } else {
        lirAt(&mut ctx, LIR_STORE, -1, place, operand, 0)
    }
}

// Binary operator encoded by the source bytes of an operator token.
fn lirBinaryOp(source: &Text, start: Int, end: Int) -> Int {
    let b0 = source.byteAt(start)
    let two = end - start >= 2
    if b0 == 43 { return LIR_ADD }
    if b0 == 45 { return LIR_SUB }
    if b0 == 42 { return LIR_MUL }
    if b0 == 47 { return LIR_DIV }
    if b0 == 37 { return LIR_REM }
    if b0 == 61 { return LIR_EQ }
    if b0 == 33 { return LIR_NE }
    if b0 == 60 && two { return LIR_LE }
    if b0 == 60 { return LIR_LT }
    if b0 == 62 && two { return LIR_GE }
    return LIR_GT
}

// Copy a list of argument or operand ids contiguously; returns the first.
fn lirSequence(ctx: &mut SemaContext, items: &List<Int>) -> Int {
    let first = ctx.lir.operands.length
    for i in 0..items.length { ctx.lir.operands.push(items[i]) }
    return first
}
