//! Desugaring of general `await` expressions inside `async fn` bodies.
//!
//! Flattens arbitrary compound expressions containing `await` into a sequence
//! of sequential statements and temporaries following strict left-to-right
//! evaluation order and short-circuit semantics, ensuring that all live temporaries
//! are first-class local variables recognized by the compiler's ownership,
//! drop elaboration, and async state machine lowering.

use crate::{
    Diagnostic,
    parser::{Expr, ExprKind, MatchArm, Stmt},
};

/// Returns true if `expr` or any of its subexpressions contains `ExprKind::Await(_)`.
pub fn has_await(expr: &Expr) -> bool {
    let mut found = false;
    walk_expr(expr, &mut |x| {
        if matches!(x.kind, ExprKind::Await(_)) {
            found = true;
        }
    });
    found
}

fn walk_expr(expr: &Expr, f: &mut impl FnMut(&Expr)) {
    f(expr);
    match &expr.kind {
        ExprKind::Named(_, inner)
        | ExprKind::Field(inner, _)
        | ExprKind::Try(inner)
        | ExprKind::Await(inner)
        | ExprKind::Spawn(inner)
        | ExprKind::Unary(_, inner) => walk_expr(inner, f),
        ExprKind::Index(a, b) | ExprKind::Binary(_, a, b) => {
            walk_expr(a, f);
            walk_expr(b, f);
        }
        ExprKind::Call(_, args) | ExprKind::GenericCall(_, _, args) => {
            for a in args {
                walk_expr(a, f);
            }
        }
        ExprKind::MethodCall(base, _, args) | ExprKind::GenericMethodCall(base, _, _, args) => {
            walk_expr(base, f);
            for a in args {
                walk_expr(a, f);
            }
        }
        ExprKind::ArrayLit(items) | ExprKind::ListLit(items) | ExprKind::Interpolate(items) => {
            for item in items {
                walk_expr(item, f);
            }
        }
        ExprKind::Match(scrutinee, arms) => {
            walk_expr(scrutinee, f);
            for arm in arms {
                for stmt in &arm.body {
                    walk_stmt(stmt, f);
                }
            }
        }
        ExprKind::Int(_)
        | ExprKind::Float(_)
        | ExprKind::Bool(_)
        | ExprKind::Unit
        | ExprKind::Text(_)
        | ExprKind::Name(_) => {}
    }
}

fn walk_stmt(stmt: &Stmt, f: &mut impl FnMut(&Expr)) {
    match stmt {
        Stmt::Let(_, _, _, e) | Stmt::Return(e) | Stmt::Expr(e, _) => walk_expr(e, f),
        Stmt::Const(c) => walk_expr(&c.value, f),
        Stmt::Assign(target, _, e, _) => {
            walk_expr(target, f);
            walk_expr(e, f);
        }
        Stmt::If(c, yes, no, _) => {
            walk_expr(c, f);
            for s in yes {
                walk_stmt(s, f);
            }
            for s in no {
                walk_stmt(s, f);
            }
        }
        Stmt::While(c, b) => {
            walk_expr(c, f);
            for s in b {
                walk_stmt(s, f);
            }
        }
        Stmt::For(_, _, start, end, _, b) => {
            walk_expr(start, f);
            walk_expr(end, f);
            for s in b {
                walk_stmt(s, f);
            }
        }
        Stmt::ForEach(_, _, coll, b) => {
            walk_expr(coll, f);
            for s in b {
                walk_stmt(s, f);
            }
        }
        Stmt::Loop(b) | Stmt::Block(b, _) | Stmt::Region(_, _, b) => {
            for s in b {
                walk_stmt(s, f);
            }
        }
        Stmt::Break(_) | Stmt::Continue(_) => {}
    }
}

/// Returns true if an expression is a side-effect-free, non-allocating, immutable primitive or variable.
fn is_trivial(e: &Expr) -> bool {
    matches!(
        e.kind,
        ExprKind::Int(_)
            | ExprKind::Float(_)
            | ExprKind::Bool(_)
            | ExprKind::Unit
            | ExprKind::Name(_)
    )
}

struct Desugarer {
    counter: usize,
}

impl Desugarer {
    fn new() -> Self {
        Self { counter: 0 }
    }

    fn fresh_tmp(&mut self) -> String {
        let name = format!("__l_await_tmp_{}", self.counter);
        self.counter += 1;
        name
    }

