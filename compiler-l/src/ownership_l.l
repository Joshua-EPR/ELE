take flow_cfg

expose fixed FLOW_UNINIT = 0
expose fixed FLOW_LIVE = 1
fixed FLOW_MOVED = 2
expose fixed FLOW_MAYBE = 3

shape FlowCheck {
    status: Int
    start: Int
    end: Int
    iterations: Int
    // Status 4: the linear type id of the leaf that would be dropped.
    linear: Int
}

shape FlowWork {
    incoming: List of[Int]
    reached: List of[Bool]
    pending: List of[Bool]
    queue: List of[Int]
    scratch: List of[Int]
}

flow flowWorkNew(blocks: Int, paths: Int) => FlowWork {
    change incoming: List of[Int] = List[]
    change reached: List of[Bool] = List[]
    change pending: List of[Bool] = List[]
    change queue: List of[Int] = List[]
    change scratch: List of[Int] = List[]
    incoming@reserve(blocks * paths)
    each i among 0..(blocks * paths) { incoming@push(FLOW_UNINIT) }
    each i among 0..blocks {
        reached@push(i == 0)
        pending@push(i == 0)
    }
    each i among 0..paths { scratch@push(FLOW_UNINIT) }
    queue@push(0)
    give FlowWork(incoming: incoming, reached: reached, pending: pending, queue: queue, scratch: scratch)
}

flow flowJoin(work: edit FlowWork, target: Int, paths: Int) {
    when target < 0 { give }
    hold first = !work.reached[target]
    change changed = first
    hold offset = target * paths
    each i among 0..paths {
        hold current = work.incoming[offset + i]
        hold arriving = work.scratch[i]
        when first {
            work.incoming[offset + i] = arriving
        } otherwise when current != arriving && current != FLOW_MAYBE {
            work.incoming[offset + i] = FLOW_MAYBE
            changed = true
        }
    }
    work.reached[target] = true
    when changed && !work.pending[target] {
        work.pending[target] = true
        work.queue@push(target)
    }
}

flow flowLoad(work: edit FlowWork, block: Int, paths: Int) {
    hold offset = block * paths
    each i among 0..paths { work.scratch[i] = work.incoming[offset + i] }
}

// A path's own cell represents its residual storage. Descendants have
// separate cells so a moved field does not invalidate a sibling.
expose flow flowApply(graph: view FlowGraph, state: edit List of[Int], event: view FlowEvent, verify: Bool) => Bool {
    hold kind = event.kind
    hold root = event.path
    // Loan events belong to the borrow checker in loans_check.l. A drop
    // ends the lifetime of whatever the path still owns.
    when kind == FLOW_DROP {
        change dropped = root
        during dropped >= 0 {
            state[dropped] = FLOW_UNINIT
            dropped = flowNextPath(graph, root, dropped)
        }
        give true
    }
    when kind == FLOW_MUTATE {
        change current = root
        during current >= 0 {
            when verify && state[current] != FLOW_LIVE { give false }
            current = flowNextPath(graph, root, current)
        }
        give true
    }
    when kind > FLOW_WRITE { give true }
    when verify && kind == FLOW_WRITE {
        change ancestor = graph.paths[root].parent
        during ancestor >= 0 {
            when state[ancestor] != FLOW_LIVE { give false }
            ancestor = graph.paths[ancestor].parent
        }
    }
    change path = root
    during path >= 0 {
        when verify && (kind == FLOW_READ || kind == FLOW_MOVE) && state[path] != FLOW_LIVE {
            give false
        }
        when kind == FLOW_MOVE {
            state[path] = FLOW_MOVED
        } otherwise when kind == FLOW_INIT || kind == FLOW_WRITE {
            state[path] = FLOW_LIVE
        }
        path = flowNextPath(graph, root, path)
    }
    give true
}

flow flowIsLinear(graph: view FlowGraph, ty: Int) => Bool {
    each i among 0..graph.linear_types.length {
        when graph.linear_types[i] == ty { give true }
    }
    give false
}

// The linear type of a leaf under `root` that dropping `root` would release
// while it is still owned on some path into this point (FLOW_LIVE or
// FLOW_MAYBE), or -1.
flow flowDropsLinear(graph: view FlowGraph, state: view List of[Int], root: Int) => Int {
    when graph.linear_types.length == 0 || root < 0 || root >= graph.paths.length { give -1 }
    change leaf = root
    during leaf >= 0 {
        when leaf < graph.drop_types.length && flowIsLinear(graph, graph.drop_types[leaf]) {
            hold s = state[leaf]
            when s == FLOW_LIVE || s == FLOW_MAYBE { give graph.drop_types[leaf] }
        }
        leaf = flowNextPath(graph, root, leaf)
    }
    give -1
}

// A write to an owned place releases its old value, just like a scope drop.
// A write through `edit` instead releases the referent; its binding path is
// a reference and therefore has no owned drop leaf. The event carries the
// referent type so it cannot evade the linear check through that binding.
flow flowReleasesLinear(graph: view FlowGraph, state: view List of[Int], event: view FlowEvent) => Int {
    when event.kind == FLOW_DROP_REF {
        when flowIsLinear(graph, event.data) { give event.data }
        give -1
    }
    when event.kind == FLOW_DROP { give flowDropsLinear(graph, state, event.path) }
    when event.kind == FLOW_WRITE {
        give flowDropsLinear(graph, state, event.path)
    }
    give -1
}

expose flow flowVerify(graph: edit FlowGraph, requires_return: Bool) => FlowCheck {
    hold paths = graph.paths.length
    hold blocks = graph.blocks.length
    when paths > 2000000 / blocks {
        give FlowCheck(status: 2, start: 0, end: 0, iterations: 0, linear: -1)
    }
    change work = flowWorkNew(blocks, paths)
    change steps = 0
    during work.queue.length > 0 {
        change id = 0
        choose work.queue@pop() {
            Some(next_block) : { id = next_block }
            None : { leave }
        }
        steps += 1
        when steps > 100000 {
            give FlowCheck(status: 2, start: 0, end: 0, iterations: steps, linear: -1)
        }
        work.pending[id] = false
        flowLoad(edit work, id, paths)
        hold block = view graph.blocks[id]
        change event = block.first
        during event >= 0 {
            hold instruction = view graph.events[event]
            flowApply(graph, edit work.scratch, instruction, false)
            event = instruction.next
        }
        flowJoin(edit work, block.next_a, paths)
        flowJoin(edit work, block.next_b, paths)
    }
    each id among 0..blocks {
        when work.reached[id] {
            flowLoad(edit work, id, paths)
            hold block = view graph.blocks[id]
            change event = block.first
            during event >= 0 {
                hold instruction = view graph.events[event]
                hold leaked = flowReleasesLinear(graph, view work.scratch, instruction)
                when leaked >= 0 {
                    give FlowCheck(status: 4, start: instruction.start, end: instruction.end, iterations: steps, linear: leaked)
                }
                when !flowApply(graph, edit work.scratch, instruction, true) {
                    give FlowCheck(status: 1, start: instruction.start, end: instruction.end, iterations: steps, linear: -1)
                }
                event = instruction.next
            }
            when requires_return && block.next_a < 0 && !block.returned {
                give FlowCheck(status: 3, start: 0, end: 0, iterations: steps, linear: -1)
            }
        }
    }
    // Keep the converged entry states for drop elaboration.
    graph.entry = work.incoming
    graph.reached = work.reached
    give FlowCheck(status: 0, start: 0, end: 0, iterations: steps, linear: -1)
}
