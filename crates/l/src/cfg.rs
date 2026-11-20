//! Block-based LIR ("CFG LIR"): functions made of basic blocks with explicit
//! terminators, typed variables and typed instructions.
//!
//! It is derived from the structured LIR (`lir.rs`) after semantic and
//! ownership analysis, so it never needs to re-check the language rules; the
//! verifier only checks that the lowering produced a well-formed program.
//! Variables are *not* SSA: a variable may be assigned in several blocks.
//! Native backends build SSA themselves (Cranelift's `FunctionBuilder` does it
//! from `def_var`/`use_var`).
//!
//! Nothing here depends on a particular backend.
use crate::{
    Diagnostic, Span,
    lir::{self, EnumDef, Pattern, PlatformOp, Receiver, StructDef, Type, ValueKind},
};
use std::collections::{HashMap, HashSet};

pub type VarId = usize;
pub type BlockId = usize;

/// Type of a variable: an owned/copied value, or a borrow of a value (`self`
/// in methods and pattern bindings that borrow from a match scrutinee). A
/// place rooted at a borrow implicitly dereferences it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VarTy {
    Value(Type),
    Ref(Type),
}
impl VarTy {
    pub fn pointee(self) -> Type {
        match self {
            VarTy::Value(t) | VarTy::Ref(t) => t,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Const {
    Int(i64),
    /// IEEE-754 bits, so NaN and -0.0 survive unchanged.
    Float(u64),
    F32(u32),
    Bool(bool),
    Unit,
    /// UTF-8 bytes with static storage.
    Text(String),
}
impl Const {
    pub fn ty(&self) -> Type {
        match self {
            Const::Int(_) => Type::Int,
            Const::Float(_) => Type::Float,
            Const::F32(_) => Type::F32,
            Const::Bool(_) => Type::Bool,
            Const::Unit => Type::Unit,
            Const::Text(_) => Type::Text,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Operand {
    Var(VarId),
    Const(Const),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Proj {
    /// Struct field index.
    Field(usize),
    /// Enum payload `index` of `variant`; only valid once the discriminant
    /// is known to be `variant`.
    Payload(usize, usize),
    /// Element of an array, slice or list at the index held by the (Int)
    /// variable. Every access through it is bounds-checked by the backend.
    Index(VarId),
}

/// Memory location: a variable (dereferenced if it is a borrow) followed by
/// field/payload projections.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Place {
    pub var: VarId,
    pub proj: Vec<Proj>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnOp {
    /// Integer negation panics on overflow; Float negation is IEEE.
    Neg,
    Not,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinOp {
    /// Integer Add/Sub/Mul/Div/Rem panic on overflow, division or remainder by
    /// zero, at the instruction's span. Float follows IEEE-754.
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
}
impl BinOp {
    pub fn is_comparison(self) -> bool {
        matches!(
            self,
            BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge
        )
    }
}

/// Call argument: by value, or a borrow of a place (method receivers).
#[derive(Debug, Clone, PartialEq)]
pub enum Arg {
    Value(Operand),
    /// Borrow of a place; `true` for an exclusive (mutable) borrow.
    Ref(Place, bool),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Rvalue {
    Platform(PlatformOp, Vec<Arg>, Type),
    Use(Operand),
    Unary(UnOp, Operand),
    Binary(BinOp, Operand, Operand),
    Call(usize, Vec<Arg>),
    /// Struct value, fields in declaration order.
    Struct(usize, Vec<Operand>),
    /// Enum value: enum id, variant (= discriminant), payload.
    Variant(usize, usize, Vec<Operand>),
    /// Copies (Copy types) or moves the value stored at a place.
    Read(Place),
    /// Borrows a place (result type `VarTy::Ref`).
    Ref(Place),
    Loan(Place, bool, Type),
    FieldLoan(Place),
    /// Discriminant (variant index) of the enum stored at a place, as Int.
    Discriminant(Place),
    /// Compares the Text stored at a place with a literal.
    TextEq(Place, String),
    /// Empty owned Text with the given byte capacity hint.
    TextBuffer(usize),
    /// Opens region `id`: an empty region owning no storage yet.
    RegionNew(usize),
    /// A new task state for the future type `index`: a zeroed block whose
    /// `resume` field is 0 (nothing has run yet). The result is the owned
    /// handle; dropping it releases the state.
    FutureNew(usize),
    /// The task state behind the future handle stored at the place, as an
    /// exclusive reference to its state struct.
    FutureState(Place),
    /// Polls the future at `place` using dynamic dispatch on its `kind` field.
    /// Returns 0 for Pending, 1 for Ready.
    FuturePoll(Place),
    /// Moves the future of the operand into the cooperative scheduler as an
    /// independent task of the given future type. The result is the owned
    /// `TaskHandle` of that task.
    TaskSpawn(Operand, usize),
    /// `1` when the task of the handle at the place already produced its
    /// result, `0` otherwise. In the `0` case it registers the running task as
    /// the one waiting for it, so finishing the other task wakes this one.
    TaskReady(Place),
    /// Register a List of owned tasks once, returning the number still pending.
    GroupRegister(Place),
    /// Read the pending count of the running task after resumption.
    GroupPending,
    CheckSleep(Operand),
    TimerStart(Operand),
    TimerPending,
    /// The task state of the task of the handle at the place, as an exclusive
    /// reference to its state struct (to take its result).
    TaskState(Place),
    /// Allocates `n` zeroed, 8-aligned bytes in the region at `place`; the
    /// result is a `Bytes` view valid while the region lives.
    RegionBytes(Place, Operand),
    RegionList(Place, usize),
    /// Length in bytes of the buffer at `place`.
    BytesLen(Place),
    /// Byte `i` of the buffer at `place` as Int; panics when out of bounds.
    BytesGet(Place, Operand),
    /// Array value of the given array type from elements in order.
    ArrayLit(Type, Vec<Operand>),
    /// New list of the given type owning the elements, in order
    /// (capacity = length).
    ListLit(Type, Vec<Operand>),
    /// Number of elements of the array, slice or list at the place.
    Len(Place),
    /// Capacity of the list at the place.
    Cap(Place),
    /// Removes the last element of a non-empty list and returns it (the list
    /// no longer owns it). Only emitted after checking the length.
    ListTakeLast(Place),
    /// Removes the last element of a list and returns Option<T> (None if empty, Some(item) if not).
    ListPop(Place, Type),
    /// Explicit numeric conversion to the target primitive type.
    Convert(Operand, Type),
}

#[derive(Debug, Clone, PartialEq)]
pub enum InstKind {
    Assign(VarId, Rvalue),
    /// Stores into a projected place (`x.campo = v`).
    Store(Place, Operand),
    /// Formats a value (Int/Float/Bool/Text) at the end of a Text variable.
    Append(VarId, Arg),
    /// Writes a value and a newline to standard output.
    Print(Arg),
    /// `buffer[i] = v` on the buffer at `place`; panics when `i` is out of
    /// bounds or `v` is not in 0..=255.
    BytesSet(Place, Operand, Operand),
    /// Appends the (moved) value to the list at the place, growing it.
    ListPush(Place, Operand),
    /// Ensures room for `n` more elements in the list at the place.
    ListReserve(Place, Operand),
    /// Writes the zero bit pattern over the place without dropping what was
    /// there: the place stops owning it (used by the async lowering after a
    /// value is moved out of a task state). Zero owns nothing for every type.
    Clear(Place),
    /// Notifies the current task: it is ready to be polled again.
    Wake,
    /// Runs the cooperative scheduler until no task is ready: polls the ready
    /// queue, releases cancelled tasks and reports a deadlock if tasks stay
    /// suspended with no possible notification. Never a busy loop.
    RunTasks,
    /// Runs the destructor of an owned variable (frees what it owns). With a
    /// flag, only when the Bool flag variable is true. Inserted by lowering at
    /// scope exits and resolved by `drops::elaborate`; never by a backend.
    Drop(VarId, Option<VarId>),
    /// Drop one owning field subtree; inserted by aggregate drop elaboration.
    DropField(Place, Option<VarId>),
    /// Ownership of the variable's contents was transferred piecewise (match
    /// bindings or a field moved out of a temporary): it no longer owns
    /// anything and must not be dropped. No runtime effect.
    Moved(VarId),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Inst {
    pub kind: InstKind,
    pub span: Span,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Terminator {
    Jump(BlockId),
    /// Condition (Bool), then-block, else-block.
    Branch(Operand, BlockId, BlockId),
    Return(Operand),
    ReturnRef(VarId, Span),
    /// Return Pending. The continuation runs in a new poll frame.
    Suspend(BlockId),
    /// Control never reaches here (after an exhaustive match).
    Unreachable,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Block {
    pub insts: Vec<Inst>,
    /// `None` only while building; the verifier rejects it.
    pub term: Option<Terminator>,
}

#[derive(Debug, Clone)]
pub struct Func {
    pub name: String,
    /// Parameter variables in order; a method receiver comes first as a `Ref`.
    pub params: Vec<VarId>,
    pub vars: Vec<VarTy>,
    pub result: Type,
    pub borrow_return: Option<lir::BorrowReturn>,
    pub view_return: Option<lir::ViewReturn>,
    /// `blocks[0]` is the entry block.
    pub blocks: Vec<Block>,
}

/// The state machine of one async function.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FutureInfo {
    /// What the async function returns.
    pub result: Type,
    /// Struct holding the task state: field 0 is `resume`, field 1 the result.
    pub state: usize,
    /// `poll(state: &mut State) -> Int`: `1` ready, `0` pending.
    pub poll: usize,
    /// `drop(state: &mut State)`: releases whatever the state still owns.
    pub drop: usize,
    /// Tagged owner slots in the task state.
    pub owned_slots: Vec<OwnedSlot>,
    pub factory: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OwnedSlot {
    pub field: usize,
    pub tag: usize,
    /// Set by the future constructor, before the first poll.
    pub parameter: bool,
}

/// Entry of the initial poll body, after dispatch.
pub(crate) const ASYNC_BODY_ENTRY: BlockId = 1;

/// Field of the future type index (kind) inside a task state.
pub const KIND_FIELD: usize = 0;
/// Field of the resume point inside a task state.
pub const RESUME_FIELD: usize = 1;
/// Field of the result inside a task state.
pub const RESULT_FIELD: usize = 2;
/// `resume` value of a task that already produced its result.
pub const RESUME_DONE: i64 = -1;
/// `poll` results.
pub const POLL_PENDING: i64 = 0;
pub const POLL_READY: i64 = 1;

#[derive(Debug, Clone)]
pub struct Module {
    pub structs: Vec<StructDef>,
    pub enums: Vec<EnumDef>,
    pub arrays: Vec<lir::ArrayDef>,
    pub slices: Vec<Type>,
    pub lists: Vec<Type>,
    pub task_groups: Vec<lir::TaskGroupDef>,
    /// State machine of each future type, indexed like `lir::Program::futures`.
    pub futures: Vec<FutureInfo>,
    pub funcs: Vec<Func>,
    pub main: usize,
}

impl Module {
    /// Element type of an array, slice, list or task group type.
    pub fn elem_of(&self, t: Type) -> Option<Type> {
        match t {
            Type::Array(a) => self.arrays.get(a).map(|d| d.elem),
            Type::Slice(s) => self.slices.get(s).copied(),
            Type::List(l) | Type::RegionList(l, _) => self.lists.get(l).copied(),
            Type::TaskGroup(g) => {
                let elem = self.task_groups.get(g)?.elem;
                let task = self
                    .futures
                    .iter()
                    .position(|f| f.result == elem)
                    .unwrap_or(0);
                Some(Type::Task(task))
            }
            _ => None,
        }
    }
}

// ---------------------------------------------------------------- lowering --

/// A lexical region whose owned variables are dropped when it ends.
struct Frame {
    /// Statement frames hold temporaries; scope frames hold named locals.
    scope: bool,
    vars: Vec<VarId>,
    /// Variables of this scope that a suspension must save in the task state:
    /// `(variable, state field)`. Only values that own nothing are saved; the
    /// rest cannot be live across a suspension (checked by semantic analysis).
    spill: Vec<(VarId, usize)>,
    /// State fields holding the owned locals of this scope that live in the
    /// task state (task handles). They are dropped when the scope ends, not
    /// when the task suspends.
    fields: Vec<usize>,
}

/// State machine being built for the body of an async function.
struct AsyncCtx {
    /// Parameter holding the task state (`&mut State`).
    state: VarId,
    /// State field of each saved local, by LIR local id.
    local_slot: HashMap<usize, usize>,
    /// Counter and limit fields of each `for` over a range, in lowering order.
    for_slots: Vec<(usize, usize)>,
    next_for: usize,
    /// State field holding the future being awaited, by future type.
    await_slot: HashMap<usize, usize>,
    group_slot: HashMap<Type, usize>,
    /// State field holding the task handle being awaited, by future type.
    task_slot: HashMap<(usize, usize), usize>,
    /// State field of each owned local that lives in the task state, by LIR
    /// local id. These fields survive suspensions.
    state_local: HashMap<usize, (usize, Type)>,
    tags: HashMap<usize, usize>,
    /// Block that continues each suspension point (`resume` = index + 1).
    resumes: Vec<BlockId>,
}

struct Builder<'a> {
    vars: Vec<VarTy>,
    blocks: Vec<Block>,
    current: BlockId,
    locals: HashMap<usize, VarId>,
    /// (continue target, break target, frame depth at loop entry).
    loops: Vec<(BlockId, BlockId, usize)>,
    frames: Vec<Frame>,
    by_value: &'a HashSet<usize>,
    owned: &'a crate::drops::Ownership,
    program: &'a lir::Program,
    futures: &'a [FutureInfo],
    /// Present while lowering the body of an async function.
    async_ctx: Option<AsyncCtx>,
    span: Span,
}

impl Builder<'_> {
    fn elem_of(&self, t: Type) -> Option<Type> {
        match t {
            Type::Array(i) => Some(self.program.arrays[i].elem),
            Type::Slice(i) => Some(self.program.slices[i]),
            Type::List(i) | Type::RegionList(i, _) => Some(self.program.lists[i]),
            Type::TaskGroup(g) => {
                let elem = self.program.task_groups.get(g)?.elem;
                let task = self
                    .futures
                    .iter()
                    .position(|f| f.result == elem)
                    .unwrap_or(0);
                Some(Type::Task(task))
            }
            _ => None,
        }
    }
    fn var(&mut self, ty: VarTy) -> VarId {
        self.vars.push(ty);
        self.vars.len() - 1
    }
    fn block(&mut self) -> BlockId {
        self.blocks.push(Block::default());
        self.blocks.len() - 1
    }
    fn emit(&mut self, kind: InstKind) {
        let span = self.span;
        self.blocks[self.current].insts.push(Inst { kind, span });
    }
    /// Ends the current block. Code that follows goes to a fresh block with no
    /// predecessors (unreachable), which keeps lowering uniform.
    fn terminate(&mut self, term: Terminator) {
        if self.blocks[self.current].term.is_none() {
            self.blocks[self.current].term = Some(term);
        }
    }
    fn switch_to(&mut self, block: BlockId) {
        self.current = block;
    }
    fn terminate_and_continue(&mut self, term: Terminator) {
        self.terminate(term);
        let dead = self.block();
        self.switch_to(dead);
    }
    fn assign(&mut self, ty: VarTy, rv: Rvalue) -> VarId {
        let v = self.var(ty);
        self.emit(InstKind::Assign(v, rv));
        self.own_temp(v);
        v
    }
    /// Place of a field of the task state (only inside an async body).
    fn state_field(&self, field: usize) -> Place {
        let ctx = self
            .async_ctx
            .as_ref()
            .expect("campo de estado fuera de una función async");
        Place {
            var: ctx.state,
            proj: vec![Proj::Field(field)],
        }
    }
    /// Saves every live saved local in the task state and returns the pairs to
    /// restore when the task resumes.
    fn spill(&mut self) -> Vec<(VarId, usize)> {
        let pairs: Vec<(VarId, usize)> = self
            .frames
            .iter()
            .flat_map(|f| f.spill.iter().copied())
            .collect();
        for (var, field) in &pairs {
            let place = self.state_field(*field);
            self.emit(InstKind::Store(place, Operand::Var(*var)));
        }
        pairs
    }
    fn reload(&mut self, pairs: &[(VarId, usize)]) {
        for (var, field) in pairs {
            let place = self.state_field(*field);
            self.emit(InstKind::Assign(*var, Rvalue::Read(place)));
        }
    }
    /// Registers a local that must survive suspensions, if it can. Like the
    /// drops of the local, the entry belongs to the innermost scope: it must
    /// outlive the statement that created it and disappear with the scope.
    fn save_local(&mut self, id: usize, var: VarId, ty: Type) {
        if !spillable(ty) {
            return;
        }
        let field = self
            .async_ctx
            .as_ref()
            .and_then(|ctx| ctx.local_slot.get(&id).copied());
        if let Some(field) = field
            && let Some(frame) = self.frames.iter_mut().rev().find(|f| f.scope)
        {
            frame.spill.push((var, field));
        }
    }
    /// Registers a variable of the innermost frame (the counter, limit and
    /// variable of a `for` over a range, which only exist inside the loop).
    fn save_loop_var(&mut self, var: VarId, field: usize) {
        if let Some(frame) = self.frames.last_mut() {
            frame.spill.push((var, field));
        }
    }
    /// State field of a local that lives in the task state, if `id` is one.
    fn state_local(&self, id: usize) -> Option<(usize, Type)> {
        self.async_ctx
            .as_ref()
            .and_then(|c| c.state_local.get(&id).copied())
    }
    /// Tagged locals store their value in the Full payload.
    fn state_local_place(&self, field: usize) -> Place {
        let mut p = self.state_field(field);
        if self.async_ctx.as_ref().unwrap().tags.contains_key(&field) {
            p.proj.push(Proj::Payload(1, 0));
        }
        p
    }

    fn read_value_place(&mut self, place: Place, ty: Type) -> VarId {
        let out = self.var(VarTy::Value(ty));
        self.read_place_into(out, place, ty);
        self.own_temp(out);
        out
    }

    fn read_place_into(&mut self, out: VarId, place: Place, ty: Type) {
        let cleared = self.async_ctx.as_ref().and_then(|ctx| {
            if !ty.is_move() || place.var != ctx.state {
                return None;
            }
            let [Proj::Field(field), Proj::Payload(1, 0), rest @ ..] = &place.proj[..] else {
                return None;
            };
            if !ctx.tags.contains_key(field) {
                return None;
            }
            // A whole move empties the tag. A partial move zeroes the moved
            // subtree so it owns nothing when the enclosing value is dropped.
            Some(if rest.is_empty() {
                self.state_field(*field)
            } else {
                place.clone()
            })
        });
        self.emit(InstKind::Assign(out, Rvalue::Read(place)));
        if let Some(cleared) = cleared {
            self.emit(InstKind::Clear(cleared));
        }
    }

    fn take_state_local(&mut self, field: usize, ty: Type) -> Operand {
        let place = self.state_local_place(field);
        let var = self.read_value_place(place, ty);
        if matches!(ty, Type::Task(_)) {
            self.emit(InstKind::Clear(self.state_field(field)));
        }
        Operand::Var(var)
    }

    fn store_state_local(&mut self, field: usize, op: Operand) {
        let tag = self
            .async_ctx
            .as_ref()
            .and_then(|ctx| ctx.tags.get(&field))
            .copied();
        let op = match tag {
            Some(tag) => {
                Operand::Var(self.assign(VarTy::Value(Type::Enum(tag)), full_slot(tag, op)))
            }
            None => op,
        };
        self.emit(InstKind::Store(self.state_field(field), op));
    }
    /// Registers the drop of a persistent field at the end of its scope.
    fn bind_state_local(&mut self, id: usize, field: usize, ty: Type, op: Operand) {
        self.store_state_local(field, op);
        if let Some(frame) = self.frames.iter_mut().rev().find(|f| f.scope) {
            frame.fields.push(field);
        }
        if let Some(ctx) = self.async_ctx.as_mut() {
            ctx.state_local.insert(id, (field, ty));
        }
    }
    /// Numbers a suspension point and records where it continues.
    fn resume_point(&mut self, block: BlockId) -> i64 {
        let ctx = self
            .async_ctx
            .as_mut()
            .expect("suspensión fuera de una función async");
        ctx.resumes.push(block);
        ctx.resumes.len() as i64
    }
    /// `await future`: polls it, suspending this task while it is pending;
    /// when it is ready, moves its result out and releases its task state.
    fn await_future(&mut self, future: &lir::Value) -> Operand {
        let index = match future.ty {
            Type::Future(index) => index,
            Type::Task(_) => {
                let [result] = self.await_tasks([future]);
                return result;
            }
            _ => unreachable!("await sobre un valor que no es future"),
        };
        let info = self.futures[index].clone();
        let slot = self
            .async_ctx
            .as_ref()
            .and_then(|c| c.await_slot.get(&index).copied())
            .expect("await sin campo de estado");
        let op = self.value(future);
        let span = self.span;
        let slot_place = self.state_field(slot);
        self.emit(InstKind::Store(slot_place, op));
        let (poll_b, susp_b, resume_b, ready_b) =
            (self.block(), self.block(), self.block(), self.block());
        self.terminate(Terminator::Jump(poll_b));

        self.switch_to(poll_b);
        let slot_place = self.state_field(slot);
        let status = self.assign(VarTy::Value(Type::Int), Rvalue::FuturePoll(slot_place));
        let ready = self.assign(
            VarTy::Value(Type::Bool),
            Rvalue::Binary(
                BinOp::Eq,
                Operand::Var(status),
                Operand::Const(Const::Int(POLL_READY)),
            ),
        );
        self.terminate(Terminator::Branch(Operand::Var(ready), ready_b, susp_b));

        // Pending: save the live locals and return to the executor.
        self.switch_to(susp_b);
        let saved = self.spill();
        self.drop_frames_keeping_state(0);
        let point = self.resume_point(resume_b);
        let resume_place = self.state_field(RESUME_FIELD);
        self.emit(InstKind::Store(
            resume_place,
            Operand::Const(Const::Int(point)),
        ));
        self.terminate(Terminator::Suspend(resume_b));

        // Resumed: restore the locals and poll again.
        self.switch_to(resume_b);
        self.reload(&saved);
        self.terminate(Terminator::Jump(poll_b));

        // Ready: take the result, then release the finished task state.
        self.switch_to(ready_b);
        self.span = span;
        let slot_place = self.state_field(slot);
        let state = self.assign(
            VarTy::Ref(Type::Struct(info.state)),
            Rvalue::FutureState(slot_place),
        );
        let result_place = Place {
            var: state,
            proj: vec![Proj::Field(RESULT_FIELD)],
        };
        let out = self.assign(
            VarTy::Value(info.result),
            Rvalue::Read(result_place.clone()),
        );
        self.emit(InstKind::Clear(result_place));
        let slot_place = self.state_field(slot);
        self.emit(InstKind::DropField(slot_place.clone(), None));
        self.emit(InstKind::Clear(slot_place));
        Operand::Var(out)
    }
    /// Waits for a set of owned handles. Probe every child before branching
    /// so each pending child can notify the same parent.
    fn await_tasks<const N: usize>(&mut self, handles: [&lir::Value; N]) -> [Operand; N] {
        let slots: [(usize, usize); N] = std::array::from_fn(|position| {
            let handle = handles[position];
            let Type::Task(index) = handle.ty else {
                unreachable!("await_tasks solo recibe TaskHandle")
            };
            let slot = self.async_ctx.as_ref().unwrap().task_slot[&(index, position)];
            let op = self.value(handle);
            self.emit(InstKind::Store(self.state_field(slot), op));
            (slot, index)
        });
        let span = self.span;
        let (check_b, susp_b, resume_b, ready_b) =
            (self.block(), self.block(), self.block(), self.block());
        self.terminate(Terminator::Jump(check_b));

        self.switch_to(check_b);
        let statuses = slots.map(|(slot, _)| {
            self.assign(
                VarTy::Value(Type::Int),
                Rvalue::TaskReady(self.state_field(slot)),
            )
        });
        for (position, status) in statuses.into_iter().enumerate() {
            let ready = self.assign(
                VarTy::Value(Type::Bool),
                Rvalue::Binary(
                    BinOp::Eq,
                    Operand::Var(status),
                    Operand::Const(Const::Int(POLL_READY)),
                ),
            );
            let next = if position + 1 == N {
                ready_b
            } else {
                self.block()
            };
            self.terminate(Terminator::Branch(Operand::Var(ready), next, susp_b));
            self.switch_to(next);
        }

        // Pending: one or more children registered us as their waiter.
        // The scheduler may run other tasks while the handles stay owned.
        self.switch_to(susp_b);
        let saved = self.spill();
        self.drop_frames_keeping_state(0);
        let point = self.resume_point(resume_b);
        let resume_place = self.state_field(RESUME_FIELD);
        self.emit(InstKind::Store(
            resume_place,
            Operand::Const(Const::Int(point)),
        ));
        self.terminate(Terminator::Suspend(resume_b));

        self.switch_to(resume_b);
        self.reload(&saved);
        self.terminate(Terminator::Jump(check_b));

        // Finished: take each result in argument order and release its task.
        self.switch_to(ready_b);
        self.span = span;
        slots.map(|(slot, index)| self.take_task_result(self.state_field(slot), index))
    }

    fn take_task_result(&mut self, slot_place: Place, index: usize) -> Operand {
        let out = self.move_task_result(slot_place.clone(), index);
        self.emit(InstKind::DropField(slot_place.clone(), None));
        self.emit(InstKind::Clear(slot_place));
        out
    }

    fn move_task_result(&mut self, handle: Place, index: usize) -> Operand {
        let info = &self.futures[index];
        let state = self.assign(
            VarTy::Ref(Type::Struct(info.state)),
            Rvalue::TaskState(handle),
        );
        let result_place = Place {
            var: state,
            proj: vec![Proj::Field(RESULT_FIELD)],
        };
        let out = self.assign(
            VarTy::Value(info.result),
            Rvalue::Read(result_place.clone()),
        );
        self.emit(InstKind::Clear(result_place));
        Operand::Var(out)
    }
    fn await_group(&mut self, group: &lir::Value, result: Type) -> Operand {
        let task = match group.ty {
            Type::List(list) => {
                let Type::Task(task) = self.program.lists[list] else {
                    unreachable!("grupo sin TaskHandle")
                };
                task
            }
            Type::TaskGroup(gid) => {
                let elem = self.program.task_groups[gid].elem;
                self.futures
                    .iter()
                    .position(|f| f.result == elem)
                    .unwrap_or(0)
            }
            _ => unreachable!("joinAll requiere List o TaskGroup"),
        };
        let slot = self.async_ctx.as_ref().unwrap().group_slot[&group.ty];
        let handles = self.value(group);
        self.store_state_local(slot, handles);
        let place = self.state_local_place(slot);

        let (check, suspend, resume, ready) =
            (self.block(), self.block(), self.block(), self.block());
        let pending = self.var(VarTy::Value(Type::Int));
        self.emit(InstKind::Assign(pending, Rvalue::GroupRegister(place)));
        self.terminate(Terminator::Jump(check));
        self.switch_to(check);
        let done = self.assign(
            VarTy::Value(Type::Bool),
            Rvalue::Binary(
                BinOp::Eq,
                Operand::Var(pending),
                Operand::Const(Const::Int(0)),
            ),
        );
        self.terminate(Terminator::Branch(Operand::Var(done), ready, suspend));

        self.switch_to(suspend);
        let saved = self.spill();
        self.drop_frames_keeping_state(0);
        let point = self.resume_point(resume);
        self.emit(InstKind::Store(
            self.state_field(RESUME_FIELD),
            Operand::Const(Const::Int(point)),
        ));
        self.terminate(Terminator::Suspend(resume));
        self.switch_to(resume);
        self.reload(&saved);
        self.emit(InstKind::Assign(pending, Rvalue::GroupPending));
        self.terminate(Terminator::Jump(check));

        // No result has moved while waiting. Allocate the output once and
        // commit each element to its initialized prefix in argument order.
        self.switch_to(ready);
        let handles = self.read_value_place(self.state_local_place(slot), group.ty);
        let place = Place {
            var: handles,
            proj: Vec::new(),
        };
        let len = self.assign(VarTy::Value(Type::Int), Rvalue::Len(place.clone()));
        let out = self.assign(VarTy::Value(result), Rvalue::ListLit(result, Vec::new()));
        let output = Place {
            var: out,
            proj: Vec::new(),
        };
        self.emit(InstKind::ListReserve(output.clone(), Operand::Var(len)));
        let index = self.assign(
            VarTy::Value(Type::Int),
            Rvalue::Use(Operand::Const(Const::Int(0))),
        );
        let (head, take, end) = (self.block(), self.block(), self.block());
        self.terminate(Terminator::Jump(head));
        self.switch_to(head);
        let more = self.assign(
            VarTy::Value(Type::Bool),
            Rvalue::Binary(BinOp::Lt, Operand::Var(index), Operand::Var(len)),
        );
        self.terminate(Terminator::Branch(Operand::Var(more), take, end));
        self.switch_to(take);
        let mut handle = place.clone();
        handle.proj.push(Proj::Index(index));
        let item = self.move_task_result(handle, task);
        self.emit(InstKind::ListPush(output, item));
        self.emit(InstKind::Assign(
            index,
            Rvalue::Binary(
                BinOp::Add,
                Operand::Var(index),
                Operand::Const(Const::Int(1)),
            ),
        ));
        self.terminate(Terminator::Jump(head));
        self.switch_to(end);
        self.emit(InstKind::Drop(handles, None));
        Operand::Var(out)
    }

    /// Suspension with nothing to wait for: the task is notified at once.
    fn yield_point(&mut self) {
        let resume_b = self.block();
        let saved = self.spill();
        self.drop_frames_keeping_state(0);
        let point = self.resume_point(resume_b);
        let resume_place = self.state_field(RESUME_FIELD);
        self.emit(InstKind::Store(
            resume_place,
            Operand::Const(Const::Int(point)),
        ));
        self.emit(InstKind::Wake);
        self.terminate(Terminator::Suspend(resume_b));
        self.switch_to(resume_b);
        self.reload(&saved);
    }
    fn sleep_point(&mut self, duration: &lir::Value) {
        let duration = self.value(duration);
        let status = self.var(VarTy::Value(Type::Int));
        self.emit(InstKind::Assign(status, Rvalue::TimerStart(duration)));
        let (check, suspend, resume, ready) =
            (self.block(), self.block(), self.block(), self.block());
        self.terminate(Terminator::Jump(check));
        self.switch_to(check);
        let waiting = self.assign(
            VarTy::Value(Type::Bool),
            Rvalue::Binary(
                BinOp::Ne,
                Operand::Var(status),
                Operand::Const(Const::Int(0)),
            ),
        );
        self.terminate(Terminator::Branch(Operand::Var(waiting), suspend, ready));

        self.switch_to(suspend);
        let saved = self.spill();
        self.drop_frames_keeping_state(0);
        let point = self.resume_point(resume);
        self.emit(InstKind::Store(
            self.state_field(RESUME_FIELD),
            Operand::Const(Const::Int(point)),
        ));
        self.terminate(Terminator::Suspend(resume));
        self.switch_to(resume);
        self.reload(&saved);
        self.emit(InstKind::Assign(status, Rvalue::TimerPending));
        self.terminate(Terminator::Jump(check));
        self.switch_to(ready);
    }

    /// Stores the result of the task, marks it finished and returns Ready.
    fn complete(&mut self, op: Operand) {
        let result_place = self.state_field(RESULT_FIELD);
        self.emit(InstKind::Store(result_place, op));
        let resume_place = self.state_field(RESUME_FIELD);
        self.emit(InstKind::Store(
            resume_place,
            Operand::Const(Const::Int(RESUME_DONE)),
        ));
        self.drop_frames(0);
        self.terminate_and_continue(Terminator::Return(Operand::Const(Const::Int(POLL_READY))));
    }
    fn owns(&self, v: VarId) -> bool {
        matches!(self.vars[v], VarTy::Value(t) if self.owned.needs_drop(t))
    }
    /// Registers an owned temporary in the innermost frame.
    fn own_temp(&mut self, v: VarId) {
        if self.owns(v)
            && let Some(f) = self.frames.last_mut()
        {
            f.vars.push(v);
        }
    }
    /// Registers an owned named local in the innermost scope frame.
    fn own_local(&mut self, v: VarId) {
        if self.owns(v)
            && let Some(f) = self.frames.iter_mut().rev().find(|f| f.scope)
        {
            f.vars.push(v);
        }
    }
    fn push_frame(&mut self, scope: bool) {
        self.frames.push(Frame {
            scope,
            vars: Vec::new(),
            spill: Vec::new(),
            fields: Vec::new(),
        });
    }
    /// Emits drops (innermost first, reverse declaration order) for every frame
    /// at index `depth` or above, without leaving them (return/break/continue).
    fn drop_frames(&mut self, depth: usize) {
        self.drop_frames_keeping_state(depth);
        // Locals kept in the task state (task handles): leaving the scope
        // destroys them, which cancels their tasks. The drop is
        // unconditional because a field that was moved out holds zero, and
        // zero owns nothing.
        let fields: Vec<usize> = self.frames[depth..]
            .iter()
            .rev()
            .flat_map(|f| f.fields.iter().rev().copied())
            .collect();
        for field in fields {
            let place = self.state_field(field);
            self.emit(InstKind::DropField(place.clone(), None));
            self.emit(InstKind::Clear(place));
        }
    }
    /// Drops what the frames own in the frame of the `poll` call, leaving what
    /// lives in the task state alone: that is what a suspension releases.
    fn drop_frames_keeping_state(&mut self, depth: usize) {
        let vars: Vec<VarId> = self.frames[depth..]
            .iter()
            .rev()
            .flat_map(|f| f.vars.iter().rev().copied())
            .collect();
        for v in vars {
            self.emit(InstKind::Drop(v, None));
        }
    }
    /// Normal exit of the innermost frame.
    fn pop_frame(&mut self) {
        let depth = self.frames.len() - 1;
        self.drop_frames(depth);
        self.frames.pop();
    }
    /// Lowers a list of instructions as a lexical scope.
    fn scope(&mut self, body: &[lir::Instruction]) {
        self.push_frame(true);
        self.instructions(body);
        self.pop_frame();
    }
    fn local(&self, id: usize) -> VarId {
        self.locals[&id]
    }
    fn place_of(&mut self, v: &lir::Value) -> Option<Place> {
        match &v.kind {
            ValueKind::Local(id) => Some(match self.state_local(*id) {
                Some((field, _)) => self.state_local_place(field),
                None => Place {
                    var: self.local(*id),
                    proj: Vec::new(),
                },
            }),
            ValueKind::Field(base, i) => {
                let mut p = self.place_of(base)?;
                p.proj.push(Proj::Field(*i));
                Some(p)
            }
            ValueKind::SharedField(base, i) => {
                let mut field = self.place_or_temp(base);
                field.proj.push(Proj::Field(*i));
                self.span = v.span;
                let var = self.assign(VarTy::Ref(v.ty), Rvalue::FieldLoan(field));
                Some(Place {
                    var,
                    proj: Vec::new(),
                })
            }
            // An element is always a place: a temporary collection is first
            // stored in a variable owned by the current statement.
            ValueKind::Index(base, index) => {
                let mut p = self.place_or_temp(base);
                let i = self.value(index);
                let i = match i {
                    Operand::Var(v) => v,
                    other => self.assign(VarTy::Value(Type::Int), Rvalue::Use(other)),
                };
                p.proj.push(Proj::Index(i));
                Some(p)
            }
            _ => None,
        }
    }
    /// The place denoted by `v`, or a temporary holding its value.
    fn place_or_temp(&mut self, v: &lir::Value) -> Place {
        match self.place_of(v) {
            Some(p) => p,
            None => {
                let op = self.value(v);
                let var = self.assign(VarTy::Value(v.ty), Rvalue::Use(op));
                Place {
                    var,
                    proj: Vec::new(),
                }
            }
        }
    }
    fn elem_type(&self, t: Type) -> Type {
        match t {
            Type::Array(a) => self.program.arrays[a].elem,
            Type::Slice(s) => self.program.slices[s],
            Type::List(l) | Type::RegionList(l, _) => self.program.lists[l],
            other => unreachable!("not a collection: {other:?}"),
        }
    }
    fn lists_elem(&self, t: Type) -> Type {
        self.elem_type(t)
    }
    fn lir_place(&self, p: &lir::Place) -> Place {
        let mut place = match self.state_local(p.root) {
            Some((field, _)) => self.state_local_place(field),
            None => Place {
                var: self.local(p.root),
                proj: Vec::new(),
            },
        };
        place.proj.extend(p.fields.iter().copied().map(Proj::Field));
        place
    }
    /// Argument for a non-consuming use (print, interpolation): borrow owned
    /// places instead of moving them.
    fn borrow_arg(&mut self, v: &lir::Value) -> Arg {
        match self.place_of(v) {
            Some(p) if v.ty.is_move() => Arg::Ref(p, false),
            _ => Arg::Value(self.value(v)),
        }
    }
    fn call_args(&mut self, args: &[lir::Value], borrows: bool) -> Vec<Arg> {
        args.iter()
            .map(|arg| match &arg.kind {
                ValueKind::Borrow(place, exclusive) => Arg::Ref(self.lir_place(place), *exclusive),
                _ => {
                    let value = self.value(arg);
                    let value = if borrows && matches!(value, Operand::Var(_)) {
                        Operand::Var(self.assign(VarTy::Value(arg.ty), Rvalue::Use(value)))
                    } else {
                        value
                    };
                    Arg::Value(value)
                }
            })
            .collect()
    }
    fn call_value(&mut self, f: usize, mut args: Vec<Arg>, v: &lir::Value) -> Operand {
        let ty = if self.program.functions[f].borrow_return.is_some() {
            VarTy::Ref(v.ty)
        } else {
            VarTy::Value(v.ty)
        };
        self.span = v.span;
        if self.program.functions[f].name == lir::SLEEP_MS
            && let [Arg::Value(ms)] = args.as_mut_slice()
        {
            *ms =
                Operand::Var(self.assign(VarTy::Value(Type::Int), Rvalue::CheckSleep(ms.clone())));
        }
        Operand::Var(self.assign(ty, Rvalue::Call(f, args)))
    }
    fn loan_value(&mut self, v: &lir::Value, mode: Receiver, ty: Type) -> VarId {
        if matches!(v.kind, ValueKind::Call(..) | ValueKind::MethodCall(..)) {
            let Operand::Var(var) = self.value(v) else {
                unreachable!()
            };
            return var;
        }
        let place = self.place_of(v).expect("local reference origin is a place");
        self.span = v.span;
        self.assign(
            VarTy::Ref(ty),
            Rvalue::Loan(place, mode == Receiver::Exclusive, ty),
        )
    }
    fn value(&mut self, v: &lir::Value) -> Operand {
        self.span = v.span;
        match &v.kind {
            ValueKind::Platform(op, values) => {
                let args = values
                    .iter()
                    .map(|value| {
                        if value.ty != Type::Text
                            && !(*op == PlatformOp::WriteBytes && matches!(value.ty, Type::List(_)))
                        {
                            return Arg::Value(self.value(value));
                        }
                        let place = self.place_or_temp(value);
                        self.span = value.span;
                        // Platform operations also borrow List<Int> for writeBytes.
                        // Preserve the actual referent type instead of constructing
                        // an invalid `Loan(List<Int>, Text)` in ELE-LIR.
                        let var =
                            self.assign(VarTy::Ref(value.ty), Rvalue::Loan(place, false, value.ty));
                        Arg::Ref(
                            Place {
                                var,
                                proj: Vec::new(),
                            },
                            false,
                        )
                    })
                    .collect();
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::Platform(*op, args, v.ty)))
            }
            ValueKind::Int(n) => Operand::Const(Const::Int(*n)),
            ValueKind::Float(f) => {
                if v.ty == Type::F32 {
                    Operand::Const(Const::F32((*f as f32).to_bits()))
                } else {
                    Operand::Const(Const::Float(f.to_bits()))
                }
            }
            ValueKind::Convert(inner, target) => {
                let op = self.value(inner);
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Value(*target), Rvalue::Convert(op, *target)))
            }
            ValueKind::Bool(b) => Operand::Const(Const::Bool(*b)),
            ValueKind::Text(s) => Operand::Const(Const::Text(s.clone())),
            ValueKind::Unit => Operand::Const(Const::Unit),
            ValueKind::Local(id) => {
                if let Some((field, ty)) = self.state_local(*id) {
                    return self.take_state_local(field, ty);
                }
                let var = self.local(*id);
                match self.vars[var] {
                    VarTy::Value(_) => Operand::Var(var),
                    VarTy::Ref(t) => {
                        if matches!(v.ty, Type::SharedField(_) | Type::MutField(_)) {
                            Operand::Var(var)
                        } else {
                            Operand::Var(self.assign(
                                VarTy::Value(t),
                                Rvalue::Read(Place {
                                    var,
                                    proj: Vec::new(),
                                }),
                            ))
                        }
                    }
                }
            }
            ValueKind::Interpolate(parts) => {
                // Capacity hint: literal bytes plus the longest decimal form
                // of Int (20) and Bool (5) parts; Text parts are unknown.
                let capacity = parts
                    .iter()
                    .map(|p| match (&p.kind, p.ty) {
                        (ValueKind::Text(s), _) => s.len(),
                        (_, Type::Int) => 20,
                        (_, Type::Float) => 24,
                        (_, Type::F32) => 16,
                        (_, Type::Bool) => 5,
                        _ => 0,
                    })
                    .sum();
                let buffer = self.assign(VarTy::Value(Type::Text), Rvalue::TextBuffer(capacity));
                for part in parts {
                    if matches!(&part.kind, ValueKind::Text(s) if s.is_empty()) {
                        continue;
                    }
                    // Each part is formatted before the next is evaluated.
                    let arg = self.borrow_arg(part);
                    self.span = part.span;
                    self.emit(InstKind::Append(buffer, arg));
                }
                Operand::Var(buffer)
            }
            ValueKind::Call(f, args) => {
                let borrows = args.iter().any(|a| matches!(a.kind, ValueKind::Borrow(..)));
                let args = self.call_args(args, borrows);
                self.call_value(*f, args, v)
            }
            ValueKind::ArrayLit(items) | ValueKind::ListLit(items) => {
                let ops: Vec<Operand> = items.iter().map(|x| self.value(x)).collect();
                self.span = v.span;
                let rv = if matches!(v.kind, ValueKind::ArrayLit(_)) {
                    Rvalue::ArrayLit(v.ty, ops)
                } else {
                    Rvalue::ListLit(v.ty, ops)
                };
                Operand::Var(self.assign(VarTy::Value(v.ty), rv))
            }
            ValueKind::Index(..) => {
                // Only Copy elements are read by value (sema/ownership).
                let place = self.place_of(v).expect("element place");
                self.span = v.span;
                let elem = match self.vars[place.var] {
                    VarTy::Value(t) | VarTy::Ref(t) => self.elem_of(t),
                };
                if let Some(Type::SharedField(target) | Type::MutField(target)) = elem {
                    let rvar = self.assign(VarTy::Ref(target.referent()), Rvalue::FieldLoan(place));
                    if matches!(v.ty, Type::SharedField(_) | Type::MutField(_)) {
                        Operand::Var(rvar)
                    } else {
                        Operand::Var(self.assign(
                            VarTy::Value(target.referent()),
                            Rvalue::Read(Place {
                                var: rvar,
                                proj: Vec::new(),
                            }),
                        ))
                    }
                } else {
                    Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::Read(place)))
                }
            }
            ValueKind::Length(base) | ValueKind::Capacity(base) => {
                let place = self.place_or_temp(base);
                let rv = if matches!(v.kind, ValueKind::Length(_)) {
                    Rvalue::Len(place)
                } else {
                    Rvalue::Cap(place)
                };
                Operand::Var(self.assign(VarTy::Value(Type::Int), rv))
            }
            ValueKind::TextByte(base, index) => {
                let place = self.place_or_temp(base);
                self.span = v.span;
                let var = self.assign(
                    VarTy::Ref(Type::Text),
                    Rvalue::Loan(place, false, Type::Text),
                );
                let index = self.value(index);
                self.span = v.span;
                let receiver = Place {
                    var,
                    proj: Vec::new(),
                };
                Operand::Var(
                    self.assign(VarTy::Value(Type::Int), Rvalue::BytesGet(receiver, index)),
                )
            }
            ValueKind::ListPush(list, item) => {
                let op = self.value(item);
                let place = self.place_of(list).expect("list place");
                self.span = v.span;
                self.emit(InstKind::ListPush(place, op));
                Operand::Const(Const::Unit)
            }
            ValueKind::ListReserve(list, n) => {
                let op = self.value(n);
                let place = self.place_of(list).expect("list place");
                self.span = v.span;
                self.emit(InstKind::ListReserve(place, op));
                Operand::Const(Const::Unit)
            }
            ValueKind::ListPop(list, option, some, none) => {
                // n = len; if n == 0 { None } else { Some(take_last) }
                let place = self.place_of(list).expect("list place");
                let result = self.var(VarTy::Value(v.ty));
                self.own_temp(result);
                let n = self.assign(VarTy::Value(Type::Int), Rvalue::Len(place.clone()));
                let empty = self.assign(
                    VarTy::Value(Type::Bool),
                    Rvalue::Binary(BinOp::Eq, Operand::Var(n), Operand::Const(Const::Int(0))),
                );
                let (none_b, some_b, join) = (self.block(), self.block(), self.block());
                self.terminate(Terminator::Branch(Operand::Var(empty), none_b, some_b));
                self.switch_to(none_b);
                self.emit(InstKind::Assign(
                    result,
                    Rvalue::Variant(*option, *none, Vec::new()),
                ));
                self.terminate(Terminator::Jump(join));
                self.switch_to(some_b);
                let elem = self.lists_elem(list.ty);
                let item = self.var(VarTy::Value(elem));
                self.emit(InstKind::Assign(item, Rvalue::ListTakeLast(place)));
                self.emit(InstKind::Assign(
                    result,
                    Rvalue::Variant(*option, *some, vec![Operand::Var(item)]),
                ));
                self.terminate(Terminator::Jump(join));
                self.switch_to(join);
                Operand::Var(result)
            }
            ValueKind::Await(future) => self.await_future(future),
            ValueKind::JoinAll(group) => self.await_group(group, v.ty),
            ValueKind::Join(handles) => {
                let Type::Struct(pair) = v.ty else {
                    unreachable!("el resultado de join es un struct")
                };
                let results = self.await_tasks([&handles[0], &handles[1]]);
                Operand::Var(
                    self.assign(VarTy::Value(v.ty), Rvalue::Struct(pair, Vec::from(results))),
                )
            }
            // `spawn f(args)`: build the future, then move it into the
            // scheduler. The handle owns the task from now on.
            ValueKind::Spawn(future) => {
                let Type::Future(index) = future.ty else {
                    unreachable!("spawn de un valor que no es future")
                };
                let op = self.value(future);
                self.span = v.span;
                Operand::Var(self.assign(
                    VarTy::Value(Type::Task(index)),
                    Rvalue::TaskSpawn(op, index),
                ))
            }
            ValueKind::RegionNew => {
                let Type::Region(r) = v.ty else {
                    unreachable!("RegionNew has a region type")
                };
                Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::RegionNew(r)))
            }
            ValueKind::RegionList(place) => {
                let Type::RegionList(element, _) = v.ty else {
                    unreachable!()
                };
                let place = self.lir_place(place);
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::RegionList(place, element)))
            }
            ValueKind::RegionBytes(place, size) => {
                let size = self.value(size);
                let place = self.lir_place(place);
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::RegionBytes(place, size)))
            }
            ValueKind::BytesLen(place) => {
                let place = self.lir_place(place);
                Operand::Var(self.assign(VarTy::Value(Type::Int), Rvalue::BytesLen(place)))
            }
            ValueKind::BytesGet(place, index) => {
                let index = self.value(index);
                let place = self.lir_place(place);
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Value(Type::Int), Rvalue::BytesGet(place, index)))
            }
            ValueKind::BytesSet(place, index, byte) => {
                let index = self.value(index);
                let byte = self.value(byte);
                let place = self.lir_place(place);
                self.span = v.span;
                self.emit(InstKind::BytesSet(place, index, byte));
                Operand::Const(Const::Unit)
            }
            ValueKind::Borrow(p, _) => {
                let place = self.lir_place(p);
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Ref(v.ty), Rvalue::Ref(place)))
            }
            ValueKind::MethodCall(f, place, receiver, args) => {
                // Arguments first; the receiver borrow starts at the call.
                let mut lowered = self.call_args(args, true);
                let place = self.lir_place(place);
                lowered.insert(0, Arg::Ref(place, *receiver == Receiver::Exclusive));
                self.call_value(*f, lowered, v)
            }
            ValueKind::TempMethodCall(f, receiver, args) => {
                let r = self.value(receiver);
                let temp = self.assign(VarTy::Value(receiver.ty), Rvalue::Use(r));
                let mut lowered = self.call_args(args, true);
                lowered.insert(
                    0,
                    Arg::Ref(
                        Place {
                            var: temp,
                            proj: Vec::new(),
                        },
                        false,
                    ),
                );
                self.call_value(*f, lowered, v)
            }
            ValueKind::Construct(s, inits) => {
                let mut fields: Vec<(usize, Operand)> =
                    inits.iter().map(|(i, x)| (*i, self.value(x))).collect();
                fields.sort_by_key(|(i, _)| *i);
                let ops = fields.into_iter().map(|(_, o)| o).collect();
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::Struct(*s, ops)))
            }
            ValueKind::Variant(e, variant, payload) => {
                let ops = payload.iter().map(|p| self.value(p)).collect();
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::Variant(*e, *variant, ops)))
            }
            ValueKind::StoredBorrow(source) => {
                let place = self
                    .place_of(source)
                    .expect("stored reference source is a place");
                self.span = v.span;
                let exclusive = matches!(v.ty, Type::MutField(_));
                Operand::Var(self.assign(
                    VarTy::Ref(source.ty),
                    Rvalue::Loan(place, exclusive, source.ty),
                ))
            }
            ValueKind::SharedField(..) => {
                let place = self.place_of(v).expect("shared field is a place");
                Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::Read(place)))
            }
            ValueKind::Field(base, index) => {
                let mut place = match self.place_of(base) {
                    Some(p) => p,
                    None => {
                        let b = self.value(base);
                        let var = self.assign(VarTy::Value(base.ty), Rvalue::Use(b));
                        Place {
                            var,
                            proj: Vec::new(),
                        }
                    }
                };
                place.proj.push(Proj::Field(*index));
                self.span = v.span;
                let out = self.read_value_place(place, v.ty);
                Operand::Var(out)
            }
            ValueKind::Match(scrutinee, arms) => self.match_value(scrutinee, arms, v.ty),
            ValueKind::Print(arg) => {
                let at = arg.span;
                let arg = self.borrow_arg(arg);
                // Reading an element may fail its bounds check: report it.
                self.span = if matches!(arg, Arg::Ref(ref p, _) if p.proj.iter().any(|x| matches!(x, Proj::Index(_))))
                {
                    at
                } else {
                    v.span
                };
                self.emit(InstKind::Print(arg));
                Operand::Const(Const::Unit)
            }
            ValueKind::Unary(op, a) => {
                let a = self.value(a);
                let op = if op == "-" { UnOp::Neg } else { UnOp::Not };
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::Unary(op, a)))
            }
            ValueKind::Binary(op, a, b) if op == "&&" || op == "||" => {
                // Short circuit: the right operand runs only when needed.
                let result = self.var(VarTy::Value(Type::Bool));
                let left = self.value(a);
                let rhs = self.block();
                let short = self.block();
                let join = self.block();
                let (yes, no) = if op == "&&" {
                    (rhs, short)
                } else {
                    (short, rhs)
                };
                self.terminate(Terminator::Branch(left, yes, no));
                self.switch_to(short);
                self.emit(InstKind::Assign(
                    result,
                    Rvalue::Use(Operand::Const(Const::Bool(op == "||"))),
                ));
                self.terminate(Terminator::Jump(join));
                self.switch_to(rhs);
                let right = self.value(b);
                self.emit(InstKind::Assign(result, Rvalue::Use(right)));
                self.terminate(Terminator::Jump(join));
                self.switch_to(join);
                Operand::Var(result)
            }
            ValueKind::Binary(op, a, b) => {
                let a = self.value(a);
                let b = self.value(b);
                let op = match op.as_str() {
                    "+" => BinOp::Add,
                    "-" => BinOp::Sub,
                    "*" => BinOp::Mul,
                    "/" => BinOp::Div,
                    "%" => BinOp::Rem,
                    "==" => BinOp::Eq,
                    "!=" => BinOp::Ne,
                    "<" => BinOp::Lt,
                    "<=" => BinOp::Le,
                    ">" => BinOp::Gt,
                    _ => BinOp::Ge,
                };
                self.span = v.span;
                Operand::Var(self.assign(VarTy::Value(v.ty), Rvalue::Binary(op, a, b)))
            }
        }
    }
    fn match_value(&mut self, scrutinee: &lir::Value, arms: &[lir::Arm], ty: Type) -> Operand {
        // The scrutinee is evaluated exactly once: a place is examined in
        // place, any other value is first stored in a temporary.
        let place = match self.place_of(scrutinee) {
            Some(p) => p,
            None => {
                let s = self.value(scrutinee);
                Place {
                    var: self.assign(VarTy::Value(scrutinee.ty), Rvalue::Use(s)),
                    proj: Vec::new(),
                }
            }
        };
        let result = match ty {
            Type::SharedField(target) | Type::MutField(target) => {
                self.var(VarTy::Ref(target.referent()))
            }
            _ => {
                let v = self.var(VarTy::Value(ty));
                self.own_temp(v);
                v
            }
        };
        let join = self.block();
        for arm in arms {
            let next = self.block();
            let mut binds = Vec::new();
            self.test(&arm.pattern, &place, next, &mut binds);
            let types: HashMap<usize, Type> = arm.bindings.iter().copied().collect();
            // Bindings and arm body form one scope.
            self.push_frame(true);
            // Moving a payload consumes a direct owned enum in sema. Take
            // that enum only in the matching arm; its poll-local temporary
            // will drop any other payloads still owned after extracting bindings.
            let owned_scrutinee = (place.proj.is_empty()
                && matches!(self.vars[place.var], VarTy::Value(_)))
                || self
                    .async_ctx
                    .as_ref()
                    .is_some_and(|ctx| place.var == ctx.state);
            let snapshot = if matches!(scrutinee.ty, Type::Enum(_))
                && owned_scrutinee
                && binds
                    .iter()
                    .any(|(id, _)| types[id].is_move() && self.by_value.contains(id))
            {
                Some(self.read_value_place(place.clone(), scrutinee.ty))
            } else {
                None
            };
            let mut moved_parts = false;
            for (local, mut at) in binds {
                if let Some(var) = snapshot {
                    at.var = var;
                    at.proj.drain(..place.proj.len());
                }
                let t = types[&local];
                let var = if let Type::SharedField(target) | Type::MutField(target) = t {
                    self.assign(VarTy::Ref(target.referent()), Rvalue::FieldLoan(at))
                } else if t.is_move() && !self.by_value.contains(&local) {
                    self.assign(VarTy::Ref(t), Rvalue::Ref(at))
                } else {
                    let persistent = self
                        .async_ctx
                        .as_ref()
                        .is_some_and(|ctx| at.var == ctx.state);
                    let moved_payload = t.is_move() && !at.proj.is_empty();
                    moved_parts |= snapshot.is_none()
                        && !persistent
                        && self.owned.needs_drop(t)
                        && !at.proj.is_empty();
                    let var = self.var(VarTy::Value(t));
                    if snapshot.is_some() && moved_payload {
                        self.read_place_into(var, at.clone(), t);
                        self.emit(InstKind::Clear(at));
                    } else {
                        self.read_place_into(var, at, t);
                    }
                    self.own_local(var);
                    var
                };
                self.locals.insert(local, var);
            }
            if moved_parts && self.vars[place.var] != VarTy::Ref(scrutinee.ty) {
                // The owned payload now belongs to the bindings.
                self.emit(InstKind::Moved(place.var));
            }
            self.instructions(&arm.body);
            if let Some(v) = &arm.value {
                let op = self.value(v);
                self.emit(InstKind::Assign(result, Rvalue::Use(op)));
            } else if ty == Type::Unit {
                self.emit(InstKind::Assign(
                    result,
                    Rvalue::Use(Operand::Const(Const::Unit)),
                ));
            }
            self.pop_frame();
            self.terminate(Terminator::Jump(join));
            self.switch_to(next);
        }
        // Exhaustiveness was proven by semantic analysis.
        self.terminate(Terminator::Unreachable);
        self.switch_to(join);
        Operand::Var(result)
    }
    /// Emits the checks of `pattern` against `place`, jumping to `fail` when it
    /// does not match, and collects the places of its bindings.
    fn test(
        &mut self,
        pattern: &Pattern,
        place: &Place,
        fail: BlockId,
        binds: &mut Vec<(usize, Place)>,
    ) {
        let compare = |b: &mut Self, rv: Rvalue| {
            let c = b.assign(VarTy::Value(Type::Bool), rv);
            let ok = b.block();
            b.terminate(Terminator::Branch(Operand::Var(c), ok, fail));
            b.switch_to(ok);
        };
        match pattern {
            Pattern::Wild => {}
            Pattern::Bind(local) => binds.push((*local, place.clone())),
            Pattern::Int(n) => {
                let x = self.assign(VarTy::Value(Type::Int), Rvalue::Read(place.clone()));
                compare(
                    self,
                    Rvalue::Binary(BinOp::Eq, Operand::Var(x), Operand::Const(Const::Int(*n))),
                );
            }
            Pattern::Bool(b) => {
                let x = self.assign(VarTy::Value(Type::Bool), Rvalue::Read(place.clone()));
                compare(
                    self,
                    Rvalue::Binary(BinOp::Eq, Operand::Var(x), Operand::Const(Const::Bool(*b))),
                );
            }
            Pattern::Text(s) => compare(self, Rvalue::TextEq(place.clone(), s.clone())),
            Pattern::Variant(_, variant, subs) => {
                let d = self.assign(VarTy::Value(Type::Int), Rvalue::Discriminant(place.clone()));
                compare(
                    self,
                    Rvalue::Binary(
                        BinOp::Eq,
                        Operand::Var(d),
                        Operand::Const(Const::Int(*variant as i64)),
                    ),
                );
                for (i, sub) in subs.iter().enumerate() {
                    let mut p = place.clone();
                    p.proj.push(Proj::Payload(*variant, i));
                    self.test(sub, &p, fail, binds);
                }
            }
        }
    }
    /// Each instruction is a statement: its temporaries are dropped at its end.
    fn instructions(&mut self, body: &[lir::Instruction]) {
        for ins in body {
            self.push_frame(false);
            self.instruction(ins);
            self.pop_frame();
        }
    }
    fn instruction(&mut self, ins: &lir::Instruction) {
        use lir::Instruction as I;
        {
            match ins {
                I::BindRef(id, mode, referent, v) => {
                    let var = self.loan_value(v, *mode, *referent);
                    self.locals.insert(*id, var);
                }
                I::ReturnRef(mode, v) => {
                    let var = self.loan_value(v, *mode, v.ty);
                    self.drop_frames(0);
                    self.terminate_and_continue(Terminator::ReturnRef(var, v.span));
                }
                I::Bind(id, _, v) => {
                    let op = self.value(v);
                    // A local that must survive suspensions lives in the task
                    // state, not in the frame of the `poll` call.
                    let in_state = self.async_ctx.as_ref().and_then(|c| {
                        v.ty.is_move()
                            .then(|| c.local_slot.get(id).copied())
                            .flatten()
                    });
                    if let Some(field) = in_state {
                        self.bind_state_local(*id, field, v.ty, op);
                    } else {
                        let var = match v.ty {
                            Type::SharedField(target) | Type::MutField(target) => {
                                self.var(VarTy::Ref(target.referent()))
                            }
                            _ => {
                                let var = self.var(VarTy::Value(v.ty));
                                self.own_local(var);
                                var
                            }
                        };
                        self.emit(InstKind::Assign(var, Rvalue::Use(op)));
                        self.locals.insert(*id, var);
                        if self.async_ctx.is_some() {
                            self.save_local(*id, var, v.ty);
                        }
                    }
                }
                I::Store(place, v) => {
                    let op = self.value(v);
                    if let Some((field, _)) = self.state_local(place.root) {
                        if place.fields.is_empty() {
                            self.store_state_local(field, op);
                        } else {
                            self.emit(InstKind::Store(self.lir_place(place), op));
                        }
                    } else {
                        let var = self.local(place.root);
                        if place.fields.is_empty() && matches!(self.vars[var], VarTy::Value(_)) {
                            self.emit(InstKind::Assign(var, Rvalue::Use(op)));
                        } else {
                            let mut ty = self.vars[var].pointee();
                            let mut proj = Vec::new();
                            for &f in &place.fields {
                                proj.push(Proj::Field(f));
                                ty = match ty {
                                    Type::Struct(s) => self.program.structs[s].fields[f].1,
                                    _ => ty,
                                };
                            }
                            if let Type::MutField(target) = ty {
                                let ref_var = self.assign(
                                    VarTy::Ref(target.referent()),
                                    Rvalue::FieldLoan(Place { var, proj }),
                                );
                                self.emit(InstKind::Store(
                                    Place {
                                        var: ref_var,
                                        proj: Vec::new(),
                                    },
                                    op,
                                ));
                            } else {
                                self.emit(InstKind::Store(Place { var, proj }, op));
                            }
                        }
                    }
                }
                I::Eval(v) => {
                    self.value(v);
                }
                I::Yield => self.yield_point(),
                I::Sleep(ms) => self.sleep_point(ms),
                I::Return(v) => {
                    // Move the result out first, then drop everything still
                    // owned by the function, then return.
                    let op = self.value(v);
                    if self.async_ctx.is_some() {
                        // An async body stores its result in the task state.
                        self.complete(op);
                    } else {
                        let result = self.var(VarTy::Value(v.ty));
                        self.emit(InstKind::Assign(result, Rvalue::Use(op)));
                        self.drop_frames(0);
                        self.terminate_and_continue(Terminator::Return(Operand::Var(result)));
                    }
                }
                I::If(c, yes, no) => {
                    let c = self.value(c);
                    let (t, e, join) = (self.block(), self.block(), self.block());
                    self.terminate(Terminator::Branch(c, t, e));
                    self.switch_to(t);
                    self.scope(yes);
                    self.terminate(Terminator::Jump(join));
                    self.switch_to(e);
                    self.scope(no);
                    self.terminate(Terminator::Jump(join));
                    self.switch_to(join);
                }
                I::While(c, body) => {
                    let (head, inner, exit) = (self.block(), self.block(), self.block());
                    self.terminate(Terminator::Jump(head));
                    self.switch_to(head);
                    let c = self.value(c);
                    self.terminate(Terminator::Branch(c, inner, exit));
                    self.switch_to(inner);
                    self.loops.push((head, exit, self.frames.len()));
                    self.scope(body);
                    self.loops.pop();
                    self.terminate(Terminator::Jump(head));
                    self.switch_to(exit);
                }
                I::ForRange(id, start, end, inclusive, body) => {
                    // i = start; end' = end; while i < end' (or <=): x = i; body;
                    // latch: (inclusive: exit if i == end') i += 1. The increment
                    // never overflows because i < end' at the latch.
                    // The loop gets a frame of its own so that a suspension
                    // inside the body saves exactly the variables in scope.
                    self.push_frame(false);
                    let s = self.value(start);
                    let counter = self.assign(VarTy::Value(Type::Int), Rvalue::Use(s));
                    let e = self.value(end);
                    let limit = self.assign(VarTy::Value(Type::Int), Rvalue::Use(e));
                    if self.async_ctx.is_some() {
                        let fields = self.async_ctx.as_mut().and_then(|ctx| {
                            let pair = ctx.for_slots.get(ctx.next_for).copied();
                            ctx.next_for += 1;
                            pair
                        });
                        if let Some((c, l)) = fields {
                            self.save_loop_var(counter, c);
                            self.save_loop_var(limit, l);
                        }
                    }
                    let (head, inner, latch, step, exit) = (
                        self.block(),
                        self.block(),
                        self.block(),
                        self.block(),
                        self.block(),
                    );
                    self.terminate(Terminator::Jump(head));
                    self.switch_to(head);
                    let op = if *inclusive { BinOp::Le } else { BinOp::Lt };
                    let c = self.assign(
                        VarTy::Value(Type::Bool),
                        Rvalue::Binary(op, Operand::Var(counter), Operand::Var(limit)),
                    );
                    self.terminate(Terminator::Branch(Operand::Var(c), inner, exit));
                    self.switch_to(inner);
                    let x =
                        self.assign(VarTy::Value(Type::Int), Rvalue::Use(Operand::Var(counter)));
                    self.locals.insert(*id, x);
                    if self.async_ctx.is_some() {
                        let field = self
                            .async_ctx
                            .as_ref()
                            .and_then(|ctx| ctx.local_slot.get(id).copied());
                        if let Some(field) = field {
                            self.save_loop_var(x, field);
                        }
                    }
                    self.loops.push((latch, exit, self.frames.len()));
                    self.scope(body);
                    self.loops.pop();
                    self.terminate(Terminator::Jump(latch));
                    self.switch_to(latch);
                    if *inclusive {
                        let last = self.assign(
                            VarTy::Value(Type::Bool),
                            Rvalue::Binary(BinOp::Eq, Operand::Var(counter), Operand::Var(limit)),
                        );
                        self.terminate(Terminator::Branch(Operand::Var(last), exit, step));
                    } else {
                        self.terminate(Terminator::Jump(step));
                    }
                    self.switch_to(step);
                    self.emit(InstKind::Assign(
                        counter,
                        Rvalue::Binary(
                            BinOp::Add,
                            Operand::Var(counter),
                            Operand::Const(Const::Int(1)),
                        ),
                    ));
                    self.terminate(Terminator::Jump(head));
                    self.switch_to(exit);
                    self.pop_frame();
                }
                I::Loop(body) => {
                    let (head, exit) = (self.block(), self.block());
                    self.terminate(Terminator::Jump(head));
                    self.switch_to(head);
                    self.loops.push((head, exit, self.frames.len()));
                    self.scope(body);
                    self.loops.pop();
                    self.terminate(Terminator::Jump(head));
                    self.switch_to(exit);
                }
                I::ForEach(id, by_ref, coll, body) => {
                    // i = 0; n = len(c) (c cannot change during the loop);
                    // while i < n: x = c[i] (copy or borrow); body; i += 1.
                    let place = self.place_or_temp(coll);
                    let elem = self.elem_type(coll.ty);
                    let zero = Operand::Const(Const::Int(0));
                    let counter = self.assign(VarTy::Value(Type::Int), Rvalue::Use(zero));
                    let limit = self.assign(VarTy::Value(Type::Int), Rvalue::Len(place.clone()));
                    let (head, inner, latch, exit) =
                        (self.block(), self.block(), self.block(), self.block());
                    self.terminate(Terminator::Jump(head));
                    self.switch_to(head);
                    let c = self.assign(
                        VarTy::Value(Type::Bool),
                        Rvalue::Binary(BinOp::Lt, Operand::Var(counter), Operand::Var(limit)),
                    );
                    self.terminate(Terminator::Branch(Operand::Var(c), inner, exit));
                    self.switch_to(inner);
                    let mut at = place.clone();
                    at.proj.push(Proj::Index(counter));
                    let x = if let Type::SharedField(target) | Type::MutField(target) = elem {
                        self.assign(VarTy::Ref(target.referent()), Rvalue::FieldLoan(at))
                    } else if *by_ref {
                        self.assign(VarTy::Ref(elem), Rvalue::Ref(at))
                    } else {
                        self.assign(VarTy::Value(elem), Rvalue::Read(at))
                    };
                    self.locals.insert(*id, x);
                    self.loops.push((latch, exit, self.frames.len()));
                    self.scope(body);
                    self.loops.pop();
                    self.terminate(Terminator::Jump(latch));
                    self.switch_to(latch);
                    self.emit(InstKind::Assign(
                        counter,
                        Rvalue::Binary(
                            BinOp::Add,
                            Operand::Var(counter),
                            Operand::Const(Const::Int(1)),
                        ),
                    ));
                    self.terminate(Terminator::Jump(head));
                    self.switch_to(exit);
                }
                I::StoreElem(target, v) => {
                    // The value first, then the place: the replaced element is
                    // dropped by the store itself.
                    let op = self.value(v);
                    let place = self.place_of(target).expect("element place");
                    // Bounds failures report the element being written.
                    self.span = target.span;
                    self.emit(InstKind::Store(place, op));
                }
                I::Break | I::Continue => {
                    let (cont, brk, depth) = *self.loops.last().expect("loop context");
                    let target = if matches!(ins, I::Break) { brk } else { cont };
                    // Leave every frame opened inside the loop.
                    self.drop_frames(depth);
                    self.terminate_and_continue(Terminator::Jump(target));
                }
                I::Block(body) => self.scope(body),
            }
        }
    }
}

