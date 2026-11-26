take tokens
take ast
take sema_types
take symbols
take scopes
take flow_cfg
take loans_l
take lir_build

expose fixed ACCESS_READ = 0
expose fixed ACCESS_MOVE = 1
expose fixed ACCESS_PLACE = 2

// Syntactic positions where a borrow or a borrowed call result may appear.
expose fixed SITE_NONE = 0
expose fixed SITE_LET = 1
expose fixed SITE_VAR = 2
expose fixed SITE_ARG = 3
expose fixed SITE_RETURN = 4

// Compile-time constant (sema_const.l): evaluation state (SEMA_CONST_*),
// owning declaration (-1 for a local `fixed`), symbol, declared type and the
// folded value as a LIR constant (kind, value and, for Text, source span).
expose fixed SEMA_CONST_PENDING = 0
expose fixed SEMA_CONST_ACTIVE = 1
expose fixed SEMA_CONST_READY = 2
expose fixed SEMA_CONST_FAILED = 3

expose fixed SEMA_INFER_NONE = 0
expose fixed SEMA_INFER_PENDING = 1
expose fixed SEMA_INFER_DONE = 2
expose fixed SEMA_INFER_FAILED = 3

expose shape SemaConst {
    state: Int
    decl: Int
    sym: Int
    ty: Int
    kind: Int
    value: Int
    start: Int
    end: Int
}

expose shape SemaError {
    code: Text
    message: Text
    start: Int
    end: Int
}

expose shape SemaContext {
    types: TypeTable
    symbols: SymbolTable
    scopes: ScopeTree
    flow: FlowGraph
    expression_path: Int
    flow_blocks: Int
    flow_edges: Int
    flow_paths: Int
    flow_iterations: Int
    flow_loans: Int
    loan_iterations: Int
    errors: List of[SemaError]
    current_fn_ret_type: Int
    current_fn_is_async: Bool
    expected_list_type: Int
    // Context for standalone None/Ok/Err when a concrete type is annotated.
    expected_union_type: Int
    // Module identity: the module whose declarations are being analyzed,
    // and the owning module of each merged-tree declaration.
    current_module: Int
    decl_module: List of[Int]
    module_access: List of[Int]
    module_count: Int
    // Position of the expression being inferred (SITE_*), consumed by it.
    borrow_site: Int
    // Loan produced by the last borrow-valued expression, or -1.
    pending_loan: Int
    // Drop elaboration (sema_drop.l): memo per type and per AST field,
    // owned root paths in declaration order, scope marks into it, the
    // mark of the innermost loop and the temporaries of the statement.
    drop_memo: List of[Int]
    field_types: List of[Int]
    owned_locals: List of[Int]
    scope_marks: List of[Int]
    loop_mark: Int
    pending_temps: List of[Int]
    // Symbols whose value a `choose` arm with a non-Copy binding examines:
    // assigning them inside that arm is L0005 (SEMANTICS.md, Stage 0).
    frozen_symbols: List of[Int]
    dump_drops: Bool
    drop_fault: Int
    drop_ops: Int
    drop_flags: Int
    drop_count: Int
    drop_iterations: Int
    // ELE LIR (lir_build.l): the function being lowered, per-AST tables
    // (local index of each field, LIR index of each function and struct
    // declaration), buffered output and statistics.
    lir: LirFn
    lir_module: LirModule
    emit_lir: Bool
    lir_fault: Int
    // Test hook: forged-instruction patch applied before verification.
    lir_patch: Text
    lir_lines: List of[Text]
    lir_functions: List of[Text]
    lir_line_starts: List of[Int]
    lir_field_local: List of[Int]
    lir_func_index: List of[Int]
    lir_struct_index: List of[Int]
    lir_main: Int
    lir_insts: Int
    lir_blocks: Int
    lir_failed: Int
    // Constant evaluation (sema_const.l): the table, a dependency cycle seen
    // by the current root declaration, and the first non-constant operand
    // of the expression being checked with its reason.
    consts: List of[SemaConst]
    const_cycle: Bool
    const_leaf: Int
    const_reason: Int
    // Result types inferred for expression-bodied flows without `=>`
    // (SEMA_INFER_*), by declaration: state and type; whether the dry run
    // being checked used a result not yet known, whether it is a dry run,
    // and the type of its last `give`.
    infer_state: List of[Int]
    infer_ret: List of[Int]
    infer_blocked: Bool
    infer_dry: Bool
    infer_last: Int
}

