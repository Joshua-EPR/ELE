//! Static effect system, inference, interprocedural analysis, and `@noalloc` verification.

use crate::lir::{Function, Instruction, Program, Type, Value, ValueKind};
use crate::{Diagnostic, Span};
use std::collections::{HashMap, HashSet, VecDeque};

/// Individual observable effect tracked by the static effect system.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Effect {
    /// Dynamic memory allocation (heap).
    Alloc,
    /// External I/O (stdout, files, network, hardware).
    Io,
    /// Possible panic or unrecoverable termination (e.g. checked integer overflow).
    Panic,
    /// Thread blocking.
    Block,
}

impl Effect {
    pub fn name(self) -> &'static str {
        match self {
            Effect::Alloc => "alloc",
            Effect::Io => "io",
            Effect::Panic => "panic",
            Effect::Block => "block",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            Effect::Alloc => "solicitud o reserva de memoria dinámica (heap)",
            Effect::Io => "operación de entrada/salida externa",
            Effect::Panic => "posible terminación por pánico o fallo irrecuperable",
            Effect::Block => "posible bloqueo del hilo de ejecución",
        }
    }
}

/// Bitset of effects.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct EffectSet {
    pub alloc: bool,
    pub io: bool,
    pub panic: bool,
    pub block: bool,
}

impl EffectSet {
    pub const EMPTY: EffectSet = EffectSet {
        alloc: false,
        io: false,
        panic: false,
        block: false,
    };

    pub const ALL: EffectSet = EffectSet {
        alloc: true,
        io: true,
        panic: true,
        block: true,
    };

    pub fn insert(&mut self, effect: Effect) {
        match effect {
            Effect::Alloc => self.alloc = true,
            Effect::Io => self.io = true,
            Effect::Panic => self.panic = true,
            Effect::Block => self.block = true,
        }
    }

    pub fn contains(&self, effect: Effect) -> bool {
        match effect {
            Effect::Alloc => self.alloc,
            Effect::Io => self.io,
            Effect::Panic => self.panic,
            Effect::Block => self.block,
        }
    }

    pub fn union(&self, other: EffectSet) -> EffectSet {
        EffectSet {
            alloc: self.alloc || other.alloc,
            io: self.io || other.io,
            panic: self.panic || other.panic,
            block: self.block || other.block,
        }
    }

    pub fn is_subset_of(&self, other: EffectSet) -> bool {
        (!self.alloc || other.alloc)
            && (!self.io || other.io)
            && (!self.panic || other.panic)
            && (!self.block || other.block)
    }

    pub fn difference(&self, other: EffectSet) -> Vec<Effect> {
        let mut diff = Vec::new();
        if self.alloc && !other.alloc {
            diff.push(Effect::Alloc);
        }
        if self.io && !other.io {
            diff.push(Effect::Io);
        }
        if self.panic && !other.panic {
            diff.push(Effect::Panic);
        }
        if self.block && !other.block {
            diff.push(Effect::Block);
        }
        diff
    }

    pub fn to_vec(&self) -> Vec<Effect> {
        let mut v = Vec::new();
        if self.alloc {
            v.push(Effect::Alloc);
        }
        if self.io {
            v.push(Effect::Io);
        }
        if self.panic {
            v.push(Effect::Panic);
        }
        if self.block {
            v.push(Effect::Block);
        }
        v
    }

    pub fn display(&self) -> String {
        let v = self.to_vec();
        if v.is_empty() {
            "!{}".to_string()
        } else {
            let names: Vec<&'static str> = v.into_iter().map(|e| e.name()).collect();
            format!("!{{{}}}", names.join(", "))
        }
    }
}

/// Explicit effect annotation in AST (`!{alloc, io}`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EffectsAnnotation {
    pub allowed: EffectSet,
    pub span: Span,
}

/// Attributes placed before function or method declarations (`@noalloc`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Attribute {
    NoAlloc(Span),
}

impl Attribute {
    pub fn span(&self) -> Span {
        match self {
            Attribute::NoAlloc(span) => *span,
        }
    }
}

/// Declared effect contract for a compiled function or method instance.
#[derive(Debug, Clone)]
pub struct FnContract {
    pub name: String,
    pub span: Span,
    pub explicit_effects: Option<EffectsAnnotation>,
    pub noalloc: Option<Span>,
}

