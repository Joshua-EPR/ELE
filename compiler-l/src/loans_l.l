import tokens
import flow_cfg

// Loan creation, binding and provenance shared by the Stage 1 borrow
// checker. Loans live in the FlowGraph so ids are stable per function.
// A reference binding is always a root move path; `binding_loans[root]`
// names the loan it carries, or -1 for an owner.

// Line (1-based) of a byte offset. Only used when a diagnostic is built.
fn loanLineAt(source: &Text, offset: Int) -> Int {
    var line = 1
    var i = 0
    while i < offset && i < source.byteLength {
        if source.byteAt(i) == 10 { line += 1 }
        i += 1
    }
    return line
}

// Column (1-based, code points) of a byte offset, as the CLI reports it.
fn loanColAt(source: &Text, offset: Int) -> Int {
    var col = 1
    var i = 0
    while i < offset && i < source.byteLength {
        let b = source.byteAt(i)
        if b == 10 {
            col = 1
        } else if b < 128 || b >= 192 {
            col += 1
        }
        i += 1
    }
    return col
}

fn loanNew(graph: &mut FlowGraph, kind: Int, place: Int, parent: Int, start: Int, end: Int) -> Int {
    let id = graph.loans.length
    graph.loans.push(Loan(kind: kind, place: place, parent: parent, alt: -1, param: -1, start: start, end: end))
    return id
}

fn loanIsMut(graph: &FlowGraph, loan: Int) -> Bool {
    if loan < 0 || loan >= graph.loans.length { return false }
    return graph.loans[loan].kind == LOAN_MUT
}

// The loan carried by the reference binding that roots `path`, or -1.
fn loanOfPath(graph: &FlowGraph, path: Int) -> Int {
    let root = flowRootPath(graph, path)
    if root < 0 || root >= graph.binding_loans.length { return -1 }
    return graph.binding_loans[root]
}

fn loanBind(graph: &mut FlowGraph, path: Int, loan: Int) {
    if path < 0 { return }
    while graph.binding_loans.length < graph.paths.length {
        graph.binding_loans.push(-1)
    }
    graph.binding_loans[path] = loan
}

// A reference parameter carries a loan on its own place. The loan has no
// creation event: it is live from entry and roots parameter provenance.
fn loanBindParam(graph: &mut FlowGraph, path: Int, index: Int, is_mut: Bool, start: Int, end: Int) {
    var kind = LOAN_SHARED
    if is_mut { kind = LOAN_MUT }
    let loan = loanNew(&mut graph, kind, path, -1, start, end)
    graph.loans[loan].param = index
    loanBind(&mut graph, path, loan)
}

// The storage a place denotes. A projection below a reference binding is
// replayed on the place borrowed by the binding's loan.
fn loanPlaceOf(graph: &mut FlowGraph, path: Int) -> Int {
    if path < 0 || path >= graph.paths.length { return -1 }
    let loan = loanOfPath(graph, path)
    if loan < 0 { return path }
    let root = flowRootPath(graph, path)
    var depth = 0
    var cursor = path
    while cursor != root {
        depth += 1
        cursor = graph.paths[cursor].parent
    }
    var place = graph.loans[loan].place
    var i = 0
    while i < depth {
        var hops = depth - 1 - i
        cursor = path
        while hops > 0 {
            cursor = graph.paths[cursor].parent
            hops -= 1
        }
        // Snapshot the projection index before taking a mutable loan of graph.
        // This preserves the exact path and avoids aliasing the graph argument.
        let field = graph.paths[cursor].field
        place = flowField(&mut graph, place, field)
        i += 1
    }
    return place
}

// Is `ancestor` on the reborrow chain of `loan` (inclusive)?
pub fn loanDescendsFrom(graph: &FlowGraph, loan: Int, ancestor: Int) -> Bool {
    var cursor = loan
    while cursor >= 0 && cursor < graph.loans.length {
        if cursor == ancestor { return true }
        cursor = graph.loans[cursor].parent
    }
    return false
}

// Loans form a DAG through `parent` (reborrow) and `alt` (another origin
// of a borrowed call result). Both always point to a smaller id, so walks
// terminate. True when every root reachable from `loan` is a reference
// parameter: the value cannot outlive the call that received it.
fn loanRootedAtParams(graph: &FlowGraph, loan: Int) -> Bool {
    var stack: List<Int> = List[]
    stack.push(loan)
    while stack.length > 0 {
        var node = -1
        match stack.pop() {
            Some(n) => { node = n }
            None => { break }
        }
        if node >= 0 && node < graph.loans.length {
            let parent = graph.loans[node].parent
            if parent < 0 {
                if graph.loans[node].param < 0 { return false }
            } else {
                stack.push(parent)
            }
            if graph.loans[node].alt >= 0 { stack.push(graph.loans[node].alt) }
        }
    }
    return true
}

// Result loan of a call to a borrowing function: one node per origin
// argument, chained through `alt`. Each node reborrows its origin so a use
// of the result keeps every possible owner borrowed.
fn loanResult(graph: &mut FlowGraph, kind: Int, origins: &List<Int>, start: Int, end: Int) -> Int {
    var head = -1
    var i = origins.length - 1
    while i >= 0 {
        let origin = origins[i]
        // Capture the origin place before the exclusive borrow for loanNew.
        // This preserves which location is reborrowed without overlapping loans.
        let borrowed_place = graph.loans[origin].place
        let node = loanNew(&mut graph, kind, borrowed_place, origin, start, end)
        graph.loans[node].alt = head
        head = node
        i -= 1
    }
    return head
}
