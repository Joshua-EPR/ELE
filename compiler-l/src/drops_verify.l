take tokens
take flow_cfg
take loans_l
take drops_plan

// Independent verifier of a DropPlan. It does not trust the ownership
// solver: it recomputes, per drop leaf, the set of possible (owns, flag)
// pairs from the raw CFG events and the plan operations, then checks every
// operation (Stage 0 `drops::verify` rules):
//   1 invalid id, block or leaf          6 move of a value not owned
//   2 drop of a value not surely owned   7 scope ends with an owned leaf
//   3 flag missing or of another leaf    8 function exit with an owned leaf
//   4 flag differs from ownership        9 operation anchored elsewhere
//   5 init or write over an owned leaf  10 REF drop not through a reference
//  11 analysis limit
// A cell is a 4-bit mask: 1 = (no, false), 2 = (yes, false),
// 4 = (no, true), 8 = (yes, true).

shape DropVerdict {
    status: Int
    iterations: Int
}

flow dropBit(mask: Int, bit: Int) => Int {
    give (mask / bit) % 2
}

flow dropPack(nf: Int, yf: Int, nt: Int, yt: Int) => Int {
    change m = 0
    when nf > 0 { m += 1 }
    when yf > 0 { m += 2 }
    when nt > 0 { m += 4 }
    when yt > 0 { m += 8 }
    give m
}

flow dropOwns(mask: Int, yes: Bool) => Int {
    hold f = dropBit(mask, 1) + dropBit(mask, 2)
    hold t = dropBit(mask, 4) + dropBit(mask, 8)
    when yes { give dropPack(0, f, 0, t) }
    give dropPack(f, 0, t, 0)
}

flow dropFlag(mask: Int, value: Bool) => Int {
    hold n = dropBit(mask, 1) + dropBit(mask, 4)
    hold y = dropBit(mask, 2) + dropBit(mask, 8)
    when value { give dropPack(0, 0, n, y) }
    give dropPack(n, y, 0, 0)
}

flow dropAllYes(mask: Int) => Bool {
    give mask != 0 && dropBit(mask, 1) == 0 && dropBit(mask, 4) == 0
}

flow dropAllNo(mask: Int) => Bool {
    give dropBit(mask, 2) == 0 && dropBit(mask, 8) == 0
}

// Apply an event to every leaf under its path. Returns a status.
flow dropVerifyEvent(graph: view FlowGraph, cells: edit List of[Int], kind: Int, root: Int, paths: Int, check: Bool) => Int {
    when root < 0 || root >= paths { give 0 }
    hold owner = loanOfPath(graph, root) < 0
    change leaf = root
    during leaf >= 0 {
        when leaf < paths && flowDropType(graph, leaf) >= 0 {
            hold mask = cells[leaf]
            when kind == FLOW_INIT || (kind == FLOW_WRITE && owner) {
                when check && !dropAllNo(mask) { give 5 }
                cells[leaf] = dropOwns(mask, true)
            } otherwise when kind == FLOW_MOVE {
                when check && !dropAllYes(mask) { give 6 }
                cells[leaf] = dropOwns(mask, false)
            } otherwise when kind == FLOW_DROP {
                when check && !dropAllNo(mask) { give 7 }
            }
        }
        leaf = flowNextPath(graph, root, leaf)
    }
    give 0
}

flow dropVerifyOp(graph: view FlowGraph, plan: view DropPlan, cells: edit List of[Int], id: Int, block: Int, paths: Int, check: Bool) => Int {
    hold op = view plan.ops[id]
    when op.block != block || op.path < 0 || op.path >= paths { give 1 }
    when op.kind == DROP_OP_REF {
        when loanOfPath(graph, op.path) < 0 { give 10 }
        give 0
    }
    when flowDropType(graph, op.path) < 0 { give 1 }
    hold mask = cells[op.path]
    when op.kind == DROP_OP_DROP {
        when check && !dropAllYes(mask) { give 2 }
        cells[op.path] = dropOwns(mask, false)
        give 0
    }
    when op.flag < 0 || op.flag >= plan.flag_paths.length || plan.flag_paths[op.flag] != op.path { give 3 }
    when op.kind == DROP_OP_COND {
        when check && (dropBit(mask, 2) == 1 || dropBit(mask, 4) == 1) { give 4 }
        cells[op.path] = dropOwns(mask, false)
    } otherwise when op.kind == DROP_OP_SET {
        cells[op.path] = dropFlag(mask, true)
    } otherwise when op.kind == DROP_OP_CLEAR {
        cells[op.path] = dropFlag(mask, false)
    } otherwise {
        give 1
    }
    give 0
}

