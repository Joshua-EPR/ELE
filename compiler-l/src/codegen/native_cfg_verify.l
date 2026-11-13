take native_cfg_types
take native_cfg_defs
take native_cfg_ir
take native_cfg_ref
take native_cfg_paths
take native_cfg_list
take native_cfg_loan

// Flow-sensitive definedness and whole-value move validation for the
// restricted native backend. Every struct is MOVE-only in ELE even if it
// contains only Int/Bool. Physical field copying is permitted solely to
// implement a semantically validated move (source is invalidated).
// Partial moves of struct-valued fields are rejected by the parser.
// States converge with intersection at joins, including loop backedges.

flow cfgEdge(p: view CfgProgram, f: Int, from: Int, to: Int) => Bool {
    hold block = view p.blocks[p.functions[f].first_block + from]
    when block.term == 2 { give block.yes == to }
    when block.term == 3 { give block.yes == to || block.no == to }
    give false
}

flow cfgHasDst(inst: view CfgInst) => Bool {
    give inst.kind != 6 && inst.kind != 10 && inst.kind != 12 && inst.kind != 13 && inst.kind != 17 && inst.kind != 19 && inst.kind != 20
}

flow cfgResultType(func: view CfgFunc) => Int {
    give func.result_type
}

// `i payload` of a shape/choice payload: a move, not a copy, because
// aggregates are move-only in ELE even when drop-free.
flow cfgPayloadMoves(p: view CfgProgram, f: Int, inst: view CfgInst) => Bool {
    when inst.kind != 9 || inst.dst < 0 || inst.dst >= p.functions[f].vars { give false }
    give p.types_code[p.functions[f].first_var + inst.dst] >= 2
}

flow cfgMoveOperand(p: view CfgProgram, f: Int, op: view NativeOperand, variable: Int) => Bool {
    give op.is_var && op.value == variable && cfgIsMove(cfgOperandType(p, f, view op))
}

// A whole-value move occurs in a struct assignment, struct constructor or
// store of a struct-valued field, in a Text passed by value to a call and
// in a drop. Primitive values are Copy.
flow cfgMoves(p: view CfgProgram, f: Int, inst: view CfgInst, variable: Int) => Bool {
    when inst.kind == 13 { give inst.place_var == variable }
    when inst.kind == 3 {
        each n among 0..inst.argc {
            hold arg = view p.call_args[inst.arg_first + n]
            when p.call_ref[inst.arg_first + n] < 0 && cfgMoveOperand(p, f, view arg, variable) { give true }
        }
        give false
    }
    when inst.kind == 1 || inst.kind == 6 || inst.kind == 19 {
        give cfgMoveOperand(p, f, view inst.a, variable)
    }
    when inst.kind == 7 && inst.argc == 1 {
        give cfgMoveOperand(p, f, view inst.a, variable)
    }
    // Extracting an aggregate payload moves the whole owned enum out.
    when inst.kind == 9 && inst.place_var == variable { give cfgPayloadMoves(p, f, inst) }
    when inst.kind == 4 || inst.kind == 18 {
        each n among 0..inst.argc {
            hold arg = view p.struct_args[inst.arg_first + n]
            when cfgMoveOperand(p, f, view arg, variable) { give true }
        }
    }
    give false
}

// Local reference `variable` stops being valid at `inst`: its root is moved,
// dropped or redefined, or overlapping storage is written (native_cfg_loan).
flow cfgLoanDies(p: view CfgProgram, f: Int, inst: view CfgInst, variable: Int) => Bool {
    hold slot = p.functions[f].first_var + variable
    when !p.var_ref[slot] || variable < p.functions[f].params { give false }
    hold root = p.ref_root[slot]
    when root < 0 { give false }
    when cfgMoves(p, f, view inst, root) { give true }
    when cfgHasDst(inst) && inst.dst == root { give true }
    give cfgLoanKilledBy(p, f, inst, variable)
}

