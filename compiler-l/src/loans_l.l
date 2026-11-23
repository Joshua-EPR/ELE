take tokens
take flow_cfg

// Loan creation, binding and provenance shared by the Stage 1 borrow
// checker. Loans live in the FlowGraph so ids are stable per function.
// A reference binding is always a root move path; `binding_loans[root]`
// names the loan it carries, or -1 for an owner.

// Line (1-based) of a byte offset. Only used when a diagnostic is built.
expose flow loanLineAt(source: view Text, offset: Int) => Int {
    change line = 1
    change i = 0
    during i < offset && i < source.byteLength {
        when source@byteAt(i) == 10 { line += 1 }
        i += 1
    }
    give line
}

// Column (1-based, code points) of a byte offset, as the CLI reports it.
expose flow loanColAt(source: view Text, offset: Int) => Int {
    change col = 1
    change i = 0
    during i < offset && i < source.byteLength {
        hold b = source@byteAt(i)
        when b == 10 {
            col = 1
        } otherwise when b < 128 || b >= 192 {
            col += 1
        }
        i += 1
    }
    give col
}

expose flow loanNew(graph: edit FlowGraph, kind: Int, place: Int, parent: Int, start: Int, end: Int) => Int {
    hold id = graph.loans.length
    graph.loans@push(Loan(kind: kind, place: place, parent: parent, alt: -1, param: -1, start: start, end: end))
    give id
}

expose flow loanIsMut(graph: view FlowGraph, loan: Int) => Bool {
    when loan < 0 || loan >= graph.loans.length { give false }
    give graph.loans[loan].kind == LOAN_MUT
}

// The loan carried by the reference binding that roots `path`, or -1.
expose flow loanOfPath(graph: view FlowGraph, path: Int) => Int {
    hold root = flowRootPath(graph, path)
    when root < 0 || root >= graph.binding_loans.length { give -1 }
    give graph.binding_loans[root]
}

flow loanBind(graph: edit FlowGraph, path: Int, loan: Int) {
    when path < 0 { give }
    during graph.binding_loans.length < graph.paths.length {
        graph.binding_loans@push(-1)
    }
    graph.binding_loans[path] = loan
}

// Exported binding boundary for semantic lowering: only a real root path
// may receive an existing loan. The unvalidated loanBind primitive stays
// module-private and is used internally by loanBindParam.
expose flow loanBindReferenceRoot(graph: edit FlowGraph, path: Int, loan: Int) => Bool {
    when path < 0 || path >= graph.paths.length { give false }
    when graph.paths[path].parent >= 0 { give false }
    when loan < 0 || loan >= graph.loans.length { give false }
    loanBind(edit graph, path, loan)
    give true
}

// A reference parameter carries a loan on its own place. The loan has no
// creation event: it is live from entry and roots parameter provenance.
expose flow loanBindParam(graph: edit FlowGraph, path: Int, index: Int, is_mut: Bool, start: Int, end: Int) {
    change kind = LOAN_SHARED
    when is_mut { kind = LOAN_MUT }
    hold loan = loanNew(edit graph, kind, path, -1, start, end)
    graph.loans[loan].param = index
    loanBind(edit graph, path, loan)
}

// The storage a place denotes. A projection below a reference binding is
// replayed on the place borrowed by the binding's loan.
expose flow loanPlaceOf(graph: edit FlowGraph, path: Int) => Int {
    when path < 0 || path >= graph.paths.length { give -1 }
    hold loan = loanOfPath(graph, path)
    when loan < 0 { give path }
    hold root = flowRootPath(graph, path)
    change depth = 0
    change cursor = path
    during cursor != root {
        depth += 1
        cursor = graph.paths[cursor].parent
    }
    change place = graph.loans[loan].place
    change i = 0
    during i < depth {
        change hops = depth - 1 - i
        cursor = path
        during hops > 0 {
            cursor = graph.paths[cursor].parent
            hops -= 1
        }
        // Snapshot the projection index before taking a mutable loan of graph.
        // This preserves the exact path and avoids aliasing the graph argument.
        hold field = graph.paths[cursor].field
        place = flowField(edit graph, place, field)
        i += 1
    }
    give place
}

// Is `ancestor` on the reborrow chain of `loan` (inclusive)?
expose flow loanDescendsFrom(graph: view FlowGraph, loan: Int, ancestor: Int) => Bool {
    change cursor = loan
    during cursor >= 0 && cursor < graph.loans.length {
        when cursor == ancestor { give true }
        cursor = graph.loans[cursor].parent
    }
    give false
}

// Loans form a DAG through `parent` (reborrow) and `alt` (another origin
// of a borrowed call result). Both always point to a smaller id, so walks
// terminate. True when every root reachable from `loan` is a reference
// parameter: the value cannot outlive the call that received it.
flow loanRootedAtParams(graph: view FlowGraph, loan: Int) => Bool {
    change stack: List of[Int] = List[]
    stack@push(loan)
    during stack.length > 0 {
        change node = -1
        choose stack@pop() {
            Some(n) : { node = n }
            None : { leave }
        }
        when node >= 0 && node < graph.loans.length {
            hold parent = graph.loans[node].parent
            when parent < 0 {
                when graph.loans[node].param < 0 { give false }
            } otherwise {
                stack@push(parent)
            }
            when graph.loans[node].alt >= 0 { stack@push(graph.loans[node].alt) }
        }
    }
    give true
}

// Validates a borrowed return across the module boundary without exposing
// the provenance walker itself. Status: 0 allowed, 1 missing/invalid loan,
// 2 mutable mode mismatch, 3 loan origin not rooted in a parameter.
expose flow loanBorrowedReturnStatus(graph: view FlowGraph, loan: Int, requires_mut: Bool) => Int {
    when loan < 0 || loan >= graph.loans.length { give 1 }
    when requires_mut && !loanIsMut(graph, loan) { give 2 }
    when !loanRootedAtParams(graph, loan) { give 3 }
    give 0
}

// Result loan of a call to a borrowing function: one node per origin
// argument, chained through `alt`. Each node reborrows its origin so a use
// of the result keeps every possible owner borrowed.
expose flow loanResult(graph: edit FlowGraph, kind: Int, origins: view List of[Int], start: Int, end: Int) => Int {
    change head = -1
    change i = origins.length - 1
    during i >= 0 {
        hold origin = origins[i]
        // Capture the origin place before the exclusive borrow for loanNew.
        // This preserves which location is reborrowed without overlapping loans.
        hold borrowed_place = graph.loans[origin].place
        hold node = loanNew(edit graph, kind, borrowed_place, origin, start, end)
        graph.loans[node].alt = head
        head = node
        i -= 1
    }
    give head
}
