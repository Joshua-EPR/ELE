//! Conservative move checking for owned (non-`Copy`) values: Text, structs and
//! enums. No user-visible references yet; method receivers are implicit
//! borrows, and `match` bindings borrow from or move out of the scrutinee.
//!
//! The pass also decides, for every owned pattern binding, whether it takes
//! ownership (by value) or is a shared borrow into the scrutinee, and records
//! the by-value ones in `Function::by_value_bindings` for the backend.
use crate::{
    Diagnostic,
    lir::{Arm, Instruction, Place, Program, Receiver, Value, ValueKind},
};
use std::{
    cell::RefCell,
    collections::{HashMap, HashSet},
    rc::Rc,
};

/// How an owned pattern binding relates to a place scrutinee.
#[derive(Clone, Copy)]
enum Projection {
    /// Part of an owned local: moving the binding moves (all of) that local.
    Owned(usize),
    /// Part of a borrowed or field place: the binding can only be read.
    Borrowed,
}

#[derive(Clone, Default)]
struct State {
    /// Owned locals currently initialized and not moved.
    available: HashSet<usize>,
    /// Partially moved subtrees. Root availability is retained for siblings.
    moved_fields: HashSet<Place>,
    /// Owned locals declared so far (used to protect them inside loops).
    known: HashSet<usize>,
    /// Outer owned locals that a loop body must not move.
    protected: HashSet<usize>,
    /// Locals that are implicit borrows (`self`) or reference parameters: never movable.
    borrowed: HashSet<usize>,
    /// Roots examined by an enclosing match arm with owned bindings: they may
    /// not be used directly until the arm ends.
    frozen: HashSet<usize>,
    projections: HashMap<usize, Projection>,
    /// Pattern bindings that take ownership (shared across branch clones).
    by_value: Rc<RefCell<HashSet<usize>>>,
    /// Active borrows: maps reference binding id to (place, is_exclusive).
    borrows: HashMap<usize, (Place, bool)>,
    receiver_id: Option<usize>,
}

impl State {
    fn active_shared_borrows(&self, root: usize) -> bool {
        self.borrows
            .values()
            .any(|(p, is_mut)| p.root == root && !*is_mut)
    }
    fn active_exclusive_borrows(&self, root: usize) -> bool {
        self.borrows
            .values()
            .any(|(p, is_mut)| p.root == root && *is_mut)
    }
}

/// Two places may share memory: same root and one path is a prefix of the other.
fn overlaps(a: &Place, b: &Place) -> bool {
    a.root == b.root && {
        let n = a.fields.len().min(b.fields.len());
        a.fields[..n] == b.fields[..n]
    }
}

/// The borrows passed to one call (and its receiver) are all alive for the
/// whole call: an exclusive borrow may not overlap any other borrow of it.
fn check_call_borrows(receiver: Option<(&Place, bool)>, args: &[Value]) -> Result<(), Diagnostic> {
    let mut borrows: Vec<(&Place, bool, &Value)> = Vec::new();
    for arg in args {
        if let ValueKind::Borrow(place, mutable) = &arg.kind {
            borrows.push((place, *mutable, arg));
        }
    }
    for (i, (pa, ma, va)) in borrows.iter().enumerate() {
        if let Some((pr, mr)) = receiver
            && (*ma || mr)
            && overlaps(pa, pr)
        {
            return Err(Diagnostic::new(
                va.span,
                "préstamo incompatible con el receptor del método: un préstamo mutable debe ser exclusivo durante la llamada",
            ));
        }
        for (pb, mb, _) in &borrows[i + 1..] {
            if (*ma || *mb) && overlaps(pa, pb) {
                return Err(Diagnostic::new(
                    va.span,
                    "préstamos incompatibles en la misma llamada: un préstamo mutable debe ser exclusivo",
                ));
            }
        }
    }
    Ok(())
}

/// Root local of a value that denotes a place (`x`, `x.a.b`), if any.
fn place_root(value: &Value) -> Option<usize> {
    match &value.kind {
        ValueKind::Local(id) => Some(*id),
        ValueKind::Field(base, _) | ValueKind::Index(base, _) => place_root(base),
        _ => None,
    }
}

