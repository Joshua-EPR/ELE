import tokens
import flow_cfg
import loans_l
import drops_plan

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

struct DropVerdict {
    status: Int
    iterations: Int
}

fn dropBit(mask: Int, bit: Int) -> Int {
    return (mask / bit) % 2
}

fn dropPack(nf: Int, yf: Int, nt: Int, yt: Int) -> Int {
    var m = 0
    if nf > 0 { m += 1 }
    if yf > 0 { m += 2 }
    if nt > 0 { m += 4 }
    if yt > 0 { m += 8 }
    return m
}

fn dropOwns(mask: Int, yes: Bool) -> Int {
    let f = dropBit(mask, 1) + dropBit(mask, 2)
    let t = dropBit(mask, 4) + dropBit(mask, 8)
    if yes { return dropPack(0, f, 0, t) }
    return dropPack(f, 0, t, 0)
}

fn dropFlag(mask: Int, value: Bool) -> Int {
    let n = dropBit(mask, 1) + dropBit(mask, 4)
    let y = dropBit(mask, 2) + dropBit(mask, 8)
    if value { return dropPack(0, 0, n, y) }
    return dropPack(n, y, 0, 0)
}

fn dropAllYes(mask: Int) -> Bool {
    return mask != 0 && dropBit(mask, 1) == 0 && dropBit(mask, 4) == 0
}

fn dropAllNo(mask: Int) -> Bool {
    return dropBit(mask, 2) == 0 && dropBit(mask, 8) == 0
}

// Apply an event to every leaf under its path. Returns a status.
fn dropVerifyEvent(graph: &FlowGraph, cells: &mut List<Int>, kind: Int, root: Int, paths: Int, check: Bool) -> Int {
    if root < 0 || root >= paths { return 0 }
    let owner = loanOfPath(graph, root) < 0
    var leaf = root
    while leaf >= 0 {
        if leaf < paths && flowDropType(graph, leaf) >= 0 {
            let mask = cells[leaf]
            if kind == FLOW_INIT || (kind == FLOW_WRITE && owner) {
                if check && !dropAllNo(mask) { return 5 }
                cells[leaf] = dropOwns(mask, true)
            } else if kind == FLOW_MOVE {
                if check && !dropAllYes(mask) { return 6 }
                cells[leaf] = dropOwns(mask, false)
            } else if kind == FLOW_DROP {
                if check && !dropAllNo(mask) { return 7 }
            }
        }
        leaf = flowNextPath(graph, root, leaf)
    }
    return 0
}

fn dropVerifyOp(graph: &FlowGraph, plan: &DropPlan, cells: &mut List<Int>, id: Int, block: Int, paths: Int, check: Bool) -> Int {
    let op = &plan.ops[id]
    if op.block != block || op.path < 0 || op.path >= paths { return 1 }
    if op.kind == DROP_OP_REF {
        if loanOfPath(graph, op.path) < 0 { return 10 }
        return 0
    }
    if flowDropType(graph, op.path) < 0 { return 1 }
    let mask = cells[op.path]
    if op.kind == DROP_OP_DROP {
        if check && !dropAllYes(mask) { return 2 }
        cells[op.path] = dropOwns(mask, false)
        return 0
    }
    if op.flag < 0 || op.flag >= plan.flag_paths.length || plan.flag_paths[op.flag] != op.path { return 3 }
    if op.kind == DROP_OP_COND {
        if check && (dropBit(mask, 2) == 1 || dropBit(mask, 4) == 1) { return 4 }
        cells[op.path] = dropOwns(mask, false)
    } else if op.kind == DROP_OP_SET {
        cells[op.path] = dropFlag(mask, true)
    } else if op.kind == DROP_OP_CLEAR {
        cells[op.path] = dropFlag(mask, false)
    } else {
        return 1
    }
    return 0
}

// Replay one block: entry operations, then each event with the
// operations anchored before and after it.
fn dropVerifyBlock(graph: &FlowGraph, plan: &DropPlan, cells: &mut List<Int>, block: Int, paths: Int, check: Bool) -> Int {
    var i = plan.block_first[block]
    let end = i + plan.block_count[block]
    while i < end && plan.ops[i].event == -1 {
        let status = dropVerifyOp(graph, plan, &mut cells, i, block, paths, check)
        if status != 0 { return status }
        i += 1
    }
    var event = graph.blocks[block].first
    while event >= 0 {
        while i < end && plan.ops[i].event == event && !plan.ops[i].after {
            let status = dropVerifyOp(graph, plan, &mut cells, i, block, paths, check)
            if status != 0 { return status }
            i += 1
        }
        let ev = &graph.events[event]
        let status = dropVerifyEvent(graph, &mut cells, ev.kind, ev.path, paths, check)
        if status != 0 { return status }
        while i < end && plan.ops[i].event == event && plan.ops[i].after {
            let status = dropVerifyOp(graph, plan, &mut cells, i, block, paths, check)
            if status != 0 { return status }
            i += 1
        }
        event = ev.next
    }
    if i != end { return 9 }
    if check && graph.blocks[block].next_a < 0 && graph.blocks[block].next_b < 0 {
        for leaf in 0..paths {
            if flowDropType(graph, leaf) >= 0 && !dropAllNo(cells[leaf]) { return 8 }
        }
    }
    return 0
}

