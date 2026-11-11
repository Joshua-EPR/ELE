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
            if open >= 0 && (p_end <= open + 1 || source.byteAt(p_end - 1) != 41) {
                semaAddError(&mut ctx, "L0004", "patrón de payload mal formado", p_start, p_end)
                valid = false
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

