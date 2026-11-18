//! Initialization of tagged owner slots along logical poll/resume edges.
use std::collections::{HashMap, HashSet, VecDeque};

use crate::{
    cfg::{
        self, ASYNC_BODY_ENTRY, BinOp, Const, Func, InstKind, Module, Operand, Place, Proj,
        RESUME_FIELD, Rvalue, Terminator, VarId, VerifyError,
    },
    drops::{Effect, Owned, Ownership},
    lir::Type,
};

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Empty,
    Full,
    Maybe,
}

#[derive(Clone)]
struct Flow {
    slots: Vec<State>,
    variants: HashMap<Place, usize>,
}

impl Flow {
    fn new(slots: Vec<State>) -> Self {
        Self {
            slots,
            variants: HashMap::new(),
        }
    }

    fn join(&mut self, incoming: &Self) -> bool {
        let mut changed = false;
        for (old, new) in self.slots.iter_mut().zip(&incoming.slots) {
            if *old != *new && *old != State::Maybe {
                *old = State::Maybe;
                changed = true;
            }
        }
        let known = self.variants.len();
        self.variants
            .retain(|place, tag| incoming.variants.get(place) == Some(tag));
        changed || self.variants.len() != known
    }
}

struct Slot {
    offset: usize,
    leaves: Vec<Vec<Proj>>,
}

impl Slot {
    fn covered<'a>(&'a self, prefix: &'a [Proj]) -> impl Iterator<Item = usize> + 'a {
        // User enums and collections are atomic ownership leaves. Payload
        // and element projections still require the enclosing leaf to be live.
        let prefix = prefix
            .split(|p| !matches!(p, Proj::Field(_)))
            .next()
            .unwrap_or_default();
        self.leaves
            .iter()
            .enumerate()
            .filter(move |(_, leaf)| leaf.starts_with(prefix) || prefix.starts_with(leaf))
            .map(|(i, _)| self.offset + i + 1)
    }
}

struct Poll<'a> {
    func: &'a Func,
    state: VarId,
    fields: &'a HashMap<usize, Slot>,
    full_values: HashSet<VarId>,
}