fn lower_function(
    f: &lir::Function,
    owned: &crate::drops::Ownership,
    program: &lir::Program,
    futures: &[FutureInfo],
) -> Func {
    let mut b = Builder {
        vars: Vec::new(),
        blocks: vec![Block::default()],
        current: 0,
        locals: HashMap::new(),
        loops: Vec::new(),
        frames: Vec::new(),
        by_value: &f.by_value_bindings,
        owned,
        program,
        futures,
        async_ctx: None,
        span: Span::default(),
    };
    // The function body scope owns the by-value parameters.
    b.push_frame(true);
    let mut params = Vec::new();
    if let Some((id, ty, _)) = f.receiver {
        let v = b.var(VarTy::Ref(ty));
        b.locals.insert(id, v);
        params.push(v);
    }
    for (i, (id, ty)) in f.params.iter().enumerate() {
        let is_ref = f.param_modes.get(i).copied().flatten().is_some();
        let var_ty = if is_ref {
            VarTy::Ref(*ty)
        } else {
            VarTy::Value(*ty)
        };
        let v = b.var(var_ty);
        b.locals.insert(*id, v);
        if !is_ref {
            b.own_local(v);
        }
        params.push(v);
    }
    b.instructions(&f.body);
    b.pop_frame();
    // Falling off the end returns () (sema guarantees non-unit functions return).
    let end = if f.result == Type::Unit && f.borrow_return.is_none() {
        Terminator::Return(Operand::Const(Const::Unit))
    } else {
        Terminator::Unreachable
    };
    b.terminate(end);
    Func {
        name: f.name.clone(),
        params,
        vars: b.vars,
        result: f.result,
        borrow_return: f.borrow_return.clone(),
        view_return: f.view_return.clone(),
        blocks: b.blocks,
    }
}

