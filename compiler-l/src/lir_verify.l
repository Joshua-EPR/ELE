import tokens
import sema_types
import lir_build
import lir_finish
import lir_verify_core
import lir_verify_helpers
import lir_builtin_union

// Verifier of one lowered function. It does not trust the lowering: every
// id is range-checked before use, so a corrupt function is rejected instead
// of crashing the compiler. Rules (status):
//   1 variable, constant, place, argument or callee id out of range
//   2 block id out of range or branch without condition
//   3 operand or result type mismatch
//   4 call does not match the callee signature
//   5 variable used before it is definitely assigned
//   6 drop of a value that is not owned, or flag that is not Bool
//   7 return value does not match the function result
//   8 field projection on a non-struct or out of range
//   9 instruction listed in the wrong block
// Owned unions (#5): a by-value use of an Option/Result owning heap storage,
// an owned payload moved into `variant` and an owned `payload` extraction
// (which consumes its union) mark the variable moved (may-analysis). Using,
// borrowing, matching or extracting it afterwards is rule 5 (use after
// move); an unflagged drop of it is rule 6 (double drop).

// Option/Result whose payloads own heap storage.
flow lirOwnedUnion(types: view TypeTable, drop_memo: view List of[Int], ty: Int) => Bool {
    when ty < 0 || ty >= types.types.length || ty >= drop_memo.length || drop_memo[ty] != 2 { give false }
    choose types.types[ty].kind {
        SemTypeKind.Option : { give true }
        SemTypeKind.Result : { give true }
        _ : { give false }
    }
}

// Ownership of the places guarded by drop flags under `root`: every guard
// inside `place` (-1: the whole variable) becomes `state`. With `overlap`,
// a guard that contains `place` is updated too (moving or dropping part
// of a guarded place leaves it owning less than all of it).
flow lirGuardSet(v: edit LirVerifier, l: view LirFn, root: Int, place: Int, state: Int, overlap: Bool) {
    when !v.has_flags { give }
    hold target = lirPlacePath(l, place)
    each f among 0..v.flag_root.length {
        when v.flag_root[f] == root && f < v.owned.length && f < v.flag_place.length {
            hold guard = lirPlacePath(l, v.flag_place[f])
            when lirPathCovers(target, guard) || (overlap && lirPathCovers(guard, target)) {
                v.owned[f] = state
            }
        }
    }
}

// A by-value operand consuming an owned union marks it moved; with `any`,
// every owned operand is marked (an owned payload moved into a union).
flow lirMoveOut(v: edit LirVerifier, l: view LirFn, types: view TypeTable, drop_memo: view List of[Int], operand: Int, any: Bool) {
    when !lirIsVar(operand) || !lirVarOk(l, operand) || l.vars[operand].is_ref || operand >= v.moved.length { give }
    hold ty = l.vars[operand].ty
    when lirOwnedUnion(types, drop_memo, ty) || (any && ty >= 0 && ty < drop_memo.length && drop_memo[ty] == 2) {
        v.moved[operand] = true
    }
    when v.has_flags && ty >= 0 && ty < drop_memo.length && drop_memo[ty] == 2 {
        lirGuardSet(edit v, l, operand, -1, 0, true)
    }
}

// Root of a place definitely assigned and not moved.
flow lirRootLive(v: edit LirVerifier, l: view LirFn, place: Int) => Bool {
    hold root = l.places[place].root
    give v.defined[root] && !(root < v.moved.length && v.moved[root])
}

