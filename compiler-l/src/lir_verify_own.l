take sema_types
take lir_build
take lir_finish
take lir_verify_core

// Ownership of every owned leaf and liveness of every loan, for the
// verifier of one lowered function (`lir_verify.l`). Mirrors the Stage 0
// verifier of protocol LIR (`crates/l/src/drops.rs`, `lir_protocol.rs`):
//
// * A leaf is an owned value a variable holds: the variable itself, or each
//   field (recursively) that owns heap storage when it is a struct. A list
//   element stands for its list. Each leaf has two may-bits per point,
//   `own` (may own a value) and `gone` (may be moved, dropped or never
//   assigned), joined by OR: Init (own, not gone), Uninit (gone, not own)
//   or Maybe (both).
// * Using, borrowing or moving a value needs its leaves Init (rule 5); an
//   unflagged drop needs them Init (rule 6, double free); a flagged drop
//   needs the flag to agree with them (rule 6); defining or storing over a
//   value that may still own one, and returning while a leaf may own one,
//   leak it (rule 10, reported only when no other rule is violated).
// * A reference variable borrows its origins: the value-rooted places it
//   was loaned from (directly, through another reference or through a
//   call that returns a reference). Using it needs every origin Init: a
//   reference never outlives the value it points to (rule 5). A reference
//   to a list element is stale after any mutation of that list (its buffer
//   may move, the element may be dropped) until it is assigned again
//   (rule 5). A borrowed return may only borrow from reference parameters
//   (rule 7).

// Owned leaves of variable `root` of type `ty`, in field order (a worklist
// of pending types and their paths, stored flat in `paths`).
flow lirLeafExpand(v: edit LirVerifier, types: view TypeTable, lm: view LirModule, drop_memo: view List of[Int], root: Int, ty: Int) {
    change wl_ty: List of[Int] = List[]
    change wl_first: List of[Int] = List[]
    change wl_len: List of[Int] = List[]
    change paths: List of[Int] = List[]
    wl_ty@push(ty)
    wl_first@push(0)
    wl_len@push(0)
    change steps = 0
    during wl_ty.length > 0 && steps < 4096 {
        steps += 1
        hold top = wl_ty.length - 1
        hold t = wl_ty[top]
        hold first_at = wl_first[top]
        hold len = wl_len[top]
        change item: List of[Int] = List[]
        each j among 0..len { item@push(paths[first_at + j]) }
        // Pop the item.
        change keep_ty: List of[Int] = List[]
        change keep_first: List of[Int] = List[]
        change keep_len: List of[Int] = List[]
        each j among 0..top {
            keep_ty@push(wl_ty[j])
            keep_first@push(wl_first[j])
            keep_len@push(wl_len[j])
        }
        wl_ty = keep_ty
        wl_first = keep_first
        wl_len = keep_len
        when t >= 0 && t < drop_memo.length && drop_memo[t] == 2 && len <= 16 {
            hold k = lirStructOf(types, lm, t)
            when k < 0 {
                v.leaf_var@push(root)
                v.leaf_first@push(v.leaf_path.length)
                v.leaf_len@push(len)
                each j among 0..len { v.leaf_path@push(item[j]) }
            } otherwise when k < lm.st_first.length && k < lm.st_count.length {
                hold first = lm.st_first[k]
                // Pushed last field first, so fields pop in order.
                change i = lm.st_count[k] - 1
                during i >= 0 {
                    when first >= 0 && first + i < lm.field_ty.length {
                        wl_ty@push(lm.field_ty[first + i])
                        wl_first@push(paths.length)
                        wl_len@push(len + 1)
                        each j among 0..len { paths@push(item[j]) }
                        paths@push(i)
                    }
                    i -= 1
                }
            }
        }
    }
}