/// Lowers checked structured LIR to block-based LIR. Drops are emitted at
/// every scope exit; `drops::elaborate` must run before the result is used.
pub fn lower(program: &lir::Program) -> Module {
    let mut structs: Vec<StructDef> = program
        .structs
        .iter()
        .map(|s| StructDef {
            name: s.name.clone(),
            fields: s.fields.clone(),
        })
        .collect();
    // Every async function becomes three functions: the one the program calls
    // (which builds the task state), its `poll` and its state destructor. The
    // originals keep their indices, so call sites stay valid.
    let user_funcs = program.functions.len();
    let mut futures = Vec::new();
    let mut layouts = Vec::new();
    let mut enums = program.enums.clone();
    let mut tags = SlotTypes {
        program,
        enums: &mut enums,
        tags: HashMap::new(),
    };
    for (index, def) in program.futures.iter().enumerate() {
        if def.func == usize::MAX {
            let layout = AsyncLayout {
                owned_slots: Vec::new(),
                fields: vec![
                    ("tipo".into(), Type::Int),
                    ("reanudar".into(), Type::Int),
                    ("resultado".into(), def.result),
                ],
                params: Vec::new(),
                local_slot: HashMap::new(),
                for_slots: Vec::new(),
                await_slot: HashMap::new(),
                group_slot: HashMap::new(),
                task_slot: HashMap::new(),
            };
            futures.push(FutureInfo {
                result: def.result,
                state: structs.len(),
                poll: user_funcs + 2 * index,
                drop: user_funcs + 2 * index + 1,
                owned_slots: Vec::new(),
                factory: usize::MAX,
            });
            structs.push(StructDef {
                name: format!("{}$estado", def.name),
                fields: layout.fields.clone(),
            });
            layouts.push(layout);
        } else {
            let function = &program.functions[def.func];
            let layout = async_layout(function, def.result, &mut tags);
            futures.push(FutureInfo {
                result: def.result,
                state: structs.len(),
                poll: user_funcs + 2 * index,
                drop: user_funcs + 2 * index + 1,
                owned_slots: layout.owned_slots.clone(),
                factory: def.func,
            });
            structs.push(StructDef {
                name: format!("{}$estado", function.name),
                fields: layout.fields.clone(),
            });
            layouts.push(layout);
        }
    }
    let owned = crate::drops::Ownership::new(&structs, &enums, &program.arrays, &program.lists);
    let mut funcs: Vec<Func> = program
        .functions
        .iter()
        .enumerate()
        .map(|(id, f)| {
            if f.is_async {
                let index = future_of(program, id);
                lower_async_new(f, &futures[index], &layouts[index], index)
            } else {
                lower_function(f, &owned, program, &futures)
            }
        })
        .collect();
    for (index, def) in program.futures.iter().enumerate() {
        if def.func == usize::MAX {
            funcs.push(Func {
                name: format!("{}$poll", def.name),
                params: vec![0],
                vars: vec![VarTy::Ref(Type::Struct(futures[index].state))],
                result: Type::Int,
                borrow_return: None,
                view_return: None,
                blocks: vec![Block {
                    insts: Vec::new(),
                    term: Some(Terminator::Return(Operand::Const(Const::Int(POLL_READY)))),
                }],
            });
            funcs.push(Func {
                name: format!("{}$drop", def.name),
                params: vec![0],
                vars: vec![VarTy::Ref(Type::Struct(futures[index].state))],
                result: Type::Unit,
                borrow_return: None,
                view_return: None,
                blocks: vec![Block {
                    insts: Vec::new(),
                    term: Some(Terminator::Return(Operand::Const(Const::Unit))),
                }],
            });
            continue;
        }
        let function = &program.functions[def.func];
        funcs.push(lower_async_poll(
            function,
            &owned,
            program,
            &futures,
            &futures[index],
            &layouts[index],
        ));
        funcs.push(lower_async_drop(
            function,
            &owned,
            &futures[index],
            &layouts[index],
        ));
    }
    // An async `main` runs on the cooperative executor.
    let mut main = program.main;
    if program.functions[main].is_async {
        let index = future_of(program, main);
        funcs.push(lower_async_runner(main, index, &futures[index]));
        main = funcs.len() - 1;
    }
    Module {
        structs,
        enums,
        arrays: program.arrays.clone(),
        slices: program.slices.clone(),
        lists: program.lists.clone(),
        task_groups: program.task_groups.clone(),
        futures,
        funcs,
        main,
    }
}

