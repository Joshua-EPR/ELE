//! Typed, structured LIR shared by semantic analysis and native backends.
//! Identifiers are resolved; lexical blocks and loop control remain explicit.
//! Nothing here refers to Rust or to any particular backend.
use crate::Span;
use std::collections::HashSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Type {
    Int,
    Float,
    F32,
    Bool,
    Text,
    Unit,
    /// Pointer stored in a local view, never a source-level value type.
    SharedField(SharedTarget),
    MutField(SharedTarget),
    /// Index into `Program::structs`.
    Struct(usize),
    /// Index into `Program::enums`. Generic enums are monomorphized: every
    /// instantiation (e.g. `Option<Int>`) is a distinct concrete enum.
    Enum(usize),
    /// A memory region (`region nombre { ... }`), identified by its lexical
    /// region id. Owns every block it allocated; never moved or copied.
    Region(usize),
    /// A zero-initialized byte buffer allocated in region `id`. A view into the
    /// region's storage: it owns nothing and cannot outlive the region, so it
    /// may only live in locals of that region or behind a reference parameter
    /// (`CALLER_REGION`).
    Bytes(usize),
    /// Index into `Program::arrays`: `[T; N]`, N elements stored contiguously.
    Array(usize),
    /// Index into `Program::slices`: `[T]`, a view of contiguous elements. Only
    /// ever behind a reference parameter (`&[T]`, `&mut [T]`).
    Slice(usize),
    /// Index into `Program::lists`: `List<T>`, a growable owned buffer.
    List(usize),
    RegionList(usize, usize), // element table index, lexical region id
    /// Index into `Program::futures`: the result of calling an `async fn`. An
    /// owned handle to the task's state; every async function has its own
    /// future type (the type is opaque, like the state machine it names).
    Future(usize),
    /// Index into `Program::futures`: `TaskHandle<T>` of a task registered in
    /// the cooperative scheduler by `spawn`. An owned, non-copyable handle:
    /// awaiting it yields the result, dropping it cancels the task.
    Task(usize),
    /// Index into `Program::task_groups`: `TaskGroup<T>` tied to a scope.
    /// An owned, structured group of tasks that yield `T`.
    TaskGroup(usize),
}
/// Referents supported by local shared views in this increment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SharedTarget {
    Int,
    Float,
    F32,
    Bool,
    Text,
    Struct(usize),
    Enum(usize),
    Array(usize),
}

impl SharedTarget {
    pub fn from_type(ty: Type) -> Option<Self> {
        Some(match ty {
            Type::Int => Self::Int,
            Type::Float => Self::Float,
            Type::F32 => Self::F32,
            Type::Bool => Self::Bool,
            Type::Text => Self::Text,
            Type::Struct(id) => Self::Struct(id),
            Type::Enum(id) => Self::Enum(id),
            Type::Array(id) => Self::Array(id),
            _ => return None,
        })
    }
    pub fn referent(self) -> Type {
        match self {
            Self::Int => Type::Int,
            Self::Float => Type::Float,
            Self::F32 => Type::F32,
            Self::Bool => Type::Bool,
            Self::Text => Type::Text,
            Self::Struct(id) => Type::Struct(id),
            Self::Enum(id) => Type::Enum(id),
            Self::Array(id) => Type::Array(id),
        }
    }
}

/// The future type of one `async fn`: what its result is and which function
/// builds it. Two async functions never share a future type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FutureDef {
    pub result: Type,
    /// Index into `Program::functions` of the async function.
    pub func: usize,
    /// Display name, e.g. `Future<Int> (de obtenerNumero)`.
    pub name: String,
}

