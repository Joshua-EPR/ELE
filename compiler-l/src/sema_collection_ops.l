import tokens
import ast
import sema_types
import symbols
import scopes
import flow_cfg
import loans_l
import lir_build
import sema_context
import sema_lower
take lir_builtin_union

pub fn semaExpectedListElem(ctx: &SemaContext) -> Int {
    let expected = ctx.expected_list_type
    if expected >= 0 && expected < ctx.types.types.length {
        match ctx.types.types[expected].kind {
            SemTypeKind.List => { return ctx.types.types[expected].elem_type }
            _ => {}
        }
    }
    return 0
}

pub fn semaFinishCollectionLit(ctx: &mut SemaContext, expr: &AstExpr, is_array: Bool, elem_t: Int, elements: &List<Int>) -> Int {
    when semaRejectLinearElem(edit ctx, elem_t, expr.start, expr.end) { give 7 }
    if is_array {
        lirMarkUnsupported(&mut ctx.lir, expr.start)
        return semTypeMakeArray(&mut ctx.types, elem_t)
    }
    let list_t = semTypeMakeList(&mut ctx.types, elem_t)
    if elem_t <= 0 {
        lirMarkUnsupported(&mut ctx.lir, expr.start)
        return list_t
    }
    let list_index = lirListRegister(&mut ctx.lir_module, elem_t)
    let first = lirSequence(&mut ctx, elements)
    // Preserve literal element order while ending the nested mutable borrow.
    let value = lirNew(&mut ctx, list_t, false, LIR_LIST_LIT, list_index, first, elements.length)
    lirSetVal(&mut ctx, value)
    return list_t
}

fn semaMethodMutable(ctx: &mut SemaContext, base_t: Int, base_path: Int, start: Int, end: Int) -> Bool {
    if semaRefElem(ctx, base_t) >= 0 && !semaIsMutRef(ctx, base_t) {
        semaAddError(&mut ctx, "L0001", "el método requiere un receptor mutable", start, end)
        return false
    }
    if base_path >= 0 {
        let loan = loanOfPath(&ctx.flow, base_path)
        if loan >= 0 {
            if !loanIsMut(&ctx.flow, loan) {
                semaAddError(&mut ctx, "L0001", "el método requiere un préstamo mutable", start, end)
                return false
            }
        } else {
            let sym = ctx.flow.paths[base_path].symbol
            if sym < 0 || !ctx.symbols.symbols[sym].is_mut {
                semaAddError(&mut ctx, "L0006", "el método requiere una variable mutable", start, end)
                return false
            }
        }
    }
    return true
}

pub fn semaMethodFinish(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, base_t: Int, bp: Int, base_path: Int, count: Int, arg_t: Int, arg_op: Int) -> Int {
    let expr = &tree.expressions[expr_id]
    var base_place = bp
    if base_place < 0 {
        let h = lirValueVar(&mut ctx, base_t)
        if h >= 0 { base_place = lirPlaceVar(&mut ctx.lir, h) }
    }
    var inner_t = base_t
    let ref_t = semaRefElem(ctx, base_t)
    if ref_t >= 0 { inner_t = ref_t }
    var elem_t = 0
    if inner_t >= 0 && inner_t < ctx.types.types.length {
        elem_t = ctx.types.types[inner_t].elem_type
    }
    let name_push = "push"
    let name_pop = "pop"
    let name_reserve = "reserve"
    let name_byte_at = "byteAt"
    if symbolNameEqualsText(source, expr.b, expr.c, name_push) {
        if inner_t < 0 || inner_t >= ctx.types.types.length || count != 1 || !semTypeEquals(&ctx.types, arg_t, elem_t) {
            semaAddError(&mut ctx, "L0003", "push requiere List<T> y un argumento T", expr.start, expr.end)
            return 7
        }
        match ctx.types.types[inner_t].kind {
            SemTypeKind.List => {}
            _ => { semaAddError(&mut ctx, "L0003", "push requiere List<T>", expr.start, expr.end); return 7 }
        }
        if !semaMethodMutable(&mut ctx, base_t, base_path, expr.start, expr.end) { return 7 }
        if base_path >= 0 { flowEvent(&mut ctx.flow, FLOW_MUTATE, base_path, expr.start, expr.end) }
        if base_place >= 0 { lirAt(&mut ctx, LIR_LIST_PUSH, -1, base_place, arg_op, 0) }
        // A separate statement ends the mutable loan of ctx.lir before lirSetVal.
        let unit_value = lirConst(&mut ctx.lir, LIR_CONST_UNIT, 0, 0, 0)
        lirSetVal(&mut ctx, unit_value)
        return 6
    }
    if symbolNameEqualsText(source, expr.b, expr.c, name_pop) {
        if inner_t < 0 || inner_t >= ctx.types.types.length || count != 0 {
            semaAddError(&mut ctx, "L0003", "pop requiere List<T> sin argumentos", expr.start, expr.end)
            return 7
        }
        match ctx.types.types[inner_t].kind {
            SemTypeKind.List => {}
            _ => { semaAddError(&mut ctx, "L0003", "pop requiere List<T>", expr.start, expr.end); return 7 }
        }
        if !semaMethodMutable(&mut ctx, base_t, base_path, expr.start, expr.end) { return 7 }
        let opt_t = semTypeMakeOption(&mut ctx.types, elem_t)
        hold enum_id = lirBuiltinRegister(edit ctx.lir_module, view ctx.types, opt_t)
        when enum_id < 0 {
            lirMarkUnsupported(edit ctx.lir, expr.start)
        }
        let dst = lirVar(&mut ctx.lir, opt_t, false)
        if base_path >= 0 { flowEvent(&mut ctx.flow, FLOW_MUTATE, base_path, expr.start, expr.end) }
        if base_place >= 0 { lirAt(&mut ctx, LIR_LIST_POP, dst, base_place, 0, 0) }
        lirSetVal(&mut ctx, dst)
        return opt_t
    }
    if symbolNameEqualsText(source, expr.b, expr.c, name_reserve) {
        if inner_t < 0 || inner_t >= ctx.types.types.length || count != 1 || arg_t != 1 {
            semaAddError(&mut ctx, "L0003", "reserve requiere List<T> y un argumento Int", expr.start, expr.end)
            return 7
        }
        match ctx.types.types[inner_t].kind {
            SemTypeKind.List => {}
            _ => { semaAddError(&mut ctx, "L0003", "reserve requiere List<T>", expr.start, expr.end); return 7 }
        }
        if !semaMethodMutable(&mut ctx, base_t, base_path, expr.start, expr.end) { return 7 }
        if base_path >= 0 { flowEvent(&mut ctx.flow, FLOW_MUTATE, base_path, expr.start, expr.end) }
        if base_place >= 0 { lirAt(&mut ctx, LIR_LIST_RESERVE, -1, base_place, arg_op, 0) }
        // A separate statement ends the mutable loan of ctx.lir before lirSetVal.
        let unit_value = lirConst(&mut ctx.lir, LIR_CONST_UNIT, 0, 0, 0)
        lirSetVal(&mut ctx, unit_value)
        return 6
    }
    if symbolNameEqualsText(source, expr.b, expr.c, name_byte_at) {
        if inner_t != 5 || count != 1 || arg_t != 1 {
            semaAddError(&mut ctx, "L0003", "byteAt requiere Text y un argumento Int", expr.start, expr.end)
            return 7
        }
        if base_path >= 0 { flowEvent(&mut ctx.flow, FLOW_READ, base_path, expr.start, expr.end) }
        let dst = lirVar(&mut ctx.lir, 1, false)
        if base_place >= 0 { lirAt(&mut ctx, LIR_BYTE_AT, dst, base_place, arg_op, 0) }
        lirSetVal(&mut ctx, dst)
        return 1
    }
    semaAddError(&mut ctx, "L0001", "método no encontrado", expr.b, expr.c)
    return 7
}

