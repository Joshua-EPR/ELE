take tokens
take sema_types
take lir_build
take lir_finish
take lir_verify_core
take lir_verify_helpers
take lir_builtin_union
take lir_verify_own

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
//  10 an owned value is leaked: overwritten, or still owned at a return
//     (reported only when no other rule is violated)
// Every owned value, not only unions, is tracked per leaf by
// `lir_verify_own.l`: a use, move or loan of a moved/dropped value is rule
// 5, an unflagged drop of it rule 6; a drop flag must agree with the
// ownership of the place it guards (rule 6), so a flag that is a parameter
// or is assigned anything but a Bool constant is rejected. A reference is
// usable only while the places it borrows are owned (rule 5) and a
// borrowed return may only borrow from reference parameters (rule 7).
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

// Check one instruction, then its ownership and loan effects
// (`lir_verify_own.l`). Returns a status.
flow lirVerifyInst(v: edit LirVerifier, l: view LirFn, types: view TypeTable, lm: view LirModule, drop_memo: view List of[Int], id: Int, block: Int, check: Bool) => Int {
    hold status = lirVerifyInstCore(edit v, l, types, lm, drop_memo, id, block, check)
    when status != 0 { give status }
    give lirOwnInst(edit v, l, types, lm, drop_memo, id, check)
}

