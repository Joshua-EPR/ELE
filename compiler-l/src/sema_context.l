import tokens
import ast
import sema_types
import symbols
import scopes
import flow_cfg
import loans_l
import lir_build

const ACCESS_READ = 0
const ACCESS_MOVE = 1
const ACCESS_PLACE = 2

// Syntactic positions where a borrow or a borrowed call result may appear.
pub const SITE_NONE = 0
pub const SITE_LET = 1
pub const SITE_VAR = 2
pub const SITE_ARG = 3
pub const SITE_RETURN = 4

pub struct SemaError {
    code: Text
    message: Text
    start: Int
    end: Int
}

pub struct SemaContext {
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
    errors: List<SemaError>
    current_fn_ret_type: Int
    current_fn_is_async: Bool
    expected_list_type: Int
    // Context for standalone None/Ok/Err when a concrete type is annotated.
    expected_union_type: Int
    // Module identity: the module whose declarations are being analyzed,
    // and the owning module of each merged-tree declaration.
    current_module: Int
    decl_module: List<Int>
    module_access: List<Int>
    module_count: Int
    // Position of the expression being inferred (SITE_*), consumed by it.
    borrow_site: Int
    // Loan produced by the last borrow-valued expression, or -1.
    pending_loan: Int
    // Drop elaboration (sema_drop.l): memo per type and per AST field,
    // owned root paths in declaration order, scope marks into it, the
    // mark of the innermost loop and the temporaries of the statement.
    drop_memo: List<Int>
    field_types: List<Int>
    owned_locals: List<Int>
    scope_marks: List<Int>
    loop_mark: Int
    pending_temps: List<Int>
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
    lir_lines: List<Text>
    lir_functions: List<Text>
    lir_line_starts: List<Int>
    lir_field_local: List<Int>
    lir_func_index: List<Int>
    lir_struct_index: List<Int>
    lir_main: Int
    lir_insts: Int
    lir_blocks: Int
    lir_failed: Int
}

pub fn semaContextNew() -> SemaContext {
    let errs: List<SemaError> = List[]
    let drop_memo: List<Int> = List[]
    let field_types: List<Int> = List[]
    let owned_locals: List<Int> = List[]
    let scope_marks: List<Int> = List[]
    let pending_temps: List<Int> = List[]
    return SemaContext(
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
    )
}

pub fn semaInitPath(ctx: &mut SemaContext, symbol: Int, start: Int, end: Int) {
    let path = flowRoot(&mut ctx.flow, symbol)
    ctx.symbols.symbols[symbol].move_path = path
    flowEvent(&mut ctx.flow, FLOW_INIT, path, start, end)
}

pub fn semaAccess(ctx: &mut SemaContext, path: Int, ty: Int, mode: Int, start: Int, end: Int) {
    ctx.expression_path = path
    if path < 0 || mode == ACCESS_PLACE { return }
    if ty < 0 || ty >= ctx.types.types.length { return }
    var kind = FLOW_READ
    let t = &ctx.types.types[ty]
    if mode == ACCESS_MOVE && semTypeIsMove(t.kind) {
        if loanOfPath(&ctx.flow, path) >= 0 {
            semaAddError(&mut ctx, "L0005", "no se puede mover un valor recibido por referencia", start, end)
        } else {
            kind = FLOW_MOVE
        }
    }
    flowEvent(&mut ctx.flow, kind, path, start, end)
}

// Referent of a reference type, or -1 when `ty` is not a reference.
pub fn semaRefElem(ctx: &SemaContext, ty: Int) -> Int {
    if ty < 8 || ty >= ctx.types.types.length { return -1 }
    let t = &ctx.types.types[ty]
    match t.kind {
        SemTypeKind.Ref => { return t.elem_type }
        SemTypeKind.MutRef => { return t.elem_type }
        _ => { return -1 }
    }
}

pub fn semaIsMutRef(ctx: &SemaContext, ty: Int) -> Bool {
    if ty < 8 || ty >= ctx.types.types.length { return false }
    match ctx.types.types[ty].kind {
        SemTypeKind.MutRef => { return true }
        _ => { return false }
    }
}

pub fn semaFindField(source: &Text, tree: &AstTree, declaration: Int, start: Int, end: Int) -> Int {
    let decl = &tree.declarations[declaration]
    for i in decl.c..(decl.c + decl.d) {
        let field = &tree.fields[i]
        if symbolNamesEqual(source, field.name_start, field.name_end, start, end) { return i }
    }
    return -1
}

