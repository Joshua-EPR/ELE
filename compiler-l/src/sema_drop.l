import tokens
import ast
import sema_types
import symbols
import flow_cfg
import sema_context
import lir_build
import sema_lower

// Semantic side of Stage 1 drop elaboration. While the AST is checked this
// module records, on the existing CFG, which paths own resources and where
// their lexical lifetime ends:
// - every owned binding materializes one move path per leaf that needs a
//   drop (Text, List, arrays, enums and Option/Result with owned payloads; struct fields
//   recursively), so moves and drops act on the same cells;
// - leaving a scope, `return`, `break` and `continue` emit FLOW_DROP for
//   the owned bindings they leave, innermost scope first and in reverse
//   declaration order (Stage 0 order);
// - owned temporaries (a discarded call result, a printed or interpolated
//   value) get a synthetic path, FLOW_INIT where they are produced and
//   FLOW_DROP at the end of their statement.
// drops_plan.l turns those events into the drop plan.

const DROP_UNKNOWN = 0
const DROP_NO = 1
const DROP_YES = 2

pub fn semaFieldType(ctx: &mut SemaContext, source: &Text, tree: &AstTree, field: Int) -> Int {
    while ctx.field_types.length < tree.fields.length { ctx.field_types.push(-2) }
    if ctx.field_types[field] == -2 {
        let ty = semaResolveAstType(&mut ctx, source, tree, tree.fields[field].type_id)
        ctx.field_types[field] = ty
    }
    return ctx.field_types[field]
}

// Does a value of type `ty` own something that must be released? Mirrors
// Stage 0 `Ownership::needs_drop` for the Stage 1 subset. Memoized per type.
pub fn semaNeedsDrop(ctx: &mut SemaContext, source: &Text, tree: &AstTree, ty: Int) -> Bool {
    if ty < 0 || ty >= ctx.types.types.length { return false }
    while ctx.drop_memo.length < ctx.types.types.length { ctx.drop_memo.push(DROP_UNKNOWN) }
    if ctx.drop_memo[ty] != DROP_UNKNOWN { return ctx.drop_memo[ty] == DROP_YES }
    var shape = 0
    var elem = -1
    var nominal = -1
    let t = &ctx.types.types[ty]
    elem = t.elem_type
    nominal = t.nominal_id
    match t.kind {
        SemTypeKind.Text => { shape = 1 }
        SemTypeKind.List => { shape = 1 }
        SemTypeKind.Array => { shape = 2 }
        SemTypeKind.Struct => { shape = 3 }
        SemTypeKind.Enum => { shape = 4 }
        SemTypeKind.Option => { shape = 5 }
        SemTypeKind.Result => { shape = 6 }
        _ => {}
    }
    var needs = shape == 1
    if shape == 2 || shape == 5 || shape == 6 {
        needs = semaNeedsDrop(&mut ctx, source, tree, elem)
        // Result<T,E> owns exactly the active payload, but *both* possible
        // payload types affect whether its whole tagged value needs a drop.
        // Do not short-circuit: either branch may contain heap ownership.
        if shape == 6 {
            if semaNeedsDrop(&mut ctx, source, tree, nominal) { needs = true }
        }
    }
    if shape == 3 && nominal >= 0 {
        let first = tree.declarations[nominal].c
        let count = tree.declarations[nominal].d
        for f in first..(first + count) {
            // End the field lookup's mutable borrow before recursive drop analysis.
            let field_t = semaFieldType(&mut ctx, source, tree, f)
            if semaNeedsDrop(&mut ctx, source, tree, field_t) { needs = true }
        }
    }
    if shape == 4 && nominal >= 0 {
        let first = tree.declarations[nominal].c
        let count = tree.declarations[nominal].d
        for v in first..(first + count) {
            let payload = tree.variants[v].first_payload_index
            for k in 0..tree.variants[v].payload_count {
                let pt = semaResolveAstType(&mut ctx, source, tree, tree.extra[payload + k])
                if semaNeedsDrop(&mut ctx, source, tree, pt) { needs = true }
            }
        }
    }
    var memo = DROP_NO
    if needs { memo = DROP_YES }
    ctx.drop_memo[ty] = memo
    return needs
}

fn semaIsStruct(ctx: &SemaContext, ty: Int) -> Bool {
    if ty < 0 || ty >= ctx.types.types.length { return false }
    match ctx.types.types[ty].kind {
        SemTypeKind.Struct => { return true }
        _ => { return false }
    }
}

// Create the drop leaves of `path`. Struct fields are created in
// declaration order, so the path tree lists them last-first and a preorder
// walk visits leaves in Stage 0 drop order (reverse fields, depth first).
fn semaMaterialize(ctx: &mut SemaContext, source: &Text, tree: &AstTree, path: Int, ty: Int) -> Bool {
    if !semaNeedsDrop(&mut ctx, source, tree, ty) { return false }
    if semaIsStruct(ctx, ty) {
        let decl = ctx.types.types[ty].nominal_id
        let first = tree.declarations[decl].c
        let count = tree.declarations[decl].d
        for f in first..(first + count) {
            let field_t = semaFieldType(&mut ctx, source, tree, f)
            if semaNeedsDrop(&mut ctx, source, tree, field_t) {
                let child = flowField(&mut ctx.flow, path, f)
                semaMaterialize(&mut ctx, source, tree, child, field_t)
            }
        }
        return true
    }
    flowPad(&mut ctx.flow)
    ctx.flow.drop_types[path] = ty
    return true
}

