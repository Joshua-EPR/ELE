import native_cfg_types
import native_cfg_defs
import native_cfg_ir
import native_cfg_ref

// Flow-sensitive definedness and whole-value move validation for the
// restricted native backend. Every struct is MOVE-only in ELE even if it
// contains only Int/Bool. Physical field copying is permitted solely to
// implement a semantically validated move (source is invalidated).
// Partial moves of struct-valued fields are rejected by the parser.
// States converge with intersection at joins, including loop backedges.

fn cfgEdge(p: &CfgProgram, f: Int, from: Int, to: Int) -> Bool {
    let block = &p.blocks[p.functions[f].first_block + from]
    if block.term == 2 { return block.yes == to }
    if block.term == 3 { return block.yes == to || block.no == to }
    return false
}

fn cfgHasDst(inst: &CfgInst) -> Bool {
    return inst.kind != 6 && inst.kind != 10 && inst.kind != 12 && inst.kind != 13
}

fn cfgResultType(func: &CfgFunc) -> Int {
    if func.result_bool { return 1 }
    if func.result_unit { return cfgUnitType() }
    if func.result_text { return cfgTextType() }
    return 0
}

fn cfgMoveOperand(p: &CfgProgram, f: Int, op: &NativeOperand, variable: Int) -> Bool {
    return op.is_var && op.value == variable && cfgIsMove(cfgOperandType(p, f, &op))
}

// A whole-value move occurs in a struct assignment, struct constructor or
// store of a struct-valued field, in a Text passed by value to a call and
// in a drop. Primitive values are Copy.
fn cfgMoves(p: &CfgProgram, f: Int, inst: &CfgInst, variable: Int) -> Bool {
    if inst.kind == 13 { return inst.place_var == variable }
    if inst.kind == 3 {
        for n in 0..inst.argc {
            let arg = &p.call_args[inst.arg_first + n]
            if p.call_ref[inst.arg_first + n] < 0 && cfgMoveOperand(p, f, &arg, variable) { return true }
        }
        return false
    }
    if inst.kind == 1 || inst.kind == 6 {
        return cfgMoveOperand(p, f, &inst.a, variable)
    }
    if inst.kind == 7 && inst.argc == 1 {
        return cfgMoveOperand(p, f, &inst.a, variable)
    }
    if inst.kind == 4 {
        if cfgMoveOperand(p, f, &inst.a, variable) { return true }
        if inst.argc >= 2 && cfgMoveOperand(p, f, &inst.b, variable) { return true }
        if inst.argc >= 3 && cfgMoveOperand(p, f, &inst.c, variable) { return true }
        if inst.argc >= 4 && cfgMoveOperand(p, f, &inst.d, variable) { return true }
    }
    return false
}

// Transfer for a single definitely-initialized bit, evaluated in
// instruction order. This models moves as KILL and assignments as GEN.
fn cfgTransferVar(p: &CfgProgram, f: Int, block: &CfgBlock, variable: Int, initial: Bool) -> Bool {
    var live = initial
    for i in block.first..(block.first + block.count) {
        let inst = &p.insts[i]
        if cfgMoves(p, f, &inst, variable) { live = false }
        if cfgHasDst(inst) && inst.dst == variable { live = true }
    }
    return live
}

fn cfgTakeOperand(p: &CfgProgram, f: Int, op: &NativeOperand, live: &mut List<Bool>) -> Int {
    if !op.is_var { return 0 }
    if op.value < 0 || op.value >= p.functions[f].vars { return 57 }
    if !live[op.value] { return 57 }
    if cfgIsMove(cfgOperandType(p, f, &op)) { live[op.value] = false }
    return 0
}

// Validate every instruction in execution order. This rejects double moves
// within one constructor, uses after moves, and move-out-before-return.
fn cfgValidateInstruction(p: &CfgProgram, f: Int, inst: &CfgInst, live: &mut List<Bool>) -> Int {
    if inst.kind == 5 || inst.kind == 6 || inst.kind == 8 || inst.kind == 9 || inst.kind == 12 || inst.kind == 14 || inst.kind == 15 || (inst.kind == 13 && inst.op < 0) {
        if inst.place_var < 0 || inst.place_var >= p.functions[f].vars || !live[inst.place_var] { return 57 }
    }
    if inst.kind == 1 && inst.a.is_var && inst.a.value == inst.dst && cfgOperandType(p, f, &inst.a) >= 2 {
        return 58
    }
    if (inst.kind == 10 || inst.kind == 12 || inst.kind == 13) && inst.op >= 0 {
        // A referenced source, or a drop flag, is read and stays live.
        if !live[inst.op] { return 57 }
    }
    if inst.kind == 13 {
        live[inst.place_var] = false
        return 0
    }
    if inst.kind == 3 {
        for n in 0..inst.argc {
            let arg = &p.call_args[inst.arg_first + n]
            if p.call_ref[inst.arg_first + n] >= 0 {
                // A borrowed root must be initialized and stays owned.
                if !live[arg.value] { return 57 }
            } else {
                let taken = cfgTakeOperand(p, f, &arg, &mut live)
                if taken != 0 { return taken }
            }
        }
    }
    if (inst.kind == 10 || inst.kind == 12) && inst.op < 0 && inst.a.is_var {
        // `print` and `append` read their source without consuming it.
        if inst.a.value < 0 || inst.a.value >= p.functions[f].vars { return 57 }
        if !live[inst.a.value] { return 57 }
    }
    let reads_a = inst.kind == 1 || inst.kind == 2 || inst.kind == 4 || inst.kind == 6 || inst.kind == 15 || inst.kind == 16
    if reads_a || (inst.kind == 7 && inst.argc == 1) {
        let a = cfgTakeOperand(p, f, &inst.a, &mut live)
        if a != 0 { return a }
    }
    if inst.kind == 2 || (inst.kind == 4 && inst.argc >= 2) {
        let b = cfgTakeOperand(p, f, &inst.b, &mut live)
        if b != 0 { return b }
    }
    if inst.kind == 4 && inst.argc >= 3 {
        let c = cfgTakeOperand(p, f, &inst.c, &mut live)
        if c != 0 { return c }
    }
    if inst.kind == 4 && inst.argc == 4 {
        let d = cfgTakeOperand(p, f, &inst.d, &mut live)
        if d != 0 { return d }
    }
    if cfgHasDst(inst) {
        // Overwriting a live owned Text would leak its buffer.
        if live[inst.dst] && p.types_code[p.functions[f].first_var + inst.dst] == cfgTextType() { return 59 }
        live[inst.dst] = true
    }
    return 0
}