// Check one instruction and apply its definition. Returns a status.
flow lirVerifyInstCore(v: edit LirVerifier, l: view LirFn, types: view TypeTable, lm: view LirModule, drop_memo: view List of[Int], id: Int, block: Int, check: Bool) => Int {
    when id < 0 || id >= l.insts.length { give 1 }
    hold inst = view l.insts[id]
    when inst.block != block { give 9 }
    hold kind = inst.kind
    hold dst = inst.dst
    when kind == LIR_PRINT || kind == LIR_APPEND {
        when inst.a < 0 || inst.a >= l.args.length { give 1 }
        hold ty = lirArgType(l, types, lm, inst.a)
        when ty == LIR_TY_ERR { give 1 }
        when !lirPrintable(ty) { give 3 }
        when !lirArgDefined(edit v, l, inst.a, check) { give 5 }
        when kind == LIR_APPEND {
            when !lirVarOk(l, dst) || l.vars[dst].ty != 5 || l.vars[dst].is_ref { give 3 }
            when check && !v.defined[dst] { give 5 }
        }
        give 0
    }
    when kind == LIR_STORE {
        hold ty = lirPlaceType(l, types, lm, inst.a)
        when ty == LIR_TY_ERR { give 8 }
        when !lirTypesCompat(types, lm, lirOperandType(l, inst.b), ty) { give 3 }
        when !lirUse(edit v, l, inst.b, check) { give 5 }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
        lirMoveOut(edit v, l, types, drop_memo, inst.b, false)
        // The stored place owns its new value (the drop plan released the
        // old one before the store).
        lirGuardSet(edit v, l, l.places[inst.a].root, inst.a, 1, false)
        give 0
    }
    when kind == LIR_LIST_PUSH || kind == LIR_LIST_RESERVE {
        hold ty = lirPlaceType(l, types, lm, inst.a)
        when ty < 0 || ty >= types.types.length { give 8 }
        choose types.types[ty].kind {
            SemTypeKind.List : {}
            _ : { give 3 }
        }
        change expected = types.types[ty].elem_type
        when kind == LIR_LIST_RESERVE { expected = 1 }
        when lirOperandType(l, inst.b) != expected { give 3 }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
        when !lirUse(edit v, l, inst.b, check) { give 5 }
        lirMoveOut(edit v, l, types, drop_memo, inst.b, false)
        give 0
    }
    when kind == LIR_DROP || kind == LIR_DROPFIELD {
        change ty = LIR_TY_ERR
        when kind == LIR_DROP {
            when !lirVarOk(l, dst) || l.vars[dst].is_ref { give 6 }
            ty = l.vars[dst].ty
            when check && !v.defined[dst] { give 5 }
            // An unflagged drop of a (maybe) moved owned union is a double
            // drop; afterwards the union owns nothing.
            when check && inst.a < 0 && dst < v.moved.length && v.moved[dst] { give 6 }
        } otherwise {
            ty = lirPlaceType(l, types, lm, inst.a)
            when ty == LIR_TY_ERR { give 8 }
        }
        when ty < 0 || ty >= drop_memo.length || drop_memo[ty] != 2 { give 6 }
        change flag = inst.a
        change root = dst
        when kind == LIR_DROPFIELD {
            flag = inst.b
            root = l.places[inst.a].root
        }
        when flag >= 0 {
            when !lirVarOk(l, flag) || l.vars[flag].ty != 4 || l.vars[flag].is_ref { give 6 }
            when check && !v.defined[flag] { give 5 }
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
        give 0
    }
    when !lirVarOk(l, dst) { give 1 }
    hold dst_t = l.vars[dst].ty
    hold dst_ref = l.vars[dst].is_ref
    change result = LIR_TY_ERR
    change result_ref = false
    when kind == LIR_USE {
        when lirIsVar(inst.a) && lirVarOk(l, inst.a) && l.vars[inst.a].is_ref {
            result = l.vars[inst.a].ty
            result_ref = true
        } otherwise {
            result = lirOperandType(l, inst.a)
        }
        when !lirUse(edit v, l, inst.a, check) { give 5 }
        lirMoveOut(edit v, l, types, drop_memo, inst.a, false)
    } otherwise when kind == LIR_UNARY {
        hold ty = lirOperandType(l, inst.b)
        when (inst.a == LIR_NEG && (ty == 1 || ty == 2)) || (inst.a == LIR_NOT && ty == 4) { result = ty }
        when inst.a == LIR_ITOF && ty == 1 { result = 2 }
        when inst.a == LIR_FTOI && ty == 2 { result = 1 }
        when inst.a == LIR_BNOT && ty == 1 { result = 1 }
        when !lirUse(edit v, l, inst.b, check) { give 5 }
    } otherwise when kind == LIR_BINARY {
        hold lt = lirOperandType(l, inst.b)
        hold rt = lirOperandType(l, inst.c)
        when lirTypesCompat(types, lm, lt, rt) && lt != LIR_TY_ERR {
            when inst.a <= LIR_REM && (lt == 1 || lt == 2) { result = lt }
            when inst.a >= LIR_BAND && inst.a <= LIR_WMUL && lt == 1 { result = 1 }
            when inst.a >= LIR_EQ && inst.a <= LIR_GE && (lt == 1 || rt == 1 || lt == 2 || ((lt == 4 || lirIsUnitEnum(types, lm, lt)) && inst.a <= LIR_NE)) { result = 4 }
        }
        when !lirUse(edit v, l, inst.b, check) || !lirUse(edit v, l, inst.c, check) { give 5 }
    } otherwise when kind == LIR_CALL {
        hold status = lirVerifyCall(edit v, l, types, lm, inst.a, inst.b, inst.c, check)
        when status != 0 { give status }
        each i among 0..inst.c {
            hold arg = l.operands[inst.b + i]
            when !l.args[arg].by_ref { lirMoveOut(edit v, l, types, drop_memo, l.args[arg].value, false) }
        }
        result = lm.fn_ret[inst.a]
        result_ref = lm.fn_ret_ref[inst.a]
    } otherwise when kind == LIR_STRUCT {
        when inst.a < 0 || inst.a >= lm.st_count.length { give 1 }
        when inst.c != lm.st_count[inst.a] || inst.b < 0 || inst.b + inst.c > l.operands.length { give 3 }
        each i among 0..inst.c {
            hold operand = l.operands[inst.b + i]
            when lirOperandType(l, operand) != lm.field_ty[lm.st_first[inst.a] + i] { give 3 }
            when !lirUse(edit v, l, operand, check) { give 5 }
            lirMoveOut(edit v, l, types, drop_memo, operand, false)
        }
        when lirStructOf(types, lm, dst_t) == inst.a { result = dst_t }
    } otherwise when kind == LIR_VARIANT {
        when inst.a < 0 || inst.a >= lm.en_decl.length || inst.b < 0 || inst.b >= lm.en_count[inst.a] { give 1 }
        hold which = lm.en_first[inst.a] + inst.b
        when which < 0 || which >= lm.variant_payload.length { give 3 }
        hold count = lm.variant_payload[which]
        when count == 1 {
            hold payload_ty = lm.variant_type[which]
            when !lirBuiltinPayloadOk(types, lm, payload_ty) || lirOperandType(l, inst.c) != payload_ty { give 3 }
            when !lirUse(edit v, l, inst.c, check) { give 5 }
            lirMoveOut(edit v, l, types, drop_memo, inst.c, true)
        } otherwise when count != 0 { give 3 }
        otherwise when inst.c != LIR_NONE { give 3 }
        when dst_t < 0 || dst_t >= types.types.length { give 3 }
        choose types.types[dst_t].kind {
            SemTypeKind.Enum : {
                when types.types[dst_t].nominal_id != lm.en_decl[inst.a] { give 3 }
                result = dst_t
            }
            SemTypeKind.Option : {
                when lm.en_builtin[inst.a] != dst_t { give 3 }
                result = dst_t
            }
            SemTypeKind.Result : {
                when lm.en_builtin[inst.a] != dst_t { give 3 }
                result = dst_t
            }
            _ : { give 3 }
        }
    } otherwise when kind == LIR_PAYLOAD {
        hold enum_t = lirPlaceType(l, types, lm, inst.a)
        when enum_t < 0 || enum_t >= types.types.length { give 8 }
        when inst.b < 0 || inst.b >= lm.en_decl.length { give 1 }
        when inst.c < 0 || inst.c >= lm.en_count[inst.b] { give 1 }
        hold variant = lm.en_first[inst.b] + inst.c
        when variant < 0 || variant >= lm.variant_payload.length || lm.variant_payload[variant] != 1 { give 3 }
        hold payload_ty = lm.variant_type[variant]
        when !lirBuiltinPayloadOk(types, lm, payload_ty) { give 3 }
        when inst.a < 0 || inst.a >= l.places.length || l.places[inst.a].parent >= 0 { give 8 }
        hold root = l.places[inst.a].root
        when !lirVarOk(l, root) || l.vars[root].is_ref { give 8 }
        choose types.types[enum_t].kind {
            SemTypeKind.Enum : {
                when types.types[enum_t].nominal_id != lm.en_decl[inst.b] { give 3 }
            }
            SemTypeKind.Option : {
                when lm.en_builtin[inst.b] != enum_t { give 3 }
            }
            SemTypeKind.Result : {
                when lm.en_builtin[inst.b] != enum_t { give 3 }
            }
            _ : { give 3 }
        }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
        // An owned payload is moved out: the whole union is consumed.
        when lirBuiltinPayloadOwned(types, lm, payload_ty) && root < v.moved.length {
            v.moved[root] = true
            lirGuardSet(edit v, l, root, -1, 0, true)
        }
        result = payload_ty
    } otherwise when kind == LIR_DISC {
        hold enum_t = lirPlaceType(l, types, lm, inst.a)
        when enum_t < 0 || enum_t >= types.types.length { give 8 }
        choose types.types[enum_t].kind {
            SemTypeKind.Enum : { result = 1 }
            SemTypeKind.Option : {
                when lirBuiltinEnumIndex(lm, enum_t) < 0 { give 3 }
                result = 1
            }
            SemTypeKind.Result : {
                when lirBuiltinEnumIndex(lm, enum_t) < 0 { give 3 }
                result = 1
            }
            _ : { give 3 }
        }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
    } otherwise when kind == LIR_LIST_LIT {
        when inst.a < 0 || inst.a >= lm.list_elem.length || inst.c < 0 || inst.b < 0 || inst.c > l.operands.length || inst.b > l.operands.length - inst.c { give 1 }
        when dst_t < 0 || dst_t >= types.types.length { give 3 }
        choose types.types[dst_t].kind {
            SemTypeKind.List : {
                when types.types[dst_t].elem_type != lm.list_elem[inst.a] { give 3 }
            }
            _ : { give 3 }
        }
        each i among 0..inst.c {
            hold operand = l.operands[inst.b + i]
            when lirOperandType(l, operand) != lm.list_elem[inst.a] { give 3 }
            when !lirUse(edit v, l, operand, check) { give 5 }
            lirMoveOut(edit v, l, types, drop_memo, operand, false)
        }
        result = dst_t
    } otherwise when kind == LIR_READ || kind == LIR_LOAN {
        result = lirPlaceType(l, types, lm, inst.a)
        when result == LIR_TY_ERR { give 8 }
        when check && !lirRootLive(edit v, l, inst.a) { give 5 }
        result_ref = kind == LIR_LOAN
        when kind == LIR_READ && result >= 0 && result < drop_memo.length && drop_memo[result] == 2 {
            // Moving an owned value out of a place releases only the
            // guards inside (or containing) that place.
            lirGuardSet(edit v, l, l.places[inst.a].root, inst.a, 0, true)
        }
    } otherwise when kind == LIR_TEXTBUF {
        result = 5
    } otherwise when kind == LIR_LEN || kind == LIR_CAP {
        hold ty = lirPlaceType(l, types, lm, inst.a)
        when ty < 0 || ty >= types.types.length { give 8 }
        choose types.types[ty].kind {
            SemTypeKind.List : {}
            SemTypeKind.Text : { when kind == LIR_CAP { give 3 } }
            _ : { give 3 }
        }
        result = 1
        when check && !v.defined[l.places[inst.a].root] { give 5 }
    } otherwise when kind == LIR_BYTE_AT {
        when lirPlaceType(l, types, lm, inst.a) != 5 || lirOperandType(l, inst.b) != 1 { give 3 }
        result = 1
        when check && !v.defined[l.places[inst.a].root] { give 5 }
        when !lirUse(edit v, l, inst.b, check) { give 5 }
    } otherwise when kind == LIR_LIST_POP {
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
        when check && !v.defined[l.places[inst.a].root] { give 5 }
    } otherwise when kind == LIR_PLATFORM {
        hold status = lirVerifyPlatform(edit v, l, types, lm, inst.a, inst.b, inst.c, dst, check)
        when status != 0 { give status }
        result = dst_t
    } otherwise {
        give 1
    }
    when result == LIR_TY_ERR || !lirTypesCompat(types, lm, result, dst_t) || result_ref != dst_ref { give 3 }
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
                    v.flags[dst] = 3
                }
            } otherwise {
                // Any other value is forged (3): unlike Unknown (2), which
                // only joins paths where the flag agreed with ownership, it
                // is not tied to ownership, so no drop may trust it.
                v.flags[dst] = 3
            }
        } otherwise when !dst_ref {
            lirGuardSet(edit v, l, dst, -1, 1, false)
        }
    }
    give 0
}

