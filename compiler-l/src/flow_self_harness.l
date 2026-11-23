take flow_cfg

// Integration entry: the implementation of flowNew and flowBlock remains in
// flow_cfg.l. This file only calls those real Stage 1 compiler functions.
flow main() => Int {
    change graph = flowNew()
    hold before = graph.blocks.length
    hold next = flowBlock(edit graph)
    when before != 1 { give 10 }
    when next != 1 { give 11 }
    give graph.blocks.length
}
