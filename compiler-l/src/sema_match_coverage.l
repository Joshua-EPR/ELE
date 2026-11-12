import ast
import symbols
import sema_context
import lir_build

// Verify enum arm coverage before lowering: a named final arm may be
// treated as a fallthrough only if every declared variant occurs once.
// Unknown/duplicate patterns and incomplete matches cannot silently turn
// into an unchecked default branch.
pub fn semaEnumMatchCovered(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr: &AstExpr, enum_decl: Int) -> Bool {
    if enum_decl < 0 || enum_decl >= tree.declarations.length { return false }
    let decl = &tree.declarations[enum_decl]
    var seen: List<Bool> = List[]
    for v in 0..decl.d { seen.push(false) }
    var wildcard = false
    var valid = true
    for arm in 0..expr.c {
        let p_start = tree.extra[expr.b + 3 * arm]
        let p_end = tree.extra[expr.b + 3 * arm + 1]
        if p_end == p_start + 1 && source.byteAt(p_start) == 95 {
            if arm != expr.c - 1 { valid = false }
            wildcard = true
            continue
        }
        if wildcard { valid = false }
        // A user-defined variant must be qualified (`Estado.Si`). The
        // qualifier is resolved to the *nominal enum declaration*, not
        // matched merely by the variant's textual spelling. Otherwise a
        // pattern like `OtroEstado.Si(v)` could be accepted for `Estado`.
        var name_start = p_start
        var name_end = p_end
        var qualifier_end = -1
        var open = -1
        var dot_count = 0
        for i in p_start..p_end {
            let byte = source.byteAt(i)
            if byte == 40 && open < 0 {
                open = i
                name_end = i
            }
            if byte == 46 && open < 0 {
                qualifier_end = i
                name_start = i + 1
                dot_count += 1
            }
        }
        if dot_count != 1 || qualifier_end <= p_start || name_start >= name_end {
            // An unqualified name may denote a whole-value binding in ELE,
            // but Stage 1's restricted native match does not lower it yet.
            // Reject its LIR rather than misreading it as an enum variant.
            lirMarkUnsupported(&mut ctx.lir, p_start)
            valid = false
            continue
        }
        let qualifier = semaLookupVisible(&mut ctx, source, p_start, qualifier_end)
        var same_enum = false
        if qualifier >= 0 {
            let sym = &ctx.symbols.symbols[qualifier]
            match sym.kind {
                SymbolKind.Enum => {
                    if sym.decl_id == enum_decl { same_enum = true }
                }
                _ => {}
            }
        }
        if !same_enum {
            semaAddError(&mut ctx, "L0004", "el patrón pertenece a otro enum o tiene un calificador inválido", p_start, p_end)
            valid = false
            continue
        }
        var found = -1
        for v in 0..decl.d {
            let variant = &tree.variants[decl.c + v]
            if symbolNamesEqual(source, variant.name_start, variant.name_end, name_start, name_end) { found = v }
        }
        if found < 0 {
            semaAddError(&mut ctx, "L0004", "patrón de enum desconocido", p_start, p_end)
            valid = false
        } else if seen[found] {
            semaAddError(&mut ctx, "L0004", "variante repetida en match", p_start, p_end)
            valid = false
        } else {
            let variant = &tree.variants[decl.c + found]
            // A unit variant cannot have a payload pattern, and a payload
            // variant must explicitly match its payload. This also prevents
            // silently treating a missing payload binder as a unit variant.
            if (variant.payload_count == 0 && open >= 0) || (variant.payload_count > 0 && open < 0) {
                semaAddError(&mut ctx, "L0004", "aridad incorrecta del patrón de variante", p_start, p_end)
                valid = false
            } else {
                seen[found] = true
            }
            if open >= 0 {
                if p_end <= open + 2 || source.byteAt(p_end - 1) != 41 {
                    semaAddError(&mut ctx, "L0004", "patrón de payload mal formado", p_start, p_end)
                    valid = false
                } else {
                    // In the native Stage 1 subset a primitive payload arm
                    // binds exactly one identifier (or '_'). Do not accept
                    // literals, multiple binders or arbitrary expressions
                    // here: they have no verified lowering or move paths.
                    let first = open + 1
                    let last = p_end - 1
                    var binder_valid = true
                    for j in first..last {
                        let b = source.byteAt(j)
                        let letter = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
                        let digit = (b >= 48 && b <= 57) && j > first
                        if !letter && !digit { binder_valid = false }
                    }
                    if !binder_valid {
                        semaAddError(&mut ctx, "L0004", "patrón de payload requiere un único identificador", p_start, p_end)
                        valid = false
                    }
                }
            }
        }
    }
    if !wildcard {
        for v in 0..decl.d {
            if !seen[v] { valid = false }
        }
    }
    if !valid {
        semaAddError(&mut ctx, "L0004", "match de enum no exhaustivo o con patrones inválidos", expr.start, expr.end)
    }
    return valid
}

// Only two correctly spelled, distinct builtin alternatives prove that a
// tagged Option/Result has no third runtime case. A wildcard is already
// handled by lirMatchArmTest; do not mistake a repeated or malformed payload
// pattern for proof of exhaustiveness. This proof governs CFG reachability,
// never bypasses ownership validation or enables unsupported LIR lowering.
fn semaBuiltinBinderIsName(source: &Text, start: Int, end: Int) -> Bool {
    if end <= start { return false }
    for i in start..end {
        let b = source.byteAt(i)
        let alpha = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
        let digit = b >= 48 && b <= 57 && i > start
        if !alpha && !digit { return false }
    }
    return true
}

pub fn semaBuiltinMatchCovered(source: &Text, tree: &AstTree, expr: &AstExpr, result_type: Bool) -> Bool {
    if expr.c != 2 { return false }
    var seen_zero = false
    var seen_one = false
    for arm in 0..expr.c {
        let start = tree.extra[expr.b + 3 * arm]
        let end = tree.extra[expr.b + 3 * arm + 1]
        let count = end - start
        var variant = -1
        var bind_start = -1
        if result_type {
            if count >= 5 && symbolNameEqualsText(source, start, start + 3, "Ok(") {
                variant = 0
                bind_start = start + 3
            } else if count >= 6 && symbolNameEqualsText(source, start, start + 4, "Err(") {
                variant = 1
                bind_start = start + 4
            }
        } else {
            if count == 4 && symbolNameEqualsText(source, start, end, "None") {
                variant = 0
            } else if count >= 7 && symbolNameEqualsText(source, start, start + 5, "Some(") {
                variant = 1
                bind_start = start + 5
            }
        }
        if variant < 0 { return false }
        if bind_start >= 0 {
            if source.byteAt(end - 1) != 41 { return false }
            if !semaBuiltinBinderIsName(source, bind_start, end - 1) { return false }
        }
        if variant == 0 {
            if seen_zero { return false }
            seen_zero = true
        } else {
            if seen_one { return false }
            seen_one = true
        }
    }
    return seen_zero && seen_one
}
