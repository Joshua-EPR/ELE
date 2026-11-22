import tokens
import sema_types
import lir_build
import lir_finish
import lir_verify_core
take lir_verify_own

// Verified call/terminator contracts and dataflow join for Stage 1.
pub fn lirVerifyCall(v: &mut LirVerifier, l: &LirFn, types: &TypeTable, lm: &LirModule, callee: Int, first: Int, count: Int, check: Bool) -> Int {
    if callee < 0 || callee >= lm.fn_first.length { return 1 }
    if count != lm.fn_count[callee] || first < 0 || first + count > l.operands.length { return 4 }
    for i in 0..count {
        let arg = l.operands[first + i]
        if arg < 0 || arg >= l.args.length { return 1 }
        let p = lm.fn_first[callee] + i
        if l.args[arg].by_ref != lm.param_ref[p] { return 4 }
        if l.args[arg].by_ref && l.args[arg].mutable != lm.param_mut[p] { return 4 }
        if !lirTypesCompat(types, lm, lirArgType(l, types, lm, arg), lm.param_ty[p]) { return 4 }
        if !lirArgDefined(&mut v, l, arg, check) { return 5 }
    }
    return 0
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

pub fn lirVerifyPlatform(v: &mut LirVerifier, l: &LirFn, types: &TypeTable, lm: &LirModule, op: Int, first: Int, count: Int, dst: Int, check: Bool) -> Int {
    if !lirVarOk(l, dst) || l.vars[dst].is_ref { return 3 }
    when lirIsResourceOp(op) {
        give lirVerifyResourcePlatform(edit v, l, types, lm, op, first, count, dst, check)
    }
    var arity = -1
    if op == LIR_PLATFORM_ARG_COUNT || op == LIR_PLATFORM_READ_EVENT { arity = 0 }
    if op == LIR_PLATFORM_ARG || op == LIR_PLATFORM_PRINT_ERROR || op == LIR_PLATFORM_CONSOLE_MODE || op == LIR_PLATFORM_WRITE_CONSOLE { arity = 1 }
    if op == LIR_PLATFORM_READ_TEXT || op == LIR_PLATFORM_WRITE_BYTES || op == LIR_PLATFORM_SAME_FILE || op == LIR_PLATFORM_TEXT_FROM_BYTES { arity = 2 }
    if arity < 0 { return 1 }
    if count != arity || first < 0 || first > l.operands.length || count > l.operands.length - first { return 4 }
    let result = l.vars[dst].ty
    if op == LIR_PLATFORM_ARG_COUNT || op == LIR_PLATFORM_WRITE_BYTES || op == LIR_PLATFORM_CONSOLE_MODE || op == LIR_PLATFORM_READ_EVENT || op == LIR_PLATFORM_WRITE_CONSOLE {
        if result != 1 { return 3 }
    } else if op == LIR_PLATFORM_PRINT_ERROR {
        if result != 6 { return 3 }
    } else {
        when op == LIR_PLATFORM_SAME_FILE {
            when result != 1 { give 3 }
        } otherwise {
            // processArg/readText produce Result<Text,Int>: an owned union
            // whose active Text is dropped once (or moved out by a match).
            if result < 8 || result >= types.types.length { return 3 }
            match types.types[result].kind {
                SemTypeKind.Result => {
                    if types.types[result].elem_type != 5 || types.types[result].nominal_id != 1 { return 3 }
                }
                _ => { return 3 }
            }
        }
    }
    for i in 0..count {
        let arg = l.operands[first + i]
        if arg < 0 || arg >= l.args.length { return 1 }
        var borrowed = false
        var expected = 1
        if op == LIR_PLATFORM_PRINT_ERROR || (op == LIR_PLATFORM_READ_TEXT && i == 0) || op == LIR_PLATFORM_WRITE_BYTES || op == LIR_PLATFORM_SAME_FILE || op == LIR_PLATFORM_WRITE_CONSOLE || (op == LIR_PLATFORM_TEXT_FROM_BYTES && i == 0) {
            borrowed = true
            expected = 5
        }
        if l.args[arg].by_ref != borrowed { return 4 }
        if borrowed && l.args[arg].mutable { return 4 }
        let ty = lirArgType(l, types, lm, arg)
        if (op == LIR_PLATFORM_WRITE_BYTES && i == 1) || op == LIR_PLATFORM_WRITE_CONSOLE || (op == LIR_PLATFORM_TEXT_FROM_BYTES && i == 0) {
            if ty < 8 || ty >= types.types.length { return 3 }
            match types.types[ty].kind {
                SemTypeKind.List => { if types.types[ty].elem_type != 1 { return 3 } }
                _ => { return 3 }
            }
        } else if ty != expected {
            return 3
        }
        if !lirArgDefined(&mut v, l, arg, check) { return 5 }
    }
    return 0
}

pub fn lirVerifyTerm(v: &mut LirVerifier, l: &LirFn, body: &LirBody, types: &TypeTable, lm: &LirModule, fn_index: Int, b: Int, blocks: Int, check: Bool) -> Int {
    let kind = body.term[b]
    if kind == LIR_T_JUMP {
        if body.ta[b] < 0 || body.ta[b] >= blocks { return 2 }
    } else if kind == LIR_T_BRANCH {
        if body.ta[b] < 0 || body.ta[b] >= blocks || body.tb[b] < 0 || body.tb[b] >= blocks { return 2 }
        if body.top[b] == LIR_NONE { return 2 }
        if lirOperandType(l, body.top[b]) != 4 { return 3 }
        if !lirUse(&mut v, l, body.top[b], check) { return 5 }
    } else if kind == LIR_T_RETURN {
        if lm.fn_ret_ref[fn_index] || !lirTypesCompat(types, lm, lirOperandType(l, body.top[b]), lm.fn_ret[fn_index]) { return 7 }
        if !lirUse(&mut v, l, body.top[b], check) { return 5 }
    } else if kind == LIR_T_RETURNREF {
        let slot = body.top[b]
        if !lm.fn_ret_ref[fn_index] || !lirVarOk(l, slot) || !l.vars[slot].is_ref || !lirTypesCompat(types, lm, l.vars[slot].ty, lm.fn_ret[fn_index]) { return 7 }
        if check && !v.defined[slot] { return 5 }
    } else if kind != LIR_T_UNREACHABLE {
        return 2
    }
    return 0
}


// Must-analysis join: a variable stays assigned only if assigned on every
// incoming edge.
pub fn lirVerifyFlow(v: &mut LirVerifier, target: Int, vars: Int) {
    let first = !v.seen[target]
    var changed = first
    for i in 0..vars {
        let incoming = v.defined[i]
        let cell = target * vars + i
        if first {
            v.table[cell] = incoming
        } else if v.table[cell] && !incoming {
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
    if changed && !v.pending[target] {
        v.pending[target] = true
        v.queue.push(target)
    }
}