// -------------------------------------------------------- async lowering ---

/// Values that a suspension can save in the task state: they own nothing, so
/// saving a copy is always correct. Anything else must not be live across a
/// suspension (semantic analysis rejects it).
fn spillable(t: Type) -> bool {
    matches!(
        t,
        Type::Int | Type::Float | Type::F32 | Type::Bool | Type::Unit
    )
}

/// Future type index of async function `id`.
fn future_of(program: &lir::Program, id: usize) -> usize {
    program
        .futures
        .iter()
        .position(|d| d.func == id)
        .expect("toda función async tiene un tipo future")
}

/// Layout of the task state of one async function.
struct AsyncLayout {
    owned_slots: Vec<OwnedSlot>,
    fields: Vec<(String, Type)>,
    /// State field of each parameter, in order.
    params: Vec<usize>,
    /// State field of each saved local, by LIR local id.
    local_slot: HashMap<usize, usize>,
    /// Counter and limit fields of each `for` over a range, in body order.
    for_slots: Vec<(usize, usize)>,
    /// State field holding the awaited future, by future type.
    await_slot: HashMap<usize, usize>,
    group_slot: HashMap<Type, usize>,
    /// Awaited task slots by future type and argument position.
    task_slot: HashMap<(usize, usize), usize>,
}

