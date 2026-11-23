take tokens
take flow_cfg
take loans_l

// Non-lexical borrow checking over the Stage 1 CFG.
// 1. Backward liveness: a loan is live after a point when a later use of a
//    binding carrying it (or a reborrow of it) is reachable without passing
//    its creation. Cells hold 0 (dead) or the byte offset + 1 of the nearest
//    witness use; the join keeps the smallest witness.
// 2. A sweep over reachable blocks checks every access against the loans
//    live immediately after it.

fixed LOAN_OK = 0
expose fixed LOAN_CONFLICT = 1
expose fixed LOAN_LIMIT = 2

shape LoanCheck {
    status: Int
    start: Int
    end: Int
    loan: Int
    witness: Int
    iterations: Int
}

shape LoanWork {
    live: List of[Int]
    table: List of[Int]
    reached: List of[Bool]
    pending: List of[Bool]
    queue: List of[Int]
    prev: List of[Int]
    root_first: List of[Int]
    root_next: List of[Int]
    stack: List of[Int]
    issue: LoanCheck
}

flow loanCheckNew(status: Int) => LoanCheck {
    give LoanCheck(status: status, start: 0, end: 0, loan: -1, witness: 0, iterations: 0)
}

// Mark a loan live together with everything it reborrows: its parents and
// every alternative origin at each level (see loanRootedAtParams).
flow loanUse(graph: view FlowGraph, work: edit LoanWork, loan: Int, offset: Int) {
    hold w = offset + 1
    work.stack@push(loan)
    during work.stack.length > 0 {
        change node = -1
        choose work.stack@pop() {
            Some(n) : { node = n }
            None : { leave }
        }
        when node >= 0 && node < graph.loans.length {
            when work.live[node] == 0 || work.live[node] > w { work.live[node] = w }
            hold parent = graph.loans[node].parent
            hold alt = graph.loans[node].alt
            when parent >= 0 { work.stack@push(parent) }
            when alt >= 0 { work.stack@push(alt) }
        }
    }
}

flow loanFail(work: edit LoanWork, loan: Int, start: Int, end: Int) => Bool {
    work.issue.status = LOAN_CONFLICT
    work.issue.start = start
    work.issue.end = end
    work.issue.loan = loan
    work.issue.witness = work.live[loan] - 1
    give false
}

// Check one event against the loans live after it, then apply the backward
// transfer. Only loans whose place shares the accessed root are visited.
flow loanStep(graph: view FlowGraph, work: edit LoanWork, id: Int, check: Bool) => Bool {
    hold ev = view graph.events[id]
    hold kind = ev.kind
    hold path = ev.path
    hold data = ev.data
    when path < 0 || path >= graph.paths.length { give true }
    // A FLOW_DROP_REF is followed by the WRITE that it prepares.
    when kind == FLOW_DROP_REF { give true }
    when kind == FLOW_LOAN_USE {
        loanUse(graph, edit work, data, ev.start)
        give true
    }
    when kind == FLOW_LOAN_CREATE {
        hold place = graph.loans[data].place
        when check {
            change m = work.root_first[flowRootPath(graph, place)]
            during m >= 0 {
                when m != data && work.live[m] != 0 && !loanDescendsFrom(graph, data, m) {
                    when loanOverlaps(graph, place, graph.loans[m].place) && (loanIsMut(graph, data) || loanIsMut(graph, m)) {
                        give loanFail(edit work, m, ev.start, ev.end)
                    }
                }
                m = work.root_next[m]
            }
        }
        work.live[data] = 0
        give true
    }
    hold loan = loanOfPath(graph, path)
    when loan >= 0 {
        // Use of a reference binding. A live reborrow of an overlapping
        // place suspends it: any access conflicts with a mutable reborrow,
        // a write with any. `data` holds the place reached through it.
        when kind == FLOW_INIT { give true }
        when check {
            change m = work.root_first[flowRootPath(graph, data)]
            during m >= 0 {
                when m != loan && work.live[m] != 0 && loanDescendsFrom(graph, m, loan) && loanOverlaps(graph, data, graph.loans[m].place) {
                    when kind == FLOW_WRITE || kind == FLOW_MUTATE || loanIsMut(graph, m) {
                        give loanFail(edit work, m, ev.start, ev.end)
                    }
                }
                m = work.root_next[m]
            }
        }
        loanUse(graph, edit work, loan, ev.start)
        give true
    }
    when check {
        // Direct access to an owner: reads coexist with shared loans only.
        change m = work.root_first[flowRootPath(graph, path)]
        during m >= 0 {
            when work.live[m] != 0 && loanOverlaps(graph, path, graph.loans[m].place) {
                when kind != FLOW_READ || loanIsMut(graph, m) {
                    give loanFail(edit work, m, ev.start, ev.end)
                }
            }
            m = work.root_next[m]
        }
    }
    give true
}

flow loanJoin(work: edit LoanWork, offset: Int, loans: Int) {
    each m among 0..loans {
        hold arriving = work.table[offset + m]
        when arriving != 0 && (work.live[m] == 0 || arriving < work.live[m]) {
            work.live[m] = arriving
        }
    }
}

// Live-out of a block: union of the live-in of its successors.
flow loanLoadOut(graph: view FlowGraph, work: edit LoanWork, block: Int, loans: Int) {
    each m among 0..loans { work.live[m] = 0 }
    hold a = graph.blocks[block].next_a
    hold b = graph.blocks[block].next_b
    when a >= 0 { loanJoin(edit work, a * loans, loans) }
    when b >= 0 { loanJoin(edit work, b * loans, loans) }
}