// Leaves of every by-value variable, and their entry states: parameters
// own their values, every other variable starts unassigned.
expose flow lirLeafSetup(v: edit LirVerifier, l: view LirFn, types: view TypeTable, lm: view LirModule, drop_memo: view List of[Int], blocks: Int) {
    each slot among 0..l.vars.length {
        when !l.vars[slot].is_ref {
            lirLeafExpand(edit v, types, lm, drop_memo, slot, l.vars[slot].ty)
        }
    }
    hold leaves = v.leaf_var.length
    each k among 0..leaves {
        v.lown@push(false)
        v.lgone@push(true)
    }
    each i among 0..(blocks * leaves) {
        v.lotable@push(false)
        v.lgtable@push(true)
    }
    each k among 0..leaves {
        when v.leaf_var[k] < l.params {
            v.lotable[k] = true
            v.lgtable[k] = false
        }
    }
    each i among 0..l.vars.length { v.stale@push(false) }
    each i among 0..(blocks * l.vars.length) { v.stable@push(false) }
}

expose flow lirLeafLoad(v: edit LirVerifier, b: Int) {
    hold n = v.lown.length
    each k among 0..n {
        v.lown[k] = v.lotable[b * n + k]
        v.lgone[k] = v.lgtable[b * n + k]
    }
    hold vars = v.stale.length
    each k among 0..vars { v.stale[k] = v.stable[b * vars + k] }
}

// Join the current leaf states into the entry of `target` (may-bits: OR).
// Returns whether the entry changed.
expose flow lirLeafJoin(v: edit LirVerifier, target: Int, first: Bool) => Bool {
    hold n = v.lown.length
    change changed = false
    each k among 0..n {
        hold cell = target * n + k
        when cell < v.lotable.length && cell < v.lgtable.length {
            when first {
                v.lotable[cell] = v.lown[k]
                v.lgtable[cell] = v.lgone[k]
            } otherwise {
                when v.lown[k] && !v.lotable[cell] {
                    v.lotable[cell] = true
                    changed = true
                }
                when v.lgone[k] && !v.lgtable[cell] {
                    v.lgtable[cell] = true
                    changed = true
                }
            }
        }
    }
    hold vars = v.stale.length
    each k among 0..vars {
        hold cell = target * vars + k
        when cell < v.stable.length {
            when first {
                v.stable[cell] = v.stale[k]
            } otherwise when v.stale[k] && !v.stable[cell] {
                v.stable[cell] = true
                changed = true
            }
        }
    }
    give changed
}

// A path cut before its first list index (the list it goes through).
flow lirPathCut(path: view List of[Int]) => List of[Int] {
    change out: List of[Int] = List[]
    change done = false
    each i among 0..path.length {
        when path[i] < 0 { done = true }
        when !done { out@push(path[i]) }
    }
    give out
}

// Mutating list place `place` of variable `root` (push, pop, reserve,
// element store, edit loan) may move its buffer or drop an element: every
// reference borrowing an element of it, or of a list inside it, is stale.
flow lirLoanMutate(v: edit LirVerifier, l: view LirFn, root: Int, place: Int) {
    hold full = lirPlacePath(l, place)
    hold target = lirPathCut(view full)
    each k among 0..v.org_ref.length {
        when v.org_root[k] == root {
            hold origin = lirPlacePath(l, v.org_place[k])
            hold list = lirPathCut(view origin)
            when list.length < origin.length && (lirPathCovers(view list, view target) || lirPathCovers(view target, view list)) {
                hold slot = v.org_ref[k]
                when slot >= 0 && slot < v.stale.length { v.stale[slot] = true }
            }
        }
    }
}

// The same through a reference: its origins are what is mutated.
flow lirLoanMutatePlace(v: edit LirVerifier, l: view LirFn, place: Int) {
    when place < 0 || place >= l.places.length { give }
    hold root = l.places[place].root
    when !lirVarOk(l, root) { give }
    when !l.vars[root].is_ref {
        lirLoanMutate(edit v, l, root, place)
        give
    }
    hold n = v.org_ref.length
    each k among 0..n {
        hold origin_root = v.org_root[k]
        hold origin_place = v.org_place[k]
        when v.org_ref[k] == root { lirLoanMutate(edit v, l, origin_root, origin_place) }
    }
}

// Does `place` project through a list index?
flow lirPlaceIndexed(l: view LirFn, place: Int) => Bool {
    hold path = lirPlacePath(l, place)
    each i among 0..path.length {
        when path[i] < 0 { give true }
    }
    give false
}

