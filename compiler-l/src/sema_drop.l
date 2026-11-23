take tokens
take ast
take sema_types
take symbols
take flow_cfg
take sema_context
take lir_build
take sema_lower

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

fixed DROP_UNKNOWN = 0
fixed DROP_NO = 1
fixed DROP_YES = 2

expose flow semaFieldType(ctx: edit SemaContext, source: view Text, tree: view AstTree, field: Int) => Int {
    during ctx.field_types.length < tree.fields.length { ctx.field_types@push(-2) }
    when ctx.field_types[field] == -2 {
        hold ty = semaResolveAstType(edit ctx, source, tree, tree.fields[field].type_id)
        ctx.field_types[field] = ty
    }
    give ctx.field_types[field]
}

// Does a value of type `ty` own something that must be released? Mirrors
// Stage 0 `Ownership::needs_drop` for the Stage 1 subset. Memoized per type.
expose flow semaNeedsDrop(ctx: edit SemaContext, source: view Text, tree: view AstTree, ty: Int) => Bool {
    when ty < 0 || ty >= ctx.types.types.length { give false }
    during ctx.drop_memo.length < ctx.types.types.length { ctx.drop_memo@push(DROP_UNKNOWN) }
    when ctx.drop_memo[ty] != DROP_UNKNOWN { give ctx.drop_memo[ty] == DROP_YES }
    change shape = 0
    change elem = -1
    change nominal = -1
    hold t = view ctx.types.types[ty]
    elem = t.elem_type
    nominal = t.nominal_id
    choose t.kind {
        SemTypeKind.Text : { shape = 1 }
        SemTypeKind.List : { shape = 1 }
        SemTypeKind.Array : { shape = 2 }
        SemTypeKind.Struct : { shape = 3 }
        SemTypeKind.Enum : { shape = 4 }
        SemTypeKind.Option : { shape = 5 }
        SemTypeKind.Result : { shape = 6 }
        _ : {}
    }
    // A linear resource owns an OS resource: tracked like an owner so moves
    // are checked, but never dropped implicitly (flowVerify status 4).
    when semTypeIsLinear(view ctx.types, ty) { shape = 1 }
    change needs = shape == 1
    when shape == 2 || shape == 5 || shape == 6 {
        needs = semaNeedsDrop(edit ctx, source, tree, elem)
        // Result<T,E> owns exactly the active payload, but *both* possible
        // payload types affect whether its whole tagged value needs a drop.
        // Do not short-circuit: either branch may contain heap ownership.
        when shape == 6 {
            when semaNeedsDrop(edit ctx, source, tree, nominal) { needs = true }
        }
    }
    when shape == 3 && nominal >= 0 {
        hold first = tree.declarations[nominal].c
        hold count = tree.declarations[nominal].d
        each f among first..(first + count) {
            // End the field lookup's mutable borrow before recursive drop analysis.
            hold field_t = semaFieldType(edit ctx, source, tree, f)
            when semaNeedsDrop(edit ctx, source, tree, field_t) { needs = true }
        }
    }
    when shape == 4 && nominal >= 0 {
        hold first = tree.declarations[nominal].c
        hold count = tree.declarations[nominal].d
        each v among first..(first + count) {
            hold payload = tree.variants[v].first_payload_index
            each k among 0..tree.variants[v].payload_count {
                hold pt = semaResolveAstType(edit ctx, source, tree, tree.extra[payload + k])
                when semaNeedsDrop(edit ctx, source, tree, pt) { needs = true }
            }
        }
    }
    change memo = DROP_NO
    when needs { memo = DROP_YES }
    ctx.drop_memo[ty] = memo
    give needs
}

flow semaIsStruct(ctx: view SemaContext, ty: Int) => Bool {
    when ty < 0 || ty >= ctx.types.types.length { give false }
    choose ctx.types.types[ty].kind {
        SemTypeKind.Struct : { give true }
        _ : { give false }
    }
}

// Create the drop leaves of `path`. Struct fields are created in
// declaration order, so the path tree lists them last-first and a preorder
// walk visits leaves in Stage 0 drop order (reverse fields, depth first).
flow semaMaterialize(ctx: edit SemaContext, source: view Text, tree: view AstTree, path: Int, ty: Int) => Bool {
    when !semaNeedsDrop(edit ctx, source, tree, ty) { give false }
    when semaIsStruct(ctx, ty) {
        hold decl = ctx.types.types[ty].nominal_id
        hold first = tree.declarations[decl].c
        hold count = tree.declarations[decl].d
        each f among first..(first + count) {
            hold field_t = semaFieldType(edit ctx, source, tree, f)
            when semaNeedsDrop(edit ctx, source, tree, field_t) {
                hold child = flowField(edit ctx.flow, path, f)
                semaMaterialize(edit ctx, source, tree, child, field_t)
            }
        }
        give true
    }
    flowPad(edit ctx.flow)
    ctx.flow.drop_types[path] = ty
    give true
}