struct SlotTypes<'a> {
    program: &'a lir::Program,
    enums: &'a mut Vec<EnumDef>,
    tags: HashMap<Type, usize>,
}

impl SlotTypes<'_> {
    fn supports(&self, ty: Type) -> bool {
        if matches!(ty, Type::List(id) if matches!(self.program.lists[id], Type::Task(_))) {
            return true;
        }
        if matches!(ty, Type::TaskGroup(_) | Type::Future(_)) {
            return true;
        }
        ty.async_owned(
            &|id| &self.program.structs[id].fields,
            &|id| &self.program.enums[id].variants,
            &self.program.arrays,
            &self.program.lists,
            &self.program.task_groups,
        )
    }

    fn add(&mut self, layout: &mut AsyncLayout, name: String, ty: Type, parameter: bool) -> usize {
        if !self.supports(ty) {
            return add_field(layout, name, ty);
        }
        let tag = *self.tags.entry(ty).or_insert_with(|| {
            let id = self.enums.len();
            self.enums.push(EnumDef {
                name: format!("$async_slot{id}"),
                variants: vec![("Empty".into(), vec![]), ("Full".into(), vec![ty])],
            });
            id
        });
        let field = add_field(layout, name, Type::Enum(tag));
        layout.owned_slots.push(OwnedSlot {
            field,
            tag,
            parameter,
        });
        field
    }
}

fn full_slot(tag: usize, op: Operand) -> Rvalue {
    Rvalue::Variant(tag, 1, vec![op])
}

/// Reserves a state field for every parameter, saved local, range loop and
/// awaited future type of the body. Reusing one field per future type is safe:
/// an awaited future is released and cleared before the next await begins.
fn async_layout(f: &lir::Function, result: Type, slots: &mut SlotTypes) -> AsyncLayout {
    let mut layout = AsyncLayout {
        owned_slots: Vec::new(),
        fields: vec![
            ("tipo".into(), Type::Int),
            ("reanudar".into(), Type::Int),
            ("resultado".into(), result),
        ],
        params: Vec::new(),
        local_slot: HashMap::new(),
        for_slots: Vec::new(),
        await_slot: HashMap::new(),
        group_slot: HashMap::new(),
        task_slot: HashMap::new(),
    };
    for (i, (_, ty)) in f.params.iter().enumerate() {
        let field = slots.add(&mut layout, format!("p{i}"), *ty, true);
        layout.params.push(field);
    }
    collect_slots(&f.body, &mut layout, slots);
    layout
}

fn add_field(layout: &mut AsyncLayout, name: String, ty: Type) -> usize {
    let index = layout.fields.len();
    layout.fields.push((name, ty));
    index
}