// Leaves of `root` inside `place` (-1: the whole variable). A path through
// a list index stands for the list; a malformed path matches nothing.
flow lirLeafHits(v: edit LirVerifier, l: view LirFn, root: Int, place: Int) => List of[Int] {
    change hits: List of[Int] = List[]
    hold full = lirPlacePath(l, place)
    change n = full.length
    change i = full.length - 1
    change bad = false
    during i >= 0 {
        when full[i] == 0 - 1000000000 { bad = true }
        when full[i] < 0 { n = i }
        i -= 1
    }
    when bad { give hits }
    each k among 0..v.leaf_var.length {
        when v.leaf_var[k] == root && v.leaf_len[k] >= n {
            change same = true
            hold base = v.leaf_first[k]
            each j among 0..n {
                when v.leaf_path[base + j] != full[j] { same = false }
            }
            when same { hits@push(k) }
        }
    }
    give hits
}

// Every leaf inside the place owns its value on every path (Init).
flow lirLeafInit(v: edit LirVerifier, l: view LirFn, root: Int, place: Int) => Bool {
    hold hits = lirLeafHits(edit v, l, root, place)
    each i among 0..hits.length {
        when !v.lown[hits[i]] || v.lgone[hits[i]] { give false }
    }
    give true
}

// No leaf inside the place may own a value (Uninit).
flow lirLeafEmpty(v: edit LirVerifier, l: view LirFn, root: Int, place: Int) => Bool {
    hold hits = lirLeafHits(edit v, l, root, place)
    each i among 0..hits.length {
        when v.lown[hits[i]] { give false }
    }
    give true
}

flow lirLeafPut(v: edit LirVerifier, l: view LirFn, root: Int, place: Int, owned: Bool) {
    hold hits = lirLeafHits(edit v, l, root, place)
    each i among 0..hits.length {
        v.lown[hits[i]] = owned
        v.lgone[hits[i]] = !owned
    }
}

// Flag value (0 Off, 1 On, 2 Unknown, 3 forged) agrees with the leaves of
// the guarded place: On exactly when Init, Off when Uninit, Unknown only
// when Maybe (a join of agreeing paths). A forged value agrees with none.
expose flow lirLeafAgrees(v: edit LirVerifier, l: view LirFn, root: Int, place: Int, flag: Int) => Bool {
    hold hits = lirLeafHits(edit v, l, root, place)
    each i among 0..hits.length {
        hold own = v.lown[hits[i]]
        hold gone = v.lgone[hits[i]]
        when flag == 1 && !(own && !gone) { give false }
        when flag == 0 && !(!own && gone) { give false }
        when flag == 2 && !(own && gone) { give false }
        when flag != 0 && flag != 1 && flag != 2 { give false }
    }
    give true
}

flow lirOwnOperand(v: edit LirVerifier, l: view LirFn, operand: Int, consume: Bool, check: Bool) => Bool {
    when !lirIsVar(operand) || !lirVarOk(l, operand) || l.vars[operand].is_ref { give true }
    when check && !lirLeafInit(edit v, l, operand, -1) { give false }
    when consume { lirLeafPut(edit v, l, operand, -1, false) }
    give true
}

flow lirOwnPlace(v: edit LirVerifier, l: view LirFn, place: Int, consume: Bool, check: Bool) => Bool {
    when place < 0 || place >= l.places.length { give true }
    hold root = l.places[place].root
    when !lirVarOk(l, root) || l.vars[root].is_ref { give true }
    when check && !lirLeafInit(edit v, l, root, place) { give false }
    when consume { lirLeafPut(edit v, l, root, place, false) }
    give true
}

flow lirOwnArg(v: edit LirVerifier, l: view LirFn, arg: Int, consume: Bool, check: Bool) => Bool {
    when arg < 0 || arg >= l.args.length { give true }
    when l.args[arg].by_ref { give lirOwnPlace(edit v, l, l.args[arg].value, false, check) }
    give lirOwnOperand(edit v, l, l.args[arg].value, consume, check)
}

