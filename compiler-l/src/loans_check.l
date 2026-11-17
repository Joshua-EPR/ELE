import tokens
import flow_cfg
import loans_l

// Non-lexical borrow checking over the Stage 1 CFG.
// 1. Backward liveness: a loan is live after a point when a later use of a
//    binding carrying it (or a reborrow of it) is reachable without passing
//    its creation. Cells hold 0 (dead) or the byte offset + 1 of the nearest
//    witness use; the join keeps the smallest witness.
// 2. A sweep over reachable blocks checks every access against the loans
//    live immediately after it.

const LOAN_OK = 0
const LOAN_CONFLICT = 1
const LOAN_LIMIT = 2

struct LoanCheck {
    status: Int
    start: Int
    end: Int
    loan: Int
    witness: Int
    iterations: Int
}

struct LoanWork {
    live: List<Int>
    table: List<Int>
    reached: List<Bool>
    pending: List<Bool>
    queue: List<Int>
    prev: List<Int>
    root_first: List<Int>
    root_next: List<Int>
    stack: List<Int>
    issue: LoanCheck
}

fn loanCheckNew(status: Int) -> LoanCheck {
    return LoanCheck(status: status, start: 0, end: 0, loan: -1, witness: 0, iterations: 0)
}

// Mark a loan live together with everything it reborrows: its parents and
// every alternative origin at each level (see loanRootedAtParams).
fn loanUse(graph: &FlowGraph, work: &mut LoanWork, loan: Int, offset: Int) {
    let w = offset + 1
    work.stack.push(loan)
    while work.stack.length > 0 {
        var node = -1
        match work.stack.pop() {
            Some(n) => { node = n }
            None => { break }
        }
        if node >= 0 && node < graph.loans.length {
            if work.live[node] == 0 || work.live[node] > w { work.live[node] = w }
            let parent = graph.loans[node].parent
            let alt = graph.loans[node].alt
            if parent >= 0 { work.stack.push(parent) }
            if alt >= 0 { work.stack.push(alt) }
        }
    }
}

fn loanFail(work: &mut LoanWork, loan: Int, start: Int, end: Int) -> Bool {
    work.issue.status = LOAN_CONFLICT
    work.issue.start = start
    work.issue.end = end
    work.issue.loan = loan
    work.issue.witness = work.live[loan] - 1
    return false
}

// Check one event against the loans live after it, then apply the backward
// transfer. Only loans whose place shares the accessed root are visited.
fn loanStep(graph: &FlowGraph, work: &mut LoanWork, id: Int, check: Bool) -> Bool {
    let ev = &graph.events[id]
    let kind = ev.kind
    let path = ev.path
    let data = ev.data
    if path < 0 || path >= graph.paths.length { return true }
    // A FLOW_DROP_REF is followed by the WRITE that it prepares.
    if kind == FLOW_DROP_REF { return true }
    if kind == FLOW_LOAN_USE {
        loanUse(graph, &mut work, data, ev.start)
        return true
    }
    if kind == FLOW_LOAN_CREATE {
        let place = graph.loans[data].place
        if check {
            var m = work.root_first[flowRootPath(graph, place)]
            while m >= 0 {
                if m != data && work.live[m] != 0 && !loanDescendsFrom(graph, data, m) {
                    if loanOverlaps(graph, place, graph.loans[m].place) && (loanIsMut(graph, data) || loanIsMut(graph, m)) {
                        return loanFail(&mut work, m, ev.start, ev.end)
                    }
                }
                m = work.root_next[m]
            }
        }
        work.live[data] = 0
        return true
    }
    let loan = loanOfPath(graph, path)
    if loan >= 0 {
        // Use of a reference binding. A live reborrow of an overlapping
        // place suspends it: any access conflicts with a mutable reborrow,
        // a write with any. `data` holds the place reached through it.
        if kind == FLOW_INIT { return true }
        if check {
            var m = work.root_first[flowRootPath(graph, data)]
            while m >= 0 {
                if m != loan && work.live[m] != 0 && loanDescendsFrom(graph, m, loan) && loanOverlaps(graph, data, graph.loans[m].place) {
                    if kind == FLOW_WRITE || kind == FLOW_MUTATE || loanIsMut(graph, m) {
                        return loanFail(&mut work, m, ev.start, ev.end)
                    }
                }
                m = work.root_next[m]
            }
        }
        loanUse(graph, &mut work, loan, ev.start)
        return true
    }
    if check {
        // Direct access to an owner: reads coexist with shared loans only.
        var m = work.root_first[flowRootPath(graph, path)]
        while m >= 0 {
            if work.live[m] != 0 && loanOverlaps(graph, path, graph.loans[m].place) {
                if kind != FLOW_READ || loanIsMut(graph, m) {
                    return loanFail(&mut work, m, ev.start, ev.end)
                }
            }
            m = work.root_next[m]
        }
    }
    return true
}

fn loanJoin(work: &mut LoanWork, offset: Int, loans: Int) {
    for m in 0..loans {
        let arriving = work.table[offset + m]
        if arriving != 0 && (work.live[m] == 0 || arriving < work.live[m]) {
            work.live[m] = arriving
        }
    }
}