// Walk a block backward. Returns false on the first conflict.
flow loanBlock(graph: view FlowGraph, work: edit LoanWork, block: Int, check: Bool) => Bool {
    change event = graph.blocks[block].last
    during event >= 0 {
        when !loanStep(graph, edit work, event, check) { give false }
        event = work.prev[event]
    }
    give true
}

flow loanWorkNew(graph: view FlowGraph, loans: Int) => LoanWork {
    hold blocks = graph.blocks.length
    change live: List of[Int] = List[]
    change table: List of[Int] = List[]
    change reached: List of[Bool] = List[]
    change pending: List of[Bool] = List[]
    change queue: List of[Int] = List[]
    change prev: List of[Int] = List[]
    change root_first: List of[Int] = List[]
    change root_next: List of[Int] = List[]
    change stack: List of[Int] = List[]
    each m among 0..loans {
        live@push(0)
        root_next@push(-1)
    }
    table@reserve(blocks * loans)
    each i among 0..(blocks * loans) { table@push(0) }
    each i among 0..blocks {
        reached@push(i == 0)
        pending@push(false)
    }
    each i among 0..graph.events.length { prev@push(-1) }
    each i among 0..graph.paths.length { root_first@push(-1) }
    // Newest loans first: a conflict names the most recent live loan.
    each m among 0..loans {
        hold root = flowRootPath(graph, graph.loans[m].place)
        when root >= 0 {
            root_next[m] = root_first[root]
            root_first[root] = m
        }
    }
    each block among 0..blocks {
        change event = graph.blocks[block].first
        during event >= 0 {
            hold next = graph.events[event].next
            when next >= 0 { prev[next] = event }
            event = next
        }
    }
    give LoanWork(live: live, table: table, reached: reached, pending: pending, queue: queue, prev: prev, root_first: root_first, root_next: root_next, stack: stack, issue: loanCheckNew(LOAN_OK))
}

// Mark blocks reachable from entry, then seed the worklist with them so the
// highest ids (latest in program order) are processed first.
flow loanReach(graph: view FlowGraph, work: edit LoanWork) {
    hold blocks = graph.blocks.length
    work.queue@push(0)
    during work.queue.length > 0 {
        change block = 0
        choose work.queue@pop() {
            Some(b) : { block = b }
            None : { leave }
        }
        hold a = graph.blocks[block].next_a
        hold b = graph.blocks[block].next_b
        when a >= 0 && !work.reached[a] {
            work.reached[a] = true
            work.queue@push(a)
        }
        when b >= 0 && !work.reached[b] {
            work.reached[b] = true
            work.queue@push(b)
        }
    }
    each i among 0..blocks {
        when work.reached[i] {
            work.pending[i] = true
            work.queue@push(i)
        }
    }
}

// Record, on every access through a reference binding, the owner place it
// reaches. Done once before the analysis so the solver never allocates.
flow loanResolveThrough(graph: edit FlowGraph) {
    each id among 0..graph.events.length {
        hold kind = graph.events[id].kind
        hold path = graph.events[id].path
        when (kind <= FLOW_WRITE || kind == FLOW_MUTATE) && path >= 0 && loanOfPath(graph, path) >= 0 {
            hold place = loanPlaceOf(edit graph, path)
            graph.events[id].data = place
        }
    }
}

expose flow loanVerify(graph: edit FlowGraph) => LoanCheck {
    hold loans = graph.loans.length
    hold blocks = graph.blocks.length
    when loans == 0 || blocks == 0 { give loanCheckNew(LOAN_OK) }
    loanResolveThrough(edit graph)
    when loans > 2000000 / blocks { give loanCheckNew(LOAN_LIMIT) }
    change work = loanWorkNew(graph, loans)
    loanReach(graph, edit work)
    change steps = 0
    during work.queue.length > 0 {
        change block = 0
        choose work.queue@pop() {
            Some(b) : { block = b }
            None : { leave }
        }
        work.pending[block] = false
        steps += 1
        when steps > 100000 {
            change limit = loanCheckNew(LOAN_LIMIT)
            limit.iterations = steps
            give limit
        }
        loanLoadOut(graph, edit work, block, loans)
        loanBlock(graph, edit work, block, false)
        hold offset = block * loans
        change changed = false
        each m among 0..loans {
            when work.table[offset + m] != work.live[m] {
                work.table[offset + m] = work.live[m]
                changed = true
            }
        }
        when changed {
            change pred = graph.blocks[block].predecessor
            during pred >= 0 {
                hold origin = graph.predecessors[pred].block
                when work.reached[origin] && !work.pending[origin] {
                    work.pending[origin] = true
                    work.queue@push(origin)
                }
                pred = graph.predecessors[pred].next
            }
        }
    }
    each block among 0..blocks {
        when work.reached[block] {
            loanLoadOut(graph, edit work, block, loans)
            when !loanBlock(graph, edit work, block, true) {
                hold found = view work.issue
                give LoanCheck(status: found.status, start: found.start, end: found.end, loan: found.loan, witness: found.witness, iterations: steps)
            }
        }
    }
    change done = loanCheckNew(LOAN_OK)
    done.iterations = steps
    give done
}