pub fn semaNamedField(source: &Text, tree: &AstTree, declaration: Int, arg: &AstExpr) -> Int {
    match arg.kind {
        AstExprKind.Named => { return semaFindField(source, tree, declaration, arg.a, arg.b) }
        _ => { return -1 }
    }
}

pub fn semaAddError(ctx: &mut SemaContext, code: Text, message: Text, start: Int, end: Int) {
    ctx.errors.push(SemaError(code: code, message: message, start: start, end: end))
}

pub fn semaDeclModule(ctx: &SemaContext, decl: Int) -> Int {
    if decl < 0 || decl >= ctx.decl_module.length { return 0 }
    return ctx.decl_module[decl]
}

pub fn semaSetDeclModules(ctx: &mut SemaContext, decl_module: &List<Int>) {
    for i in 0..decl_module.length {
        ctx.decl_module.push(decl_module[i])
    }
}

pub fn semaSetModuleAccess(ctx: &mut SemaContext, access: &List<Int>, module_count: Int) {
    ctx.module_count = module_count
    for i in 0..access.length { ctx.module_access.push(access[i]) }
}

pub fn semaLookupVisible(ctx: &mut SemaContext, source: &Text, start: Int, end: Int) -> Int {
    let found = scopeLookupAllVisible(&ctx.scopes, &ctx.symbols, source, start, end, ctx.current_module, &ctx.module_access, ctx.module_count)
    if found == -2 {
        semaAddError(&mut ctx, "L0014", "nombre ambiguo: varias declaraciones públicas importadas", start, end)
    }
    return found
}

pub fn semaResolveAstType(ctx: &mut SemaContext, source: &Text, tree: &AstTree, type_id: Int) -> Int {
    if type_id < 0 || type_id >= tree.types.length {
        return 0
    }
    let at = &tree.types[type_id]
    match at.kind {
        AstTypeKind.Int => { return 1 }
        AstTypeKind.Float => { return 2 }
        AstTypeKind.F32 => { return 3 }
        AstTypeKind.Bool => { return 4 }
        AstTypeKind.Text => { return 5 }
        AstTypeKind.Unit => { return 6 }
        AstTypeKind.Named => {
            // `List<T>` is the built-in growable list; any other generic
            // arguments are outside the Stage 1 subset.
            if at.c >= 0 && at.c < tree.extra.length {
                let list_name = "List"
                let result_name = "Result"
                let option_name = "Option"
                if tree.extra[at.c] == 1 && symbolNameEqualsText(source, at.a, at.b, list_name) {
                    let elem = semaResolveAstType(&mut ctx, source, tree, tree.extra[at.c + 1])
                    return semTypeMakeList(&mut ctx.types, elem)
                }
                if tree.extra[at.c] == 1 && symbolNameEqualsText(source, at.a, at.b, option_name) {
                    let elem = semaResolveAstType(&mut ctx, source, tree, tree.extra[at.c + 1])
                    return semTypeMakeOption(&mut ctx.types, elem)
                }
                if tree.extra[at.c] == 2 && symbolNameEqualsText(source, at.a, at.b, result_name) {
                    let ok_elem = semaResolveAstType(&mut ctx, source, tree, tree.extra[at.c + 1])
                    let err_elem = semaResolveAstType(&mut ctx, source, tree, tree.extra[at.c + 2])
                    return semTypeMakeResult(&mut ctx.types, ok_elem, err_elem)
                }
                semaAddError(&mut ctx, "L0016", "argumentos genéricos fuera del subconjunto de Stage 1", at.start, at.end)
                return 7
            }
            let sym_id = semaLookupVisible(&mut ctx, source, at.a, at.b)
            if sym_id == -2 { return 7 }
            if sym_id >= 0 {
                let sym = &ctx.symbols.symbols[sym_id]
                match sym.kind {
                    SymbolKind.Struct => { return sym.type_id }
                    SymbolKind.Enum => { return sym.type_id }
                    _ => {}
                }
            }
            semaAddError(&mut ctx, "L0001", "tipo desconocido", at.start, at.end)
            return 7
        }
        AstTypeKind.Ref => {
            let inner = semaResolveAstType(&mut ctx, source, tree, at.a)
            return semTypeMakeRef(&mut ctx.types, inner, at.b == 1)
        }
        AstTypeKind.Array => {
            let inner = semaResolveAstType(&mut ctx, source, tree, at.a)
            return semTypeMakeArray(&mut ctx.types, inner)
        }
        AstTypeKind.Slice => {
            let inner = semaResolveAstType(&mut ctx, source, tree, at.a)
            return semTypeMakeSlice(&mut ctx.types, inner)
        }
    }
}