expose flow semaContextNew() => SemaContext {
    hold errs: List of[SemaError] = List[]
    hold drop_memo: List of[Int] = List[]
    hold field_types: List of[Int] = List[]
    hold owned_locals: List of[Int] = List[]
    hold scope_marks: List of[Int] = List[]
    hold pending_temps: List of[Int] = List[]
    hold frozen_symbols: List of[Int] = List[]
    give SemaContext(
        types: typeTableNew(),
        symbols: symbolTableNew(),
        scopes: scopeTreeNew(),
        flow: flowNew(),
        expression_path: -1,
        flow_blocks: 0,
        flow_edges: 0,
        flow_paths: 0,
        flow_iterations: 0,
        flow_loans: 0,
        loan_iterations: 0,
        errors: errs,
        current_fn_ret_type: 6,
        current_fn_is_async: false,
        expected_list_type: -1,
        expected_union_type: -1,
        current_module: 0,
        decl_module: List[],
        module_access: List[],
        module_count: 0,
        borrow_site: 0,
        pending_loan: -1,
        drop_memo: drop_memo,
        field_types: field_types,
        owned_locals: owned_locals,
        scope_marks: scope_marks,
        loop_mark: 0,
        pending_temps: pending_temps,
        frozen_symbols: frozen_symbols,
        dump_drops: false,
        drop_fault: 0,
        drop_ops: 0,
        drop_flags: 0,
        drop_count: 0,
        drop_iterations: 0,
        lir: lirFnNew(),
        lir_module: lirModuleNew(),
        emit_lir: false,
        lir_fault: 0,
        lir_patch: "",
        lir_lines: List[],
        lir_functions: List[],
        lir_line_starts: List[],
        lir_field_local: List[],
        lir_func_index: List[],
        lir_struct_index: List[],
        lir_main: -1,
        lir_insts: 0,
        lir_blocks: 0,
        lir_failed: 0,
        consts: List[],
        const_cycle: false,
        const_leaf: -1,
        const_reason: 0,
        infer_state: List[],
        infer_ret: List[],
        infer_blocked: false,
        infer_dry: false,
        infer_last: -1,
    )
}

expose flow semaInferState(ctx: view SemaContext, decl_id: Int) => Int {
    when decl_id < 0 || decl_id >= ctx.infer_state.length { give SEMA_INFER_NONE }
    give ctx.infer_state[decl_id]
}

// Result type of a function declaration: the annotation, `()` when absent,
// or the type inferred from an expression body (`flow f() = expr`; 7 while it
// is still unknown).
expose flow semaDeclRet(ctx: edit SemaContext, source: view Text, tree: view AstTree, decl_id: Int) => Int {
    when semaInferState(view ctx, decl_id) != SEMA_INFER_NONE {
        give ctx.infer_ret[decl_id]
    }
    hold annotation = tree.declarations[decl_id].f
    when annotation >= 0 { give semaResolveAstType(edit ctx, source, tree, annotation) }
    give 6
}

// A call whose callee result is still being inferred blocks the dry run that
// contains it: it is retried once the callee is known.
expose flow semaNoteCallee(ctx: edit SemaContext, decl_id: Int) {
    when semaInferState(view ctx, decl_id) == SEMA_INFER_PENDING { ctx.infer_blocked = true }
}

expose flow semaInitPath(ctx: edit SemaContext, symbol: Int, start: Int, end: Int) {
    hold path = flowRoot(edit ctx.flow, symbol)
    ctx.symbols.symbols[symbol].move_path = path
    flowEvent(edit ctx.flow, FLOW_INIT, path, start, end)
}

