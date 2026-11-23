take tokens
take ast
take sema_types
take symbols
take flow_cfg
take loans_l
take sema_context
take lir_build
take sema_lower

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
expose flow semaPlaceRoot(tree: view AstTree, expr_id: Int) => Int {
    change cursor = expr_id
    during cursor >= 0 && cursor < tree.expressions.length {
        hold expr = view tree.expressions[cursor]
        choose expr.kind {
            AstExprKind.Name : { give cursor }
            AstExprKind.Field : { cursor = expr.a }
            AstExprKind.Index : { cursor = expr.a }
            _ : { give -1 }
        }
    }
    give -1
}

// Create the loan for `&place` / `&mut place` once the operand has been
// resolved to `path`. A place below a reference binding reborrows it.
expose flow semaBorrowPlace(ctx: edit SemaContext, path: Int, operand_t: Int, is_mut: Bool, site: Int, start: Int, end: Int) => Int {
    ctx.pending_loan = -1
    when path < 0 {
        semaAddError(edit ctx, "L0012", "use let para prestar una variable, campo o elemento con un origen fijo", start, end)
        give 7
    }
    change code = "L0012"
    when site == SITE_ARG { code = "L0001" }
    hold existing = loanOfPath(view ctx.flow, path)
    change referent = operand_t
    hold elem = semaRefElem(ctx, operand_t)
    when elem >= 0 { referent = elem }
    when is_mut {
        change allowed = loanIsMut(view ctx.flow, existing)
        when existing < 0 {
            hold symbol = ctx.flow.paths[flowRootPath(view ctx.flow, path)].symbol
            allowed = ctx.symbols.symbols[symbol].is_mut
        }
        when !allowed {
            semaAddError(edit ctx, code, "no se puede prestar mutablemente una variable inmutable", start, end)
            give 7
        }
    }
    change kind = LOAN_SHARED
    when is_mut { kind = LOAN_MUT }
    flowEvent(edit ctx.flow, FLOW_READ, path, start, end)
    ctx.lir.borrowed = lirPathPlace(edit ctx, path)
    hold place = loanPlaceOf(edit ctx.flow, path)
    hold loan = loanNew(edit ctx.flow, kind, place, existing, start, end)
    flowEventData(edit ctx.flow, FLOW_LOAN_CREATE, path, start, end, loan)
    ctx.pending_loan = loan
    give semTypeMakeRef(edit ctx.types, referent, is_mut)
}

// Close a call: the argument loans are used at the call point, so two
// arguments borrowing the same place must be compatible. A borrowing
// callee yields a result loan that reborrows every reference argument.
expose flow semaCallLoans(ctx: edit SemaContext, loans: view List of[Int], ret_t: Int, site: Int, start: Int, end: Int) => Int {
    ctx.pending_loan = -1
    change origins: List of[Int] = List[]
    each a among 0..loans.length {
        hold loan = loans[a]
        when loan >= 0 {
            // Read the existing loan place before mutating the event graph.
            hold place = ctx.flow.loans[loan].place
            flowEventData(edit ctx.flow, FLOW_LOAN_USE, place, start, end, loan)
            origins@push(loan)
        }
    }
    when semaRefElem(ctx, ret_t) < 0 { give ret_t }
    when site == SITE_VAR {
        semaAddError(edit ctx, "L0013", "el resultado prestado requiere let y una anotación de referencia compatible", start, end)
        give 7
    }
    when site != SITE_LET && site != SITE_RETURN {
        semaAddError(edit ctx, "L0013", "use el resultado prestado como inicializador de let o retorno prestado, con un receptor que sea un lugar", start, end)
        give 7
    }
    when origins.length == 0 { give ret_t }
    change kind = LOAN_SHARED
    when semaIsMutRef(ctx, ret_t) { kind = LOAN_MUT }
    hold head = loanResult(edit ctx.flow, kind, view origins, start, end)
    change node = head
    during node >= 0 {
        hold place = ctx.flow.loans[node].place
        flowEventData(edit ctx.flow, FLOW_LOAN_CREATE, place, start, end, node)
        node = ctx.flow.loans[node].alt
    }
    ctx.pending_loan = head
    give ret_t
}

// A borrowed return must carry a loan of a compatible mode whose every
// origin is rooted at a reference parameter.
expose flow semaReturnBorrow(ctx: edit SemaContext, value_t: Int, loan: Int, start: Int, end: Int) {
    hold ret_t = ctx.current_fn_ret_type
    when loan < 0 {
        semaAddError(edit ctx, "L0013", "un retorno de referencia necesita un parámetro prestado compatible con su modo; los propietarios locales se destruyen al retornar", start, end)
        give
    }
    hold origin_status = loanBorrowedReturnStatus(view ctx.flow, loan, semaIsMutRef(ctx, ret_t))
    when origin_status == 2 {
        semaAddError(edit ctx, "L0013", "el modo del préstamo no coincide con el retorno", start, end)
        give
    }
    when origin_status != 0 {
        semaAddError(edit ctx, "L0013", "un retorno de referencia necesita un parámetro prestado compatible con su modo; los propietarios locales se destruyen al retornar", start, end)
        give
    }
    hold expected = semaRefElem(ctx, ret_t)
    hold actual = semaRefElem(ctx, value_t)
    when !semTypeEquals(view ctx.types, expected, actual) {
        semaAddError(edit ctx, "L0003", "tipo de retorno incompatible en el retorno prestado", start, end)
    }
}

// Reject reference types outside parameters, results and let annotations.
expose flow semaCheckRefTypes(ctx: edit SemaContext, tree: view AstTree) {
    each i among 0..tree.types.length {
        hold ty = view tree.types[i]
        change inner = -1
        choose ty.kind {
            AstTypeKind.Ref : { inner = ty.a }
            AstTypeKind.Array : { inner = ty.a }
            AstTypeKind.Slice : {
                semaAddError(edit ctx, "L0016", "vistas de colecciones fuera del subconjunto verificado", ty.start, ty.end)
            }
            _ : {}
        }
        when inner >= 0 && inner < tree.types.length {
            choose tree.types[inner].kind {
                AstTypeKind.Ref : {
                    semaAddError(edit ctx, "L0012", "referencias anidadas o almacenadas en colecciones fuera del subconjunto de Stage 1", ty.start, ty.end)
                }
                _ : {}
            }
        }
    }
    each i among 0..tree.fields.length {
        hold field = view tree.fields[i]
        when field.type_id >= 0 && field.type_id < tree.types.length {
            choose tree.types[field.type_id].kind {
                AstTypeKind.Ref : {
                    semaAddError(edit ctx, "L0012", "un struct no puede almacenar referencias en el subconjunto de Stage 1", field.name_start, field.name_end)
                }
                _ : {}
            }
        }
    }
}