// Check one instruction and apply its definition. Returns a status.
fn lirVerifyInst(v: &mut LirVerifier, l: &LirFn, types: &TypeTable, lm: &LirModule, drop_memo: &List<Int>, id: Int, block: Int, check: Bool) -> Int {
    if id < 0 || id >= l.insts.length { return 1 }
    let inst = &l.insts[id]
    if inst.block != block { return 9 }
    let kind = inst.kind
    let dst = inst.dst
    if kind == LIR_PRINT || kind == LIR_APPEND {
        if inst.a < 0 || inst.a >= l.args.length { return 1 }
        let ty = lirArgType(l, types, lm, inst.a)
        if ty == LIR_TY_ERR { return 1 }
        if !lirPrintable(ty) { return 3 }
        if !lirArgDefined(&mut v, l, inst.a, check) { return 5 }
        if kind == LIR_APPEND {
            if !lirVarOk(l, dst) || l.vars[dst].ty != 5 || l.vars[dst].is_ref { return 3 }
            if check && !v.defined[dst] { return 5 }
        }
        return 0
    }
    if kind == LIR_STORE {
        let ty = lirPlaceType(l, types, lm, inst.a)
        if ty == LIR_TY_ERR { return 8 }
        if !lirTypesCompat(types, lm, lirOperandType(l, inst.b), ty) { return 3 }
        if !lirUse(&mut v, l, inst.b, check) { return 5 }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
        lirMoveOut(edit v, l, types, drop_memo, inst.b, false)
        // The stored place owns its new value (the drop plan released the
        // old one before the store).
        lirGuardSet(edit v, l, l.places[inst.a].root, inst.a, 1, false)
        return 0
    }
    if kind == LIR_LIST_PUSH || kind == LIR_LIST_RESERVE {
        let ty = lirPlaceType(l, types, lm, inst.a)
        if ty < 0 || ty >= types.types.length { return 8 }
        match types.types[ty].kind {
            SemTypeKind.List => {}
            _ => { return 3 }
        }
        var expected = types.types[ty].elem_type
        if kind == LIR_LIST_RESERVE { expected = 1 }
        if lirOperandType(l, inst.b) != expected { return 3 }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
        if !lirUse(&mut v, l, inst.b, check) { return 5 }
        lirMoveOut(edit v, l, types, drop_memo, inst.b, false)
        return 0
    }
    if kind == LIR_DROP || kind == LIR_DROPFIELD {
        var ty = LIR_TY_ERR
        if kind == LIR_DROP {
            if !lirVarOk(l, dst) || l.vars[dst].is_ref { return 6 }
            ty = l.vars[dst].ty
            if check && !v.defined[dst] { return 5 }
            // An unflagged drop of a (maybe) moved owned union is a double
            // drop; afterwards the union owns nothing.
            when check && inst.a < 0 && dst < v.moved.length && v.moved[dst] { give 6 }
        } else {
            ty = lirPlaceType(l, types, lm, inst.a)
            if ty == LIR_TY_ERR { return 8 }
        }
        if ty < 0 || ty >= drop_memo.length || drop_memo[ty] != 2 { return 6 }
        var flag = inst.a
        change root = dst
        when kind == LIR_DROPFIELD {
            flag = inst.b
            root = l.places[inst.a].root
        }
        if flag >= 0 {
            if !lirVarOk(l, flag) || l.vars[flag].ty != 4 || l.vars[flag].is_ref { return 6 }
            if check && !v.defined[flag] { return 5 }
            when check && v.has_flags {
                when root < 0 || flag >= v.flag_root.length || v.flag_root[flag] != root { give 6 }
                when flag >= v.owned.length || flag >= v.flags.length { give 6 }
                when v.flags[flag] != v.owned[flag] { give 6 }
            }
        }
        when kind == LIR_DROP && dst < v.moved.length && lirOwnedUnion(types, drop_memo, ty) { v.moved[dst] = true }
        when v.has_flags {
            when kind == LIR_DROP {
                lirGuardSet(edit v, l, dst, -1, 0, true)
            } otherwise {
                lirGuardSet(edit v, l, root, inst.a, 0, true)
            }
        }
        return 0
    }
    if !lirVarOk(l, dst) { return 1 }
    let dst_t = l.vars[dst].ty
    let dst_ref = l.vars[dst].is_ref
    var result = LIR_TY_ERR
    var result_ref = false
    if kind == LIR_USE {
        if lirIsVar(inst.a) && lirVarOk(l, inst.a) && l.vars[inst.a].is_ref {
            result = l.vars[inst.a].ty
            result_ref = true
        } else {
            result = lirOperandType(l, inst.a)
        }
        if !lirUse(&mut v, l, inst.a, check) { return 5 }
        lirMoveOut(edit v, l, types, drop_memo, inst.a, false)
    } else if kind == LIR_UNARY {
        let ty = lirOperandType(l, inst.b)
        if (inst.a == LIR_NEG && (ty == 1 || ty == 2)) || (inst.a == LIR_NOT && ty == 4) { result = ty }
        if !lirUse(&mut v, l, inst.b, check) { return 5 }
    } else if kind == LIR_BINARY {
        let lt = lirOperandType(l, inst.b)
        let rt = lirOperandType(l, inst.c)
        if lirTypesCompat(types, lm, lt, rt) && lt != LIR_TY_ERR {
            if inst.a <= LIR_REM && (lt == 1 || lt == 2) { result = lt }
            if inst.a >= LIR_EQ && inst.a <= LIR_GE && (lt == 1 || rt == 1 || lt == 2 || ((lt == 4 || lirIsUnitEnum(types, lm, lt)) && inst.a <= LIR_NE)) { result = 4 }
        }
        if !lirUse(&mut v, l, inst.b, check) || !lirUse(&mut v, l, inst.c, check) { return 5 }
    } else if kind == LIR_CALL {
        let status = lirVerifyCall(&mut v, l, types, lm, inst.a, inst.b, inst.c, check)
        if status != 0 { return status }
        each i among 0..inst.c {
            hold arg = l.operands[inst.b + i]
            when !l.args[arg].by_ref { lirMoveOut(edit v, l, types, drop_memo, l.args[arg].value, false) }
        }
        result = lm.fn_ret[inst.a]
        result_ref = lm.fn_ret_ref[inst.a]
    } else if kind == LIR_STRUCT {
        if inst.a < 0 || inst.a >= lm.st_count.length { return 1 }
        if inst.c != lm.st_count[inst.a] || inst.b < 0 || inst.b + inst.c > l.operands.length { return 3 }
        for i in 0..inst.c {
            let operand = l.operands[inst.b + i]
            if lirOperandType(l, operand) != lm.field_ty[lm.st_first[inst.a] + i] { return 3 }
            if !lirUse(&mut v, l, operand, check) { return 5 }
            lirMoveOut(edit v, l, types, drop_memo, operand, false)
        }
        if lirStructOf(types, lm, dst_t) == inst.a { result = dst_t }
    } else if kind == LIR_VARIANT {
        if inst.a < 0 || inst.a >= lm.en_decl.length || inst.b < 0 || inst.b >= lm.en_count[inst.a] { return 1 }
        let which = lm.en_first[inst.a] + inst.b
        if which < 0 || which >= lm.variant_payload.length { return 3 }
        let count = lm.variant_payload[which]
        if count == 1 {
            let payload_ty = lm.variant_type[which]
            if !lirBuiltinPayloadOk(types, lm, payload_ty) || lirOperandType(l, inst.c) != payload_ty { return 3 }
            if !lirUse(&mut v, l, inst.c, check) { return 5 }
            lirMoveOut(edit v, l, types, drop_memo, inst.c, true)
        } else if count != 0 { return 3 }
        else if inst.c != LIR_NONE { return 3 }
        if dst_t < 0 || dst_t >= types.types.length { return 3 }
        match types.types[dst_t].kind {
            SemTypeKind.Enum => {
                if types.types[dst_t].nominal_id != lm.en_decl[inst.a] { return 3 }
                result = dst_t
            }
            SemTypeKind.Option => {
                if lm.en_builtin[inst.a] != dst_t { return 3 }
                result = dst_t
            }
            SemTypeKind.Result => {
                if lm.en_builtin[inst.a] != dst_t { return 3 }
                result = dst_t
            }
            _ => { return 3 }
        }
    } else if kind == LIR_PAYLOAD {
        let enum_t = lirPlaceType(l, types, lm, inst.a)
        if enum_t < 0 || enum_t >= types.types.length { return 8 }
        if inst.b < 0 || inst.b >= lm.en_decl.length { return 1 }
        if inst.c < 0 || inst.c >= lm.en_count[inst.b] { return 1 }
        let variant = lm.en_first[inst.b] + inst.c
        if variant < 0 || variant >= lm.variant_payload.length || lm.variant_payload[variant] != 1 { return 3 }
        let payload_ty = lm.variant_type[variant]
        if !lirBuiltinPayloadOk(types, lm, payload_ty) { return 3 }
        if inst.a < 0 || inst.a >= l.places.length || l.places[inst.a].parent >= 0 { return 8 }
        let root = l.places[inst.a].root
        if !lirVarOk(l, root) || l.vars[root].is_ref { return 8 }
        match types.types[enum_t].kind {
            SemTypeKind.Enum => {
                if types.types[enum_t].nominal_id != lm.en_decl[inst.b] { return 3 }
            }
            SemTypeKind.Option => {
                if lm.en_builtin[inst.b] != enum_t { return 3 }
            }
            SemTypeKind.Result => {
                if lm.en_builtin[inst.b] != enum_t { return 3 }
            }
            _ => { return 3 }
        }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
        // An owned payload is moved out: the whole union is consumed.
        when lirBuiltinPayloadOwned(types, lm, payload_ty) && root < v.moved.length {
            v.moved[root] = true
            lirGuardSet(edit v, l, root, -1, 0, true)
        }
        result = payload_ty
    } else if kind == LIR_DISC {
        let enum_t = lirPlaceType(l, types, lm, inst.a)
        if enum_t < 0 || enum_t >= types.types.length { return 8 }
        match types.types[enum_t].kind {
            SemTypeKind.Enum => { result = 1 }
            SemTypeKind.Option => {
                if lirBuiltinEnumIndex(lm, enum_t) < 0 { return 3 }
                result = 1
            }
            SemTypeKind.Result => {
                if lirBuiltinEnumIndex(lm, enum_t) < 0 { return 3 }
                result = 1
            }
            _ => { return 3 }
        }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
    } else if kind == LIR_LIST_LIT {
        if inst.a < 0 || inst.a >= lm.list_elem.length || inst.c < 0 || inst.b < 0 || inst.c > l.operands.length || inst.b > l.operands.length - inst.c { return 1 }
        if dst_t < 0 || dst_t >= types.types.length { return 3 }
        match types.types[dst_t].kind {
            SemTypeKind.List => {
                if types.types[dst_t].elem_type != lm.list_elem[inst.a] { return 3 }
            }
            _ => { return 3 }
        }
        for i in 0..inst.c {
            let operand = l.operands[inst.b + i]
            if lirOperandType(l, operand) != lm.list_elem[inst.a] { return 3 }
            if !lirUse(&mut v, l, operand, check) { return 5 }
            lirMoveOut(edit v, l, types, drop_memo, operand, false)
        }
        result = dst_t
    } else if kind == LIR_READ || kind == LIR_LOAN {
        result = lirPlaceType(l, types, lm, inst.a)
        if result == LIR_TY_ERR { return 8 }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
        result_ref = kind == LIR_LOAN
        when kind == LIR_READ && result >= 0 && result < drop_memo.length && drop_memo[result] == 2 {
            // Moving an owned value out of a place releases only the
            // guards inside (or containing) that place.
            lirGuardSet(edit v, l, l.places[inst.a].root, inst.a, 0, true)
        }
    } else if kind == LIR_TEXTBUF {
        result = 5
    } else if kind == LIR_LEN || kind == LIR_CAP {
        let ty = lirPlaceType(l, types, lm, inst.a)
        if ty < 0 || ty >= types.types.length { return 8 }
        match types.types[ty].kind {
            SemTypeKind.List => {}
            SemTypeKind.Text => { if kind == LIR_CAP { return 3 } }
            _ => { return 3 }
        }
        result = 1
        if check && !v.defined[l.places[inst.a].root] { return 5 }
    } else if kind == LIR_BYTE_AT {
        if lirPlaceType(l, types, lm, inst.a) != 5 || lirOperandType(l, inst.b) != 1 { return 3 }
        result = 1
        if check && !v.defined[l.places[inst.a].root] { return 5 }
        if !lirUse(&mut v, l, inst.b, check) { return 5 }
    } else if kind == LIR_LIST_POP {
        hold list_t = lirPlaceType(l, types, lm, inst.a)
        when list_t < 0 || list_t >= types.types.length { give 8 }
        choose types.types[list_t].kind {
            SemTypeKind.List : {}
            _ : { give 3 }
        }
        when dst_t < 0 || dst_t >= types.types.length { give 3 }
        choose types.types[dst_t].kind {
            SemTypeKind.Option : {
                when types.types[dst_t].elem_type != types.types[list_t].elem_type { give 3 }
            }
            _ : { give 3 }
        }
        result = dst_t
        if check && !v.defined[l.places[inst.a].root] { return 5 }
    } else if kind == LIR_PLATFORM {
        let status = lirVerifyPlatform(&mut v, l, types, lm, inst.a, inst.b, inst.c, dst, check)
        if status != 0 { return status }
        result = dst_t
    } else {
        return 1
    }
    if result == LIR_TY_ERR || !lirTypesCompat(types, lm, result, dst_t) || result_ref != dst_ref { return 3 }
    v.defined[dst] = true
    when dst < v.moved.length { v.moved[dst] = false }
    when v.has_flags {
        when dst < v.flag_root.length && v.flag_root[dst] >= 0 {
            when kind == LIR_USE && !lirIsVar(inst.a) {
                hold cid = lirConstId(inst.a)
                when cid >= 0 && cid < l.consts.length && l.consts[cid].kind == LIR_CONST_BOOL {
                    when l.consts[cid].value != 0 {
                        v.flags[dst] = 1
                    } otherwise {
                        v.flags[dst] = 0
                    }
                } otherwise {
                    v.flags[dst] = 2
                }
            } otherwise {
                v.flags[dst] = 2
            }
        } otherwise when !dst_ref {
            lirGuardSet(edit v, l, dst, -1, 1, false)
        }
    }
    return 0
}

