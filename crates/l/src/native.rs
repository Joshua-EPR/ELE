//! Native backend: CFG LIR → Cranelift IR → relocatable object file.
//!
//! The runtime has no C runtime dependency. The core runtime
//! (`native/runtime.rs`: entry point, output, heap, Text building) is generated
//! as Cranelift IR in the same object and only calls the operating system
//! (Windows x86-64, kernel32).
//!
//! Supported subset (anything else is rejected with a clear diagnostic, never
//! miscompiled): Int, Bool, Unit and Text values (static literals and owned
//! heap buffers built by interpolation); nested structs by value; locals and shared borrows of
//! locals and fields; checked integer arithmetic with panics; comparisons; branches,
//! loops and `match` on Int/Bool/Text; calls and recursion; `print`; drops;
//! fixed arrays `[T; N]` (in the frame), slice parameters `&[T]` (passed as
//! `(ptr, len)`) and `List<T>` (`(ptr, len, cap)` owning a heap buffer of
//! `cap` elements). Every element access is bounds-checked.
//!
//! Text is three machine words `(ptr, len, cap)`: `cap == 0` means static
//! storage that is never freed; `cap > 0` means a heap buffer of `cap` bytes
//! owned by exactly one variable, released by its (elaborated) `Drop`.
mod platform;
mod runtime;

use crate::{
    Diagnostic, Span,
    cfg::{self, Arg, BinOp, Const, InstKind, Operand, Place, Rvalue, Terminator, UnOp, VarTy},
    layout::{Layout, Layouts},
    lir::{PlatformOp, Type},
};
use cranelift_codegen::{
    Context,
    ir::{
        self, AbiParam, BlockArg, InstBuilder, MemFlagsData, TrapCode, UserFuncName,
        condcodes::{FloatCC, IntCC},
        types,
    },
    isa::OwnedTargetIsa,
    settings::{self, Configurable},
};
use cranelift_frontend::{FunctionBuilder, FunctionBuilderContext, Variable};
use cranelift_module::{DataDescription, DataId, FuncId, Linkage, Module, default_libcall_names};
use cranelift_object::{ObjectBuilder, ObjectModule};
use std::cell::Cell;
use std::collections::{HashMap, HashSet};

pub use runtime::PANIC_EXIT_CODE;

/// Testing instruments compiled into the runtime on request. They never
/// change program semantics when disabled (the default).
#[derive(Debug, Clone, Copy, Default)]
pub struct Options {
    /// Count heap operations, validate every pointer before freeing it and
    /// the whole heap at exit, and report on stderr at normal exit:
    /// `l-alloc: allocs=A reallocs=R frees=F heap_ok=1`.
    pub trace_alloc: bool,
    /// Make the heap allocation attempt number `n + 1` fail (out-of-memory
    /// path testing). Implies counting.
    pub fail_alloc_after: Option<u64>,
}

fn unsupported(span: Span, what: impl std::fmt::Display) -> Diagnostic {
    Diagnostic::new(
        span,
        format!("backend cranelift: {what} aún no está soportado; use --backend rustc"),
    )
    .classify("L0008", "backend")
}

fn internal(e: impl std::fmt::Display) -> Diagnostic {
    Diagnostic::new(
        Span { line: 1, column: 1 },
        format!("backend cranelift: {e}"),
    )
    .classify("L0008", "backend")
}

// ------------------------------------------------------------ support check --

fn supported_type(t: Type) -> bool {
    matches!(
        t,
        Type::Int
            | Type::Float
            | Type::F32
            | Type::Bool
            | Type::Unit
            | Type::Text
            | Type::Struct(_)
            | Type::Enum(_)
            | Type::Region(_)
            | Type::Bytes(_)
            | Type::Array(_)
            | Type::Slice(_)
            | Type::List(_)
            | Type::RegionList(..)
            | Type::Future(_)
            | Type::Task(_)
            | Type::TaskGroup(_)
    )
}

/// Whether a result is returned through a hidden pointer to a caller slot.
fn by_sret(t: Type) -> bool {
    matches!(
        t,
        Type::Text
            | Type::Struct(_)
            | Type::Enum(_)
            | Type::Array(_)
            | Type::List(_)
            | Type::RegionList(..)
            | Type::TaskGroup(_)
    )
}

/// A `&[T]`/`&mut [T]` is a view `(ptr, len)`: two machine words.
fn is_slice_ref(t: VarTy) -> bool {
    matches!(t, VarTy::Ref(Type::Slice(_)))
}

fn layouts_of(module: &cfg::Module) -> Result<Layouts, Diagnostic> {
    let layouts = Layouts::windows_x64_with(&module.structs, &module.enums, &module.arrays)
        .map_err(internal)?;
    // A group's handle layout is canonical by result type. A child keeps
    // its actual poll/drop kind, but the result prefix must match that type.
    if !module
        .lists
        .iter()
        .any(|elem| matches!(elem, Type::Task(_)))
    {
        return Ok(layouts);
    }
    let mut result_offsets = HashMap::new();
    for future in &module.futures {
        let state = layouts.get(Type::Struct(future.state)).map_err(internal)?;
        let offset = *state
            .fields
            .get(cfg::RESULT_FIELD)
            .ok_or_else(|| internal("estado async sin campo de resultado"))?;
        if result_offsets
            .insert(future.result, offset)
            .is_some_and(|old| old != offset)
        {
            return Err(internal("offset de resultado async inconsistente"));
        }
    }
    Ok(layouts)
}

fn type_error(t: Type, func: &str, span: Span) -> Diagnostic {
    match t {
        Type::Struct(_) => unsupported(span, format!("struct (en {func})")),
        Type::Enum(_) => unsupported(span, format!("enum (en {func})")),
        _ => unsupported(span, format!("tipo {t:?} (en {func})")),
    }
}

fn check_operand(_op: &Operand, _span: Span) -> Result<(), Diagnostic> {
    Ok(())
}

fn check_place(_p: &Place, _span: Span) -> Result<(), Diagnostic> {
    Ok(())
}

fn check_arg(a: &Arg, span: Span) -> Result<(), Diagnostic> {
    match a {
        Arg::Value(o) => check_operand(o, span),
        Arg::Ref(p, _) => check_place(p, span),
    }
}

/// Rejects every construct outside the supported subset before generating code.
pub fn check_supported(module: &cfg::Module) -> Result<(), Diagnostic> {
    let _layouts = layouts_of(module)?;
    for f in &module.funcs {
        let first_span = f
            .blocks
            .iter()
            .flat_map(|b| b.insts.first())
            .map(|i| i.span)
            .next()
            .unwrap_or(Span { line: 1, column: 1 });
        if let Some(p) = f.params.first()
            && let VarTy::Ref(ty) = f.vars[*p]
            && !supported_type(ty)
        {
            return Err(type_error(ty, &f.name, first_span));
        }
        for t in &f.vars {
            let ty = t.pointee();
            if !supported_type(ty) {
                return Err(type_error(ty, &f.name, first_span));
            }
        }
        for block in &f.blocks {
            for inst in &block.insts {
                let span = inst.span;
                match &inst.kind {
                    InstKind::Assign(_, rv) => match rv {
                        Rvalue::Use(o)
                        | Rvalue::Unary(UnOp::Not | UnOp::Neg, o)
                        | Rvalue::Convert(o, _) => check_operand(o, span)?,
                        Rvalue::Binary(_, a, b) => {
                            check_operand(a, span)?;
                            check_operand(b, span)?;
                        }
                        Rvalue::Call(_, args) | Rvalue::Platform(_, args, _) => {
                            for a in args {
                                check_arg(a, span)?;
                            }
                        }
                        Rvalue::Read(p)
                        | Rvalue::FieldLoan(p)
                        | Rvalue::Ref(p)
                        | Rvalue::Loan(p, ..)
                        | Rvalue::TextEq(p, _) => check_place(p, span)?,
                        Rvalue::TextBuffer(_) => {}
                        Rvalue::Struct(_, fields) => {
                            for field in fields {
                                check_operand(field, span)?;
                            }
                        }
                        Rvalue::Variant(_, _, fields) => {
                            for field in fields {
                                check_operand(field, span)?;
                            }
                        }
                        Rvalue::Discriminant(p) => {
                            check_place(p, span)?;
                        }
                        Rvalue::RegionNew(_) => {}
                        Rvalue::RegionList(p, _) => check_place(p, span)?,
                        Rvalue::RegionBytes(p, o) | Rvalue::BytesGet(p, o) => {
                            check_place(p, span)?;
                            check_operand(o, span)?;
                        }
                        Rvalue::BytesLen(p)
                        | Rvalue::Len(p)
                        | Rvalue::Cap(p)
                        | Rvalue::ListTakeLast(p) => check_place(p, span)?,
                        Rvalue::ArrayLit(_, ops) | Rvalue::ListLit(_, ops) => {
                            for o in ops {
                                check_operand(o, span)?;
                            }
                        }
                        Rvalue::FutureNew(_) | Rvalue::GroupPending | Rvalue::TimerPending => {}
                        Rvalue::CheckSleep(ms) | Rvalue::TimerStart(ms) => check_operand(ms, span)?,
                        Rvalue::FutureState(p)
                        | Rvalue::FuturePoll(p)
                        | Rvalue::TaskReady(p)
                        | Rvalue::TaskState(p)
                        | Rvalue::GroupRegister(p) => check_place(p, span)?,
                        Rvalue::TaskSpawn(o, _) => check_operand(o, span)?,
                    },
                    InstKind::Clear(p) => check_place(p, span)?,
                    InstKind::Wake | InstKind::RunTasks => {}
                    InstKind::ListPush(p, o) | InstKind::ListReserve(p, o) => {
                        check_place(p, span)?;
                        check_operand(o, span)?;
                    }
                    InstKind::BytesSet(p, i, v) => {
                        check_place(p, span)?;
                        check_operand(i, span)?;
                        check_operand(v, span)?;
                    }
                    InstKind::Print(arg) | InstKind::Append(_, arg) => check_arg(arg, span)?,
                    InstKind::Store(p, o) => {
                        check_place(p, span)?;
                        check_operand(o, span)?;
                    }
                    InstKind::Drop(..) | InstKind::Moved(_) => {}
                    InstKind::DropField(p, _) => check_place(p, span)?,
                }
            }
            if let Some(Terminator::Branch(o, ..) | Terminator::Return(o)) = &block.term {
                check_operand(o, Span { line: 1, column: 1 })?;
            }
        }
    }
    Ok(())
}

// --------------------------------------------------------------- generation --

fn clif_type_of(ty: Type) -> ir::Type {
    match ty {
        Type::Bool => types::I8,
        Type::F32 => types::F32,
        Type::Float => types::F64,
        _ => types::I64,
    }
}