// Transfer for a single definitely-initialized bit, evaluated in
// instruction order. This models moves as KILL and assignments as GEN.
flow cfgTransferVar(p: view CfgProgram, f: Int, block: view CfgBlock, variable: Int, initial: Bool) => Bool {
    change live = initial
    each i among block.first..(block.first + block.count) {
        hold inst = view p.insts[i]
        when cfgMoves(p, f, view inst, variable) { live = false }
        when cfgLoanDies(p, f, view inst, variable) { live = false }
        when cfgHasDst(inst) && inst.dst == variable { live = true }
    }
    give live
}

flow cfgTakeOperand(p: view CfgProgram, f: Int, op: view NativeOperand, live: edit List of[Bool]) => Int {
    when !op.is_var { give 0 }
    when op.value < 0 || op.value >= p.functions[f].vars { give 57 }
    when !live[op.value] { give 57 }
    when cfgIsMove(cfgOperandType(p, f, view op)) { live[op.value] = false }
    give 0
}

// Validate every instruction in execution order. This rejects double moves
// within one constructor, uses after moves, and move-out-before-return.
flow cfgValidateInstruction(p: view CfgProgram, f: Int, inst: view CfgInst, live: edit List of[Bool]) => Int {
    when inst.kind == 5 || inst.kind == 6 || inst.kind == 8 || inst.kind == 9 || inst.kind == 12 || inst.kind == 14 || inst.kind == 15 || inst.kind == 19 || inst.kind == 20 || inst.kind == 21 || inst.kind == 22 || ((inst.kind == 13 || inst.kind == 17) && inst.op < 0) {
        when inst.place_var < 0 || inst.place_var >= p.functions[f].vars || !live[inst.place_var] { give 57 }
    }
    // The index variables of a place are read before the instruction runs.
    when !cfgExtLive(p, inst.place_ext, live) || !cfgExtLive(p, inst.src_ext, live) { give 57 }
    when inst.kind == 1 && inst.a.is_var && inst.a.value == inst.dst && cfgOperandType(p, f, view inst.a) >= 2 {
        give 58
    }
    when (inst.kind == 10 || inst.kind == 12 || inst.kind == 13 || inst.kind == 17) && inst.op >= 0 {
        // A referenced source, or a drop flag, is read and stays live.
        when !live[inst.op] { give 57 }
    }
    when inst.kind == 13 {
        live[inst.place_var] = false
        give 0
    }
    // An aggregate payload is moved out: the enum is consumed (a later
    // `disc`, `payload` or use of it is a use after move).
    when inst.kind == 9 && cfgPayloadMoves(p, f, inst) { live[inst.place_var] = false }
    when inst.kind == 3 {
        each n among 0..inst.argc {
            hold arg = view p.call_args[inst.arg_first + n]
            when p.call_ref[inst.arg_first + n] >= 0 {
                // A borrowed root must be initialized and stays owned.
                when !live[arg.value] { give 57 }
                when !cfgExtLive(p, p.call_ext[inst.arg_first + n], live) { give 57 }
            } otherwise {
                hold taken = cfgTakeOperand(p, f, view arg, edit live)
                when taken != 0 { give taken }
            }
        }
    }
    when (inst.kind == 10 || inst.kind == 12) && inst.op < 0 && inst.a.is_var {
        // `print` and `append` read their source without consuming it.
        when inst.a.value < 0 || inst.a.value >= p.functions[f].vars { give 57 }
        when !live[inst.a.value] { give 57 }
    }
    when inst.kind == 4 || inst.kind == 18 {
        // Consume left to right: duplicate moves in one constructor fail.
        each n among 0..inst.argc {
            hold arg = view p.struct_args[inst.arg_first + n]
            hold taken = cfgTakeOperand(p, f, view arg, edit live)
            when taken != 0 { give taken }
        }
    }
    hold reads_a = inst.kind == 1 || inst.kind == 2 || inst.kind == 6 || inst.kind == 15 || inst.kind == 16 || inst.kind == 19 || inst.kind == 20
    when reads_a || (inst.kind == 7 && inst.argc == 1) {
        hold a = cfgTakeOperand(p, f, view inst.a, edit live)
        when a != 0 { give a }
    }
    when inst.kind == 2 {
        hold b = cfgTakeOperand(p, f, view inst.b, edit live)
        when b != 0 { give b }
    }
    when cfgHasDst(inst) {
        // Overwriting a live owned Text or list would leak its buffer. A
        // reference owns nothing: a loop may take its loan again.
        hold dst_slot = p.functions[f].first_var + inst.dst
        when live[inst.dst] && !p.var_ref[dst_slot] && cfgHeapDirect(p, p.types_code[dst_slot]) { give 59 }
        live[inst.dst] = true
    }
    give 0
}