/// A fixed-size array type `[elem; len]`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ArrayDef {
    pub elem: Type,
    pub len: usize,
}
/// Definition of a scoped task group: task result type `elem`, and lexical scope `scope`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TaskGroupDef {
    pub elem: Type,
    pub scope: usize,
}
/// Region id of a `&Bytes`/`&mut Bytes` parameter: some region of a caller,
/// which strictly outlives the call.
pub const CALLER_REGION: usize = usize::MAX;
impl Type {
    /// Values of these types are owned resources: assignment and by-value
    /// passing move them. Primitive scalars are `Copy`.
    pub fn is_move(self) -> bool {
        matches!(
            self,
            Type::Text
                | Type::Struct(_)
                | Type::Enum(_)
                | Type::Region(_)
                | Type::Bytes(_)
                | Type::Array(_)
                | Type::List(_)
                | Type::RegionList(..)
                | Type::Future(_)
                | Type::Task(_)
                | Type::TaskGroup(_)
        )
    }
    /// Owned types whose moved subtrees may be cleared to zero in a Future.
    pub(crate) fn async_owned<'a>(
        self,
        fields: &impl Fn(usize) -> &'a [(String, Type)],
        variants: &impl Fn(usize) -> &'a [(String, Vec<Type>)],
        arrays: &[ArrayDef],
        lists: &[Type],
        task_groups: &[TaskGroupDef],
    ) -> bool {
        fn storable<'a>(
            ty: Type,
            fields: &impl Fn(usize) -> &'a [(String, Type)],
            variants: &impl Fn(usize) -> &'a [(String, Vec<Type>)],
            arrays: &[ArrayDef],
            lists: &[Type],
            task_groups: &[TaskGroupDef],
            cache: &mut std::collections::HashMap<Type, bool>,
        ) -> bool {
            if let Some(result) = cache.get(&ty) {
                return *result;
            }
            // A cycle is conservatively ineligible.
            cache.insert(ty, false);
            let mut child = |ty| storable(ty, fields, variants, arrays, lists, task_groups, cache);
            let result = match ty {
                Type::Int | Type::Float | Type::F32 | Type::Bool | Type::Unit | Type::Text => true,
                Type::Struct(id) => fields(id).iter().all(|(_, ty)| child(*ty)),
                Type::Enum(id) => variants(id)
                    .iter()
                    .flat_map(|(_, payload)| payload)
                    .all(|ty| child(*ty)),
                Type::Array(id) => child(arrays[id].elem),
                Type::List(id) => child(lists[id]),
                Type::TaskGroup(id) => child(task_groups[id].elem),
                _ => false,
            };
            cache.insert(ty, result);
            result
        }
        self == Type::Text
            || (self.is_move()
                && storable(
                    self,
                    fields,
                    variants,
                    arrays,
                    lists,
                    task_groups,
                    &mut Default::default(),
                ))
    }

    /// Types tied to a region's lifetime: they must never escape it.
    pub fn is_region_bound(self) -> bool {
        matches!(
            self,
            Type::Region(_) | Type::Bytes(_) | Type::RegionList(..)
        )
    }
}

#[derive(Debug, Clone)]
pub struct Value {
    pub ty: Type,
    pub span: Span,
    pub kind: ValueKind,
}

/// A memory location rooted at a local binding, optionally projected through
/// struct fields (`root.f0.f1`). Field entries are indices into the struct
/// definition of the previous step.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Place {
    pub root: usize,
    pub fields: Vec<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Receiver {
    /// `fn` in `impl`: implicit shared borrow of the receiver.
    Shared,
    /// `mut fn` in `impl`: implicit exclusive borrow of the receiver.
    Exclusive,
}

/// Pattern tested against a value of a statically known type.
#[derive(Debug, Clone, PartialEq)]
pub enum Pattern {
    /// `_`: matches anything, binds nothing.
    Wild,
    /// Identifier pattern: matches anything and binds it to a local.
    Bind(usize),
    Int(i64),
    Bool(bool),
    Text(String),
    /// Enum id, variant index (= discriminant), payload sub-patterns.
    Variant(usize, usize, Vec<Pattern>),
}

/// One `match` arm. Bindings are introduced by the pattern for `body` and
/// `value` only.
#[derive(Debug, Clone)]
pub struct Arm {
    pub pattern: Pattern,
    /// Locals bound by `pattern`, with their types.
    pub bindings: Vec<(usize, Type)>,
    pub body: Vec<Instruction>,
    /// Arm result when the match is used as a value and the arm completes.
    pub value: Option<Value>,
    /// The arm never completes normally (return/break/continue on every path).
    pub diverges: bool,
}

