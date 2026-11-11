import tokens
import sema_types
import lir_build
import lir_finish
import lir_verify_core

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
    }
    v.seen[target] = true
    if changed && !v.pending[target] {
        v.pending[target] = true
        v.queue.push(target)
    }
}