flow cfgCheckCalls(p: view CfgProgram) => Int {
    each f among 0..p.functions.length {
        hold func = view p.functions[f]
        each b among 0..func.blocks {
            hold block = view p.blocks[func.first_block + b]
            each i among block.first..(block.first + block.count) {
                hold inst = view p.insts[i]
                when inst.kind == 3 {
                    hold callee = inst.callee
                    when callee < 0 || callee >= p.functions.length { give 51 }
                    hold target = view p.functions[callee]
                    when inst.argc != target.params { give 52 }
                    hold dst_type = p.types_code[func.first_var + inst.dst]
                    when dst_type != cfgResultType(target) { give 53 }
                    hold args = cfgCheckCallArgs(p, f, inst)
                    when args != 0 { give args }
                }
            }
        }
    }
    give 0
}

// State of path `k` after `inst`, from its state before (see native_cfg_paths).
flow cfgPathAfter(p: view CfgProgram, f: Int, paths: view CfgPaths, inst: view CfgInst, k: Int, before: Bool) => Bool {
    hold v = paths.var_of[k]
    change live = before
    when cfgMoves(p, f, view inst, v) { live = false }
    when cfgLoanDies(p, f, view inst, v) { live = false }
    // Moving a field out of an owned shape, or releasing its Text, kills
    // the paths inside it. Through a reference a read is a copy.
    when inst.kind == 5 && inst.place_ext < 0 && inst.place_var == v && inst.place_field >= 0 && !p.var_ref[p.functions[f].first_var + v] {
        hold place = CfgPlace(variable: v, field: inst.place_field, subfield: inst.place_subfield, ext: -1)
        hold moved = cfgPlaceType(p, f, view place)
        when (moved >= 2 || moved == cfgTextType()) && cfgPathWithin(paths, k, v, inst.place_field, inst.place_subfield) { live = false }
    }
    when inst.kind == 17 && inst.place_var == v && cfgPathWithin(paths, k, v, inst.place_field, inst.place_subfield) { live = false }
    // A store through an extension writes inside a list, not the path.
    when inst.kind == 6 && inst.place_ext < 0 && inst.place_var == v && inst.place_field >= 0 {
        when cfgPathWithin(paths, k, v, inst.place_field, inst.place_subfield) { live = true }
    }
    when cfgHasDst(inst) && inst.dst == v { live = true }
    give live
}

flow cfgTransferPath(p: view CfgProgram, f: Int, paths: view CfgPaths, block: view CfgBlock, k: Int, initial: Bool) => Bool {
    change live = initial
    each i among block.first..(block.first + block.count) {
        hold inst = view p.insts[i]
        live = cfgPathAfter(p, f, paths, view inst, k, live)
    }
    give live
}

flow cfgWholeLive(paths: view CfgPaths, vars: Int, live: view List of[Bool], op: view NativeOperand) => Bool {
    when !op.is_var { give true }
    give cfgPathsLive(paths, vars, live, op.value, -1, -1)
}