// Register an owned binding: parameter (origin -1 - index), local
// (origin = initializer offset). Bindings owning nothing are not tracked.
expose flow semaOwn(ctx: edit SemaContext, source: view Text, tree: view AstTree, path: Int, ty: Int, origin: Int) {
    when path < 0 { give }
    semaOrigin(edit ctx, path, origin)
    when semaMaterialize(edit ctx, source, tree, path, ty) {
        ctx.owned_locals@push(path)
    }
}

// Source offset that names the value of an initializer, as Stage 0 spans
// its lowering: a field read is named by its `.`, a borrow by its place.
expose flow semaValueOrigin(source: view Text, tree: view AstTree, expr_id: Int) => Int {
    change cursor = expr_id
    during cursor >= 0 && cursor < tree.expressions.length {
        hold expr = view tree.expressions[cursor]
        choose expr.kind {
            AstExprKind.Field : {
                // Stage 0 names a projection by its `.`.
                change dot = expr.b - 1
                during dot > 0 && source@byteAt(dot) != 46 { dot -= 1 }
                give dot
            }
            AstExprKind.Unary : {
                when expr.b >= 0 && expr.b < source.byteLength && source@byteAt(expr.b) == 38 {
                    cursor = expr.a
                } otherwise {
                    give expr.start
                }
            }
            _ : { give expr.start }
        }
    }
    give FLOW_NO_ORIGIN
}

// Record where a binding (owned or reference) was defined.
expose flow semaOrigin(ctx: edit SemaContext, path: Int, origin: Int) {
    when path < 0 { give }
    flowPad(edit ctx.flow)
    ctx.flow.origins[path] = origin
}

expose flow semaScopeEnter(ctx: edit SemaContext) {
    ctx.scope_marks@push(ctx.owned_locals.length)
}

// Emit FLOW_DROP for owned bindings declared after `mark`, last first.
expose flow semaDropFrom(ctx: edit SemaContext, mark: Int, start: Int, end: Int) {
    change i = ctx.owned_locals.length - 1
    during i >= mark && i >= 0 {
        flowEvent(edit ctx.flow, FLOW_DROP, ctx.owned_locals[i], start, end)
        i -= 1
    }
}

expose flow semaScopeExit(ctx: edit SemaContext, start: Int, end: Int) {
    change mark = 0
    choose ctx.scope_marks@pop() {
        Some(m) : { mark = m }
        None : {}
    }
    semaDropFrom(edit ctx, mark, start, end)
    during ctx.owned_locals.length > mark {
        ctx.owned_locals@pop()
    }
}

// An owned value produced and not consumed by its statement. It is placed
// in creation order at `mark`: an interpolation buffer exists before the
// temporaries of its parts, so it is released after them.
expose flow semaTempAt(ctx: edit SemaContext, source: view Text, tree: view AstTree, ty: Int, start: Int, end: Int, mark: Int) {
    hold before = ctx.pending_temps.length
    semaTemp(edit ctx, source, tree, ty, start, end)
    when ctx.pending_temps.length == before { give }
    change i = ctx.pending_temps.length - 1
    during i > mark && i > 0 {
        hold moved = ctx.pending_temps[i]
        ctx.pending_temps[i] = ctx.pending_temps[i - 1]
        ctx.pending_temps[i - 1] = moved
        i -= 1
    }
}

expose flow semaTemp(ctx: edit SemaContext, source: view Text, tree: view AstTree, ty: Int, start: Int, end: Int) {
    when !semaNeedsDrop(edit ctx, source, tree, ty) { give }
    hold path = flowRoot(edit ctx.flow, -1)
    // Snapshot the newly allocated value before borrowing ctx.lir exclusively.
    hold value = lirValueVar(edit ctx, ty)
    lirBindPath(edit ctx.lir, path, value)
    flowPad(edit ctx.flow)
    ctx.flow.origins[path] = start
    semaMaterialize(edit ctx, source, tree, path, ty)
    flowEvent(edit ctx.flow, FLOW_INIT, path, start, end)
    ctx.pending_temps@push(path)
}

// An owned temporary scrutinee (e.g. `choose readText(...)`) held among LIR
// variable `value`. It becomes an owned binding of the enclosing scope, not
// a statement temporary: an arm that binds its payload moves it, and every
// exit (arm end, give, leave, proceed) drops it otherwise. Returns its
// move path, or -1 when it owns nothing.
expose flow semaOwnScrutinee(ctx: edit SemaContext, source: view Text, tree: view AstTree, value: Int, ty: Int, start: Int, end: Int) => Int {
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
expose flow semaFlushTemps(ctx: edit SemaContext, start: Int, end: Int) {
    during ctx.pending_temps.length > 0 {
        choose ctx.pending_temps@pop() {
            Some(path) : { flowEvent(edit ctx.flow, FLOW_DROP, path, start, end) }
            None : {}
        }
    }
}

// Reset the per-function drop bookkeeping.
expose flow semaDropReset(ctx: edit SemaContext) {
    during ctx.owned_locals.length > 0 { ctx.owned_locals@pop() }
    during ctx.scope_marks.length > 0 { ctx.scope_marks@pop() }
    during ctx.pending_temps.length > 0 { ctx.pending_temps@pop() }
    ctx.loop_mark = 0
}