    pub fn desugar_stmts(&mut self, stmts: &[Stmt]) -> Result<Vec<Stmt>, Diagnostic> {
        let mut out = Vec::new();
        for stmt in stmts {
            self.desugar_stmt(stmt, &mut out)?;
        }
        Ok(out)
    }

    fn desugar_stmt(&mut self, stmt: &Stmt, out: &mut Vec<Stmt>) -> Result<(), Diagnostic> {
        match stmt {
            Stmt::Let(name, mutable, annotation, expr) => {
                if !has_await(expr) {
                    out.push(stmt.clone());
                } else if let ExprKind::Await(inner) = &expr.kind
                    && !has_await(inner)
                {
                    out.push(stmt.clone());
                } else {
                    let lowered = self.lower_expr(expr.clone(), out)?;
                    out.push(Stmt::Let(
                        name.clone(),
                        *mutable,
                        annotation.clone(),
                        lowered,
                    ));
                }
            }
            Stmt::Assign(target, op, value, span) => {
                if !has_await(target) && !has_await(value) {
                    out.push(stmt.clone());
                } else if op == "="
                    && !has_await(target)
                    && let ExprKind::Await(inner) = &value.kind
                    && !has_await(inner)
                {
                    out.push(stmt.clone());
                } else {
                    let target_lowered = self.lower_expr(target.clone(), out)?;
                    let value_lowered = self.lower_expr(value.clone(), out)?;
                    out.push(Stmt::Assign(
                        target_lowered,
                        op.clone(),
                        value_lowered,
                        *span,
                    ));
                }
            }
            Stmt::Return(expr) => {
                if !has_await(expr) {
                    out.push(stmt.clone());
                } else if let ExprKind::Await(inner) = &expr.kind
                    && !has_await(inner)
                {
                    out.push(stmt.clone());
                } else {
                    let lowered = self.lower_expr(expr.clone(), out)?;
                    out.push(Stmt::Return(lowered));
                }
            }
            Stmt::Expr(expr, explicit) => {
                if !has_await(expr) {
                    out.push(stmt.clone());
                } else if let ExprKind::Await(inner) = &expr.kind
                    && !has_await(inner)
                {
                    out.push(stmt.clone());
                } else {
                    let lowered = self.lower_expr(expr.clone(), out)?;
                    out.push(Stmt::Expr(lowered, *explicit));
                }
            }
            Stmt::If(cond, yes, no, explicit) => {
                let yes_desugared = self.desugar_stmts(yes)?;
                let no_desugared = self.desugar_stmts(no)?;
                if !has_await(cond) {
                    out.push(Stmt::If(
                        cond.clone(),
                        yes_desugared,
                        no_desugared,
                        *explicit,
                    ));
                } else {
                    let cond_lowered = self.lower_expr(cond.clone(), out)?;
                    out.push(Stmt::If(
                        cond_lowered,
                        yes_desugared,
                        no_desugared,
                        *explicit,
                    ));
                }
            }
            Stmt::While(cond, body) => {
                let body_desugared = self.desugar_stmts(body)?;
                if !has_await(cond) {
                    out.push(Stmt::While(cond.clone(), body_desugared));
                } else {
                    let mut loop_body = Vec::new();
                    let cond_lowered = self.lower_expr(cond.clone(), &mut loop_body)?;
                    let not_cond = Expr {
                        kind: ExprKind::Unary("!".into(), Box::new(cond_lowered)),
                        span: cond.span,
                    };
                    loop_body.push(Stmt::If(
                        not_cond,
                        vec![Stmt::Break(cond.span)],
                        Vec::new(),
                        true,
                    ));
                    loop_body.extend(body_desugared);
                    out.push(Stmt::Loop(loop_body));
                }
            }
            Stmt::For(name, span, start, end, inclusive, body) => {
                let body_desugared = self.desugar_stmts(body)?;
                let start_lowered = if has_await(start) {
                    self.lower_expr(start.clone(), out)?
                } else {
                    start.clone()
                };
                let end_lowered = if has_await(end) {
                    self.lower_expr(end.clone(), out)?
                } else {
                    end.clone()
                };
                out.push(Stmt::For(
                    name.clone(),
                    *span,
                    start_lowered,
                    end_lowered,
                    *inclusive,
                    body_desugared,
                ));
            }
            Stmt::ForEach(name, span, coll, body) => {
                let body_desugared = self.desugar_stmts(body)?;
                let coll_lowered = if has_await(coll) {
                    self.lower_expr(coll.clone(), out)?
                } else {
                    coll.clone()
                };
                out.push(Stmt::ForEach(
                    name.clone(),
                    *span,
                    coll_lowered,
                    body_desugared,
                ));
            }
            Stmt::Loop(body) => {
                let body_desugared = self.desugar_stmts(body)?;
                out.push(Stmt::Loop(body_desugared));
            }
            Stmt::Block(body, is_unsafe) => {
                let body_desugared = self.desugar_stmts(body)?;
                out.push(Stmt::Block(body_desugared, *is_unsafe));
            }
            Stmt::Region(name, span, body) => {
                let body_desugared = self.desugar_stmts(body)?;
                out.push(Stmt::Region(name.clone(), *span, body_desugared));
            }
            Stmt::Const(_) | Stmt::Break(_) | Stmt::Continue(_) => {
                out.push(stmt.clone());
            }
        }
        Ok(())
    }