// Every place and whole value that `inst` uses still has its moved-out
// paths initialized; a store needs only the enclosing field of a subfield.
flow cfgPathUses(p: view CfgProgram, f: Int, paths: view CfgPaths, inst: view CfgInst, live: view List of[Bool]) => Bool {
    hold vars = p.functions[f].vars
    when paths.var_of.length == 0 { give true }
    when !cfgWholeLive(paths, vars, live, view inst.a) || !cfgWholeLive(paths, vars, live, view inst.b) { give false }
    when !cfgWholeLive(paths, vars, live, view inst.c) || !cfgWholeLive(paths, vars, live, view inst.d) { give false }
    when inst.kind == 4 || inst.kind == 18 {
        each n among 0..inst.argc {
            hold arg = view p.struct_args[inst.arg_first + n]
            when !cfgWholeLive(paths, vars, live, view arg) { give false }
        }
    }
    when inst.kind == 3 {
        each n among 0..inst.argc {
            hold k = inst.arg_first + n
            hold arg = view p.call_args[k]
            when p.call_ref[k] < 0 {
                when !cfgWholeLive(paths, vars, live, view arg) { give false }
            } otherwise when !cfgPathsLive(paths, vars, live, arg.value, p.call_field[k], p.call_sub[k]) {
                give false
            }
        }
    }
    // A place with an extension needs its whole static prefix: the list that
    // is indexed must still be there, also for a store.
    hold reads_place = inst.kind == 5 || inst.kind == 14 || inst.kind == 15 || (inst.kind == 17 && inst.op < 0) || inst.kind == 19 || inst.kind == 20 || inst.kind == 21 || inst.kind == 22 || (inst.kind == 6 && inst.place_ext >= 0)
    when reads_place && !cfgPathsLive(paths, vars, live, inst.place_var, inst.place_field, inst.place_subfield) { give false }
    hold whole_place = inst.kind == 8 || inst.kind == 9 || inst.kind == 12 || inst.kind == 13
    when whole_place && !cfgPathsLive(paths, vars, live, inst.place_var, -1, -1) { give false }
    hold projected_source = (inst.kind == 10 || inst.kind == 12) && inst.op >= 0
    when projected_source && !cfgPathsLive(paths, vars, live, inst.op, inst.src_field, inst.src_sub) { give false }
    when inst.kind == 6 && inst.place_ext < 0 && inst.place_subfield >= 0 {
        each k among 0..paths.var_of.length {
            hold enclosing = paths.var_of[k] == inst.place_var && paths.field[k] == inst.place_field && paths.sub[k] < 0
            when enclosing && !live[vars + k] { give false }
        }
    }
    give true
}