impl Poll<'_> {
    fn slot<'a>(&self, place: &'a Place) -> Option<(&Slot, &'a [Proj])> {
        let (Proj::Field(field), rest) = place.proj.split_first()? else {
            return None;
        };
        if place.var != self.state {
            return None;
        }
        Some((self.fields.get(field)?, rest))
    }

    fn update(&self, inst: &InstKind, state: &mut Flow) {
        // A write through an alias may change a discriminant. Index variables
        // also form part of the identity of an indexed enum place.
        match inst {
            InstKind::Store(..)
            | InstKind::Clear(_)
            | InstKind::Drop(..)
            | InstKind::DropField(..)
            | InstKind::ListPush(..)
            | InstKind::ListReserve(..)
            | InstKind::BytesSet(..)
            | InstKind::Assign(
                _,
                Rvalue::Call(..) | Rvalue::ListTakeLast(_) | Rvalue::ListPop(..),
            ) => state.variants.clear(),
            InstKind::Assign(var, _) => state
                .variants
                .retain(|p, _| !p.proj.contains(&Proj::Index(*var))),
            _ => {}
        }
        let (place, next) = match inst {
            InstKind::Store(p, _) => (p, State::Full),
            InstKind::Clear(p) | InstKind::DropField(p, _) => (p, State::Empty),
            _ => return,
        };
        match self.slot(place) {
            Some((slot, [])) => {
                state.slots[slot.offset..slot.offset + slot.leaves.len() + 1].fill(next);
            }
            Some((slot, [Proj::Payload(1, 0), rest @ ..]))
                if rest.iter().all(|p| matches!(p, Proj::Field(_))) =>
            {
                for leaf in slot.covered(rest) {
                    state.slots[leaf] = next;
                }
            }
            _ => {}
        }
    }

    fn fail(&self, block: usize, message: &str) -> VerifyError {
        VerifyError {
            func: self.func.name.clone(),
            block,
            message: message.into(),
        }
    }

    fn move_target(&self, place: &Place, owned: &Owned) -> Option<Place> {
        if !owned.place_type(place)?.is_move() {
            return None;
        }
        match self.slot(place)? {
            (_, [Proj::Payload(1, 0)]) => Some(Place {
                var: place.var,
                proj: place.proj[..1].to_vec(),
            }),
            (_, [Proj::Payload(1, 0), ..]) => Some(place.clone()),
            _ => None,
        }
    }

    fn validate(
        &self,
        block: usize,
        index: usize,
        owned: &Owned,
        state: &Flow,
    ) -> Result<(), VerifyError> {
        let insts = &self.func.blocks[block].insts;
        let inst = &insts[index].kind;
        let previous = index.checked_sub(1).map(|i| &insts[i].kind);
        let following = insts.get(index + 1).map(|i| &i.kind);
        for effect in owned.inst(inst) {
            let place = match &effect {
                Effect::Use(p) | Effect::Move(p) | Effect::Def(p) | Effect::Drop(p) => p,
            };
            let Some((slot, projection)) = self.slot(place) else {
                continue;
            };
            let invalid = || self.fail(block, "transición inválida de ranura propietaria async");
            let has_drop = owned
                .place_type(place)
                .is_some_and(|t| owned.ownership.needs_drop(t));
            let dropped_before =
                matches!(previous, Some(InstKind::DropField(p, None)) if p == place);
            let in_payload = matches!(projection, [Proj::Payload(1, 0), ..]);
            if in_payload && state.slots[slot.offset] != State::Full {
                return Err(self.fail(block, "acceso a una ranura propietaria no inicializada"));
            }
            if in_payload {
                for (i, projection) in place.proj.iter().enumerate().skip(2) {
                    if let Proj::Payload(tag, _) = projection {
                        let owner = Place {
                            var: place.var,
                            proj: place.proj[..i].to_vec(),
                        };
                        if state.variants.get(&owner) != Some(tag) {
                            return Err(
                                self.fail(block, "payload async sin prueba de variante activa")
                            );
                        }
                    }
                }
            }
            let interior = projection
                .iter()
                .skip(1)
                .find(|p| !matches!(p, Proj::Field(_)));
            // Store into an element preserves the collection's ownership.
            let element = matches!(interior, Some(Proj::Index(_)));
            match inst {
                InstKind::Store(p, op) if p == place && !element => {
                    if interior.is_some() || (has_drop && !dropped_before) {
                        return Err(invalid());
                    }
                    if !in_payload
                        && (!projection.is_empty()
                            || !matches!(op, Operand::Var(v) if self.full_values.contains(v)))
                    {
                        return Err(invalid());
                    }
                }
                InstKind::DropField(p, None) if p == place => {
                    if interior.is_some()
                        || (!matches!(following, Some(InstKind::Store(next, _)) if next == p)
                            && !(projection.is_empty()
                                && matches!(following, Some(InstKind::Clear(next)) if next == p)))
                    {
                        return Err(invalid());
                    }
                }
                InstKind::Clear(p) if p == place => {
                    if interior.is_some()
                        || (!(projection.is_empty() && dropped_before)
                            && !matches!(previous, Some(InstKind::Assign(_, Rvalue::Read(read)))
                            if self.move_target(read, owned).as_ref() == Some(p)))
                    {
                        return Err(invalid());
                    }
                }
                _ => {
                    let [Proj::Payload(1, 0), rest @ ..] = projection else {
                        return Err(invalid());
                    };
                    if !matches!(effect, Effect::Use(_) | Effect::Move(_))
                        || slot.covered(rest).any(|i| state.slots[i] != State::Full)
                    {
                        return Err(self.fail(
                            block,
                            "lectura de campo propietario no inicializado en alguna reanudación",
                        ));
                    }
                    if let InstKind::Assign(_, Rvalue::Read(p)) = inst
                        && p == place
                        && let Some(target) = self.move_target(p, owned)
                        && (interior.is_some()
                            || !matches!(following, Some(InstKind::Clear(clear)) if *clear == target))
                    {
                        return Err(self.fail(
                            block,
                            "mover un valor del estado async exige vaciar su origen",
                        ));
                    }
                }
            }
        }
        Ok(())
    }

    /// Tie each logical edge to the actual dispatch performed on the next poll.
    fn verify_dispatch(&self) -> Result<(), VerifyError> {
        let resume = Place {
            var: self.state,
            proj: vec![Proj::Field(RESUME_FIELD)],
        };
        let entry = &self.func.blocks[0];
        let point = entry.insts.iter().find_map(|inst| match &inst.kind {
            InstKind::Assign(id, Rvalue::Read(p)) if *p == resume => Some(*id),
            _ => None,
        });
        let mut dispatch = HashMap::new();
        let mut block = 0;
        loop {
            let body = &self.func.blocks[block];
            let Some(Terminator::Branch(Operand::Var(hit), target, next)) = body.term else {
                return Err(self.fail(block, "despacho async inválido"));
            };
            let key = body.insts.last().and_then(|inst| match inst.kind {
                InstKind::Assign(
                    id,
                    Rvalue::Binary(BinOp::Eq, Operand::Var(v), Operand::Const(Const::Int(key))),
                ) if id == hit && Some(v) == point => Some(key),
                _ => None,
            });
            let Some(key) = key else {
                return Err(self.fail(block, "falta la condición de reanudación"));
            };
            if dispatch.insert(key, target).is_some() {
                return Err(self.fail(block, "índice de reanudación duplicado"));
            }
            if key == 0 {
                if target != ASYNC_BODY_ENTRY {
                    return Err(self.fail(block, "entrada inicial de poll inválida"));
                }
                break;
            }
            block = next;
        }
        for (block, body) in self.func.blocks.iter().enumerate() {
            if let Some(Terminator::Suspend(target)) = body.term {
                let saved = body.insts.iter().rev().find_map(|inst| match &inst.kind {
                    InstKind::Store(p, value) if *p == resume => Some(value),
                    _ => None,
                });
                if !matches!(saved, Some(Operand::Const(Const::Int(key)))
                    if *key > 0 && dispatch.get(key) == Some(&target))
                {
                    return Err(self.fail(block, "reanudación distinta del índice guardado"));
                }
            }
        }
        Ok(())
    }

    /// A matched branch proves the active variant for the exact place that
    /// was tested. Other branches and joins inherit only proven facts.
    fn variant_guard(&self, block: &cfg::Block) -> Option<(usize, Place, usize)> {
        let Terminator::Branch(Operand::Var(hit), yes, no) = block.term.as_ref()? else {
            return None;
        };
        if yes == no {
            return None;
        }
        let [.., discr, compare] = &block.insts[..] else {
            return None;
        };
        let InstKind::Assign(input, Rvalue::Discriminant(place)) = &discr.kind else {
            return None;
        };
        let InstKind::Assign(
            result,
            Rvalue::Binary(BinOp::Eq, Operand::Var(v), Operand::Const(Const::Int(tag))),
        ) = compare.kind
        else {
            return None;
        };
        if result != *hit || v != *input || self.slot(place).is_none() {
            return None;
        }
        Some((*yes, place.clone(), usize::try_from(tag).ok()?))
    }

    fn verify(&self, ownership: &Ownership, initial: Vec<State>) -> Result<(), VerifyError> {
        if self.func.blocks.len() <= ASYNC_BODY_ENTRY {
            return Err(self.fail(0, "falta la entrada inicial del poll"));
        }
        self.verify_dispatch()?;
        // The constructor proves the initial state. The dispatcher is not an additional predecessor of each resume:
        // the predecessor is the poll that stored that resume index.
        let mut entries = vec![None::<Flow>; self.func.blocks.len()];
        entries[ASYNC_BODY_ENTRY] = Some(Flow::new(initial));
        let mut work = VecDeque::from([ASYNC_BODY_ENTRY]);
        while let Some(block) = work.pop_front() {
            let mut out = entries[block].as_ref().unwrap().clone();
            let body = &self.func.blocks[block];
            for inst in &body.insts {
                self.update(&inst.kind, &mut out);
            }
            let term = body.term.as_ref().unwrap();
            let next = match term {
                Terminator::Suspend(resume) => vec![*resume],
                _ => cfg::successors(term),
            };
            let guard = self.variant_guard(body);
            for target in next {
                let mut matched;
                let incoming = if let Some((yes, place, tag)) = &guard
                    && target == *yes
                {
                    matched = out.clone();
                    matched.variants.insert(place.clone(), *tag);
                    &matched
                } else {
                    &out
                };
                let changed = if let Some(entry) = &mut entries[target] {
                    entry.join(incoming)
                } else {
                    entries[target] = Some(incoming.clone());
                    true
                };
                if changed {
                    work.push_back(target);
                }
            }
        }
        let owned = Owned {
            vars: &self.func.vars,
            ownership,
        };
        for (block, entry) in entries.into_iter().enumerate() {
            let Some(mut state) = entry else { continue };
            let body = &self.func.blocks[block];
            for (index, inst) in body.insts.iter().enumerate() {
                self.validate(block, index, &owned, &state)?;
                self.update(&inst.kind, &mut state);
            }
            if matches!(
                body.term,
                Some(Terminator::Return(Operand::Const(Const::Int(
                    cfg::POLL_READY
                ))))
            ) && state.slots.iter().any(|s| *s != State::Empty)
            {
                return Err(self.fail(
                    block,
                    "el poll termina con una ranura propietaria todavía ocupada",
                ));
            }
        }
        Ok(())
    }
}

