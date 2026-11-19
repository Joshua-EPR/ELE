import sema_types
import lir_build

pub const LIR_TY_ERR = -1

pub struct LirCheck {
    status: Int
    block: Int
    inst: Int
}

pub struct LirVerifier {
    defined: List of[Bool]
    table: List of[Bool]
    seen: List of[Bool]
    pending: List of[Bool]
    queue: List of[Int]
    status: Int
    // Owned-union ownership (#5): may-moved bit per variable (OR join) and
    // its per-block entry table. A moved variable may not be used, read,
    // borrowed or dropped without a flag until it is assigned again.
    moved: List of[Bool]
    mtable: List of[Bool]
    // Drop flags (#F1): abstract values (0: Off, 1: On, 2: Unknown) and
    // ownership states (0: Uninit, 1: Init, 2: Maybe) of guarded places.
    // `owned`/`otable` are indexed by the flag variable: each flag guards
    // one place (`flag_place`, -1 for the whole variable `flag_root`), and
    // two fields of one struct may own different values at the same point.
    flags: List of[Int]
    ftable: List of[Int]
    owned: List of[Int]
    otable: List of[Int]
    flag_root: List of[Int]
    flag_place: List of[Int]
    has_flags: Bool
    // Owned leaves (`lir_verify_own.l`): variable and field path of each
    // leaf, its may-own / may-be-gone bits and their per-block entry tables.
    leaf_var: List of[Int]
    leaf_first: List of[Int]
    leaf_len: List of[Int]
    leaf_path: List of[Int]
    lown: List of[Bool]
    lgone: List of[Bool]
    lotable: List of[Bool]
    lgtable: List of[Bool]
    // Loan origins: reference `org_ref` borrows place `org_place` (-1: the
    // whole variable) of the by-value variable `org_root`.
    org_ref: List of[Int]
    org_root: List of[Int]
    org_place: List of[Int]
    // Per variable: a reference that may borrow a list element after that
    // list was mutated (push, pop, reserve, element store, edit loan to a
    // call), with its per-block entry table (OR join).
    stale: List of[Bool]
    stable: List of[Bool]
    // A leak was seen while checking (rule 10, reported last).
    leaked: Bool
}

// Field/index path of a place from its root, outermost first. The whole
// variable (a root place, or -1) is the empty path. A malformed chain
// yields a path that no other place shares.
expose flow lirPlacePath(l: view LirFn, place: Int) => List of[Int] {
    change rev: List of[Int] = List[]
    change path: List of[Int] = List[]
    when place < 0 || place >= l.places.length { give path }
    change cursor = place
    change steps = 0
    change bad = false
    during !bad && l.places[cursor].parent >= 0 {
        rev@push(l.places[cursor].field)
        cursor = l.places[cursor].parent
        steps += 1
        when cursor < 0 || cursor >= l.places.length || steps > l.places.length { bad = true }
    }
    when bad {
        path@push(0 - 1000000000)
        give path
    }
    change i = rev.length - 1
    during i >= 0 {
        path@push(rev[i])
        i -= 1
    }
    give path
}

// Is `outer` a prefix of `inner` (the place `outer` contains `inner`)?
expose flow lirPathCovers(outer: view List of[Int], inner: view List of[Int]) => Bool {
    when outer.length > inner.length { give false }
    each i among 0..outer.length {
        when outer[i] != inner[i] { give false }
    }
    give true
}

expose flow lirVarOk(l: view LirFn, slot: Int) => Bool {
    give slot >= 0 && slot < l.vars.length
}

// Type of an operand, or LIR_TY_ERR when the id is invalid.
expose flow lirOperandType(l: view LirFn, operand: Int) => Int {
    when operand == LIR_NONE { give LIR_TY_ERR }
    when lirIsVar(operand) {
        when !lirVarOk(l, operand) || l.vars[operand].is_ref { give LIR_TY_ERR }
        give l.vars[operand].ty
    }
    hold id = lirConstId(operand)
    when id < 0 || id >= l.consts.length { give LIR_TY_ERR }
    hold kind = l.consts[id].kind
    when kind == LIR_CONST_INT { give 1 }
    when kind == LIR_CONST_BOOL { give 4 }
    when kind == LIR_CONST_UNIT { give 6 }
    when kind == LIR_CONST_TEXT { give 5 }
    give LIR_TY_ERR
}