    fn lower_expr(&mut self, expr: Expr, out: &mut Vec<Stmt>) -> Result<Expr, Diagnostic> {
        if !has_await(&expr) {
            return Ok(expr);
        }
        match expr.kind {
            ExprKind::Await(inner) => {
                let inner_lowered = self.lower_expr(*inner, out)?;
                let tmp = self.fresh_tmp();
                out.push(Stmt::Let(
                    tmp.clone(),
                    false,
                    None,
                    Expr {
                        kind: ExprKind::Await(Box::new(inner_lowered)),
                        span: expr.span,
                    },
                ));
                Ok(Expr {
                    kind: ExprKind::Name(tmp),
                    span: expr.span,
                })
            }
            ExprKind::Unary(op, inner) => {
                let inner_lowered = self.lower_expr(*inner, out)?;
                Ok(Expr {
                    kind: ExprKind::Unary(op, Box::new(inner_lowered)),
                    span: expr.span,
                })
            }
            ExprKind::Binary(op, lhs, rhs) if op == "&&" => {
                if !has_await(&rhs) {
                    let l = self.lower_expr(*lhs, out)?;
                    Ok(Expr {
                        kind: ExprKind::Binary(op, Box::new(l), rhs),
                        span: expr.span,
                    })
                } else {
                    let l = self.lower_expr(*lhs, out)?;
                    let res_tmp = self.fresh_tmp();
                    out.push(Stmt::Let(
                        res_tmp.clone(),
                        true,
                        None,
                        Expr {
                            kind: ExprKind::Bool(false),
                            span: expr.span,
                        },
                    ));
                    let mut then_stmts = Vec::new();
                    let r = self.lower_expr(*rhs, &mut then_stmts)?;
                    then_stmts.push(Stmt::Assign(
                        Expr {
                            kind: ExprKind::Name(res_tmp.clone()),
                            span: expr.span,
                        },
                        "=".into(),
                        r,
                        expr.span,
                    ));
                    out.push(Stmt::If(l, then_stmts, Vec::new(), true));
                    Ok(Expr {
                        kind: ExprKind::Name(res_tmp),
                        span: expr.span,
                    })
                }
            }
            ExprKind::Binary(op, lhs, rhs) if op == "||" => {
                if !has_await(&rhs) {
                    let l = self.lower_expr(*lhs, out)?;
                    Ok(Expr {
                        kind: ExprKind::Binary(op, Box::new(l), rhs),
                        span: expr.span,
                    })
                } else {
                    let l = self.lower_expr(*lhs, out)?;
                    let res_tmp = self.fresh_tmp();
                    out.push(Stmt::Let(
                        res_tmp.clone(),
                        true,
                        None,
                        Expr {
                            kind: ExprKind::Bool(true),
                            span: expr.span,
                        },
                    ));
                    let mut then_stmts = Vec::new();
                    let r = self.lower_expr(*rhs, &mut then_stmts)?;
                    then_stmts.push(Stmt::Assign(
                        Expr {
                            kind: ExprKind::Name(res_tmp.clone()),
                            span: expr.span,
                        },
                        "=".into(),
                        r,
                        expr.span,
                    ));
                    let not_l = Expr {
                        kind: ExprKind::Unary("!".into(), Box::new(l)),
                        span: expr.span,
                    };
                    out.push(Stmt::If(not_l, then_stmts, Vec::new(), true));
                    Ok(Expr {
                        kind: ExprKind::Name(res_tmp),
                        span: expr.span,
                    })
                }
            }
            ExprKind::Binary(op, lhs, rhs) => {
                let (lhs_val, rhs_val) = if has_await(&rhs) {
                    let l = self.lower_expr(*lhs, out)?;
                    let l_held = if !is_trivial(&l) {
                        let tmp = self.fresh_tmp();
                        let span = l.span;
                        out.push(Stmt::Let(tmp.clone(), false, None, l));
                        Expr {
                            kind: ExprKind::Name(tmp),
                            span,
                        }
                    } else {
                        l
                    };
                    let r = self.lower_expr(*rhs, out)?;
                    (l_held, r)
                } else {
                    let l = self.lower_expr(*lhs, out)?;
                    (l, *rhs)
                };
                Ok(Expr {
                    kind: ExprKind::Binary(op, Box::new(lhs_val), Box::new(rhs_val)),
                    span: expr.span,
                })
            }
            ExprKind::Call(name, args) => {
                let args_lowered = self.lower_expr_list(args, out)?;
                Ok(Expr {
                    kind: ExprKind::Call(name, args_lowered),
                    span: expr.span,
                })
            }
            ExprKind::GenericCall(name, ty_args, args) => {
                let args_lowered = self.lower_expr_list(args, out)?;
                Ok(Expr {
                    kind: ExprKind::GenericCall(name, ty_args, args_lowered),
                    span: expr.span,
                })
            }
            ExprKind::MethodCall(base, member, args) => {
                let base_has_await = has_await(&base);
                let args_have_await = args.iter().any(has_await);
                let base_lowered = if args_have_await {
                    let b = self.lower_expr(*base, out)?;
                    if !is_trivial(&b) {
                        let tmp = self.fresh_tmp();
                        let span = b.span;
                        out.push(Stmt::Let(tmp.clone(), false, None, b));
                        Expr {
                            kind: ExprKind::Name(tmp),
                            span,
                        }
                    } else {
                        b
                    }
                } else if base_has_await {
                    self.lower_expr(*base, out)?
                } else {
                    *base
                };
                let args_lowered = self.lower_expr_list(args, out)?;
                Ok(Expr {
                    kind: ExprKind::MethodCall(Box::new(base_lowered), member, args_lowered),
                    span: expr.span,
                })
            }
            ExprKind::GenericMethodCall(base, member, ty_args, args) => {
                let base_has_await = has_await(&base);
                let args_have_await = args.iter().any(has_await);
                let base_lowered = if args_have_await {
                    let b = self.lower_expr(*base, out)?;
                    if !is_trivial(&b) {
                        let tmp = self.fresh_tmp();
                        let span = b.span;
                        out.push(Stmt::Let(tmp.clone(), false, None, b));
                        Expr {
                            kind: ExprKind::Name(tmp),
                            span,
                        }
                    } else {
                        b
                    }
                } else if base_has_await {
                    self.lower_expr(*base, out)?
                } else {
                    *base
                };
                let args_lowered = self.lower_expr_list(args, out)?;
                Ok(Expr {
                    kind: ExprKind::GenericMethodCall(
                        Box::new(base_lowered),
                        member,
                        ty_args,
                        args_lowered,
                    ),
                    span: expr.span,
                })
            }
            ExprKind::Named(name, val) => {
                let val_lowered = self.lower_expr(*val, out)?;
                Ok(Expr {
                    kind: ExprKind::Named(name, Box::new(val_lowered)),
                    span: expr.span,
                })
            }
            ExprKind::Field(base, field) => {
                let base_lowered = self.lower_expr(*base, out)?;
                Ok(Expr {
                    kind: ExprKind::Field(Box::new(base_lowered), field),
                    span: expr.span,
                })
            }
            ExprKind::Index(base, index) => {
                let index_has_await = has_await(&index);
                let base_lowered = if index_has_await {
                    let b = self.lower_expr(*base, out)?;
                    if !is_trivial(&b) {
                        let tmp = self.fresh_tmp();
                        let span = b.span;
                        out.push(Stmt::Let(tmp.clone(), false, None, b));
                        Expr {
                            kind: ExprKind::Name(tmp),
                            span,
                        }
                    } else {
                        b
                    }
                } else {
                    self.lower_expr(*base, out)?
                };
                let index_lowered = self.lower_expr(*index, out)?;
                Ok(Expr {
                    kind: ExprKind::Index(Box::new(base_lowered), Box::new(index_lowered)),
                    span: expr.span,
                })
            }
            ExprKind::Try(inner) => {
                let inner_lowered = self.lower_expr(*inner, out)?;
                Ok(Expr {
                    kind: ExprKind::Try(Box::new(inner_lowered)),
                    span: expr.span,
                })
            }
            ExprKind::Spawn(inner) => {
                let inner_lowered = self.lower_expr(*inner, out)?;
                Ok(Expr {
                    kind: ExprKind::Spawn(Box::new(inner_lowered)),
                    span: expr.span,
                })
            }
            ExprKind::ArrayLit(items) => {
                let items_lowered = self.lower_expr_list(items, out)?;
                Ok(Expr {
                    kind: ExprKind::ArrayLit(items_lowered),
                    span: expr.span,
                })
            }
            ExprKind::ListLit(items) => {
                let items_lowered = self.lower_expr_list(items, out)?;
                Ok(Expr {
                    kind: ExprKind::ListLit(items_lowered),
                    span: expr.span,
                })
            }
            ExprKind::Interpolate(parts) => {
                let parts_lowered = self.lower_expr_list(parts, out)?;
                Ok(Expr {
                    kind: ExprKind::Interpolate(parts_lowered),
                    span: expr.span,
                })
            }
            ExprKind::Match(scrutinee, arms) => {
                let s = self.lower_expr(*scrutinee, out)?;
                let mut arms_lowered = Vec::new();
                for arm in arms {
                    let body = self.desugar_stmts(&arm.body)?;
                    arms_lowered.push(MatchArm {
                        pattern: arm.pattern,
                        body,
                        span: arm.span,
                    });
                }
                Ok(Expr {
                    kind: ExprKind::Match(Box::new(s), arms_lowered),
                    span: expr.span,
                })
            }
            ExprKind::Int(_)
            | ExprKind::Float(_)
            | ExprKind::Bool(_)
            | ExprKind::Unit
            | ExprKind::Text(_)
            | ExprKind::Name(_) => Ok(expr),
        }
    }