// A definition (or store) of a place that may still own a value leaks it.
// A leak is recorded (`leaked`) and reported only when the function has no
// memory-safety violation, which is the more useful diagnostic.
flow lirOwnDef(v: edit LirVerifier, l: view LirFn, root: Int, place: Int, check: Bool) {
    when !lirVarOk(l, root) || l.vars[root].is_ref { give }
    when check && !lirLeafEmpty(edit v, l, root, place) { v.leaked = true }
    lirLeafPut(edit v, l, root, place, true)
}

flow lirLoanAdd(v: edit LirVerifier, dst: Int, root: Int, place: Int) => Bool {
    each k among 0..v.org_ref.length {
        when v.org_ref[k] == dst && v.org_root[k] == root && v.org_place[k] == place { give false }
    }
    v.org_ref@push(dst)
    v.org_root@push(root)
    v.org_place@push(place)
    give true
}

flow lirLoanCopy(v: edit LirVerifier, dst: Int, src: Int) => Bool {
    change changed = false
    hold n = v.org_ref.length
    each k among 0..n {
        hold origin_root = v.org_root[k]
        hold origin_place = v.org_place[k]
        when v.org_ref[k] == src && lirLoanAdd(edit v, dst, origin_root, origin_place) { changed = true }
    }
    give changed
}

// `dst` borrows `place`: a value-rooted place is an origin, a place below a
// reference inherits that reference's origins.
flow lirLoanFrom(v: edit LirVerifier, l: view LirFn, dst: Int, place: Int) => Bool {
    when place < 0 || place >= l.places.length { give false }
    hold root = l.places[place].root
    when !lirVarOk(l, root) { give false }
    when l.vars[root].is_ref { give lirLoanCopy(edit v, dst, root) }
    give lirLoanAdd(edit v, dst, root, place)
}

// Origins of every reference variable (flow-insensitive: every definition
// of a reference adds its origins), computed to a fixpoint.
expose flow lirLoanSetup(v: edit LirVerifier, l: view LirFn) {
    change grew = true
    change rounds = 0
    during grew && rounds <= l.vars.length + 1 {
        grew = false
        rounds += 1
        each id among 0..l.insts.length {
            hold kind = l.insts[id].kind
            hold dst = l.insts[id].dst
            when lirVarOk(l, dst) && l.vars[dst].is_ref {
                when kind == LIR_LOAN {
                    when lirLoanFrom(edit v, l, dst, l.insts[id].a) { grew = true }
                } otherwise when kind == LIR_USE {
                    hold src = l.insts[id].a
                    when lirIsVar(src) && lirVarOk(l, src) && l.vars[src].is_ref && lirLoanCopy(edit v, dst, src) { grew = true }
                } otherwise when kind == LIR_CALL {
                    hold first = l.insts[id].b
                    each i among 0..l.insts[id].c {
                        when first >= 0 && first + i < l.operands.length {
                            hold arg = l.operands[first + i]
                            when arg >= 0 && arg < l.args.length && l.args[arg].by_ref && lirLoanFrom(edit v, l, dst, l.args[arg].value) { grew = true }
                        }
                    }
                }
            }
        }
    }
}

// Is every origin of reference `slot` still owned (Init), and is no
// borrowed list element possibly moved or dropped by a list mutation?
flow lirLoanLive(v: edit LirVerifier, l: view LirFn, slot: Int) => Bool {
    when slot >= 0 && slot < v.stale.length && v.stale[slot] { give false }
    each k among 0..v.org_ref.length {
        hold origin_root = v.org_root[k]
        hold origin_place = v.org_place[k]
        when v.org_ref[k] == slot && !lirLeafInit(edit v, l, origin_root, origin_place) { give false }
    }
    give true
}

flow lirLoanOperand(v: edit LirVerifier, l: view LirFn, operand: Int) => Bool {
    when !lirIsVar(operand) || !lirVarOk(l, operand) || !l.vars[operand].is_ref { give true }
    give lirLoanLive(edit v, l, operand)
}

flow lirLoanPlace(v: edit LirVerifier, l: view LirFn, place: Int) => Bool {
    when place < 0 || place >= l.places.length { give true }
    give lirLoanOperand(edit v, l, l.places[place].root)
}