expose flow semaAccess(ctx: edit SemaContext, path: Int, ty: Int, mode: Int, start: Int, end: Int) {
    ctx.expression_path = path
    when path < 0 || mode == ACCESS_PLACE { give }
    when ty < 0 || ty >= ctx.types.types.length { give }
    change kind = FLOW_READ
    hold t = view ctx.types.types[ty]
    when mode == ACCESS_MOVE && semTypeIsMove(t.kind) {
        when loanOfPath(view ctx.flow, path) >= 0 {
            semaAddError(edit ctx, "L0005", "no se puede mover un valor recibido por referencia", start, end)
        } otherwise {
            kind = FLOW_MOVE
        }
    }
    flowEvent(edit ctx.flow, kind, path, start, end)
}

// Referent of a reference type, or -1 when `ty` is not a reference.
expose flow semaRefElem(ctx: view SemaContext, ty: Int) => Int {
    when ty < 8 || ty >= ctx.types.types.length { give -1 }
    hold t = view ctx.types.types[ty]
    choose t.kind {
        SemTypeKind.Ref : { give t.elem_type }
        SemTypeKind.MutRef : { give t.elem_type }
        _ : { give -1 }
    }
}

expose flow semaIsMutRef(ctx: view SemaContext, ty: Int) => Bool {
    when ty < 8 || ty >= ctx.types.types.length { give false }
    choose ctx.types.types[ty].kind {
        SemTypeKind.MutRef : { give true }
        _ : { give false }
    }
}

expose flow semaFindField(source: view Text, tree: view AstTree, declaration: Int, start: Int, end: Int) => Int {
    hold decl = view tree.declarations[declaration]
    each i among decl.c..(decl.c + decl.d) {
        hold field = view tree.fields[i]
        when symbolNamesEqual(source, field.name_start, field.name_end, start, end) { give i }
    }
    give -1
}

expose flow semaNamedField(source: view Text, tree: view AstTree, declaration: Int, arg: view AstExpr) => Int {
    choose arg.kind {
        AstExprKind.Named : { give semaFindField(source, tree, declaration, arg.a, arg.b) }
        _ : { give -1 }
    }
}

expose flow semaAddError(ctx: edit SemaContext, code: Text, message: Text, start: Int, end: Int) {
    ctx.errors@push(SemaError(code: code, message: message, start: start, end: end))
}

expose flow semaDeclModule(ctx: view SemaContext, decl: Int) => Int {
    when decl < 0 || decl >= ctx.decl_module.length { give 0 }
    give ctx.decl_module[decl]
}

expose flow semaSetDeclModules(ctx: edit SemaContext, decl_module: view List of[Int]) {
    each i among 0..decl_module.length {
        ctx.decl_module@push(decl_module[i])
    }
}

expose flow semaSetModuleAccess(ctx: edit SemaContext, access: view List of[Int], module_count: Int) {
    ctx.module_count = module_count
    each i among 0..access.length { ctx.module_access@push(access[i]) }
}

expose flow semaLookupVisible(ctx: edit SemaContext, source: view Text, start: Int, end: Int) => Int {
    hold found = scopeLookupAllVisible(view ctx.scopes, view ctx.symbols, source, start, end, ctx.current_module, view ctx.module_access, ctx.module_count)
    when found == -2 {
        semaAddError(edit ctx, "L0014", "nombre ambiguo: varias declaraciones públicas importadas", start, end)
    }
    give found
}

