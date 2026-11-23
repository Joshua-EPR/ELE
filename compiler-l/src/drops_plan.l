take tokens
take flow_cfg
take ownership_l
take loans_l

// Drop elaboration for Stage 1. Input: the function CFG with its
// FLOW_DROP / FLOW_DROP_REF events (sema_drop.l) and the converged entry
// states of the ownership solver (ownership_l.l). Output: a backend
// independent DropPlan, a list of operations anchored to CFG events.
//
// Per leaf path that needs a drop, the state at each point is the one the
// ownership solver already proved: LIVE -> unconditional drop, MAYBE ->
// drop guarded by a dynamic flag, MOVED/UNINIT -> nothing. A flag exists
// only for leaves that are MAYBE at some drop point; it is cleared at
// function entry, set when the leaf is initialized or written and cleared
// when it is moved or dropped (Stage 0 `drops::elaborate`).

expose fixed DROP_OP_DROP = 0
expose fixed DROP_OP_COND = 1
expose fixed DROP_OP_SET = 2
expose fixed DROP_OP_CLEAR = 3
expose fixed DROP_OP_REF = 4

expose shape DropOp {
    kind: Int
    // Leaf path (DROP, COND, SET, CLEAR) or written place (REF).
    path: Int
    flag: Int
    block: Int
    // Anchor event; -1 means the entry of the block (flag prologue).
    event: Int
    // Runs after the anchor event instead of before it.
    after: Bool
    ty: Int
}

expose shape DropPlan {
    ops: List of[DropOp]
    flag_of: List of[Int]
    flag_paths: List of[Int]
    block_first: List of[Int]
    block_count: List of[Int]
    drops: Int
}

flow dropPush(plan: edit DropPlan, kind: Int, path: Int, flag: Int, block: Int, event: Int, after: Bool, ty: Int) {
    plan.ops@push(DropOp(kind: kind, path: path, flag: flag, block: block, event: event, after: after, ty: ty))
    when kind == DROP_OP_DROP || kind == DROP_OP_COND || kind == DROP_OP_REF { plan.drops += 1 }
}

flow dropLoad(graph: view FlowGraph, state: edit List of[Int], block: Int, paths: Int) {
    hold offset = block * paths
    each i among 0..paths { state[i] = graph.entry[offset + i] }
}

// Release what the leaves under `root` still own, in preorder (Stage 0
// order), before `event`.
flow dropLeaves(graph: view FlowGraph, plan: edit DropPlan, state: view List of[Int], root: Int, block: Int, event: Int, paths: Int) {
    change leaf = root
    during leaf >= 0 {
        hold ty = flowDropType(graph, leaf)
        when ty >= 0 && leaf < paths {
            hold flag = plan.flag_of[leaf]
            when state[leaf] == FLOW_LIVE {
                dropPush(edit plan, DROP_OP_DROP, leaf, -1, block, event, false, ty)
            } otherwise when state[leaf] == FLOW_MAYBE {
                dropPush(edit plan, DROP_OP_COND, leaf, flag, block, event, false, ty)
            }
            when flag >= 0 && (state[leaf] == FLOW_LIVE || state[leaf] == FLOW_MAYBE) {
                dropPush(edit plan, DROP_OP_CLEAR, leaf, flag, block, event, false, ty)
            }
        }
        leaf = flowNextPath(graph, root, leaf)
    }
}

// Keep the flags of the leaves under `root` equal to "owns a value".
flow dropFlags(graph: view FlowGraph, plan: edit DropPlan, root: Int, kind: Int, block: Int, event: Int, paths: Int) {
    change leaf = root
    during leaf >= 0 {
        when leaf < paths && plan.flag_of[leaf] >= 0 {
            // Snapshot immutable metadata before mutating the drop plan.
            hold flag = plan.flag_of[leaf]
            hold ty = flowDropType(graph, leaf)
            dropPush(edit plan, kind, leaf, flag, block, event, true, ty)
        }
        leaf = flowNextPath(graph, root, leaf)
    }
}

// Does this event release owned leaves under its path?
flow dropReleases(graph: view FlowGraph, kind: Int, path: Int) => Bool {
    when kind == FLOW_DROP { give true }
    give kind == FLOW_WRITE && loanOfPath(graph, path) < 0
}

// Pass 1: a leaf needs a flag when it is MAYBE where it is released.
flow dropFindFlags(graph: view FlowGraph, plan: edit DropPlan, state: edit List of[Int], paths: Int) {
    each block among 0..graph.blocks.length {
        when graph.reached[block] {
            dropLoad(graph, edit state, block, paths)
            change event = graph.blocks[block].first
            during event >= 0 {
                hold ev = view graph.events[event]
                when ev.path >= 0 && dropReleases(graph, ev.kind, ev.path) {
                    change leaf = ev.path
                    during leaf >= 0 {
                        when leaf < paths && flowDropType(graph, leaf) >= 0 && state[leaf] == FLOW_MAYBE && plan.flag_of[leaf] < 0 {
                            plan.flag_of[leaf] = plan.flag_paths.length
                            plan.flag_paths@push(leaf)
                        }
                        leaf = flowNextPath(graph, ev.path, leaf)
                    }
                }
                flowApply(graph, edit state, ev, false)
                event = ev.next
            }
        }
    }
}

expose flow dropElaborate(graph: view FlowGraph) => DropPlan {
    change plan = DropPlan(ops: List[], flag_of: List[], flag_paths: List[], block_first: List[], block_count: List[], drops: 0)
    hold blocks = graph.blocks.length
    each i among 0..graph.paths.length { plan.flag_of@push(-1) }
    when blocks == 0 || graph.reached.length != blocks { give plan }
    hold paths = graph.entry.length / blocks
    change state: List of[Int] = List[]
    each i among 0..paths { state@push(FLOW_UNINIT) }
    dropFindFlags(graph, edit plan, edit state, paths)
    each block among 0..blocks {
        plan.block_first@push(plan.ops.length)
        when graph.reached[block] {
            when block == 0 {
                each f among 0..plan.flag_paths.length {
                    hold leaf = plan.flag_paths[f]
                    dropPush(edit plan, DROP_OP_CLEAR, leaf, f, 0, -1, false, flowDropType(graph, leaf))
                }
            }
            dropLoad(graph, edit state, block, paths)
            change event = graph.blocks[block].first
            during event >= 0 {
                hold ev = view graph.events[event]
                hold kind = ev.kind
                hold path = ev.path
                when path >= 0 && path < paths {
                    when dropReleases(graph, kind, path) {
                        dropLeaves(graph, edit plan, view state, path, block, event, paths)
                    }
                    when kind == FLOW_DROP_REF {
                        dropPush(edit plan, DROP_OP_REF, path, -1, block, event, false, ev.data)
                    }
                    when kind == FLOW_INIT || (kind == FLOW_WRITE && loanOfPath(graph, path) < 0) {
                        dropFlags(graph, edit plan, path, DROP_OP_SET, block, event, paths)
                    }
                    when kind == FLOW_MOVE {
                        dropFlags(graph, edit plan, path, DROP_OP_CLEAR, block, event, paths)
                    }
                }
                flowApply(graph, edit state, ev, false)
                event = ev.next
            }
        }
        plan.block_count@push(plan.ops.length - plan.block_first[block])
    }
    give plan
}