flow cfgCheckFunction(p: view CfgProgram, f: Int) => Int {
    hold func = view p.functions[f]
    hold blocks = func.blocks
    hold vars = func.vars
    change reachable: List of[Bool] = List[]
    each b among 0..blocks { reachable@push(b == 0) }
    change changing = true
    during changing {
        changing = false
        each b among 0..blocks {
            when reachable[b] {
                each target among 0..blocks {
                    when cfgEdge(p, f, b, target) && !reachable[target] {
                        reachable[target] = true
                        changing = true
                    }
                }
            }
        }
    }
    // Stage 1 emits an empty synthetic block terminated by `unreachable`
    // after paths that already returned. No other disconnected block is valid.
    each b among 0..blocks {
        when !reachable[b] {
            hold dead = view p.blocks[func.first_block + b]
            when dead.term != 4 || dead.count != 0 { give 55 }
        }
    }

    // Bits 0..vars are variables; bits vars.. are the move paths of their
    // aggregate fields (native_cfg_paths). Parameters arrive whole.
    hold paths = cfgPathsOf(p, f)
    hold bits = vars + paths.var_of.length
    change inputs: List of[Bool] = List[]
    change outputs: List of[Bool] = List[]
    each b among 0..blocks {
        each v among 0..bits {
            change initial = true
            when b == 0 && v < vars { initial = v < func.params }
            when b == 0 && v >= vars { initial = paths.var_of[v - vars] < func.params }
            inputs@push(initial)
            outputs@push(true)
        }
    }
    changing = true
    change iterations = 0
    during changing {
        iterations += 1
        when iterations > blocks * bits + blocks + 2 { give 56 }
        changing = false
        each b among 0..blocks {
            hold block = view p.blocks[func.first_block + b]
            each v among 0..bits {
                change is_init = true
                when b == 0 && v < vars { is_init = v < func.params }
                when b == 0 && v >= vars { is_init = paths.var_of[v - vars] < func.params }
                // Entry can also have backedges. Intersect with their
                // states rather than assuming every iteration begins with
                // fresh parameters; moving a parameter in a loop must not
                // silently reinitialize it.
                each pred among 0..blocks {
                    when cfgEdge(p, f, pred, b) && !outputs[pred * bits + v] {
                        is_init = false
                    }
                }
                hold slot = b * bits + v
                when inputs[slot] != is_init { inputs[slot] = is_init; changing = true }
                change after = is_init
                when v < vars {
                    after = cfgTransferVar(p, f, view block, v, is_init)
                } otherwise {
                    after = cfgTransferPath(p, f, view paths, view block, v - vars, is_init)
                }
                when outputs[slot] != after { outputs[slot] = after; changing = true }
            }
        }
    }

    each b among 0..blocks {
        hold block = view p.blocks[func.first_block + b]
        change live: List of[Bool] = List[]
        each v among 0..bits { live@push(inputs[b * bits + v]) }
        each i among block.first..(block.first + block.count) {
            hold inst = view p.insts[i]
            // A use of a moved-out field, or of a partially moved value.
            when !cfgPathUses(p, f, view paths, view inst, view live) { give 57 }
            // Storing over a live Text, or giving a new value to a variable
            // that still owns one in a field, would leak it.
            when inst.kind == 6 && inst.place_ext < 0 && cfgTextLiveWithin(view paths, vars, view live, inst.place_var, inst.place_field, inst.place_subfield) { give 59 }
            when cfgHasDst(inst) && live[inst.dst] && !p.var_ref[func.first_var + inst.dst] && cfgTextLiveWithin(view paths, vars, view live, inst.dst, -1, -1) { give 59 }
            each k among 0..paths.var_of.length {
                live[vars + k] = cfgPathAfter(p, f, view paths, view inst, k, live[vars + k])
            }
            hold error = cfgValidateInstruction(p, f, view inst, edit live)
            when error != 0 { give error }
            // References into storage that this instruction moved or wrote die.
            each v among func.params..vars {
                when live[v] && cfgLoanDies(p, f, view inst, v) { live[v] = false }
            }
        }
        when block.term == 1 || block.term == 3 {
            when !cfgWholeLive(view paths, vars, view live, view block.value) { give 57 }
            hold last = cfgTakeOperand(p, f, view block.value, edit live)
            when last != 0 { give last }
        }
        when block.term == 1 {
            // A Text field still owned by a live variable leaks; a referent
            // must be given back whole.
            each k among 0..paths.var_of.length {
                hold root = paths.var_of[k]
                when paths.text[k] && root < func.params && p.var_ref[func.first_var + root] && !live[vars + k] { give 95 }
                when paths.text[k] && !p.var_ref[func.first_var + root] && live[root] && live[vars + k] { give 59 }
            }
            // Every owned Text or list must have been moved out or dropped by now.
            // A reference parameter does not own its referent.
            each v among 0..vars {
                when live[v] && !p.var_ref[func.first_var + v] && cfgHeapDirect(p, p.types_code[func.first_var + v]) { give 59 }
            }
        }
    }
    give 0
}

expose flow cfgVerify(p: view CfgProgram) => Int {
    when p.error != 0 { give p.error }
    hold calls = cfgCheckCalls(p)
    when calls != 0 { give calls }
    each f among 0..p.functions.length {
        hold modes = cfgCheckLoanModes(p, f)
        when modes != 0 { give modes }
        hold result = cfgCheckFunction(p, f)
        when result != 0 { give result }
    }
    give 0
}