flow lirLoanArg(v: edit LirVerifier, l: view LirFn, arg: Int) => Bool {
    when arg < 0 || arg >= l.args.length { give true }
    when l.args[arg].by_ref { give lirLoanPlace(edit v, l, l.args[arg].value) }
    give lirLoanOperand(edit v, l, l.args[arg].value)
}

// Every reference an instruction reads must still point to an owned value.
flow lirLoanInst(v: edit LirVerifier, l: view LirFn, id: Int) => Bool {
    hold kind = l.insts[id].kind
    hold a = l.insts[id].a
    hold b = l.insts[id].b
    hold c = l.insts[id].c
    when kind == LIR_USE { give lirLoanOperand(edit v, l, a) }
    when kind == LIR_UNARY { give lirLoanOperand(edit v, l, b) }
    when kind == LIR_BINARY { give lirLoanOperand(edit v, l, b) && lirLoanOperand(edit v, l, c) }
    when kind == LIR_CALL || kind == LIR_PLATFORM {
        each i among 0..c {
            when !lirLoanArg(edit v, l, l.operands[b + i]) { give false }
        }
        give true
    }
    when kind == LIR_STRUCT || kind == LIR_LIST_LIT {
        each i among 0..c {
            when !lirLoanOperand(edit v, l, l.operands[b + i]) { give false }
        }
        give true
    }
    when kind == LIR_VARIANT { give c == LIR_NONE || lirLoanOperand(edit v, l, c) }
    when kind == LIR_PRINT || kind == LIR_APPEND { give lirLoanArg(edit v, l, a) }
    // `textbuf` reads nothing (its operand is a capacity).
    when kind == LIR_DROP || kind == LIR_TEXTBUF { give true }
    when kind == LIR_STORE || kind == LIR_LIST_PUSH || kind == LIR_LIST_RESERVE || kind == LIR_BYTE_AT {
        give lirLoanPlace(edit v, l, a) && lirLoanOperand(edit v, l, b)
    }
    give lirLoanPlace(edit v, l, a)
}

