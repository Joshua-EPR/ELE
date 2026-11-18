//! Local reference origins and liveness on the verified CFG.
use crate::{
    Diagnostic, Span,
    cfg::{self, Arg, Func, InstKind, Module, Place, Proj, Rvalue, VarId, VarTy},
    drops::{Effect, Owned, Ownership},
    lir::{Receiver, Type},
};
use std::{
    borrow::Cow,
    collections::{BTreeMap, BTreeSet, HashMap, HashSet},
};

#[derive(Clone)]
struct Origin {
    place: Place,
    // A loan can authorize an access only along every path to this place.
    through: Vec<VarId>,
    exclusive: bool,
}

struct Alias {
    origins: Vec<Origin>,
    // Every possible ancestor stays live when the derived pointer stays live.
    ancestors: BTreeSet<VarId>,
    // None is an internal projection, e.g. an element used by for-each.
    writable: Option<bool>,
    span: Span,
}

fn root(var: VarId) -> Place {
    Place {
        var,
        proj: Vec::new(),
    }
}

fn origins<'a>(
    place: &Place,
    aliases: &'a HashMap<VarId, Alias>,
    views: &ViewFields,
) -> Cow<'a, [Origin]> {
    let (key, rest) = match place.proj.as_slice() {
        [Proj::Field(i), rest @ ..] => (Some(ViewKey::Field(*i)), rest),
        [Proj::Payload(v, f), rest @ ..] => (Some(ViewKey::Payload(*v, *f)), rest),
        [Proj::Index(_), rest @ ..] => (Some(ViewKey::Index), rest),
        _ => (None, &[][..]),
    };
    if let Some(key) = key
        && let Some(fields) = views.get(&place.var)
        && let Some(&loan_id) = fields.get(&key)
        && let Some(alias) = aliases.get(&loan_id)
    {
        return Cow::Owned(
            alias
                .origins
                .iter()
                .cloned()
                .map(|mut origin| {
                    origin.place.proj.extend_from_slice(rest);
                    if !origin.through.contains(&loan_id) {
                        origin.through.push(loan_id);
                    }
                    origin
                })
                .collect(),
        );
    }
    match aliases.get(&place.var) {
        Some(alias) if place.proj.is_empty() => Cow::Borrowed(&alias.origins),
        Some(alias) => Cow::Owned(
            alias
                .origins
                .iter()
                .cloned()
                .map(|mut origin| {
                    origin.place.proj.extend_from_slice(&place.proj);
                    origin
                })
                .collect(),
        ),
        None => Cow::Owned(vec![Origin {
            place: place.clone(),
            through: Vec::new(),
            exclusive: false,
        }]),
    }
}
fn overlaps(a: &Place, b: &Place) -> bool {
    a.var == b.var
        && a.proj
            .iter()
            .zip(&b.proj)
            .find_map(|(x, y)| match (x, y) {
                (Proj::Field(f), Proj::Field(g)) if f != g => Some(false),
                (Proj::Payload(v, f), Proj::Payload(w, g)) if v == w && f != g => Some(false),
                // A dynamic index can denote any element. Keep the entire indexed
                // projection conservative, even for different subsequent fields.
                (Proj::Index(_), _) | (_, Proj::Index(_)) => Some(true),
                _ if x != y => Some(true),
                _ => None,
            })
            .unwrap_or(true)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ViewKey {
    Field(usize),
    Payload(usize, usize),
    Index,
}

impl ViewKey {
    pub const fn to_raw(self) -> usize {
        match self {
            Self::Field(i) => i * 4,
            Self::Payload(v, f) => ((v * 1024 + f) * 4) + 1,
            Self::Index => 2,
        }
    }
    pub const fn from_raw(raw: usize) -> Self {
        match raw % 4 {
            0 => Self::Field(raw / 4),
            1 => {
                let inner = raw / 4;
                Self::Payload(inner / 1024, inner % 1024)
            }
            _ => Self::Index,
        }
    }
}

type ViewFields = HashMap<VarId, BTreeMap<ViewKey, VarId>>;

fn invalid_view_origin(span: Span) -> Diagnostic {
    Diagnostic::new(
        span,
        "el campo de una vista debe provenir de un préstamo compartido explícito",
    )
    .classify("L0014", "préstamos")
}

fn view_keys_for_type(
    ty: Type,
    module: &Module,
    next_loan_id: &mut usize,
) -> BTreeMap<ViewKey, VarId> {
    let mut sources = BTreeMap::new();
    match ty {
        Type::Struct(id) => {
            let fields = &module.structs[id].fields;
            for (i, (_, fty)) in fields.iter().enumerate() {
                if matches!(fty, Type::SharedField(_) | Type::MutField(_)) {
                    sources.insert(ViewKey::Field(i), *next_loan_id);
                    *next_loan_id += 1;
                }
            }
        }
        Type::Enum(id) => {
            let enum_def = &module.enums[id];
            for (v, (_, payload)) in enum_def.variants.iter().enumerate() {
                for (f, fty) in payload.iter().enumerate() {
                    if matches!(fty, Type::SharedField(_) | Type::MutField(_)) {
                        sources.insert(ViewKey::Payload(v, f), *next_loan_id);
                        *next_loan_id += 1;
                    }
                }
            }
        }
        Type::Array(id) => {
            let elem = module.arrays[id].elem;
            if matches!(elem, Type::SharedField(_) | Type::MutField(_)) {
                sources.insert(ViewKey::Index, *next_loan_id);
                *next_loan_id += 1;
            }
        }
        Type::List(elem) | Type::RegionList(elem, _) => {
            let elem_ty = module.lists[elem];
            if matches!(elem_ty, Type::SharedField(_) | Type::MutField(_)) {
                sources.insert(ViewKey::Index, *next_loan_id);
                *next_loan_id += 1;
            }
        }
        _ => {}
    }
    sources
}

/// Recover which loan initialized each stored pointer. Local views only have
/// constructor and move definitions, both of which are fixed for a CFG id.
fn view_fields(f: &Func, module: &Module) -> Result<ViewFields, Diagnostic> {
    let mut views = ViewFields::new();
    let mut next_loan_id = f.vars.len();
    for &param_var in &f.params {
        let pointee = f.vars[param_var].pointee();
        let sources = view_keys_for_type(pointee, module, &mut next_loan_id);
        if !sources.is_empty() {
            views.insert(param_var, sources);
        }
    }
    for inst in f.blocks.iter().flat_map(|block| &block.insts) {
        let InstKind::Assign(dest, rval) = &inst.kind else {
            continue;
        };
        let pointee = f.vars[*dest].pointee();
        let sources = match rval {
            Rvalue::Variant(eid, variant, _) => {
                let mut s = BTreeMap::new();
                for (f, fty) in module.enums[*eid].variants[*variant].1.iter().enumerate() {
                    if matches!(fty, Type::SharedField(_) | Type::MutField(_)) {
                        s.insert(ViewKey::Payload(*variant, f), next_loan_id);
                        next_loan_id += 1;
                    }
                }
                s
            }
            Rvalue::Use(cfg::Operand::Var(src)) => {
                if let Some(src_fields) = views.get(src) {
                    let mut s = BTreeMap::new();
                    for &k in src_fields.keys() {
                        s.insert(k, next_loan_id);
                        next_loan_id += 1;
                    }
                    s
                } else {
                    BTreeMap::new()
                }
            }
            _ => view_keys_for_type(pointee, module, &mut next_loan_id),
        };
        if !sources.is_empty() && !views.contains_key(dest) {
            views.insert(*dest, sources);
        }
    }
    Ok(views)
}

type Live = HashMap<VarId, Span>;

fn step(live: &mut Live, inst: &cfg::Inst, aliases: &HashMap<VarId, Alias>, views: &ViewFields) {
    let (uses, def) = cfg::uses_defs(&inst.kind);
    if let Some(def) = def {
        live.remove(&def);
        if let Some(fields) = views.get(&def) {
            for &loan in fields.values() {
                live.remove(&loan);
            }
        }
    }
    for id in uses {
        if aliases.contains_key(&id) {
            live.insert(id, inst.span);
        }
        if let Some(fields) = views.get(&id) {
            for &loan in fields.values() {
                live.insert(loan, inst.span);
            }
        }
    }
}

fn live_out(f: &Func, aliases: &HashMap<VarId, Alias>, views: &ViewFields) -> Vec<Live> {
    let mut inputs = vec![Live::new(); f.blocks.len()];
    let mut outputs = inputs.clone();
    loop {
        let mut changed = false;
        for (b, block) in f.blocks.iter().enumerate().rev() {
            let mut out = Live::new();
            for successor in cfg::successors(block.term.as_ref().expect("verified terminator")) {
                for (&id, &span) in &inputs[successor] {
                    // Fixed order for diagnostic witnesses across merges.
                    let old = out.entry(id).or_insert(span);
                    if (span.line, span.column) < (old.line, old.column) {
                        *old = span;
                    }
                }
            }
            if let Some(cfg::Terminator::ReturnRef(var, span)) = block.term {
                out.insert(var, span);
            }
            let mut input = out.clone();
            for inst in block.insts.iter().rev() {
                step(&mut input, inst, aliases, views);
            }
            if input != inputs[b] {
                inputs[b] = input;
                changed = true;
            }
            outputs[b] = out;
        }
        if !changed {
            return outputs;
        }
    }
}

fn conflict(span: Span, loan: Span, later: Span) -> Diagnostic {
    Diagnostic::new(span, format!(
        "préstamo incompatible con este acceso. Préstamo iniciado en {}:{}, uso vivo en {}:{}. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.",
        loan.line, loan.column, later.line, later.column
    )).classify("L0012", "préstamos")
}

/// Accesses to data, excluding the assignment of the reference pointer itself.
fn accesses(inst: &InstKind, owned: &Owned) -> Vec<(Place, bool)> {
    let mut accesses = Vec::new();
    for effect in owned.inst(inst) {
        let access = match effect {
            Effect::Use(p) => (p, false),
            Effect::Move(p) => {
                let moving = owned.place_type(&p).is_some_and(Type::is_move)
                    && matches!(owned.vars[p.var], VarTy::Value(_));
                (p, moving)
            }
            Effect::Def(p)
                if matches!(inst, InstKind::Assign(_, _))
                    && matches!(owned.vars[p.var], VarTy::Ref(_)) =>
            {
                continue;
            }
            Effect::Def(p) | Effect::Drop(p) => (p, true),
        };
        accesses.push(access);
    }
    match inst {
        InstKind::Assign(
            _,
            Rvalue::Loan(p, true, _) | Rvalue::ListTakeLast(p) | Rvalue::ListPop(p, _),
        )
        | InstKind::Store(p, _)
        | InstKind::Clear(p)
        | InstKind::ListPush(p, _)
        | InstKind::ListReserve(p, _)
        | InstKind::BytesSet(p, ..) => accesses.push((p.clone(), true)),
        InstKind::Assign(_, Rvalue::Read(p))
            if matches!(owned.vars[p.var], VarTy::Value(_))
                && p.proj.iter().all(|x| matches!(x, Proj::Field(_)))
                && owned.place_type(p).is_some_and(Type::is_move) =>
        {
            accesses.push((p.clone(), true));
        }
        InstKind::Assign(_, Rvalue::Call(_, args)) => {
            accesses.extend(args.iter().filter_map(|arg| match arg {
                Arg::Ref(p, true) => Some((p.clone(), true)),
                _ => None,
            }));
        }
        _ => {}
    }
    accesses
}

/// Resolve each alias once in variable order. CFG lowering allocates reference
/// ids after their inputs. Deduplication plus a per-alias bound prevents
/// exponential expansion through chains of joins.
fn collect_aliases(
    f: &Func,
    funcs: &[Func],
    views: &ViewFields,
    module: &Module,
) -> Result<HashMap<VarId, Alias>, Diagnostic> {
    const MAX_ORIGINS: usize = 256;
    let mut definitions = BTreeMap::new();
    let entry_span = f
        .blocks
        .first()
        .and_then(|b| b.insts.first())
        .map_or(Span::at(1, 1), |i| i.span);
    for &param_var in &f.params {
        let pointee = f.vars[param_var].pointee();
        if let Some(view_fields) = views.get(&param_var) {
            for (&key, &loan_id) in view_fields {
                let (proj, is_mut) = match key {
                    ViewKey::Field(i) => {
                        let Type::Struct(id) = pointee else {
                            unreachable!()
                        };
                        (
                            vec![Proj::Field(i)],
                            matches!(module.structs[id].fields[i].1, Type::MutField(_)),
                        )
                    }
                    ViewKey::Payload(v, f) => {
                        let Type::Enum(id) = pointee else {
                            unreachable!()
                        };
                        (
                            vec![Proj::Payload(v, f)],
                            matches!(module.enums[id].variants[v].1[f], Type::MutField(_)),
                        )
                    }
                    ViewKey::Index => {
                        let is_mut = match pointee {
                            Type::Array(id) => matches!(module.arrays[id].elem, Type::MutField(_)),
                            Type::List(id) | Type::RegionList(id, _) => {
                                matches!(module.lists[id], Type::MutField(_))
                            }
                            _ => unreachable!(),
                        };
                        (vec![Proj::Index(0)], is_mut)
                    }
                };
                let place = Place {
                    var: param_var,
                    proj,
                };
                definitions.insert(loan_id, (vec![(place, is_mut)], Some(is_mut), entry_span));
            }
        }
    }
    for inst in f.blocks.iter().flat_map(|b| &b.insts) {
        if let InstKind::ListPush(p, cfg::Operand::Var(source)) = &inst.kind
            && let Some(view_fields) = views.get(&p.var)
            && let Some(&loan_id) = view_fields.get(&ViewKey::Index)
        {
            let is_mut = definitions.get(&loan_id).and_then(|d| d.1).unwrap_or(false);
            let entry = definitions
                .entry(loan_id)
                .or_insert_with(|| (Vec::new(), Some(is_mut), inst.span));
            entry.0.push((root(*source), is_mut));
        }
        if let InstKind::Store(p, cfg::Operand::Var(source)) = &inst.kind
            && let Some(view_fields) = views.get(&p.var)
            && let Some(&loan_id) = view_fields.get(&ViewKey::Index)
        {
            let is_mut = definitions.get(&loan_id).and_then(|d| d.1).unwrap_or(false);
            let entry = definitions
                .entry(loan_id)
                .or_insert_with(|| (Vec::new(), Some(is_mut), inst.span));
            entry.0.push((root(*source), is_mut));
        }
        let InstKind::Assign(id, value) = &inst.kind else {
            continue;
        };
        if let Some(view_fields) = views.get(id) {
            match value {
                Rvalue::Struct(sid, operands) => {
                    for (i, (_, f_ty)) in module.structs[*sid].fields.iter().enumerate() {
                        if matches!(f_ty, Type::SharedField(_) | Type::MutField(_)) {
                            let loan_id = view_fields[&ViewKey::Field(i)];
                            let cfg::Operand::Var(source) = operands[i] else {
                                return Err(invalid_view_origin(inst.span));
                            };
                            let is_mut = matches!(f_ty, Type::MutField(_));
                            let entry = definitions
                                .entry(loan_id)
                                .or_insert_with(|| (Vec::new(), Some(is_mut), inst.span));
                            entry.0.push((root(source), is_mut));
                        }
                    }
                    continue;
                }
                Rvalue::Variant(eid, variant, operands) => {
                    for (f, f_ty) in module.enums[*eid].variants[*variant].1.iter().enumerate() {
                        if matches!(f_ty, Type::SharedField(_) | Type::MutField(_)) {
                            let loan_id = view_fields[&ViewKey::Payload(*variant, f)];
                            let cfg::Operand::Var(source) = operands[f] else {
                                return Err(invalid_view_origin(inst.span));
                            };
                            let is_mut = matches!(f_ty, Type::MutField(_));
                            let entry = definitions
                                .entry(loan_id)
                                .or_insert_with(|| (Vec::new(), Some(is_mut), inst.span));
                            entry.0.push((root(source), is_mut));
                        }
                    }
                    continue;
                }
                Rvalue::ArrayLit(_, operands) | Rvalue::ListLit(_, operands) => {
                    if let Some(&loan_id) = view_fields.get(&ViewKey::Index) {
                        let is_mut = match f.vars[*id].pointee() {
                            Type::Array(aid) => {
                                matches!(module.arrays[aid].elem, Type::MutField(_))
                            }
                            Type::List(lid) | Type::RegionList(lid, _) => {
                                matches!(module.lists[lid], Type::MutField(_))
                            }
                            _ => false,
                        };
                        let entry = definitions
                            .entry(loan_id)
                            .or_insert_with(|| (Vec::new(), Some(is_mut), inst.span));
                        for op in operands {
                            if let cfg::Operand::Var(source) = op {
                                entry.0.push((root(*source), is_mut));
                            }
                        }
                    }
                    continue;
                }
                Rvalue::Use(cfg::Operand::Var(source)) if views.contains_key(source) => {
                    for (&key, &loan_id) in view_fields {
                        if let Some(&src_loan_id) = views[source].get(&key) {
                            let is_mut = definitions
                                .get(&src_loan_id)
                                .and_then(|d| d.1)
                                .unwrap_or(false);
                            let entry = definitions
                                .entry(loan_id)
                                .or_insert_with(|| (Vec::new(), Some(is_mut), inst.span));
                            entry.0.push((root(src_loan_id), is_mut));
                        }
                    }
                    continue;
                }
                Rvalue::Call(callee, args) if funcs[*callee].view_return.is_some() => {
                    let contract = funcs[*callee].view_return.as_ref().unwrap();
                    for fc in &contract.fields {
                        let key = ViewKey::from_raw(fc.field_index);
                        if let Some(&loan_id) = view_fields.get(&key) {
                            let mut sources = Vec::new();
                            if !fc.projections.is_empty() {
                                for (param_idx, proj) in &fc.projections {
                                    let Arg::Ref(arg_place, exclusive) = &args[*param_idx] else {
                                        unreachable!("validated borrow contract")
                                    };
                                    let mut p = arg_place.clone();
                                    for ep in proj {
                                        match ep {
                                            EscapeProjection::Field(f) => {
                                                p.proj.push(Proj::Field(*f))
                                            }
                                            EscapeProjection::Payload(v, f) => {
                                                p.proj.push(Proj::Payload(*v, *f))
                                            }
                                            EscapeProjection::Indexed => {
                                                p.proj.push(Proj::Index(0))
                                            }
                                        }
                                    }
                                    sources.push((p, *exclusive || fc.mode == Receiver::Exclusive));
                                }
                            } else {
                                for &param_idx in &fc.params {
                                    let Arg::Ref(arg_place, exclusive) = &args[param_idx] else {
                                        unreachable!("validated borrow contract")
                                    };
                                    sources.push((
                                        arg_place.clone(),
                                        *exclusive || fc.mode == Receiver::Exclusive,
                                    ));
                                }
                            }
                            let entry = definitions.entry(loan_id).or_insert_with(|| {
                                (Vec::new(), Some(fc.mode == Receiver::Exclusive), inst.span)
                            });
                            entry.0.extend(sources);
                        }
                    }
                    continue;
                }
                _ => {}
            }
        }
        let (sources, writable) = match value {
            Rvalue::Loan(p, exclusive, _) => (vec![(p.clone(), *exclusive)], Some(*exclusive)),
            Rvalue::Ref(p) => (vec![(p.clone(), false)], None),
            Rvalue::Use(cfg::Operand::Var(source)) if matches!(f.vars[*id], VarTy::Ref(_)) => {
                let is_mut = definitions.get(source).and_then(|d| d.1).unwrap_or(false);
                (vec![(root(*source), is_mut)], Some(is_mut))
            }
            Rvalue::FieldLoan(p) => {
                let key = match p.proj.as_slice() {
                    [Proj::Field(i)] => Some(ViewKey::Field(*i)),
                    [Proj::Payload(v, f)] => Some(ViewKey::Payload(*v, *f)),
                    [Proj::Index(_)] => Some(ViewKey::Index),
                    _ => None,
                };
                let source = key
                    .and_then(|k| views.get(&p.var).and_then(|fields| fields.get(&k)))
                    .copied();
                let source = source.ok_or_else(|| {
                    Diagnostic::new(inst.span, "campo prestado sin procedencia de construcción")
                        .classify("L0014", "préstamos")
                })?;
                let pointee = f.vars[p.var].pointee();
                let is_mut = match (key.unwrap(), pointee) {
                    (ViewKey::Field(i), Type::Struct(sid)) => {
                        matches!(module.structs[sid].fields[i].1, Type::MutField(_))
                    }
                    (ViewKey::Payload(v, f), Type::Enum(eid)) => {
                        matches!(module.enums[eid].variants[v].1[f], Type::MutField(_))
                    }
                    (ViewKey::Index, Type::Array(aid)) => {
                        matches!(module.arrays[aid].elem, Type::MutField(_))
                    }
                    (ViewKey::Index, Type::List(lid) | Type::RegionList(lid, _)) => {
                        matches!(module.lists[lid], Type::MutField(_))
                    }
                    _ => false,
                };
                (vec![(root(source), is_mut)], Some(is_mut))
            }
            Rvalue::Call(callee, args) => {
                if let Some(contract) = &funcs[*callee].borrow_return {
                    let sources = contract
                        .params
                        .iter()
                        .map(|&index| {
                            let Arg::Ref(place, exclusive) = &args[index] else {
                                unreachable!("validated borrow contract")
                            };
                            (place.clone(), *exclusive)
                        })
                        .collect();
                    (
                        sources,
                        Some(contract.mode == crate::lir::Receiver::Exclusive),
                    )
                } else {
                    continue;
                }
            }
            _ => continue,
        };
        if definitions
            .insert(*id, (sources, writable, inst.span))
            .is_some()
        {
            return Err(Diagnostic::new(
                inst.span,
                "una referencia debe tener una única definición estática",
            )
            .classify("L0013", "préstamos"));
        }
    }
    type DefMap = BTreeMap<VarId, (Vec<(Place, bool)>, Option<bool>, Span)>;
    let mut aliases: HashMap<VarId, Alias> = HashMap::new();
    let mut visiting: HashSet<VarId> = HashSet::new();

    fn resolve_alias(
        id: VarId,
        definitions: &DefMap,
        aliases: &mut HashMap<VarId, Alias>,
        visiting: &mut HashSet<VarId>,
        views: &ViewFields,
    ) -> Result<(), Diagnostic> {
        if aliases.contains_key(&id) {
            return Ok(());
        }
        if !visiting.insert(id) {
            let span = definitions.get(&id).map(|(_, _, s)| *s).unwrap_or_default();
            return Err(Diagnostic::new(
                span,
                "la procedencia de la referencia contiene una dependencia cíclica",
            )
            .classify("L0013", "préstamos"));
        }
        let (sources, writable, span) = &definitions[&id];
        let span = *span;
        let writable = *writable;
        let sources = sources.clone();
        for (source, _) in &sources {
            if definitions.contains_key(&source.var) {
                resolve_alias(source.var, definitions, aliases, visiting, views)?;
            }
        }
        visiting.remove(&id);

        let mut resolved: Vec<Origin> = Vec::new();
        let mut ancestors = BTreeSet::from([id]);
        for (source, exclusive) in &sources {
            if let Some(parent) = aliases.get(&source.var) {
                ancestors.extend(&parent.ancestors);
            }
            for mut candidate in origins(source, aliases, views).into_owned() {
                candidate.through.push(id);
                // This alias retains the mode of each argument, including an
                // exclusive input used to produce a shared result.
                candidate.exclusive = *exclusive;
                if let Some(existing) = resolved
                    .iter_mut()
                    .find(|other| other.place == candidate.place)
                {
                    existing.exclusive |= candidate.exclusive;
                    existing
                        .through
                        .retain(|loan| candidate.through.contains(loan));
                } else {
                    if resolved.len() == MAX_ORIGINS {
                        return Err(Diagnostic::new(
                            span,
                            "la referencia excede el límite de 256 lugares de origen; divida la selección en préstamos más pequeños",
                        )
                        .classify("L0013", "préstamos"));
                    }
                    resolved.push(candidate);
                }
            }
        }
        aliases.insert(
            id,
            Alias {
                origins: resolved,
                ancestors,
                writable,
                span,
            },
        );
        Ok(())
    }

    for &id in definitions.keys() {
        resolve_alias(id, &definitions, &mut aliases, &mut visiting, views)?;
    }
    Ok(aliases)
}

fn verify_returns(
    f: &Func,
    aliases: &HashMap<VarId, Alias>,
    views: &ViewFields,
    module: &Module,
) -> Result<(BTreeSet<ReturnOrigin>, Option<ViewReturn>), Diagnostic> {
    let mut returned = BTreeSet::new();
    let mut refined_fields: BTreeMap<usize, BTreeSet<(usize, Vec<EscapeProjection>)>> =
        BTreeMap::new();
    for block in &f.blocks {
        if let Some(cfg::Terminator::ReturnRef(var, span)) = block.term {
            let contract = f.borrow_return.as_ref().expect("validated borrow contract");
            for origin in origins(&root(var), aliases, views).iter() {
                let index = contract
                    .params
                    .iter()
                    .copied()
                    .find(|&i| f.params[i] == origin.place.var);
                let Some(index) = index else {
                    let at = aliases.get(&var).map_or(span, |alias| alias.span);
                    let expected = contract
                        .params
                        .iter()
                        .map(|i| (i + 1).to_string())
                        .collect::<Vec<_>>()
                        .join(", ");
                    return Err(Diagnostic::new(span, format!("un posible origen del retorno no pertenece a los parámetros prestados [{expected}]. El préstamo de {}:{} puede apuntar a un propietario local, temporal o regional que se destruye al retornar", at.line, at.column))
                        .classify("L0013", "préstamos"));
                };
                let projection = origin
                    .place
                    .proj
                    .iter()
                    .map(|p| match p {
                        Proj::Field(i) => EscapeProjection::Field(*i),
                        Proj::Payload(variant, field) => {
                            EscapeProjection::Payload(*variant, *field)
                        }
                        Proj::Index(_) => EscapeProjection::Indexed,
                    })
                    .collect();
                returned.insert(ReturnOrigin {
                    parameter: index,
                    projection,
                });
            }
        } else if let Some(cfg::Terminator::Return(cfg::Operand::Var(res_var))) = block.term
            && let Some(field_map) = views.get(&res_var)
        {
            let res_ty = f.vars[res_var].pointee();
            let span = block
                .insts
                .iter()
                .rev()
                .find_map(|i| {
                    if matches!(&i.kind, InstKind::Assign(dest, _) if *dest == res_var) {
                        Some(i.span)
                    } else {
                        None
                    }
                })
                .unwrap_or_else(|| block.insts.last().map_or(Span::at(1, 1), |i| i.span));
            for (&key, &loan_id) in field_map {
                let field_origins = origins(&root(loan_id), aliases, views);
                let is_mut_field = match (key, res_ty) {
                    (ViewKey::Field(f), Type::Struct(sid)) => {
                        matches!(module.structs[sid].fields[f].1, Type::MutField(_))
                    }
                    (ViewKey::Payload(v, f), Type::Enum(eid)) => {
                        matches!(module.enums[eid].variants[v].1[f], Type::MutField(_))
                    }
                    (ViewKey::Index, Type::Array(aid)) => {
                        matches!(module.arrays[aid].elem, Type::MutField(_))
                    }
                    (ViewKey::Index, Type::List(lid) | Type::RegionList(lid, _)) => {
                        matches!(module.lists[lid], Type::MutField(_))
                    }
                    _ => false,
                };
                let desc = match key {
                    ViewKey::Field(f) => format!(
                        "el campo '{}'",
                        module.structs[match res_ty {
                            Type::Struct(sid) => sid,
                            _ => unreachable!(),
                        }]
                        .fields[f]
                            .0
                    ),
                    ViewKey::Payload(v, f) => format!(
                        "la variante '{}' campo {f}",
                        module.enums[match res_ty {
                            Type::Enum(eid) => eid,
                            _ => unreachable!(),
                        }]
                        .variants[v]
                            .0
                    ),
                    ViewKey::Index => "el elemento".to_string(),
                };
                for origin in field_origins.iter() {
                    if is_mut_field && !origin.exclusive {
                        return Err(Diagnostic::new(
                            span,
                            format!("{desc} mutable no puede provenir de un préstamo compartido"),
                        )
                        .classify("L0012", "préstamos"));
                    }
                    let param_index = f
                        .params
                        .iter()
                        .position(|&p| p == origin.place.var && matches!(f.vars[p], VarTy::Ref(_)));
                    let Some(param_idx) = param_index else {
                        let at = aliases.get(&loan_id).map_or(span, |alias| alias.span);
                        return Err(Diagnostic::new(
                                span,
                                format!("escape de vista devuelta: {desc} apunta a un propietario local, temporal o regional en {}:{} que se destruye al retornar", at.line, at.column)
                            ).classify("L0014", "préstamos"));
                    };
                    let projection: Vec<EscapeProjection> = origin
                        .place
                        .proj
                        .iter()
                        .map(|p| match p {
                            Proj::Field(i) => EscapeProjection::Field(*i),
                            Proj::Payload(variant, field) => {
                                EscapeProjection::Payload(*variant, *field)
                            }
                            Proj::Index(_) => EscapeProjection::Indexed,
                        })
                        .collect();
                    returned.insert(ReturnOrigin {
                        parameter: param_idx,
                        projection: projection.clone(),
                    });
                    refined_fields
                        .entry(key.to_raw())
                        .or_default()
                        .insert((param_idx, projection));
                }
            }
        }
    }
    let refined_view = f.view_return.as_ref().map(|vr| {
        let mut fields = vr.fields.clone();
        for fc in &mut fields {
            if let Some(projs) = refined_fields.get(&fc.field_index) {
                fc.projections = projs.iter().cloned().collect();
                fc.params = projs
                    .iter()
                    .map(|(p, _)| *p)
                    .collect::<BTreeSet<_>>()
                    .into_iter()
                    .collect();
            }
        }
        let params = fields
            .iter()
            .flat_map(|fc| &fc.params)
            .copied()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        ViewReturn { params, fields }
    });
    Ok((returned, refined_view))
}

pub use crate::lir::{EscapeProjection, ViewReturn};

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct ReturnOrigin {
    pub parameter: usize,
    pub projection: Vec<EscapeProjection>,
}

/// Escape destinations observed in one CFG function. Parameter indices include
/// the receiver. Forwarding is a potential escape edge, not an escape by itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EscapeSummary {
    pub return_origins: BTreeSet<ReturnOrigin>,
    pub forwarded_params: BTreeSet<usize>,
    /// Borrowed parameters whose addresses are stored only in local views.
    pub local_view_params: BTreeSet<usize>,
}