/// Trait method effect contract.
#[derive(Debug, Clone)]
pub struct TraitMethodContract {
    pub trait_name: String,
    pub method_name: String,
    pub allowed: EffectSet,
    pub noalloc: bool,
    pub span: Span,
}

thread_local! {
    /// Function id of each future type of the program being analyzed, so an
    /// `await` can inherit the effects of the function it polls.
    static FUTURE_FUNCS: std::cell::RefCell<Vec<usize>> =
        const { std::cell::RefCell::new(Vec::new()) };
}

/// Direct, local operations inside a function body before interprocedural propagation.
#[derive(Default)]
struct LocalAnalysis {
    effects: EffectSet,
    calls: Vec<(usize, Span)>,
    alloc_reason: Option<(Span, &'static str)>,
    io_reason: Option<(Span, &'static str)>,
    panic_reason: Option<(Span, &'static str)>,
    block_reason: Option<(Span, &'static str)>,
}

impl LocalAnalysis {
    fn record(&mut self, effect: Effect, span: Span, reason: &'static str) {
        self.effects.insert(effect);
        match effect {
            Effect::Alloc => {
                if self.alloc_reason.is_none() {
                    self.alloc_reason = Some((span, reason));
                }
            }
            Effect::Io => {
                if self.io_reason.is_none() {
                    self.io_reason = Some((span, reason));
                }
            }
            Effect::Panic => {
                if self.panic_reason.is_none() {
                    self.panic_reason = Some((span, reason));
                }
            }
            Effect::Block => {
                if self.block_reason.is_none() {
                    self.block_reason = Some((span, reason));
                }
            }
        }
    }
}

fn scan_value(val: &Value, local: &mut LocalAnalysis) {
    match &val.kind {
        // A region allocation is a dynamic allocation: regions never let
        // @noalloc code allocate (spec §7). It can also fail (negative size,
        // out of memory).
        ValueKind::RegionList(_) => {}
        ValueKind::RegionBytes(_, size) => {
            local.record(
                Effect::Alloc,
                val.span,
                "reserva de un buffer en una región (.bytes)",
            );
            local.record(
                Effect::Panic,
                val.span,
                "reserva en región: tamaño negativo o memoria insuficiente",
            );
            scan_value(size, local);
        }
        ValueKind::BytesGet(_, index) => {
            local.record(
                Effect::Panic,
                val.span,
                "acceso a buffer con comprobación de límites",
            );
            scan_value(index, local);
        }
        ValueKind::BytesSet(_, index, byte) => {
            local.record(
                Effect::Panic,
                val.span,
                "escritura en buffer con comprobación de límites y de rango de byte",
            );
            scan_value(index, local);
            scan_value(byte, local);
        }
        // Opening a region and reading a length allocate nothing.
        ValueKind::RegionNew | ValueKind::BytesLen(_) => {}
        // A fixed-size array lives in place: no dynamic allocation.
        ValueKind::ArrayLit(items) => {
            for i in items {
                scan_value(i, local);
            }
        }
        ValueKind::ListLit(items) => {
            local.record(
                Effect::Alloc,
                val.span,
                "construcción de List (reserva en el heap)",
            );
            local.record(
                Effect::Panic,
                val.span,
                "construcción de List: memoria insuficiente",
            );
            for i in items {
                scan_value(i, local);
            }
        }
        ValueKind::Index(base, index) => {
            // A constant index into a fixed array was proven in range by sema.
            let proven =
                matches!(base.ty, Type::Array(_)) && matches!(index.kind, ValueKind::Int(_));
            if !proven {
                local.record(
                    Effect::Panic,
                    val.span,
                    "acceso indexado con comprobación de límites",
                );
            }
            scan_value(base, local);
            scan_value(index, local);
        }
        ValueKind::Length(base) | ValueKind::Capacity(base) => scan_value(base, local),
        ValueKind::TextByte(base, index) => {
            scan_value(base, local);
            scan_value(index, local);
            local.record(
                Effect::Panic,
                val.span,
                "acceso a Text con comprobación de límites",
            );
        }
        ValueKind::ListPush(list, item) => {
            local.record(
                Effect::Alloc,
                val.span,
                "List.push (puede ampliar la capacidad)",
            );
            local.record(
                Effect::Panic,
                val.span,
                "List.push: memoria insuficiente o capacidad desbordada",
            );
            scan_value(list, local);
            scan_value(item, local);
        }
        ValueKind::ListReserve(list, n) => {
            local.record(Effect::Alloc, val.span, "List.reserve (reserva en el heap)");
            local.record(
                Effect::Panic,
                val.span,
                "List.reserve: tamaño negativo, desbordado o sin memoria",
            );
            scan_value(list, local);
            scan_value(n, local);
        }
        ValueKind::ListPop(list, ..) => scan_value(list, local),
        ValueKind::Interpolate(parts) => {
            local.record(
                Effect::Alloc,
                val.span,
                "interpolación dinámica de texto en el heap",
            );
            for p in parts {
                scan_value(p, local);
            }
        }
        ValueKind::Platform(op, args) => {
            use crate::lir::PlatformOp::*;
            local.record(Effect::Io, val.span, "servicio de plataforma");
            if matches!(op, ReadText | PrintError | WriteBytes) {
                local.record(Effect::Block, val.span, "I/O síncrono de plataforma");
            }
            if !matches!(op, PrintError) {
                local.record(Effect::Alloc, val.span, "buffer de plataforma");
            }
            if matches!(op, Arg | ReadText | WriteBytes) {
                local.record(Effect::Panic, val.span, "reserva de memoria para Text");
            }
            for arg in args {
                scan_value(arg, local);
            }
        }
        ValueKind::Print(inner) => {
            local.record(Effect::Io, val.span, "llamada a 'print' (salida estándar)");
            local.record(
                Effect::Block,
                val.span,
                "llamada a 'print' (I/O bloqueante)",
            );
            local.record(
                Effect::Alloc,
                val.span,
                "llamada a 'print' (formateo dinámico de texto)",
            );
            local.record(
                Effect::Panic,
                val.span,
                "llamada a 'print' (posible fallo de escritura I/O)",
            );
            scan_value(inner, local);
        }
        ValueKind::Binary(op, left, right) => {
            if left.ty == Type::Int {
                match op.as_str() {
                    "+" | "-" | "*" => {
                        local.record(
                            Effect::Panic,
                            val.span,
                            "aritmética entera con verificación de desbordamiento (overflow)",
                        );
                    }
                    "/" | "%" => {
                        local.record(
                            Effect::Panic,
                            val.span,
                            "división o módulo de enteros (posible división por cero o overflow)",
                        );
                    }
                    _ => {}
                }
            }
            scan_value(left, local);
            scan_value(right, local);
        }
        ValueKind::Unary(op, inner) => {
            if op == "-" && inner.ty == Type::Int {
                local.record(
                    Effect::Panic,
                    val.span,
                    "negación de entero (posible desbordamiento en i64::MIN)",
                );
            }
            scan_value(inner, local);
        }
        // Calling an async function builds its future: it reserves the task
        // state and runs nothing, so it does not inherit the body's effects.
        ValueKind::Call(_, args) if matches!(val.ty, Type::Future(_)) => {
            local.record(
                Effect::Alloc,
                val.span,
                "creación de un future (reserva del estado de la tarea)",
            );
            local.record(
                Effect::Panic,
                val.span,
                "creación de un future: memoria insuficiente",
            );
            for arg in args {
                scan_value(arg, local);
            }
        }
        // Spawning registers the future as a task: it reserves the task block
        // and commits to running the body (only cancellation can stop it), so
        // it inherits the body's effects. Registering is not a blocking
        // operation and creates no thread.
        ValueKind::Spawn(future) => {
            local.record(
                Effect::Alloc,
                val.span,
                "spawn: reserva del registro de la tarea en el planificador",
            );
            local.record(
                Effect::Panic,
                val.span,
                "spawn: memoria insuficiente al registrar la tarea",
            );
            if let Type::Future(index) = future.ty {
                let func = FUTURE_FUNCS.with(|f| f.borrow().get(index).copied());
                if let Some(func) = func
                    && func != usize::MAX
                {
                    local.calls.push((func, val.span));
                }
            }
            scan_value(future, local);
        }
        // Awaiting polls the future: it runs the body, so it inherits its
        // effects. Cooperative suspension is not a blocking operation.
        ValueKind::Await(future) => {
            if let Type::Future(index) = future.ty {
                let func = FUTURE_FUNCS.with(|f| f.borrow().get(index).copied());
                if let Some(func) = func
                    && func != usize::MAX
                {
                    local.calls.push((func, val.span));
                }
            }
            scan_value(future, local);
        }
        // The handles already belong to spawned tasks, whose effects are
        // accounted for at spawn. Waiting for both allocates and blocks nothing.
        ValueKind::JoinAll(group) => {
            local.record(Effect::Alloc, val.span, "joinAll: lista de resultados");
            local.record(
                Effect::Panic,
                val.span,
                "joinAll: memoria insuficiente para los resultados",
            );
            scan_value(group, local);
        }
        ValueKind::Join(handles) => {
            for handle in handles.iter() {
                scan_value(handle, local);
            }
        }
        ValueKind::Call(fid, args) => {
            local.calls.push((*fid, val.span));
            for arg in args {
                scan_value(arg, local);
            }
        }
        ValueKind::MethodCall(fid, _, _, args) => {
            local.calls.push((*fid, val.span));
            for arg in args {
                scan_value(arg, local);
            }
        }
        ValueKind::TempMethodCall(fid, receiver, args) => {
            local.calls.push((*fid, val.span));
            scan_value(receiver, local);
            for arg in args {
                scan_value(arg, local);
            }
        }
        ValueKind::Construct(_, fields) => {
            for (_, fval) in fields {
                scan_value(fval, local);
            }
        }
        ValueKind::StoredBorrow(base)
        | ValueKind::SharedField(base, _)
        | ValueKind::Field(base, _) => {
            scan_value(base, local);
        }
        ValueKind::Variant(_, _, args) => {
            for arg in args {
                scan_value(arg, local);
            }
        }
        ValueKind::Match(scrutinee, arms) => {
            scan_value(scrutinee, local);
            for arm in arms {
                for inst in &arm.body {
                    scan_instruction(inst, local);
                }
                if let Some(v) = &arm.value {
                    scan_value(v, local);
                }
            }
        }
        ValueKind::Convert(inner, _) => {
            scan_value(inner, local);
        }
        ValueKind::Borrow(_, _)
        | ValueKind::Unit
        | ValueKind::Int(_)
        | ValueKind::Float(_)
        | ValueKind::Bool(_)
        | ValueKind::Text(_)
        | ValueKind::Local(_) => {}
    }
}

fn scan_instruction(inst: &Instruction, local: &mut LocalAnalysis) {
    match inst {
        // Suspending is cooperative: it neither blocks a thread nor allocates.
        Instruction::Sleep(v) => {
            scan_value(v, local);
            local.record(Effect::Alloc, v.span, "sleepMs: registro del temporizador");
            local.record(
                Effect::Panic,
                v.span,
                "sleepMs: fallo de registro o espera del temporizador",
            );
        }
        Instruction::Yield => {}
        Instruction::BindRef(_, _, _, val)
        | Instruction::Bind(_, _, val)
        | Instruction::Store(_, val)
        | Instruction::Eval(val)
        | Instruction::ReturnRef(_, val)
        | Instruction::Return(val) => {
            scan_value(val, local);
        }
        Instruction::If(cond, then_block, else_block) => {
            scan_value(cond, local);
            for i in then_block {
                scan_instruction(i, local);
            }
            for i in else_block {
                scan_instruction(i, local);
            }
        }
        Instruction::While(cond, body) => {
            scan_value(cond, local);
            for i in body {
                scan_instruction(i, local);
            }
        }
        Instruction::ForRange(_, start, end, _, body) => {
            scan_value(start, local);
            scan_value(end, local);
            for i in body {
                scan_instruction(i, local);
            }
        }
        // Iterating reads elements in bounds by construction: no effect of its own.
        Instruction::ForEach(_, _, coll, body) => {
            scan_value(coll, local);
            for i in body {
                scan_instruction(i, local);
            }
        }
        Instruction::StoreElem(target, value) => {
            scan_value(value, local);
            scan_value(target, local);
        }
        Instruction::Loop(body) | Instruction::Block(body) => {
            for i in body {
                scan_instruction(i, local);
            }
        }
        Instruction::Break | Instruction::Continue => {}
    }
}

/// Finds the shortest call chain from `start_fid` to a target function that exhibits `effect`.
fn find_call_chain(
    start_fid: usize,
    effect: Effect,
    locals: &[LocalAnalysis],
    callees: &[Vec<usize>],
    functions: &[Function],
) -> Vec<String> {
    if locals[start_fid].effects.contains(effect) {
        let reason = match effect {
            Effect::Alloc => locals[start_fid]
                .alloc_reason
                .map(|r| r.1)
                .unwrap_or("alloc"),
            Effect::Io => locals[start_fid].io_reason.map(|r| r.1).unwrap_or("io"),
            Effect::Panic => locals[start_fid]
                .panic_reason
                .map(|r| r.1)
                .unwrap_or("panic"),
            Effect::Block => locals[start_fid]
                .block_reason
                .map(|r| r.1)
                .unwrap_or("block"),
        };
        return vec![format!(
            "{}() [{}: {}]",
            functions[start_fid].name,
            effect.name(),
            reason
        )];
    }

    let mut queue = VecDeque::new();
    let mut visited = HashSet::new();
    let mut parent: HashMap<usize, usize> = HashMap::new();

    queue.push_back(start_fid);
    visited.insert(start_fid);

    let mut target = None;
    while let Some(u) = queue.pop_front() {
        if locals[u].effects.contains(effect) {
            target = Some(u);
            break;
        }
        for &v in &callees[u] {
            if visited.insert(v) {
                parent.insert(v, u);
                queue.push_back(v);
            }
        }
    }

    let Some(dest) = target else {
        return vec![format!("{}()", functions[start_fid].name)];
    };

    let mut path = Vec::new();
    let mut cur = dest;
    while cur != start_fid {
        path.push(cur);
        cur = parent[&cur];
    }
    path.push(start_fid);
    path.reverse();

    let mut result = Vec::new();
    for (i, &fid) in path.iter().enumerate() {
        if i == path.len() - 1 {
            let reason = match effect {
                Effect::Alloc => locals[fid].alloc_reason.map(|r| r.1).unwrap_or("alloc"),
                Effect::Io => locals[fid].io_reason.map(|r| r.1).unwrap_or("io"),
                Effect::Panic => locals[fid].panic_reason.map(|r| r.1).unwrap_or("panic"),
                Effect::Block => locals[fid].block_reason.map(|r| r.1).unwrap_or("block"),
            };
            result.push(format!(
                "{}() [{}: {}]",
                functions[fid].name,
                effect.name(),
                reason
            ));
        } else {
            result.push(format!("{}()", functions[fid].name));
        }
    }
    result
}

fn format_call_trace(chain: &[String]) -> String {
    if chain.len() <= 1 {
        return chain.first().cloned().unwrap_or_default();
    }
    let mut s = String::new();
    for (i, node) in chain.iter().enumerate() {
        if i == 0 {
            s.push_str(&format!("  {node}\n"));
        } else {
            let indent = "     ".repeat(i - 1);
            s.push_str(&format!("  {indent}└── {node}\n"));
        }
    }
    s
}

/// Performs interprocedural static effect analysis on the lowering program.
///
/// 1. Infers direct effects for every concrete function in the program.
/// 2. Builds the call graph and propagates effects until fixed-point convergence.
/// 3. Validates explicit `@noalloc` annotations and `!{...}` contracts.
/// 4. Validates trait method effect contracts against implementations.
/// 5. Stores verified inferred effects in `lir::Function.effects`.
pub fn check_effects(
    program: &mut Program,
    contracts: &HashMap<usize, FnContract>,
    trait_contracts: &[TraitMethodContract],
    // (trait_name, method_name) -> every implementation (one per implementing type).
    impl_methods: &HashMap<(String, String), Vec<usize>>,
) -> Result<(), Diagnostic> {
    FUTURE_FUNCS.with(|f| {
        *f.borrow_mut() = program.futures.iter().map(|d| d.func).collect();
    });
    let n = program.functions.len();
    let mut locals: Vec<LocalAnalysis> = Vec::with_capacity(n);
    let mut callees: Vec<Vec<usize>> = vec![Vec::new(); n];
    let mut callers: Vec<Vec<usize>> = vec![Vec::new(); n];

    for f in &program.functions {
        let mut local = LocalAnalysis::default();
        for inst in &f.body {
            scan_instruction(inst, &mut local);
        }
        locals.push(local);
    }

    for (fid, local) in locals.iter().enumerate() {
        let mut seen = HashSet::new();
        for &(callee, _) in &local.calls {
            if callee < n && seen.insert(callee) {
                callees[fid].push(callee);
                callers[callee].push(fid);
            }
        }
    }

    // Fixed-point propagation
    let mut inferred: Vec<EffectSet> = locals.iter().map(|l| l.effects).collect();
    let mut worklist: VecDeque<usize> = (0..n).collect();
    let mut in_worklist: Vec<bool> = vec![true; n];

    while let Some(u) = worklist.pop_front() {
        in_worklist[u] = false;
        let u_effects = inferred[u];

        for &caller in &callers[u] {
            let old = inferred[caller];
            let new = old.union(u_effects);
            if new != old {
                inferred[caller] = new;
                if !in_worklist[caller] {
                    worklist.push_back(caller);
                    in_worklist[caller] = true;
                }
            }
        }
    }

    // 1. Validate function contracts
    for (fid, contract) in contracts {
        if *fid >= n {
            continue;
        }
        let fn_effects = inferred[*fid];

        // Validate @noalloc
        if let Some(noalloc_span) = contract.noalloc
            && fn_effects.alloc
        {
            let chain = find_call_chain(*fid, Effect::Alloc, &locals, &callees, &program.functions);
            let trace = format_call_trace(&chain);
            let msg = format!(
                "violación de @noalloc en '{}': la función no permite asignaciones dinámicas en el heap.\n\nRuta de llamadas:\n{trace}\nSugerencia: elimine la asignación, evite interpolación de texto dinámica o retire la anotación @noalloc.",
                contract.name
            );
            return Err(Diagnostic::new(noalloc_span, msg).classify("L0010", "efectos"));
        }

        // Validate explicit !{...}
        if let Some(annot) = contract.explicit_effects
            && !fn_effects.is_subset_of(annot.allowed)
        {
            let diff = fn_effects.difference(annot.allowed);
            let diff_names: Vec<&str> = diff.iter().map(|e| e.name()).collect();
            let primary_effect = diff[0];
            let chain =
                find_call_chain(*fid, primary_effect, &locals, &callees, &program.functions);
            let trace = format_call_trace(&chain);
            let msg = format!(
                "violación de contrato de efectos {} en '{}': introduce efectos no permitidos [{}].\n\nRuta de llamadas que introduce '{}':\n{trace}\nSugerencia: declare los efectos necesarios en la firma '{}' o elimine las operaciones causantes.",
                annot.allowed.display(),
                contract.name,
                diff_names.join(", "),
                primary_effect.name(),
                annot.allowed.display()
            );
            return Err(Diagnostic::new(annot.span, msg).classify("L0010", "efectos"));
        }
    }

    // 2. Validate trait contracts
    for tc in trait_contracts {
        let key = (tc.trait_name.clone(), tc.method_name.clone());
        let impls = impl_methods
            .get(&key)
            .map(Vec::as_slice)
            .unwrap_or_default();
        for &fid in impls.iter().filter(|fid| **fid < n) {
            let fn_effects = inferred[fid];
            if tc.noalloc && fn_effects.alloc {
                let chain =
                    find_call_chain(fid, Effect::Alloc, &locals, &callees, &program.functions);
                let trace = format_call_trace(&chain);
                let msg = format!(
                    "el método '{}' viola el contrato @noalloc del trait '{}'.\n\nRuta de llamadas:\n{trace}",
                    tc.method_name, tc.trait_name
                );
                return Err(Diagnostic::new(tc.span, msg).classify("L0010", "efectos"));
            }
            if !fn_effects.is_subset_of(tc.allowed) {
                let diff = fn_effects.difference(tc.allowed);
                let diff_names: Vec<&str> = diff.iter().map(|e| e.name()).collect();
                let primary_effect = diff[0];
                let chain =
                    find_call_chain(fid, primary_effect, &locals, &callees, &program.functions);
                let trace = format_call_trace(&chain);
                let msg = format!(
                    "el método '{}' viola el contrato de efectos {} del trait '{}': introduce efectos no permitidos [{}].\n\nRuta de llamadas:\n{trace}",
                    tc.method_name,
                    tc.allowed.display(),
                    tc.trait_name,
                    diff_names.join(", ")
                );
                return Err(Diagnostic::new(tc.span, msg).classify("L0010", "efectos"));
            }
        }
    }

    // 3. Store verified inferred effects on lir::Function
    for (fid, f) in program.functions.iter_mut().enumerate() {
        f.effects = inferred[fid];
    }

    Ok(())
}