/// Machine values of a type: Int → i64, Bool → i8, () → none,
/// Text → (ptr, len, cap). A shared borrow has the same representation as the
/// borrowed value (an alias that is never dropped and never mutated).
fn clif_types(t: Type, layouts: &Layouts) -> Result<Vec<ir::Type>, Diagnostic> {
    Ok(layouts
        .get(t)
        .map_err(internal)?
        .components
        .iter()
        .map(|c| clif_type_of(c.ty))
        .collect())
}

pub(crate) struct Gen {
    module: ObjectModule,
    ctx: Context,
    fctx: FunctionBuilderContext,
    strings: HashMap<String, DataId>,
}

fn flags() -> MemFlagsData {
    MemFlagsData::trusted()
}

fn isa() -> Result<OwnedTargetIsa, Diagnostic> {
    let triple = target_lexicon::Triple::host();
    let windows_x64 = triple.operating_system == target_lexicon::OperatingSystem::Windows
        && triple.architecture == target_lexicon::Architecture::X86_64;
    if !windows_x64 {
        return Err(internal(format!(
            "plataforma {triple} no soportada todavía (solo Windows x86-64)"
        )));
    }
    let mut builder = settings::builder();
    for (k, v) in [
        ("opt_level", "speed"),
        // Stack probes inline: no external __chkstk symbol is needed.
        ("enable_probestack", "true"),
        ("probestack_strategy", "inline"),
        ("enable_verifier", "true"),
    ] {
        builder.set(k, v).map_err(internal)?;
    }
    cranelift_native::builder()
        .map_err(internal)?
        .finish(settings::Flags::new(builder))
        .map_err(internal)
}

/// Read-only static data holding the UTF-8 bytes of `s` (deduplicated).
fn string_data(
    module: &mut ObjectModule,
    strings: &mut HashMap<String, DataId>,
    s: &str,
) -> Result<DataId, Diagnostic> {
    if let Some(id) = strings.get(s) {
        return Ok(*id);
    }
    let name = format!("l_str{}", strings.len());
    let id = module
        .declare_data(&name, Linkage::Local, false, false)
        .map_err(internal)?;
    let mut desc = DataDescription::new();
    // A trailing NUL keeps every object non-empty; it is not part of the length.
    let mut bytes = s.as_bytes().to_vec();
    bytes.push(0);
    desc.define(bytes.into_boxed_slice());
    module.define_data(id, &desc).map_err(internal)?;
    strings.insert(s.to_string(), id);
    Ok(id)
}

impl Gen {
    fn new() -> Result<Self, Diagnostic> {
        let builder =
            ObjectBuilder::new(isa()?, "l_program", default_libcall_names()).map_err(internal)?;
        let module = ObjectModule::new(builder);
        let ctx = module.make_context();
        Ok(Gen {
            module,
            ctx,
            fctx: FunctionBuilderContext::new(),
            strings: HashMap::new(),
        })
    }
    fn signature(&self, params: &[ir::Type], returns: &[ir::Type]) -> ir::Signature {
        let mut sig = self.module.make_signature();
        sig.params.extend(params.iter().map(|t| AbiParam::new(*t)));
        sig.returns
            .extend(returns.iter().map(|t| AbiParam::new(*t)));
        sig
    }
    fn declare(
        &mut self,
        name: &str,
        linkage: Linkage,
        params: &[ir::Type],
        returns: &[ir::Type],
    ) -> Result<FuncId, Diagnostic> {
        let sig = self.signature(params, returns);
        self.module
            .declare_function(name, linkage, &sig)
            .map_err(internal)
    }
    /// Defines a dispatch function `f(kind, state)` that forwards to the
    /// function of the future type `kind` chosen by `pick` (its `poll` or its
    /// state destructor). The scheduler calls these instead of holding
    /// function pointers in the task records, so every call it makes is a
    /// direct call to a function of this object.
    fn dispatch(
        &mut self,
        id: FuncId,
        params: &[ir::Type],
        returns: &[ir::Type],
        futures: &[cfg::FutureInfo],
        user: &[FuncId],
        pick: impl Fn(&cfg::FutureInfo) -> usize,
    ) -> Result<(), Diagnostic> {
        let targets: Vec<FuncId> = futures.iter().map(|i| user[pick(i)]).collect();
        let returns_value = !returns.is_empty();
        self.define(id, params, returns, move |b, h| {
            let entry = b.create_block();
            b.append_block_params_for_function_params(entry);
            b.switch_to_block(entry);
            let args = b.block_params(entry).to_vec();
            let (kind, state) = (args[0], args[1]);
            for (index, target) in targets.iter().enumerate() {
                let (hit, next) = (b.create_block(), b.create_block());
                let is = b.ins().icmp_imm_s(IntCC::Equal, kind, index as i64);
                brif(b, is, hit, next);
                b.switch_to_block(hit);
                let out = h.call(b, *target, &[state]);
                if returns_value {
                    b.ins().return_(&[out[0]]);
                } else {
                    b.ins().return_(&[]);
                }
                b.switch_to_block(next);
            }
            // Unreachable: every task record carries a valid future type.
            b.ins().trap(TrapCode::unwrap_user(1));
            Ok(())
        })
    }
    /// Zero-initialized writable data of `size` bytes.
    fn zeroed(&mut self, name: &str, size: usize) -> Result<DataId, Diagnostic> {
        let id = self
            .module
            .declare_data(name, Linkage::Local, true, false)
            .map_err(internal)?;
        let mut desc = DataDescription::new();
        desc.define_zeroinit(size);
        self.module.define_data(id, &desc).map_err(internal)?;
        Ok(id)
    }
    /// Defines `id` with a body produced by `body` and the given signature.
    fn define(
        &mut self,
        id: FuncId,
        params: &[ir::Type],
        returns: &[ir::Type],
        body: impl FnOnce(&mut FunctionBuilder, &mut Helpers) -> Result<(), Diagnostic>,
    ) -> Result<(), Diagnostic> {
        self.ctx.clear();
        self.ctx.func.signature = self.signature(params, returns);
        self.ctx.func.name = UserFuncName::user(0, id.as_u32());
        let config = self.module.target_config();
        {
            let mut builder = FunctionBuilder::new(&mut self.ctx.func, &mut self.fctx);
            let mut helpers = Helpers {
                module: &mut self.module,
                strings: &mut self.strings,
                funcs: HashMap::new(),
                datas: HashMap::new(),
            };
            body(&mut builder, &mut helpers)?;
            builder.seal_all_blocks();
            builder.finalize(config);
        }
        self.module
            .define_function(id, &mut self.ctx)
            .map_err(|e| internal(format!("{e:?}")))?;
        Ok(())
    }
}

/// Access to module-level entities while a function body is being built.
pub(crate) struct Helpers<'a> {
    module: &'a mut ObjectModule,
    strings: &'a mut HashMap<String, DataId>,
    funcs: HashMap<FuncId, ir::FuncRef>,
    datas: HashMap<DataId, ir::GlobalValue>,
}

/// Functions returning a Text (three words) receive a hidden first argument:
/// a pointer to a 24-byte slot of the caller where they store `(ptr, len,
/// cap)`. This does not depend on how many return registers the platform
/// calling convention offers.
const SRET_SIZE: u32 = 24;

/// Stores a Text result through the hidden return pointer and returns.
fn return_text(b: &mut FunctionBuilder, out: ir::Value, values: &[ir::Value]) {
    for (i, v) in values.iter().enumerate() {
        b.ins().store(flags(), *v, out, (i * 8) as i32);
    }
    b.ins().return_(&[]);
}

impl Helpers<'_> {
    fn call_struct(
        &mut self,
        b: &mut FunctionBuilder,
        f: FuncId,
        args: &[ir::Value],
        layout: &Layout,
    ) -> Vec<ir::Value> {
        let slot = b.create_sized_stack_slot(ir::StackSlotData::new(
            ir::StackSlotKind::ExplicitSlot,
            layout.size.max(1),
            layout.align.trailing_zeros() as u8,
        ));
        let out = b.ins().stack_addr(types::I64, slot, 0);
        let mut all = vec![out];
        all.extend_from_slice(args);
        self.call(b, f, &all);
        layout
            .components
            .iter()
            .map(|c| {
                b.ins()
                    .load(clif_type_of(c.ty), flags(), out, c.offset as i32)
            })
            .collect()
    }
    /// Calls a function that returns a Text through a hidden return pointer.
    fn call_text(
        &mut self,
        b: &mut FunctionBuilder,
        f: FuncId,
        args: &[ir::Value],
    ) -> Vec<ir::Value> {
        let slot = b.create_sized_stack_slot(ir::StackSlotData::new(
            ir::StackSlotKind::ExplicitSlot,
            SRET_SIZE,
            3,
        ));
        let out = b.ins().stack_addr(types::I64, slot, 0);
        let mut all = vec![out];
        all.extend_from_slice(args);
        self.call(b, f, &all);
        (0..3)
            .map(|i| b.ins().load(types::I64, flags(), out, i * 8))
            .collect()
    }
    fn call(&mut self, b: &mut FunctionBuilder, f: FuncId, args: &[ir::Value]) -> Vec<ir::Value> {
        let fref = *self
            .funcs
            .entry(f)
            .or_insert_with(|| self.module.declare_func_in_func(f, b.func));
        let inst = b.ins().call(fref, args);
        b.inst_results(inst).to_vec()
    }
    fn data_addr(&mut self, b: &mut FunctionBuilder, id: DataId) -> ir::Value {
        let gv = *self
            .datas
            .entry(id)
            .or_insert_with(|| self.module.declare_data_in_func(id, b.func));
        b.ins().symbol_value(types::I64, gv)
    }
    /// Pointer and length of a static string.
    fn text(
        &mut self,
        b: &mut FunctionBuilder,
        s: &str,
    ) -> Result<(ir::Value, ir::Value), Diagnostic> {
        let id = string_data(self.module, self.strings, s)?;
        let ptr = self.data_addr(b, id);
        let len = b.ins().iconst(types::I64, s.len() as i64);
        Ok((ptr, len))
    }
}

fn jump(b: &mut FunctionBuilder, block: ir::Block, args: &[ir::Value]) {
    let args: Vec<BlockArg> = args.iter().map(|v| BlockArg::Value(*v)).collect();
    b.ins().jump(block, &args);
}
fn brif(b: &mut FunctionBuilder, c: ir::Value, yes: ir::Block, no: ir::Block) {
    b.ins().brif(c, yes, &[], no, &[]);
}
fn never(b: &mut FunctionBuilder) {
    b.ins()
        .trap(TrapCode::user(1).expect("valid user trap code"));
}

