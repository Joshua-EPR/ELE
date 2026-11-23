expose fixed FLOW_READ = 0
expose fixed FLOW_MOVE = 1
expose fixed FLOW_INIT = 2
expose fixed FLOW_WRITE = 3
expose fixed FLOW_LOAN_CREATE = 4
expose fixed FLOW_LOAN_USE = 5
// End of the lexical lifetime of an owned binding or temporary: the drop
// elaborator (drops_plan.l) turns it into drops of whatever it still owns.
expose fixed FLOW_DROP = 6
// Write through a reference: the old referent value is released first.
expose fixed FLOW_DROP_REF = 7
// In-place collection mutation: requires a live owner and exclusive access,
// but does not replace or drop the collection value.
expose fixed FLOW_MUTATE = 8

// Loan kinds.
expose fixed LOAN_SHARED = 0
expose fixed LOAN_MUT = 1

expose shape FlowBlock {
    first: Int
    last: Int
    next_a: Int
    next_b: Int
    returned: Bool
    predecessor: Int
}

expose shape FlowPredecessor {
    block: Int
    next: Int
}

expose shape FlowEvent {
    kind: Int
    path: Int
    start: Int
    end: Int
    next: Int
    // Loan id for FLOW_LOAN_CREATE and FLOW_LOAN_USE events, -1 otherwise.
    data: Int
}

// A loan is one syntactic borrow site. `place` is the borrowed move path,
// `parent` the loan it reborrows from, `alt` the next alternative origin of
// a borrowed call result and `param` the parameter index of a loan carried
// by a reference parameter (-1 otherwise).
expose shape Loan {
    kind: Int
    place: Int
    parent: Int
    alt: Int
    param: Int
    start: Int
    end: Int
}

expose shape MovePath {
    symbol: Int
    parent: Int
    field: Int
    child: Int
    sibling: Int
}

expose shape FlowGraph {
    blocks: List of[FlowBlock]
    events: List of[FlowEvent]
    paths: List of[MovePath]
    predecessors: List of[FlowPredecessor]
    loans: List of[Loan]
    // Loan id per move path: a path bound to a reference carries that loan.
    binding_loans: List of[Int]
    // Per path: the type of an owned leaf that needs a drop, or -1.
    drop_types: List of[Int]
    // Per root path: where it was defined (>= 0 byte offset of the
    // initializer or temporary, -1 - i for parameter i, FLOW_NO_ORIGIN).
    origins: List of[Int]
    // Ownership states at block entry and reachability, kept by flowVerify
    // for the drop elaborator.
    entry: List of[Int]
    reached: List of[Bool]
    current: Int
    break_to: Int
    continue_to: Int
    // Sema type ids of the linear resources (semTypeLinearIds): a leaf of
    // one of these types still (maybe) owned when it is dropped is rejected
    // instead of released.
    linear_types: List of[Int]
}

expose flow flowNew() => FlowGraph {
    change blocks: List of[FlowBlock] = List[]
    hold events: List of[FlowEvent] = List[]
    hold paths: List of[MovePath] = List[]
    hold predecessors: List of[FlowPredecessor] = List[]
    hold loans: List of[Loan] = List[]
    hold binding_loans: List of[Int] = List[]
    hold drop_types: List of[Int] = List[]
    hold origins: List of[Int] = List[]
    hold entry: List of[Int] = List[]
    hold reached: List of[Bool] = List[]
    hold linear_types: List of[Int] = List[]
    blocks@push(flowEmptyBlock())
    give FlowGraph(blocks: blocks, events: events, paths: paths, predecessors: predecessors, loans: loans, binding_loans: binding_loans, drop_types: drop_types, origins: origins, entry: entry, reached: reached, current: 0, break_to: -1, continue_to: -1, linear_types: linear_types)
}

expose flow flowEmptyBlock() => FlowBlock {
    give FlowBlock(first: -1, last: -1, next_a: -1, next_b: -1, returned: false, predecessor: -1)
}

expose flow flowBlock(graph: edit FlowGraph) => Int {
    hold id = graph.blocks.length
    graph.blocks@push(flowEmptyBlock())
    give id
}

expose flow flowLink(graph: edit FlowGraph, first: Int, second: Int) {
    hold id = graph.current
    graph.blocks[id].next_a = first
    graph.blocks[id].next_b = second
    flowAddPredecessor(edit graph, first, id)
    flowAddPredecessor(edit graph, second, id)
}

expose flow flowAddPredecessor(graph: edit FlowGraph, destination: Int, origin: Int) {
    when destination < 0 { give }
    hold previous = graph.blocks[destination].predecessor
    hold id = graph.predecessors.length
    graph.predecessors@push(FlowPredecessor(block: origin, next: previous))
    graph.blocks[destination].predecessor = id
}