/// Split only the subtrees affected by projected writes or moves. Each
/// untouched subtree uses one abstract state, regardless of its layout size.
fn split_paths(func: &Func) -> HashMap<usize, HashSet<Vec<Proj>>> {
    let mut split = HashMap::<usize, HashSet<Vec<Proj>>>::new();
    for inst in func.blocks.iter().flat_map(|block| &block.insts) {
        let place = match &inst.kind {
            InstKind::Store(p, _) | InstKind::Clear(p) if p.var == func.params[0] => p,
            _ => continue,
        };
        if let [Proj::Field(slot), Proj::Payload(1, 0), rest @ ..] = &place.proj[..]
            && rest.iter().all(|p| matches!(p, Proj::Field(_)))
        {
            for end in 0..rest.len() {
                split.entry(*slot).or_default().insert(rest[..end].to_vec());
            }
        }
    }
    split
}

fn leaves(
    module: &Module,
    ty: Type,
    split: Option<&HashSet<Vec<Proj>>>,
    path: &mut Vec<Proj>,
    out: &mut Vec<Vec<Proj>>,
) {
    if let Type::Struct(id) = ty
        && split.is_some_and(|prefixes| prefixes.contains(path))
    {
        for (i, (_, ty)) in module.structs[id].fields.iter().enumerate() {
            path.push(Proj::Field(i));
            leaves(module, *ty, split, path, out);
            path.pop();
        }
    } else {
        out.push(path.clone());
    }
}

