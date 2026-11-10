import tokens
import flow_cfg
import ownership_l
import loans_l

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

const DROP_OP_DROP = 0
const DROP_OP_COND = 1
const DROP_OP_SET = 2
const DROP_OP_CLEAR = 3
const DROP_OP_REF = 4

struct DropOp {
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

struct DropPlan {
    ops: List<DropOp>
    flag_of: List<Int>
    flag_paths: List<Int>
    block_first: List<Int>
    block_count: List<Int>
    drops: Int
}

fn dropPush(plan: &mut DropPlan, kind: Int, path: Int, flag: Int, block: Int, event: Int, after: Bool, ty: Int) {
    plan.ops.push(DropOp(kind: kind, path: path, flag: flag, block: block, event: event, after: after, ty: ty))
    if kind == DROP_OP_DROP || kind == DROP_OP_COND || kind == DROP_OP_REF { plan.drops += 1 }
}

fn dropLoad(graph: &FlowGraph, state: &mut List<Int>, block: Int, paths: Int) {
    let offset = block * paths
    for i in 0..paths { state[i] = graph.entry[offset + i] }
}

// Release what the leaves under `root` still own, in preorder (Stage 0
// order), before `event`.
fn dropLeaves(graph: &FlowGraph, plan: &mut DropPlan, state: &List<Int>, root: Int, block: Int, event: Int, paths: Int) {
    var leaf = root
    while leaf >= 0 {
        let ty = flowDropType(graph, leaf)
        if ty >= 0 && leaf < paths {
            let flag = plan.flag_of[leaf]
            if state[leaf] == FLOW_LIVE {
                dropPush(&mut plan, DROP_OP_DROP, leaf, -1, block, event, false, ty)
            } else if state[leaf] == FLOW_MAYBE {
                dropPush(&mut plan, DROP_OP_COND, leaf, flag, block, event, false, ty)
            }
            if flag >= 0 && (state[leaf] == FLOW_LIVE || state[leaf] == FLOW_MAYBE) {
                dropPush(&mut plan, DROP_OP_CLEAR, leaf, flag, block, event, false, ty)
            }
        }
        leaf = flowNextPath(graph, root, leaf)
    }
}

// Keep the flags of the leaves under `root` equal to "owns a value".
fn dropFlags(graph: &FlowGraph, plan: &mut DropPlan, root: Int, kind: Int, block: Int, event: Int, paths: Int) {
    var leaf = root
    while leaf >= 0 {
        if leaf < paths && plan.flag_of[leaf] >= 0 {
            dropPush(&mut plan, kind, leaf, plan.flag_of[leaf], block, event, true, flowDropType(graph, leaf))
        }
        leaf = flowNextPath(graph, root, leaf)
    }
}

// Does this event release owned leaves under its path?
fn dropReleases(graph: &FlowGraph, kind: Int, path: Int) -> Bool {
    if kind == FLOW_DROP { return true }
    return kind == FLOW_WRITE && loanOfPath(graph, path) < 0
}

// Pass 1: a leaf needs a flag when it is MAYBE where it is released.
fn dropFindFlags(graph: &FlowGraph, plan: &mut DropPlan, state: &mut List<Int>, paths: Int) {
    for block in 0..graph.blocks.length {
        if graph.reached[block] {
            dropLoad(graph, &mut state, block, paths)
            var event = graph.blocks[block].first
            while event >= 0 {
                let ev = &graph.events[event]
                if ev.path >= 0 && dropReleases(graph, ev.kind, ev.path) {
                    var leaf = ev.path
                    while leaf >= 0 {
                        if leaf < paths && flowDropType(graph, leaf) >= 0 && state[leaf] == FLOW_MAYBE && plan.flag_of[leaf] < 0 {
                            plan.flag_of[leaf] = plan.flag_paths.length
                            plan.flag_paths.push(leaf)
                        }
                        leaf = flowNextPath(graph, ev.path, leaf)
                    }
                }
                flowApply(graph, &mut state, ev, false)
                event = ev.next
            }
        }
    }
}

fn dropElaborate(graph: &FlowGraph) -> DropPlan {
    var plan = DropPlan(ops: List[], flag_of: List[], flag_paths: List[], block_first: List[], block_count: List[], drops: 0)
    let blocks = graph.blocks.length
    for i in 0..graph.paths.length { plan.flag_of.push(-1) }
    if blocks == 0 || graph.reached.length != blocks { return plan }
    let paths = graph.entry.length / blocks
    var state: List<Int> = List[]
    for i in 0..paths { state.push(FLOW_UNINIT) }
    dropFindFlags(graph, &mut plan, &mut state, paths)
    for block in 0..blocks {
        plan.block_first.push(plan.ops.length)
        if graph.reached[block] {
            if block == 0 {
                for f in 0..plan.flag_paths.length {
                    let leaf = plan.flag_paths[f]
                    dropPush(&mut plan, DROP_OP_CLEAR, leaf, f, 0, -1, false, flowDropType(graph, leaf))
                }
            }
            dropLoad(graph, &mut state, block, paths)
            var event = graph.blocks[block].first
            while event >= 0 {
                let ev = &graph.events[event]
                let kind = ev.kind
                let path = ev.path
                if path >= 0 && path < paths {
                    if dropReleases(graph, kind, path) {
                        dropLeaves(graph, &mut plan, &state, path, block, event, paths)
                    }
                    if kind == FLOW_DROP_REF {
                        dropPush(&mut plan, DROP_OP_REF, path, -1, block, event, false, ev.data)
                    }
                    if kind == FLOW_INIT || (kind == FLOW_WRITE && loanOfPath(graph, path) < 0) {
                        dropFlags(graph, &mut plan, path, DROP_OP_SET, block, event, paths)
                    }
                    if kind == FLOW_MOVE {
                        dropFlags(graph, &mut plan, path, DROP_OP_CLEAR, block, event, paths)
                    }
                }
                flowApply(graph, &mut state, ev, false)
                event = ev.next
            }
        }
        plan.block_count.push(plan.ops.length - plan.block_first[block])
    }
    return plan
}