expose flow flowReturn(graph: edit FlowGraph) {
    graph.blocks[graph.current].returned = true
    hold detached = flowBlock(edit graph)
    graph.current = detached
}

expose shape FlowLoop {
    header: Int
    exit: Int
    outer_break: Int
    outer_continue: Int
}

expose flow flowLoopStart(graph: edit FlowGraph) => FlowLoop {
    hold header = flowBlock(edit graph)
    hold exit = flowBlock(edit graph)
    flowLink(edit graph, header, -1)
    graph.current = header
    give FlowLoop(header: header, exit: exit, outer_break: graph.break_to, outer_continue: graph.continue_to)
}

expose flow flowLoopBody(graph: edit FlowGraph, state: view FlowLoop, conditional: Bool) {
    hold body = flowBlock(edit graph)
    change alternative = -1
    when conditional { alternative = state.exit }
    flowLink(edit graph, body, alternative)
    graph.current = body
    graph.break_to = state.exit
    graph.continue_to = state.header
}

expose flow flowLoopEnd(graph: edit FlowGraph, state: view FlowLoop) {
    flowLink(edit graph, state.header, -1)
    graph.current = state.exit
    graph.break_to = state.outer_break
    graph.continue_to = state.outer_continue
}

expose fixed FLOW_NO_ORIGIN = -1000000000

expose flow flowPad(graph: edit FlowGraph) {
    during graph.drop_types.length < graph.paths.length {
        graph.drop_types@push(-1)
        graph.origins@push(FLOW_NO_ORIGIN)
    }
}

expose flow flowDropType(graph: view FlowGraph, path: Int) => Int {
    when path < 0 || path >= graph.drop_types.length { give -1 }
    give graph.drop_types[path]
}

expose flow flowRoot(graph: edit FlowGraph, symbol: Int) => Int {
    hold id = graph.paths.length
    graph.paths@push(MovePath(symbol: symbol, parent: -1, field: -1, child: -1, sibling: -1))
    give id
}

expose flow flowField(graph: edit FlowGraph, parent: Int, field: Int) => Int {
    hold first = graph.paths[parent].child
    change cursor = first
    during cursor >= 0 {
        when graph.paths[cursor].field == field { give cursor }
        cursor = graph.paths[cursor].sibling
    }
    hold id = graph.paths.length
    hold symbol = graph.paths[parent].symbol
    graph.paths@push(MovePath(symbol: symbol, parent: parent, field: field, child: -1, sibling: first))
    graph.paths[parent].child = id
    give id
}

expose flow flowEvent(graph: edit FlowGraph, kind: Int, path: Int, start: Int, end: Int) {
    flowEventData(edit graph, kind, path, start, end, -1)
}

expose flow flowEventData(graph: edit FlowGraph, kind: Int, path: Int, start: Int, end: Int, data: Int) {
    when path < 0 { give }
    hold block = graph.current
    hold previous = graph.blocks[block].last
    hold id = graph.events.length
    graph.events@push(FlowEvent(kind: kind, path: path, start: start, end: end, next: -1, data: data))
    when previous >= 0 {
        graph.events[previous].next = id
    } otherwise {
        graph.blocks[block].first = id
    }
    graph.blocks[block].last = id
}

// The root move path of any path.
expose flow flowRootPath(graph: view FlowGraph, path: Int) => Int {
    when path < 0 || path >= graph.paths.length { give -1 }
    change cursor = path
    during graph.paths[cursor].parent >= 0 {
        cursor = graph.paths[cursor].parent
    }
    give cursor
}

// True when places a and b share storage: same root and one is an
// ancestor-or-equal of the other (field projections are canonical ids).
expose flow loanOverlaps(graph: view FlowGraph, a: Int, b: Int) => Bool {
    when a < 0 || b < 0 { give false }
    when a == b { give true }
    when flowRootPath(graph, a) != flowRootPath(graph, b) { give false }
    change cursor = graph.paths[a].parent
    during cursor >= 0 {
        when cursor == b { give true }
        cursor = graph.paths[cursor].parent
    }
    cursor = graph.paths[b].parent
    during cursor >= 0 {
        when cursor == a { give true }
        cursor = graph.paths[cursor].parent
    }
    give false
}

// Walk the tracked subtree without recursion or a temporary stack.
expose flow flowNextPath(graph: view FlowGraph, root: Int, current: Int) => Int {
    hold child = graph.paths[current].child
    when child >= 0 { give child }
    change cursor = current
    during cursor != root {
        hold sibling = graph.paths[cursor].sibling
        when sibling >= 0 { give sibling }
        cursor = graph.paths[cursor].parent
    }
    give -1
}