fn full_values(func: &Func, tags: &HashSet<usize>) -> HashSet<VarId> {
    let mut definitions = func
        .blocks
        .iter()
        .flat_map(|block| &block.insts)
        .filter_map(|inst| match &inst.kind {
            InstKind::Assign(dest, rv)
                if matches!(func.vars[*dest], cfg::VarTy::Value(Type::Enum(tag)) if tags.contains(&tag)) =>
            {
                Some((*dest, rv))
            }
            _ => None,
        })
        .collect::<Vec<_>>();
    definitions.sort_by_key(|(id, _)| *id);
    let mut full = HashSet::new();
    for (dest, rv) in definitions {
        if matches!(rv, Rvalue::Variant(tag, 1, _) if tags.contains(tag))
            || matches!(rv, Rvalue::Use(Operand::Var(source)) if full.contains(source))
        {
            full.insert(dest);
        }
    }
    full
}

pub(crate) fn verify(module: &Module, ownership: &Ownership) -> Result<(), VerifyError> {
    for (future, info) in module.futures.iter().enumerate() {
        if info.owned_slots.is_empty() {
            continue;
        }
        let func = &module.funcs[info.poll];
        let invalid = |message: &str| VerifyError {
            func: func.name.clone(),
            block: 0,
            message: message.into(),
        };
        let split = split_paths(func);
        let mut fields = HashMap::new();
        let mut tags = HashSet::new();
        let mut initial = Vec::new();
        for slot in &info.owned_slots {
            let Some((_, Type::Enum(tag))) = module.structs[info.state].fields.get(slot.field)
            else {
                return Err(invalid("campo inválido para ranura propietaria async"));
            };
            let [(_, empty), (_, full)] = &module.enums[*tag].variants[..] else {
                return Err(invalid("etiqueta inválida para ranura propietaria async"));
            };
            let [ty] = &full[..] else {
                return Err(invalid("payload inválido para ranura propietaria async"));
            };
            if *tag != slot.tag || !empty.is_empty() {
                return Err(invalid("layout inválido para ranura propietaria async"));
            }
            let mut paths = Vec::new();
            leaves(
                module,
                *ty,
                split.get(&slot.field),
                &mut Vec::new(),
                &mut paths,
            );
            let offset = initial.len();
            let entry = if slot.parameter {
                State::Full
            } else {
                State::Empty
            };
            initial.resize(offset + paths.len() + 1, entry);
            if fields
                .insert(
                    slot.field,
                    Slot {
                        offset,
                        leaves: paths,
                    },
                )
                .is_some()
            {
                return Err(invalid("ranura propietaria async duplicada"));
            }
            tags.insert(*tag);
        }

        // The constructor has a straight-line entry and starts from the zeroed
        // state allocated by FutureNew. Check its transfers before trusting the
        // initialized parameter slots at the initial poll.
        let factory = module
            .funcs
            .get(info.factory)
            .ok_or_else(|| invalid("constructor async inexistente"))?;
        let [body] = &factory.blocks[..] else {
            return Err(invalid("constructor async con flujo inesperado"));
        };
        let handle = body
            .insts
            .iter()
            .find_map(|i| match i.kind {
                InstKind::Assign(var, Rvalue::FutureNew(id)) if id == future => Some(var),
                _ => None,
            })
            .ok_or_else(|| invalid("el constructor no reserva el estado async"))?;
        let state = body
            .insts
            .iter()
            .find_map(|i| match &i.kind {
                InstKind::Assign(var, Rvalue::FutureState(p))
                    if p.var == handle && p.proj.is_empty() =>
                {
                    Some(*var)
                }
                _ => None,
            })
            .ok_or_else(|| invalid("el constructor no obtiene su estado async"))?;
        let constructor = Poll {
            func: factory,
            state,
            fields: &fields,
            full_values: full_values(factory, &tags),
        };
        let owned = Owned {
            vars: &factory.vars,
            ownership,
        };
        let mut constructed = Flow::new(vec![State::Empty; initial.len()]);
        for (i, inst) in body.insts.iter().enumerate() {
            constructor.validate(0, i, &owned, &constructed)?;
            constructor.update(&inst.kind, &mut constructed);
        }
        if constructed.slots != initial
            || !matches!(body.term, Some(Terminator::Return(Operand::Var(v))) if v == handle)
        {
            return Err(invalid(
                "el constructor no inicializa correctamente las ranuras de parámetros",
            ));
        }

        Poll {
            func,
            state: func.params[0],
            fields: &fields,
            full_values: full_values(func, &tags),
        }
        .verify(ownership, initial)?;
    }
    Ok(())
}
