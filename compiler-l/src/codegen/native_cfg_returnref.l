take native_cfg_defs
take native_cfg_types

// Functions that return a reference (`result T 1 0` shared, `result T 1 1`
// exclusive) in the ELE-written CFG backend, and their terminator
// `t returnref vN` (term 5).
//
// The returned value is one word, the referent's address, in RAX; the
// function has no hidden result pointer (its CfgFunc.result_type is 0 and
// result_ref_type keeps T). A returned reference must outlive the callee,
// so this backend accepts it only under rules it can check on the LIR:
// - `vN` is a reference of type T: a reference parameter, or a local
//   reference whose loan (native_cfg_loan) has a reference PARAMETER as its
//   root, so it points into storage owned by the caller. A loan of a local
//   or of a by-value parameter would dangle and is rejected.
// - An exclusive result needs an exclusive loan; returning an exclusive
//   reference parameter makes that parameter exclusive (cfgParamNeedsMut).
// - The verifier requires `vN` to be valid at the terminator (57), and the
//   same leak checks as `t return` apply.
// - A plain `t return` in such a function is rejected.
// Calls of these functions are not lowered yet: the caller would need the
// returned reference as a local loan over its reference arguments. They are
// rejected (141) rather than accepted unchecked.
//
// Rejection codes: 140 malformed or unsound returned reference, 141 call of
// a function that returns a reference.

// Mode of `result T <ref> <mut>`: -1 no reference, 0 shared, 1 exclusive,
// -2 an invalid combination.
expose flow cfgReturnedRefMode(returned_ref: Int, returned_mut: Int) => Int {
    when returned_ref == 0 && returned_mut == 0 { give -1 }
    when returned_ref == 1 && returned_mut == 0 { give 0 }
    when returned_ref == 1 && returned_mut == 1 { give 1 }
    give -2
}

// Checked once the whole function is read, when every loan is recorded.
expose flow cfgCheckReturnRefs(p: view CfgProgram, f: Int) => Int {
    hold func = view p.functions[f]
    each b among func.first_block..(func.first_block + func.blocks) {
        hold block = view p.blocks[b]
        when block.term == 1 && func.result_ref >= 0 { give 140 }
        when block.term == 5 {
            when func.result_ref < 0 || !block.value.is_var { give 140 }
            hold v = block.value.value
            when v < 0 || v >= func.vars { give 140 }
            hold slot = func.first_var + v
            when !p.var_ref[slot] || p.types_code[slot] != func.result_ref_type { give 140 }
            when v >= func.params {
                hold root = p.ref_root[slot]
                when root < 0 || root >= func.params { give 140 }
                when !p.var_ref[func.first_var + root] { give 140 }
                when func.result_ref == 1 && p.ref_mut[slot] != 1 { give 140 }
            }
        }
    }
    give 0
}

// Whether function `f` returns its reference parameter `v` exclusively.
expose flow cfgReturnsParamMut(p: view CfgProgram, f: Int, v: Int) => Bool {
    hold func = view p.functions[f]
    when func.result_ref != 1 { give false }
    each b among func.first_block..(func.first_block + func.blocks) {
        hold block = view p.blocks[b]
        when block.term == 5 && block.value.is_var && block.value.value == v { give true }
    }
    give false
}