/// Translates one CFG function.
struct FnGen<'a> {
    func: &'a cfg::Func,
    funcs: &'a [cfg::Func],
    vars: Vec<Vec<Variable>>,
    slots: HashMap<usize, ir::StackSlot>,
    blocks: Vec<ir::Block>,
    slices: &'a [Type],
    user: &'a [FuncId],
    /// Result type of every user function (Text/struct results use sret).
    rt: &'a runtime::Runtime,
    layouts: &'a Layouts,
    structs: &'a [crate::lir::StructDef],
    enums: &'a [crate::lir::EnumDef],
    futures: &'a [cfg::FutureInfo],
    arrays: &'a [crate::lir::ArrayDef],
    lists: &'a [Type],
    task_groups: &'a [crate::lir::TaskGroupDef],
    /// Drop glue of each list type: `l_list_drop{l}(ptr, len, cap)`.
    list_drops: &'a [FuncId],
    task_group_drops: &'a [FuncId],
    /// Source position of the instruction being translated (bounds checks).
    span: Cell<Span>,
}

impl FnGen<'_> {
    fn list_region(&self, b: &mut FunctionBuilder, hdr: ir::Value, ty: Type) -> ir::Value {
        if matches!(ty, Type::RegionList(..)) {
            b.ins().load(types::I64, flags(), hdr, runtime::LIST_REGION)
        } else {
            b.ins().iconst(types::I64, 0)
        }
    }

    /// Element type of a collection type.
    fn elem_of(&self, t: Type) -> Result<Type, Diagnostic> {
        match t {
            Type::Array(a) => Ok(self.arrays[a].elem),
            Type::List(l) | Type::RegionList(l, _) => Ok(self.lists[l]),
            Type::TaskGroup(g) => {
                let elem = self.task_groups[g].elem;
                let task = self
                    .futures
                    .iter()
                    .position(|f| f.result == elem)
                    .unwrap_or(0);
                Ok(Type::Task(task))
            }
            Type::Slice(_) => Err(internal("slice sin tabla en el backend")),
            _ => Err(internal("índice sobre un valor que no es colección")),
        }
    }
    /// Bytes between consecutive elements (sizes are multiples of the alignment).
    fn stride(&self, elem: Type) -> Result<i64, Diagnostic> {
        Ok(i64::from(self.layouts.get(elem).map_err(internal)?.size))
    }
    /// Type of the value a place denotes.
    fn place_type(&self, p: &Place) -> Result<Type, Diagnostic> {
        let mut ty = self.func.vars[p.var].pointee();
        for proj in &p.proj {
            ty = match (ty, proj) {
                (Type::Struct(s), cfg::Proj::Field(field)) => self.structs[s].fields[*field].1,
                (Type::Enum(e), cfg::Proj::Payload(variant, field)) => {
                    self.enums[e].variants[*variant].1[*field]
                }
                (Type::Slice(_), cfg::Proj::Index(_)) => self.slice_elem(p.var)?,
                (t, cfg::Proj::Index(_)) => self.elem_of(t)?,
                _ => return Err(internal("proyección nativa inválida")),
            };
        }
        Ok(ty)
    }
    /// Element type of the slice parameter `v`.
    fn slice_elem(&self, v: usize) -> Result<Type, Diagnostic> {
        match self.func.vars[v] {
            VarTy::Ref(Type::Slice(s)) => self
                .slices
                .get(s)
                .copied()
                .ok_or_else(|| internal("slice inexistente")),
            _ => Err(internal("slice que no es parámetro")),
        }
    }
    /// `(ptr, len)` view of the collection at `p` for a `&[T]` argument.
    fn slice_parts(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        p: &Place,
    ) -> Result<[ir::Value; 2], Diagnostic> {
        Ok(match self.place_type(p)? {
            Type::Array(a) => {
                let addr = self.place_addr(b, h, p)?;
                [addr, b.ins().iconst(types::I64, self.arrays[a].len as i64)]
            }
            Type::List(_) | Type::RegionList(..) | Type::TaskGroup(_) => {
                let addr = self.place_addr(b, h, p)?;
                [
                    b.ins().load(types::I64, flags(), addr, runtime::LIST_PTR),
                    b.ins().load(types::I64, flags(), addr, runtime::LIST_LEN),
                ]
            }
            Type::Slice(_) if p.proj.is_empty() => [
                b.use_var(self.vars[p.var][0]),
                b.use_var(self.vars[p.var][1]),
            ],
            t => return Err(internal(format!("vista de slice sobre {t:?}"))),
        })
    }
    /// Panics (index out of range) unless `0 <= i < len`.
    fn check_index(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        i: ir::Value,
        len: ir::Value,
    ) -> Result<(), Diagnostic> {
        // Unsigned comparison also rejects negative indices.
        let out = b.ins().icmp(IntCC::UnsignedGreaterThanOrEqual, i, len);
        self.panic_msg_if(b, h, out, self.span.get(), runtime::INDEX_RANGE)
    }
    /// Address of a place. Field and payload projections add constant
    /// offsets; an index projection checks the bounds and moves to the
    /// element (inside the frame for arrays, inside the heap buffer for
    /// lists, inside the viewed storage for slices).
    fn place_addr(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        p: &Place,
    ) -> Result<ir::Value, Diagnostic> {
        let mut addr = match self.func.vars[p.var] {
            VarTy::Ref(_) => b.use_var(self.vars[p.var][0]),
            VarTy::Value(_) => {
                let slot = self
                    .slots
                    .get(&p.var)
                    .copied()
                    .ok_or_else(|| internal("variable prestada sin stack slot"))?;
                b.ins().stack_addr(types::I64, slot, 0)
            }
        };
        let mut ty = self.func.vars[p.var].pointee();
        let mut offset = 0i64;
        for (k, proj) in p.proj.iter().enumerate() {
            match (ty, proj) {
                (Type::Struct(s), cfg::Proj::Field(field)) => {
                    let layout = self.layouts.get(ty).map_err(internal)?;
                    offset += i64::from(layout.fields[*field]);
                    ty = self.structs[s].fields[*field].1;
                }
                (Type::Enum(e), cfg::Proj::Payload(variant, field)) => {
                    // A raw projection must never read an inactive union
                    // payload, including from LIR files supplied externally.
                    // Account for a preceding struct-field offset as well.
                    let enum_addr = if offset == 0 {
                        addr
                    } else {
                        b.ins().iadd_imm_s(addr, offset)
                    };
                    let active = b.ins().load(types::I64, flags(), enum_addr, 0);
                    let wrong = b.ins().icmp_imm_s(
                        IntCC::NotEqual,
                        active,
                        *variant as i64,
                    );
                    self.panic_msg_if(
                        b, h, wrong, self.span.get(), "acceso a variante enum inactiva",
                    )?;
                    let field_off = self
                        .layouts
                        .variant_field_offset(e, *variant, *field)
                        .map_err(internal)?;
                    offset += i64::from(field_off);
                    ty = self.enums[e].variants[*variant].1[*field];
                }
                (
                    Type::Array(_)
                    | Type::List(_)
                    | Type::RegionList(..)
                    | Type::TaskGroup(_)
                    | Type::Slice(_),
                    cfg::Proj::Index(iv),
                ) => {
                    let base = if offset == 0 {
                        addr
                    } else {
                        b.ins().iadd_imm_s(addr, offset)
                    };
                    let (data, len, elem) = match ty {
                        Type::Array(a) => {
                            let n = b.ins().iconst(types::I64, self.arrays[a].len as i64);
                            (base, n, self.arrays[a].elem)
                        }
                        Type::List(l) | Type::RegionList(l, _) => (
                            b.ins().load(types::I64, flags(), base, runtime::LIST_PTR),
                            b.ins().load(types::I64, flags(), base, runtime::LIST_LEN),
                            self.lists[l],
                        ),
                        Type::TaskGroup(g) => {
                            let elem = self.task_groups[g].elem;
                            let task = self
                                .futures
                                .iter()
                                .position(|f| f.result == elem)
                                .unwrap_or(0);
                            (
                                b.ins().load(types::I64, flags(), base, runtime::LIST_PTR),
                                b.ins().load(types::I64, flags(), base, runtime::LIST_LEN),
                                Type::Task(task),
                            )
                        }
                        _ if k == 0 && is_slice_ref(self.func.vars[p.var]) => (
                            base,
                            b.use_var(self.vars[p.var][1]),
                            self.slice_elem(p.var)?,
                        ),
                        _ => return Err(internal("slice anidado en un lugar")),
                    };
                    let i = self.var_values(b, *iv)[0];
                    self.check_index(b, h, i, len)?;
                    // i < len, so i * stride stays inside the storage.
                    let scaled = b.ins().imul_imm_s(i, self.stride(elem)?);
                    addr = b.ins().iadd(data, scaled);
                    offset = 0;
                    ty = elem;
                }
                _ => return Err(internal("proyección nativa inválida")),
            }
        }
        Ok(if offset == 0 {
            addr
        } else {
            b.ins().iadd_imm_s(addr, offset)
        })
    }

    fn place_parts(&self, p: &Place) -> Result<(usize, usize, Type), Diagnostic> {
        let mut ty = self.func.vars[p.var].pointee();
        let mut start = 0;
        for proj in &p.proj {
            match (ty, proj) {
                (Type::Struct(s), cfg::Proj::Field(field)) => {
                    for (_, t) in &self.structs[s].fields[..*field] {
                        start += self.layouts.get(*t).map_err(internal)?.components.len();
                    }
                    ty = self.structs[s].fields[*field].1;
                }
                (Type::Enum(e), cfg::Proj::Payload(variant, field)) => {
                    ty = self.enums[e].variants[*variant].1[*field];
                }
                _ => return Err(internal("proyección nativa inválida")),
            }
        }
        Ok((
            start,
            self.layouts.get(ty).map_err(internal)?.components.len(),
            ty,
        ))
    }

    fn place_values(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        p: &Place,
    ) -> Result<Vec<ir::Value>, Diagnostic> {
        let is_ref = matches!(self.func.vars[p.var], VarTy::Ref(_));
        let has_slot = self.slots.contains_key(&p.var);
        let has_payload = p
            .proj
            .iter()
            .any(|proj| matches!(proj, cfg::Proj::Payload(..) | cfg::Proj::Index(_)));
        if is_ref || has_slot || has_payload {
            let addr = self.place_addr(b, h, p)?;
            let ty = self.place_type(p)?;
            let layout = self.layouts.get(ty).map_err(internal)?;
            return Ok(layout
                .components
                .iter()
                .map(|c| {
                    let clif_ty = clif_type_of(c.ty);
                    b.ins().load(clif_ty, flags(), addr, c.offset as i32)
                })
                .collect());
        }
        let (start, count, _) = self.place_parts(p)?;
        Ok(self.vars[p.var][start..start + count]
            .iter()
            .map(|v| b.use_var(*v))
            .collect())
    }

    fn type_needs_drop(&self, ty: Type) -> bool {
        match ty {
            // A future owns its task state, which owns whatever the suspended
            // body still holds.
            Type::Text
            | Type::Region(_)
            | Type::List(_)
            | Type::RegionList(..)
            | Type::Future(_)
            | Type::Task(_)
            | Type::TaskGroup(_) => true,
            Type::Array(a) => self.type_needs_drop(self.arrays[a].elem),
            Type::Struct(s) => self.structs[s]
                .fields
                .iter()
                .any(|(_, t)| self.type_needs_drop(*t)),
            Type::Enum(e) => self.enums[e]
                .variants
                .iter()
                .any(|(_, ts)| ts.iter().any(|t| self.type_needs_drop(*t))),
            _ => false,
        }
    }

    fn drop_in_place(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        addr: ir::Value,
        ty: Type,
    ) -> Result<(), Diagnostic> {
        match ty {
            Type::Text => {
                let ptr = b.ins().load(types::I64, flags(), addr, 0);
                let len = b.ins().load(types::I64, flags(), addr, 8);
                let cap = b.ins().load(types::I64, flags(), addr, 16);
                h.call(b, self.rt.text_drop, &[ptr, len, cap]);
            }
            Type::Struct(s) => {
                let layout = self.layouts.get(Type::Struct(s)).map_err(internal)?;
                for (i, (_, field_ty)) in self.structs[s].fields.iter().enumerate() {
                    if self.type_needs_drop(*field_ty) {
                        let field_off = layout.fields[i];
                        let field_addr = b.ins().iadd_imm_u(addr, field_off as i64);
                        self.drop_in_place(b, h, field_addr, *field_ty)?;
                    }
                }
            }
            Type::Enum(e) => {
                if !self.type_needs_drop(Type::Enum(e)) {
                    return Ok(());
                }
                let disc = b.ins().load(types::I64, flags(), addr, 0);
                let done = b.create_block();
                for (var_idx, (_, payload)) in self.enums[e].variants.iter().enumerate() {
                    let has_drop = payload.iter().any(|t| self.type_needs_drop(*t));
                    if !has_drop {
                        continue;
                    }
                    let drop_block = b.create_block();
                    let next_block = b.create_block();
                    let is_var = b.ins().icmp_imm_s(IntCC::Equal, disc, var_idx as i64);
                    brif(b, is_var, drop_block, next_block);
                    b.switch_to_block(drop_block);
                    for (f_idx, field_ty) in payload.iter().enumerate() {
                        if self.type_needs_drop(*field_ty) {
                            let f_off = self
                                .layouts
                                .variant_field_offset(e, var_idx, f_idx)
                                .map_err(internal)?;
                            let f_addr = b.ins().iadd_imm_u(addr, f_off as i64);
                            self.drop_in_place(b, h, f_addr, *field_ty)?;
                        }
                    }
                    jump(b, done, &[]);
                    b.switch_to_block(next_block);
                }
                jump(b, done, &[]);
                b.switch_to_block(done);
            }
            Type::Array(a) => {
                let def = self.arrays[a];
                if self.type_needs_drop(def.elem) {
                    let stride = self.stride(def.elem)?;
                    self.drop_elements(b, h, addr, def.len as i64, None, def.elem, stride)?;
                }
            }
            // Releasing a task: the state destructor frees whatever the
            // suspended body still owns, then the state block itself. A handle
            // that was never written, or already cleared, is null and owns
            // nothing.
            Type::Future(_) => {
                let ptr = b.ins().load(types::I64, flags(), addr, 0);
                let (release, done) = (b.create_block(), b.create_block());
                let live = b.ins().icmp_imm_s(IntCC::NotEqual, ptr, 0);
                brif(b, live, release, done);
                b.switch_to_block(release);
                let kind = b.ins().load(types::I64, flags(), ptr, 0);
                h.call(b, self.rt.drop_dispatch, &[kind, ptr]);
                h.call(b, self.rt.free, &[ptr]);
                jump(b, done, &[]);
                b.switch_to_block(done);
            }
            // Destroying a task handle cancels the task: the runtime releases
            // what its state still owns (in cascade, its own tasks) and its
            // record. A null handle (never written, or already moved out) owns
            // nothing.
            Type::Task(_) => {
                let ptr = b.ins().load(types::I64, flags(), addr, 0);
                h.call(b, self.rt.task_cancel, &[ptr]);
            }
            // A list's glue is a function of its own: element types may
            // contain lists of the same type (recursive data through the heap).
            Type::RegionList(l, _) => {
                let elem = self.lists[l];
                if self.type_needs_drop(elem) {
                    let ptr = b.ins().load(types::I64, flags(), addr, runtime::LIST_PTR);
                    let len = b.ins().load(types::I64, flags(), addr, runtime::LIST_LEN);
                    self.drop_elements(b, h, ptr, 0, Some(len), elem, self.stride(elem)?)?;
                }
            }
            Type::List(l) => {
                let ptr = b.ins().load(types::I64, flags(), addr, runtime::LIST_PTR);
                let len = b.ins().load(types::I64, flags(), addr, runtime::LIST_LEN);
                let cap = b.ins().load(types::I64, flags(), addr, runtime::LIST_CAP);
                h.call(b, self.list_drops[l], &[ptr, len, cap]);
            }
            Type::TaskGroup(g) => {
                let ptr = b.ins().load(types::I64, flags(), addr, runtime::LIST_PTR);
                let len = b.ins().load(types::I64, flags(), addr, runtime::LIST_LEN);
                let cap = b.ins().load(types::I64, flags(), addr, runtime::LIST_CAP);
                h.call(b, self.task_group_drops[g], &[ptr, len, cap]);
            }
            _ => {}
        }
        Ok(())
    }

    /// Drops elements `0..len` (constant `n` or dynamic `len`) at `data`.
    #[allow(clippy::too_many_arguments)]
    fn drop_elements(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        data: ir::Value,
        n: i64,
        len: Option<ir::Value>,
        elem: Type,
        stride: i64,
    ) -> Result<(), Diagnostic> {
        let len = match len {
            Some(v) => v,
            None => b.ins().iconst(types::I64, n),
        };
        let (head, body, exit) = (b.create_block(), b.create_block(), b.create_block());
        let i = b.append_block_param(head, types::I64);
        let zero = b.ins().iconst(types::I64, 0);
        jump(b, head, &[zero]);
        b.switch_to_block(head);
        let more = b.ins().icmp(IntCC::SignedLessThan, i, len);
        brif(b, more, body, exit);
        b.switch_to_block(body);
        let scaled = b.ins().imul_imm_s(i, stride);
        let at = b.ins().iadd(data, scaled);
        self.drop_in_place(b, h, at, elem)?;
        let next = b.ins().iadd_imm_s(i, 1);
        jump(b, head, &[next]);
        b.switch_to_block(exit);
        Ok(())
    }

    /// Body of `l_list_drop{l}(ptr, len, cap)`: drops the live elements,
    /// then releases the buffer (an unallocated list has `cap == 0`).
    fn list_drop_glue(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        l: usize,
    ) -> Result<(), Diagnostic> {
        let entry = b.create_block();
        b.append_block_params_for_function_params(entry);
        b.switch_to_block(entry);
        let params = b.block_params(entry).to_vec();
        let (ptr, len, cap) = (params[0], params[1], params[2]);
        let elem = self.lists[l];
        if self.type_needs_drop(elem) {
            let stride = self.stride(elem)?;
            self.drop_elements(b, h, ptr, 0, Some(len), elem, stride)?;
        }
        let (release, done) = (b.create_block(), b.create_block());
        let owned = b.ins().icmp_imm_s(IntCC::NotEqual, cap, 0);
        brif(b, owned, release, done);
        b.switch_to_block(release);
        h.call(b, self.rt.free, &[ptr]);
        jump(b, done, &[]);
        b.switch_to_block(done);
        b.ins().return_(&[]);
        Ok(())
    }

    /// Body of `l_task_group_drop{g}(ptr, len, cap)`: drops the task handles
    /// (cancelling any pending tasks), then releases the buffer.
    fn task_group_drop_glue(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        g: usize,
    ) -> Result<(), Diagnostic> {
        let entry = b.create_block();
        b.append_block_params_for_function_params(entry);
        b.switch_to_block(entry);
        let params = b.block_params(entry).to_vec();
        let (ptr, len, cap) = (params[0], params[1], params[2]);
        let elem = self.task_groups[g].elem;
        let task = self
            .futures
            .iter()
            .position(|f| f.result == elem)
            .unwrap_or(0);
        let task_ty = Type::Task(task);
        self.drop_elements(b, h, ptr, 0, Some(len), task_ty, 8)?;
        let (release, done) = (b.create_block(), b.create_block());
        let owned = b.ins().icmp_imm_s(IntCC::NotEqual, cap, 0);
        brif(b, owned, release, done);
        b.switch_to_block(release);
        h.call(b, self.rt.free, &[ptr]);
        jump(b, done, &[]);
        b.switch_to_block(done);
        b.ins().return_(&[]);
        Ok(())
    }

    fn var_values(&self, b: &mut FunctionBuilder, v: usize) -> Vec<ir::Value> {
        if let Some(slot) = self.slots.get(&v) {
            let base = b.ins().stack_addr(types::I64, *slot, 0);
            if let Ok(layout) = self.layouts.get(self.func.vars[v].pointee()) {
                return layout
                    .components
                    .iter()
                    .map(|c| {
                        let clif_ty = clif_type_of(c.ty);
                        b.ins().load(clif_ty, flags(), base, c.offset as i32)
                    })
                    .collect();
            }
        }
        self.vars[v].iter().map(|x| b.use_var(*x)).collect()
    }

    fn operand(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        op: &Operand,
    ) -> Result<Vec<ir::Value>, Diagnostic> {
        Ok(match op {
            Operand::Var(v) => self.var_values(b, *v),
            Operand::Const(Const::Int(n)) => vec![b.ins().iconst(types::I64, *n)],
            Operand::Const(Const::Bool(x)) => vec![b.ins().iconst(types::I8, i64::from(*x))],
            Operand::Const(Const::Float(bits)) => {
                vec![b.ins().f64const(f64::from_bits(*bits))]
            }
            Operand::Const(Const::F32(bits)) => {
                vec![b.ins().f32const(f32::from_bits(*bits))]
            }
            Operand::Const(Const::Unit) => Vec::new(),
            // Literal: static storage, capacity 0 (never freed).
            Operand::Const(Const::Text(s)) => {
                let (p, l) = h.text(b, s)?;
                let cap = b.ins().iconst(types::I64, 0);
                vec![p, l, cap]
            }
        })
    }

    /// Evaluates an argument to values (for builtins like Print and Append).
    fn arg_values(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        a: &Arg,
    ) -> Result<Vec<ir::Value>, Diagnostic> {
        match a {
            Arg::Value(op) => self.operand(b, h, op),
            Arg::Ref(p, _) => self.place_values(b, h, p),
        }
    }

    fn arg_type(&self, a: &Arg) -> Result<Type, Diagnostic> {
        Ok(match a {
            Arg::Value(op) => self.operand_type(op),
            Arg::Ref(p, _) => self.place_type(p)?,
        })
    }
    fn operand_type(&self, op: &Operand) -> Type {
        match op {
            Operand::Var(v) => self.func.vars[*v].pointee(),
            Operand::Const(c) => c.ty(),
        }
    }
    /// Branches to a panic block reporting `span` when `cond` is true.
    /// Branches to a located panic with `msg` when `cond` is true.
    fn panic_msg_if(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        cond: ir::Value,
        span: Span,
        msg: &str,
    ) -> Result<(), Diagnostic> {
        let fail = b.create_block();
        let ok = b.create_block();
        brif(b, cond, fail, ok);
        b.switch_to_block(fail);
        let line = b.ins().iconst(types::I64, span.line as i64);
        let col = b.ins().iconst(types::I64, span.column as i64);
        let (p, l) = h.text(b, msg)?;
        h.call(b, self.rt.panic_at, &[line, col, p, l]);
        never(b);
        b.switch_to_block(ok);
        Ok(())
    }
    /// Pointer and length of a buffer, after checking `index < len`.
    fn checked_byte_addr(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        p: &Place,
        index: &Operand,
        span: Span,
    ) -> Result<ir::Value, Diagnostic> {
        let buffer = self.place_values(b, h, p)?;
        let i = self.operand(b, h, index)?[0];
        // Unsigned comparison also rejects negative indices.
        let out = b
            .ins()
            .icmp(IntCC::UnsignedGreaterThanOrEqual, i, buffer[1]);
        let message = if self.place_type(p)? == Type::Text {
            runtime::INDEX_RANGE
        } else {
            runtime::INDEX_OUT_OF_RANGE
        };
        self.panic_msg_if(b, h, out, span, message)?;
        Ok(b.ins().iadd(buffer[0], i))
    }
    fn panic_if(&self, b: &mut FunctionBuilder, h: &mut Helpers, cond: ir::Value, span: Span) {
        let fail = b.create_block();
        let ok = b.create_block();
        brif(b, cond, fail, ok);
        b.switch_to_block(fail);
        let line = b.ins().iconst(types::I64, span.line as i64);
        let col = b.ins().iconst(types::I64, span.column as i64);
        h.call(b, self.rt.panic_arith, &[line, col]);
        never(b);
        b.switch_to_block(ok);
    }
    fn rvalue(
        &self,
        b: &mut FunctionBuilder,
        h: &mut Helpers,
        rv: &Rvalue,
        span: Span,
    ) -> Result<Vec<ir::Value>, Diagnostic> {
        Ok(match rv {
            // An array value is its elements' components in order.
            Rvalue::ArrayLit(_, ops) => {
                let mut values = Vec::new();
                for op in ops {
                    values.extend(self.operand(b, h, op)?);
                }
                values
            }
            Rvalue::ListLit(t, ops) => {
                let elem = self.elem_of(*t)?;
                let stride = self.stride(elem)?;
                let n = ops.len() as i64;
                if n == 0 {
                    // An empty list owns nothing until it grows.
                    let zero = b.ins().iconst(types::I64, 0);
                    return Ok(vec![zero, zero, zero]);
                }
                let bytes = n
                    .checked_mul(stride)
                    .ok_or_else(|| internal("literal de List demasiado grande"))?
                    .max(1);
                let size = b.ins().iconst(types::I64, bytes);
                let ptr = h.call(b, self.rt.alloc, &[size])[0];
                let layout = self.layouts.get(elem).map_err(internal)?;
                for (i, op) in ops.iter().enumerate() {
                    let values = self.operand(b, h, op)?;
                    for (c, v) in layout.components.iter().zip(values) {
                        let at = i as i64 * stride + i64::from(c.offset);
                        b.ins().store(flags(), v, ptr, at as i32);
                    }
                }
                let len = b.ins().iconst(types::I64, n);
                vec![ptr, len, len]
            }
            Rvalue::Len(p) => match self.place_type(p)? {
                Type::Text => vec![self.place_values(b, h, p)?[1]],
                Type::Array(a) => vec![b.ins().iconst(types::I64, self.arrays[a].len as i64)],
                Type::Slice(_) => vec![self.slice_parts(b, h, p)?[1]],
                _ => {
                    let addr = self.place_addr(b, h, p)?;
                    vec![b.ins().load(types::I64, flags(), addr, runtime::LIST_LEN)]
                }
            },
            Rvalue::Cap(p) => {
                let addr = self.place_addr(b, h, p)?;
                vec![b.ins().load(types::I64, flags(), addr, runtime::LIST_CAP)]
            }
            // The caller checked `len > 0`: the last element moves out and
            // the list stops owning it.
            Rvalue::ListTakeLast(p) => {
                let elem = self.elem_of(self.place_type(p)?)?;
                let hdr = self.place_addr(b, h, p)?;
                let ptr = b.ins().load(types::I64, flags(), hdr, runtime::LIST_PTR);
                let len = b.ins().load(types::I64, flags(), hdr, runtime::LIST_LEN);
                let last = b.ins().iadd_imm_s(len, -1);
                b.ins().store(flags(), last, hdr, runtime::LIST_LEN);
                let scaled = b.ins().imul_imm_s(last, self.stride(elem)?);
                let at = b.ins().iadd(ptr, scaled);
                let layout = self.layouts.get(elem).map_err(internal)?;
                layout
                    .components
                    .iter()
                    .map(|c| {
                        b.ins()
                            .load(clif_type_of(c.ty), flags(), at, c.offset as i32)
                    })
                    .collect()
            }
            // A new task state: zeroed, so `resume` is 0 (nothing has run
            // yet) and every field owns nothing until it is written.
            Rvalue::FutureNew(index) => {
                let info = &self.futures[*index];
                let size = self
                    .layouts
                    .get(Type::Struct(info.state))
                    .map_err(internal)?
                    .size
                    .max(1);
                let bytes = b.ins().iconst(types::I64, i64::from(size));
                let ptr = h.call(b, self.rt.alloc, &[bytes])[0];
                h.call(b, self.rt.zero, &[ptr, bytes]);
                vec![ptr]
            }
            // The handle is the address of the task state.
            Rvalue::FutureState(p) => vec![self.place_values(b, h, p)?[0]],
            Rvalue::FuturePoll(p) => {
                let state = self.place_values(b, h, p)?[0];
                let kind = b.ins().load(types::I64, flags(), state, 0);
                vec![h.call(b, self.rt.poll_dispatch, &[kind, state])[0]]
            }
            // Moving the future into the scheduler: the task record takes over
            // the state and the handle identifies it from now on.
            Rvalue::TaskSpawn(op, _index) => {
                let state = self.operand(b, h, op)?[0];
                let kind = b.ins().load(types::I64, flags(), state, 0);
                vec![h.call(b, self.rt.task_spawn, &[state, kind])[0]]
            }
            Rvalue::GroupRegister(p) => {
                let fields = self.place_values(b, h, p)?;
                vec![h.call(b, self.rt.group_register, &fields[..2])[0]]
            }
            Rvalue::CheckSleep(ms) => {
                let timers = self
                    .rt
                    .timers
                    .ok_or_else(|| internal("runtime de temporizador ausente"))?;
                let ms = self.operand(b, h, ms)?[0];
                let line = b.ins().iconst(types::I64, span.line as i64);
                let col = b.ins().iconst(types::I64, span.column as i64);
                vec![h.call(b, timers.check, &[ms, line, col])[0]]
            }
            Rvalue::TimerStart(ms) => {
                let timers = self
                    .rt
                    .timers
                    .ok_or_else(|| internal("runtime de temporizador ausente"))?;
                let ms = self.operand(b, h, ms)?[0];
                vec![h.call(b, timers.start, &[ms])[0]]
            }
            Rvalue::TimerPending => {
                let timers = self
                    .rt
                    .timers
                    .ok_or_else(|| internal("runtime de temporizador ausente"))?;
                vec![h.call(b, timers.pending, &[])[0]]
            }
            Rvalue::GroupPending => vec![h.call(b, self.rt.group_pending, &[])[0]],
            Rvalue::TaskReady(p) => {
                let task = self.place_values(b, h, p)?[0];
                vec![h.call(b, self.rt.task_ready, &[task])[0]]
            }
            Rvalue::TaskState(p) => {
                let task = self.place_values(b, h, p)?[0];
                vec![h.call(b, self.rt.task_state, &[task])[0]]
            }
            Rvalue::Use(op) => self.operand(b, h, op)?,
            Rvalue::Read(p) | Rvalue::FieldLoan(p) => self.place_values(b, h, p)?,
            Rvalue::Struct(_, fields) => {
                let mut values = Vec::new();
                for field in fields {
                    values.extend(self.operand(b, h, field)?);
                }
                values
            }
            Rvalue::Unary(UnOp::Not, op) => {
                let x = self.operand(b, h, op)?[0];
                vec![b.ins().bxor_imm_u(x, 1)]
            }
            Rvalue::Unary(UnOp::Neg, op) => {
                let ty = self.operand_type(op);
                let x = self.operand(b, h, op)?[0];
                if ty == Type::Float || ty == Type::F32 {
                    vec![b.ins().fneg(x)]
                } else {
                    let min = b.ins().icmp_imm_s(IntCC::Equal, x, i64::MIN);
                    self.panic_if(b, h, min, span);
                    vec![b.ins().ineg(x)]
                }
            }
            Rvalue::Binary(op, l, r) => {
                let ty = self.operand_type(l);
                let x = self.operand(b, h, l)?;
                let y = self.operand(b, h, r)?;
                if ty == Type::Unit {
                    let equal = matches!(op, BinOp::Eq | BinOp::Le | BinOp::Ge);
                    return Ok(vec![b.ins().iconst(types::I8, i64::from(equal))]);
                }
                let (x, y) = (x[0], y[0]);
                if ty == Type::Float || ty == Type::F32 {
                    let cond = match op {
                        BinOp::Eq => Some(FloatCC::Equal),
                        BinOp::Ne => Some(FloatCC::NotEqual),
                        BinOp::Lt => Some(FloatCC::LessThan),
                        BinOp::Le => Some(FloatCC::LessThanOrEqual),
                        BinOp::Gt => Some(FloatCC::GreaterThan),
                        BinOp::Ge => Some(FloatCC::GreaterThanOrEqual),
                        _ => None,
                    };
                    if let Some(c) = cond {
                        return Ok(vec![b.ins().fcmp(c, x, y)]);
                    }
                    let value = match op {
                        BinOp::Add => b.ins().fadd(x, y),
                        BinOp::Sub => b.ins().fsub(x, y),
                        BinOp::Mul => b.ins().fmul(x, y),
                        BinOp::Div => b.ins().fdiv(x, y),
                        _ => unreachable!("unsupported float operator"),
                    };
                    return Ok(vec![value]);
                }
                let cond = match op {
                    BinOp::Eq => Some(IntCC::Equal),
                    BinOp::Ne => Some(IntCC::NotEqual),
                    BinOp::Lt => Some(IntCC::SignedLessThan),
                    BinOp::Le => Some(IntCC::SignedLessThanOrEqual),
                    BinOp::Gt => Some(IntCC::SignedGreaterThan),
                    BinOp::Ge => Some(IntCC::SignedGreaterThanOrEqual),
                    _ => None,
                };
                if let Some(c) = cond {
                    return Ok(vec![b.ins().icmp(c, x, y)]);
                }
                let value = match op {
                    BinOp::Add => {
                        let (v, of) = b.ins().sadd_overflow(x, y);
                        self.panic_if(b, h, of, span);
                        v
                    }
                    BinOp::Sub => {
                        let (v, of) = b.ins().ssub_overflow(x, y);
                        self.panic_if(b, h, of, span);
                        v
                    }
                    BinOp::Mul => {
                        let (v, of) = b.ins().smul_overflow(x, y);
                        self.panic_if(b, h, of, span);
                        v
                    }
                    BinOp::Div | BinOp::Rem => {
                        let zero = b.ins().icmp_imm_s(IntCC::Equal, y, 0);
                        self.panic_if(b, h, zero, span);
                        let min = b.ins().icmp_imm_s(IntCC::Equal, x, i64::MIN);
                        let minus_one = b.ins().icmp_imm_s(IntCC::Equal, y, -1);
                        let overflow = b.ins().band(min, minus_one);
                        self.panic_if(b, h, overflow, span);
                        if *op == BinOp::Div {
                            b.ins().sdiv(x, y)
                        } else {
                            b.ins().srem(x, y)
                        }
                    }
                    _ => unreachable!("comparisons handled above"),
                };
                vec![value]
            }
            Rvalue::Convert(op, target) => {
                let src_ty = self.operand_type(op);
                let x = self.operand(b, h, op)?[0];
                let val = match (src_ty, target) {
                    (s, t) if s == *t => x,
                    (Type::Int, Type::Float) => b.ins().fcvt_from_sint(types::F64, x),
                    (Type::Int, Type::F32) => b.ins().fcvt_from_sint(types::F32, x),
                    (Type::Float, Type::Int) => b.ins().fcvt_to_sint_sat(types::I64, x),
                    (Type::Float, Type::F32) => b.ins().fdemote(types::F32, x),
                    (Type::F32, Type::Int) => b.ins().fcvt_to_sint_sat(types::I64, x),
                    (Type::F32, Type::Float) => b.ins().fpromote(types::F64, x),
                    _ => unreachable!(
                        "unsupported numeric conversion {:?} to {:?}",
                        src_ty, target
                    ),
                };
                vec![val]
            }
            Rvalue::Call(f, args) => {
                let callee = &self.funcs[*f];
                let mut values = Vec::new();
                for (param_var, a) in callee.params.iter().zip(args) {
                    match a {
                        Arg::Ref(p, _) if is_slice_ref(callee.vars[*param_var]) => {
                            values.extend(self.slice_parts(b, h, p)?);
                        }
                        Arg::Ref(p, _) if matches!(callee.vars[*param_var], VarTy::Ref(_)) => {
                            values.push(self.place_addr(b, h, p)?);
                        }
                        _ => {
                            values.extend(self.arg_values(b, h, a)?);
                        }
                    }
                }
                if callee.borrow_return.is_some() {
                    h.call(b, self.user[*f], &values)
                } else if callee.result == Type::Text {
                    h.call_text(b, self.user[*f], &values)
                } else if by_sret(callee.result) {
                    h.call_struct(
                        b,
                        self.user[*f],
                        &values,
                        &self.layouts.get(callee.result).map_err(internal)?,
                    )
                } else {
                    h.call(b, self.user[*f], &values)
                }
            }
            Rvalue::Loan(p, _, Type::Slice(_)) => self.slice_parts(b, h, p)?.to_vec(),
            Rvalue::Ref(p) | Rvalue::Loan(p, ..) => vec![self.place_addr(b, h, p)?],
            Rvalue::RegionNew(_) => {
                // The header lives in this frame for the region's lexical life.
                let slot = b.create_sized_stack_slot(ir::StackSlotData::new(
                    ir::StackSlotKind::ExplicitSlot,
                    runtime::REGION_HEADER_SIZE,
                    3,
                ));
                let hdr = b.ins().stack_addr(types::I64, slot, 0);
                let zero = b.ins().iconst(types::I64, 0);
                for offset in [0, 8, 16] {
                    b.ins().store(flags(), zero, hdr, offset);
                }
                vec![hdr]
            }
            Rvalue::RegionList(p, _) => {
                let region = self.place_values(b, h, p)?[0];
                let zero = b.ins().iconst(types::I64, 0);
                vec![zero, zero, zero, region]
            }
            Rvalue::RegionBytes(p, size) => {
                let hdr = self.place_values(b, h, p)?[0];
                let n = self.operand(b, h, size)?[0];
                let line = b.ins().iconst(types::I64, span.line as i64);
                let col = b.ins().iconst(types::I64, span.column as i64);
                let ptr = h.call(b, self.rt.region_alloc, &[hdr, n, line, col])[0];
                vec![ptr, n]
            }
            Rvalue::Platform(op, args, _) => self.platform(b, h, *op, args)?,
            Rvalue::BytesLen(p) => vec![self.place_values(b, h, p)?[1]],
            Rvalue::BytesGet(p, index) => {
                let addr = self.checked_byte_addr(b, h, p, index, span)?;
                let byte = b.ins().load(types::I8, flags(), addr, 0);
                vec![b.ins().uextend(types::I64, byte)]
            }
            Rvalue::TextBuffer(capacity) => {
                if *capacity == 0 {
                    // Nothing allocated until the first append.
                    self.operand(b, h, &Operand::Const(Const::Text(String::new())))?
                } else {
                    // At least the runtime's minimum, so short texts do not
                    // reallocate on their first non-literal part.
                    let size = b
                        .ins()
                        .iconst(types::I64, (*capacity as i64).max(runtime::MIN_CAPACITY));
                    let ptr = h.call(b, self.rt.alloc, &[size])[0];
                    let len = b.ins().iconst(types::I64, 0);
                    vec![ptr, len, size]
                }
            }
            Rvalue::TextEq(p, literal) => {
                let text = self.place_values(b, h, p)?;
                let (lp, ll) = h.text(b, literal)?;
                h.call(b, self.rt.text_eq, &[text[0], text[1], lp, ll])
            }
            Rvalue::Discriminant(p) => {
                let addr = self.place_addr(b, h, p)?;
                let disc = b.ins().load(types::I64, flags(), addr, 0);
                vec![disc]
            }
            Rvalue::Variant(e, variant, operands) => {
                let enum_layout = self.layouts.enum_layout(*e).map_err(internal)?;
                let slot = b.create_sized_stack_slot(ir::StackSlotData::new(
                    ir::StackSlotKind::ExplicitSlot,
                    enum_layout.layout.size.max(1),
                    enum_layout.layout.align.trailing_zeros() as u8,
                ));
                let base = b.ins().stack_addr(types::I64, slot, 0);
                // The full enum representation is subsequently loaded as
                // machine words. Zero-initialize every word first, including
                // inactive payload bytes, to avoid reading uninitialized
                // stack memory when building a unit variant.
                let zero = b.ins().iconst(types::I64, 0);
                for w in 0..(enum_layout.layout.size / 8) {
                    b.ins().store(flags(), zero, base, (w * 8) as i32);
                }
                let disc = b.ins().iconst(types::I64, *variant as i64);
                b.ins().store(flags(), disc, base, 0);
                for (i, op) in operands.iter().enumerate() {
                    let field_off = self
                        .layouts
                        .variant_field_offset(*e, *variant, i)
                        .map_err(internal)?;
                    let op_values = self.operand(b, h, op)?;
                    let op_ty = self.operand_type(op);
                    let op_layout = self.layouts.get(op_ty).map_err(internal)?;
                    for (c, val) in op_layout.components.iter().zip(&op_values) {
                        b.ins()
                            .store(flags(), *val, base, (field_off + c.offset) as i32);
                    }
                }
                let num_words = enum_layout.layout.size / 8;
                let mut words = Vec::new();
                for w in 0..num_words {
                    words.push(b.ins().load(types::I64, flags(), base, (w * 8) as i32));
                }
                words
            }
        })
    }
    fn build(&self, b: &mut FunctionBuilder, h: &mut Helpers) -> Result<(), Diagnostic> {
        let entry = self.blocks[0];
        b.append_block_params_for_function_params(entry);
        b.switch_to_block(entry);
        let params = b.block_params(entry).to_vec();
        let sret =
            (self.func.borrow_return.is_none() && by_sret(self.func.result)).then(|| params[0]);
        let mut i = usize::from(sret.is_some());
        for p in &self.func.params {
            match self.func.vars[*p] {
                VarTy::Value(_) => {
                    for var in &self.vars[*p] {
                        b.def_var(*var, params[i]);
                        i += 1;
                    }
                    if let Some(slot) = self.slots.get(p) {
                        let base = b.ins().stack_addr(types::I64, *slot, 0);
                        let layout = self
                            .layouts
                            .get(self.func.vars[*p].pointee())
                            .map_err(internal)?;
                        for (c, var) in layout.components.iter().zip(&self.vars[*p]) {
                            let val = b.use_var(*var);
                            b.ins().store(flags(), val, base, c.offset as i32);
                        }
                    }
                }
                VarTy::Ref(_) => {
                    for var in &self.vars[*p] {
                        b.def_var(*var, params[i]);
                        i += 1;
                    }
                }
            }
        }
        for (id, block) in self.func.blocks.iter().enumerate() {
            if id != 0 {
                b.switch_to_block(self.blocks[id]);
            }
            for inst in &block.insts {
                self.span.set(inst.span);
                match &inst.kind {
                    InstKind::Assign(dest, rv) => {
                        let values = self.rvalue(b, h, rv, inst.span)?;
                        for (var, value) in self.vars[*dest].iter().zip(&values) {
                            b.def_var(*var, *value);
                        }
                        if let Some(slot) = self.slots.get(dest) {
                            let base = b.ins().stack_addr(types::I64, *slot, 0);
                            let layout = self
                                .layouts
                                .get(self.func.vars[*dest].pointee())
                                .map_err(internal)?;
                            for (c, value) in layout.components.iter().zip(&values) {
                                b.ins().store(flags(), *value, base, c.offset as i32);
                            }
                        }
                    }
                    InstKind::ListPush(p, op) => {
                        // The element is evaluated before the list may move.
                        let values = self.operand(b, h, op)?;
                        let list = self.place_type(p)?;
                        let elem = self.elem_of(list)?;
                        let stride = self.stride(elem)?;
                        let hdr = self.place_addr(b, h, p)?;
                        let len = b.ins().load(types::I64, flags(), hdr, runtime::LIST_LEN);
                        let cap = b.ins().load(types::I64, flags(), hdr, runtime::LIST_CAP);
                        let full = b.ins().icmp(IntCC::Equal, len, cap);
                        let (grow, ready) = (b.create_block(), b.create_block());
                        brif(b, full, grow, ready);
                        b.switch_to_block(grow);
                        let one = b.ins().iconst(types::I64, 1);
                        let stride_v = b.ins().iconst(types::I64, stride);
                        let min = b.ins().iconst(types::I64, 4);
                        let line = b.ins().iconst(types::I64, inst.span.line as i64);
                        let col = b.ins().iconst(types::I64, inst.span.column as i64);
                        let region = self.list_region(b, hdr, list);
                        h.call(
                            b,
                            self.rt.list_reserve,
                            &[hdr, one, stride_v, min, line, col, region],
                        );
                        jump(b, ready, &[]);
                        b.switch_to_block(ready);
                        let ptr = b.ins().load(types::I64, flags(), hdr, runtime::LIST_PTR);
                        let scaled = b.ins().imul_imm_s(len, stride);
                        let at = b.ins().iadd(ptr, scaled);
                        let layout = self.layouts.get(elem).map_err(internal)?;
                        for (c, v) in layout.components.iter().zip(values) {
                            b.ins().store(flags(), v, at, c.offset as i32);
                        }
                        let new_len = b.ins().iadd_imm_s(len, 1);
                        b.ins().store(flags(), new_len, hdr, runtime::LIST_LEN);
                    }
                    InstKind::ListReserve(p, op) => {
                        let n = self.operand(b, h, op)?[0];
                        let list = self.place_type(p)?;
                        let elem = self.elem_of(list)?;
                        let stride = b.ins().iconst(types::I64, self.stride(elem)?);
                        let hdr = self.place_addr(b, h, p)?;
                        let min = b.ins().iconst(types::I64, 0);
                        let line = b.ins().iconst(types::I64, inst.span.line as i64);
                        let col = b.ins().iconst(types::I64, inst.span.column as i64);
                        let region = self.list_region(b, hdr, list);
                        h.call(
                            b,
                            self.rt.list_reserve,
                            &[hdr, n, stride, min, line, col, region],
                        );
                    }
                    InstKind::BytesSet(p, index, byte) => {
                        let addr = self.checked_byte_addr(b, h, p, index, inst.span)?;
                        let v = self.operand(b, h, byte)?[0];
                        let wide = b.ins().icmp_imm_u(IntCC::UnsignedGreaterThan, v, 255);
                        self.panic_msg_if(b, h, wide, inst.span, runtime::BYTE_OUT_OF_RANGE)?;
                        b.ins().istore8(flags(), v, addr, 0);
                    }
                    InstKind::Print(arg) => {
                        let values = self.arg_values(b, h, arg)?;
                        match self.arg_type(arg)? {
                            Type::Int => h.call(b, self.rt.print_int, &values),
                            Type::Bool => h.call(b, self.rt.print_bool, &values),
                            Type::Float => h.call(b, self.rt.print_float, &values),
                            Type::F32 => h.call(b, self.rt.print_f32, &values),
                            Type::Text => h.call(b, self.rt.print_text, &values[..2]),
                            _ => return Err(unsupported(inst.span, "print de este tipo")),
                        };
                    }
                    InstKind::Append(target, arg) => {
                        let mut values = self.var_values(b, *target);
                        let part = self.arg_values(b, h, arg)?;
                        let f = match self.arg_type(arg)? {
                            Type::Int => self.rt.push_int,
                            Type::Bool => self.rt.push_bool,
                            Type::Float => self.rt.push_float,
                            Type::F32 => self.rt.push_f32,
                            Type::Text => self.rt.push_text,
                            _ => return Err(unsupported(inst.span, "formato de este tipo")),
                        };
                        values.extend(match self.arg_type(arg)? {
                            Type::Text => part[..2].to_vec(),
                            _ => part,
                        });
                        let result = h.call_text(b, f, &values);
                        for (var, value) in self.vars[*target].iter().zip(result) {
                            b.def_var(*var, value);
                        }
                    }
                    InstKind::Drop(v, flag) => {
                        let ty = self.func.vars[*v].pointee();
                        if !self.type_needs_drop(ty) {
                            continue;
                        }
                        if let Type::Region(_) = ty {
                            // Releases every block; the header itself is in the frame.
                            let hdr = self.var_values(b, *v)[0];
                            match flag {
                                None => {
                                    h.call(b, self.rt.region_free, &[hdr]);
                                }
                                Some(f) => {
                                    let cond = self.var_values(b, *f)[0];
                                    let (drop_b, done_b) = (b.create_block(), b.create_block());
                                    brif(b, cond, drop_b, done_b);
                                    b.switch_to_block(drop_b);
                                    h.call(b, self.rt.region_free, &[hdr]);
                                    jump(b, done_b, &[]);
                                    b.switch_to_block(done_b);
                                }
                            }
                            continue;
                        }
                        if ty == Type::Text
                            && !self.slots.contains_key(v)
                            && !matches!(self.func.vars[*v], VarTy::Ref(_))
                        {
                            let values = self.var_values(b, *v);
                            match flag {
                                None => {
                                    h.call(b, self.rt.text_drop, &values);
                                }
                                Some(f) => {
                                    let cond = self.var_values(b, *f)[0];
                                    let (drop_b, done_b) = (b.create_block(), b.create_block());
                                    brif(b, cond, drop_b, done_b);
                                    b.switch_to_block(drop_b);
                                    h.call(b, self.rt.text_drop, &values);
                                    jump(b, done_b, &[]);
                                    b.switch_to_block(done_b);
                                }
                            }
                        } else {
                            let addr = self.place_addr(
                                b,
                                h,
                                &Place {
                                    var: *v,
                                    proj: Vec::new(),
                                },
                            )?;
                            match flag {
                                None => {
                                    self.drop_in_place(b, h, addr, ty)?;
                                }
                                Some(f) => {
                                    let cond = self.var_values(b, *f)[0];
                                    let (drop_b, done_b) = (b.create_block(), b.create_block());
                                    brif(b, cond, drop_b, done_b);
                                    b.switch_to_block(drop_b);
                                    self.drop_in_place(b, h, addr, ty)?;
                                    jump(b, done_b, &[]);
                                    b.switch_to_block(done_b);
                                }
                            }
                        }
                    }
                    // The place stops owning what it held: the value was
                    // moved out first, so only the bits are discarded.
                    InstKind::Clear(p) => {
                        let ty = self.place_type(p)?;
                        let size = self.layouts.get(ty).map_err(internal)?.size;
                        if size > 0 {
                            let addr = self.place_addr(b, h, p)?;
                            let bytes = b.ins().iconst(types::I64, i64::from(size));
                            h.call(b, self.rt.zero, &[addr, bytes]);
                        }
                    }
                    InstKind::Wake => {
                        h.call(b, self.rt.wake, &[]);
                    }
                    InstKind::RunTasks => {
                        h.call(b, self.rt.run, &[]);
                    }
                    InstKind::Moved(_) => {}
                    // A field owning a collection is dropped through its glue.
                    InstKind::DropField(p, flag) if self.place_type(p)? != Type::Text => {
                        let ty = self.place_type(p)?;
                        let (drop_b, done_b) = (b.create_block(), b.create_block());
                        match flag {
                            Some(f) => {
                                let cond = self.var_values(b, *f)[0];
                                brif(b, cond, drop_b, done_b);
                            }
                            None => jump(b, drop_b, &[]),
                        }
                        b.switch_to_block(drop_b);
                        let addr = self.place_addr(b, h, p)?;
                        self.drop_in_place(b, h, addr, ty)?;
                        jump(b, done_b, &[]);
                        b.switch_to_block(done_b);
                    }
                    InstKind::DropField(p, flag) => {
                        let values = self.place_values(b, h, p)?;
                        if let Some(f) = flag {
                            let cond = self.var_values(b, *f)[0];
                            let (drop, done) = (b.create_block(), b.create_block());
                            brif(b, cond, drop, done);
                            b.switch_to_block(drop);
                            h.call(b, self.rt.text_drop, &values);
                            jump(b, done, &[]);
                            b.switch_to_block(done);
                        } else {
                            h.call(b, self.rt.text_drop, &values);
                        }
                    }
                    InstKind::Store(p, op) => {
                        let values = self.operand(b, h, op)?;
                        let is_ref = matches!(self.func.vars[p.var], VarTy::Ref(_));
                        let has_slot = self.slots.contains_key(&p.var);
                        let is_enum = matches!(self.func.vars[p.var].pointee(), Type::Enum(_));
                        if is_ref || has_slot || is_enum {
                            let addr = self.place_addr(b, h, p)?;
                            let ty = self.place_type(p)?;
                            // Storing into an element replaces it: the old
                            // element is dropped first (it is initialized).
                            if (is_ref && p.proj.is_empty()
                                || p.proj.iter().any(|x| matches!(x, cfg::Proj::Index(_))))
                                && self.type_needs_drop(ty)
                            {
                                self.drop_in_place(b, h, addr, ty)?;
                            }
                            let layout = self.layouts.get(ty).map_err(internal)?;
                            for (c, val) in layout.components.iter().zip(&values) {
                                b.ins().store(flags(), *val, addr, c.offset as i32);
                            }
                        }
                        // A variable kept in memory is only read from memory.
                        if !is_ref && !is_enum && !has_slot {
                            let (start, count, _) = self.place_parts(p)?;
                            for (var, val) in
                                self.vars[p.var][start..start + count].iter().zip(values)
                            {
                                b.def_var(*var, val);
                            }
                        }
                    }
                }
            }
            match block
                .term
                .as_ref()
                .ok_or_else(|| internal("bloque sin terminador"))?
            {
                Terminator::Jump(t) => jump(b, self.blocks[*t], &[]),
                Terminator::Branch(c, t, e) => {
                    let c = self.operand(b, h, c)?[0];
                    brif(b, c, self.blocks[*t], self.blocks[*e]);
                }
                Terminator::Suspend(_) => {
                    let pending = b.ins().iconst(types::I64, cfg::POLL_PENDING);
                    b.ins().return_(&[pending]);
                }
                Terminator::ReturnRef(var, _) => {
                    let values = self.var_values(b, *var);
                    b.ins().return_(&values);
                }
                Terminator::Return(op) => {
                    let values = self.operand(b, h, op)?;
                    match sret {
                        Some(out) if self.func.result != Type::Text => {
                            let layout = self.layouts.get(self.func.result).map_err(internal)?;
                            for (c, value) in layout.components.iter().zip(values) {
                                b.ins().store(flags(), value, out, c.offset as i32);
                            }
                            b.ins().return_(&[]);
                        }
                        Some(out) => return_text(b, out, &values),
                        None => {
                            b.ins().return_(&values);
                        }
                    }
                }
                Terminator::Unreachable => never(b),
            }
        }
        Ok(())
    }
}

