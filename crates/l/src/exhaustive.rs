//! Pattern exhaustiveness and reachability ("usefulness", after Maranget,
//! *Warnings for pattern matching*, 2007). Works on typed LIR patterns only.
//!
//! A pattern vector `q` is useful with respect to rows `P` when some value
//! matches `q` but no row of `P`. An arm is unreachable when its pattern is not
//! useful against the previous arms; a match is exhaustive when `_` is not
//! useful against all arms. The witness returned for a useful `_` is a value
//! shape that no arm covers, used in diagnostics.
use crate::lir::{Pattern, Type};

/// Access to the variants of concrete enums.
pub trait Variants {
    /// Payload types of every variant, in discriminant order.
    fn payloads(&self, enum_id: usize) -> Vec<Vec<Type>>;
    /// How a variant is written in source (`Estado.Error`, `Some`).
    fn variant_name(&self, enum_id: usize, variant: usize) -> String;
}

#[derive(Debug, Clone, PartialEq)]
enum Ctor {
    Variant(usize),
    Bool(bool),
    Int(i64),
    Text(String),
}

#[derive(Debug, Clone)]
enum Pat {
    Wild,
    Ctor(Ctor, Vec<Pat>),
}

fn lower(p: &Pattern) -> Pat {
    match p {
        Pattern::Wild | Pattern::Bind(_) => Pat::Wild,
        Pattern::Int(n) => Pat::Ctor(Ctor::Int(*n), Vec::new()),
        Pattern::Bool(b) => Pat::Ctor(Ctor::Bool(*b), Vec::new()),
        Pattern::Text(s) => Pat::Ctor(Ctor::Text(s.clone()), Vec::new()),
        Pattern::Variant(_, v, subs) => {
            Pat::Ctor(Ctor::Variant(*v), subs.iter().map(lower).collect())
        }
    }
}

/// Complete constructor set of a type, if it is finite.
fn signature(ctx: &dyn Variants, ty: Type) -> Option<Vec<Ctor>> {
    match ty {
        Type::Bool => Some(vec![Ctor::Bool(false), Ctor::Bool(true)]),
        Type::Enum(id) => Some((0..ctx.payloads(id).len()).map(Ctor::Variant).collect()),
        _ => None,
    }
}

fn arity(ctx: &dyn Variants, ty: Type, c: &Ctor) -> Vec<Type> {
    match (ty, c) {
        (Type::Enum(id), Ctor::Variant(v)) => ctx.payloads(id)[*v].clone(),
        _ => Vec::new(),
    }
}

fn render(ctx: &dyn Variants, ty: Type, c: &Ctor, args: &[String]) -> String {
    match c {
        Ctor::Bool(b) => b.to_string(),
        Ctor::Int(n) => n.to_string(),
        Ctor::Text(s) => format!("{s:?}"),
        Ctor::Variant(v) => {
            let Type::Enum(id) = ty else {
                return "_".into();
            };
            let name = ctx.variant_name(id, *v);
            if args.is_empty() {
                name
            } else {
                format!("{name}({})", args.join(", "))
            }
        }
    }
}

fn specialize(row: &[Pat], c: &Ctor, n: usize) -> Option<Vec<Pat>> {
    let (head, rest) = row.split_first()?;
    let mut out = match head {
        Pat::Wild => vec![Pat::Wild; n],
        Pat::Ctor(c2, args) if c2 == c => args.clone(),
        Pat::Ctor(..) => return None,
    };
    out.extend_from_slice(rest);
    Some(out)
}

/// Returns a witness (one rendered pattern per column) if `q` is useful.
fn useful(ctx: &dyn Variants, rows: &[Vec<Pat>], q: &[Pat], tys: &[Type]) -> Option<Vec<String>> {
    let Some((head, rest)) = q.split_first() else {
        return rows.is_empty().then(Vec::new);
    };
    let ty = tys[0];
    let specialized = |c: &Ctor, sub: &[Pat]| -> Option<Vec<String>> {
        let args = arity(ctx, ty, c);
        let rows: Vec<Vec<Pat>> = rows
            .iter()
            .filter_map(|r| specialize(r, c, args.len()))
            .collect();
        let mut q2 = sub.to_vec();
        q2.extend_from_slice(rest);
        let mut tys2 = args.clone();
        tys2.extend_from_slice(&tys[1..]);
        let mut w = useful(ctx, &rows, &q2, &tys2)?;
        let tail = w.split_off(args.len());
        let mut out = vec![render(ctx, ty, c, &w)];
        out.extend(tail);
        Some(out)
    };
    match head {
        Pat::Ctor(c, args) => specialized(c, args),
        Pat::Wild => {
            let used: Vec<Ctor> = rows
                .iter()
                .filter_map(|r| match r.first() {
                    Some(Pat::Ctor(c, _)) => Some(c.clone()),
                    _ => None,
                })
                .collect();
            if let Some(all) = signature(ctx, ty)
                && all.iter().all(|c| used.contains(c))
            {
                return all.iter().find_map(|c| {
                    let wild = vec![Pat::Wild; arity(ctx, ty, c).len()];
                    specialized(c, &wild)
                });
            }
            // Incomplete or infinite signature: only rows starting with `_` matter.
            let default: Vec<Vec<Pat>> = rows
                .iter()
                .filter(|r| matches!(r.first(), Some(Pat::Wild)))
                .map(|r| r[1..].to_vec())
                .collect();
            let mut w = useful(ctx, &default, rest, &tys[1..])?;
            let missing = signature(ctx, ty).and_then(|all| {
                all.into_iter().find(|c| !used.contains(c)).map(|c| {
                    let wild = vec!["_".to_string(); arity(ctx, ty, &c).len()];
                    render(ctx, ty, &c, &wild)
                })
            });
            w.insert(0, missing.unwrap_or_else(|| "_".into()));
            Some(w)
        }
    }
}

pub enum Issue {
    /// Arm index whose pattern can never match.
    Unreachable(usize),
    /// Example of a value no arm matches.
    Missing(String),
}

/// Checks reachability of every arm, then exhaustiveness.
pub fn check(ctx: &dyn Variants, ty: Type, arms: &[&Pattern]) -> Result<(), Issue> {
    let mut rows: Vec<Vec<Pat>> = Vec::new();
    for (i, p) in arms.iter().enumerate() {
        let row = vec![lower(p)];
        if useful(ctx, &rows, &row, &[ty]).is_none() {
            return Err(Issue::Unreachable(i));
        }
        rows.push(row);
    }
    match useful(ctx, &rows, &[Pat::Wild], &[ty]) {
        Some(w) => Err(Issue::Missing(w.join(", "))),
        None => Ok(()),
    }
}
