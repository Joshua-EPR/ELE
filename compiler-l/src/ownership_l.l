import flow_cfg

const FLOW_UNINIT = 0
pub const FLOW_LIVE = 1
const FLOW_MOVED = 2
pub const FLOW_MAYBE = 3

struct FlowCheck {
    status: Int
    start: Int
    end: Int
    iterations: Int
}

struct FlowWork {
    incoming: List<Int>
    reached: List<Bool>
    pending: List<Bool>
    queue: List<Int>
    scratch: List<Int>
}

fn flowWorkNew(blocks: Int, paths: Int) -> FlowWork {
    var incoming: List<Int> = List[]
    var reached: List<Bool> = List[]
    var pending: List<Bool> = List[]
    var queue: List<Int> = List[]
    var scratch: List<Int> = List[]
    incoming.reserve(blocks * paths)
    for i in 0..(blocks * paths) { incoming.push(FLOW_UNINIT) }
    for i in 0..blocks {
        reached.push(i == 0)
        pending.push(i == 0)
    }
    for i in 0..paths { scratch.push(FLOW_UNINIT) }
    queue.push(0)
    return FlowWork(incoming: incoming, reached: reached, pending: pending, queue: queue, scratch: scratch)
}

fn flowJoin(work: &mut FlowWork, target: Int, paths: Int) {
    if target < 0 { return }
    let first = !work.reached[target]
    var changed = first
    let offset = target * paths
    for i in 0..paths {
        let current = work.incoming[offset + i]
        let arriving = work.scratch[i]
        if first {
            work.incoming[offset + i] = arriving
        } else if current != arriving && current != FLOW_MAYBE {
            work.incoming[offset + i] = FLOW_MAYBE
            changed = true
        }
    }
    work.reached[target] = true
    if changed && !work.pending[target] {
        work.pending[target] = true
        work.queue.push(target)
    }
}

fn flowLoad(work: &mut FlowWork, block: Int, paths: Int) {
    let offset = block * paths
    for i in 0..paths { work.scratch[i] = work.incoming[offset + i] }
}

// A path's own cell represents its residual storage. Descendants have
// separate cells so a moved field does not invalidate a sibling.
fn flowApply(graph: &FlowGraph, state: &mut List<Int>, event: &FlowEvent, verify: Bool) -> Bool {
    let kind = event.kind
    let root = event.path
    // Loan events belong to the borrow checker in loans_check.l. A drop
    // ends the lifetime of whatever the path still owns.
    if kind == FLOW_DROP {
        var dropped = root
        while dropped >= 0 {
            state[dropped] = FLOW_UNINIT
            dropped = flowNextPath(graph, root, dropped)
        }
        return true
    }
    if kind == FLOW_MUTATE {
        var current = root
        while current >= 0 {
            if verify && state[current] != FLOW_LIVE { return false }
            current = flowNextPath(graph, root, current)
        }
        return true
    }
    if kind > FLOW_WRITE { return true }
    if verify && kind == FLOW_WRITE {
        var ancestor = graph.paths[root].parent
        while ancestor >= 0 {
            if state[ancestor] != FLOW_LIVE { return false }
            ancestor = graph.paths[ancestor].parent
        }
    }
    var path = root
    while path >= 0 {
        if verify && (kind == FLOW_READ || kind == FLOW_MOVE) && state[path] != FLOW_LIVE {
            return false
        }
        if kind == FLOW_MOVE {
            state[path] = FLOW_MOVED
        } else if kind == FLOW_INIT || kind == FLOW_WRITE {
            state[path] = FLOW_LIVE
        }
        path = flowNextPath(graph, root, path)
    }
    return true
}

fn flowVerify(graph: &mut FlowGraph, requires_return: Bool) -> FlowCheck {
    let paths = graph.paths.length
    let blocks = graph.blocks.length
    if paths > 2000000 / blocks {
        return FlowCheck(status: 2, start: 0, end: 0, iterations: 0)
    }
    var work = flowWorkNew(blocks, paths)
    var steps = 0
    while work.queue.length > 0 {
        var id = 0
        match work.queue.pop() {
            Some(next_block) => { id = next_block }
            None => { break }
        }
        steps += 1
        if steps > 100000 {
            return FlowCheck(status: 2, start: 0, end: 0, iterations: steps)
        }
        work.pending[id] = false
        flowLoad(&mut work, id, paths)
        let block = &graph.blocks[id]
        var event = block.first
        while event >= 0 {
            let instruction = &graph.events[event]
            flowApply(graph, &mut work.scratch, instruction, false)
            event = instruction.next
        }
        flowJoin(&mut work, block.next_a, paths)
        flowJoin(&mut work, block.next_b, paths)
    }
    for id in 0..blocks {
        if work.reached[id] {
            flowLoad(&mut work, id, paths)
            let block = &graph.blocks[id]
            var event = block.first
            while event >= 0 {
                let instruction = &graph.events[event]
                if !flowApply(graph, &mut work.scratch, instruction, true) {
                    return FlowCheck(status: 1, start: instruction.start, end: instruction.end, iterations: steps)
                }
                event = instruction.next
            }
            if requires_return && block.next_a < 0 && !block.returned {
                return FlowCheck(status: 3, start: 0, end: 0, iterations: steps)
            }
        }
    }
    // Keep the converged entry states for drop elaboration.
    graph.entry = work.incoming
    graph.reached = work.reached
    return FlowCheck(status: 0, start: 0, end: 0, iterations: steps)
}