/// Whether a value of type `t` holds a collection header or a task handle by
/// value: those live in memory so that elements and state can be reached by
/// computed addresses and released in place.
fn contains_collection(t: Type, module: &cfg::Module) -> bool {
    match t {
        Type::Array(_)
        | Type::List(_)
        | Type::RegionList(..)
        | Type::TaskGroup(_)
        | Type::Future(_)
        | Type::Task(_) => true,
        Type::Struct(s) => module.structs[s]
            .fields
            .iter()
            .any(|(_, f)| contains_collection(*f, module)),
        Type::Enum(e) => module.enums[e]
            .variants
            .iter()
            .any(|(_, ts)| ts.iter().any(|f| contains_collection(*f, module))),
        _ => false,
    }
}

/// Timer-enabled objects import the monotonic clock from the Windows SDK.
pub fn uses_timers(module: &cfg::Module) -> bool {
    module
        .funcs
        .iter()
        .flat_map(|f| &f.blocks)
        .flat_map(|block| &block.insts)
        .any(|inst| matches!(inst.kind, InstKind::Assign(_, Rvalue::TimerStart(_))))
}

pub fn uses_platform(module: &cfg::Module) -> bool {
    module
        .funcs
        .iter()
        .flat_map(|f| &f.blocks)
        .flat_map(|block| &block.insts)
        .any(|inst| matches!(inst.kind, InstKind::Assign(_, Rvalue::Platform(op, ..)) if op != PlatformOp::PrintError))
}