// Live-out of a block: union of the live-in of its successors.
fn loanLoadOut(graph: &FlowGraph, work: &mut LoanWork, block: Int, loans: Int) {
    for m in 0..loans { work.live[m] = 0 }
    let a = graph.blocks[block].next_a
    let b = graph.blocks[block].next_b
    if a >= 0 { loanJoin(&mut work, a * loans, loans) }
    if b >= 0 { loanJoin(&mut work, b * loans, loans) }
}

// Walk a block backward. Returns false on the first conflict.
fn loanBlock(graph: &FlowGraph, work: &mut LoanWork, block: Int, check: Bool) -> Bool {
    var event = graph.blocks[block].last
    while event >= 0 {
        if !loanStep(graph, &mut work, event, check) { return false }
        event = work.prev[event]
    }
    return true
}

fn loanWorkNew(graph: &FlowGraph, loans: Int) -> LoanWork {
    let blocks = graph.blocks.length
    var live: List<Int> = List[]
    var table: List<Int> = List[]
    var reached: List<Bool> = List[]
    var pending: List<Bool> = List[]
    var queue: List<Int> = List[]
    var prev: List<Int> = List[]
    var root_first: List<Int> = List[]
    var root_next: List<Int> = List[]
    var stack: List<Int> = List[]
    for m in 0..loans {
        live.push(0)
        root_next.push(-1)
    }
    table.reserve(blocks * loans)
    for i in 0..(blocks * loans) { table.push(0) }
    for i in 0..blocks {
        reached.push(i == 0)
        pending.push(false)
    }
    for i in 0..graph.events.length { prev.push(-1) }
    for i in 0..graph.paths.length { root_first.push(-1) }
    // Newest loans first: a conflict names the most recent live loan.
    for m in 0..loans {
        let root = flowRootPath(graph, graph.loans[m].place)
        if root >= 0 {
            root_next[m] = root_first[root]
            root_first[root] = m
        }
    }
    for block in 0..blocks {
        var event = graph.blocks[block].first
        while event >= 0 {
            let next = graph.events[event].next
            if next >= 0 { prev[next] = event }
            event = next
        }
    }
    return LoanWork(live: live, table: table, reached: reached, pending: pending, queue: queue, prev: prev, root_first: root_first, root_next: root_next, stack: stack, issue: loanCheckNew(LOAN_OK))
}

// Mark blocks reachable from entry, then seed the worklist with them so the
// highest ids (latest in program order) are processed first.
fn loanReach(graph: &FlowGraph, work: &mut LoanWork) {
    let blocks = graph.blocks.length
    work.queue.push(0)
    while work.queue.length > 0 {
        var block = 0
        match work.queue.pop() {
            Some(b) => { block = b }
            None => { break }
        }
        let a = graph.blocks[block].next_a
        let b = graph.blocks[block].next_b
        if a >= 0 && !work.reached[a] {
            work.reached[a] = true
            work.queue.push(a)
        }
        if b >= 0 && !work.reached[b] {
            work.reached[b] = true
            work.queue.push(b)
        }
    }
    for i in 0..blocks {
        if work.reached[i] {
            work.pending[i] = true
            work.queue.push(i)
        }
    }
}

// Record, on every access through a reference binding, the owner place it
// reaches. Done once before the analysis so the solver never allocates.
fn loanResolveThrough(graph: &mut FlowGraph) {
    for id in 0..graph.events.length {
        let kind = graph.events[id].kind
        let path = graph.events[id].path
        if (kind <= FLOW_WRITE || kind == FLOW_MUTATE) && path >= 0 && loanOfPath(graph, path) >= 0 {
            let place = loanPlaceOf(&mut graph, path)
            graph.events[id].data = place
        }
    }
}

pub fn loanVerify(graph: &mut FlowGraph) -> LoanCheck {
    let loans = graph.loans.length
    let blocks = graph.blocks.length
    if loans == 0 || blocks == 0 { return loanCheckNew(LOAN_OK) }
    loanResolveThrough(&mut graph)
    if loans > 2000000 / blocks { return loanCheckNew(LOAN_LIMIT) }
    var work = loanWorkNew(graph, loans)
    loanReach(graph, &mut work)
    var steps = 0
    while work.queue.length > 0 {
        var block = 0
        match work.queue.pop() {
            Some(b) => { block = b }
            None => { break }
        }
        work.pending[block] = false
        steps += 1
        if steps > 100000 {
            var limit = loanCheckNew(LOAN_LIMIT)
            limit.iterations = steps
            return limit
        }
        loanLoadOut(graph, &mut work, block, loans)
        loanBlock(graph, &mut work, block, false)
        let offset = block * loans
        var changed = false
        for m in 0..loans {
            if work.table[offset + m] != work.live[m] {
                work.table[offset + m] = work.live[m]
                changed = true
            }
        }
        if changed {
            var pred = graph.blocks[block].predecessor
            while pred >= 0 {
                let origin = graph.predecessors[pred].block
                if work.reached[origin] && !work.pending[origin] {
                    work.pending[origin] = true
                    work.queue.push(origin)
                }
                pred = graph.predecessors[pred].next
            }
        }
    }
    for block in 0..blocks {
        if work.reached[block] {
            loanLoadOut(graph, &mut work, block, loans)
            if !loanBlock(graph, &mut work, block, true) {
                let found = &work.issue
                return LoanCheck(status: found.status, start: found.start, end: found.end, loan: found.loan, witness: found.witness, iterations: steps)
            }
        }
    }
    var done = loanCheckNew(LOAN_OK)
    done.iterations = steps
    return done
}
