take ast
take sema_context
take sema_drop

// Kept separate to preserve the Stage 0 CORE-1 token budget per module.
expose flow semaReadTemp(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr_id: Int, ty: Int, mark: Int) {
    when ctx.expression_path >= 0 || expr_id < 0 { give }
    choose tree.expressions[expr_id].kind {
        AstExprKind.TextLit : { give }
        _ : {}
    }
    semaTempAt(edit ctx, source, tree, ty, tree.expressions[expr_id].start, tree.expressions[expr_id].end, mark)
}
