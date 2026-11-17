import ast
import sema_context
import sema_drop

// Kept separate to preserve the Stage 0 CORE-1 token budget per module.
pub fn semaReadTemp(ctx: &mut SemaContext, source: &Text, tree: &AstTree, expr_id: Int, ty: Int, mark: Int) {
    if ctx.expression_path >= 0 || expr_id < 0 { return }
    match tree.expressions[expr_id].kind {
        AstExprKind.TextLit => { return }
        _ => {}
    }
    semaTempAt(&mut ctx, source, tree, ty, tree.expressions[expr_id].start, tree.expressions[expr_id].end, mark)
}
