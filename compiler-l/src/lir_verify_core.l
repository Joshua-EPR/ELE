import sema_types
import lir_build

pub const LIR_TY_ERR = -1

pub struct LirCheck {
    status: Int
    block: Int
    inst: Int
}

pub struct LirVerifier {
    defined: List<Bool>
    table: List<Bool>
    seen: List<Bool>
    pending: List<Bool>
    queue: List<Int>
    status: Int
    // Owned-union ownership (#5): may-moved bit per variable (OR join) and
    // its per-block entry table. A moved variable may not be used, read,
    // borrowed or dropped without a flag until it is assigned again.
    moved: List of[Bool]
    mtable: List of[Bool]
    // Drop flags (#F1): abstract values (0: Off, 1: On, 2: Unknown) and
    // ownership states (0: Uninit, 1: Init, 2: Maybe) of guarded places.
    flags: List of[Int]
    ftable: List of[Int]
    owned: List of[Int]
    otable: List of[Int]
    flag_root: List of[Int]
    has_flags: Bool
}

expose flow lirVarOk(l: view LirFn, slot: Int) => Bool {
    return slot >= 0 && slot < l.vars.length
}

// Type of an operand, or LIR_TY_ERR when the id is invalid.
expose flow lirOperandType(l: view LirFn, operand: Int) => Int {
    if operand == LIR_NONE { return LIR_TY_ERR }
    if lirIsVar(operand) {
        if !lirVarOk(l, operand) || l.vars[operand].is_ref { return LIR_TY_ERR }
        return l.vars[operand].ty
    }
    let id = lirConstId(operand)
    if id < 0 || id >= l.consts.length { return LIR_TY_ERR }
    let kind = l.consts[id].kind
    if kind == LIR_CONST_INT { return 1 }
    if kind == LIR_CONST_BOOL { return 4 }
    if kind == LIR_CONST_UNIT { return 6 }
    if kind == LIR_CONST_TEXT { return 5 }
    return LIR_TY_ERR
}

// LIR struct index of a semantic struct type, or -1.
expose flow lirStructOf(types: view TypeTable, lm: view LirModule, ty: Int) => Int {
    if ty < 0 || ty >= types.types.length { return -1 }
    match types.types[ty].kind {
        SemTypeKind.Struct => {
            let decl = types.types[ty].nominal_id
            for k in 0..lm.st_decl.length {
                if lm.st_decl[k] == decl { return k }
            }
            return -1
        }
        _ => { return -1 }
    }
}

// Type of a place (the referent for a reference root), or LIR_TY_ERR.
// The chain is walked with a step bound so a corrupt cycle terminates.
expose flow lirPlaceType(l: view LirFn, types: view TypeTable, lm: view LirModule, place: Int) => Int {
    if place < 0 || place >= l.places.length { return LIR_TY_ERR }
    var fields: List<Int> = List[]
    var cursor = place
    var steps = 0
    while l.places[cursor].parent >= 0 {
        fields.push(l.places[cursor].field)
        cursor = l.places[cursor].parent
        steps += 1
        if cursor < 0 || cursor >= l.places.length || steps > l.places.length { return LIR_TY_ERR }
    }
    if !lirVarOk(l, l.places[cursor].root) || l.places[cursor].root != l.places[place].root { return LIR_TY_ERR }
    var ty = l.vars[l.places[cursor].root].ty
    var i = fields.length - 1
    while i >= 0 {
        if fields[i] < 0 {
            if ty < 0 || ty >= types.types.length { return LIR_TY_ERR }
            match types.types[ty].kind {
                SemTypeKind.List => {}
                _ => { return LIR_TY_ERR }
            }
            let index_var = 0 - 2 - fields[i]
            if !lirVarOk(l, index_var) || l.vars[index_var].ty != 1 || l.vars[index_var].is_ref { return LIR_TY_ERR }
            let elem = types.types[ty].elem_type
            if elem < 0 || elem >= types.types.length { return LIR_TY_ERR }
            ty = elem
        } else {
            let k = lirStructOf(types, lm, ty)
            // A malformed LIR module must not access missing or truncated
            // struct tables. Compare using subtraction before adding indexes.
            if k < 0 || k >= lm.st_count.length || k >= lm.st_first.length { return LIR_TY_ERR }
            let first = lm.st_first[k]
            let count = lm.st_count[k]
            if first < 0 || first > lm.field_ty.length || count < 0 { return LIR_TY_ERR }
            if count > lm.field_ty.length - first || fields[i] >= count { return LIR_TY_ERR }
            ty = lm.field_ty[first + fields[i]]
            if ty < 0 || ty >= types.types.length { return LIR_TY_ERR }
        }
        i -= 1
    }
    return ty
}

expose flow lirUse(v: edit LirVerifier, l: view LirFn, operand: Int, check: Bool) => Bool {
    if !lirIsVar(operand) {
        // A constant must have a valid ID and one of the known LIR kinds.
        // This also rejects LIR_NONE and malformed constant encodings.
        return lirOperandType(l, operand) != LIR_TY_ERR
    }
    if !lirVarOk(l, operand) { return false }
    if !check { return true }
    // A malformed defined-state table must be rejected, not indexed.
    if operand >= v.defined.length { return false }
    give v.defined[operand] && !(operand < v.moved.length && v.moved[operand])
}

expose flow lirArgType(l: view LirFn, types: view TypeTable, lm: view LirModule, arg: Int) => Int {
    if arg < 0 || arg >= l.args.length { return LIR_TY_ERR }
    if l.args[arg].by_ref { return lirPlaceType(l, types, lm, l.args[arg].value) }
    return lirOperandType(l, l.args[arg].value)
}

expose flow lirPrintable(ty: Int) => Bool {
    return ty == 1 || ty == 2 || ty == 4 || ty == 5
}

expose flow lirArgDefined(v: edit LirVerifier, l: view LirFn, arg: Int, check: Bool) => Bool {
    if arg < 0 || arg >= l.args.length { return false }
    if l.args[arg].by_ref {
        let place = l.args[arg].value
        if place < 0 || place >= l.places.length { return false }
        let root = l.places[place].root
        if !lirVarOk(l, root) { return false }
        if !check { return true }
        if root >= v.defined.length { return false }
        give v.defined[root] && !(root < v.moved.length && v.moved[root])
    }
    return lirUse(&mut v, l, l.args[arg].value, check)
}