// Replay one block: entry operations, then each event with the
// operations anchored before and after it.
flow dropVerifyBlock(graph: view FlowGraph, plan: view DropPlan, cells: edit List of[Int], block: Int, paths: Int, check: Bool) => Int {
    change i = plan.block_first[block]
    hold end = i + plan.block_count[block]
    during i < end && plan.ops[i].event == -1 {
        hold status = dropVerifyOp(graph, plan, edit cells, i, block, paths, check)
        when status != 0 { give status }
        i += 1
    }
    change event = graph.blocks[block].first
    during event >= 0 {
        during i < end && plan.ops[i].event == event && !plan.ops[i].after {
            hold status = dropVerifyOp(graph, plan, edit cells, i, block, paths, check)
            when status != 0 { give status }
            i += 1
        }
        hold ev = view graph.events[event]
        hold status = dropVerifyEvent(graph, edit cells, ev.kind, ev.path, paths, check)
        when status != 0 { give status }
        during i < end && plan.ops[i].event == event && plan.ops[i].after {
            hold status = dropVerifyOp(graph, plan, edit cells, i, block, paths, check)
            when status != 0 { give status }
            i += 1
        }
        event = ev.next
    }
    when i != end { give 9 }
    when check && graph.blocks[block].next_a < 0 && graph.blocks[block].next_b < 0 {
        each leaf among 0..paths {
            when flowDropType(graph, leaf) >= 0 && !dropAllNo(cells[leaf]) { give 8 }
        }
    }
    give 0
}

flow dropMerge(table: edit List of[Int], cells: view List of[Int], target: Int, paths: Int, seen: edit List of[Bool]) => Bool {
    when target < 0 { give false }
    hold offset = target * paths
    change changed = !seen[target]
    seen[target] = true
    each i among 0..paths {
        hold old = table[offset + i]
        hold arriving = cells[i]
        // Bitwise OR without bit operators; equal or empty cells are the
        // common case and skip the arithmetic.
        change merged = old
        when old == 0 {
            merged = arriving
        } otherwise when arriving != 0 && arriving != old {
            merged = old + arriving - dropPack(dropBit(old, 1) * dropBit(arriving, 1), dropBit(old, 2) * dropBit(arriving, 2), dropBit(old, 4) * dropBit(arriving, 4), dropBit(old, 8) * dropBit(arriving, 8))
        }
        when merged != old {
            table[offset + i] = merged
            changed = true
        }
    }
    give changed
}

expose flow dropVerify(graph: view FlowGraph, plan: view DropPlan) => DropVerdict {
    hold blocks = graph.blocks.length
    when blocks == 0 || graph.reached.length != blocks { give DropVerdict(status: 0, iterations: 0) }
    hold paths = graph.entry.length / blocks
    when plan.block_first.length != blocks { give DropVerdict(status: 1, iterations: 0) }
    change table: List of[Int] = List[]
    change seen: List of[Bool] = List[]
    change pending: List of[Bool] = List[]
    change queue: List of[Int] = List[]
    change cells: List of[Int] = List[]
    table@reserve(blocks * paths)
    each i among 0..(blocks * paths) { table@push(0) }
    each b among 0..blocks {
        seen@push(b == 0)
        pending@push(b == 0)
    }
    each i among 0..paths {
        table[i] = 1
        cells@push(0)
    }
    queue@push(0)
    change steps = 0
    during queue.length > 0 {
        change block = 0
        choose queue@pop() {
            Some(b) : { block = b }
            None : { leave }
        }
        pending[block] = false
        steps += 1
        when steps > 100000 { give DropVerdict(status: 11, iterations: steps) }
        each i among 0..paths { cells[i] = table[block * paths + i] }
        hold status = dropVerifyBlock(graph, plan, edit cells, block, paths, false)
        when status != 0 { give DropVerdict(status: status, iterations: steps) }
        hold a = graph.blocks[block].next_a
        hold b = graph.blocks[block].next_b
        when dropMerge(edit table, view cells, a, paths, edit seen) && !pending[a] {
            pending[a] = true
            queue@push(a)
        }
        when dropMerge(edit table, view cells, b, paths, edit seen) && !pending[b] {
            pending[b] = true
            queue@push(b)
        }
    }
    each block among 0..blocks {
        when seen[block] {
            when !graph.reached[block] { give DropVerdict(status: 1, iterations: steps) }
            each i among 0..paths { cells[i] = table[block * paths + i] }
            hold status = dropVerifyBlock(graph, plan, edit cells, block, paths, true)
            when status != 0 { give DropVerdict(status: status, iterations: steps) }
        }
    }
    give DropVerdict(status: 0, iterations: steps)
}