    fn lower_expr_list(
        &mut self,
        list: Vec<Expr>,
        out: &mut Vec<Stmt>,
    ) -> Result<Vec<Expr>, Diagnostic> {
        let last_await_idx = list.iter().rposition(has_await);
        let Some(last_await) = last_await_idx else {
            return Ok(list);
        };
        let mut result = Vec::new();
        for (i, item) in list.into_iter().enumerate() {
            let item_span = item.span;
            if let ExprKind::Named(name, val) = item.kind {
                if has_await(&val) {
                    let val_lowered = self.lower_expr(*val, out)?;
                    if i < last_await && !is_trivial(&val_lowered) {
                        let tmp = self.fresh_tmp();
                        out.push(Stmt::Let(tmp.clone(), false, None, val_lowered));
                        result.push(Expr {
                            kind: ExprKind::Named(
                                name,
                                Box::new(Expr {
                                    kind: ExprKind::Name(tmp),
                                    span: item_span,
                                }),
                            ),
                            span: item_span,
                        });
                    } else {
                        result.push(Expr {
                            kind: ExprKind::Named(name, Box::new(val_lowered)),
                            span: item_span,
                        });
                    }
                } else if i < last_await && !is_trivial(&val) {
                    let tmp = self.fresh_tmp();
                    out.push(Stmt::Let(tmp.clone(), false, None, *val));
                    result.push(Expr {
                        kind: ExprKind::Named(
                            name,
                            Box::new(Expr {
                                kind: ExprKind::Name(tmp),
                                span: item_span,
                            }),
                        ),
                        span: item_span,
                    });
                } else {
                    result.push(Expr {
                        kind: ExprKind::Named(name, val),
                        span: item_span,
                    });
                }
            } else if has_await(&item) {
                let lowered = self.lower_expr(item, out)?;
                if i < last_await && !is_trivial(&lowered) {
                    let tmp = self.fresh_tmp();
                    out.push(Stmt::Let(tmp.clone(), false, None, lowered));
                    result.push(Expr {
                        kind: ExprKind::Name(tmp),
                        span: item_span,
                    });
                } else {
                    result.push(lowered);
                }
            } else if i < last_await && !is_trivial(&item) {
                let tmp = self.fresh_tmp();
                out.push(Stmt::Let(tmp.clone(), false, None, item));
                result.push(Expr {
                    kind: ExprKind::Name(tmp),
                    span: item_span,
                });
            } else {
                result.push(item);
            }
        }
        Ok(result)
    }
}

/// Desugars all expressions containing `await` inside an `async fn`'s statements into
/// statement-level `await`s and temporary variable bindings.
pub fn desugar_async_stmts(stmts: &[Stmt]) -> Result<Vec<Stmt>, Diagnostic> {
    let mut desugarer = Desugarer::new();
    desugarer.desugar_stmts(stmts)
}
