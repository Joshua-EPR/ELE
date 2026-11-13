import tokens
import flow_cfg
import drops_plan
import lir_build

// Final form of a lowered function. Instructions are grouped per CFG block
// in execution order; the drop plan is spliced in: an operation anchored
// before event `e` runs before the first instruction emitted after `e`, an
// operation anchored after `e` before the first instruction emitted after
// `e + 1`. Drop flags become Bool variables. Every block gets a terminator.

pub struct LirBody {
    order: List<Int>
    first: List<Int>
    count: List<Int>
    term: List<Int>
    ta: List<Int>
    tb: List<Int>
    top: List<Int>
    flag_vars: List<Int>
}

fn lirFinishPlace(l: &mut LirFn, graph: &FlowGraph, field_local: &List<Int>, path: Int) -> Int {
    if path < 0 || path >= graph.paths.length { return -1 }
    let parent = graph.paths[path].parent
    if parent < 0 {
        let slot = lirPathVar(l, path)
        if slot < 0 { return -1 }
        return lirPlaceVar(&mut l, slot)
    }
    let base = lirFinishPlace(&mut l, graph, field_local, parent)
    if base < 0 { return -1 }
    return lirPlaceField(&mut l, base, field_local[graph.paths[path].field])
}

// Append one drop-plan operation to the block as LIR instructions.
fn lirFinishOp(l: &mut LirFn, body: &mut LirBody, graph: &FlowGraph, field_local: &List<Int>, plan: &DropPlan, index: Int, block: Int, pos: Int) {
    let op = &plan.ops[index]
    l.at = graph.events.length
    if op.event >= 0 && op.event < graph.events.length { l.at = graph.events[op.event].start }
    var flag = -1
    if op.flag >= 0 && op.flag < body.flag_vars.length { flag = body.flag_vars[op.flag] }
    if op.kind == DROP_OP_SET || op.kind == DROP_OP_CLEAR {
        var value = 0
        if op.kind == DROP_OP_SET { value = 1 }
        let constant = lirConst(&mut l, LIR_CONST_BOOL, value, 0, 0)
        lirEmit(&mut l, LIR_USE, flag, constant, 0, 0, block, pos)
        body.order.push(l.insts.length - 1)
        return
    }
    let place = lirFinishPlace(&mut l, graph, field_local, op.path)
    if place < 0 { return }
    if op.kind == DROP_OP_COND && flag < 0 { return }
    let guard = flag
    if op.kind == DROP_OP_REF {
        // Storing through a reference root releases the old referent in
        // the backend (Stage 0 ABI); a field behind it is dropped here.
        if l.places[place].parent < 0 { return }
        lirEmit(&mut l, LIR_DROPFIELD, -1, place, -1, 0, block, pos)
    } else if l.places[place].parent < 0 {
        let root = l.places[place].root
        lirEmit(&mut l, LIR_DROP, root, guard, 0, 0, block, pos)
    } else {
        lirEmit(&mut l, LIR_DROPFIELD, -1, place, guard, 0, block, pos)
    }
    body.order.push(l.insts.length - 1)
}

fn lirOpKey(plan: &DropPlan, index: Int) -> Int {
    let op = &plan.ops[index]
    if op.event < 0 { return -1 }
    if op.after { return op.event + 1 }
    return op.event
}

fn lirFinish(l: &mut LirFn, graph: &FlowGraph, plan: &DropPlan, field_local: &List<Int>) -> LirBody {
    let blocks = graph.blocks.length
    var body = LirBody(order: List[], first: List[], count: List[], term: List[], ta: List[], tb: List[], top: List[], flag_vars: List[])
    lirBlocks(&mut l, blocks)
    for f in 0..plan.flag_paths.length { body.flag_vars.push(lirVar(&mut l, 4, false)) }
    // Bucket the emitted instructions by block, keeping emission order.
    var bucket_first: List<Int> = List[]
    var bucket_fill: List<Int> = List[]
    var bucket: List<Int> = List[]
    for b in 0..(blocks + 1) {
        bucket_first.push(0)
        bucket_fill.push(0)
    }
    let emitted = l.insts.length
    for i in 0..emitted { bucket_first[l.insts[i].block + 1] += 1 }
    for b in 0..blocks { bucket_first[b + 1] += bucket_first[b] }
    for i in 0..emitted { bucket.push(-1) }
    for i in 0..emitted {
        let b = l.insts[i].block
        bucket[bucket_first[b] + bucket_fill[b]] = i
        bucket_fill[b] += 1
    }
    for b in 0..blocks {
        body.first.push(body.order.length)
        let reached = b < graph.reached.length && graph.reached[b]
        if reached {
            var op_i = 0
            var op_end = 0
            if b < plan.block_first.length {
                op_i = plan.block_first[b]
                op_end = op_i + plan.block_count[b]
            }
            for k in 0..bucket_fill[b] {
                let inst = bucket[bucket_first[b] + k]
                let pos = l.insts[inst].pos
                while op_i < op_end && lirOpKey(plan, op_i) < pos {
                    lirFinishOp(&mut l, &mut body, graph, field_local, plan, op_i, b, pos)
                    op_i += 1
                }
                body.order.push(inst)
            }
            while op_i < op_end {
                lirFinishOp(&mut l, &mut body, graph, field_local, plan, op_i, b, graph.events.length)
                op_i += 1
            }
        }
        body.count.push(body.order.length - body.first[b])
        lirFinishTerm(&mut l, &mut body, graph, b, reached)
    }
    return body
}

fn lirFinishTerm(l: &mut LirFn, body: &mut LirBody, graph: &FlowGraph, b: Int, reached: Bool) {
    let a = graph.blocks[b].next_a
    let c = graph.blocks[b].next_b
    var kind = LIR_T_UNREACHABLE
    var ta = -1
    var tb = -1
    var top = LIR_NONE
    if !reached {
        kind = LIR_T_UNREACHABLE
    } else if graph.blocks[b].returned {
        kind = LIR_T_RETURN
        if l.ret_ref[b] { kind = LIR_T_RETURNREF }
        top = l.ret[b]
    } else if a >= 0 && c >= 0 {
        kind = LIR_T_BRANCH
        top = l.cond[b]
        ta = a
        tb = c
        if l.swap[b] {
            ta = c
            tb = a
        }
    } else if a >= 0 {
        kind = LIR_T_JUMP
        ta = a
    } else {
        // Falling off the end of a function returning unit.
        kind = LIR_T_RETURN
        top = lirConst(&mut l, LIR_CONST_UNIT, 0, 0, 0)
    }
    body.term.push(kind)
    body.ta.push(ta)
    body.tb.push(tb)
    body.top.push(top)
}