fn dropMerge(table: &mut List<Int>, cells: &List<Int>, target: Int, paths: Int, seen: &mut List<Bool>) -> Bool {
    if target < 0 { return false }
    let offset = target * paths
    var changed = !seen[target]
    seen[target] = true
    for i in 0..paths {
        let old = table[offset + i]
        let arriving = cells[i]
        // Bitwise OR without bit operators; equal or empty cells are the
        // common case and skip the arithmetic.
        var merged = old
        if old == 0 {
            merged = arriving
        } else if arriving != 0 && arriving != old {
            merged = old + arriving - dropPack(dropBit(old, 1) * dropBit(arriving, 1), dropBit(old, 2) * dropBit(arriving, 2), dropBit(old, 4) * dropBit(arriving, 4), dropBit(old, 8) * dropBit(arriving, 8))
        }
        if merged != old {
            table[offset + i] = merged
            changed = true
        }
    }
    return changed
}

fn dropVerify(graph: &FlowGraph, plan: &DropPlan) -> DropVerdict {
    let blocks = graph.blocks.length
    if blocks == 0 || graph.reached.length != blocks { return DropVerdict(status: 0, iterations: 0) }
    let paths = graph.entry.length / blocks
    if plan.block_first.length != blocks { return DropVerdict(status: 1, iterations: 0) }
    var table: List<Int> = List[]
    var seen: List<Bool> = List[]
    var pending: List<Bool> = List[]
    var queue: List<Int> = List[]
    var cells: List<Int> = List[]
    table.reserve(blocks * paths)
    for i in 0..(blocks * paths) { table.push(0) }
    for b in 0..blocks {
        seen.push(b == 0)
        pending.push(b == 0)
    }
    for i in 0..paths {
        table[i] = 1
        cells.push(0)
    }
    queue.push(0)
    var steps = 0
    while queue.length > 0 {
        var block = 0
        match queue.pop() {
            Some(b) => { block = b }
            None => { break }
        }
        pending[block] = false
        steps += 1
        if steps > 100000 { return DropVerdict(status: 11, iterations: steps) }
        for i in 0..paths { cells[i] = table[block * paths + i] }
        let status = dropVerifyBlock(graph, plan, &mut cells, block, paths, false)
        if status != 0 { return DropVerdict(status: status, iterations: steps) }
        let a = graph.blocks[block].next_a
        let b = graph.blocks[block].next_b
        if dropMerge(&mut table, &cells, a, paths, &mut seen) && !pending[a] {
            pending[a] = true
            queue.push(a)
        }
        if dropMerge(&mut table, &cells, b, paths, &mut seen) && !pending[b] {
            pending[b] = true
            queue.push(b)
        }
    }
    for block in 0..blocks {
        if seen[block] {
            if !graph.reached[block] { return DropVerdict(status: 1, iterations: steps) }
            for i in 0..paths { cells[i] = table[block * paths + i] }
            let status = dropVerifyBlock(graph, plan, &mut cells, block, paths, true)
            if status != 0 { return DropVerdict(status: status, iterations: steps) }
        }
    }
    return DropVerdict(status: 0, iterations: steps)
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
fn dropInjectFault(graph: &FlowGraph, plan: &mut DropPlan, fault: Int) -> Bool {
    var target = -1
    for i in 0..plan.ops.length {
        if target < 0 {
            let kind = plan.ops[i].kind
            if (fault == 1 || fault == 2 || fault == 6 || fault == 7) && kind == DROP_OP_DROP { target = i }
            if fault == 3 && kind == DROP_OP_COND { target = i }
            if fault == 4 && (kind == DROP_OP_SET || kind == DROP_OP_CLEAR) { target = i }
            if fault == 5 && kind == DROP_OP_SET { target = i }
        }
    }
    if target < 0 { return false }
    let block = plan.ops[target].block
    if fault == 1 {
        let copy = &plan.ops[target]
        let twin = DropOp(kind: copy.kind, path: copy.path, flag: copy.flag, block: copy.block, event: copy.event, after: copy.after, ty: copy.ty)
        plan.ops.push(twin)
        // Shift the later operations up by one so the twin follows its copy.
        var i = plan.ops.length - 1
        while i > target + 1 {
            let prev = &plan.ops[i - 1]
            let shifted = DropOp(kind: prev.kind, path: prev.path, flag: prev.flag, block: prev.block, event: prev.event, after: prev.after, ty: prev.ty)
            plan.ops[i] = shifted
            i -= 1
        }
        plan.block_count[block] += 1
        for b in (block + 1)..plan.block_first.length { plan.block_first[b] += 1 }
    } else if fault == 2 || fault == 5 {
        // Shift the later operations down by one, then drop the last slot.
        var i = target
        while i + 1 < plan.ops.length {
            let next = &plan.ops[i + 1]
            let shifted = DropOp(kind: next.kind, path: next.path, flag: next.flag, block: next.block, event: next.event, after: next.after, ty: next.ty)
            plan.ops[i] = shifted
            i += 1
        }
        plan.ops.pop()
        plan.block_count[block] -= 1
        for b in (block + 1)..plan.block_first.length { plan.block_first[b] -= 1 }
    } else if fault == 3 {
        plan.ops[target].kind = DROP_OP_DROP
    } else if fault == 4 {
        plan.ops[target].flag = plan.flag_paths.length
    } else if fault == 6 {
        plan.ops[target].block = block + 1
    } else if fault == 7 {
        let parent = graph.paths[plan.ops[target].path].parent
        if parent < 0 { return false }
        plan.ops[target].path = parent
    }
    return true
}