#[derive(Debug, Clone)]
pub enum ValueKind {
    Platform(PlatformOp, Vec<Value>),
    Int(i64),
    Float(f64),
    Bool(bool),
    Text(String),
    Interpolate(Vec<Value>),
    Unit,
    Local(usize),
    Call(usize, Vec<Value>),
    /// Method call: function id, receiver place (borrowed, never moved),
    /// borrow kind and by-value arguments evaluated left to right before the
    /// receiver borrow is activated.
    MethodCall(usize, Place, Receiver, Vec<Value>),
    /// Method call on a temporary receiver value (shared borrow only).
    TempMethodCall(usize, Box<Value>, Vec<Value>),
    /// Struct construction. Field initializers in evaluation order:
    /// call-site order first, then declaration defaults.
    Construct(usize, Vec<(usize, Value)>),
    /// Enum construction: enum id, variant index, payload in order.
    Variant(usize, usize, Vec<Value>),
    /// Explicit borrow `&place` (exclusive=false) or `&mut place` (exclusive=true).
    Borrow(Place, bool),
    /// Field read `base.field`.
    Field(Box<Value>, usize),
    /// Pointer initializer for a shared view field.
    StoredBorrow(Box<Value>),
    /// Read through a view field, without moving its referent.
    SharedField(Box<Value>, usize),
    /// Evaluates the scrutinee exactly once, then runs the first arm whose
    /// pattern matches (arms are exhaustive and reachable by construction).
    Match(Box<Value>, Vec<Arm>),
    Print(Box<Value>),
    Unary(String, Box<Value>),
    Binary(String, Box<Value>, Box<Value>),
    Convert(Box<Value>, Type),
    /// Opens the region bound by the enclosing `Bind` (allocates nothing).
    RegionNew,
    /// `region.bytes(n)`: `n` zeroed bytes, 8-aligned, from the region.
    RegionBytes(Place, Box<Value>),
    RegionList(Place),
    /// `buffer.len()`.
    BytesLen(Place),
    /// `buffer.get(i)`: byte `i` as Int (0..=255); panics out of bounds.
    BytesGet(Place, Box<Value>),
    /// `buffer.set(i, v)`: panics out of bounds or if `v` is not 0..=255.
    BytesSet(Place, Box<Value>, Box<Value>),
    /// `[a, b, c]`: elements evaluated left to right.
    ArrayLit(Vec<Value>),
    /// `List[a, b, c]`: elements evaluated left to right; capacity = length.
    ListLit(Vec<Value>),
    /// `base[index]`: bounds-checked element access. `base` denotes a place (a
    /// local, field or element) or a temporary collection. Reading yields a copy
    /// of a Copy element; a non-Copy element can only be borrowed.
    Index(Box<Value>, Box<Value>),
    /// `.length` of an array, slice or list.
    Length(Box<Value>),
    /// Read one unsigned UTF-8 byte without consuming the Text.
    TextByte(Box<Value>, Box<Value>),
    /// `.capacity` of a list.
    Capacity(Box<Value>),
    /// `lista.push(v)`; the list is a place.
    ListPush(Box<Value>, Box<Value>),
    /// `lista.pop()` -> `Option<T>`: list place, Option enum id, Some and None
    /// variant indices.
    ListPop(Box<Value>, usize, usize, usize),
    /// `lista.reserve(n)`: at least `n` more elements without reallocating.
    ListReserve(Box<Value>, Box<Value>),
    /// `await f`: consumes the future and yields its result, suspending the
    /// enclosing async function while the future is pending. The operand is a
    /// `Future<T>` (polled in place) or a `TaskHandle<T>` (driven by the
    /// scheduler, which wakes this task when the other one finishes).
    Await(Box<Value>),
    /// Consumes two scoped task handles and suspends until both results exist.
    /// The result is an inferred struct with fields first and second.
    Join(Box<[Value; 2]>),
    /// Consumes a scoped List of task handles and waits for the whole group.
    JoinAll(Box<Value>),
    /// `spawn f(args)`: consumes the future of the inner call and registers it
    /// as an independent task of the cooperative scheduler. The result is the
    /// `TaskHandle<T>` that owns it.
    Spawn(Box<Value>),
}

/// The small synchronous platform interface available to L programs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlatformOp {
    ArgCount,
    Arg,
    ReadText,
    PrintError,
    /// writeBytes(path: Text, bytes: List<Int>) -> Int; zero on success.
    /// The list is borrowed, not consumed. Each element must be in 0..=255.
    WriteBytes,
}

impl PlatformOp {
    pub fn named(name: &str) -> Option<Self> {
        Some(match name {
            "processArgCount" => Self::ArgCount,
            "processArg" => Self::Arg,
            "readText" => Self::ReadText,
            "printError" => Self::PrintError,
            "writeBytes" => Self::WriteBytes,
            _ => return None,
        })
    }

    pub fn params(self) -> &'static [Type] {
        match self {
            Self::ArgCount => &[],
            Self::Arg => &[Type::Int],
            Self::ReadText => &[Type::Text, Type::Int],
            Self::PrintError => &[Type::Text],
            // Dynamic List<Int> type index is resolved by the type checker.
            // This operation is checked separately in sema and cfg::verify.
            Self::WriteBytes => &[],
        }
    }
}
pub(crate) const SLEEP_MS: &str = "sleepMs";
pub(crate) const MAX_SLEEP_MS: i64 = i64::MAX / 10_000;
pub(crate) const INVALID_SLEEP: &str = "duración de sleepMs fuera de rango";

