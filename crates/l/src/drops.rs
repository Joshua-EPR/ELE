//! Drop elaboration and ownership verification on block-based LIR.
//!
//! Lowering (`cfg.rs`) emits `Drop(v)` for every owned variable at every exit
//! of the lexical region that owns it (end of statement for temporaries, end of
//! scope for locals, `return`, `break`, `continue`). Those drops are naive: the
//! variable may have been moved before. This pass decides what each one means:
//!
//! 1. A forward dataflow computes, at every point, whether each owned variable
//!    is `Init`, `Uninit` (never assigned, moved or dropped) or `Maybe`.
//! 2. `Drop(v)` where `v` is `Init` stays; where it is `Uninit` it is removed;
//!    where it is `Maybe` it becomes conditional on a *drop flag*, a Bool
//!    variable kept equal to "v currently owns a value" (set on assignment,
//!    cleared on move and on drop).
//! 3. Assigning to an owned variable that may still own a value first drops
//!    the old value (after the new value has been computed).
//!
//! `verify` then proves, independently of how the drops were produced, the
//! invariants every backend relies on:
//! - an owned variable is read, borrowed or moved only when it is `Init`
//!   (no use after move, no use of uninitialized memory);
//! - an unconditional drop happens only when it is `Init` (no double free);
//! - an assignment never overwrites an owned value (no leak by overwrite);
//! - at every `return` no owned variable still owns a value (no leak).
//!
//! Struct resources are tracked by hierarchical field paths. Enums remain
//! atomic pending variant-sensitive ownership and native enum code generation.
use crate::{
    cfg::{
        Arg, Const, Func, Inst, InstKind, Module, Operand, Place, Proj, Rvalue, Terminator, VarId,
        VarTy,
    },
    lir::{EnumDef, StructDef, Type},
};
use std::collections::{HashMap, HashSet};

/// Which types own resources that must be released.
pub struct Ownership {
    structs: Vec<bool>,
    enums: Vec<bool>,
    /// Element type of each array type, and whether it needs a drop.
    arrays: Vec<crate::lir::ArrayDef>,
    /// Element type of each list type.
    lists: Vec<Type>,
    fields: Vec<Vec<Type>>,
    payloads: Vec<Vec<Vec<Type>>>,
}

impl Ownership {
    pub fn new(
        structs: &[StructDef],
        enums: &[EnumDef],
        arrays: &[crate::lir::ArrayDef],
        lists: &[Type],
    ) -> Self {
        // Types cannot contain themselves by value (rejected by sema), so a
        // fixed point over the declarations terminates.
        let mut o = Ownership {
            structs: vec![false; structs.len()],
            enums: vec![false; enums.len()],
            arrays: arrays.to_vec(),
            lists: lists.to_vec(),
            fields: structs
                .iter()
                .map(|s| s.fields.iter().map(|(_, t)| *t).collect())
                .collect(),
            payloads: enums
                .iter()
                .map(|e| e.variants.iter().map(|(_, ts)| ts.clone()).collect())
                .collect(),
        };
        loop {
            let mut changed = false;
            for (i, s) in structs.iter().enumerate() {
                let v = s.fields.iter().any(|(_, t)| o.needs_drop(*t));
                changed |= v != o.structs[i];
                o.structs[i] = v;
            }
            for (i, e) in enums.iter().enumerate() {
                let v = e
                    .variants
                    .iter()
                    .any(|(_, p)| p.iter().any(|t| o.needs_drop(*t)));
                changed |= v != o.enums[i];
                o.enums[i] = v;
            }
            if !changed {
                return o;
            }
        }
    }
    /// Text owns a buffer (unless static); aggregates own what their parts own.
    pub fn needs_drop(&self, t: Type) -> bool {
        match t {
            Type::Text => true,
            // A region owns its blocks; its drop releases all of them.
            Type::Region(_) => true,
            Type::Struct(i) => self.structs[i],
            Type::Enum(i) => self.enums[i],
            // An array owns exactly what its elements own.
            Type::Array(a) => self.needs_drop(self.arrays[a].elem),
            // A future owns its task state (and whatever it holds).
            Type::Future(_) | Type::Task(_) => true,
            // A list or task group always owns its buffer (and its elements' resources).
            Type::List(_) | Type::RegionList(..) | Type::TaskGroup(_) => true,
            _ => false,
        }
    }
    fn elem(&self, t: Type) -> Option<Type> {
        match t {
            Type::Array(a) => self.arrays.get(a).map(|d| d.elem),
            Type::List(l) | Type::RegionList(l, _) => self.lists.get(l).copied(),
            _ => None,
        }
    }
}