fn value_place(value: &Value) -> Option<Place> {
    match &value.kind {
        ValueKind::Local(id) => Some(Place {
            root: *id,
            fields: Vec::new(),
        }),
        ValueKind::Field(base, field) => {
            let mut p = value_place(base)?;
            p.fields.push(*field);
            Some(p)
        }
        _ => None,
    }
}

/// Whether a structured block cannot reach the following statement.
fn exits(body: &[Instruction]) -> bool {
    body.iter().any(|i| match i {
        Instruction::Return(_)
        | Instruction::ReturnRef(..)
        | Instruction::Break
        | Instruction::Continue => true,
        Instruction::Block(body) => exits(body),
        Instruction::If(_, yes, no) => exits(yes) && exits(no),
        _ => false,
    })
}

impl State {
    fn require(&self, id: usize, value: &Value) -> Result<(), Diagnostic> {
        self.require_place(
            &Place {
                root: id,
                fields: Vec::new(),
            },
            value,
        )
    }
    fn require_place(&self, place: &Place, value: &Value) -> Result<(), Diagnostic> {
        let id = place.root;
        if self.frozen.contains(&id) {
            return Err(Diagnostic::new(
                value.span,
                "valor examinado por match: dentro del brazo use los nombres del patrón",
            ));
        }
        if self.known.contains(&id) && !self.available.contains(&id) {
            return Err(Diagnostic::new(
                value.span,
                "uso de valor después de moverlo (o movido en alguna rama)",
            ));
        }
        if self.active_exclusive_borrows(id) {
            return Err(Diagnostic::new(
                value.span,
                "no se puede leer un valor mientras existe un préstamo mutable activo",
            ));
        }
        if self.moved_fields.iter().any(|p| {
            p.root == id
                && (p.fields.starts_with(&place.fields) || place.fields.starts_with(&p.fields))
        }) {
            return Err(Diagnostic::new(
                value.span,
                "uso de campo o agregado parcialmente movido",
            ));
        }
        Ok(())
    }
    /// Moves owned local `id` (already checked available).
    fn consume_local(&mut self, id: usize, value: &Value) -> Result<(), Diagnostic> {
        if self.borrowed.contains(&id) {
            let msg = if self.receiver_id == Some(id) {
                "no se puede mover self: el método solo lo recibe prestado"
            } else {
                "no se puede mover un valor recibido por referencia"
            };
            return Err(Diagnostic::new(value.span, msg));
        }
        if self.active_shared_borrows(id) || self.active_exclusive_borrows(id) {
            return Err(Diagnostic::new(
                value.span,
                "no se puede mover un valor mientras está prestado",
            ));
        }
        if self.protected.contains(&id) {
            return Err(Diagnostic::new(
                value.span,
                "movimiento de valor exterior dentro de bucle no soportado; podría repetirse",
            ));
        }
        match self.projections.get(&id).copied() {
            Some(Projection::Borrowed) => {
                return Err(Diagnostic::new(
                    value.span,
                    "no se puede mover un valor del patrón: está prestado de un campo o de self",
                ));
            }
            Some(Projection::Owned(root)) => {
                self.by_value.borrow_mut().insert(id);
                // Moving part of the scrutinee consumes the whole owned root.
                self.consume_local(root, value)?;
            }
            None => {}
        }
        self.available.remove(&id);
        Ok(())
    }
    fn call_arguments(&mut self, args: &[Value]) -> Result<(), Diagnostic> {
        for arg in args {
            self.value(arg, true)?;
        }
        // Address arguments are activated after evaluating by-value arguments.
        for arg in args {
            if let ValueKind::Borrow(place, _) = &arg.kind {
                self.require_place(place, arg)?;
            }
        }
        Ok(())
    }
    fn value(&mut self, value: &Value, consume: bool) -> Result<(), Diagnostic> {
        match &value.kind {
            ValueKind::Local(id) if value.ty.is_move() => {
                self.require(*id, value)?;
                if consume {
                    self.consume_local(*id, value)?;
                }
            }
            ValueKind::StoredBorrow(base) => self.value(base, false)?,
            ValueKind::SharedField(base, _) => {
                self.value(base, false)?;
                if consume && value.ty.is_move() {
                    return Err(Diagnostic::new(
                        value.span,
                        "no se puede mover el referente de un campo prestado",
                    ));
                }
            }
            ValueKind::Field(base, _) => match value_place(value) {
                Some(place) => {
                    self.require_place(&place, value)?;
                    if consume && value.ty.is_move() {
                        if self.borrowed.contains(&place.root)
                            || self.projections.contains_key(&place.root)
                        {
                            return Err(Diagnostic::new(
                                value.span,
                                format!("no se puede mover un campo prestado (self o patrón); value={value:?}"),
                            ));
                        }
                        if self.protected.contains(&place.root) {
                            return Err(Diagnostic::new(
                                value.span,
                                "movimiento de campo exterior dentro de bucle no soportado; podría repetirse",
                            ));
                        }
                        self.moved_fields.insert(place);
                    }
                }
                // Field of an element: reading borrows the collection; an
                // owned field cannot be moved out of it.
                None if place_root(base).is_some() => {
                    self.value(base, false)?;
                    if consume && value.ty.is_move() {
                        return Err(Diagnostic::new(
                            value.span,
                            "no se puede mover un elemento fuera de una colección (sin movimientos parciales); léalo con print/interpolación o use un índice para reemplazarlo",
                        ));
                    }
                }
                // Field of a temporary: the temporary itself is consumed.
                None => self.value(base, true)?,
            },
            ValueKind::Call(_, args) | ValueKind::Variant(_, _, args) => {
                check_call_borrows(None, args)?;
                self.call_arguments(args)?;
            }
            // Awaiting consumes the future: its result is moved out and the
            // task state is released.
            ValueKind::Await(future) | ValueKind::JoinAll(future) => self.value(future, true)?,
            ValueKind::Join(handles) => {
                for handle in handles.iter() {
                    self.value(handle, true)?;
                }
            }
            // Spawning moves the future into the scheduler; the handle that
            // comes back owns the task.
            ValueKind::Spawn(future) => self.value(future, true)?,
            ValueKind::ArrayLit(items) | ValueKind::ListLit(items) => {
                for item in items {
                    self.value(item, true)?;
                }
            }
            ValueKind::Index(base, index) => {
                self.value(index, true)?;
                // Reading through a place borrows it; a temporary collection
                // is consumed by the expression.
                self.value(base, place_root(base).is_none())?;
                if consume && value.ty.is_move() {
                    return Err(Diagnostic::new(
                        value.span,
                        "no se puede mover un elemento fuera de una colección (sin movimientos parciales); léalo con print/interpolación o use un índice para reemplazarlo",
                    ));
                }
            }
            ValueKind::Length(base) | ValueKind::Capacity(base) => {
                self.value(base, place_root(base).is_none())?;
            }
            ValueKind::TextByte(base, index) => {
                self.value(base, place_root(base).is_none())?;
                self.value(index, true)?;
            }
            ValueKind::ListPush(list, item) => {
                self.value(item, true)?;
                self.mutate_collection(list, value)?;
            }
            ValueKind::ListReserve(list, n) => {
                self.value(n, true)?;
                self.mutate_collection(list, value)?;
            }
            ValueKind::ListPop(list, ..) => self.mutate_collection(list, value)?,
            // Region and buffer operations borrow their receiver for the
            // duration of the operation; operands are evaluated normally.
            ValueKind::RegionList(place) => self.require(place.root, value)?,
            ValueKind::RegionBytes(place, size) => {
                self.value(size, true)?;
                self.place_available(place, value)?;
            }
            ValueKind::BytesLen(place) => self.place_available(place, value)?,
            ValueKind::BytesGet(place, index) => {
                self.value(index, true)?;
                self.place_available(place, value)?;
            }
            ValueKind::BytesSet(place, index, byte) => {
                self.value(index, true)?;
                self.value(byte, true)?;
                self.place_available(place, value)?;
                if self.active_shared_borrows(place.root) {
                    return Err(Diagnostic::new(
                        value.span,
                        "no se puede modificar el buffer mientras está prestado",
                    ));
                }
            }
            ValueKind::Borrow(place, mutable) => {
                self.require_place(place, value)?;
                if *mutable {
                    if self.active_exclusive_borrows(place.root)
                        || self.active_shared_borrows(place.root)
                    {
                        return Err(Diagnostic::new(
                            value.span,
                            "no se puede crear un préstamo mutable mientras existen otros préstamos activos",
                        ));
                    }
                } else if self.active_exclusive_borrows(place.root) {
                    return Err(Diagnostic::new(
                        value.span,
                        "no se puede crear un préstamo de lectura mientras existe un préstamo mutable activo",
                    ));
                }
            }
            ValueKind::MethodCall(_, place, receiver, args) => {
                check_call_borrows(Some((place, *receiver == Receiver::Exclusive)), args)?;
                self.place_available(place, value)?;
                if *receiver == Receiver::Exclusive {
                    if self.active_exclusive_borrows(place.root)
                        || self.active_shared_borrows(place.root)
                    {
                        return Err(Diagnostic::new(
                            value.span,
                            "no se puede invocar método mutable mientras existen otros préstamos activos",
                        ));
                    }
                } else if self.active_exclusive_borrows(place.root) {
                    return Err(Diagnostic::new(
                        value.span,
                        "no se puede invocar método de lectura mientras existe un préstamo mutable activo",
                    ));
                }
                self.call_arguments(args)?;
                if self.require_place(place, value).is_err() {
                    return Err(Diagnostic::new(
                        value.span,
                        "el receptor se mueve en los argumentos de su propio método",
                    ));
                }
            }
            ValueKind::TempMethodCall(_, receiver, args) => {
                check_call_borrows(None, args)?;
                self.value(receiver, true)?;
                self.call_arguments(args)?;
            }
            ValueKind::Construct(_, inits) => {
                for (_, init) in inits {
                    self.value(init, true)?;
                }
            }
            ValueKind::Match(scrutinee, arms) => self.match_value(scrutinee, arms)?,
            ValueKind::Print(arg) => self.value(arg, false)?,
            ValueKind::Platform(_, args) => {
                for arg in args {
                    self.value(arg, false)?;
                }
            }
            ValueKind::Interpolate(parts) => {
                // Each part is formatted immediately, so its temporary borrow ends
                // before evaluating the next expression. Calls still move arguments.
                for part in parts {
                    self.value(part, false)?;
                }
            }
            ValueKind::Unary(_, arg) => self.value(arg, true)?,
            ValueKind::Binary(op, a, b) => {
                self.value(a, true)?;
                if op == "&&" || op == "||" {
                    let mut rhs = self.clone();
                    rhs.value(b, true)?;
                    self.available.retain(|id| rhs.available.contains(id));
                    self.moved_fields.extend(rhs.moved_fields);
                } else {
                    self.value(b, true)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    fn match_value(&mut self, scrutinee: &Value, arms: &[Arm]) -> Result<(), Diagnostic> {
        let root = place_root(scrutinee);
        // Owned bindings of a direct owned local are projections of it; of a
        // field or a borrowed local they are borrows; of a temporary they own.
        let projection = match (root, &scrutinee.kind) {
            (None, _) => None,
            (Some(r), ValueKind::Local(_))
                if !self.borrowed.contains(&r)
                    && !matches!(self.projections.get(&r), Some(Projection::Borrowed)) =>
            {
                Some(Projection::Owned(r))
            }
            (Some(_), _) => Some(Projection::Borrowed),
        };
        match root {
            None => self.value(scrutinee, true)?,
            Some(_) => self.value(scrutinee, false)?,
        }
        let mut states = Vec::new();
        for arm in arms {
            let mut state = self.clone();
            let owned: Vec<usize> = arm
                .bindings
                .iter()
                .filter(|(_, t)| t.is_move())
                .map(|(id, _)| *id)
                .collect();
            if let Some(r) = root
                && !owned.is_empty()
            {
                state.frozen.insert(r);
            }
            for id in owned {
                state.known.insert(id);
                state.available.insert(id);
                match projection {
                    Some(p) => {
                        state.projections.insert(id, p);
                    }
                    None => {
                        state.by_value.borrow_mut().insert(id);
                    }
                }
            }
            state.block(&arm.body)?;
            if let Some(v) = &arm.value {
                state.value(v, true)?;
            }
            states.push((state, arm.diverges));
        }
        // Code after the match is reached only through arms that complete.
        let completing: Vec<&State> = states.iter().filter(|(_, d)| !d).map(|(s, _)| s).collect();
        let merge: Vec<&State> = if completing.is_empty() {
            states.iter().map(|(s, _)| s).collect()
        } else {
            completing
        };
        self.available
            .retain(|id| merge.iter().all(|s| s.available.contains(id)));
        self.moved_fields.clear();
        for s in &merge {
            self.moved_fields.extend(s.moved_fields.iter().cloned());
        }
        for (s, _) in &states {
            self.known.extend(s.known.iter().copied());
            self.projections
                .extend(s.projections.iter().map(|(k, v)| (*k, *v)));
        }
        Ok(())
    }
    /// A collection modified in place must be available and not borrowed.
    fn mutate_collection(&mut self, target: &Value, at: &Value) -> Result<(), Diagnostic> {
        self.value(target, false)?;
        if let Some(root) = place_root(target)
            && (self.active_shared_borrows(root) || self.active_exclusive_borrows(root))
        {
            return Err(Diagnostic::new(
                at.span,
                "no se puede modificar una colección mientras está prestada (p. ej. durante un for que la recorre)",
            ));
        }
        Ok(())
    }
    fn place_available(&self, place: &Place, value: &Value) -> Result<(), Diagnostic> {
        self.require_place(place, value)
    }
    fn block(&mut self, body: &[Instruction]) -> Result<(), Diagnostic> {
        for instruction in body {
            match instruction {
                Instruction::BindRef(id, mode, _, source) => {
                    self.value(source, false)?;
                    if *mode == Receiver::Exclusive
                        && place_root(source).is_some_and(|root| self.active_shared_borrows(root))
                    {
                        return Err(Diagnostic::new(
                            source.span,
                            "préstamo mutable incompatible con la iteración activa",
                        ));
                    }
                    self.borrowed.insert(*id);
                }
                Instruction::Bind(id, _, v) => {
                    self.value(v, true)?;
                    if v.ty.is_move() {
                        self.known.insert(*id);
                        self.available.insert(*id);
                    }
                }
                Instruction::Store(place, v) => {
                    self.value(v, true)?;
                    if self.frozen.contains(&place.root) {
                        return Err(Diagnostic::new(
                            v.span,
                            "no se puede modificar un valor mientras match examina sus datos",
                        ));
                    }
                    if self.active_shared_borrows(place.root) {
                        return Err(Diagnostic::new(
                            v.span,
                            "no se puede modificar un valor mientras tiene préstamos de lectura activos",
                        ));
                    }
                    if self.active_exclusive_borrows(place.root) {
                        return Err(Diagnostic::new(
                            v.span,
                            "no se puede reasignar un valor mientras tiene un préstamo mutable activo",
                        ));
                    }
                    if place.fields.is_empty() {
                        // Whole reassignment (re)initializes the binding.
                        if v.ty.is_move() {
                            self.known.insert(place.root);
                            self.available.insert(place.root);
                            self.moved_fields.retain(|p| p.root != place.root);
                        }
                    } else {
                        if self.known.contains(&place.root) && !self.available.contains(&place.root)
                        {
                            return Err(Diagnostic::new(
                                v.span,
                                "asignación a campo de un struct ya movido",
                            ));
                        }
                        // Reinitializing a moved subtree is valid; writing through
                        // a moved ancestor is not (its other fields are uninitialized).
                        if self.moved_fields.iter().any(|p| {
                            p.root == place.root
                                && p.fields.len() < place.fields.len()
                                && place.fields.starts_with(&p.fields)
                        }) {
                            return Err(Diagnostic::new(
                                v.span,
                                "asignación a campo dentro de un agregado movido",
                            ));
                        }
                        self.moved_fields.retain(|p| {
                            p.root != place.root || !p.fields.starts_with(&place.fields)
                        });
                    }
                }
                Instruction::ReturnRef(_, v) => self.value(v, false)?,
                Instruction::Eval(v) | Instruction::Return(v) => self.value(v, true)?,
                Instruction::If(v, yes, no) => {
                    self.value(v, true)?;
                    let mut y = self.clone();
                    let mut n = self.clone();
                    y.block(yes)?;
                    n.block(no)?;
                    match (exits(yes), exits(no)) {
                        (true, false) => {
                            self.available = n.available;
                            self.moved_fields = n.moved_fields;
                        }
                        (false, true) => {
                            self.available = y.available;
                            self.moved_fields = y.moved_fields;
                        }
                        _ => {
                            self.available =
                                y.available.intersection(&n.available).copied().collect();
                            self.moved_fields = y.moved_fields;
                            self.moved_fields.extend(n.moved_fields);
                        }
                    }
                    self.known.extend(y.known);
                    self.known.extend(n.known);
                }
                Instruction::While(condition, body) => self.loop_body(Some(condition), body)?,
                Instruction::ForEach(id, by_ref, coll, body) => {
                    let root = place_root(coll);
                    self.value(coll, root.is_none())?;
                    // An owned element is only borrowed by the loop variable.
                    if *by_ref {
                        self.borrowed.insert(*id);
                    }
                    // The collection is borrowed for the whole loop: no push,
                    // element store or move may invalidate the iteration.
                    if let Some(r) = root {
                        self.borrows.insert(
                            *id,
                            (
                                Place {
                                    root: r,
                                    fields: Vec::new(),
                                },
                                false,
                            ),
                        );
                    }
                    let result = self.loop_body(None, body);
                    self.borrows.remove(id);
                    result?;
                }
                Instruction::StoreElem(target, v) => {
                    self.value(v, true)?;
                    self.mutate_collection(target, v)?;
                }
                Instruction::ForRange(_, start, end, _, body) => {
                    self.value(start, true)?;
                    self.value(end, true)?;
                    self.loop_body(None, body)?;
                }
                Instruction::Loop(body) => self.loop_body(None, body)?,
                Instruction::Block(body) => self.block(body)?,
                // A suspension point moves nothing and borrows nothing.
                Instruction::Sleep(v) => self.value(v, false)?,
                Instruction::Yield => {}
                Instruction::Break | Instruction::Continue => {}
            }
        }
        Ok(())
    }
    fn loop_body(
        &mut self,
        condition: Option<&Value>,
        body: &[Instruction],
    ) -> Result<(), Diagnostic> {
        let mut loop_state = self.clone();
        loop_state.protected.extend(self.known.iter().copied());
        if let Some(c) = condition {
            loop_state.value(c, true)?;
        }
        loop_state.block(body)?;
        // Loop may execute zero times or exit early. Preserve only incoming guarantees.
        self.available
            .retain(|id| loop_state.available.contains(id));
        self.moved_fields.extend(loop_state.moved_fields);
        Ok(())
    }
}
pub fn check(program: &mut Program) -> Result<(), Diagnostic> {
    for function in &mut program.functions {
        let mut state = State::default();
        if let Some((id, _, _)) = function.receiver {
            state.receiver_id = Some(id);
            state.known.insert(id);
            state.available.insert(id);
            state.borrowed.insert(id);
        }
        for ((id, ty), mode) in function.params.iter().zip(&function.param_modes) {
            if mode.is_some() {
                state.borrowed.insert(*id);
            }
            if ty.is_move() {
                state.known.insert(*id);
                state.available.insert(*id);
            }
        }
        state
            .block(&function.body)
            .map_err(|e| e.classify("L0005", "ownership"))?;
        function.by_value_bindings = state.by_value.take();
    }
    Ok(())
}