fn lirVerifyBlock(v: &mut LirVerifier, l: &LirFn, body: &LirBody, types: &TypeTable, lm: &LirModule, drop_memo: &List<Int>, fn_index: Int, b: Int, check: Bool) -> Int {
    let blocks = body.term.length
    let first = body.first[b]
    if first < 0 || body.count[b] < 0 || first + body.count[b] > body.order.length { return 1 }
    for i in first..(first + body.count[b]) {
        let status = lirVerifyInst(&mut v, l, types, lm, drop_memo, body.order[i], b, check)
        if status != 0 { return status }
    }
    when check && v.has_flags {
        hold term = body.term[b]
        when term == LIR_T_JUMP || term == LIR_T_BRANCH {
            each f among 0..v.flag_root.length {
                hold root = v.flag_root[f]
                when root >= 0 {
                    when f >= v.owned.length || f >= v.flags.length { give 6 }
                    when v.flags[f] != v.owned[f] { give 6 }
                }
            }
        }
    }
    return lirVerifyTerm(&mut v, l, body, types, lm, fn_index, b, blocks, check)
}

pub fn lirVerify(l: &LirFn, body: &LirBody, types: &TypeTable, lm: &LirModule, drop_memo: &List<Int>, fn_index: Int) -> LirCheck {
    let blocks = body.term.length
    let vars = l.vars.length
    if fn_index < 0 || fn_index >= lm.fn_first.length || blocks == 0 { return LirCheck(status: 1, block: -1, inst: -1) }
    if body.first.length != blocks || body.count.length != blocks || body.ta.length != blocks || body.tb.length != blocks || body.top.length != blocks {
        return LirCheck(status: 2, block: -1, inst: -1)
    }
    change v = LirVerifier(
        defined: List[],
        table: List[],
        seen: List[],
        pending: List[],
        queue: List[],
        status: 0,
        moved: List[],
        mtable: List[],
        flags: List[],
        ftable: List[],
        owned: List[],
        otable: List[],
        flag_root: List[],
        flag_place: List[],
        has_flags: false,
    )
    each i among 0..vars {
        v.defined@push(false)
        v.moved@push(false)
        v.flags@push(0)
        v.owned@push(0)
        v.flag_root@push(-1)
        v.flag_place@push(-1)
    }
    each id among 0..l.insts.length {
        hold kind = l.insts[id].kind
        when kind == LIR_DROP || kind == LIR_DROPFIELD {
            change f = l.insts[id].a
            change root = l.insts[id].dst
            change guarded = -1
            when kind == LIR_DROPFIELD {
                f = l.insts[id].b
                hold place = l.insts[id].a
                when f >= 0 {
                    when place < 0 || place >= l.places.length {
                        give LirCheck(status: 1, block: l.insts[id].block, inst: id)
                    }
                    root = l.places[place].root
                    guarded = place
                }
            }
            // One flag guards one place: every drop it guards names it.
            when f >= 0 && lirVarOk(l, f) && v.flag_root[f] >= 0 {
                hold known = lirPlacePath(l, v.flag_place[f])
                hold named = lirPlacePath(l, guarded)
                when !lirPathCovers(known, named) || !lirPathCovers(named, known) {
                    give LirCheck(status: 6, block: l.insts[id].block, inst: id)
                }
            }
            when f >= 0 {
                when !lirVarOk(l, f) || l.vars[f].ty != 4 || l.vars[f].is_ref {
                    give LirCheck(status: 6, block: l.insts[id].block, inst: id)
                }
                when !lirVarOk(l, root) {
                    give LirCheck(status: 1, block: l.insts[id].block, inst: id)
                }
                when v.flag_root[f] >= 0 && v.flag_root[f] != root {
                    give LirCheck(status: 6, block: l.insts[id].block, inst: id)
                }
                v.flag_root[f] = root
                v.flag_place[f] = guarded
                v.has_flags = true
            }
        }
    }
    each i among 0..(blocks * vars) {
        v.table@push(true)
        v.mtable@push(false)
        v.ftable@push(0)
        v.otable@push(0)
    }
    for b in 0..blocks {
        v.seen.push(b == 0)
        v.pending.push(b == 0)
    }
    // Parameters are assigned on entry.
    each i among 0..vars {
        v.table[i] = i < l.params
        // A guard of a parameter starts owning its place.
        when v.flag_root[i] >= 0 && v.flag_root[i] < l.params { v.otable[i] = 1 }
    }
    v.queue.push(0)
    var steps = 0
    while v.queue.length > 0 {
        var b = 0
        match v.queue.pop() {
            Some(x) => { b = x }
            None => { break }
        }
        v.pending[b] = false
        steps += 1
        if steps > 100000 { return LirCheck(status: 2, block: b, inst: -1) }
        each i among 0..vars {
            v.defined[i] = v.table[b * vars + i]
            v.moved[i] = v.mtable[b * vars + i]
            when v.has_flags {
                v.flags[i] = v.ftable[b * vars + i]
                v.owned[i] = v.otable[b * vars + i]
            }
        }
        let status = lirVerifyBlock(&mut v, l, body, types, lm, drop_memo, fn_index, b, false)
        if status != 0 { return LirCheck(status: status, block: b, inst: -1) }
        let kind = body.term[b]
        if kind == LIR_T_JUMP || kind == LIR_T_BRANCH {
            lirVerifyFlow(&mut v, body.ta[b], vars)
        }
        if kind == LIR_T_BRANCH { lirVerifyFlow(&mut v, body.tb[b], vars) }
    }
    for b in 0..blocks {
        if v.seen[b] {
            each i among 0..vars {
                v.defined[i] = v.table[b * vars + i]
                v.moved[i] = v.mtable[b * vars + i]
                when v.has_flags {
                    v.flags[i] = v.ftable[b * vars + i]
                    v.owned[i] = v.otable[b * vars + i]
                }
            }
            let status = lirVerifyBlock(&mut v, l, body, types, lm, drop_memo, fn_index, b, true)
            if status != 0 { return LirCheck(status: status, block: b, inst: -1) }
        }
    }
    return LirCheck(status: 0, block: -1, inst: steps)
}

