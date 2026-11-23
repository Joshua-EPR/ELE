take ast
take symbols
take sema_context
take lir_build

// Verify enum arm coverage before lowering: a named final arm may be
// treated as a fallthrough only if every declared variant occurs once.
// Unknown/duplicate patterns and incomplete matches cannot silently turn
// into an unchecked default branch.
expose flow semaEnumMatchCovered(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr: view AstExpr, enum_decl: Int) => Bool {
    when enum_decl < 0 || enum_decl >= tree.declarations.length { give false }
    hold decl = view tree.declarations[enum_decl]
    change seen: List of[Bool] = List[]
    each v among 0..decl.d { seen@push(false) }
    change wildcard = false
    change valid = true
    each arm among 0..expr.c {
        hold p_start = tree.extra[expr.b + 3 * arm]
        hold p_end = tree.extra[expr.b + 3 * arm + 1]
        when p_end == p_start + 1 && source@byteAt(p_start) == 95 {
            when arm != expr.c - 1 { valid = false }
            wildcard = true
            proceed
        }
        when wildcard { valid = false }
        // A user-defined variant must be qualified (`Estado.Si`). The
        // qualifier is resolved to the *nominal enum declaration*, not
        // matched merely by the variant's textual spelling. Otherwise a
        // pattern like `OtroEstado.Si(v)` could be accepted for `Estado`.
        change name_start = p_start
        change name_end = p_end
        change qualifier_end = -1
        change open = -1
        change dot_count = 0
        each i among p_start..p_end {
            hold byte = source@byteAt(i)
            when byte == 40 && open < 0 {
                open = i
                name_end = i
            }
            when byte == 46 && open < 0 {
                qualifier_end = i
                name_start = i + 1
                dot_count += 1
            }
        }
        when dot_count != 1 || qualifier_end <= p_start || name_start >= name_end {
            // An unqualified name may denote a whole-value binding in ELE,
            // but Stage 1's restricted native match does not lower it yet.
            // Reject its LIR rather than misreading it as an enum variant.
            lirMarkUnsupported(edit ctx.lir, p_start)
            valid = false
            proceed
        }
        hold qualifier = semaLookupVisible(edit ctx, source, p_start, qualifier_end)
        change same_enum = false
        when qualifier >= 0 {
            hold sym = view ctx.symbols.symbols[qualifier]
            choose sym.kind {
                SymbolKind.Enum : {
                    when sym.decl_id == enum_decl { same_enum = true }
                }
                _ : {}
            }
        }
        when !same_enum {
            semaAddError(edit ctx, "L0004", "el patrón pertenece a otro enum o tiene un calificador inválido", p_start, p_end)
            valid = false
            proceed
        }
        change found = -1
        each v among 0..decl.d {
            hold variant = view tree.variants[decl.c + v]
            when symbolNamesEqual(source, variant.name_start, variant.name_end, name_start, name_end) { found = v }
        }
        when found < 0 {
            semaAddError(edit ctx, "L0004", "patrón de enum desconocido", p_start, p_end)
            valid = false
        } otherwise when seen[found] {
            semaAddError(edit ctx, "L0004", "variante repetida en match", p_start, p_end)
            valid = false
        } otherwise {
            hold variant = view tree.variants[decl.c + found]
            // A unit variant cannot have a payload pattern, and a payload
            // variant must explicitly match its payload. This also prevents
            // silently treating a missing payload binder as a unit variant.
            when (variant.payload_count == 0 && open >= 0) || (variant.payload_count > 0 && open < 0) {
                semaAddError(edit ctx, "L0004", "aridad incorrecta del patrón de variante", p_start, p_end)
                valid = false
            } otherwise {
                seen[found] = true
            }
            when open >= 0 {
                when p_end <= open + 2 || source@byteAt(p_end - 1) != 41 {
                    semaAddError(edit ctx, "L0004", "patrón de payload mal formado", p_start, p_end)
                    valid = false
                } otherwise {
                    // In the native Stage 1 subset a primitive payload arm
                    // binds exactly one identifier (or '_'). Do not accept
                    // literals, multiple binders or arbitrary expressions
                    // here: they have no verified lowering or move paths.
                    hold first = open + 1
                    hold last = p_end - 1
                    change binder_valid = true
                    each j among first..last {
                        hold b = source@byteAt(j)
                        hold letter = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
                        hold digit = (b >= 48 && b <= 57) && j > first
                        when !letter && !digit { binder_valid = false }
                    }
                    when !binder_valid {
                        semaAddError(edit ctx, "L0004", "patrón de payload requiere un único identificador", p_start, p_end)
                        valid = false
                    }
                }
            }
        }
    }
    when !wildcard {
        each v among 0..decl.d {
            when !seen[v] { valid = false }
        }
    }
    when !valid {
        semaAddError(edit ctx, "L0004", "match de enum no exhaustivo o con patrones inválidos", expr.start, expr.end)
    }
    give valid
}

// Only two correctly spelled, distinct builtin alternatives prove that a
// tagged Option/Result has no third runtime case. A wildcard is already
// handled by lirMatchArmTest; do not mistake a repeated or malformed payload
// pattern for proof of exhaustiveness. This proof governs CFG reachability,
// never bypasses ownership validation or enables unsupported LIR lowering.
flow semaBuiltinBinderIsName(source: view Text, start: Int, end: Int) => Bool {
    when end <= start { give false }
    each i among start..end {
        hold b = source@byteAt(i)
        hold alpha = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
        hold digit = b >= 48 && b <= 57 && i > start
        when !alpha && !digit { give false }
    }
    give true
}

expose flow semaBuiltinMatchCovered(source: view Text, tree: view AstTree, expr: view AstExpr, result_type: Bool) => Bool {
    when expr.c != 2 { give false }
    // Stage 0 requires a variable/field at a &Text parameter. Keep these
    // patterns as reusable Text bindings rather than temporary literals.
    hold ok_name = "Ok("
    hold err_name = "Err("
    hold some_name = "Some("
    hold none_name = "None"
    change seen_zero = false
    change seen_one = false
    each arm among 0..expr.c {
        hold start = tree.extra[expr.b + 3 * arm]
        hold end = tree.extra[expr.b + 3 * arm + 1]
        hold count = end - start
        change variant = -1
        change bind_start = -1
        when result_type {
            when count >= 5 && symbolNameEqualsText(source, start, start + 3, ok_name) {
                variant = 0
                bind_start = start + 3
            } otherwise when count >= 6 && symbolNameEqualsText(source, start, start + 4, err_name) {
                variant = 1
                bind_start = start + 4
            }
        } otherwise {
            when count == 4 && symbolNameEqualsText(source, start, end, none_name) {
                variant = 0
            } otherwise when count >= 7 && symbolNameEqualsText(source, start, start + 5, some_name) {
                variant = 1
                bind_start = start + 5
            }
        }
        when variant < 0 { give false }
        when bind_start >= 0 {
            when source@byteAt(end - 1) != 41 { give false }
            when !semaBuiltinBinderIsName(source, bind_start, end - 1) { give false }
        }
        when variant == 0 {
            when seen_zero { give false }
            seen_zero = true
        } otherwise {
            when seen_one { give false }
            seen_one = true
        }
    }
    give seen_zero && seen_one
}