flow lirVerifyBlock(v: edit LirVerifier, l: view LirFn, body: view LirBody, types: view TypeTable, lm: view LirModule, drop_memo: view List of[Int], fn_index: Int, b: Int, check: Bool) => Int {
    hold blocks = body.term.length
    hold first = body.first[b]
    when first < 0 || body.count[b] < 0 || first + body.count[b] > body.order.length { give 1 }
    each i among first..(first + body.count[b]) {
        hold status = lirVerifyInst(edit v, l, types, lm, drop_memo, body.order[i], b, check)
        when status != 0 { give status }
    }
    when check && v.has_flags {
        hold term = body.term[b]
        when term == LIR_T_JUMP || term == LIR_T_BRANCH {
            each f among 0..v.flag_root.length {
                hold root = v.flag_root[f]
                when root >= 0 {
                    when f >= v.owned.length || f >= v.flags.length { give 6 }
                    when v.flags[f] != v.owned[f] { give 6 }
                    hold guarded = v.flag_place[f]
                    hold value = v.flags[f]
                    when !lirLeafAgrees(edit v, l, root, guarded, value) { give 6 }
                }
            }
        }
    }
    hold term = lirVerifyTerm(edit v, l, body, types, lm, fn_index, b, blocks, check)
    when term != 0 { give term }
    give lirOwnTerm(edit v, l, body, b, check)
}

