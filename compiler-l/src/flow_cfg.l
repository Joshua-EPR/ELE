pub const FLOW_READ = 0
pub const FLOW_MOVE = 1
pub const FLOW_INIT = 2
pub const FLOW_WRITE = 3
pub const FLOW_LOAN_CREATE = 4
pub const FLOW_LOAN_USE = 5
// End of the lexical lifetime of an owned binding or temporary: the drop
// elaborator (drops_plan.l) turns it into drops of whatever it still owns.
pub const FLOW_DROP = 6
// Write through a reference: the old referent value is released first.
pub const FLOW_DROP_REF = 7
// In-place collection mutation: requires a live owner and exclusive access,
// but does not replace or drop the collection value.
pub const FLOW_MUTATE = 8

// Loan kinds.
pub const LOAN_SHARED = 0
pub const LOAN_MUT = 1

pub struct FlowBlock {
    first: Int
    last: Int
    next_a: Int
    next_b: Int
    returned: Bool
    predecessor: Int
}

pub struct FlowPredecessor {
    block: Int
    next: Int
}

pub struct FlowEvent {
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
pub struct Loan {
    kind: Int
    place: Int
    parent: Int
    alt: Int
    param: Int
    start: Int
    end: Int
}

pub struct MovePath {
    symbol: Int
    parent: Int
    field: Int
    child: Int
    sibling: Int
}

pub struct FlowGraph {
    blocks: List<FlowBlock>
    events: List<FlowEvent>
    paths: List<MovePath>
    predecessors: List<FlowPredecessor>
    loans: List<Loan>
    // Loan id per move path: a path bound to a reference carries that loan.
    binding_loans: List<Int>
    // Per path: the type of an owned leaf that needs a drop, or -1.
    drop_types: List<Int>
    // Per root path: where it was defined (>= 0 byte offset of the
    // initializer or temporary, -1 - i for parameter i, FLOW_NO_ORIGIN).
    origins: List<Int>
    // Ownership states at block entry and reachability, kept by flowVerify
    // for the drop elaborator.
    entry: List<Int>
    reached: List<Bool>
    current: Int
    break_to: Int
    continue_to: Int
}

pub fn flowNew() -> FlowGraph {
    var blocks: List<FlowBlock> = List[]
    let events: List<FlowEvent> = List[]
    let paths: List<MovePath> = List[]
    let predecessors: List<FlowPredecessor> = List[]
    let loans: List<Loan> = List[]
    let binding_loans: List<Int> = List[]
    let drop_types: List<Int> = List[]
    let origins: List<Int> = List[]
    let entry: List<Int> = List[]
    let reached: List<Bool> = List[]
    blocks.push(flowEmptyBlock())
    return FlowGraph(blocks: blocks, events: events, paths: paths, predecessors: predecessors, loans: loans, binding_loans: binding_loans, drop_types: drop_types, origins: origins, entry: entry, reached: reached, current: 0, break_to: -1, continue_to: -1)
}

pub fn flowEmptyBlock() -> FlowBlock {
    return FlowBlock(first: -1, last: -1, next_a: -1, next_b: -1, returned: false, predecessor: -1)
}

pub fn flowBlock(graph: &mut FlowGraph) -> Int {
    let id = graph.blocks.length
    graph.blocks.push(flowEmptyBlock())
    return id
}

pub fn flowLink(graph: &mut FlowGraph, first: Int, second: Int) {
    let id = graph.current
    graph.blocks[id].next_a = first
    graph.blocks[id].next_b = second
    flowAddPredecessor(&mut graph, first, id)
    flowAddPredecessor(&mut graph, second, id)
}

pub fn flowAddPredecessor(graph: &mut FlowGraph, destination: Int, origin: Int) {
    if destination < 0 { return }
    let previous = graph.blocks[destination].predecessor
    let id = graph.predecessors.length
    graph.predecessors.push(FlowPredecessor(block: origin, next: previous))
    graph.blocks[destination].predecessor = id
}

pub fn flowReturn(graph: &mut FlowGraph) {
    graph.blocks[graph.current].returned = true
    let detached = flowBlock(&mut graph)
    graph.current = detached
}

pub struct FlowLoop {
    header: Int
    exit: Int
    outer_break: Int
    outer_continue: Int
}

pub fn flowLoopStart(graph: &mut FlowGraph) -> FlowLoop {
    let header = flowBlock(&mut graph)
    let exit = flowBlock(&mut graph)
    flowLink(&mut graph, header, -1)
    graph.current = header
    return FlowLoop(header: header, exit: exit, outer_break: graph.break_to, outer_continue: graph.continue_to)
}

pub fn flowLoopBody(graph: &mut FlowGraph, state: &FlowLoop, conditional: Bool) {
    let body = flowBlock(&mut graph)
    var alternative = -1
    if conditional { alternative = state.exit }
    flowLink(&mut graph, body, alternative)
    graph.current = body
    graph.break_to = state.exit
    graph.continue_to = state.header
}

pub fn flowLoopEnd(graph: &mut FlowGraph, state: &FlowLoop) {
    flowLink(&mut graph, state.header, -1)
    graph.current = state.exit
    graph.break_to = state.outer_break
    graph.continue_to = state.outer_continue
}

pub const FLOW_NO_ORIGIN = -1000000000

pub fn flowPad(graph: &mut FlowGraph) {
    while graph.drop_types.length < graph.paths.length {
        graph.drop_types.push(-1)
        graph.origins.push(FLOW_NO_ORIGIN)
    }
}

pub fn flowDropType(graph: &FlowGraph, path: Int) -> Int {
    if path < 0 || path >= graph.drop_types.length { return -1 }
    return graph.drop_types[path]
}

pub fn flowRoot(graph: &mut FlowGraph, symbol: Int) -> Int {
    let id = graph.paths.length
    graph.paths.push(MovePath(symbol: symbol, parent: -1, field: -1, child: -1, sibling: -1))
    return id
}

pub fn flowField(graph: &mut FlowGraph, parent: Int, field: Int) -> Int {
    let first = graph.paths[parent].child
    var cursor = first
    while cursor >= 0 {
        if graph.paths[cursor].field == field { return cursor }
        cursor = graph.paths[cursor].sibling
    }
    let id = graph.paths.length
    let symbol = graph.paths[parent].symbol
    graph.paths.push(MovePath(symbol: symbol, parent: parent, field: field, child: -1, sibling: first))
    graph.paths[parent].child = id
    return id
}

pub fn flowEvent(graph: &mut FlowGraph, kind: Int, path: Int, start: Int, end: Int) {
    flowEventData(&mut graph, kind, path, start, end, -1)
}

pub fn flowEventData(graph: &mut FlowGraph, kind: Int, path: Int, start: Int, end: Int, data: Int) {
    if path < 0 { return }
    let block = graph.current
    let previous = graph.blocks[block].last
    let id = graph.events.length
    graph.events.push(FlowEvent(kind: kind, path: path, start: start, end: end, next: -1, data: data))
    if previous >= 0 {
        graph.events[previous].next = id
    } else {
        graph.blocks[block].first = id
    }
    graph.blocks[block].last = id
}

// The root move path of any path.
pub fn flowRootPath(graph: &FlowGraph, path: Int) -> Int {
    if path < 0 || path >= graph.paths.length { return -1 }
    var cursor = path
    while graph.paths[cursor].parent >= 0 {
        cursor = graph.paths[cursor].parent
    }
    return cursor
}

// True when places a and b share storage: same root and one is an
// ancestor-or-equal of the other (field projections are canonical ids).
fn loanOverlaps(graph: &FlowGraph, a: Int, b: Int) -> Bool {
    if a < 0 || b < 0 { return false }
    if a == b { return true }
    if flowRootPath(graph, a) != flowRootPath(graph, b) { return false }
    var cursor = graph.paths[a].parent
    while cursor >= 0 {
        if cursor == b { return true }
        cursor = graph.paths[cursor].parent
    }
    cursor = graph.paths[b].parent
    while cursor >= 0 {
        if cursor == a { return true }
        cursor = graph.paths[cursor].parent
    }
    return false
}

// Walk the tracked subtree without recursion or a temporary stack.
pub fn flowNextPath(graph: &FlowGraph, root: Int, current: Int) -> Int {
    let child = graph.paths[current].child
    if child >= 0 { return child }
    var cursor = current
    while cursor != root {
        let sibling = graph.paths[cursor].sibling
        if sibling >= 0 { return sibling }
        cursor = graph.paths[cursor].parent
    }
    return -1
}