fn collect_slots(body: &[lir::Instruction], layout: &mut AsyncLayout, slots: &mut SlotTypes) {
    use lir::Instruction as I;
    for inst in body {
        match inst {
            I::Bind(id, _, v) => {
                collect_value(v, layout, slots);
                let in_state = spillable(v.ty)
                    || matches!(v.ty, Type::Task(_) | Type::Future(_))
                    || slots.supports(v.ty);
                if in_state && !layout.local_slot.contains_key(id) {
                    let field = slots.add(layout, format!("l{id}"), v.ty, false);
                    layout.local_slot.insert(*id, field);
                }
            }
            I::BindRef(_, _, _, v)
            | I::Store(_, v)
            | I::Eval(v)
            | I::Return(v)
            | I::ReturnRef(_, v) => collect_value(v, layout, slots),
            I::StoreElem(a, b) => {
                collect_value(a, layout, slots);
                collect_value(b, layout, slots);
            }
            I::If(c, yes, no) => {
                collect_value(c, layout, slots);
                collect_slots(yes, layout, slots);
                collect_slots(no, layout, slots);
            }
            I::While(c, b) | I::ForEach(_, _, c, b) => {
                collect_value(c, layout, slots);
                collect_slots(b, layout, slots);
            }
            I::ForRange(id, from, to, _, b) => {
                collect_value(from, layout, slots);
                collect_value(to, layout, slots);
                let counter = add_field(layout, format!("i{id}"), Type::Int);
                let limit = add_field(layout, format!("n{id}"), Type::Int);
                layout.for_slots.push((counter, limit));
                if !layout.local_slot.contains_key(id) {
                    let field = add_field(layout, format!("l{id}"), Type::Int);
                    layout.local_slot.insert(*id, field);
                }
                collect_slots(b, layout, slots);
            }
            I::Loop(b) | I::Block(b) => collect_slots(b, layout, slots),
            I::Sleep(ms) => collect_value(ms, layout, slots),
            I::Yield | I::Break | I::Continue => {}
        }
    }
}

fn reserve_task_slot(layout: &mut AsyncLayout, ty: Type, position: usize) {
    if let Type::Task(index) = ty
        && !layout.task_slot.contains_key(&(index, position))
    {
        let field = add_field(layout, format!("t{index}_{position}"), ty);
        layout.task_slot.insert((index, position), field);
    }
}

fn collect_value(v: &lir::Value, layout: &mut AsyncLayout, slots: &mut SlotTypes) {
    crate::sema::visit_values(v, &mut |x| match &x.kind {
        ValueKind::Await(future) => match future.ty {
            Type::Future(index) if !layout.await_slot.contains_key(&index) => {
                let field = add_field(layout, format!("f{index}"), future.ty);
                layout.await_slot.insert(index, field);
            }
            ty => reserve_task_slot(layout, ty, 0),
        },
        ValueKind::JoinAll(group) => {
            if !layout.group_slot.contains_key(&group.ty) {
                let field = slots.add(
                    layout,
                    format!("g{}", layout.group_slot.len()),
                    group.ty,
                    false,
                );
                layout.group_slot.insert(group.ty, field);
            }
        }
        ValueKind::Join(handles) => {
            for (position, handle) in handles.iter().enumerate() {
                reserve_task_slot(layout, handle.ty, position);
            }
        }
        _ => {}
    });
}

/// The function the program calls: it reserves the task state, stores the
/// arguments in it and returns the future. Nothing of the body runs yet.
fn lower_async_new(
    f: &lir::Function,
    info: &FutureInfo,
    layout: &AsyncLayout,
    index: usize,
) -> Func {
    let mut vars = Vec::new();
    let mut params = Vec::new();
    for (_, ty) in &f.params {
        vars.push(VarTy::Value(*ty));
        params.push(vars.len() - 1);
    }
    vars.push(VarTy::Value(Type::Future(index)));
    let handle = vars.len() - 1;
    vars.push(VarTy::Ref(Type::Struct(info.state)));
    let state = vars.len() - 1;
    let span = Span::at(1, 1);
    let mut insts = vec![
        Inst {
            kind: InstKind::Assign(handle, Rvalue::FutureNew(index)),
            span,
        },
        Inst {
            kind: InstKind::Assign(
                state,
                Rvalue::FutureState(Place {
                    var: handle,
                    proj: Vec::new(),
                }),
            ),
            span,
        },
        Inst {
            kind: InstKind::Store(
                Place {
                    var: state,
                    proj: vec![Proj::Field(KIND_FIELD)],
                },
                Operand::Const(Const::Int(index as i64)),
            ),
            span,
        },
    ];
    for (&param, &field) in params.iter().zip(&layout.params) {
        let mut op = Operand::Var(param);
        if let Type::Enum(tag) = layout.fields[field].1 {
            let packed = vars.len();
            vars.push(VarTy::Value(Type::Enum(tag)));
            insts.push(Inst {
                kind: InstKind::Assign(packed, full_slot(tag, op)),
                span,
            });
            op = Operand::Var(packed);
        }
        insts.push(Inst {
            kind: InstKind::Store(
                Place {
                    var: state,
                    proj: vec![Proj::Field(field)],
                },
                op,
            ),
            span,
        });
    }
    Func {
        name: f.name.clone(),
        params,
        vars,
        result: Type::Future(index),
        borrow_return: None,
        view_return: None,
        blocks: vec![Block {
            insts,
            term: Some(Terminator::Return(Operand::Var(handle))),
        }],
    }
}

/// `poll(state) -> Int`: resumes the body where it left off and runs it until
/// it finishes (Ready) or reaches a suspension point (Pending).
fn lower_async_poll(
    f: &lir::Function,
    owned: &crate::drops::Ownership,
    program: &lir::Program,
    futures: &[FutureInfo],
    info: &FutureInfo,
    layout: &AsyncLayout,
) -> Func {
    let mut b = Builder {
        vars: Vec::new(),
        blocks: vec![Block::default()],
        current: 0,
        locals: HashMap::new(),
        loops: Vec::new(),
        frames: Vec::new(),
        by_value: &f.by_value_bindings,
        owned,
        program,
        futures,
        async_ctx: None,
        span: Span::default(),
    };
    let state = b.var(VarTy::Ref(Type::Struct(info.state)));
    b.async_ctx = Some(AsyncCtx {
        state,
        local_slot: layout.local_slot.clone(),
        for_slots: layout.for_slots.clone(),
        next_for: 0,
        await_slot: layout.await_slot.clone(),
        group_slot: layout.group_slot.clone(),
        task_slot: layout.task_slot.clone(),
        state_local: HashMap::new(),
        tags: layout
            .owned_slots
            .iter()
            .map(|s| (s.field, s.tag))
            .collect(),
        resumes: Vec::new(),
    });
    // Copy parameters are loaded on every poll. Owners remain in their slots
    // from the constructor to their move or the exit of the outer scope.
    let start = b.block();
    debug_assert_eq!(start, ASYNC_BODY_ENTRY);
    b.switch_to(start);
    b.push_frame(true);
    let mut param_vars = Vec::new();
    for (&(id, ty), &field) in f.params.iter().zip(&layout.params) {
        if matches!(layout.fields[field].1, Type::Enum(_)) {
            b.frames.last_mut().unwrap().fields.push(field);
            b.async_ctx
                .as_mut()
                .unwrap()
                .state_local
                .insert(id, (field, ty));
        } else {
            let v = b.var(VarTy::Value(ty));
            b.locals.insert(id, v);
            param_vars.push((v, field));
        }
    }
    b.instructions(&f.body);
    b.pop_frame();
    // Falling off the end finishes the task with the unit result (semantic
    // analysis guarantees that a body with a result returns on every path).
    if b.blocks[b.current].term.is_none() {
        if f.result == Type::Unit {
            b.complete(Operand::Const(Const::Unit));
        } else {
            b.terminate(Terminator::Unreachable);
        }
    }
    // `complete` leaves a fresh block behind; nothing reaches it.
    if b.blocks[b.current].term.is_none() {
        b.terminate(Terminator::Unreachable);
    }
    // The entry block restores the parameters and jumps to the resume point.
    let resumes = b
        .async_ctx
        .as_ref()
        .map(|c| c.resumes.clone())
        .unwrap_or_default();
    b.switch_to(0);
    for (var, field) in &param_vars {
        let place = Place {
            var: state,
            proj: vec![Proj::Field(*field)],
        };
        b.emit(InstKind::Assign(*var, Rvalue::Read(place)));
    }
    let resume_place = Place {
        var: state,
        proj: vec![Proj::Field(RESUME_FIELD)],
    };
    let point = b.assign(VarTy::Value(Type::Int), Rvalue::Read(resume_place));
    for (i, target) in resumes.iter().enumerate() {
        let next = b.block();
        let hit = b.assign(
            VarTy::Value(Type::Bool),
            Rvalue::Binary(
                BinOp::Eq,
                Operand::Var(point),
                Operand::Const(Const::Int(i as i64 + 1)),
            ),
        );
        b.terminate(Terminator::Branch(Operand::Var(hit), *target, next));
        b.switch_to(next);
    }
    // `resume` is 0 on the first poll. A finished task is never polled again:
    // its handle is released as soon as its result is taken.
    let first = b.assign(
        VarTy::Value(Type::Bool),
        Rvalue::Binary(
            BinOp::Eq,
            Operand::Var(point),
            Operand::Const(Const::Int(0)),
        ),
    );
    let invalid = b.block();
    b.terminate(Terminator::Branch(Operand::Var(first), start, invalid));
    b.switch_to(invalid);
    b.terminate(Terminator::Unreachable);
    Func {
        name: format!("{}$poll", f.name),
        params: vec![state],
        vars: b.vars,
        result: Type::Int,
        borrow_return: None,
        view_return: None,
        blocks: b.blocks,
    }
}

/// `drop(state)`: releases what the task state still owns. A field that was
/// never written, or whose value was already taken, holds the zero pattern,
/// which owns nothing, so every owning field can be dropped unconditionally.
fn lower_async_drop(
    f: &lir::Function,
    owned: &crate::drops::Ownership,
    info: &FutureInfo,
    layout: &AsyncLayout,
) -> Func {
    let state = 0;
    let span = Span::at(1, 1);
    let insts = layout
        .fields
        .iter()
        .enumerate()
        .filter(|(_, (_, ty))| owned.needs_drop(*ty))
        .map(|(field, _)| Inst {
            kind: InstKind::DropField(
                Place {
                    var: state,
                    proj: vec![Proj::Field(field)],
                },
                None,
            ),
            span,
        })
        .collect();
    Func {
        name: format!("{}$drop", f.name),
        params: vec![state],
        vars: vec![VarTy::Ref(Type::Struct(info.state))],
        result: Type::Unit,
        borrow_return: None,
        view_return: None,
        blocks: vec![Block {
            insts,
            term: Some(Terminator::Return(Operand::Const(Const::Unit))),
        }],
    }
}

/// Entry point of a program with an async `main`: it registers the task of
/// `main` in the cooperative scheduler and runs the scheduler until no task is
/// ready. No thread is ever created, and destroying the root handle at the end
/// cancels whatever is left (there should be nothing: leaving the body of
/// `main` already destroyed its handles).
fn lower_async_runner(main: usize, index: usize, _info: &FutureInfo) -> Func {
    let span = Span::at(1, 1);
    let vars = vec![
        VarTy::Value(Type::Future(index)),
        VarTy::Value(Type::Task(index)),
    ];
    let (future, task) = (0, 1);
    let blocks = vec![Block {
        insts: vec![
            Inst {
                kind: InstKind::Assign(future, Rvalue::Call(main, Vec::new())),
                span,
            },
            Inst {
                kind: InstKind::Assign(task, Rvalue::TaskSpawn(Operand::Var(future), index)),
                span,
            },
            Inst {
                kind: InstKind::RunTasks,
                span,
            },
            Inst {
                kind: InstKind::Drop(task, None),
                span,
            },
        ],
        term: Some(Terminator::Return(Operand::Const(Const::Unit))),
    }];
    Func {
        name: "main$ejecutor".into(),
        params: Vec::new(),
        vars,
        result: Type::Unit,
        borrow_return: None,
        view_return: None,
        blocks,
    }
}

// ---------------------------------------------------------------- verifier --

/// A malformed CFG LIR program: always a compiler bug, never a user error.
#[derive(Debug, Clone, PartialEq)]
pub struct VerifyError {
    pub func: String,
    pub block: BlockId,
    pub message: String,
}
impl VerifyError {
    pub fn into_diagnostic(self) -> Diagnostic {
        Diagnostic::new(
            Span::at(1, 1),
            format!(
                "error interno del compilador: LIR inválida en {} (bloque {}): {}",
                self.func, self.block, self.message
            ),
        )
        .classify("L0007", "lir")
    }
}

struct Verifier<'a> {
    module: &'a Module,
    func: &'a Func,
    block: BlockId,
}

