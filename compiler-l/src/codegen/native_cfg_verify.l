import native_cfg_types
import native_cfg_defs
import native_cfg_ir
import native_cfg_ref
import native_cfg_paths

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
    return inst.kind != 6 && inst.kind != 10 && inst.kind != 12 && inst.kind != 13 && inst.kind != 17
}

fn cfgResultType(func: &CfgFunc) -> Int {
    return func.result_type
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
        for n in 0..inst.argc {
            let arg = &p.struct_args[inst.arg_first + n]
            if cfgMoveOperand(p, f, &arg, variable) { return true }
        }
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
    if inst.kind == 5 || inst.kind == 6 || inst.kind == 8 || inst.kind == 9 || inst.kind == 12 || inst.kind == 14 || inst.kind == 15 || ((inst.kind == 13 || inst.kind == 17) && inst.op < 0) {
        if inst.place_var < 0 || inst.place_var >= p.functions[f].vars || !live[inst.place_var] { return 57 }
    }
    if inst.kind == 1 && inst.a.is_var && inst.a.value == inst.dst && cfgOperandType(p, f, &inst.a) >= 2 {
        return 58
    }
    if (inst.kind == 10 || inst.kind == 12 || inst.kind == 13 || inst.kind == 17) && inst.op >= 0 {
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
    if inst.kind == 4 {
        // Consume left to right: duplicate moves in one constructor fail.
        for n in 0..inst.argc {
            let arg = &p.struct_args[inst.arg_first + n]
            let taken = cfgTakeOperand(p, f, &arg, &mut live)
            if taken != 0 { return taken }
        }
    }
    let reads_a = inst.kind == 1 || inst.kind == 2 || inst.kind == 6 || inst.kind == 15 || inst.kind == 16
    if reads_a || (inst.kind == 7 && inst.argc == 1) {
        let a = cfgTakeOperand(p, f, &inst.a, &mut live)
        if a != 0 { return a }
    }
    if inst.kind == 2 {
        let b = cfgTakeOperand(p, f, &inst.b, &mut live)
        if b != 0 { return b }
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

// State of path `k` after `inst`, from its state before (see native_cfg_paths).
fn cfgPathAfter(p: &CfgProgram, f: Int, paths: &CfgPaths, inst: &CfgInst, k: Int, before: Bool) -> Bool {
    let v = paths.var_of[k]
    var live = before
    if cfgMoves(p, f, &inst, v) { live = false }
    // Moving a field out of an owned shape, or releasing its Text, kills
    // the paths inside it. Through a reference a read is a copy.
    if inst.kind == 5 && inst.place_var == v && inst.place_field >= 0 && !p.var_ref[p.functions[f].first_var + v] {
        let place = CfgPlace(variable: v, field: inst.place_field, subfield: inst.place_subfield)
        let moved = cfgPlaceType(p, f, &place)
        if (moved >= 2 || moved == cfgTextType()) && cfgPathWithin(paths, k, v, inst.place_field, inst.place_subfield) { live = false }
    }
    if inst.kind == 17 && inst.place_var == v && cfgPathWithin(paths, k, v, inst.place_field, inst.place_subfield) { live = false }
    if inst.kind == 6 && inst.place_var == v && inst.place_field >= 0 {
        if cfgPathWithin(paths, k, v, inst.place_field, inst.place_subfield) { live = true }
    }
    if cfgHasDst(inst) && inst.dst == v { live = true }
    return live
}

fn cfgTransferPath(p: &CfgProgram, f: Int, paths: &CfgPaths, block: &CfgBlock, k: Int, initial: Bool) -> Bool {
    var live = initial
    for i in block.first..(block.first + block.count) {
        let inst = &p.insts[i]
        live = cfgPathAfter(p, f, paths, &inst, k, live)
    }
    return live
}

fn cfgWholeLive(paths: &CfgPaths, vars: Int, live: &List<Bool>, op: &NativeOperand) -> Bool {
    if !op.is_var { return true }
    return cfgPathsLive(paths, vars, live, op.value, -1, -1)
}

// Every place and whole value that `inst` uses still has its moved-out
// paths initialized; a store needs only the enclosing field of a subfield.
fn cfgPathUses(p: &CfgProgram, f: Int, paths: &CfgPaths, inst: &CfgInst, live: &List<Bool>) -> Bool {
    let vars = p.functions[f].vars
    if paths.var_of.length == 0 { return true }
    if !cfgWholeLive(paths, vars, live, &inst.a) || !cfgWholeLive(paths, vars, live, &inst.b) { return false }
    if !cfgWholeLive(paths, vars, live, &inst.c) || !cfgWholeLive(paths, vars, live, &inst.d) { return false }
    if inst.kind == 4 {
        for n in 0..inst.argc {
            let arg = &p.struct_args[inst.arg_first + n]
            if !cfgWholeLive(paths, vars, live, &arg) { return false }
        }
    }
    if inst.kind == 3 {
        for n in 0..inst.argc {
            let k = inst.arg_first + n
            let arg = &p.call_args[k]
            if p.call_ref[k] < 0 {
                if !cfgWholeLive(paths, vars, live, &arg) { return false }
            } else if !cfgPathsLive(paths, vars, live, arg.value, p.call_field[k], p.call_sub[k]) {
                return false
            }
        }
    }
    let reads_place = inst.kind == 5 || inst.kind == 14 || inst.kind == 15 || (inst.kind == 17 && inst.op < 0)
    if reads_place && !cfgPathsLive(paths, vars, live, inst.place_var, inst.place_field, inst.place_subfield) { return false }
    let whole_place = inst.kind == 8 || inst.kind == 9 || inst.kind == 12 || inst.kind == 13
    if whole_place && !cfgPathsLive(paths, vars, live, inst.place_var, -1, -1) { return false }
    let projected_source = (inst.kind == 10 || inst.kind == 12) && inst.op >= 0
    if projected_source && !cfgPathsLive(paths, vars, live, inst.op, inst.src_field, inst.src_sub) { return false }
    if inst.kind == 6 && inst.place_subfield >= 0 {
        for k in 0..paths.var_of.length {
            let enclosing = paths.var_of[k] == inst.place_var && paths.field[k] == inst.place_field && paths.sub[k] < 0
            if enclosing && !live[vars + k] { return false }
        }
    }
    return true
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

    // Bits 0..vars are variables; bits vars.. are the move paths of their
    // aggregate fields (native_cfg_paths). Parameters arrive whole.
    let paths = cfgPathsOf(p, f)
    let bits = vars + paths.var_of.length
    var inputs: List<Bool> = List[]
    var outputs: List<Bool> = List[]
    for b in 0..blocks {
        for v in 0..bits {
            var initial = true
            if b == 0 && v < vars { initial = v < func.params }
            if b == 0 && v >= vars { initial = paths.var_of[v - vars] < func.params }
            inputs.push(initial)
            outputs.push(true)
        }
    }
    changing = true
    var iterations = 0
    while changing {
        iterations += 1
        if iterations > blocks * bits + blocks + 2 { return 56 }
        changing = false
        for b in 0..blocks {
            let block = &p.blocks[func.first_block + b]
            for v in 0..bits {
                var is_init = true
                if b == 0 && v < vars { is_init = v < func.params }
                if b == 0 && v >= vars { is_init = paths.var_of[v - vars] < func.params }
                // Entry can also have backedges. Intersect with their
                // states rather than assuming every iteration begins with
                // fresh parameters; moving a parameter in a loop must not
                // silently reinitialize it.
                for pred in 0..blocks {
                    if cfgEdge(p, f, pred, b) && !outputs[pred * bits + v] {
                        is_init = false
                    }
                }
                let slot = b * bits + v
                if inputs[slot] != is_init { inputs[slot] = is_init; changing = true }
                var after = is_init
                if v < vars {
                    after = cfgTransferVar(p, f, &block, v, is_init)
                } else {
                    after = cfgTransferPath(p, f, &paths, &block, v - vars, is_init)
                }
                if outputs[slot] != after { outputs[slot] = after; changing = true }
            }
        }
    }

    for b in 0..blocks {
        let block = &p.blocks[func.first_block + b]
        var live: List<Bool> = List[]
        for v in 0..bits { live.push(inputs[b * bits + v]) }
        for i in block.first..(block.first + block.count) {
            let inst = &p.insts[i]
            // A use of a moved-out field, or of a partially moved value.
            if !cfgPathUses(p, f, &paths, &inst, &live) { return 57 }
            // Storing over a live Text, or giving a new value to a variable
            // that still owns one in a field, would leak it.
            if inst.kind == 6 && cfgTextLiveWithin(&paths, vars, &live, inst.place_var, inst.place_field, inst.place_subfield) { return 59 }
            if cfgHasDst(inst) && live[inst.dst] && cfgTextLiveWithin(&paths, vars, &live, inst.dst, -1, -1) { return 59 }
            for k in 0..paths.var_of.length {
                live[vars + k] = cfgPathAfter(p, f, &paths, &inst, k, live[vars + k])
            }
            let error = cfgValidateInstruction(p, f, &inst, &mut live)
            if error != 0 { return error }
        }
        if block.term == 1 || block.term == 3 {
            if !cfgWholeLive(&paths, vars, &live, &block.value) { return 57 }
            let last = cfgTakeOperand(p, f, &block.value, &mut live)
            if last != 0 { return last }
        }
        if block.term == 1 {
            // A Text field still owned by a live variable leaks; a referent
            // must be given back whole.
            for k in 0..paths.var_of.length {
                let root = paths.var_of[k]
                if paths.text[k] && p.var_ref[func.first_var + root] && !live[vars + k] { return 95 }
                if paths.text[k] && !p.var_ref[func.first_var + root] && live[root] && live[vars + k] { return 59 }
            }
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
