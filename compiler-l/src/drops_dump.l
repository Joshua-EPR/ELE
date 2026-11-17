import tokens
import ast
import flow_cfg
import loans_l
import drops_plan

// Deterministic text form of a DropPlan (`sema-l archivo.l --drop-plan`),
// used by the differential tests to execute the plan path by path:
//   DropPlan fn=<line>:<col> blocks=<n> flags=<n> ops=<n> drops=<n>
//   B <block> <next_a> <next_b> <reached 0|1>
//   O <drop|cdrop|set|clear|ref> <place> <flag>
// A place is P<i> (parameter i) or S<line>:<col> (initializer or
// temporary) followed by `.k` per struct field, k counted from 0.

fn dropLine(source: &Text, offset: Int) -> Text {
    let line = loanLineAt(source, offset)
    let col = loanColAt(source, offset)
    return "{line}:{col}"
}

// Index of an AST field inside its struct declaration.
fn dropLocalField(tree: &AstTree, field: Int) -> Int {
    for d in 0..tree.declarations.length {
        let decl = &tree.declarations[d]
        match decl.kind {
            AstDeclKind.Struct => {
                if field >= decl.c && field < decl.c + decl.d { return field - decl.c }
            }
            _ => {}
        }
    }
    return -1
}

fn dropPlace(graph: &FlowGraph, source: &Text, tree: &AstTree, path: Int) -> Text {
    var suffix = ""
    var cursor = path
    while graph.paths[cursor].parent >= 0 {
        let k = dropLocalField(tree, graph.paths[cursor].field)
        suffix = ".{k}{suffix}"
        cursor = graph.paths[cursor].parent
    }
    var origin = FLOW_NO_ORIGIN
    if cursor < graph.origins.length { origin = graph.origins[cursor] }
    if origin < 0 && origin > FLOW_NO_ORIGIN {
        let index = -1 - origin
        return "P{index}{suffix}"
    }
    if origin >= 0 {
        let at = dropLine(source, origin)
        return "S{at}{suffix}"
    }
    return "?{suffix}"
}

fn dropKindName(kind: Int) -> Text {
    if kind == DROP_OP_DROP { return "drop" }
    if kind == DROP_OP_COND { return "cdrop" }
    if kind == DROP_OP_SET { return "set" }
    if kind == DROP_OP_CLEAR { return "clear" }
    return "ref"
}

pub fn dropDump(graph: &FlowGraph, plan: &DropPlan, source: &Text, tree: &AstTree, name: Int) {
    let at = dropLine(source, name)
    let blocks = graph.blocks.length
    let flags = plan.flag_paths.length
    let ops = plan.ops.length
    let drops = plan.drops
    print("DropPlan fn={at} blocks={blocks} flags={flags} ops={ops} drops={drops}")
    for b in 0..plan.block_first.length {
        let a = graph.blocks[b].next_a
        let c = graph.blocks[b].next_b
        var reached = 0
        if graph.reached[b] { reached = 1 }
        print("B {b} {a} {c} {reached}")
        let first = plan.block_first[b]
        for i in first..(first + plan.block_count[b]) {
            let op = &plan.ops[i]
            let kind = dropKindName(op.kind)
            let place = dropPlace(graph, source, tree, op.path)
            let flag = op.flag
            print("O {kind} {place} {flag}")
        }
    }
}