fn root(var: VarId) -> Place {
    Place {
        var,
        proj: Vec::new(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    Use(Place),
    Move(Place),
    Def(Place),
    Drop(Place),
}

pub struct Owned<'a> {
    pub vars: &'a [VarTy],
    pub ownership: &'a Ownership,
}
impl Owned<'_> {
    pub fn tracked(&self, v: VarId) -> bool {
        matches!(self.vars.get(v), Some(VarTy::Value(t)) if self.ownership.needs_drop(*t))
    }
    pub fn place_type(&self, p: &Place) -> Option<Type> {
        let mut t = self.vars.get(p.var)?.pointee();
        for projection in &p.proj {
            t = match (t, projection) {
                (Type::Struct(s), Proj::Field(f)) => *self.ownership.fields.get(s)?.get(*f)?,
                (Type::Enum(e), Proj::Payload(v, f)) => {
                    *self.ownership.payloads.get(e)?.get(*v)?.get(*f)?
                }
                (t, Proj::Index(_)) => self.ownership.elem(t)?,
                _ => return None,
            };
        }
        Some(t)
    }
    /// Resource leaves below a struct place. Enum payload paths conservatively
    /// refer to their atomic owning enum; native variants remain unsupported.
    fn leaves(&self, p: &Place) -> Vec<Place> {
        if !self.tracked(p.var) {
            return Vec::new();
        }
        // Collections are atomic resources: an element path stands for its
        // owning collection (elements are dropped by the collection's glue).
        if let Some(at) = p
            .proj
            .iter()
            .position(|p| matches!(p, Proj::Payload(..) | Proj::Index(_)))
        {
            let mut owner = p.clone();
            owner.proj.truncate(at);
            return vec![owner];
        }
        let mut out = Vec::new();
        if let Some(t) = self.place_type(p) {
            self.expand(p.clone(), t, &mut out);
        }
        out
    }
    fn expand(&self, p: Place, ty: Type, out: &mut Vec<Place>) {
        if let Type::Struct(s) = ty {
            for (i, t) in self.ownership.fields[s].iter().enumerate() {
                let mut field = p.clone();
                field.proj.push(Proj::Field(i));
                self.expand(field, *t, out);
            }
        } else if self.ownership.needs_drop(ty) {
            out.push(p);
        }
    }
    fn operand(&self, o: &Operand, consume: bool, effects: &mut Vec<Effect>) {
        if let Operand::Var(v) = o {
            effects.push(if consume {
                Effect::Move(root(*v))
            } else {
                Effect::Use(root(*v))
            });
        }
    }
    fn arg(&self, a: &Arg, consume: bool, effects: &mut Vec<Effect>) {
        match a {
            Arg::Value(o) => self.operand(o, consume, effects),
            Arg::Ref(p, _) => effects.push(Effect::Use(p.clone())),
        }
    }
    pub fn inst(&self, k: &InstKind) -> Vec<Effect> {
        let mut out = Vec::new();
        match k {
            InstKind::Assign(d, rv) => {
                match rv {
                    Rvalue::Use(o) => self.operand(o, true, &mut out),
                    Rvalue::Unary(_, o) => self.operand(o, false, &mut out),
                    Rvalue::Binary(_, a, b) => {
                        self.operand(a, false, &mut out);
                        self.operand(b, false, &mut out);
                    }
                    Rvalue::Call(_, args) | Rvalue::Platform(_, args, _) => {
                        for a in args {
                            self.arg(a, true, &mut out);
                        }
                    }
                    Rvalue::Struct(_, os) | Rvalue::Variant(_, _, os) => {
                        for o in os {
                            self.operand(o, true, &mut out);
                        }
                    }
                    // Reserving a task state owns nothing yet; reading the
                    // state behind a handle borrows the handle.
                    Rvalue::FutureNew(_) | Rvalue::GroupPending | Rvalue::TimerPending => {}
                    Rvalue::CheckSleep(ms) | Rvalue::TimerStart(ms) => {
                        self.operand(ms, false, &mut out)
                    }
                    Rvalue::FutureState(p)
                    | Rvalue::FuturePoll(p)
                    | Rvalue::TaskReady(p)
                    | Rvalue::TaskState(p)
                    | Rvalue::GroupRegister(p) => out.push(Effect::Use(p.clone())),
                    // Spawning moves the future into the scheduler.
                    Rvalue::TaskSpawn(o, _) => self.operand(o, true, &mut out),
                    Rvalue::Read(p) => {
                        // Enum bindings still have an explicit atomic Moved marker.
                        let moving = !p
                            .proj
                            .iter()
                            .any(|p| matches!(p, Proj::Payload(..) | Proj::Index(_)))
                            && self
                                .place_type(p)
                                .is_some_and(|t| self.ownership.needs_drop(t));
                        out.push(if moving {
                            Effect::Move(p.clone())
                        } else {
                            Effect::Use(p.clone())
                        });
                    }
                    Rvalue::FieldLoan(p)
                    | Rvalue::Ref(p)
                    | Rvalue::Loan(p, ..)
                    | Rvalue::Discriminant(p)
                    | Rvalue::TextEq(p, _) => out.push(Effect::Use(p.clone())),
                    Rvalue::Convert(o, _) => self.operand(o, false, &mut out),
                    Rvalue::TextBuffer(_) | Rvalue::RegionNew(_) => {}
                    // Allocating from a region or reading a buffer only
                    // borrows the region/buffer.
                    Rvalue::RegionList(p, _) => out.push(Effect::Use(p.clone())),
                    Rvalue::RegionBytes(p, o) | Rvalue::BytesGet(p, o) => {
                        self.operand(o, false, &mut out);
                        out.push(Effect::Use(p.clone()));
                    }
                    Rvalue::BytesLen(p) => out.push(Effect::Use(p.clone())),
                    Rvalue::ArrayLit(_, os) | Rvalue::ListLit(_, os) => {
                        for o in os {
                            self.operand(o, true, &mut out);
                        }
                    }
                    // Taking the last element moves it out of the list, whose
                    // length shrinks: the list keeps owning the rest.
                    Rvalue::Len(p)
                    | Rvalue::Cap(p)
                    | Rvalue::ListTakeLast(p)
                    | Rvalue::ListPop(p, _) => out.push(Effect::Use(p.clone())),
                }
                out.push(Effect::Def(root(*d)));
            }
            // Storing into an element replaces it (the backend drops the old
            // element); the collection stays initialized.
            InstKind::Store(p, o) if p.proj.iter().any(|x| matches!(x, Proj::Index(_))) => {
                self.operand(o, true, &mut out);
                out.push(Effect::Use(p.clone()));
            }
            InstKind::Store(p, o) => {
                self.operand(o, true, &mut out);
                out.push(Effect::Def(p.clone()));
            }
            InstKind::ListPush(p, o) => {
                self.operand(o, true, &mut out);
                out.push(Effect::Use(p.clone()));
            }
            InstKind::ListReserve(p, o) => {
                self.operand(o, false, &mut out);
                out.push(Effect::Use(p.clone()));
            }
            InstKind::Append(v, a) => {
                self.arg(a, false, &mut out);
                out.push(Effect::Use(root(*v)));
            }
            InstKind::Print(a) => self.arg(a, false, &mut out),
            InstKind::BytesSet(p, i, b) => {
                self.operand(i, false, &mut out);
                self.operand(b, false, &mut out);
                out.push(Effect::Use(p.clone()));
            }
            InstKind::Drop(v, _) => out.push(Effect::Drop(root(*v))),
            InstKind::DropField(p, _) => out.push(Effect::Drop(p.clone())),
            // Clearing a place makes it stop owning what it held (the value
            // was moved out beforehand); it never drops anything.
            InstKind::Clear(p) => out.push(Effect::Use(p.clone())),
            InstKind::Wake | InstKind::RunTasks => {}
            InstKind::Moved(v) => out.push(Effect::Move(root(*v))),
        }
        out
    }
    pub fn terminator(&self, t: &Terminator) -> Vec<Effect> {
        let mut out = Vec::new();
        match t {
            Terminator::Branch(c, ..) => self.operand(c, false, &mut out),
            Terminator::Return(o) => self.operand(o, true, &mut out),
            _ => {}
        }
        out
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Uninit,
    Init,
    Maybe,
}
fn join(a: State, b: State) -> State {
    if a == b { a } else { State::Maybe }
}
pub type States = HashMap<Place, State>;
fn apply(owned: &Owned, state: &mut States, effects: &[Effect]) {
    for e in effects {
        let (p, s) = match e {
            Effect::Move(p) | Effect::Drop(p) => (p, State::Uninit),
            Effect::Def(p) => (p, State::Init),
            Effect::Use(_) => continue,
        };
        for leaf in owned.leaves(p) {
            state.insert(leaf, s);
        }
    }
}
pub fn successors(t: &Terminator) -> Vec<usize> {
    match t {
        Terminator::Jump(b) => vec![*b],
        Terminator::Branch(_, a, b) => vec![*a, *b],
        _ => Vec::new(),
    }
}
pub fn reachable(f: &Func) -> Vec<bool> {
    let mut seen = vec![false; f.blocks.len()];
    let mut work = vec![0];
    while let Some(b) = work.pop() {
        if b >= seen.len() || std::mem::replace(&mut seen[b], true) {
            continue;
        }
        if let Some(t) = &f.blocks[b].term {
            work.extend(successors(t));
        }
    }
    seen
}
pub fn entry_states(f: &Func, owned: &Owned) -> Vec<Option<States>> {
    let mut start = States::new();
    for v in 0..f.vars.len() {
        for p in owned.leaves(&root(v)) {
            start.insert(p, State::Uninit);
        }
    }
    for v in &f.params {
        for p in owned.leaves(&root(*v)) {
            start.insert(p, State::Init);
        }
    }
    let mut entries = vec![None; f.blocks.len()];
    if entries.is_empty() {
        return entries;
    }
    entries[0] = Some(start);
    let mut work = vec![0];
    while let Some(b) = work.pop() {
        let Some(mut state) = entries[b].clone() else {
            continue;
        };
        for inst in &f.blocks[b].insts {
            apply(owned, &mut state, &owned.inst(&inst.kind));
        }
        let Some(t) = &f.blocks[b].term else {
            continue;
        };
        apply(owned, &mut state, &owned.terminator(t));
        for next in successors(t) {
            if next >= entries.len() {
                continue;
            }
            let merged = match &entries[next] {
                None => state.clone(),
                Some(old) => old
                    .iter()
                    .map(|(p, s)| (p.clone(), join(*s, state[p])))
                    .collect(),
            };
            if entries[next].as_ref() != Some(&merged) {
                entries[next] = Some(merged);
                work.push(next);
            }
        }
    }
    entries
}
fn drop_inst(p: Place, flag: Option<VarId>, span: crate::Span) -> Inst {
    Inst {
        kind: if p.proj.is_empty() {
            InstKind::Drop(p.var, flag)
        } else {
            InstKind::DropField(p, flag)
        },
        span,
    }
}
fn emit_drops(
    owned: &Owned,
    p: &Place,
    state: &States,
    flags: &mut HashMap<Place, VarId>,
    vars: &mut Vec<VarTy>,
    span: crate::Span,
    out: &mut Vec<Inst>,
) {
    for leaf in owned.leaves(p).into_iter().rev() {
        match state.get(&leaf).copied().unwrap_or(State::Uninit) {
            State::Uninit => {}
            State::Init => out.push(drop_inst(leaf, None, span)),
            State::Maybe => {
                let flag = *flags.entry(leaf.clone()).or_insert_with(|| {
                    let id = vars.len();
                    vars.push(VarTy::Value(Type::Bool));
                    id
                });
                out.push(drop_inst(leaf, Some(flag), span));
            }
        }
    }
}
pub fn elaborate(module: &mut Module, ownership: &Ownership) {
    for func in &mut module.funcs {
        let original = func.vars.clone();
        let owned = Owned {
            vars: &original,
            ownership,
        };
        let entries = entry_states(func, &owned);
        let mut flags = HashMap::new();
        for (b, block) in func.blocks.iter_mut().enumerate() {
            let Some(mut state) = entries[b].clone() else {
                block
                    .insts
                    .retain(|i| !matches!(i.kind, InstKind::Drop(..) | InstKind::DropField(..)));
                continue;
            };
            let mut out = Vec::new();
            for inst in &block.insts {
                let effects = owned.inst(&inst.kind);
                match &inst.kind {
                    InstKind::Drop(v, None) => emit_drops(
                        &owned,
                        &root(*v),
                        &state,
                        &mut flags,
                        &mut func.vars,
                        inst.span,
                        &mut out,
                    ),
                    // A place behind a reference has no ownership state to
                    // consult (the function does not own it): the drop stays
                    // as written and the backend runs it unconditionally.
                    InstKind::DropField(p, None) if matches!(original[p.var], VarTy::Ref(_)) => {
                        out.push(inst.clone())
                    }
                    InstKind::DropField(p, None) => emit_drops(
                        &owned,
                        p,
                        &state,
                        &mut flags,
                        &mut func.vars,
                        inst.span,
                        &mut out,
                    ),
                    InstKind::Assign(d, rv) if owned.tracked(*d) => {
                        let (before, def) = effects.split_at(effects.len() - 1);
                        // Evaluate new RHS before releasing previous destination.
                        let overwrites = owned
                            .leaves(&root(*d))
                            .iter()
                            .any(|p| state.get(p) != Some(&State::Uninit));
                        let new_value = if overwrites {
                            let tmp = func.vars.len();
                            func.vars.push(original[*d]);
                            out.push(Inst {
                                kind: InstKind::Assign(tmp, rv.clone()),
                                span: inst.span,
                            });
                            Some(Operand::Var(tmp))
                        } else {
                            None
                        };
                        apply(&owned, &mut state, before);
                        emit_drops(
                            &owned,
                            &root(*d),
                            &state,
                            &mut flags,
                            &mut func.vars,
                            inst.span,
                            &mut out,
                        );
                        out.push(Inst {
                            kind: InstKind::Assign(
                                *d,
                                new_value.map(Rvalue::Use).unwrap_or_else(|| rv.clone()),
                            ),
                            span: inst.span,
                        });
                        apply(&owned, &mut state, def);
                        continue;
                    }
                    InstKind::Store(p, o) => {
                        // The operand is already lowered. Snapshot it before dropping
                        // the target, including when it denotes the same subtree.
                        let ty = owned.place_type(p);
                        // An element store replaces the element in place: the
                        // backend drops the old element (the collection stays
                        // whole), so no drop is elaborated here.
                        let element = p.proj.iter().any(|x| matches!(x, Proj::Index(_)));
                        let ref_root =
                            p.proj.is_empty() && matches!(original[p.var], VarTy::Ref(_));
                        if !element && !ref_root && ty.is_some_and(|t| ownership.needs_drop(t)) {
                            let tmp = func.vars.len();
                            func.vars.push(VarTy::Value(ty.unwrap_or(Type::Unit)));
                            out.push(Inst {
                                kind: InstKind::Assign(tmp, Rvalue::Use(o.clone())),
                                span: inst.span,
                            });
                            let (before, def) = effects.split_at(effects.len() - 1);
                            apply(&owned, &mut state, before);
                            if matches!(original[p.var], VarTy::Ref(_)) {
                                out.push(drop_inst(p.clone(), None, inst.span));
                            } else {
                                emit_drops(
                                    &owned,
                                    p,
                                    &state,
                                    &mut flags,
                                    &mut func.vars,
                                    inst.span,
                                    &mut out,
                                );
                            }
                            out.push(Inst {
                                kind: InstKind::Store(p.clone(), Operand::Var(tmp)),
                                span: inst.span,
                            });
                            apply(&owned, &mut state, def);
                            continue;
                        }
                        out.push(inst.clone());
                    }
                    _ => out.push(inst.clone()),
                }
                apply(&owned, &mut state, &effects);
            }
            block.insts = out;
        }
        if flags.is_empty() {
            continue;
        }
        let vars = func.vars.clone();
        let owned = Owned {
            vars: &vars,
            ownership,
        };
        let set = |id, b, span| Inst {
            kind: InstKind::Assign(id, Rvalue::Use(Operand::Const(crate::cfg::Const::Bool(b)))),
            span,
        };
        for block in &mut func.blocks {
            let mut out = Vec::new();
            for inst in block.insts.drain(..) {
                let effects = owned.inst(&inst.kind);
                let span = inst.span;
                out.push(inst);
                for e in effects {
                    let (p, b) = match e {
                        Effect::Def(p) => (p, true),
                        Effect::Move(p) | Effect::Drop(p) => (p, false),
                        Effect::Use(_) => continue,
                    };
                    for leaf in owned.leaves(&p) {
                        if let Some(flag) = flags.get(&leaf) {
                            out.push(set(*flag, b, span));
                        }
                    }
                }
            }
            block.insts = out;
        }
        let params: HashSet<_> = func.params.iter().copied().collect();
        let mut prologue: Vec<_> = flags
            .iter()
            .map(|(p, f)| set(*f, params.contains(&p.var), crate::Span::default()))
            .collect();
        prologue.sort_by_key(|i| match i.kind {
            InstKind::Assign(v, _) => v,
            _ => 0,
        });
        prologue.append(&mut func.blocks[0].insts);
        func.blocks[0].insts = prologue;
    }
}
#[derive(Debug)]
pub struct Violation {
    pub block: usize,
    pub message: String,
}
pub fn verify(func: &Func, ownership: &Ownership) -> Result<(), Violation> {
    let owned = Owned {
        vars: &func.vars,
        ownership,
    };
    let entries = entry_states(func, &owned);
    for (b, block) in func.blocks.iter().enumerate() {
        let Some(mut state) = entries[b].clone() else {
            continue;
        };
        let check = |state: &mut States,
                     effects: &[Effect],
                     conditional: bool|
         -> Result<(), Violation> {
            for e in effects {
                let p = match e {
                    Effect::Use(p) | Effect::Move(p) | Effect::Def(p) | Effect::Drop(p) => p,
                };
                let region_error = match func.vars[p.var].pointee() {
                        Type::RegionList(_, r)
                            if !state.iter().any(|(owner, status)| {
                                *status == State::Init
                                    && func.vars[owner.var].pointee() == Type::Region(r)
                            }) => Some("lista regional sin región viva"),
                        Type::Region(r) if matches!(e, Effect::Drop(_))
                            && state.iter().any(|(list, status)| {
                                *status != State::Uninit
                                    && matches!(func.vars[list.var].pointee(), Type::RegionList(_, id) if id == r)
                            }) => Some("la región todavía contiene listas vivas"),
                        _ => None,
                    };
                if let Some(message) = region_error {
                    return Err(Violation {
                        block: b,
                        message: message.into(),
                    });
                }
                for leaf in owned.leaves(p) {
                    let st = state.get(&leaf).copied().unwrap_or(State::Uninit);
                    let message = match e {
                        Effect::Use(_) | Effect::Move(_) if st != State::Init => {
                            Some("uso tras movimiento o inicialización parcial")
                        }
                        Effect::Drop(_) if !conditional && st != State::Init => {
                            Some("doble liberación")
                        }
                        Effect::Def(_) if st != State::Uninit => Some("fuga por sobrescritura"),
                        _ => None,
                    };
                    if let Some(message) = message {
                        return Err(Violation {
                            block: b,
                            message: format!("{leaf:?}: {message}"),
                        });
                    }
                }
                apply(&owned, state, std::slice::from_ref(e));
            }
            Ok(())
        };
        for inst in &block.insts {
            let conditional = matches!(
                inst.kind,
                InstKind::Drop(_, Some(_)) | InstKind::DropField(_, Some(_))
            );
            if let InstKind::Drop(v, _) = inst.kind
                && !owned.tracked(v)
            {
                return Err(Violation {
                    block: b,
                    message: format!("drop de v{v}, que no es un valor propio"),
                });
            }
            check(&mut state, &owned.inst(&inst.kind), conditional)?;
        }
        if let Some(t) = &block.term {
            check(&mut state, &owned.terminator(t), false)?;
            if matches!(
                t,
                Terminator::Return(_) | Terminator::ReturnRef(..) | Terminator::Suspend(_)
            ) && let Some((p, _)) = state.iter().find(|(_, s)| **s != State::Uninit)
            {
                return Err(Violation {
                    block: b,
                    message: format!("{p:?} sigue poseyendo un valor al retornar: fuga"),
                });
            }
        }
    }
    Ok(())
}

/// Abstract value of a drop flag on the paths reaching a point.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FlagValue {
    Off,
    On,
    Unknown,
}
fn join_flag(a: FlagValue, b: FlagValue) -> FlagValue {
    if a == b { a } else { FlagValue::Unknown }
}
/// The places each drop flag guards (from every flagged `Drop`/`DropField`).
fn flag_places(func: &Func) -> HashMap<VarId, Vec<Place>> {
    let mut out: HashMap<VarId, Vec<Place>> = HashMap::new();
    for block in &func.blocks {
        for inst in &block.insts {
            let (place, flag) = match &inst.kind {
                InstKind::Drop(v, Some(f)) => (root(*v), *f),
                InstKind::DropField(p, Some(f)) => (p.clone(), *f),
                _ => continue,
            };
            let places = out.entry(flag).or_default();
            if !places.contains(&place) {
                places.push(place);
            }
        }
    }
    out
}
fn flag_transfer(flags: &mut HashMap<VarId, FlagValue>, kind: &InstKind) {
    if let InstKind::Assign(d, rv) = kind
        && let Some(value) = flags.get_mut(d)
    {
        *value = match rv {
            Rvalue::Use(Operand::Const(Const::Bool(true))) => FlagValue::On,
            Rvalue::Use(Operand::Const(Const::Bool(false))) => FlagValue::Off,
            _ => FlagValue::Unknown,
        };
    }
}
/// Whether flag value `f` agrees with the ownership state of every leaf the
/// flag guards: `On` exactly when each leaf owns a value, `Off` exactly when
/// none does, `Unknown` only where the leaves are `Maybe` (a join of agreeing
/// paths).
fn flag_agrees(owned: &Owned, state: &States, places: &[Place], f: FlagValue) -> bool {
    places.iter().all(|p| {
        owned.leaves(p).iter().all(|leaf| {
            let st = state.get(leaf).copied().unwrap_or(State::Uninit);
            matches!(
                (st, f),
                (State::Init, FlagValue::On)
                    | (State::Uninit, FlagValue::Off)
                    | (State::Maybe, FlagValue::Unknown)
            )
        })
    })
}
/// Drop-flag values (#F1). `verify` treats a flagged drop as possibly not
/// executing, so a forged flag value could double free (flag set while the
/// value was moved or dropped) or leak (flag clear while it owns a value).
/// This pass tracks every flag as an abstract constant per path (CFG
/// dataflow over `Off`/`On`/`Unknown`) next to the ownership states, and
/// requires the Stage 0 invariant "flag == value currently owned": at each
/// flagged drop and at the end of every block that continues to another
/// block. Joins of agreeing paths stay agreeing (`Maybe`/`Unknown`); any
/// other combination is rejected, never assumed.
pub fn verify_flags(func: &Func, ownership: &Ownership) -> Result<(), Violation> {
    let guarded = flag_places(func);
    if guarded.is_empty() {
        return Ok(());
    }
    let owned = Owned {
        vars: &func.vars,
        ownership,
    };
    for flag in guarded.keys() {
        if func.vars.get(*flag) != Some(&VarTy::Value(Type::Bool)) {
            return Err(Violation {
                block: 0,
                message: format!("v{flag} no es un flag Bool"),
            });
        }
    }
    let places = entry_states(func, &owned);
    let start: HashMap<VarId, FlagValue> = guarded.keys().map(|f| (*f, FlagValue::Off)).collect();
    let mut flags: Vec<Option<HashMap<VarId, FlagValue>>> = vec![None; func.blocks.len()];
    if flags.is_empty() {
        return Ok(());
    }
    flags[0] = Some(start);
    let mut work = vec![0];
    while let Some(b) = work.pop() {
        let Some(mut values) = flags[b].clone() else {
            continue;
        };
        for inst in &func.blocks[b].insts {
            flag_transfer(&mut values, &inst.kind);
        }
        let Some(t) = &func.blocks[b].term else {
            continue;
        };
        for next in successors(t) {
            if next >= flags.len() {
                continue;
            }
            let merged = match &flags[next] {
                None => values.clone(),
                Some(old) => old
                    .iter()
                    .map(|(f, v)| (*f, join_flag(*v, values[f])))
                    .collect(),
            };
            if flags[next].as_ref() != Some(&merged) {
                flags[next] = Some(merged);
                work.push(next);
            }
        }
    }
    for (b, block) in func.blocks.iter().enumerate() {
        let (Some(mut state), Some(mut values)) = (places[b].clone(), flags[b].clone()) else {
            continue;
        };
        for inst in &block.insts {
            if let InstKind::Drop(_, Some(f)) | InstKind::DropField(_, Some(f)) = &inst.kind {
                let here = [match &inst.kind {
                    InstKind::Drop(v, _) => root(*v),
                    InstKind::DropField(p, _) => p.clone(),
                    _ => unreachable!(),
                }];
                if !flag_agrees(&owned, &state, &here, values[f]) {
                    return Err(Violation {
                        block: b,
                        message: format!(
                            "flag v{f} = {:?} no coincide con la propiedad de {:?}: doble liberación o fuga",
                            values[f], here[0]
                        ),
                    });
                }
            }
            apply(&owned, &mut state, &owned.inst(&inst.kind));
            flag_transfer(&mut values, &inst.kind);
        }
        let Some(t) = &block.term else {
            continue;
        };
        apply(&owned, &mut state, &owned.terminator(t));
        if successors(t).is_empty() {
            continue;
        }
        for (f, guarded_places) in &guarded {
            if !flag_agrees(&owned, &state, guarded_places, values[f]) {
                return Err(Violation {
                    block: b,
                    message: format!(
                        "flag v{f} = {:?} no refleja la propiedad de {:?} al salir del bloque",
                        values[f], guarded_places
                    ),
                });
            }
        }
    }
    Ok(())
}
