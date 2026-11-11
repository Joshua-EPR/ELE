import sema_context
import flow_cfg

pub fn semaJumpLoop(ctx: &mut SemaContext, target: Int, start: Int, end: Int) {
    if target < 0 {
        semaAddError(&mut ctx, "L0001", "salto fuera de un bucle", start, end)
    } else {
        flowLink(&mut ctx.flow, target, -1)
        let detached = flowBlock(&mut ctx.flow)
        ctx.flow.current = detached
    }
}
