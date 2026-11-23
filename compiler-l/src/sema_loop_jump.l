take sema_context
take flow_cfg

expose flow semaJumpLoop(ctx: edit SemaContext, target: Int, start: Int, end: Int) {
    when target < 0 {
        semaAddError(edit ctx, "L0001", "salto fuera de un bucle", start, end)
    } otherwise {
        flowLink(edit ctx.flow, target, -1)
        hold detached = flowBlock(edit ctx.flow)
        ctx.flow.current = detached
    }
}