impl Verifier<'_> {
    fn fail<T>(&self, message: impl Into<String>) -> Result<T, VerifyError> {
        Err(VerifyError {
            func: self.func.name.clone(),
            block: self.block,
            message: message.into(),
        })
    }
    fn var(&self, v: VarId) -> Result<VarTy, VerifyError> {
        match self.func.vars.get(v) {
            Some(t) => Ok(*t),
            None => self.fail(format!("variable inexistente v{v}")),
        }
    }
    fn operand(&self, op: &Operand) -> Result<VarTy, VerifyError> {
        match op {
            Operand::Var(v) => self.var(*v),
            Operand::Const(c) => Ok(VarTy::Value(c.ty())),
        }
    }
    fn value_operand(&self, op: &Operand) -> Result<Type, VerifyError> {
        match self.operand(op)? {
            VarTy::Value(t) => Ok(t),
            VarTy::Ref(_) => self.fail("un préstamo no puede usarse como valor directo"),
        }
    }
    fn collection_element(
        &self,
        list: Type,
        expected: Type,
        actual: Type,
    ) -> Result<(), VerifyError> {
        if let (Type::List(_), Type::Task(a), Type::Task(b)) = (list, expected, actual)
            && let (Some(a), Some(b)) = (self.module.futures.get(a), self.module.futures.get(b))
            && a.result == b.result
        {
            return Ok(());
        }
        self.expect(expected, actual, "elemento de colección")
    }

    fn place(&self, p: &Place) -> Result<Type, VerifyError> {
        let mut t = self.var(p.var)?.pointee();
        for proj in &p.proj {
            t = match (proj, t) {
                (Proj::Field(i), Type::Struct(s)) => {
                    match self.module.structs.get(s).and_then(|d| d.fields.get(*i)) {
                        Some((_, ft)) => *ft,
                        None => return self.fail(format!("campo {i} inexistente")),
                    }
                }
                (Proj::Payload(v, i), Type::Enum(e)) => {
                    match self
                        .module
                        .enums
                        .get(e)
                        .and_then(|d| d.variants.get(*v))
                        .and_then(|(_, p)| p.get(*i))
                    {
                        Some(pt) => *pt,
                        None => return self.fail(format!("payload {v}.{i} inexistente")),
                    }
                }
                (
                    Proj::Index(i),
                    Type::Array(_)
                    | Type::Slice(_)
                    | Type::List(_)
                    | Type::RegionList(..)
                    | Type::TaskGroup(_),
                ) => {
                    if self.var(*i)? != VarTy::Value(Type::Int) {
                        return self.fail(format!("índice v{i} no es Int"));
                    }
                    match self.module.elem_of(t) {
                        Some(e) => e,
                        None => return self.fail(format!("colección inexistente {t:?}")),
                    }
                }
                _ => return self.fail(format!("proyección {proj:?} sobre tipo {t:?}")),
            };
        }
        Ok(t)
    }
    fn expect(&self, expected: Type, actual: Type, what: &str) -> Result<(), VerifyError> {
        if expected == actual {
            return Ok(());
        }
        if let (Type::Future(a), Type::Future(b)) = (expected, actual)
            && let (Some(fa), Some(fb)) = (self.module.futures.get(a), self.module.futures.get(b))
            && fa.result == fb.result
        {
            return Ok(());
        }
        self.fail(format!(
            "{what}: se esperaba {expected:?}, encontrado {actual:?}"
        ))
    }
    fn rvalue(&self, rv: &Rvalue) -> Result<VarTy, VerifyError> {
        Ok(match rv {
            Rvalue::Use(op) => self.operand(op)?,
            Rvalue::Unary(op, a) => {
                let t = self.value_operand(a)?;
                match (op, t) {
                    (UnOp::Neg, Type::Int | Type::Float | Type::F32) | (UnOp::Not, Type::Bool) => {
                        VarTy::Value(t)
                    }
                    _ => return self.fail(format!("{op:?} sobre {t:?}")),
                }
            }
            Rvalue::Binary(op, a, b) => {
                let (ta, tb) = (self.value_operand(a)?, self.value_operand(b)?);
                self.expect(ta, tb, "operandos de operación binaria")?;
                if op.is_comparison() {
                    let equality = matches!(op, BinOp::Eq | BinOp::Ne);
                    let ok = match ta {
                        Type::Int | Type::Float | Type::F32 => true,
                        Type::Bool | Type::Unit => equality,
                        _ => false,
                    };
                    if !ok {
                        return self.fail(format!("comparación {op:?} sobre {ta:?}"));
                    }
                    VarTy::Value(Type::Bool)
                } else if matches!(ta, Type::Int | Type::Float | Type::F32) {
                    VarTy::Value(ta)
                } else {
                    return self.fail(format!("aritmética sobre {ta:?}"));
                }
            }
            Rvalue::Platform(op, args, result) => {
                if *op == PlatformOp::WriteBytes {
                    if args.len() != 2 || *result != Type::Int {
                        return self.fail("writeBytes requiere dos argumentos y resultado Int");
                    }
                    let Arg::Ref(path, false) = &args[0] else {
                        return self.fail("writeBytes requiere ruta Text prestada");
                    };
                    self.expect(Type::Text, self.place(path)?, "ruta de writeBytes")?;
                    let Arg::Ref(bytes, false) = &args[1] else {
                        return self.fail("writeBytes requiere List<Int> prestada");
                    };
                    let Type::List(l) = self.place(bytes)? else {
                        return self.fail("writeBytes requiere List<Int>");
                    };
                    if self.module.lists.get(l) != Some(&Type::Int) {
                        return self.fail("writeBytes requiere elementos Int");
                    }
                    return Ok(VarTy::Value(Type::Int));
                }
                if args.len() != op.params().len() {
                    return self.fail("aridad de operación de plataforma incorrecta");
                }
                for (arg, ty) in args.iter().zip(op.params()) {
                    let actual = match (arg, ty) {
                        (Arg::Ref(p, false), Type::Text) => self.place(p)?,
                        (Arg::Value(value), Type::Int) => self.value_operand(value)?,
                        _ => return self.fail("modo de argumento de plataforma incorrecto"),
                    };
                    self.expect(*ty, actual, "operación de plataforma")?;
                }
                match (op, result) {
                    (PlatformOp::ArgCount, Type::Int)
                    | (PlatformOp::PrintError, Type::Unit)
                    | (PlatformOp::SameFile, Type::Bool) => {}
                    (PlatformOp::Arg | PlatformOp::ReadText, Type::Enum(id))
                        if self.module.enums.get(*id).is_some_and(|e| {
                            matches!(
                                e.variants.as_slice(),
                                [(ok, text), (err, code)] if ok == "Ok" && text == &[Type::Text]
                                    && err == "Err" && code == &[Type::Int]
                            )
                        }) => {}
                    _ => return self.fail("resultado de operación de plataforma incorrecto"),
                }
                VarTy::Value(*result)
            }
            Rvalue::Call(f, args) => {
                let Some(callee) = self.module.funcs.get(*f) else {
                    return self.fail(format!("función inexistente f{f}"));
                };
                if callee.params.len() != args.len() {
                    return self.fail(format!(
                        "llamada a {} con {} argumentos",
                        callee.name,
                        args.len()
                    ));
                }
                for (param, arg) in callee.params.iter().zip(args) {
                    let expected = callee.vars[*param];
                    let actual = match arg {
                        Arg::Value(op) => VarTy::Value(self.value_operand(op)?),
                        Arg::Ref(p, _) => VarTy::Ref(self.place(p)?),
                    };
                    // A `&Bytes` parameter accepts a buffer of any caller region.
                    let caller_buffer = matches!(
                        (expected, actual),
                        (
                            VarTy::Ref(Type::Bytes(crate::lir::CALLER_REGION)),
                            VarTy::Ref(Type::Bytes(_))
                        )
                    );
                    let slice_view = match (expected, actual) {
                        (VarTy::Ref(e @ Type::Slice(_)), VarTy::Ref(a)) => {
                            matches!(
                                a,
                                Type::Array(_)
                                    | Type::List(_)
                                    | Type::RegionList(..)
                                    | Type::Slice(_)
                            ) && self.module.elem_of(e) == self.module.elem_of(a)
                        }
                        _ => false,
                    };
                    let future_compat = match (expected, actual) {
                        (VarTy::Value(Type::Future(a)), VarTy::Value(Type::Future(b))) => {
                            match (self.module.futures.get(a), self.module.futures.get(b)) {
                                (Some(fa), Some(fb)) => fa.result == fb.result,
                                _ => false,
                            }
                        }
                        _ => false,
                    };
                    if expected != actual && !caller_buffer && !slice_view && !future_compat {
                        return self.fail(format!(
                            "argumento de {}: se esperaba {expected:?}, encontrado {actual:?}",
                            callee.name
                        ));
                    }
                }
                if let Some(contract) = &callee.borrow_return {
                    if contract.params.is_empty()
                        || contract.params.iter().any(|&index| {
                            !matches!(args.get(index), Some(Arg::Ref(_, exclusive))
                        if contract.mode == Receiver::Shared || *exclusive)
                        })
                    {
                        return self.fail("la llamada no respeta el contrato de retorno prestado");
                    }
                    VarTy::Ref(callee.result)
                } else {
                    VarTy::Value(callee.result)
                }
            }
            Rvalue::Struct(s, ops) => {
                let Some(def) = self.module.structs.get(*s) else {
                    return self.fail(format!("struct inexistente {s}"));
                };
                if def.fields.len() != ops.len() {
                    return self.fail("número de campos incorrecto");
                }
                for ((_, t), op) in def.fields.iter().zip(ops) {
                    if let Type::SharedField(target) | Type::MutField(target) = t {
                        let Operand::Var(source) = op else {
                            return self.fail("un campo prestado requiere una referencia");
                        };
                        if self.var(*source)? != VarTy::Ref(target.referent()) {
                            return self.fail("referente incorrecto para el campo prestado");
                        }
                    } else {
                        self.expect(*t, self.value_operand(op)?, "campo de struct")?;
                    }
                }
                VarTy::Value(Type::Struct(*s))
            }
            Rvalue::Variant(e, v, ops) => {
                let Some((_, payload)) = self.module.enums.get(*e).and_then(|d| d.variants.get(*v))
                else {
                    return self.fail(format!("variante inexistente {e}.{v}"));
                };
                if payload.len() != ops.len() {
                    return self.fail("número de datos de variante incorrecto");
                }
                for (t, op) in payload.iter().zip(ops) {
                    if let Type::SharedField(target) | Type::MutField(target) = t {
                        let Operand::Var(source) = op else {
                            return self
                                .fail("el campo prestado requiere una variable de préstamo");
                        };
                        if self.var(*source)? != VarTy::Ref(target.referent()) {
                            return self.fail("referente incorrecto para el campo prestado");
                        }
                    } else {
                        self.expect(*t, self.value_operand(op)?, "dato de variante")?;
                    }
                }
                VarTy::Value(Type::Enum(*e))
            }
            Rvalue::FieldLoan(p) => {
                let target = match self.place(p)? {
                    Type::SharedField(t) | Type::MutField(t) => t,
                    _ => return self.fail("se esperaba un campo con puntero prestado"),
                };
                if !matches!(
                    p.proj.as_slice(),
                    [Proj::Field(_)] | [Proj::Payload(..)] | [Proj::Index(_)]
                ) {
                    return self.fail("una vista local requiere acceso a un campo directo");
                }
                VarTy::Ref(target.referent())
            }
            Rvalue::Read(p) => {
                let ty = self.place(p)?;
                if matches!(ty, Type::SharedField(_) | Type::MutField(_)) {
                    return self.fail("use FieldLoan para leer un campo prestado");
                }
                VarTy::Value(ty)
            }
            Rvalue::Ref(p) => VarTy::Ref(self.place(p)?),
            Rvalue::Loan(p, _, t) => {
                let actual = self.place(p)?;
                let slice_view = matches!(t, Type::Slice(_))
                    && self.module.elem_of(*t).is_some()
                    && self.module.elem_of(*t) == self.module.elem_of(actual);
                if !slice_view {
                    self.expect(*t, actual, "origen del préstamo")?;
                }
                VarTy::Ref(*t)
            }
            Rvalue::Discriminant(p) => match self.place(p)? {
                Type::Enum(_) => VarTy::Value(Type::Int),
                t => return self.fail(format!("discriminante de {t:?}")),
            },
            Rvalue::TextEq(p, _) => {
                self.expect(Type::Text, self.place(p)?, "comparación de Text")?;
                VarTy::Value(Type::Bool)
            }
            Rvalue::TextBuffer(_) => VarTy::Value(Type::Text),
            Rvalue::RegionNew(r) => VarTy::Value(Type::Region(*r)),
            Rvalue::FutureNew(index) => match self.module.futures.get(*index) {
                Some(_) => VarTy::Value(Type::Future(*index)),
                None => return self.fail(format!("tipo future inexistente {index}")),
            },
            Rvalue::FutureState(p) => match self.place(p)? {
                Type::Future(index) => match self.module.futures.get(index) {
                    Some(info) => VarTy::Ref(Type::Struct(info.state)),
                    None => return self.fail(format!("tipo future inexistente {index}")),
                },
                other => {
                    return self.fail(format!("estado de un valor que no es future: {other:?}"));
                }
            },
            Rvalue::FuturePoll(p) => match self.place(p)? {
                Type::Future(_) => VarTy::Value(Type::Int),
                other => {
                    return self.fail(format!("poll de un valor que no es future: {other:?}"));
                }
            },
            Rvalue::TaskSpawn(op, index) => {
                let actual = self.value_operand(op)?;
                match (actual, self.module.futures.get(*index)) {
                    (Type::Future(act), Some(exp_info)) => {
                        let act_info = match self.module.futures.get(act) {
                            Some(info) => info,
                            None => return self.fail(format!("tipo future inexistente {act}")),
                        };
                        if act_info.result != exp_info.result {
                            return self.fail(format!(
                                "future registrado por spawn: tipos de resultado incompatibles {:?} y {:?}",
                                act_info.result, exp_info.result
                            ));
                        }
                        VarTy::Value(Type::Task(*index))
                    }
                    _ => return self.fail("future registrado por spawn"),
                }
            }
            Rvalue::GroupRegister(p) => match self.place(p)? {
                Type::List(i) if matches!(self.module.lists[i], Type::Task(_)) => {
                    VarTy::Value(Type::Int)
                }
                Type::TaskGroup(_) => VarTy::Value(Type::Int),
                _ => return self.fail("GroupRegister requiere una lista de TaskHandle"),
            },
            Rvalue::GroupPending | Rvalue::TimerPending => VarTy::Value(Type::Int),
            Rvalue::CheckSleep(ms) | Rvalue::TimerStart(ms) => {
                self.expect(
                    Type::Int,
                    self.value_operand(ms)?,
                    "duración del temporizador",
                )?;
                VarTy::Value(Type::Int)
            }
            Rvalue::TaskReady(p) => match self.place(p)? {
                Type::Task(_) => VarTy::Value(Type::Int),
                other => {
                    return self.fail(format!("estado de un valor que no es tarea: {other:?}"));
                }
            },
            Rvalue::TaskState(p) => match self.place(p)? {
                Type::Task(index) => match self.module.futures.get(index) {
                    Some(info) => VarTy::Ref(Type::Struct(info.state)),
                    None => return self.fail(format!("tipo future inexistente {index}")),
                },
                other => {
                    return self.fail(format!("estado de un valor que no es tarea: {other:?}"));
                }
            },
            Rvalue::RegionList(p, elem) => match self.place(p)? {
                Type::Region(r)
                    if self
                        .module
                        .lists
                        .get(*elem)
                        .is_some_and(|t| !t.is_region_bound() && *t != Type::Unit) =>
                {
                    VarTy::Value(Type::RegionList(*elem, r))
                }
                _ => return self.fail("constructor de lista regional inválido"),
            },
            Rvalue::RegionBytes(p, size) => {
                self.expect(Type::Int, self.value_operand(size)?, "tamaño de bytes")?;
                match self.place(p)? {
                    Type::Region(r) => VarTy::Value(Type::Bytes(r)),
                    t => return self.fail(format!("bytes() sobre {t:?}, no una región")),
                }
            }
            Rvalue::BytesLen(p) => {
                if !matches!(self.place(p)?, Type::Bytes(_)) {
                    return self.fail("len() sobre algo que no es Bytes");
                }
                VarTy::Value(Type::Int)
            }
            Rvalue::ArrayLit(t, ops) | Rvalue::ListLit(t, ops) => {
                if matches!(t, Type::RegionList(..)) {
                    return self.fail("literal de lista regional sin región");
                }
                let Some(elem) = self.module.elem_of(*t) else {
                    return self.fail(format!("literal de colección con tipo {t:?}"));
                };
                if let Type::Array(a) = t
                    && self.module.arrays[*a].len != ops.len()
                {
                    return self.fail("número de elementos distinto de la longitud del array");
                }
                for o in ops {
                    if let Type::SharedField(target) | Type::MutField(target) = elem {
                        let Operand::Var(source) = o else {
                            return self
                                .fail("el elemento prestado requiere una variable de préstamo");
                        };
                        if self.var(*source)? != VarTy::Ref(target.referent()) {
                            return self.fail("referente incorrecto para el elemento prestado");
                        }
                    } else {
                        self.collection_element(*t, elem, self.value_operand(o)?)?;
                    }
                }
                VarTy::Value(*t)
            }
            Rvalue::Len(p) => match self.place(p)? {
                Type::Text
                | Type::Array(_)
                | Type::Slice(_)
                | Type::List(_)
                | Type::RegionList(..)
                | Type::TaskGroup(_) => VarTy::Value(Type::Int),
                t => return self.fail(format!("length de {t:?}")),
            },
            Rvalue::Cap(p) => match self.place(p)? {
                Type::List(_) | Type::RegionList(..) | Type::TaskGroup(_) => {
                    VarTy::Value(Type::Int)
                }
                t => return self.fail(format!("capacity de {t:?}")),
            },
            Rvalue::ListTakeLast(p) => match self.place(p)? {
                t @ (Type::List(_) | Type::RegionList(..) | Type::TaskGroup(_)) => {
                    VarTy::Value(self.module.elem_of(t).expect("list"))
                }
                t => return self.fail(format!("pop de {t:?}")),
            },
            Rvalue::ListPop(p, opt_ty) => {
                let list_ty = self.place(p)?;
                let Some(elem) = self.module.elem_of(list_ty) else {
                    return self.fail("pop de no-lista");
                };
                let Type::Enum(e) = opt_ty else {
                    return self.fail("resultado de listpop debe ser un enum (Option)");
                };
                let Some(enum_decl) = self.module.enums.get(*e) else {
                    return self.fail("enum inexistente");
                };
                if enum_decl.variants.len() != 2
                    || !enum_decl.variants[0].1.is_empty()
                    || enum_decl.variants[1].1.as_slice() != [elem]
                {
                    return self.fail("enum no compatible con Option<T>");
                }
                VarTy::Value(*opt_ty)
            }
            Rvalue::BytesGet(p, i) => {
                if !matches!(self.place(p)?, Type::Bytes(_) | Type::Text) {
                    return self.fail("lectura de byte sobre algo que no es Bytes o Text");
                }
                self.expect(Type::Int, self.value_operand(i)?, "índice")?;
                VarTy::Value(Type::Int)
            }
            Rvalue::Convert(op, target) => {
                let t = self.value_operand(op)?;
                if !matches!(t, Type::Int | Type::Float | Type::F32)
                    || !matches!(target, Type::Int | Type::Float | Type::F32)
                {
                    return self.fail(format!("conversión no soportada de {t:?} a {target:?}"));
                }
                VarTy::Value(*target)
            }
        })
    }
    fn formattable(&self, arg: &Arg) -> Result<(), VerifyError> {
        let t = match arg {
            Arg::Value(op) => self.value_operand(op)?,
            Arg::Ref(p, false) => self.place(p)?,
            Arg::Ref(_, true) => return self.fail("préstamo exclusivo para formatear"),
        };
        if matches!(
            t,
            Type::Int | Type::Float | Type::F32 | Type::Bool | Type::Text
        ) {
            Ok(())
        } else {
            self.fail(format!("{t:?} no se puede formatear"))
        }
    }
    fn target(&self, b: BlockId) -> Result<(), VerifyError> {
        if b < self.func.blocks.len() {
            Ok(())
        } else {
            self.fail(format!("salto a bloque inexistente b{b}"))
        }
    }
}