/// Classify return and call edges using the same provenance as borrow checking.
/// A parameter absent from both sets has no external destination in this subset.
/// Aggregate storage is rejected during semantic analysis.
pub fn escape_summaries(module: &Module) -> Result<Vec<EscapeSummary>, Diagnostic> {
    cfg::verify(module).map_err(cfg::VerifyError::into_diagnostic)?;
    let mut funcs = module.funcs.clone();
    loop {
        let mut changed = false;
        for i in 0..funcs.len() {
            if funcs[i].view_return.is_some() {
                let views = view_fields(&funcs[i], module)?;
                let aliases = collect_aliases(&funcs[i], &funcs, &views, module)?;
                let (_, refined_view) = verify_returns(&funcs[i], &aliases, &views, module)?;
                if let Some(refined) = refined_view
                    && funcs[i].view_return.as_ref() != Some(&refined)
                {
                    funcs[i].view_return = Some(refined);
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    funcs
        .iter()
        .map(|f| {
            let views = view_fields(f, module)?;
            let aliases = collect_aliases(f, &funcs, &views, module)?;
            let (return_origins, _) = verify_returns(f, &aliases, &views, module)?;
            let borrowed_param = |var| {
                f.params
                    .iter()
                    .position(|&p| p == var)
                    .filter(|_| matches!(f.vars[var], VarTy::Ref(_)))
            };
            let returned_params: BTreeSet<usize> =
                return_origins.iter().map(|o| o.parameter).collect();
            let mut local_view_params = BTreeSet::new();
            for loan in views.values().flat_map(|fields| fields.values()) {
                for origin in origins(&root(*loan), &aliases, &views).iter() {
                    if let Some(p) = borrowed_param(origin.place.var)
                        && !returned_params.contains(&p)
                    {
                        local_view_params.insert(p);
                    }
                }
            }
            let mut forwarded_params = BTreeSet::new();
            for inst in f.blocks.iter().flat_map(|b| &b.insts) {
                if let InstKind::Assign(_, Rvalue::Call(_, args)) = &inst.kind {
                    for arg in args {
                        if let Arg::Ref(place, _) = arg {
                            for origin in origins(place, &aliases, &views).iter() {
                                forwarded_params.extend(borrowed_param(origin.place.var));
                            }
                        }
                    }
                }
            }
            Ok(EscapeSummary {
                return_origins,
                forwarded_params,
                local_view_params,
            })
        })
        .collect()
}

fn check_func(
    f: &Func,
    module: &Module,
    funcs: &[Func],
    ownership: &Ownership,
) -> Result<(), Diagnostic> {
    let explicit = f
        .blocks
        .iter()
        .flat_map(|b| &b.insts)
        .any(|i| match &i.kind {
            InstKind::Assign(_, Rvalue::Loan(..) | Rvalue::FieldLoan(_)) => true,
            InstKind::Assign(_, Rvalue::Struct(id, _)) => module.structs[*id]
                .fields
                .iter()
                .any(|(_, ty)| matches!(ty, Type::SharedField(_) | Type::MutField(_))),
            InstKind::Assign(_, Rvalue::Variant(id, variant, _)) => module.enums[*id].variants
                [*variant]
                .1
                .iter()
                .any(|ty| matches!(ty, Type::SharedField(_) | Type::MutField(_))),
            InstKind::Assign(_, Rvalue::ArrayLit(ty, _) | Rvalue::ListLit(ty, _)) => match ty {
                Type::Array(aid) => {
                    matches!(
                        module.arrays[*aid].elem,
                        Type::SharedField(_) | Type::MutField(_)
                    )
                }
                Type::List(lid) | Type::RegionList(lid, _) => {
                    matches!(module.lists[*lid], Type::SharedField(_) | Type::MutField(_))
                }
                _ => false,
            },
            InstKind::Assign(_, Rvalue::Call(id, _)) => {
                funcs[*id].borrow_return.is_some() || funcs[*id].view_return.is_some()
            }
            _ => false,
        });
    if f.borrow_return.is_none() && f.view_return.is_none() && !explicit {
        return Ok(());
    }
    let views = view_fields(f, module)?;
    let aliases = collect_aliases(f, funcs, &views, module)?;
    verify_returns(f, &aliases, &views, module)?;
    let owned = Owned {
        vars: &f.vars,
        ownership,
    };
    let outputs = live_out(f, &aliases, &views);
    let mut reachable = HashSet::new();
    let mut pending = vec![0];
    while let Some(b) = pending.pop() {
        if reachable.insert(b) {
            pending.extend(cfg::successors(f.blocks[b].term.as_ref().unwrap()));
        }
    }
    for (b, block) in f.blocks.iter().enumerate() {
        if !reachable.contains(&b) {
            continue;
        }
        let mut live = outputs[b].clone();
        for inst in block.insts.iter().rev() {
            step(&mut live, inst, &aliases, &views);
            let mut active = BTreeMap::<VarId, Span>::new();
            for (&id, &later) in &live {
                if let Some(alias) = aliases.get(&id) {
                    for &ancestor in &alias.ancestors {
                        if aliases[&ancestor].writable.is_some() {
                            let witness = active.entry(ancestor).or_insert(later);
                            if (later.line, later.column) < (witness.line, witness.column) {
                                *witness = later;
                            }
                        }
                    }
                }
            }
            for (place, write) in accesses(&inst.kind, &owned) {
                for access in origins(&place, &aliases, &views).iter() {
                    for id in &access.through {
                        if write && aliases[id].writable == Some(false) {
                            return Err(conflict(inst.span, aliases[id].span, inst.span));
                        }
                    }
                    for (id, later) in &active {
                        let alias = &aliases[id];
                        for loan in &alias.origins {
                            let ends_region = matches!(inst.kind, InstKind::Drop(v, _) if v == access.place.var)
                                && matches!(f.vars[access.place.var].pointee(), Type::Region(r)
                                    if matches!(f.vars[loan.place.var].pointee(), Type::Bytes(id) | Type::RegionList(_, id) if id == r));
                            if ends_region
                                || ((write || loan.exclusive)
                                    && !access.through.contains(id)
                                    && overlaps(&access.place, &loan.place))
                            {
                                return Err(conflict(inst.span, alias.span, *later));
                            }
                        }
                    }
                }
            }
            if let InstKind::Assign(_, Rvalue::Call(_, args)) = &inst.kind {
                let refs: Vec<_> = args
                    .iter()
                    .filter_map(|arg| match arg {
                        Arg::Ref(p, exclusive) => Some((origins(p, &aliases, &views), *exclusive)),
                        _ => None,
                    })
                    .collect();
                for (i, (place, exclusive)) in refs.iter().enumerate() {
                    for (other, other_exclusive) in &refs[i + 1..] {
                        if (*exclusive || *other_exclusive)
                            && place
                                .iter()
                                .any(|a| other.iter().any(|b| overlaps(&a.place, &b.place)))
                        {
                            return Err(Diagnostic::new(inst.span, "préstamos incompatibles en la llamada: sus referencias pueden apuntar al mismo lugar").classify("L0012", "préstamos"));
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

pub(crate) fn check(module: &Module, ownership: &Ownership) -> Result<(), Diagnostic> {
    let mut funcs = module.funcs.clone();
    loop {
        let mut changed = false;
        for i in 0..funcs.len() {
            if funcs[i].view_return.is_some() {
                let views = view_fields(&funcs[i], module)?;
                let aliases = collect_aliases(&funcs[i], &funcs, &views, module)?;
                let (_, refined_view) = verify_returns(&funcs[i], &aliases, &views, module)?;
                if let Some(refined) = refined_view
                    && funcs[i].view_return.as_ref() != Some(&refined)
                {
                    funcs[i].view_return = Some(refined);
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    for f in &funcs {
        check_func(f, module, &funcs, ownership)?;
    }
    Ok(())
}

#[cfg(test)]
#[test]
#[ignore = "microbenchmark manual del pase de préstamos"]
fn profile_local_loans() {
    use std::{fmt::Write, time::Instant};
    for count in [1, 80] {
        let mut source = String::new();
        for i in 0..count {
            writeln!(
                source,
                "fn sample_{i}() {{\n let x = 10\n let r = &x\n print(r)\n}}"
            )
            .unwrap();
        }
        source.push_str("fn main() { sample_0() }");
        let ir = crate::check(&source).unwrap();
        let module = crate::lower_to_cfg(&ir).unwrap();
        let ownership = Ownership::new(
            &module.structs,
            &module.enums,
            &module.arrays,
            &module.lists,
        );
        let mut samples = Vec::new();
        for _ in 0..21 {
            let start = Instant::now();
            for _ in 0..100 {
                check(std::hint::black_box(&module), &ownership).unwrap();
            }
            samples.push(start.elapsed().as_secs_f64() * 10_000.0);
        }
        samples.sort_by(f64::total_cmp);
        eprintln!(
            "functions={} loans={count} median_us={:.2} min_us={:.2} max_us={:.2}",
            module.funcs.len(),
            samples[10],
            samples[0],
            samples[20]
        );
    }
}

#[cfg(test)]
#[test]
#[ignore = "microbenchmark manual de retornos prestados"]
fn profile_reference_returns() {
    use std::{fmt::Write, time::Instant};
    for (count, multiple) in [(1, false), (80, false), (80, true)] {
        let mut source = if multiple {
            "fn sample_0(a: &Int, b: &Int) -> &Int = a\n".to_string()
        } else {
            "fn sample_0(x: &Int) -> &Int = x\n".to_string()
        };
        for i in 1..count {
            if multiple {
                writeln!(
                    source,
                    "fn sample_{i}(a: &Int, b: &Int) -> &Int = sample_{}(b, a)",
                    i - 1
                )
                .unwrap();
            } else {
                writeln!(
                    source,
                    "fn sample_{i}(x: &Int) -> &Int = sample_{}(x)",
                    i - 1
                )
                .unwrap();
            }
        }
        let args = if multiple { "x, y" } else { "x" };
        writeln!(
            source,
            "fn main() {{ let x = 1\n let y = 2\n let r = sample_{}({args})\n print(r) }}",
            count - 1
        )
        .unwrap();
        let ir = crate::check(&source).unwrap();
        let module = crate::lower_to_cfg(&ir).unwrap();
        let ownership = Ownership::new(
            &module.structs,
            &module.enums,
            &module.arrays,
            &module.lists,
        );
        let aliases: Vec<_> = module
            .funcs
            .iter()
            .map(|f| {
                collect_aliases(f, &module.funcs, &view_fields(f, &module).unwrap(), &module)
                    .unwrap()
            })
            .collect();
        for (label, passes) in [("borrow_and_escape", true), ("escape_only", false)] {
            let mut samples = Vec::new();
            for _ in 0..15 {
                let start = Instant::now();
                for _ in 0..100 {
                    if passes {
                        check(std::hint::black_box(&module), &ownership).unwrap();
                    } else {
                        for (f, table) in module.funcs.iter().zip(std::hint::black_box(&aliases)) {
                            let views = view_fields(f, &module).unwrap();
                            verify_returns(f, table, &views, &module).unwrap();
                        }
                    }
                }
                samples.push(start.elapsed().as_secs_f64() * 10_000.0);
            }
            samples.sort_by(f64::total_cmp);
            eprintln!(
                "{label} functions={} contracts={count} multiple={multiple} median_us={:.2} min_us={:.2} max_us={:.2}",
                module.funcs.len(),
                samples[7],
                samples[0],
                samples[14]
            );
        }
    }
}

#[cfg(test)]
#[test]
#[ignore = "microbenchmark manual de vistas locales"]
fn profile_aggregate_views() {
    use std::{fmt::Write, time::Instant};
    for count in [1, 40] {
        let mut source =
            "struct Owned { n: Int }\nstruct View { a: &Int, b: &Int, owned: Owned }\n".to_string();
        for i in 0..count {
            writeln!(source, "fn sample_{i}() {{\n let x = 1\n let y = 2\n let v = View(a: &x, b: &y, owned: Owned(n: x))\n let moved = v\n print(moved.a + moved.b + moved.owned.n)\n}}").unwrap();
        }
        source.push_str("fn main() { sample_0() }");
        let ir = crate::check(&source).unwrap();
        let module = crate::lower_to_cfg(&ir).unwrap();
        let ownership = Ownership::new(
            &module.structs,
            &module.enums,
            &module.arrays,
            &module.lists,
        );
        for provenance_only in [false, true] {
            let mut samples = Vec::new();
            for _ in 0..15 {
                let start = Instant::now();
                for _ in 0..100 {
                    if provenance_only {
                        for f in &std::hint::black_box(&module).funcs {
                            let views = view_fields(f, &module).unwrap();
                            std::hint::black_box(
                                collect_aliases(f, &module.funcs, &views, &module).unwrap(),
                            );
                        }
                    } else {
                        check(std::hint::black_box(&module), &ownership).unwrap();
                    }
                }
                samples.push(start.elapsed().as_secs_f64() * 10_000.0);
            }
            samples.sort_by(f64::total_cmp);
            eprintln!(
                "functions={} views={count} field_loans={} provenance_only={provenance_only} median_us={:.2} min_us={:.2} max_us={:.2}",
                module.funcs.len(),
                count * 2,
                samples[7],
                samples[0],
                samples[14]
            );
        }
    }
}
