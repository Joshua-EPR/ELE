import flow_cfg

// Integration entry: the implementation of flowNew and flowBlock remains in
// flow_cfg.l. This file only calls those real Stage 1 compiler functions.
fn main() -> Int {
    var graph = flowNew()
    let before = graph.blocks.length
    let next = flowBlock(&mut graph)
    if before != 1 { return 10 }
    if next != 1 { return 11 }
    return graph.blocks.length
}