#[cfg(all(windows, target_arch = "x86_64"))]
pub fn platform_object() -> &'static [u8] {
    include_bytes!(concat!(env!("OUT_DIR"), "/l_platform.obj"))
}

#[cfg(not(all(windows, target_arch = "x86_64")))]
pub fn platform_object() -> &'static [u8] {
    &[]
}

/// Compiles a verified CFG module to a relocatable object file whose entry
/// point symbol is `l_start`.
pub fn compile(module: &cfg::Module, options: Options) -> Result<Vec<u8>, Diagnostic> {
    check_supported(module)?;
    let layouts = layouts_of(module)?;
    let mut g = Gen::new()?;
    let timers_enabled = uses_timers(module);
    let rt = g.runtime(options, timers_enabled, uses_platform(module))?;
    let list_drops = (0..module.lists.len())
        .map(|l| {
            g.declare(
                &format!("l_list_drop{l}"),
                Linkage::Local,
                &[types::I64; 3],
                &[],
            )
        })
        .collect::<Result<Vec<_>, Diagnostic>>()?;
    let task_group_drops = (0..module.task_groups.len())
        .map(|idx| {
            g.declare(
                &format!("l_task_group_drop{idx}"),
                Linkage::Local,
                &[types::I64; 3],
                &[],
            )
        })
        .collect::<Result<Vec<_>, Diagnostic>>()?;
    let mut user = Vec::new();
    let mut sigs = Vec::new();
    for (i, f) in module.funcs.iter().enumerate() {
        let text_result = f.borrow_return.is_none() && by_sret(f.result);
        let mut params: Vec<ir::Type> = if text_result {
            vec![types::I64]
        } else {
            Vec::new()
        };
        for p in &f.params {
            match f.vars[*p] {
                VarTy::Value(t) => params.extend(clif_types(t, &layouts)?),
                VarTy::Ref(_) if is_slice_ref(f.vars[*p]) => params.extend([types::I64; 2]),
                VarTy::Ref(_) => params.push(types::I64),
            }
        }
        let returns = if f.borrow_return.is_some() {
            vec![
                types::I64;
                if is_slice_ref(VarTy::Ref(f.result)) {
                    2
                } else {
                    1
                }
            ]
        } else if text_result {
            Vec::new()
        } else {
            clif_types(f.result, &layouts)?
        };
        user.push(g.declare(&format!("l_f{i}"), Linkage::Local, &params, &returns)?);
        sigs.push((params, returns));
    }
    for (i, f) in module.funcs.iter().enumerate() {
        let (params, returns) = sigs[i].clone();
        g.define(user[i], &params, &returns, |b, h| {
            let mut borrowed_vars = HashSet::new();
            for block in &f.blocks {
                for inst in &block.insts {
                    match &inst.kind {
                        InstKind::Assign(_, Rvalue::Call(_, args)) => {
                            for arg in args {
                                if let Arg::Ref(p, _) = arg
                                    && matches!(f.vars[p.var], VarTy::Value(_))
                                {
                                    borrowed_vars.insert(p.var);
                                }
                            }
                        }
                        InstKind::Assign(_, Rvalue::Ref(p) | Rvalue::Loan(p, ..)) => {
                            if matches!(f.vars[p.var], VarTy::Value(_)) {
                                borrowed_vars.insert(p.var);
                            }
                        }
                        _ => {}
                    }
                }
            }
            let mut slots = HashMap::new();
            for (v, var_ty) in f.vars.iter().enumerate() {
                let ty = var_ty.pointee();
                // Collections (and values containing them) live in memory:
                // elements are reached by computed addresses.
                let in_memory =
                    matches!(var_ty, VarTy::Value(_)) && contains_collection(ty, module);
                if matches!(var_ty, VarTy::Value(_))
                    && (matches!(ty, Type::Enum(_)) || borrowed_vars.contains(&v) || in_memory)
                {
                    let layout = layouts.get(ty).map_err(internal)?;
                    let slot = b.create_sized_stack_slot(ir::StackSlotData::new(
                        ir::StackSlotKind::ExplicitSlot,
                        layout.size.max(1),
                        layout.align.trailing_zeros() as u8,
                    ));
                    slots.insert(v, slot);
                }
            }
            let vars = f
                .vars
                .iter()
                .map(|t| match t {
                    VarTy::Value(t) => Ok(clif_types(*t, &layouts)?
                        .into_iter()
                        .map(|ty| b.declare_var(ty))
                        .collect()),
                    VarTy::Ref(_) if is_slice_ref(*t) => {
                        Ok(vec![b.declare_var(types::I64), b.declare_var(types::I64)])
                    }
                    VarTy::Ref(_) => Ok(vec![b.declare_var(types::I64)]),
                })
                .collect::<Result<Vec<_>, Diagnostic>>()?;
            let blocks = f.blocks.iter().map(|_| b.create_block()).collect();
            FnGen {
                func: f,
                funcs: &module.funcs,
                vars,
                slots,
                blocks,
                user: &user,
                rt: &rt,
                layouts: &layouts,
                structs: &module.structs,
                enums: &module.enums,
                futures: &module.futures,
                arrays: &module.arrays,
                lists: &module.lists,
                slices: &module.slices,
                task_groups: &module.task_groups,
                list_drops: &list_drops,
                task_group_drops: &task_group_drops,
                span: Cell::new(Span { line: 1, column: 1 }),
            }
            .build(b, h)
        })?;
    }
    // Drop glue of every list type (only needs the type tables).
    for (l, id) in list_drops.iter().enumerate() {
        g.define(*id, &[types::I64; 3], &[], |b, h| {
            FnGen {
                func: &module.funcs[module.main],
                funcs: &module.funcs,
                vars: Vec::new(),
                slots: HashMap::new(),
                blocks: Vec::new(),
                user: &user,
                rt: &rt,
                layouts: &layouts,
                structs: &module.structs,
                enums: &module.enums,
                futures: &module.futures,
                arrays: &module.arrays,
                lists: &module.lists,
                slices: &module.slices,
                task_groups: &module.task_groups,
                list_drops: &list_drops,
                task_group_drops: &task_group_drops,
                span: Cell::new(Span { line: 1, column: 1 }),
            }
            .list_drop_glue(b, h, l)
        })?;
    }
    // Drop glue of every task group type.
    for (group_idx, id) in task_group_drops.iter().enumerate() {
        g.define(*id, &[types::I64; 3], &[], |b, h| {
            FnGen {
                func: &module.funcs[module.main],
                funcs: &module.funcs,
                vars: Vec::new(),
                slots: HashMap::new(),
                blocks: Vec::new(),
                user: &user,
                rt: &rt,
                layouts: &layouts,
                structs: &module.structs,
                enums: &module.enums,
                futures: &module.futures,
                arrays: &module.arrays,
                lists: &module.lists,
                slices: &module.slices,
                task_groups: &module.task_groups,
                list_drops: &list_drops,
                task_group_drops: &task_group_drops,
                span: Cell::new(Span { line: 1, column: 1 }),
            }
            .task_group_drop_glue(b, h, group_idx)
        })?;
    }
    // Dispatch of the scheduler to the state machine of each future type:
    // generated here, where the `poll` and destructor of every async function
    // are already declared. The scheduler itself stays type-agnostic.
    g.dispatch(
        rt.poll_dispatch,
        &[types::I64; 2],
        &[types::I64],
        &module.futures,
        &user,
        |info| info.poll,
    )?;
    g.dispatch(
        rt.drop_dispatch,
        &[types::I64; 2],
        &[],
        &module.futures,
        &user,
        |info| info.drop,
    )?;
    g.entry_point(
        &rt,
        user[module.main],
        module.funcs[module.main].result == Type::Int,
        options,
    )?;
    g.module.finish().emit().map_err(internal)
}