pub fn semaIndexFinish(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, mode: Int, base_t: Int, bp: Int, parent_path: Int, idx_t: Int, idx_op: Int) -> Int {
    let expr = &tree.expressions[expr_id]
    if idx_t != 1 {
        semaAddError(&mut ctx, "L0003", "el índice debe ser Int", expr.start, expr.end)
        return 7
    }
    var base_place = bp
    if base_place < 0 {
        let holder = lirValueVar(&mut ctx, base_t)
        if holder >= 0 { base_place = lirPlaceVar(&mut ctx.lir, holder) }
    }
    var idx_var = idx_op
    if !lirIsVar(idx_op) {
        let v = lirVar(&mut ctx.lir, 1, false)
        lirAt(&mut ctx, LIR_USE, v, idx_op, 0, 0)
        idx_var = v
    }
    var elem_t = 0
    var unwrapped = base_t
    let referent = semaRefElem(ctx, base_t)
    if referent >= 0 { unwrapped = referent }
    if unwrapped >= 0 && unwrapped < ctx.types.types.length {
        let bt = &ctx.types.types[unwrapped]
        match bt.kind {
            SemTypeKind.List => { elem_t = bt.elem_type }
            SemTypeKind.Array => { elem_t = bt.elem_type }
            SemTypeKind.Slice => { elem_t = bt.elem_type }
            _ => {
                semaAddError(&mut ctx, "L0003", "el tipo no admite indexación", expr.start, expr.end)
                return 7
            }
        }
    }
    if elem_t > 0 && elem_t < ctx.types.types.length {
        let element = &ctx.types.types[elem_t]
        if mode == ACCESS_MOVE && semTypeIsMove(element.kind) {
            semaAddError(&mut ctx, "L0005", "no se puede mover un elemento fuera de una colección", expr.start, expr.end)
            return 7
        }
    }
    if parent_path >= 0 {
        ctx.expression_path = parent_path
        semaAccess(&mut ctx, parent_path, elem_t, mode, expr.start, expr.end)
    }
    if base_place >= 0 {
        let indexed_place = lirPlaceIndex(&mut ctx.lir, base_place, idx_var)
        lirSetPlace(&mut ctx, indexed_place)
        if mode != ACCESS_PLACE && elem_t >= 0 && elem_t < ctx.types.types.length {
            let element = &ctx.types.types[elem_t]
            if semTypeIsCopy(element.kind) {
                let val_var = lirVar(&mut ctx.lir, elem_t, false)
                lirAt(&mut ctx, LIR_READ, val_var, indexed_place, 0, 0)
                lirSetVal(&mut ctx, val_var)
            }
        }
    }
    return elem_t
}

