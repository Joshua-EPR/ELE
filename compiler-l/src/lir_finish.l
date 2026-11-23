take tokens
take flow_cfg
take drops_plan
take lir_build

// Final form of a lowered function. Instructions are grouped per CFG block
// in execution order; the drop plan is spliced in: an operation anchored
// before event `e` runs before the first instruction emitted after `e`, an
// operation anchored after `e` before the first instruction emitted after
// `e + 1`. Drop flags become Bool variables. Every block gets a terminator.

expose shape LirBody {
    order: List of[Int]
    first: List of[Int]
    count: List of[Int]
    term: List of[Int]
    ta: List of[Int]
    tb: List of[Int]
    top: List of[Int]
    flag_vars: List of[Int]
}

flow lirFinishPlace(l: edit LirFn, graph: view FlowGraph, field_local: view List of[Int], path: Int) => Int {
    when path < 0 || path >= graph.paths.length { give -1 }
    hold parent = graph.paths[path].parent
    when parent < 0 {
        hold slot = lirPathVar(l, path)
        when slot < 0 { give -1 }
        give lirPlaceVar(edit l, slot)
    }
    hold base = lirFinishPlace(edit l, graph, field_local, parent)
    when base < 0 { give -1 }
    give lirPlaceField(edit l, base, field_local[graph.paths[path].field])
}

// Append one drop-plan operation to the block as LIR instructions.
flow lirFinishOp(l: edit LirFn, body: edit LirBody, graph: view FlowGraph, field_local: view List of[Int], plan: view DropPlan, index: Int, block: Int, pos: Int) {
    hold op = view plan.ops[index]
    l.at = graph.events.length
    when op.event >= 0 && op.event < graph.events.length { l.at = graph.events[op.event].start }
    change flag = -1
    when op.flag >= 0 && op.flag < body.flag_vars.length { flag = body.flag_vars[op.flag] }
    when op.kind == DROP_OP_SET || op.kind == DROP_OP_CLEAR {
        change value = 0
        when op.kind == DROP_OP_SET { value = 1 }
        hold constant = lirConst(edit l, LIR_CONST_BOOL, value, 0, 0)
        lirEmit(edit l, LIR_USE, flag, constant, 0, 0, block, pos)
        body.order@push(l.insts.length - 1)
        give
    }
    hold place = lirFinishPlace(edit l, graph, field_local, op.path)
    when place < 0 { give }
    when op.kind == DROP_OP_COND && flag < 0 { give }
    hold guard = flag
    when op.kind == DROP_OP_REF {
        // Storing through a reference root releases the old referent in
        // the backend (Stage 0 ABI); a field behind it is dropped here.
        when l.places[place].parent < 0 { give }
        lirEmit(edit l, LIR_DROPFIELD, -1, place, -1, 0, block, pos)
    } otherwise when l.places[place].parent < 0 {
        hold root = l.places[place].root
        lirEmit(edit l, LIR_DROP, root, guard, 0, 0, block, pos)
    } otherwise {
        lirEmit(edit l, LIR_DROPFIELD, -1, place, guard, 0, block, pos)
    }
    body.order@push(l.insts.length - 1)
}

flow lirOpKey(plan: view DropPlan, index: Int) => Int {
    hold op = view plan.ops[index]
    when op.event < 0 { give -1 }
    when op.after { give op.event + 1 }
    give op.event
}

expose flow lirFinish(l: edit LirFn, graph: view FlowGraph, plan: view DropPlan, field_local: view List of[Int]) => LirBody {
    hold blocks = graph.blocks.length
    change body = LirBody(order: List[], first: List[], count: List[], term: List[], ta: List[], tb: List[], top: List[], flag_vars: List[])
    lirBlocks(edit l, blocks)
    each f among 0..plan.flag_paths.length { body.flag_vars@push(lirVar(edit l, 4, false)) }
    // Bucket the emitted instructions by block, keeping emission order.
    change bucket_first: List of[Int] = List[]
    change bucket_fill: List of[Int] = List[]
    change bucket: List of[Int] = List[]
    each b among 0..(blocks + 1) {
        bucket_first@push(0)
        bucket_fill@push(0)
    }
    hold emitted = l.insts.length
    each i among 0..emitted { bucket_first[l.insts[i].block + 1] += 1 }
    each b among 0..blocks { bucket_first[b + 1] += bucket_first[b] }
    each i among 0..emitted { bucket@push(-1) }
    each i among 0..emitted {
        hold b = l.insts[i].block
        bucket[bucket_first[b] + bucket_fill[b]] = i
        bucket_fill[b] += 1
    }
    each b among 0..blocks {
        body.first@push(body.order.length)
        hold reached = b < graph.reached.length && graph.reached[b]
        when reached {
            change op_i = 0
            change op_end = 0
            when b < plan.block_first.length {
                op_i = plan.block_first[b]
                op_end = op_i + plan.block_count[b]
            }
            each k among 0..bucket_fill[b] {
                hold inst = bucket[bucket_first[b] + k]
                hold pos = l.insts[inst].pos
                during op_i < op_end && lirOpKey(plan, op_i) < pos {
                    lirFinishOp(edit l, edit body, graph, field_local, plan, op_i, b, pos)
                    op_i += 1
                }
                body.order@push(inst)
            }
            during op_i < op_end {
                lirFinishOp(edit l, edit body, graph, field_local, plan, op_i, b, graph.events.length)
                op_i += 1
            }
        }
        body.count@push(body.order.length - body.first[b])
        lirFinishTerm(edit l, edit body, graph, b, reached)
    }
    give body
}

flow lirFinishTerm(l: edit LirFn, body: edit LirBody, graph: view FlowGraph, b: Int, reached: Bool) {
    hold a = graph.blocks[b].next_a
    hold c = graph.blocks[b].next_b
    change kind = LIR_T_UNREACHABLE
    change ta = -1
    change tb = -1
    change top = LIR_NONE
    when !reached {
        kind = LIR_T_UNREACHABLE
    } otherwise when graph.blocks[b].returned {
        kind = LIR_T_RETURN
        when l.ret_ref[b] { kind = LIR_T_RETURNREF }
        top = l.ret[b]
    } otherwise when a >= 0 && c >= 0 {
        kind = LIR_T_BRANCH
        top = l.cond[b]
        ta = a
        tb = c
        when l.swap[b] {
            ta = c
            tb = a
        }
    } otherwise when a >= 0 {
        kind = LIR_T_JUMP
        ta = a
    } otherwise {
        // Falling off the end of a function returning unit.
        kind = LIR_T_RETURN
        top = lirConst(edit l, LIR_CONST_UNIT, 0, 0, 0)
    }
    body.term@push(kind)
    body.ta@push(ta)
    body.tb@push(tb)
    body.top@push(top)
}