// Ownership effects of one instruction already checked by the type rules.
// Returns a status (0, 5, 6 or 10).
expose flow lirOwnInst(v: edit LirVerifier, l: view LirFn, types: view TypeTable, lm: view LirModule, drop_memo: view List of[Int], id: Int, check: Bool) => Int {
    hold kind = l.insts[id].kind
    hold dst = l.insts[id].dst
    hold a = l.insts[id].a
    hold b = l.insts[id].b
    hold c = l.insts[id].c
    when check && !lirLoanInst(edit v, l, id) { give 5 }
    when kind == LIR_LIST_PUSH || kind == LIR_LIST_RESERVE || kind == LIR_LIST_POP || (kind == LIR_STORE && lirPlaceIndexed(l, a)) {
        lirLoanMutatePlace(edit v, l, a)
    }
    when kind == LIR_CALL || kind == LIR_PLATFORM {
        each i among 0..c {
            hold arg = l.operands[b + i]
            when arg >= 0 && arg < l.args.length && l.args[arg].by_ref && l.args[arg].mutable {
                lirLoanMutatePlace(edit v, l, l.args[arg].value)
            }
        }
    }
    when kind == LIR_DROP || kind == LIR_DROPFIELD {
        change root = dst
        change place = -1
        change flag = a
        when kind == LIR_DROPFIELD {
            root = l.places[a].root
            place = a
            flag = b
        }
        when check && flag < 0 && !lirLeafInit(edit v, l, root, place) { give 6 }
        when check && flag >= 0 {
            when flag >= v.flags.length { give 6 }
            hold value = v.flags[flag]
            when !lirLeafAgrees(edit v, l, root, place, value) { give 6 }
        }
        lirLeafPut(edit v, l, root, place, false)
        give 0
    }
    change ok = true
    change defines = true
    when kind == LIR_USE {
        ok = lirOwnOperand(edit v, l, a, true, check)
    } otherwise when kind == LIR_UNARY {
        ok = lirOwnOperand(edit v, l, b, false, check)
    } otherwise when kind == LIR_BINARY {
        ok = lirOwnOperand(edit v, l, b, false, check) && lirOwnOperand(edit v, l, c, false, check)
    } otherwise when kind == LIR_CALL || kind == LIR_PLATFORM {
        each i among 0..c {
            when ok { ok = lirOwnArg(edit v, l, l.operands[b + i], true, check) }
        }
    } otherwise when kind == LIR_STRUCT || kind == LIR_LIST_LIT {
        each i among 0..c {
            when ok { ok = lirOwnOperand(edit v, l, l.operands[b + i], true, check) }
        }
    } otherwise when kind == LIR_VARIANT {
        when c != LIR_NONE { ok = lirOwnOperand(edit v, l, c, true, check) }
    } otherwise when kind == LIR_READ {
        hold ty = lirPlaceType(l, types, lm, a)
        hold moving = !lirPlaceIndexed(l, a) && ty >= 0 && ty < drop_memo.length && drop_memo[ty] == 2
        ok = lirOwnPlace(edit v, l, a, moving, check)
    } otherwise when kind == LIR_BYTE_AT {
        ok = lirOwnOperand(edit v, l, b, false, check) && lirOwnPlace(edit v, l, a, false, check)
    } otherwise when kind == LIR_PRINT {
        defines = false
        ok = lirOwnArg(edit v, l, a, false, check)
    } otherwise when kind == LIR_APPEND {
        defines = false
        ok = lirOwnArg(edit v, l, a, false, check) && lirOwnOperand(edit v, l, dst, false, check)
    } otherwise when kind == LIR_STORE {
        defines = false
        ok = lirOwnOperand(edit v, l, b, true, check)
        when ok && lirPlaceIndexed(l, a) {
            // Storing into a list element replaces it; the list stays owned.
            ok = lirOwnPlace(edit v, l, a, false, check)
        } otherwise when ok {
            hold root = l.places[a].root
            lirOwnDef(edit v, l, root, a, check)
        }
    } otherwise when kind == LIR_LIST_PUSH {
        defines = false
        ok = lirOwnOperand(edit v, l, b, true, check) && lirOwnPlace(edit v, l, a, false, check)
    } otherwise when kind == LIR_LIST_RESERVE {
        defines = false
        ok = lirOwnOperand(edit v, l, b, false, check) && lirOwnPlace(edit v, l, a, false, check)
    } otherwise when kind != LIR_TEXTBUF {
        // loan, disc, len, cap, listpop, payload: the place is only used.
        ok = lirOwnPlace(edit v, l, a, false, check)
    }
    when !ok { give 5 }
    when !defines { give 0 }
    lirOwnDef(edit v, l, dst, -1, check)
    // A reference assigned again borrows afresh.
    when dst < v.stale.length { v.stale[dst] = false }
    when kind == LIR_PAYLOAD && l.vars[dst].ty != 1 && l.vars[dst].ty != 4 {
        // A non-Copy payload consumes its whole union.
        when !lirOwnOperand(edit v, l, l.places[a].root, true, check) { give 5 }
    }
    give 0
}

// Ownership effects of a terminator already checked by the type rules.
expose flow lirOwnTerm(v: edit LirVerifier, l: view LirFn, body: view LirBody, b: Int, check: Bool) => Int {
    hold kind = body.term[b]
    hold top = body.top[b]
    when kind == LIR_T_RETURN {
        when check && !lirLoanOperand(edit v, l, top) { give 5 }
        when !lirOwnOperand(edit v, l, top, true, check) { give 5 }
    }
    when kind == LIR_T_RETURNREF {
        when check && !lirLoanOperand(edit v, l, top) { give 5 }
        // Only a borrow of a reference parameter may be returned.
        each k among 0..v.org_ref.length {
            when check && v.org_ref[k] == top { give 7 }
        }
    }
    when check && (kind == LIR_T_RETURN || kind == LIR_T_RETURNREF) {
        each k among 0..v.lown.length {
            when v.lown[k] { v.leaked = true }
        }
    }
    give 0
}