// Register an owned binding: parameter (origin -1 - index), local
// (origin = initializer offset). Bindings owning nothing are not tracked.
pub fn semaOwn(ctx: &mut SemaContext, source: &Text, tree: &AstTree, path: Int, ty: Int, origin: Int) {
    if path < 0 { return }
    semaOrigin(&mut ctx, path, origin)
    if semaMaterialize(&mut ctx, source, tree, path, ty) {
        ctx.owned_locals.push(path)
    }
}

// Source offset that names the value of an initializer, as Stage 0 spans
// its lowering: a field read is named by its `.`, a borrow by its place.
pub fn semaValueOrigin(source: &Text, tree: &AstTree, expr_id: Int) -> Int {
    var cursor = expr_id
    while cursor >= 0 && cursor < tree.expressions.length {
        let expr = &tree.expressions[cursor]
        match expr.kind {
            AstExprKind.Field => {
                // Stage 0 names a projection by its `.`.
                var dot = expr.b - 1
                while dot > 0 && source.byteAt(dot) != 46 { dot -= 1 }
                return dot
            }
            AstExprKind.Unary => {
                if expr.b >= 0 && expr.b < source.byteLength && source.byteAt(expr.b) == 38 {
                    cursor = expr.a
                } else {
                    return expr.start
                }
            }
            _ => { return expr.start }
        }
    }
    return FLOW_NO_ORIGIN
}

// Record where a binding (owned or reference) was defined.
pub fn semaOrigin(ctx: &mut SemaContext, path: Int, origin: Int) {
    if path < 0 { return }
    flowPad(&mut ctx.flow)
    ctx.flow.origins[path] = origin
}

pub fn semaScopeEnter(ctx: &mut SemaContext) {
    ctx.scope_marks.push(ctx.owned_locals.length)
}

// Emit FLOW_DROP for owned bindings declared after `mark`, last first.
pub fn semaDropFrom(ctx: &mut SemaContext, mark: Int, start: Int, end: Int) {
    var i = ctx.owned_locals.length - 1
    while i >= mark && i >= 0 {
        flowEvent(&mut ctx.flow, FLOW_DROP, ctx.owned_locals[i], start, end)
        i -= 1
    }
}

pub fn semaScopeExit(ctx: &mut SemaContext, start: Int, end: Int) {
    var mark = 0
    match ctx.scope_marks.pop() {
        Some(m) => { mark = m }
        None => {}
    }
    semaDropFrom(&mut ctx, mark, start, end)
    while ctx.owned_locals.length > mark {
        ctx.owned_locals.pop()
    }
}

// An owned value produced and not consumed by its statement. It is placed
// in creation order at `mark`: an interpolation buffer exists before the
// temporaries of its parts, so it is released after them.
pub fn semaTempAt(ctx: &mut SemaContext, source: &Text, tree: &AstTree, ty: Int, start: Int, end: Int, mark: Int) {
    let before = ctx.pending_temps.length
    semaTemp(&mut ctx, source, tree, ty, start, end)
    if ctx.pending_temps.length == before { return }
    var i = ctx.pending_temps.length - 1
    while i > mark && i > 0 {
        let moved = ctx.pending_temps[i]
        ctx.pending_temps[i] = ctx.pending_temps[i - 1]
        ctx.pending_temps[i - 1] = moved
        i -= 1
    }
}

pub fn semaTemp(ctx: &mut SemaContext, source: &Text, tree: &AstTree, ty: Int, start: Int, end: Int) {
    if !semaNeedsDrop(&mut ctx, source, tree, ty) { return }
    let path = flowRoot(&mut ctx.flow, -1)
    // Snapshot the newly allocated value before borrowing ctx.lir exclusively.
    let value = lirValueVar(&mut ctx, ty)
    lirBindPath(&mut ctx.lir, path, value)
    flowPad(&mut ctx.flow)
    ctx.flow.origins[path] = start
    semaMaterialize(&mut ctx, source, tree, path, ty)
    flowEvent(&mut ctx.flow, FLOW_INIT, path, start, end)
    ctx.pending_temps.push(path)
}

// An owned temporary scrutinee (e.g. `choose readText(...)`) held among LIR
// variable `value`. It becomes an owned binding of the enclosing scope, not
// a statement temporary: an arm that binds its payload moves it, and every
// exit (arm end, give, leave, proceed) drops it otherwise. Returns its
// move path, or -1 when it owns nothing.
pub flow semaOwnScrutinee(ctx: edit SemaContext, source: view Text, tree: view AstTree, value: Int, ty: Int, start: Int, end: Int) => Int {
    when value < 0 || !semaNeedsDrop(edit ctx, source, tree, ty) { give -1 }
    hold path = flowRoot(edit ctx.flow, -1)
    lirBindPath(edit ctx.lir, path, value)
    flowPad(edit ctx.flow)
    ctx.flow.origins[path] = start
    semaMaterialize(edit ctx, source, tree, path, ty)
    flowEvent(edit ctx.flow, FLOW_INIT, path, start, end)
    ctx.owned_locals@push(path)
    give path
}

// Temporaries die at the end of their statement, last created first.
pub fn semaFlushTemps(ctx: &mut SemaContext, start: Int, end: Int) {
    while ctx.pending_temps.length > 0 {
        match ctx.pending_temps.pop() {
            Some(path) => { flowEvent(&mut ctx.flow, FLOW_DROP, path, start, end) }
            None => {}
        }
    }
}

// Reset the per-function drop bookkeeping.
pub fn semaDropReset(ctx: &mut SemaContext) {
    while ctx.owned_locals.length > 0 { ctx.owned_locals.pop() }
    while ctx.scope_marks.length > 0 { ctx.scope_marks.pop() }
    while ctx.pending_temps.length > 0 { ctx.pending_temps.pop() }
    ctx.loop_mark = 0
}