#[derive(Debug, Clone)]
pub enum Instruction {
    /// A local reference with a fixed origin and access mode.
    BindRef(usize, Receiver, Type, Value),
    Bind(usize, bool, Value),
    Store(Place, Value),
    Eval(Value),
    Return(Value),
    ReturnRef(Receiver, Value),
    If(Value, Vec<Instruction>, Vec<Instruction>),
    While(Value, Vec<Instruction>),
    /// `for id in start..end` (or `..=` when inclusive). Bounds are evaluated
    /// once, start before end. The induction variable is a fresh immutable Int
    /// per iteration; stepping never overflows (the loop ends at the bound).
    ForRange(usize, Value, Value, bool, Vec<Instruction>),
    /// `for x in colección`: binding, whether it borrows (non-Copy elements)
    /// instead of copying, the iterated collection place, body. The collection
    /// cannot be mutated or moved while the loop runs.
    ForEach(usize, bool, Value, Vec<Instruction>),
    /// `colección[i] = v` (or a field below an element): target place value,
    /// new value. The value is evaluated first, then the index; the replaced
    /// element is dropped.
    StoreElem(Value, Value),
    Loop(Vec<Instruction>),
    /// Suspension point of an async function with no future to wait for: the
    /// task is notified immediately and resumes on the next poll. The only
    /// producer is the built-in `yieldNow`.
    Yield,
    /// Suspend until a monotonic deadline. Only emitted for sleepMs.
    Sleep(Value),
    Break,
    Continue,
    Block(Vec<Instruction>),
}
/// Conservative set of parameters borrowed for the life of the result.
/// Parameter indices include the receiver, when present.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BorrowReturn {
    pub params: Vec<usize>,
    pub mode: Receiver,
}

/// A symbolic projection of an origin within a parameter or value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum EscapeProjection {
    Field(usize),
    Payload(usize, usize),
    Indexed,
}

/// A contract for an individual field of a view returned by value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FieldContract {
    pub field_index: usize,
    pub mode: Receiver,
    pub params: Vec<usize>,
    pub projections: Vec<(usize, Vec<EscapeProjection>)>,
}

/// Conservative set of parameters and field-level projections borrowed by a returned view aggregate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ViewReturn {
    pub params: Vec<usize>,
    pub fields: Vec<FieldContract>,
}

#[derive(Debug)]
pub struct Function {
    pub name: String,
    /// `async fn`: the body is a state machine; callers get `Future<result>`.
    pub is_async: bool,
    /// For methods with `self`: (local id of `self`, receiver type, borrow kind).
    pub receiver: Option<(usize, Type, Receiver)>,
    pub params: Vec<(usize, Type)>,
    pub param_modes: Vec<Option<Receiver>>,
    pub result: Type,
    pub borrow_return: Option<BorrowReturn>,
    pub view_return: Option<ViewReturn>,
    pub body: Vec<Instruction>,
    /// Pattern bindings of owned (non-Copy) type that take ownership of their
    /// part of the scrutinee. Every other owned pattern binding is a shared
    /// borrow into the scrutinee. Filled by the ownership pass.
    pub by_value_bindings: HashSet<usize>,
    /// Verified inferred and allowed effects of this function.
    pub effects: crate::effects::EffectSet,
}
#[derive(Debug, Clone)]
pub struct StructDef {
    pub name: String,
    pub fields: Vec<(String, Type)>,
}
/// Concrete (monomorphized) enum. The discriminant of a variant is its index.
#[derive(Debug, Clone)]
pub struct EnumDef {
    /// Display name, including type arguments (`Option<Int>`).
    pub name: String,
    pub variants: Vec<(String, Vec<Type>)>,
}
#[derive(Debug)]
pub struct Program {
    pub structs: Vec<StructDef>,
    pub enums: Vec<EnumDef>,
    pub arrays: Vec<ArrayDef>,
    /// Element type of each slice type.
    pub slices: Vec<Type>,
    /// Element type of each list type.
    pub lists: Vec<Type>,
    /// Future type of each async function, in declaration order of use.
    pub futures: Vec<FutureDef>,
    /// TaskGroup definitions tied to an async scope.
    pub task_groups: Vec<TaskGroupDef>,
    pub functions: Vec<Function>,
    pub main: usize,
}