/// A place reads its root variable and every index variable in it.
fn place_uses(p: &Place, out: &mut Vec<VarId>) {
    out.push(p.var);
    for proj in &p.proj {
        if let Proj::Index(i) = proj {
            out.push(*i);
        }
    }
}
fn arg_uses(arg: &Arg, out: &mut Vec<VarId>) {
    match arg {
        Arg::Value(Operand::Var(v)) => out.push(*v),
        Arg::Ref(p, _) => place_uses(p, out),
        Arg::Value(Operand::Const(_)) => {}
    }
}
fn operand_uses(op: &Operand, out: &mut Vec<VarId>) {
    if let Operand::Var(v) = op {
        out.push(*v);
    }
}
/// Variables read by an instruction, and the variable it (re)defines.
pub(crate) fn uses_defs(kind: &InstKind) -> (Vec<VarId>, Option<VarId>) {
    let mut uses = Vec::new();
    let def = match kind {
        InstKind::Assign(d, rv) => {
            match rv {
                Rvalue::Use(o) | Rvalue::Unary(_, o) | Rvalue::Convert(o, _) => {
                    operand_uses(o, &mut uses)
                }
                Rvalue::Binary(_, a, b) => {
                    operand_uses(a, &mut uses);
                    operand_uses(b, &mut uses);
                }
                Rvalue::Call(_, args) | Rvalue::Platform(_, args, _) => {
                    args.iter().for_each(|a| arg_uses(a, &mut uses))
                }
                Rvalue::Struct(_, ops) | Rvalue::Variant(_, _, ops) => {
                    ops.iter().for_each(|o| operand_uses(o, &mut uses))
                }
                Rvalue::FutureNew(_) | Rvalue::GroupPending | Rvalue::TimerPending => {}
                Rvalue::CheckSleep(ms) | Rvalue::TimerStart(ms) => operand_uses(ms, &mut uses),
                Rvalue::TaskSpawn(o, _) => operand_uses(o, &mut uses),
                Rvalue::TaskReady(p) | Rvalue::TaskState(p) | Rvalue::GroupRegister(p) => {
                    place_uses(p, &mut uses)
                }
                Rvalue::FutureState(p)
                | Rvalue::FuturePoll(p)
                | Rvalue::Read(p)
                | Rvalue::Ref(p)
                | Rvalue::Loan(p, ..)
                | Rvalue::FieldLoan(p)
                | Rvalue::Discriminant(p)
                | Rvalue::TextEq(p, _)
                | Rvalue::Len(p)
                | Rvalue::Cap(p)
                | Rvalue::ListTakeLast(p)
                | Rvalue::ListPop(p, _) => place_uses(p, &mut uses),
                Rvalue::ArrayLit(_, ops) | Rvalue::ListLit(_, ops) => {
                    ops.iter().for_each(|o| operand_uses(o, &mut uses))
                }
                Rvalue::TextBuffer(_) | Rvalue::RegionNew(_) => {}
                Rvalue::RegionList(p, _) => place_uses(p, &mut uses),
                Rvalue::RegionBytes(p, o) | Rvalue::BytesGet(p, o) => {
                    place_uses(p, &mut uses);
                    operand_uses(o, &mut uses);
                }
                Rvalue::BytesLen(p) => place_uses(p, &mut uses),
            }
            Some(*d)
        }
        InstKind::BytesSet(p, i, b) => {
            place_uses(p, &mut uses);
            operand_uses(i, &mut uses);
            operand_uses(b, &mut uses);
            None
        }
        InstKind::ListPush(p, o) | InstKind::ListReserve(p, o) => {
            place_uses(p, &mut uses);
            operand_uses(o, &mut uses);
            None
        }
        InstKind::Store(p, o) => {
            place_uses(p, &mut uses);
            operand_uses(o, &mut uses);
            None
        }
        InstKind::Append(v, a) => {
            uses.push(*v);
            arg_uses(a, &mut uses);
            None
        }
        InstKind::Print(a) => {
            arg_uses(a, &mut uses);
            None
        }
        // Whether a dropped or moved variable holds a value is checked by the
        // ownership verifier (`drops::verify`), which also covers flags.
        InstKind::Drop(_, flag) | InstKind::DropField(_, flag) => {
            uses.extend(flag.iter().copied());
            None
        }
        InstKind::Clear(p) => {
            place_uses(p, &mut uses);
            None
        }
        // Notifying and running the scheduler touch tasks, not variables.
        InstKind::Wake | InstKind::RunTasks => None,
        InstKind::Moved(_) => None,
    };
    (uses, def)
}

pub(crate) fn successors(term: &Terminator) -> Vec<BlockId> {
    match term {
        Terminator::Jump(b) => vec![*b],
        Terminator::Branch(_, t, e) => vec![*t, *e],
        Terminator::Return(_)
        | Terminator::ReturnRef(..)
        | Terminator::Suspend(_)
        | Terminator::Unreachable => Vec::new(),
    }
}

/// Checks structure (terminators, jump targets), types of every instruction
/// and terminator, call signatures, and that every variable is assigned on
/// every path before it is read.
pub fn verify(module: &Module) -> Result<(), VerifyError> {
    if module.funcs.get(module.main).is_none() {
        return Err(VerifyError {
            func: "<módulo>".into(),
            block: 0,
            message: "función main inexistente".into(),
        });
    }
    let ownership = crate::drops::Ownership::new(
        &module.structs,
        &module.enums,
        &module.arrays,
        &module.lists,
    );
    for func in &module.funcs {
        verify_func(module, func)?;
        crate::drops::verify(func, &ownership).map_err(|e| VerifyError {
            func: func.name.clone(),
            block: e.block,
            message: e.message,
        })?;
    }
    crate::async_state::verify(module, &ownership)
}

fn verify_func(module: &Module, func: &Func) -> Result<(), VerifyError> {
    let mut v = Verifier {
        module,
        func,
        block: 0,
    };
    if func.blocks.is_empty() {
        return v.fail("función sin bloques");
    }
    if matches!(func.result, Type::RegionList(..)) {
        return v.fail("una función no puede devolver una lista regional");
    }
    for &p in &func.params {
        if matches!(v.var(p)?.pointee(), Type::RegionList(..)) {
            return v.fail("use un slice para prestar una lista regional a otra función");
        }
    }
    if let Some(contract) = &func.borrow_return
        && (contract.params.is_empty()
            || contract.params.windows(2).any(|pair| pair[0] >= pair[1])
            || contract.params.iter().any(|&i| {
                !matches!(
                    func.params.get(i).and_then(|p| func.vars.get(*p)),
                    Some(VarTy::Ref(_))
                )
            }))
    {
        return v.fail("contrato de retorno prestado con orígenes inválidos");
    }
    if let Some(contract) = &func.view_return
        && contract.params.iter().any(|&i| {
            !matches!(
                func.params.get(i).and_then(|p| func.vars.get(*p)),
                Some(VarTy::Ref(_))
            )
        })
    {
        return v.fail("contrato de retorno de vista con parámetros inválidos");
    }
    for (id, block) in func.blocks.iter().enumerate() {
        v.block = id;
        for inst in &block.insts {
            match &inst.kind {
                InstKind::Assign(dest, rv) => {
                    let t = v.rvalue(rv)?;
                    let d = v.var(*dest)?;
                    let compatible = match (d, t) {
                        (VarTy::Value(Type::Future(a)), VarTy::Value(Type::Future(b))) => {
                            match (v.module.futures.get(a), v.module.futures.get(b)) {
                                (Some(fa), Some(fb)) => fa.result == fb.result,
                                _ => false,
                            }
                        }
                        _ => d == t,
                    };
                    if !compatible {
                        return v.fail(format!("asignación a v{dest}: {d:?} ← {t:?}"));
                    }
                }
                InstKind::Store(p, op) => {
                    if p.proj.is_empty() && matches!(v.var(p.var)?, VarTy::Value(_)) {
                        return v.fail("Store requiere un lugar proyectado; use Assign");
                    }
                    let target = v.place(p)?;
                    if matches!(target, Type::SharedField(_) | Type::MutField(_)) {
                        return v.fail("un campo prestado tiene un origen fijo");
                    }
                    v.expect(target, v.value_operand(op)?, "Store")?;
                }
                InstKind::Clear(p) => {
                    v.place(p)?;
                }
                InstKind::Wake | InstKind::RunTasks => {}
                InstKind::Append(t, arg) => {
                    v.expect(Type::Text, v.var(*t)?.pointee(), "destino de Append")?;
                    v.formattable(arg)?;
                }
                InstKind::Print(arg) => v.formattable(arg)?,
                InstKind::ListPush(p, o) => match v.place(p)? {
                    t @ (Type::List(_) | Type::RegionList(..)) => {
                        let elem = v.module.elem_of(t).expect("list");
                        if let Type::SharedField(target) | Type::MutField(target) = elem {
                            let Operand::Var(source) = o else {
                                return v.fail("push prestado requiere una variable de préstamo");
                            };
                            if v.var(*source)? != VarTy::Ref(target.referent()) {
                                return v.fail("referente incorrecto para push prestado");
                            }
                        } else {
                            v.collection_element(t, elem, v.value_operand(o)?)?;
                        }
                    }
                    Type::TaskGroup(g) => {
                        let elem = v.module.task_groups[g].elem;
                        let actual = v.value_operand(o)?;
                        if let Type::Task(task) = actual {
                            let expected = v.module.futures[task].result;
                            if expected != elem {
                                return v.fail("resultado de tarea incompatible con el grupo");
                            }
                        } else {
                            return v.fail("push en TaskGroup requiere un TaskHandle");
                        }
                    }
                    t => return v.fail(format!("push sobre {t:?}")),
                },
                InstKind::ListReserve(p, o) => {
                    if !matches!(
                        v.place(p)?,
                        Type::List(_) | Type::RegionList(..) | Type::TaskGroup(_)
                    ) {
                        return v.fail("reserve sobre algo que no es List");
                    }
                    v.expect(Type::Int, v.value_operand(o)?, "reserve")?;
                }
                InstKind::BytesSet(p, i, b) => {
                    if !matches!(v.place(p)?, Type::Bytes(_)) {
                        return v.fail("set() sobre algo que no es Bytes");
                    }
                    v.expect(Type::Int, v.value_operand(i)?, "índice")?;
                    v.expect(Type::Int, v.value_operand(b)?, "byte")?;
                }
                InstKind::Drop(var, flag) => {
                    if !matches!(v.var(*var)?, VarTy::Value(_)) {
                        return v.fail(format!("drop de un préstamo v{var}"));
                    }
                    if let Some(f) = flag {
                        v.expect(Type::Bool, v.var(*f)?.pointee(), "drop flag")?;
                    }
                }
                InstKind::DropField(place, flag) => {
                    if place.proj.is_empty() || !v.place(place)?.is_move() {
                        return v.fail("DropField requiere un campo propietario");
                    }
                    if let Some(f) = flag {
                        v.expect(Type::Bool, v.var(*f)?.pointee(), "drop flag")?;
                    }
                }
                InstKind::Moved(var) => {
                    v.var(*var)?;
                }
            }
        }
        match &block.term {
            None => return v.fail("bloque sin terminador"),
            Some(Terminator::Jump(b)) => v.target(*b)?,
            Some(Terminator::Branch(c, t, e)) => {
                v.expect(Type::Bool, v.value_operand(c)?, "condición de salto")?;
                v.target(*t)?;
                v.target(*e)?;
            }
            Some(Terminator::Return(op)) => {
                if func.borrow_return.is_some() {
                    return v.fail("retorno por valor en función con retorno prestado");
                }
                v.expect(func.result, v.value_operand(op)?, "retorno")?
            }
            Some(Terminator::ReturnRef(var, _)) => {
                if func.borrow_return.is_none() {
                    return v.fail("retorno prestado sin contrato");
                }
                if v.var(*var)? != VarTy::Ref(func.result) {
                    return v.fail("retorno prestado con tipo inválido");
                }
            }
            Some(Terminator::Suspend(resume)) => {
                v.target(*resume)?;
                if !module.futures.iter().any(|info| {
                    module
                        .funcs
                        .get(info.poll)
                        .is_some_and(|poll| std::ptr::eq(poll, func))
                }) {
                    return v.fail("suspensión fuera de un poll");
                }
            }
            Some(Terminator::Unreachable) => {}
        }
    }
    verify_definite_assignment(&mut v)
}

/// Forward "must be assigned" dataflow over reachable blocks.
fn verify_definite_assignment(v: &mut Verifier) -> Result<(), VerifyError> {
    let func = v.func;
    let n = func.blocks.len();
    let all: HashSet<VarId> = (0..func.vars.len()).collect();
    let mut reachable = vec![false; n];
    let mut stack = vec![0];
    while let Some(b) = stack.pop() {
        if std::mem::replace(&mut reachable[b], true) {
            continue;
        }
        if let Some(t) = &func.blocks[b].term {
            stack.extend(successors(t));
        }
    }
    let mut preds = vec![Vec::new(); n];
    for (b, block) in func.blocks.iter().enumerate() {
        if reachable[b]
            && let Some(t) = &block.term
        {
            for s in successors(t) {
                preds[s].push(b);
            }
        }
    }
    let assigned = |b: usize, input: &HashSet<VarId>| -> HashSet<VarId> {
        let mut set = input.clone();
        for inst in &func.blocks[b].insts {
            if let (_, Some(d)) = uses_defs(&inst.kind) {
                set.insert(d);
            }
        }
        set
    };
    let entry: HashSet<VarId> = func.params.iter().copied().collect();
    let mut out: Vec<HashSet<VarId>> = vec![all.clone(); n];
    let mut changed = true;
    while changed {
        changed = false;
        for b in 0..n {
            if !reachable[b] {
                continue;
            }
            let input = input_of(b, &entry, &preds, &out, &all);
            let new = assigned(b, &input);
            if new != out[b] {
                out[b] = new;
                changed = true;
            }
        }
    }
    for (b, _) in reachable.iter().enumerate().filter(|(_, r)| **r) {
        v.block = b;
        let mut set = input_of(b, &entry, &preds, &out, &all);
        let check = |set: &HashSet<VarId>, vars: Vec<VarId>, v: &Verifier| {
            for var in vars {
                if !set.contains(&var) {
                    return v.fail(format!("v{var} se usa antes de asignarse en alguna ruta"));
                }
            }
            Ok(())
        };
        for inst in &func.blocks[b].insts {
            let (uses, def) = uses_defs(&inst.kind);
            check(&set, uses, v)?;
            if let Some(d) = def {
                set.insert(d);
            }
        }
        let mut uses = Vec::new();
        match &func.blocks[b].term {
            Some(Terminator::Branch(c, _, _)) => operand_uses(c, &mut uses),
            Some(Terminator::Return(o)) => operand_uses(o, &mut uses),
            Some(Terminator::ReturnRef(v, _)) => uses.push(*v),
            _ => {}
        }
        check(&set, uses, v)?;
    }
    Ok(())
}

fn input_of(
    b: usize,
    entry: &HashSet<VarId>,
    preds: &[Vec<usize>],
    out: &[HashSet<VarId>],
    all: &HashSet<VarId>,
) -> HashSet<VarId> {
    if b == 0 {
        // The entry block may also be a loop target; params are always set.
        let mut set = entry.clone();
        if !preds[0].is_empty() {
            let mut inter = all.clone();
            for p in &preds[0] {
                inter.retain(|v| out[*p].contains(v));
            }
            set.retain(|v| inter.contains(v) || entry.contains(v));
        }
        return set;
    }
    let mut inter: Option<HashSet<VarId>> = None;
    for p in &preds[b] {
        inter = Some(match inter {
            None => out[*p].clone(),
            Some(s) => s.intersection(&out[*p]).copied().collect(),
        });
    }
    inter.unwrap_or_default()
}
