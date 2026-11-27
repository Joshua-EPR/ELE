take tokens
take sema_types
take lir_build
take lir_finish
take lir_verify_core
take lir_verify_own

// Verified call/terminator contracts and dataflow join for Stage 1.
expose flow lirVerifyCall(v: edit LirVerifier, l: view LirFn, types: view TypeTable, lm: view LirModule, callee: Int, first: Int, count: Int, check: Bool) => Int {
    when callee < 0 || callee >= lm.fn_first.length { give 1 }
    when count != lm.fn_count[callee] || first < 0 || first + count > l.operands.length { give 4 }
    each i among 0..count {
        hold arg = l.operands[first + i]
        when arg < 0 || arg >= l.args.length { give 1 }
        hold p = lm.fn_first[callee] + i
        when l.args[arg].by_ref != lm.param_ref[p] { give 4 }
        when l.args[arg].by_ref && l.args[arg].mutable != lm.param_mut[p] { give 4 }
        when !lirTypesCompat(types, lm, lirArgType(l, types, lm, arg), lm.param_ty[p]) { give 4 }
        when !lirArgDefined(edit v, l, arg, check) { give 5 }
    }
    give 0
}


// Validate every platform call independently of the semantic lowering.
// This closes the old verifier gap where LIR_PLATFORM unconditionally
// accepted the destination's own type and never inspected the arguments.
// Rules: 1 invalid ids/opcode, 3 type/result, 4 arity/borrow mode,
// 5 use-before-initialization.
// ---- Linear resource operations ------------------------------------------
// The per-family table (ops, arity, opener, argument kinds) lives in
// lir_build.l, shared with sema. Here: the resource type of each family.

// Whether `ty` is the linear resource type of the family of `op`.
flow lirIsOpResource(types: view TypeTable, op: Int, ty: Int) => Bool {
    when lirIsWindowOp(op) { give semTypeIsWindow(types, ty) }
    give semTypeIsFile(types, ty)
}

flow lirIsByteList(types: view TypeTable, ty: Int) => Bool {
    when ty < 8 || ty >= types.types.length { give false }
    choose types.types[ty].kind {
        SemTypeKind.List : { give types.types[ty].elem_type == 1 }
        _ : { give false }
    }
}

// A resource comes only from its open op: every resource operand must have
// the family's resource type (an Int cannot be passed as a handle), the
// resource is never borrowed exclusively, and only the close op consumes
// it by value.
flow lirVerifyResourcePlatform(v: edit LirVerifier, l: view LirFn, types: view TypeTable, lm: view LirModule, op: Int, first: Int, count: Int, dst: Int, check: Bool) => Int {
    hold arity = lirResourceArity(op)
    when count != arity || first < 0 || first > l.operands.length || count > l.operands.length - first { give 4 }
    hold result = l.vars[dst].ty
    when lirResourceOpens(op) {
        when !lirIsOpResource(types, op, result) { give 3 }
    } otherwise when result != 1 { give 3 }
    each i among 0..count {
        hold arg = l.operands[first + i]
        when arg < 0 || arg >= l.args.length { give 1 }
        hold kind = lirResourceArgKind(op, i)
        hold by_ref = kind >= 1 && kind <= 4
        when l.args[arg].by_ref != by_ref { give 4 }
        when l.args[arg].mutable != (kind == 3) { give 4 }
        hold ty = lirArgType(l, types, lm, arg)
        when kind == 0 && ty != 1 { give 3 }
        when (kind == 1 || kind == 5) && !lirIsOpResource(types, op, ty) { give 3 }
        when (kind == 2 || kind == 3) && !lirIsByteList(types, ty) { give 3 }
        when kind == 4 && ty != 5 { give 3 }
        when !lirArgDefined(edit v, l, arg, check) { give 5 }
    }
    give 0
}