// LIR struct index of a semantic struct type, or -1.
expose flow lirStructOf(types: view TypeTable, lm: view LirModule, ty: Int) => Int {
    when ty < 0 || ty >= types.types.length { give -1 }
    choose types.types[ty].kind {
        SemTypeKind.Struct: {
            hold decl = types.types[ty].nominal_id
            each k among 0..lm.st_decl.length {
                when lm.st_decl[k] == decl { give k }
            }
            give -1
        }
        _: { give -1 }
    }
}

// Type of a place (the referent for a reference root), or LIR_TY_ERR.
// The chain is walked with a step bound so a corrupt cycle terminates.
expose flow lirPlaceType(l: view LirFn, types: view TypeTable, lm: view LirModule, place: Int) => Int {
    when place < 0 || place >= l.places.length { give LIR_TY_ERR }
    change fields: List of[Int] = List[]
    change cursor = place
    change steps = 0
    during l.places[cursor].parent >= 0 {
        fields@push(l.places[cursor].field)
        cursor = l.places[cursor].parent
        steps += 1
        when cursor < 0 || cursor >= l.places.length || steps > l.places.length { give LIR_TY_ERR }
    }
    when !lirVarOk(l, l.places[cursor].root) || l.places[cursor].root != l.places[place].root { give LIR_TY_ERR }
    change ty = l.vars[l.places[cursor].root].ty
    change i = fields.length - 1
    during i >= 0 {
        when fields[i] < 0 {
            when ty < 0 || ty >= types.types.length { give LIR_TY_ERR }
            choose types.types[ty].kind {
                SemTypeKind.List: {}
                _: { give LIR_TY_ERR }
            }
            hold index_var = 0 - 2 - fields[i]
            when !lirVarOk(l, index_var) || l.vars[index_var].ty != 1 || l.vars[index_var].is_ref { give LIR_TY_ERR }
            hold elem = types.types[ty].elem_type
            when elem < 0 || elem >= types.types.length { give LIR_TY_ERR }
            ty = elem
        } else {
            hold k = lirStructOf(types, lm, ty)
            // A malformed LIR module must not access missing or truncated
            // struct tables. Compare using subtraction before adding indexes.
            when k < 0 || k >= lm.st_count.length || k >= lm.st_first.length { give LIR_TY_ERR }
            hold first = lm.st_first[k]
            hold count = lm.st_count[k]
            when first < 0 || first > lm.field_ty.length || count < 0 { give LIR_TY_ERR }
            when count > lm.field_ty.length - first || fields[i] >= count { give LIR_TY_ERR }
            ty = lm.field_ty[first + fields[i]]
            when ty < 0 || ty >= types.types.length { give LIR_TY_ERR }
        }
        i -= 1
    }
    give ty
}

expose flow lirUse(v: edit LirVerifier, l: view LirFn, operand: Int, check: Bool) => Bool {
    when !lirIsVar(operand) {
        // A constant must have a valid ID and one of the known LIR kinds.
        // This also rejects LIR_NONE and malformed constant encodings.
        give lirOperandType(l, operand) != LIR_TY_ERR
    }
    when !lirVarOk(l, operand) { give false }
    when !check { give true }
    // A malformed defined-state table must be rejected, not indexed.
    when operand >= v.defined.length { give false }
    give v.defined[operand] && !(operand < v.moved.length && v.moved[operand])
}

expose flow lirArgType(l: view LirFn, types: view TypeTable, lm: view LirModule, arg: Int) => Int {
    when arg < 0 || arg >= l.args.length { give LIR_TY_ERR }
    when l.args[arg].by_ref { give lirPlaceType(l, types, lm, l.args[arg].value) }
    give lirOperandType(l, l.args[arg].value)
}

expose flow lirPrintable(ty: Int) => Bool {
    give ty == 1 || ty == 2 || ty == 4 || ty == 5
}

expose flow lirArgDefined(v: edit LirVerifier, l: view LirFn, arg: Int, check: Bool) => Bool {
    when arg < 0 || arg >= l.args.length { give false }
    when l.args[arg].by_ref {
        hold place = l.args[arg].value
        when place < 0 || place >= l.places.length { give false }
        hold root = l.places[place].root
        when !lirVarOk(l, root) { give false }
        when !check { give true }
        when root >= v.defined.length { give false }
        give v.defined[root] && !(root < v.moved.length && v.moved[root])
    }
    give lirUse(edit v, l, l.args[arg].value, check)
}