// Test hook (`sema-l archivo.l --drop-fault=K`): corrupt a correct plan in
// one well-defined way so the tests can prove that the verifier rejects
// it. Returns false when the plan has nothing to corrupt.
//   1 duplicate the first drop (double drop)
//   2 delete the first drop (leak)
//   3 make the first conditional drop unconditional
//   4 give the first flag operation another flag
//   5 delete the first flag set (flag out of sync)
//   6 anchor the first drop to another block
//   7 aim the first drop at the root of a partly owned struct
expose flow dropInjectFault(graph: view FlowGraph, plan: edit DropPlan, fault: Int) => Bool {
    change target = -1
    each i among 0..plan.ops.length {
        when target < 0 {
            hold kind = plan.ops[i].kind
            when (fault == 1 || fault == 2 || fault == 6 || fault == 7) && kind == DROP_OP_DROP { target = i }
            when fault == 3 && kind == DROP_OP_COND { target = i }
            when fault == 4 && (kind == DROP_OP_SET || kind == DROP_OP_CLEAR) { target = i }
            when fault == 5 && kind == DROP_OP_SET { target = i }
        }
    }
    when target < 0 { give false }
    hold block = plan.ops[target].block
    when fault == 1 {
        hold copy = view plan.ops[target]
        hold twin = DropOp(kind: copy.kind, path: copy.path, flag: copy.flag, block: copy.block, event: copy.event, after: copy.after, ty: copy.ty)
        plan.ops@push(twin)
        // Shift the later operations up by one so the twin follows its copy.
        change i = plan.ops.length - 1
        during i > target + 1 {
            hold prev = view plan.ops[i - 1]
            hold shifted = DropOp(kind: prev.kind, path: prev.path, flag: prev.flag, block: prev.block, event: prev.event, after: prev.after, ty: prev.ty)
            plan.ops[i] = shifted
            i -= 1
        }
        plan.block_count[block] += 1
        each b among (block + 1)..plan.block_first.length { plan.block_first[b] += 1 }
    } otherwise when fault == 2 || fault == 5 {
        // Shift the later operations down by one, then drop the last slot.
        change i = target
        during i + 1 < plan.ops.length {
            hold next = view plan.ops[i + 1]
            hold shifted = DropOp(kind: next.kind, path: next.path, flag: next.flag, block: next.block, event: next.event, after: next.after, ty: next.ty)
            plan.ops[i] = shifted
            i += 1
        }
        plan.ops@pop()
        plan.block_count[block] -= 1
        each b among (block + 1)..plan.block_first.length { plan.block_first[b] -= 1 }
    } otherwise when fault == 3 {
        plan.ops[target].kind = DROP_OP_DROP
    } otherwise when fault == 4 {
        plan.ops[target].flag = plan.flag_paths.length
    } otherwise when fault == 6 {
        plan.ops[target].block = block + 1
    } otherwise when fault == 7 {
        hold parent = graph.paths[plan.ops[target].path].parent
        when parent < 0 { give false }
        plan.ops[target].path = parent
    }
    give true
}