expose flow lirVerifyPlatform(v: edit LirVerifier, l: view LirFn, types: view TypeTable, lm: view LirModule, op: Int, first: Int, count: Int, dst: Int, check: Bool) => Int {
    when !lirVarOk(l, dst) || l.vars[dst].is_ref { give 3 }
    when lirIsResourceOp(op) {
        give lirVerifyResourcePlatform(edit v, l, types, lm, op, first, count, dst, check)
    }
    when lirIsIntrinsicOp(op) {
        // Kernel intrinsics: `val` Int arguments; Int or Unit result.
        hold arity = lirIntrinsicArity(op)
        when (arity >= 0 && count != arity) || (arity < 0 && (count < 1 || count > 256)) || first < 0 || first > l.operands.length || count > l.operands.length - first { give 4 }
        when l.vars[dst].ty != lirIntrinsicResultType(op) { give 3 }
        each i among 0..count {
            hold arg = l.operands[first + i]
            when arg < 0 || arg >= l.args.length { give 1 }
            when l.args[arg].by_ref { give 4 }
            when lirArgType(l, types, lm, arg) != lirIntrinsicArgType(op, i) { give 3 }
            when !lirArgDefined(edit v, l, arg, check) { give 5 }
        }
        give 0
    }
    change arity = -1
    when op == LIR_PLATFORM_ARG_COUNT || op == LIR_PLATFORM_READ_EVENT { arity = 0 }
    when op == LIR_PLATFORM_ARG || op == LIR_PLATFORM_PRINT_ERROR || op == LIR_PLATFORM_CONSOLE_MODE || op == LIR_PLATFORM_WRITE_CONSOLE { arity = 1 }
    when op == LIR_PLATFORM_READ_TEXT || op == LIR_PLATFORM_WRITE_BYTES || op == LIR_PLATFORM_SAME_FILE || op == LIR_PLATFORM_CLIPBOARD_WRITE || op == LIR_PLATFORM_CLIPBOARD_READ || op == LIR_PLATFORM_TEXT_FROM_BYTES { arity = 2 }
    when arity < 0 { give 1 }
    when count != arity || first < 0 || first > l.operands.length || count > l.operands.length - first { give 4 }
    hold result = l.vars[dst].ty
    when op == LIR_PLATFORM_ARG_COUNT || op == LIR_PLATFORM_WRITE_BYTES || op == LIR_PLATFORM_CONSOLE_MODE || op == LIR_PLATFORM_READ_EVENT || op == LIR_PLATFORM_WRITE_CONSOLE || op == LIR_PLATFORM_CLIPBOARD_WRITE || op == LIR_PLATFORM_CLIPBOARD_READ {
        when result != 1 { give 3 }
    } otherwise when op == LIR_PLATFORM_PRINT_ERROR {
        when result != 6 { give 3 }
    } otherwise {
        when op == LIR_PLATFORM_SAME_FILE {
            when result != 1 { give 3 }
        } otherwise {
            // processArg/readText produce Result<Text,Int>: an owned union
            // whose active Text is dropped once (or moved out by a match).
            when result < 8 || result >= types.types.length { give 3 }
            choose types.types[result].kind {
                SemTypeKind.Result : {
                    when types.types[result].elem_type != 5 || types.types[result].nominal_id != 1 { give 3 }
                }
                _ : { give 3 }
            }
        }
    }
    each i among 0..count {
        hold arg = l.operands[first + i]
        when arg < 0 || arg >= l.args.length { give 1 }
        change borrowed = false
        change expected = 1
        when (op == LIR_PLATFORM_CLIPBOARD_WRITE || op == LIR_PLATFORM_CLIPBOARD_READ) && i == 0 {
            when !l.args[arg].by_ref || l.args[arg].mutable != (op == LIR_PLATFORM_CLIPBOARD_READ) { give 4 }
            when !lirIsByteList(types, lirArgType(l, types, lm, arg)) { give 3 }
            when !lirArgDefined(edit v, l, arg, check) { give 5 }
            proceed
        }
        when op == LIR_PLATFORM_PRINT_ERROR || (op == LIR_PLATFORM_READ_TEXT && i == 0) || op == LIR_PLATFORM_WRITE_BYTES || op == LIR_PLATFORM_SAME_FILE || op == LIR_PLATFORM_WRITE_CONSOLE || (op == LIR_PLATFORM_TEXT_FROM_BYTES && i == 0) {
            borrowed = true
            expected = 5
        }
        when l.args[arg].by_ref != borrowed { give 4 }
        when borrowed && l.args[arg].mutable { give 4 }
        hold ty = lirArgType(l, types, lm, arg)
        when (op == LIR_PLATFORM_WRITE_BYTES && i == 1) || op == LIR_PLATFORM_WRITE_CONSOLE || (op == LIR_PLATFORM_TEXT_FROM_BYTES && i == 0) {
            when ty < 8 || ty >= types.types.length { give 3 }
            choose types.types[ty].kind {
                SemTypeKind.List : { when types.types[ty].elem_type != 1 { give 3 } }
                _ : { give 3 }
            }
        } otherwise when ty != expected {
            give 3
        }
        when !lirArgDefined(edit v, l, arg, check) { give 5 }
    }
    give 0
}