fn cfgCheckCalls(p: &CfgProgram) -> Int {
    for f in 0..p.functions.length {
        let func = &p.functions[f]
        for b in 0..func.blocks {
            let block = &p.blocks[func.first_block + b]
            for i in block.first..(block.first + block.count) {
                let inst = &p.insts[i]
                if inst.kind == 3 {
                    let callee = inst.callee
                    if callee < 0 || callee >= p.functions.length { return 51 }
                    let target = &p.functions[callee]
                    if inst.argc != target.params { return 52 }
                    let dst_type = p.types_code[func.first_var + inst.dst]
                    if dst_type != cfgResultType(target) { return 53 }
                    let args = cfgCheckCallArgs(p, f, inst)
                    if args != 0 { return args }
                }
            }
        }
    }
    return 0
}

fn cfgCheckFunction(p: &CfgProgram, f: Int) -> Int {
    let func = &p.functions[f]
    let blocks = func.blocks
    let vars = func.vars
    var reachable: List<Bool> = List[]
    for b in 0..blocks { reachable.push(b == 0) }
    var changing = true
    while changing {
        changing = false
        for b in 0..blocks {
            if reachable[b] {
                for target in 0..blocks {
                    if cfgEdge(p, f, b, target) && !reachable[target] {
                        reachable[target] = true
                        changing = true
                    }
                }
            }
        }
    }
    // Stage 1 emits an empty synthetic block terminated by `unreachable`
    // after paths that already returned. No other disconnected block is valid.
    for b in 0..blocks {
        if !reachable[b] {
            let dead = &p.blocks[func.first_block + b]
            if dead.term != 4 || dead.count != 0 { return 55 }
        }
    }

    var inputs: List<Bool> = List[]
    var outputs: List<Bool> = List[]
    for b in 0..blocks {
        for v in 0..vars {
            var initial = true
            if b == 0 { initial = v < func.params }
            inputs.push(initial)
            outputs.push(true)
        }
    }
    changing = true
    var iterations = 0
    while changing {
        iterations += 1
        if iterations > blocks * vars + blocks + 2 { return 56 }
        changing = false
        for b in 0..blocks {
            let block = &p.blocks[func.first_block + b]
            for v in 0..vars {
                var is_init = true
                if b == 0 { is_init = v < func.params }
                // Entry can also have backedges. Intersect with their
                // states rather than assuming every iteration begins with
                // fresh parameters; moving a parameter in a loop must not
                // silently reinitialize it.
                for pred in 0..blocks {
                    if cfgEdge(p, f, pred, b) && !outputs[pred * vars + v] {
                        is_init = false
                    }
                }
                let slot = b * vars + v
                if inputs[slot] != is_init { inputs[slot] = is_init; changing = true }
                let after = cfgTransferVar(p, f, &block, v, is_init)
                if outputs[slot] != after { outputs[slot] = after; changing = true }
            }
        }
    }

    for b in 0..blocks {
        let block = &p.blocks[func.first_block + b]
        var live: List<Bool> = List[]
        for v in 0..vars { live.push(inputs[b * vars + v]) }
        for i in block.first..(block.first + block.count) {
            let inst = &p.insts[i]
            let error = cfgValidateInstruction(p, f, &inst, &mut live)
            if error != 0 { return error }
        }
        if block.term == 1 || block.term == 3 {
            let last = cfgTakeOperand(p, f, &block.value, &mut live)
            if last != 0 { return last }
        }
        if block.term == 1 {
            // Every owned Text must have been moved out or dropped by now.
            // A reference parameter does not own its referent.
            for v in 0..vars {
                if live[v] && !p.var_ref[func.first_var + v] && p.types_code[func.first_var + v] == cfgTextType() { return 59 }
            }
        }
    }
    return 0
}

pub fn cfgVerify(p: &CfgProgram) -> Int {
    if p.error != 0 { return p.error }
    let calls = cfgCheckCalls(p)
    if calls != 0 { return calls }
    for f in 0..p.functions.length {
        let result = cfgCheckFunction(p, f)
        if result != 0 { return result }
    }
    return 0
}
