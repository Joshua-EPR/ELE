take tokens
take ast
take flow_cfg
take loans_l
take drops_plan

// Deterministic text form of a DropPlan (`sema-l archivo.l --drop-plan`),
// used by the differential tests to execute the plan path by path:
//   DropPlan fn=<line>:<col> blocks=<n> flags=<n> ops=<n> drops=<n>
//   B <block> <next_a> <next_b> <reached 0|1>
//   O <drop|cdrop|set|clear|ref> <place> <flag>
// A place is P<i> (parameter i) or S<line>:<col> (initializer or
// temporary) followed by `.k` per struct field, k counted from 0.

flow dropLine(source: view Text, offset: Int) => Text {
    hold line = loanLineAt(source, offset)
    hold col = loanColAt(source, offset)
    give "{line}:{col}"
}

// Index of an AST field inside its struct declaration.
flow dropLocalField(tree: view AstTree, field: Int) => Int {
    each d among 0..tree.declarations.length {
        hold decl = view tree.declarations[d]
        choose decl.kind {
            AstDeclKind.Struct : {
                when field >= decl.c && field < decl.c + decl.d { give field - decl.c }
            }
            _ : {}
        }
    }
    give -1
}

flow dropPlace(graph: view FlowGraph, source: view Text, tree: view AstTree, path: Int) => Text {
    change suffix = ""
    change cursor = path
    during graph.paths[cursor].parent >= 0 {
        hold k = dropLocalField(tree, graph.paths[cursor].field)
        suffix = ".{k}{suffix}"
        cursor = graph.paths[cursor].parent
    }
    change origin = FLOW_NO_ORIGIN
    when cursor < graph.origins.length { origin = graph.origins[cursor] }
    when origin < 0 && origin > FLOW_NO_ORIGIN {
        hold index = -1 - origin
        give "P{index}{suffix}"
    }
    when origin >= 0 {
        hold at = dropLine(source, origin)
        give "S{at}{suffix}"
    }
    give "?{suffix}"
}

flow dropKindName(kind: Int) => Text {
    when kind == DROP_OP_DROP { give "drop" }
    when kind == DROP_OP_COND { give "cdrop" }
    when kind == DROP_OP_SET { give "set" }
    when kind == DROP_OP_CLEAR { give "clear" }
    give "ref"
}

expose flow dropDump(graph: view FlowGraph, plan: view DropPlan, source: view Text, tree: view AstTree, name: Int) {
    hold at = dropLine(source, name)
    hold blocks = graph.blocks.length
    hold flags = plan.flag_paths.length
    hold ops = plan.ops.length
    hold drops = plan.drops
    print("DropPlan fn={at} blocks={blocks} flags={flags} ops={ops} drops={drops}")
    each b among 0..plan.block_first.length {
        hold a = graph.blocks[b].next_a
        hold c = graph.blocks[b].next_b
        change reached = 0
        when graph.reached[b] { reached = 1 }
        print("B {b} {a} {c} {reached}")
        hold first = plan.block_first[b]
        each i among first..(first + plan.block_count[b]) {
            hold op = view plan.ops[i]
            hold kind = dropKindName(op.kind)
            hold place = dropPlace(graph, source, tree, op.path)
            hold flag = op.flag
            print("O {kind} {place} {flag}")
        }
    }
}