expose flow lirVerifyTerm(v: edit LirVerifier, l: view LirFn, body: view LirBody, types: view TypeTable, lm: view LirModule, fn_index: Int, b: Int, blocks: Int, check: Bool) => Int {
    hold kind = body.term[b]
    when kind == LIR_T_JUMP {
        when body.ta[b] < 0 || body.ta[b] >= blocks { give 2 }
    } otherwise when kind == LIR_T_BRANCH {
        when body.ta[b] < 0 || body.ta[b] >= blocks || body.tb[b] < 0 || body.tb[b] >= blocks { give 2 }
        when body.top[b] == LIR_NONE { give 2 }
        when lirOperandType(l, body.top[b]) != 4 { give 3 }
        when !lirUse(edit v, l, body.top[b], check) { give 5 }
    } otherwise when kind == LIR_T_RETURN {
        when lm.fn_ret_ref[fn_index] || !lirTypesCompat(types, lm, lirOperandType(l, body.top[b]), lm.fn_ret[fn_index]) { give 7 }
        when !lirUse(edit v, l, body.top[b], check) { give 5 }
    } otherwise when kind == LIR_T_RETURNREF {
        hold slot = body.top[b]
        when !lm.fn_ret_ref[fn_index] || !lirVarOk(l, slot) || !l.vars[slot].is_ref || !lirTypesCompat(types, lm, l.vars[slot].ty, lm.fn_ret[fn_index]) { give 7 }
        when check && !v.defined[slot] { give 5 }
    } otherwise when kind != LIR_T_UNREACHABLE {
        give 2
    }
    give 0
}


// Must-analysis join: a variable stays assigned only if assigned on every
// incoming edge.
expose flow lirVerifyFlow(v: edit LirVerifier, target: Int, vars: Int) {
    hold first = !v.seen[target]
    change changed = first
    each i among 0..vars {
        hold incoming = v.defined[i]
        hold cell = target * vars + i
        when first {
            v.table[cell] = incoming
        } otherwise when v.table[cell] && !incoming {
            v.table[cell] = false
            changed = true
        }
        // May-analysis for owned-union moves: moved on any incoming edge.
        when cell < v.mtable.length && i < v.moved.length {
            hold gone = v.moved[i]
            when first {
                v.mtable[cell] = gone
            } otherwise when gone && !v.mtable[cell] {
                v.mtable[cell] = true
                changed = true
            }
        }
        when v.has_flags {
            when i < v.flag_root.length && v.flag_root[i] >= 0 {
                hold f_in = v.flags[i]
                when cell < v.ftable.length {
                    when first {
                        v.ftable[cell] = f_in
                    } otherwise when v.ftable[cell] != f_in {
                        // Paths that disagree join to Unknown; a forged
                        // value (3) stays forged.
                        change joined = 2
                        when v.ftable[cell] == 3 || f_in == 3 { joined = 3 }
                        when v.ftable[cell] != joined {
                            v.ftable[cell] = joined
                            changed = true
                        }
                    }
                }
                // Ownership of the place this flag guards (per flag, not
                // per root: fields of one struct are owned independently).
                when i < v.owned.length && cell < v.otable.length {
                    hold o_in = v.owned[i]
                    when first {
                        v.otable[cell] = o_in
                    } otherwise when v.otable[cell] != o_in && v.otable[cell] != 2 {
                        v.otable[cell] = 2
                        changed = true
                    }
                }
            }
        }
    }
    when lirLeafJoin(edit v, target, first) { changed = true }
    v.seen[target] = true
    when changed && !v.pending[target] {
        v.pending[target] = true
        v.queue@push(target)
    }
}