expose flow lirVerify(l: view LirFn, body: view LirBody, types: view TypeTable, lm: view LirModule, drop_memo: view List of[Int], fn_index: Int) => LirCheck {
    hold blocks = body.term.length
    hold vars = l.vars.length
    when fn_index < 0 || fn_index >= lm.fn_first.length || blocks == 0 { give LirCheck(status: 1, block: -1, inst: -1) }
    when body.first.length != blocks || body.count.length != blocks || body.ta.length != blocks || body.tb.length != blocks || body.top.length != blocks {
        give LirCheck(status: 2, block: -1, inst: -1)
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
        leaf_var: List[],
        leaf_first: List[],
        leaf_len: List[],
        leaf_path: List[],
        lown: List[],
        lgone: List[],
        lotable: List[],
        lgtable: List[],
        org_ref: List[],
        org_root: List[],
        org_place: List[],
        stale: List[],
        stable: List[],
        leaked: false,
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
                // A parameter's value is chosen by the caller: as a drop
                // flag it could claim ownership of anything.
                when f < l.params {
                    give LirCheck(status: 6, block: l.insts[id].block, inst: id)
                }
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
    lirLeafSetup(edit v, l, types, lm, drop_memo, blocks)
    lirLoanSetup(edit v, l)
    each i among 0..(blocks * vars) {
        v.table@push(true)
        v.mtable@push(false)
        v.ftable@push(0)
        v.otable@push(0)
    }
    each b among 0..blocks {
        v.seen@push(b == 0)
        v.pending@push(b == 0)
    }
    // Parameters are assigned on entry.
    each i among 0..vars {
        v.table[i] = i < l.params
        // A guard of a parameter starts owning its place.
        when v.flag_root[i] >= 0 && v.flag_root[i] < l.params { v.otable[i] = 1 }
    }
    v.queue@push(0)
    change steps = 0
    during v.queue.length > 0 {
        change b = 0
        choose v.queue@pop() {
            Some(x) : { b = x }
            None : { leave }
        }
        v.pending[b] = false
        steps += 1
        when steps > 100000 { give LirCheck(status: 2, block: b, inst: -1) }
        each i among 0..vars {
            v.defined[i] = v.table[b * vars + i]
            v.moved[i] = v.mtable[b * vars + i]
            when v.has_flags {
                v.flags[i] = v.ftable[b * vars + i]
                v.owned[i] = v.otable[b * vars + i]
            }
        }
        lirLeafLoad(edit v, b)
        hold status = lirVerifyBlock(edit v, l, body, types, lm, drop_memo, fn_index, b, false)
        when status != 0 { give LirCheck(status: status, block: b, inst: -1) }
        hold kind = body.term[b]
        when kind == LIR_T_JUMP || kind == LIR_T_BRANCH {
            lirVerifyFlow(edit v, body.ta[b], vars)
        }
        when kind == LIR_T_BRANCH { lirVerifyFlow(edit v, body.tb[b], vars) }
    }
    change leak_block = -1
    each b among 0..blocks {
        when v.seen[b] {
            each i among 0..vars {
                v.defined[i] = v.table[b * vars + i]
                v.moved[i] = v.mtable[b * vars + i]
                when v.has_flags {
                    v.flags[i] = v.ftable[b * vars + i]
                    v.owned[i] = v.otable[b * vars + i]
                }
            }
            lirLeafLoad(edit v, b)
            hold status = lirVerifyBlock(edit v, l, body, types, lm, drop_memo, fn_index, b, true)
            when status != 0 { give LirCheck(status: status, block: b, inst: -1) }
            when v.leaked && leak_block < 0 { leak_block = b }
        }
    }
    // A leak only once no memory-safety rule is violated anywhere.
    when leak_block >= 0 { give LirCheck(status: 10, block: leak_block, inst: -1) }
    give LirCheck(status: 0, block: -1, inst: steps)
}