expose flow semaResolveAstType(ctx: edit SemaContext, source: view Text, tree: view AstTree, type_id: Int) => Int {
    when type_id < 0 || type_id >= tree.types.length {
        give 0
    }
    hold at = view tree.types[type_id]
    choose at.kind {
        AstTypeKind.Int : { give 1 }
        AstTypeKind.Float : { give 2 }
        AstTypeKind.F32 : {
            semaAddError(edit ctx, "L0016", "F32 no está soportado por el driver ELE; use Float", at.start, at.end)
            give 7
        }
        AstTypeKind.Bool : { give 4 }
        AstTypeKind.Text : { give 5 }
        AstTypeKind.Unit : { give 6 }
        AstTypeKind.Named : {
            // `List<T>` is the built-in growable list; any other generic
            // arguments are outside the Stage 1 subset.
            when at.c >= 0 && at.c < tree.extra.length {
                hold list_name = "List"
                hold result_name = "Result"
                hold option_name = "Option"
                when tree.extra[at.c] == 1 && symbolNameEqualsText(source, at.a, at.b, list_name) {
                    hold elem = semaResolveAstType(edit ctx, source, tree, tree.extra[at.c + 1])
                    when semaRejectLinearElem(edit ctx, elem, at.start, at.end) { give 7 }
                    give semTypeMakeList(edit ctx.types, elem)
                }
                // `T?` is parsed as a nameless one-argument type (span 0..0).
                hold is_sugar = at.a == 0 && at.b == 0
                when tree.extra[at.c] == 1 && (is_sugar || symbolNameEqualsText(source, at.a, at.b, option_name)) {
                    hold elem = semaResolveAstType(edit ctx, source, tree, tree.extra[at.c + 1])
                    when semaRejectLinearElem(edit ctx, elem, at.start, at.end) { give 7 }
                    give semTypeMakeOption(edit ctx.types, elem)
                }
                when tree.extra[at.c] == 2 && symbolNameEqualsText(source, at.a, at.b, result_name) {
                    hold ok_elem = semaResolveAstType(edit ctx, source, tree, tree.extra[at.c + 1])
                    hold err_elem = semaResolveAstType(edit ctx, source, tree, tree.extra[at.c + 2])
                    when semaRejectLinearElem(edit ctx, ok_elem, at.start, at.end) || semaRejectLinearElem(edit ctx, err_elem, at.start, at.end) { give 7 }
                    give semTypeMakeResult(edit ctx.types, ok_elem, err_elem)
                }
                semaAddError(edit ctx, "L0016", "argumentos genéricos fuera del subconjunto de Stage 1", at.start, at.end)
                give 7
            }
            hold sym_id = semaLookupVisible(edit ctx, source, at.a, at.b)
            when sym_id == -2 { give 7 }
            when sym_id >= 0 {
                hold sym = view ctx.symbols.symbols[sym_id]
                choose sym.kind {
                    SymbolKind.Struct : { give sym.type_id }
                    SymbolKind.Enum : { give sym.type_id }
                    _ : {}
                }
            }
            // The built-in opaque File, unless a program shape shadows it.
            hold file_name = "File"
            when symbolNameEqualsText(source, at.a, at.b, file_name) { give semTypeMakeFile(edit ctx.types) }
            hold window_name = "Window"
            when symbolNameEqualsText(source, at.a, at.b, window_name) { give semTypeMakeWindow(edit ctx.types) }
            semaAddError(edit ctx, "L0001", "tipo desconocido", at.start, at.end)
            give 7
        }
        AstTypeKind.Ref : {
            hold inner = semaResolveAstType(edit ctx, source, tree, at.a)
            give semTypeMakeRef(edit ctx.types, inner, at.b == 1)
        }
        AstTypeKind.Array : {
            hold inner = semaResolveAstType(edit ctx, source, tree, at.a)
            when semaRejectLinearElem(edit ctx, inner, at.start, at.end) { give 7 }
            give semTypeMakeArray(edit ctx.types, inner)
        }
        AstTypeKind.Slice : {
            hold inner = semaResolveAstType(edit ctx, source, tree, at.a)
            when semaRejectLinearElem(edit ctx, inner, at.start, at.end) { give 7 }
            give semTypeMakeSlice(edit ctx.types, inner)
        }
    }
}

// Linear resources (semTypeIsLinear): a container, option, result, shape
// field or choice payload would release one through an ordinary drop
// without closing it.
expose flow semaRejectLinearElem(ctx: edit SemaContext, elem: Int, start: Int, end: Int) => Bool {
    when !semTypeIsLinear(view ctx.types, elem) { give false }
    hold name = semTypeLinearName(view ctx.types, elem)
    hold message = "{name} es lineal: no puede guardarse en List, Option, Result, arreglos, shapes ni choices"
    semaAddError(edit ctx, "L0016", message, start, end)
    give true
}
