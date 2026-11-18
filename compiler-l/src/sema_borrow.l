import tokens
import ast
import sema_types
import symbols
import flow_cfg
import loans_l
import sema_context
import lir_build
import sema_lower

// Semantic side of the Stage 1 borrow checker. Borrows are accepted only
// where Stage 0 accepts them: a `let` initializer, an argument for a
// reference parameter and a borrowed return. Every borrow site becomes a
// loan; its exclusivity and lifetime are verified by loans_check.l.
//
// Borrowed-return contract (signature based, as in Stage 0): the result of
// a function returning a reference may borrow from any of its reference
// parameters, so a caller keeps every reference argument borrowed while
// the result is live. The callee proves that each returned loan is rooted
// at one of its reference parameters, never at a local owner.

// Root name expression of a place (`a`, `a.b.c`), or -1.
pub fn semaPlaceRoot(tree: &AstTree, expr_id: Int) -> Int {
    var cursor = expr_id
    while cursor >= 0 && cursor < tree.expressions.length {
        let expr = &tree.expressions[cursor]
        match expr.kind {
            AstExprKind.Name => { return cursor }
            AstExprKind.Field => { cursor = expr.a }
            AstExprKind.Index => { cursor = expr.a }
            _ => { return -1 }
        }
    }
    return -1
}

// Create the loan for `&place` / `&mut place` once the operand has been
// resolved to `path`. A place below a reference binding reborrows it.
pub fn semaBorrowPlace(ctx: &mut SemaContext, path: Int, operand_t: Int, is_mut: Bool, site: Int, start: Int, end: Int) -> Int {
    ctx.pending_loan = -1
    if path < 0 {
        semaAddError(&mut ctx, "L0012", "use let para prestar una variable, campo o elemento con un origen fijo", start, end)
        return 7
    }
    var code = "L0012"
    if site == SITE_ARG { code = "L0001" }
    let existing = loanOfPath(&ctx.flow, path)
    var referent = operand_t
    let elem = semaRefElem(ctx, operand_t)
    if elem >= 0 { referent = elem }
    if is_mut {
        var allowed = loanIsMut(&ctx.flow, existing)
        if existing < 0 {
            let symbol = ctx.flow.paths[flowRootPath(&ctx.flow, path)].symbol
            allowed = ctx.symbols.symbols[symbol].is_mut
        }
        if !allowed {
            semaAddError(&mut ctx, code, "no se puede prestar mutablemente una variable inmutable", start, end)
            return 7
        }
    }
    var kind = LOAN_SHARED
    if is_mut { kind = LOAN_MUT }
    flowEvent(&mut ctx.flow, FLOW_READ, path, start, end)
    ctx.lir.borrowed = lirPathPlace(&mut ctx, path)
    let place = loanPlaceOf(&mut ctx.flow, path)
    let loan = loanNew(&mut ctx.flow, kind, place, existing, start, end)
    flowEventData(&mut ctx.flow, FLOW_LOAN_CREATE, path, start, end, loan)
    ctx.pending_loan = loan
    return semTypeMakeRef(&mut ctx.types, referent, is_mut)
}

// Close a call: the argument loans are used at the call point, so two
// arguments borrowing the same place must be compatible. A borrowing
// callee yields a result loan that reborrows every reference argument.
pub fn semaCallLoans(ctx: &mut SemaContext, loans: &List<Int>, ret_t: Int, site: Int, start: Int, end: Int) -> Int {
    ctx.pending_loan = -1
    var origins: List<Int> = List[]
    for a in 0..loans.length {
        let loan = loans[a]
        if loan >= 0 {
            // Read the existing loan place before mutating the event graph.
            let place = ctx.flow.loans[loan].place
            flowEventData(&mut ctx.flow, FLOW_LOAN_USE, place, start, end, loan)
            origins.push(loan)
        }
    }
    if semaRefElem(ctx, ret_t) < 0 { return ret_t }
    if site == SITE_VAR {
        semaAddError(&mut ctx, "L0013", "el resultado prestado requiere let y una anotación de referencia compatible", start, end)
        return 7
    }
    if site != SITE_LET && site != SITE_RETURN {
        semaAddError(&mut ctx, "L0013", "use el resultado prestado como inicializador de let o retorno prestado, con un receptor que sea un lugar", start, end)
        return 7
    }
    if origins.length == 0 { return ret_t }
    var kind = LOAN_SHARED
    if semaIsMutRef(ctx, ret_t) { kind = LOAN_MUT }
    let head = loanResult(&mut ctx.flow, kind, &origins, start, end)
    var node = head
    while node >= 0 {
        let place = ctx.flow.loans[node].place
        flowEventData(&mut ctx.flow, FLOW_LOAN_CREATE, place, start, end, node)
        node = ctx.flow.loans[node].alt
    }
    ctx.pending_loan = head
    return ret_t
}

// A borrowed return must carry a loan of a compatible mode whose every
// origin is rooted at a reference parameter.
pub fn semaReturnBorrow(ctx: &mut SemaContext, value_t: Int, loan: Int, start: Int, end: Int) {
    let ret_t = ctx.current_fn_ret_type
    if loan < 0 {
        semaAddError(&mut ctx, "L0013", "un retorno de referencia necesita un parámetro prestado compatible con su modo; los propietarios locales se destruyen al retornar", start, end)
        return
    }
    let origin_status = loanBorrowedReturnStatus(&ctx.flow, loan, semaIsMutRef(ctx, ret_t))
    if origin_status == 2 {
        semaAddError(&mut ctx, "L0013", "el modo del préstamo no coincide con el retorno", start, end)
        return
    }
    if origin_status != 0 {
        semaAddError(&mut ctx, "L0013", "un retorno de referencia necesita un parámetro prestado compatible con su modo; los propietarios locales se destruyen al retornar", start, end)
        return
    }
    let expected = semaRefElem(ctx, ret_t)
    let actual = semaRefElem(ctx, value_t)
    if !semTypeEquals(&ctx.types, expected, actual) {
        semaAddError(&mut ctx, "L0003", "tipo de retorno incompatible en el retorno prestado", start, end)
    }
}

// Reject reference types outside parameters, results and let annotations.
pub fn semaCheckRefTypes(ctx: &mut SemaContext, tree: &AstTree) {
    for i in 0..tree.types.length {
        let ty = &tree.types[i]
        var inner = -1
        match ty.kind {
            AstTypeKind.Ref => { inner = ty.a }
            AstTypeKind.Array => { inner = ty.a }
            AstTypeKind.Slice => {
                semaAddError(&mut ctx, "L0016", "vistas de colecciones fuera del subconjunto verificado", ty.start, ty.end)
            }
            _ => {}
        }
        if inner >= 0 && inner < tree.types.length {
            match tree.types[inner].kind {
                AstTypeKind.Ref => {
                    semaAddError(&mut ctx, "L0012", "referencias anidadas o almacenadas en colecciones fuera del subconjunto de Stage 1", ty.start, ty.end)
                }
                _ => {}
            }
        }
    }
    for i in 0..tree.fields.length {
        let field = &tree.fields[i]
        if field.type_id >= 0 && field.type_id < tree.types.length {
            match tree.types[field.type_id].kind {
                AstTypeKind.Ref => {
                    semaAddError(&mut ctx, "L0012", "un struct no puede almacenar referencias en el subconjunto de Stage 1", field.name_start, field.name_end)
                }
                _ => {}
            }
        }
    }
}
