//! Runtime of the native backend, generated as Cranelift IR in the program's
//! own object file. It depends only on kernel32 (Windows x86-64):
//! `GetStdHandle`, `WriteFile`, `ExitProcess`, `GetProcessHeap`, `HeapAlloc`,
//! `HeapReAlloc`, `HeapFree` and `HeapValidate`. No Rust, no C runtime.
//!
//! Stable internal interface (all `l_rt_*` symbols are local to the object):
//!
//! | Function | Contract |
//! |---|---|
//! | `alloc(size) -> ptr` | Heap block of `size > 0` bytes; out of memory → panic, never null |
//! | `realloc(ptr, size) -> ptr` | Grows a block from `alloc`; out of memory → panic |
//! | `free(ptr)` | Releases a block from `alloc`/`realloc` exactly once |
//! | `list_reserve(hdr, n, stride, min, line, col, region)` | Ensures `cap - len >= n` for the list header at `hdr` (policy below); panics on negative `n`, overflow or OOM |
//! | `wake()` | Marks the running task ready to be polled again |
//! | `task_spawn(state, kind) -> task` | Registers a task in the scheduler's ready queue; the task record owns the state |
//! | `task_ready(task) -> i64` | `1` if it already finished; otherwise registers the running task as its waiter |
//! | `task_state(task) -> ptr` | State of the task, to take its result |
//! | `task_cancel(task)` | Destroys the task: releases its state (and in cascade its children) and its record |
//! | `run()` | Cooperative scheduler: polls ready tasks until none is left; reports a deadlock if any stays suspended |
//! | `text_push(p, l, c, src, n) -> (p, l, c)` | Appends `n` bytes; takes ownership of the buffer and returns it |
//! | `text_push_int/bool(p, l, c, x) -> (p, l, c)` | Appends the decimal / `true`/`false` form |
//! | `text_drop(p, l, c)` | Frees the buffer iff `c != 0` (static Text has `c == 0`) |
//! | `text_eq(p1, l1, p2, l2) -> i8` | Byte equality |
//! | `print_int/bool/text` | Value and `\n` to stdout |
//! | `panic_arith(line, col)` | Message to stderr, abnormal exit |
use super::{Gen, Helpers, Options, brif, flags, jump, never, return_text};
use crate::Diagnostic;
use cranelift_codegen::ir::{
    self, BlockArg, InstBuilder, StackSlotData, StackSlotKind,
    condcodes::{FloatCC, IntCC},
    types,
};
use cranelift_frontend::FunctionBuilder;
use cranelift_module::{DataId, FuncId, Linkage};

#[path = "timers.rs"]
mod timers;
use timers::Timers;

/// Exit status used for `panic` (abnormal termination). On Windows it is the
/// same status as an aborted process (`STATUS_STACK_BUFFER_OVERRUN`, used by
/// `__fastfail`), which is also what the rustc backend produces.
pub const PANIC_EXIT_CODE: u32 = 0xC000_0409;
/// Standard handles for `GetStdHandle`.
const STDOUT: i64 = -11;
pub(super) const STDERR: i64 = -12;
const ARITH_MESSAGE: &str = ": overflow entero o división/resto por cero\n";
const OOM_MESSAGE: &str = "ELE: memoria insuficiente\n";
const BAD_FREE_MESSAGE: &str = "ELE: liberación de memoria inválida\n";
/// Smallest heap buffer allocated for a growing Text.
pub(crate) const MIN_CAPACITY: i64 = 16;
/// Offsets of the counters in the statistics block.
const ALLOCS: i32 = 0;
const REALLOCS: i32 = 8;
const FREES: i32 = 16;
const ATTEMPTS: i32 = 24;
const REGION_ALLOCS: i32 = 32;
const REGION_BYTES: i32 = 40;
const REGION_RETIRED: i32 = 48;
/// Suspensions the executor actually observed (a poll that returned Pending).
const SUSPENDS: i32 = 56;
/// Smallest block a region reserves from the heap.
const REGION_MIN_BLOCK: i64 = 4096;
/// Bytes before the data of a region block: pointer to the previous block
/// and padding to keep data 16-aligned.
const REGION_BLOCK_HEADER: i64 = 16;
/// Offsets in a region header: current block, bump offset, block capacity.
const REGION_BLOCK: i32 = 0;
const REGION_OFFSET: i32 = 8;
const REGION_CAPACITY: i32 = 16;
pub(crate) const REGION_HEADER_SIZE: u32 = 24;
pub(crate) const NEGATIVE_SIZE: &str = ": tamaño de buffer negativo\n";
pub(crate) const INDEX_OUT_OF_RANGE: &str = ": índice de buffer fuera de rango\n";
pub(crate) const INDEX_RANGE: &str = ": índice fuera de rango\n";
pub(crate) const NEGATIVE_RESERVE: &str = ": reserve con tamaño negativo\n";
pub(crate) const CAPACITY_OVERFLOW: &str = ": capacidad de List desbordada\n";
/// Offsets in a list header `(ptr, len, cap)`.
pub(crate) const LIST_PTR: i32 = 0;
pub(crate) const LIST_LEN: i32 = 8;
pub(crate) const LIST_CAP: i32 = 16;
pub(crate) const LIST_REGION: i32 = 24;
pub(crate) const BYTE_OUT_OF_RANGE: &str = ": valor de byte fuera de rango (0..=255)\n";
const MISALIGNED: &str = "ELE: reserva de región desalineada\n";
const DEADLOCK_MESSAGE: &str = "ELE: tarea suspendida sin notificación (interbloqueo)\n";
/// Offsets in a task record of the scheduler (heap, never moved, so
/// a handle to it stays valid while the task lives).
const TASK_STATE: i32 = 0;
/// Future type index of the task: selects its `poll` and its destructor.
const TASK_KIND: i32 = 8;
/// `TASK_READY` / `TASK_PENDING` / `TASK_DONE` / `TASK_CANCELLED`.
const TASK_STATUS: i32 = 16;
/// Next record in the ready queue (intrusive, doubly linked, FIFO).
const TASK_NEXT: i32 = 24;
/// Task waiting for this one to finish (its record), or 0.
const TASK_WAITER: i32 = 32;
/// 1 while the record is in the ready queue.
const TASK_QUEUED: i32 = 40;
/// Next record waiting to be destroyed, while a cancellation is in progress.
const TASK_PURGE: i32 = 48;
/// Previous record in the ready queue, so leaving it costs O(1).
const TASK_PREV: i32 = 56;
/// Number of children still running during a group wait, or zero.
const TASK_GROUP_PENDING: i32 = 64;
const TASK_RECORD_SIZE: i64 = 72;
const TASK_READY: i64 = 0;
const TASK_PENDING: i64 = 1;
const TASK_DONE: i64 = 2;

pub(crate) struct Runtime {
    pub(crate) platform: Option<super::platform::Platform>,
    exit_process: FuncId,
    get_process_heap: FuncId,
    heap_validate: FuncId,
    pub(super) write: FuncId,
    write_int: FuncId,
    pub(crate) alloc: FuncId,
    pub(crate) print_int: FuncId,
    pub(crate) print_bool: FuncId,
    pub(crate) print_text: FuncId,
    pub(crate) print_float: FuncId,
    pub(crate) print_f32: FuncId,
    pub(crate) panic_arith: FuncId,
    pub(crate) push_text: FuncId,
    pub(crate) push_int: FuncId,
    pub(crate) push_bool: FuncId,
    pub(crate) push_float: FuncId,
    pub(crate) push_f32: FuncId,
    pub(crate) text_drop: FuncId,
    pub(crate) text_eq: FuncId,
    /// `l_rt_region_alloc(header, n, line, col) -> ptr`: n zeroed, 8-aligned bytes.
    pub(crate) region_alloc: FuncId,
    /// `l_rt_region_free(header)`: releases every block of the region.
    pub(crate) region_free: FuncId,
    /// `l_rt_panic_at(line, col, msg, len)`: located panic with a message.
    pub(crate) panic_at: FuncId,
    /// `l_rt_free(ptr)`: releases a heap block.
    pub(crate) free: FuncId,
    /// `l_rt_zero(ptr, n)`: writes `n` zero bytes.
    pub(crate) zero: FuncId,
    /// `l_rt_wake()`: the running task is ready to be polled again.
    pub(crate) wake: FuncId,
    pub(crate) timers: Option<Timers>,
    /// `l_rt_task_spawn(state, kind) -> task`: registers a ready task.
    pub(crate) task_spawn: FuncId,
    /// `l_rt_task_ready(task) -> i64`: finished, or register the waiter.
    pub(crate) task_ready: FuncId,
    pub(crate) group_register: FuncId,
    pub(crate) group_pending: FuncId,
    /// `l_rt_task_state(task) -> ptr`: state of the task.
    pub(crate) task_state: FuncId,
    /// `l_rt_task_cancel(task)`: destroys the task and releases its state.
    pub(crate) task_cancel: FuncId,
    /// `l_rt_run()`: the cooperative scheduler.
    pub(crate) run: FuncId,
    /// `l_task_poll(kind, state) -> i64`: dispatch to the `poll` of the future
    /// type, defined by the backend once the user functions exist.
    pub(crate) poll_dispatch: FuncId,
    /// `l_task_drop(kind, state)`: dispatch to the state destructor.
    pub(crate) drop_dispatch: FuncId,
    /// `l_rt_list_reserve(hdr, n, stride, min, line, col, region)`.
    pub(crate) list_reserve: FuncId,
    stats: Option<DataId>,
}

/// Entry block with the function parameters bound.
fn enter(b: &mut FunctionBuilder) -> Vec<ir::Value> {
    let entry = b.create_block();
    b.append_block_params_for_function_params(entry);
    b.switch_to_block(entry);
    b.block_params(entry).to_vec()
}

fn slot(b: &mut FunctionBuilder, size: u32) -> ir::StackSlot {
    b.create_sized_stack_slot(StackSlotData::new(StackSlotKind::ExplicitSlot, size, 3))
}

/// `counter += 1` in the statistics block, returning the new value.
fn bump(b: &mut FunctionBuilder, h: &mut Helpers, stats: DataId, offset: i32) -> ir::Value {
    let base = h.data_addr(b, stats);
    let old = b.ins().load(types::I64, flags(), base, offset);
    let new = b.ins().iadd_imm_s(old, 1);
    b.ins().store(flags(), new, base, offset);
    new
}

impl Gen {
    pub(crate) fn runtime(
        &mut self,
        options: Options,
        timers_enabled: bool,
        platform_enabled: bool,
    ) -> Result<Runtime, Diagnostic> {
        use types::{F32, F64, I8, I32, I64};
        let counting = options.trace_alloc || options.fail_alloc_after.is_some();
        let stats = if counting {
            Some(self.zeroed(
                "l_rt_stats",
                if timers_enabled {
                    timers::STATS_SIZE
                } else {
                    64
                },
            )?)
        } else {
            None
        };
        let get_std_handle = self.declare("GetStdHandle", Linkage::Import, &[I32], &[I64])?;
        let write_file = self.declare(
            "WriteFile",
            Linkage::Import,
            &[I64, I64, I32, I64, I64],
            &[I32],
        )?;
        let exit_process = self.declare("ExitProcess", Linkage::Import, &[I32], &[])?;
        let get_process_heap = self.declare("GetProcessHeap", Linkage::Import, &[], &[I64])?;
        let heap_alloc = self.declare("HeapAlloc", Linkage::Import, &[I64, I32, I64], &[I64])?;
        let heap_realloc = self.declare(
            "HeapReAlloc",
            Linkage::Import,
            &[I64, I32, I64, I64],
            &[I64],
        )?;
        let heap_free = self.declare("HeapFree", Linkage::Import, &[I64, I32, I64], &[I32])?;
        let heap_validate =
            self.declare("HeapValidate", Linkage::Import, &[I64, I32, I64], &[I32])?;
        let local = |g: &mut Gen, name: &str, p: &[ir::Type], r: &[ir::Type]| {
            g.declare(name, Linkage::Local, p, r)
        };
        let allocator = |g: &mut Gen, name: &str, p: &[ir::Type], r: &[ir::Type]| {
            let linkage = if platform_enabled {
                Linkage::Export
            } else {
                Linkage::Local
            };
            g.declare(name, linkage, p, r)
        };
        // Text-returning functions take a hidden result pointer first.
        let text3: [ir::Type; 0] = [];
        let rt = Runtime {
            platform: if platform_enabled {
                Some(super::platform::Platform::declare(
                    self,
                    options.trace_alloc,
                )?)
            } else {
                None
            },
            exit_process,
            get_process_heap,
            heap_validate,
            write: local(self, "l_rt_write", &[I32, I64, I64], &[])?,
            write_int: local(self, "l_rt_write_int", &[I32, I64], &[])?,
            alloc: allocator(self, "l_rt_alloc", &[I64], &[I64])?,
            print_int: local(self, "l_rt_print_int", &[I64], &[])?,
            print_bool: local(self, "l_rt_print_bool", &[I8], &[])?,
            print_text: local(self, "l_rt_print_text", &[I64, I64], &[])?,
            print_float: local(self, "l_rt_print_float", &[F64], &[])?,
            print_f32: local(self, "l_rt_print_f32", &[F32], &[])?,
            panic_arith: local(self, "l_rt_panic_arith", &[I64, I64], &[])?,
            push_text: local(
                self,
                "l_rt_text_push",
                &[I64, I64, I64, I64, I64, I64],
                &text3,
            )?,
            push_int: local(
                self,
                "l_rt_text_push_int",
                &[I64, I64, I64, I64, I64],
                &text3,
            )?,
            push_bool: local(
                self,
                "l_rt_text_push_bool",
                &[I64, I64, I64, I64, I8],
                &text3,
            )?,
            push_float: local(
                self,
                "l_rt_text_push_float",
                &[I64, I64, I64, I64, F64],
                &text3,
            )?,
            push_f32: local(
                self,
                "l_rt_text_push_f32",
                &[I64, I64, I64, I64, F32],
                &text3,
            )?,
            text_drop: local(self, "l_rt_text_drop", &[I64, I64, I64], &[])?,
            text_eq: local(self, "l_rt_text_eq", &[I64, I64, I64, I64], &[I8])?,
            region_alloc: local(self, "l_rt_region_alloc", &[I64, I64, I64, I64], &[I64])?,
            region_free: local(self, "l_rt_region_free", &[I64], &[])?,
            panic_at: local(self, "l_rt_panic_at", &[I64, I64, I64, I64], &[])?,
            free: allocator(self, "l_rt_free", &[I64], &[])?,
            zero: local(self, "l_rt_zero", &[I64, I64], &[])?,
            wake: local(self, "l_rt_wake", &[], &[])?,
            timers: if timers_enabled {
                Some(Timers::declare(self)?)
            } else {
                None
            },
            task_spawn: local(self, "l_rt_task_spawn", &[I64, I64], &[I64])?,
            task_ready: local(self, "l_rt_task_ready", &[I64], &[I64])?,
            group_register: local(self, "l_rt_group_register", &[I64, I64], &[I64])?,
            group_pending: local(self, "l_rt_group_pending", &[], &[I64])?,
            task_state: local(self, "l_rt_task_state", &[I64], &[I64])?,
            task_cancel: local(self, "l_rt_task_cancel", &[I64], &[])?,
            run: local(self, "l_rt_run", &[], &[])?,
            poll_dispatch: local(self, "l_task_poll", &[I64, I64], &[I64])?,
            drop_dispatch: local(self, "l_task_drop", &[I64, I64], &[])?,
            list_reserve: local(
                self,
                "l_rt_list_reserve",
                &[I64, I64, I64, I64, I64, I64, I64],
                &[],
            )?,
            stats,
        };
        let ftoa = local(self, "l_rt_ftoa", &[F64, I32, I64], &[I64])?;
        let utoa = local(self, "l_rt_utoa", &[I64, I64], &[I64])?;
        let realloc = allocator(self, "l_rt_realloc", &[I64, I64], &[I64])?;
        let free = rt.free;
        let copy = local(self, "l_rt_copy", &[I64, I64, I64], &[])?;
        let reserve = local(
            self,
            "l_rt_text_reserve",
            &[I64, I64, I64, I64, I64],
            &text3,
        )?;
        let fatal = local(self, "l_rt_fatal", &[I64, I64], &[])?;
        let zero = rt.zero;
        let write = rt.write;

        // l_rt_write(handle_kind, ptr, len): WriteFile until done or error.
        self.define(write, &[I32, I64, I64], &[], |b, h| {
            let params = enter(b);
            let handle = h.call(b, get_std_handle, &[params[0]])[0];
            let written = slot(b, 8);
            let head = b.create_block();
            let p = b.append_block_param(head, I64);
            let l = b.append_block_param(head, I64);
            let body = b.create_block();
            let done = b.create_block();
            jump(b, head, &[params[1], params[2]]);
            b.switch_to_block(head);
            let empty = b.ins().icmp_imm_s(IntCC::SignedLessThanOrEqual, l, 0);
            brif(b, empty, done, body);
            b.switch_to_block(body);
            let big = b.ins().icmp_imm_s(IntCC::UnsignedGreaterThan, l, 1 << 30);
            let cap = b.ins().iconst(I64, 1 << 30);
            let chunk = b.ins().select(big, cap, l);
            let chunk32 = b.ins().ireduce(I32, chunk);
            let addr = b.ins().stack_addr(I64, written, 0);
            let zero32 = b.ins().iconst(I32, 0);
            b.ins().store(flags(), zero32, addr, 0);
            let null = b.ins().iconst(I64, 0);
            let ok = h.call(b, write_file, &[handle, p, chunk32, addr, null])[0];
            let w32 = b.ins().load(I32, flags(), addr, 0);
            let w = b.ins().uextend(I64, w32);
            let failed = b.ins().icmp_imm_s(IntCC::Equal, ok, 0);
            let stuck = b.ins().icmp_imm_s(IntCC::Equal, w, 0);
            let stop = b.ins().bor(failed, stuck);
            let next = b.create_block();
            brif(b, stop, done, next);
            b.switch_to_block(next);
            let p2 = b.ins().iadd(p, w);
            let l2 = b.ins().isub(l, w);
            jump(b, head, &[p2, l2]);
            b.switch_to_block(done);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_utoa(n, end): decimal digits of n just before `end`; returns the
        // number of bytes written (sign included). i64::MIN is handled.
        self.define(utoa, &[I64, I64], &[I64], |b, _| {
            let params = enter(b);
            let (n, end) = (params[0], params[1]);
            let negative = b.ins().icmp_imm_s(IntCC::SignedLessThan, n, 0);
            let negated = b.ins().ineg(n); // i64::MIN stays 2^63 as unsigned.
            let magnitude = b.ins().select(negative, negated, n);
            let digit = b.create_block();
            let p = b.append_block_param(digit, I64);
            let m = b.append_block_param(digit, I64);
            jump(b, digit, &[end, magnitude]);
            b.switch_to_block(digit);
            let q = b.ins().udiv_imm_u(m, 10);
            let r = b.ins().urem_imm_u(m, 10);
            let ch = b.ins().iadd_imm_s(r, 48);
            let p1 = b.ins().iadd_imm_s(p, -1);
            b.ins().istore8(flags(), ch, p1, 0);
            let more = b.ins().icmp_imm_s(IntCC::NotEqual, q, 0);
            let sign = b.create_block();
            let after = b.create_block();
            let fin = b.create_block();
            let start = b.append_block_param(fin, I64);
            let after_p = b.append_block_param(after, I64);
            let sp = b.append_block_param(sign, I64);
            let args = [BlockArg::Value(p1), BlockArg::Value(q)];
            let after_args = [BlockArg::Value(p1)];
            b.ins().brif(more, digit, &args, after, &after_args);
            b.switch_to_block(after);
            let to_sign = [BlockArg::Value(after_p)];
            let to_fin = [BlockArg::Value(after_p)];
            b.ins().brif(negative, sign, &to_sign, fin, &to_fin);
            b.switch_to_block(sign);
            let sp1 = b.ins().iadd_imm_s(sp, -1);
            let minus = b.ins().iconst(I64, 45);
            b.ins().istore8(flags(), minus, sp1, 0);
            jump(b, fin, &[sp1]);
            b.switch_to_block(fin);
            let len = b.ins().isub(end, start);
            b.ins().return_(&[len]);
            Ok(())
        })?;

        // l_rt_write_int(handle_kind, n): digits only.
        self.define(rt.write_int, &[I32, I64], &[], |b, h| {
            let params = enter(b);
            let s = slot(b, 32);
            let base = b.ins().stack_addr(I64, s, 0);
            let end = b.ins().iadd_imm_s(base, 32);
            let len = h.call(b, utoa, &[params[1], end])[0];
            let start = b.ins().isub(end, len);
            h.call(b, write, &[params[0], start, len]);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_fatal(msg_ptr, msg_len): message to stderr, abnormal exit.
        self.define(fatal, &[I64, I64], &[], |b, h| {
            let params = enter(b);
            let err = b.ins().iconst(I32, STDERR);
            h.call(b, write, &[err, params[0], params[1]]);
            let code = b.ins().iconst(I32, i64::from(PANIC_EXIT_CODE as i32));
            h.call(b, exit_process, &[code]);
            never(b);
            Ok(())
        })?;

        // Heap. Allocation failure is a panic (spec: unrecoverable), never a
        // null pointer handed to the program.
        let counted = |b: &mut FunctionBuilder, h: &mut Helpers, offset: i32| {
            stats.map(|s| bump(b, h, s, offset))
        };
        let oom = |b: &mut FunctionBuilder, h: &mut Helpers| -> Result<(), Diagnostic> {
            let (p, l) = h.text(b, OOM_MESSAGE)?;
            h.call(b, fatal, &[p, l]);
            never(b);
            Ok(())
        };
        // Allocation attempt counter for fault injection: true when this
        // attempt must fail.
        let injected = |b: &mut FunctionBuilder, h: &mut Helpers| -> Option<ir::Value> {
            let attempt = counted(b, h, ATTEMPTS)?;
            let limit = options.fail_alloc_after? as i64;
            Some(b.ins().icmp_imm_s(IntCC::SignedGreaterThan, attempt, limit))
        };
        self.define(rt.alloc, &[I64], &[I64], |b, h| {
            let params = enter(b);
            let fail = b.create_block();
            if let Some(forced) = injected(b, h) {
                let go = b.create_block();
                brif(b, forced, fail, go);
                b.switch_to_block(go);
            }
            let heap = h.call(b, get_process_heap, &[])[0];
            let zero = b.ins().iconst(I32, 0);
            let p = h.call(b, heap_alloc, &[heap, zero, params[0]])[0];
            let null = b.ins().icmp_imm_s(IntCC::Equal, p, 0);
            let ok = b.create_block();
            brif(b, null, fail, ok);
            b.switch_to_block(ok);
            counted(b, h, ALLOCS);
            b.ins().return_(&[p]);
            b.switch_to_block(fail);
            oom(b, h)
        })?;
        self.define(realloc, &[I64, I64], &[I64], |b, h| {
            let params = enter(b);
            let fail = b.create_block();
            if let Some(forced) = injected(b, h) {
                let go = b.create_block();
                brif(b, forced, fail, go);
                b.switch_to_block(go);
            }
            let heap = h.call(b, get_process_heap, &[])[0];
            let zero = b.ins().iconst(I32, 0);
            let p = h.call(b, heap_realloc, &[heap, zero, params[0], params[1]])[0];
            let null = b.ins().icmp_imm_s(IntCC::Equal, p, 0);
            let ok = b.create_block();
            brif(b, null, fail, ok);
            b.switch_to_block(ok);
            counted(b, h, REALLOCS);
            b.ins().return_(&[p]);
            b.switch_to_block(fail);
            oom(b, h)
        })?;
        self.define(free, &[I64], &[], |b, h| {
            let params = enter(b);
            let heap = h.call(b, get_process_heap, &[])[0];
            let zero = b.ins().iconst(I32, 0);
            if options.trace_alloc {
                // Instrumented build: a pointer that is not a live block of the
                // process heap (double free, foreign pointer) aborts loudly.
                let valid = h.call(b, heap_validate, &[heap, zero, params[0]])[0];
                let bad = b.ins().icmp_imm_s(IntCC::Equal, valid, 0);
                let (fail, ok) = (b.create_block(), b.create_block());
                brif(b, bad, fail, ok);
                b.switch_to_block(fail);
                let (p, l) = h.text(b, BAD_FREE_MESSAGE)?;
                h.call(b, fatal, &[p, l]);
                never(b);
                b.switch_to_block(ok);
            }
            h.call(b, heap_free, &[heap, zero, params[0]]);
            counted(b, h, FREES);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_copy(dst, src, n): byte copy, non-overlapping.
        self.define(copy, &[I64, I64, I64], &[], |b, _| {
            let params = enter(b);
            let (dst, src, n) = (params[0], params[1], params[2]);
            let head = b.create_block();
            let i = b.append_block_param(head, I64);
            let (body, done) = (b.create_block(), b.create_block());
            let zero = b.ins().iconst(I64, 0);
            jump(b, head, &[zero]);
            b.switch_to_block(head);
            let more = b.ins().icmp(IntCC::UnsignedLessThan, i, n);
            brif(b, more, body, done);
            b.switch_to_block(body);
            let s = b.ins().iadd(src, i);
            let d = b.ins().iadd(dst, i);
            let byte = b.ins().load(I8, flags(), s, 0);
            b.ins().store(flags(), byte, d, 0);
            let next = b.ins().iadd_imm_s(i, 1);
            jump(b, head, &[next]);
            b.switch_to_block(done);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_ftoa(val: F64, is_f32: I32, buf: I64) -> len: I64
        self.define(ftoa, &[F64, I32, I64], &[I64], |b, h| {
            let params = enter(b);
            let (val, is_f32, buf) = (params[0], params[1], params[2]);

            let s_int = slot(b, 32);
            let s_frac = slot(b, 32);
            let int_buf_base = b.ins().stack_addr(I64, s_int, 0);
            let int_buf_end = b.ins().iadd_imm_s(int_buf_base, 32);
            let frac_buf = b.ins().stack_addr(I64, s_frac, 0);

            let mut bf = ir::MemFlagsData::new();
            bf.set_endianness(ir::Endianness::Little);
            let bits = b.ins().bitcast(I64, bf, val);
            let is_neg = b.ins().icmp_imm_s(IntCC::SignedLessThan, bits, 0);
            let mask_abs = b.ins().iconst(I64, 0x7FFF_FFFF_FFFF_FFFF);
            let abs_bits = b.ins().band(bits, mask_abs);
            let shift_52 = b.ins().iconst(I64, 52);
            let exp = b.ins().ushr(abs_bits, shift_52);
            let mask_mant = b.ins().iconst(I64, 0x000F_FFFF_FFFF_FFFF);
            let mant = b.ins().band(abs_bits, mask_mant);

            let blk_special = b.create_block();
            let blk_finite = b.create_block();

            let exp_7ff = b.ins().iconst(I64, 0x7FF);
            let is_special_exp = b.ins().icmp(IntCC::Equal, exp, exp_7ff);
            let zero_i64 = b.ins().iconst(I64, 0);
            let is_zero = b.ins().icmp(IntCC::Equal, abs_bits, zero_i64);
            let is_special = b.ins().bor(is_special_exp, is_zero);
            brif(b, is_special, blk_special, blk_finite);

            // --- blk_special ---
            b.switch_to_block(blk_special);
            let blk_nan_or_inf = b.create_block();
            let blk_zero = b.create_block();
            brif(b, is_zero, blk_zero, blk_nan_or_inf);

            // blk_zero
            b.switch_to_block(blk_zero);
            let blk_neg_zero = b.create_block();
            let blk_pos_zero = b.create_block();
            brif(b, is_neg, blk_neg_zero, blk_pos_zero);

            b.switch_to_block(blk_neg_zero);
            let m = b.ins().iconst(I64, 45); // '-'
            let z = b.ins().iconst(I64, 48); // '0'
            b.ins().istore8(flags(), m, buf, 0);
            b.ins().istore8(flags(), z, buf, 1);
            let len2 = b.ins().iconst(I64, 2);
            b.ins().return_(&[len2]);

            b.switch_to_block(blk_pos_zero);
            let z = b.ins().iconst(I64, 48); // '0'
            b.ins().istore8(flags(), z, buf, 0);
            let len1 = b.ins().iconst(I64, 1);
            b.ins().return_(&[len1]);

            // blk_nan_or_inf
            b.switch_to_block(blk_nan_or_inf);
            let is_nan = b.ins().icmp(IntCC::NotEqual, mant, zero_i64);
            let blk_nan = b.create_block();
            let blk_inf = b.create_block();
            brif(b, is_nan, blk_nan, blk_inf);

            b.switch_to_block(blk_nan);
            let ch_n = b.ins().iconst(I64, 78); // 'N'
            let ch_a = b.ins().iconst(I64, 97); // 'a'
            b.ins().istore8(flags(), ch_n, buf, 0);
            b.ins().istore8(flags(), ch_a, buf, 1);
            b.ins().istore8(flags(), ch_n, buf, 2);
            let len3 = b.ins().iconst(I64, 3);
            b.ins().return_(&[len3]);

            b.switch_to_block(blk_inf);
            let blk_neg_inf = b.create_block();
            let blk_pos_inf = b.create_block();
            brif(b, is_neg, blk_neg_inf, blk_pos_inf);

            b.switch_to_block(blk_neg_inf);
            let m = b.ins().iconst(I64, 45); // '-'
            let ch_i = b.ins().iconst(I64, 105); // 'i'
            let ch_n = b.ins().iconst(I64, 110); // 'n'
            let ch_f = b.ins().iconst(I64, 102); // 'f'
            b.ins().istore8(flags(), m, buf, 0);
            b.ins().istore8(flags(), ch_i, buf, 1);
            b.ins().istore8(flags(), ch_n, buf, 2);
            b.ins().istore8(flags(), ch_f, buf, 3);
            let len4 = b.ins().iconst(I64, 4);
            b.ins().return_(&[len4]);

            b.switch_to_block(blk_pos_inf);
            let ch_i = b.ins().iconst(I64, 105); // 'i'
            let ch_n = b.ins().iconst(I64, 110); // 'n'
            let ch_f = b.ins().iconst(I64, 102); // 'f'
            b.ins().istore8(flags(), ch_i, buf, 0);
            b.ins().istore8(flags(), ch_n, buf, 1);
            b.ins().istore8(flags(), ch_f, buf, 2);
            let len3 = b.ins().iconst(I64, 3);
            b.ins().return_(&[len3]);

            // --- blk_finite ---
            b.switch_to_block(blk_finite);
            let abs_val = b.ins().fabs(val);
            let int_part = b.ins().fcvt_to_sint_sat(I64, abs_val);
            let float_int = b.ins().fcvt_from_sint(F64, int_part);
            let frac = b.ins().fsub(abs_val, float_int);

            let int_len = h.call(b, utoa, &[int_part, int_buf_end])[0];
            let int_start = b.ins().isub(int_buf_end, int_len);

            let blk_sign = b.create_block();
            let blk_no_sign = b.create_block();
            let blk_after_sign = b.create_block();
            let sign_offset = b.append_block_param(blk_after_sign, I64);
            brif(b, is_neg, blk_sign, blk_no_sign);

            b.switch_to_block(blk_sign);
            let minus_char = b.ins().iconst(I64, 45); // '-'
            b.ins().istore8(flags(), minus_char, buf, 0);
            let one_i64 = b.ins().iconst(I64, 1);
            jump(b, blk_after_sign, &[one_i64]);

            b.switch_to_block(blk_no_sign);
            jump(b, blk_after_sign, &[zero_i64]);

            b.switch_to_block(blk_after_sign);
            let int_dst = b.ins().iadd(buf, sign_offset);
            h.call(b, copy, &[int_dst, int_start, int_len]);

            let is_f32_bool = b.ins().icmp_imm_s(IntCC::NotEqual, is_f32, 0);
            let prec_f32 = b.ins().iconst(I64, 7);
            let prec_f64 = b.ins().iconst(I64, 16);
            let prec = b.ins().select(is_f32_bool, prec_f32, prec_f64);
            let max_dec_raw = b.ins().isub(prec, int_len);
            let max_dec_zero = b
                .ins()
                .icmp_imm_s(IntCC::SignedLessThanOrEqual, max_dec_raw, 0);
            let max_dec = b.ins().select(max_dec_zero, zero_i64, max_dec_raw);

            let frac_head = b.create_block();
            let k = b.append_block_param(frac_head, I64);
            let cur_frac = b.append_block_param(frac_head, F64);
            let frac_body = b.create_block();
            let frac_done = b.create_block();
            let frac_final = b.append_block_param(frac_done, F64);

            jump(b, frac_head, &[zero_i64, frac]);

            b.switch_to_block(frac_head);
            let frac_more = b.ins().icmp(IntCC::SignedLessThan, k, max_dec);
            let blk_to_done = b.create_block();
            brif(b, frac_more, frac_body, blk_to_done);

            b.switch_to_block(blk_to_done);
            jump(b, frac_done, &[cur_frac]);

            b.switch_to_block(frac_body);
            let ten = b.ins().f64const(10.0);
            let f10 = b.ins().fmul(cur_frac, ten);
            let digit = b.ins().fcvt_to_sint_sat(I64, f10);
            let digit_f = b.ins().fcvt_from_sint(F64, digit);
            let next_frac = b.ins().fsub(f10, digit_f);
            let digit_char = b.ins().iadd_imm_s(digit, 48);
            let dst_digit = b.ins().iadd(frac_buf, k);
            b.ins().istore8(flags(), digit_char, dst_digit, 0);
            let next_k = b.ins().iadd_imm_s(k, 1);
            jump(b, frac_head, &[next_k, next_frac]);

            b.switch_to_block(frac_done);
            let has_dec = b.ins().icmp(IntCC::SignedGreaterThan, max_dec, zero_i64);
            let half = b.ins().f64const(0.5);
            let need_round = b.ins().fcmp(FloatCC::GreaterThanOrEqual, frac_final, half);
            let should_round = b.ins().band(has_dec, need_round);

            let blk_round = b.create_block();
            let blk_after_round = b.create_block();
            brif(b, should_round, blk_round, blk_after_round);

            b.switch_to_block(blk_round);
            let round_loop = b.create_block();
            let r_idx = b.append_block_param(round_loop, I64);
            let start_r_idx = b.ins().iadd_imm_s(max_dec, -1);
            jump(b, round_loop, &[start_r_idx]);

            b.switch_to_block(round_loop);
            let r_idx_neg = b.ins().icmp_imm_s(IntCC::SignedLessThan, r_idx, 0);
            let blk_carry_out = b.create_block();
            let blk_round_digit = b.create_block();
            brif(b, r_idx_neg, blk_carry_out, blk_round_digit);

            b.switch_to_block(blk_round_digit);
            let p_ch = b.ins().iadd(frac_buf, r_idx);
            let ch_val = b.ins().load(I8, flags(), p_ch, 0);
            let ch_val64 = b.ins().uextend(I64, ch_val);
            let ch_inc = b.ins().iadd_imm_s(ch_val64, 1);
            let is_ten = b.ins().icmp_imm_s(IntCC::Equal, ch_inc, 58); // ':'
            let blk_overflow_digit = b.create_block();
            let blk_normal_digit = b.create_block();
            brif(b, is_ten, blk_overflow_digit, blk_normal_digit);

            b.switch_to_block(blk_overflow_digit);
            let zero_char = b.ins().iconst(I64, 48);
            b.ins().istore8(flags(), zero_char, p_ch, 0);
            let prev_r = b.ins().iadd_imm_s(r_idx, -1);
            jump(b, round_loop, &[prev_r]);

            b.switch_to_block(blk_normal_digit);
            b.ins().istore8(flags(), ch_inc, p_ch, 0);
            jump(b, blk_after_round, &[]);

            b.switch_to_block(blk_carry_out);
            let int_len_m1 = b.ins().iadd_imm_s(int_len, -1);
            let last_int_p = b.ins().iadd(int_dst, int_len_m1);
            let old_ch = b.ins().load(I8, flags(), last_int_p, 0);
            let old_ch64 = b.ins().uextend(I64, old_ch);
            let inc_old = b.ins().iadd_imm_s(old_ch64, 1);
            b.ins().istore8(flags(), inc_old, last_int_p, 0);
            jump(b, blk_after_round, &[]);

            b.switch_to_block(blk_after_round);
            let trim_loop = b.create_block();
            let t_idx = b.append_block_param(trim_loop, I64);
            let start_t = b.ins().iadd_imm_s(max_dec, -1);
            jump(b, trim_loop, &[start_t]);

            b.switch_to_block(trim_loop);
            let t_neg = b.ins().icmp_imm_s(IntCC::SignedLessThan, t_idx, 0);
            let blk_trim_neg = b.create_block();
            let blk_trim_check = b.create_block();
            let blk_assemble = b.create_block();
            let valid_frac_len = b.append_block_param(blk_assemble, I64);
            brif(b, t_neg, blk_trim_neg, blk_trim_check);

            b.switch_to_block(blk_trim_neg);
            jump(b, blk_assemble, &[zero_i64]);

            b.switch_to_block(blk_trim_check);
            let p_t = b.ins().iadd(frac_buf, t_idx);
            let t_ch = b.ins().load(I8, flags(), p_t, 0);
            let is_zero_ch = b.ins().icmp_imm_s(IntCC::Equal, t_ch, 48); // '0'
            let blk_trim_next = b.create_block();
            let blk_trim_stop = b.create_block();
            brif(b, is_zero_ch, blk_trim_next, blk_trim_stop);

            b.switch_to_block(blk_trim_next);
            let prev_t = b.ins().iadd_imm_s(t_idx, -1);
            jump(b, trim_loop, &[prev_t]);

            b.switch_to_block(blk_trim_stop);
            let valid_len = b.ins().iadd_imm_s(t_idx, 1);
            jump(b, blk_assemble, &[valid_len]);

            b.switch_to_block(blk_assemble);
            let has_frac_digits = b
                .ins()
                .icmp(IntCC::SignedGreaterThan, valid_frac_len, zero_i64);
            let blk_append_frac = b.create_block();
            let blk_no_frac = b.create_block();
            let blk_done_all = b.create_block();
            let final_len = b.append_block_param(blk_done_all, I64);

            let base_len = b.ins().iadd(sign_offset, int_len);
            brif(b, has_frac_digits, blk_append_frac, blk_no_frac);

            b.switch_to_block(blk_no_frac);
            jump(b, blk_done_all, &[base_len]);

            b.switch_to_block(blk_append_frac);
            let dot_p = b.ins().iadd(buf, base_len);
            let dot = b.ins().iconst(I64, 46); // '.'
            b.ins().istore8(flags(), dot, dot_p, 0);
            let frac_dst = b.ins().iadd_imm_s(dot_p, 1);
            h.call(b, copy, &[frac_dst, frac_buf, valid_frac_len]);
            let base_p1 = b.ins().iadd_imm_s(base_len, 1);
            let total_len = b.ins().iadd(base_p1, valid_frac_len);
            jump(b, blk_done_all, &[total_len]);

            b.switch_to_block(blk_done_all);
            b.ins().return_(&[final_len]);
            Ok(())
        })?;

        // l_rt_text_reserve(p, l, c, extra): ensures an owned buffer with room
        // for `extra` more bytes. A static Text (c == 0) is copied into a new
        // heap buffer; growth is geometric (max(need, 2c, 16)).
        self.define(reserve, &[I64, I64, I64, I64, I64], &text3, |b, h| {
            let params = enter(b);
            let out = params[0];
            let (p, l, c, extra) = (params[1], params[2], params[3], params[4]);
            let need = b.ins().iadd(l, extra);
            let wrapped = b.ins().icmp(IntCC::UnsignedLessThan, need, l);
            let (fail, check) = (b.create_block(), b.create_block());
            brif(b, wrapped, fail, check);
            b.switch_to_block(check);
            let owned = b.ins().icmp_imm_s(IntCC::NotEqual, c, 0);
            let fits = b.ins().icmp(IntCC::UnsignedGreaterThanOrEqual, c, need);
            let enough = b.ins().band(owned, fits);
            let (keep, grow) = (b.create_block(), b.create_block());
            brif(b, enough, keep, grow);
            b.switch_to_block(keep);
            return_text(b, out, &[p, l, c]);
            b.switch_to_block(grow);
            let doubled = b.ins().iadd(c, c);
            let bigger = b.ins().icmp(IntCC::UnsignedGreaterThan, doubled, need);
            let m = b.ins().select(bigger, doubled, need);
            let small = b.ins().icmp_imm_u(IntCC::UnsignedLessThan, m, MIN_CAPACITY);
            let min = b.ins().iconst(I64, MIN_CAPACITY);
            let newcap = b.ins().select(small, min, m);
            let (from_static, from_heap) = (b.create_block(), b.create_block());
            brif(b, owned, from_heap, from_static);
            b.switch_to_block(from_static);
            let np = h.call(b, rt.alloc, &[newcap])[0];
            h.call(b, copy, &[np, p, l]);
            return_text(b, out, &[np, l, newcap]);
            b.switch_to_block(from_heap);
            let np = h.call(b, realloc, &[p, newcap])[0];
            return_text(b, out, &[np, l, newcap]);
            b.switch_to_block(fail);
            oom(b, h)
        })?;

        // l_rt_text_push(p, l, c, src, n).
        self.define(
            rt.push_text,
            &[I64, I64, I64, I64, I64, I64],
            &text3,
            |b, h| {
                let params = enter(b);
                let out = params[0];
                let (src, n) = (params[4], params[5]);
                let r = h.call_text(b, reserve, &[params[1], params[2], params[3], n]);
                let at = b.ins().iadd(r[0], r[1]);
                h.call(b, copy, &[at, src, n]);
                let len = b.ins().iadd(r[1], n);
                return_text(b, out, &[r[0], len, r[2]]);
                Ok(())
            },
        )?;
        // l_rt_text_push_int(p, l, c, n).
        self.define(rt.push_int, &[I64, I64, I64, I64, I64], &text3, |b, h| {
            let params = enter(b);
            let s = slot(b, 32);
            let base = b.ins().stack_addr(I64, s, 0);
            let end = b.ins().iadd_imm_s(base, 32);
            let len = h.call(b, utoa, &[params[4], end])[0];
            let start = b.ins().isub(end, len);
            let r = h.call_text(
                b,
                rt.push_text,
                &[params[1], params[2], params[3], start, len],
            );
            return_text(b, params[0], &r);
            Ok(())
        })?;
        // l_rt_text_push_bool(p, l, c, v).
        self.define(rt.push_bool, &[I64, I64, I64, I64, I8], &text3, |b, h| {
            let params = enter(b);
            let (t, tl) = h.text(b, "true")?;
            let (f, fl) = h.text(b, "false")?;
            let ptr = b.ins().select(params[4], t, f);
            let len = b.ins().select(params[4], tl, fl);
            let r = h.call_text(
                b,
                rt.push_text,
                &[params[1], params[2], params[3], ptr, len],
            );
            return_text(b, params[0], &r);
            Ok(())
        })?;
        // l_rt_text_push_float(p, l, c, v).
        self.define(rt.push_float, &[I64, I64, I64, I64, F64], &text3, |b, h| {
            let params = enter(b);
            let s = slot(b, 64);
            let base = b.ins().stack_addr(I64, s, 0);
            let zero = b.ins().iconst(I32, 0);
            let len = h.call(b, ftoa, &[params[4], zero, base])[0];
            let r = h.call_text(
                b,
                rt.push_text,
                &[params[1], params[2], params[3], base, len],
            );
            return_text(b, params[0], &r);
            Ok(())
        })?;
        // l_rt_text_push_f32(p, l, c, v).
        self.define(rt.push_f32, &[I64, I64, I64, I64, F32], &text3, |b, h| {
            let params = enter(b);
            let f64_val = b.ins().fpromote(F64, params[4]);
            let s = slot(b, 64);
            let base = b.ins().stack_addr(I64, s, 0);
            let one = b.ins().iconst(I32, 1);
            let len = h.call(b, ftoa, &[f64_val, one, base])[0];
            let r = h.call_text(
                b,
                rt.push_text,
                &[params[1], params[2], params[3], base, len],
            );
            return_text(b, params[0], &r);
            Ok(())
        })?;
        // l_rt_text_drop(p, l, c): static Text (c == 0) is never freed.
        self.define(rt.text_drop, &[I64, I64, I64], &[], |b, h| {
            let params = enter(b);
            let owned = b.ins().icmp_imm_s(IntCC::NotEqual, params[2], 0);
            let (release, done) = (b.create_block(), b.create_block());
            brif(b, owned, release, done);
            b.switch_to_block(release);
            h.call(b, free, &[params[0]]);
            jump(b, done, &[]);
            b.switch_to_block(done);
            b.ins().return_(&[]);
            Ok(())
        })?;
        // l_rt_text_eq(p1, l1, p2, l2) -> i8.
        self.define(rt.text_eq, &[I64, I64, I64, I64], &[I8], |b, _| {
            let params = enter(b);
            let (p1, l1, p2, l2) = (params[0], params[1], params[2], params[3]);
            let (head, body, yes, no) = (
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
            );
            let i = b.append_block_param(head, I64);
            let same_len = b.ins().icmp(IntCC::Equal, l1, l2);
            let start = b.create_block();
            brif(b, same_len, start, no);
            b.switch_to_block(start);
            let zero = b.ins().iconst(I64, 0);
            jump(b, head, &[zero]);
            b.switch_to_block(head);
            let more = b.ins().icmp(IntCC::UnsignedLessThan, i, l1);
            brif(b, more, body, yes);
            b.switch_to_block(body);
            let a = b.ins().iadd(p1, i);
            let c = b.ins().iadd(p2, i);
            let x = b.ins().load(I8, flags(), a, 0);
            let y = b.ins().load(I8, flags(), c, 0);
            let differ = b.ins().icmp(IntCC::NotEqual, x, y);
            let next = b.ins().iadd_imm_s(i, 1);
            let cont = b.create_block();
            brif(b, differ, no, cont);
            b.switch_to_block(cont);
            jump(b, head, &[next]);
            b.switch_to_block(yes);
            let one = b.ins().iconst(I8, 1);
            b.ins().return_(&[one]);
            b.switch_to_block(no);
            let zero8 = b.ins().iconst(I8, 0);
            b.ins().return_(&[zero8]);
            Ok(())
        })?;

        // print_*: value followed by "\n".
        self.define(rt.print_int, &[I64], &[], |b, h| {
            let n = enter(b)[0];
            let s = slot(b, 32);
            let base = b.ins().stack_addr(I64, s, 0);
            let end = b.ins().iadd_imm_s(base, 31);
            let newline = b.ins().iconst(I64, 10);
            b.ins().istore8(flags(), newline, end, 0);
            let len = h.call(b, utoa, &[n, end])[0];
            let start = b.ins().isub(end, len);
            let total = b.ins().iadd_imm_s(len, 1);
            let out = b.ins().iconst(I32, STDOUT);
            h.call(b, write, &[out, start, total]);
            b.ins().return_(&[]);
            Ok(())
        })?;
        self.define(rt.print_bool, &[I8], &[], |b, h| {
            let v = enter(b)[0];
            let (t, tl) = h.text(b, "true\n")?;
            let (f, fl) = h.text(b, "false\n")?;
            let ptr = b.ins().select(v, t, f);
            let len = b.ins().select(v, tl, fl);
            let out = b.ins().iconst(I32, STDOUT);
            h.call(b, write, &[out, ptr, len]);
            b.ins().return_(&[]);
            Ok(())
        })?;
        self.define(rt.print_text, &[I64, I64], &[], |b, h| {
            let params = enter(b);
            let out = b.ins().iconst(I32, STDOUT);
            h.call(b, write, &[out, params[0], params[1]]);
            let (nl, nll) = h.text(b, "\n")?;
            h.call(b, write, &[out, nl, nll]);
            b.ins().return_(&[]);
            Ok(())
        })?;
        self.define(rt.print_float, &[F64], &[], |b, h| {
            let val = enter(b)[0];
            let s = slot(b, 64);
            let base = b.ins().stack_addr(I64, s, 0);
            let zero = b.ins().iconst(I32, 0);
            let len = h.call(b, ftoa, &[val, zero, base])[0];
            let nl_ptr = b.ins().iadd(base, len);
            let newline = b.ins().iconst(I64, 10);
            b.ins().istore8(flags(), newline, nl_ptr, 0);
            let total = b.ins().iadd_imm_s(len, 1);
            let out = b.ins().iconst(I32, STDOUT);
            h.call(b, write, &[out, base, total]);
            b.ins().return_(&[]);
            Ok(())
        })?;
        self.define(rt.print_f32, &[F32], &[], |b, h| {
            let val = enter(b)[0];
            let f64_val = b.ins().fpromote(F64, val);
            let s = slot(b, 64);
            let base = b.ins().stack_addr(I64, s, 0);
            let one = b.ins().iconst(I32, 1);
            let len = h.call(b, ftoa, &[f64_val, one, base])[0];
            let nl_ptr = b.ins().iadd(base, len);
            let newline = b.ins().iconst(I64, 10);
            b.ins().istore8(flags(), newline, nl_ptr, 0);
            let total = b.ins().iadd_imm_s(len, 1);
            let out = b.ins().iconst(I32, STDOUT);
            h.call(b, write, &[out, base, total]);
            b.ins().return_(&[]);
            Ok(())
        })?;
        // l_rt_panic_at(line, column, msg, len): "ELE l:c" + msg.
        self.define(rt.panic_at, &[I64, I64, I64, I64], &[], |b, h| {
            let params = enter(b);
            let err = b.ins().iconst(I32, STDERR);
            let (p, l) = h.text(b, "ELE ")?;
            h.call(b, write, &[err, p, l]);
            h.call(b, rt.write_int, &[err, params[0]]);
            let (p, l) = h.text(b, ":")?;
            h.call(b, write, &[err, p, l]);
            h.call(b, rt.write_int, &[err, params[1]]);
            h.call(b, fatal, &[params[2], params[3]]);
            never(b);
            Ok(())
        })?;

        // l_rt_list_reserve(hdr, n, stride, min, line, col, region): capacity policy
        // shared with the rustc backend. When `cap - len < n` the new capacity
        // is max(len + n, 2 * cap, min) (push passes n = 1, min = 4; reserve
        // passes min = 0). Every size computation is checked: overflow of the
        // element count or of the byte size (above i64::MAX) is a located
        // panic; heap exhaustion is the usual out-of-memory panic. The header
        // is only updated after a successful (re)allocation.
        self.define(
            rt.list_reserve,
            &[I64, I64, I64, I64, I64, I64, I64],
            &[],
            |b, h| {
                let params = enter(b);
                let (hdr, n, stride, min, line, col, region) = (
                    params[0], params[1], params[2], params[3], params[4], params[5], params[6],
                );
                let located = |b: &mut FunctionBuilder,
                               h: &mut Helpers,
                               msg: &str|
                 -> Result<(), Diagnostic> {
                    let (p, l) = h.text(b, msg)?;
                    h.call(b, rt.panic_at, &[line, col, p, l]);
                    never(b);
                    Ok(())
                };
                let (negative, sized) = (b.create_block(), b.create_block());
                let is_negative = b.ins().icmp_imm_s(IntCC::SignedLessThan, n, 0);
                brif(b, is_negative, negative, sized);
                b.switch_to_block(negative);
                located(b, h, NEGATIVE_RESERVE)?;

                b.switch_to_block(sized);
                let ptr = b.ins().load(I64, flags(), hdr, LIST_PTR);
                let len = b.ins().load(I64, flags(), hdr, LIST_LEN);
                let cap = b.ins().load(I64, flags(), hdr, LIST_CAP);
                let free_slots = b.ins().isub(cap, len);
                let enough = b.ins().icmp(IntCC::SignedGreaterThanOrEqual, free_slots, n);
                let (done, grow) = (b.create_block(), b.create_block());
                brif(b, enough, done, grow);

                b.switch_to_block(grow);
                let overflow = b.create_block();
                let (need, of1) = b.ins().sadd_overflow(len, n);
                let two = b.ins().iconst(I64, 2);
                let (double, of2) = b.ins().smul_overflow(cap, two);
                // A doubled capacity that overflows is never needed: fall back
                // to the exact need (which is then checked below).
                let double = b.ins().select(of2, need, double);
                let bigger = b.ins().icmp(IntCC::SignedGreaterThan, double, need);
                let new_cap = b.ins().select(bigger, double, need);
                let below_min = b.ins().icmp(IntCC::SignedLessThan, new_cap, min);
                let new_cap = b.ins().select(below_min, min, new_cap);
                let (bytes, of3) = b.ins().smul_overflow(new_cap, stride);
                let bad = b.ins().bor(of1, of3);
                let sized_ok = b.create_block();
                brif(b, bad, overflow, sized_ok);
                b.switch_to_block(overflow);
                located(b, h, CAPACITY_OVERFLOW)?;

                b.switch_to_block(sized_ok);
                // Zero-sized elements still get a real (1-byte) block.
                let one = b.ins().iconst(I64, 1);
                let empty = b.ins().icmp_imm_s(IntCC::Equal, bytes, 0);
                let bytes = b.ins().select(empty, one, bytes);
                let (fresh, moved, store) = (b.create_block(), b.create_block(), b.create_block());
                let new_ptr = b.append_block_param(store, I64);
                let (arena, heap) = (b.create_block(), b.create_block());
                let regional = b.ins().icmp_imm_s(IntCC::NotEqual, region, 0);
                brif(b, regional, arena, heap);
                b.switch_to_block(arena);
                let p = h.call(b, rt.region_alloc, &[region, bytes, line, col])[0];
                let live = b.ins().imul(len, stride);
                h.call(b, copy, &[p, ptr, live]);
                if let Some(stats) = rt.stats {
                    let base = h.data_addr(b, stats);
                    let retired = b.ins().imul(cap, stride);
                    let total = b.ins().load(I64, flags(), base, REGION_RETIRED);
                    let total = b.ins().iadd(total, retired);
                    b.ins().store(flags(), total, base, REGION_RETIRED);
                }
                jump(b, store, &[p]);
                b.switch_to_block(heap);
                let unallocated = b.ins().icmp_imm_s(IntCC::Equal, cap, 0);
                brif(b, unallocated, fresh, moved);
                b.switch_to_block(fresh);
                let p = h.call(b, rt.alloc, &[bytes])[0];
                jump(b, store, &[p]);
                b.switch_to_block(moved);
                let p = h.call(b, realloc, &[ptr, bytes])[0];
                jump(b, store, &[p]);
                b.switch_to_block(store);
                b.ins().store(flags(), new_ptr, hdr, LIST_PTR);
                b.ins().store(flags(), new_cap, hdr, LIST_CAP);
                jump(b, done, &[]);

                b.switch_to_block(done);
                b.ins().return_(&[]);
                Ok(())
            },
        )?;

        // Cooperative scheduler. One thread, a FIFO queue of ready tasks and
        // a count of the suspended ones. A pending task is only polled again
        // after a notification: nothing spins and no thread is ever blocked.
        // When no task is ready and some task is still suspended, no
        // notification can ever arrive: that is a deadlock and is reported.
        let ready_head = self.zeroed("l_rt_ready_head", 8)?;
        let ready_tail = self.zeroed("l_rt_ready_tail", 8)?;
        let current = self.zeroed("l_rt_current", 8)?;
        let suspended = self.zeroed("l_rt_suspended", 8)?;
        let cancelling = self.zeroed("l_rt_cancelling", 8)?;
        let purge_head = self.zeroed("l_rt_purge", 8)?;
        let push_ready = local(self, "l_rt_push_ready", &[I64], &[])?;
        let leave_ready = local(self, "l_rt_leave_ready", &[I64], &[])?;
        let wake_task = local(self, "l_rt_wake_task", &[I64], &[])?;
        let purge_task = local(self, "l_rt_purge_task", &[I64], &[])?;

        // l_rt_push_ready(task): append to the tail of the ready queue.
        self.define(push_ready, &[I64], &[], |b, h| {
            let task = enter(b)[0];
            let zero = b.ins().iconst(I64, 0);
            b.ins().store(flags(), zero, task, TASK_NEXT);
            let one = b.ins().iconst(I64, 1);
            b.ins().store(flags(), one, task, TASK_QUEUED);
            let head_addr = h.data_addr(b, ready_head);
            let tail_addr = h.data_addr(b, ready_tail);
            let tail = b.ins().load(I64, flags(), tail_addr, 0);
            b.ins().store(flags(), tail, task, TASK_PREV);
            let (first, after) = (b.create_block(), b.create_block());
            let empty = b.ins().icmp_imm_s(IntCC::Equal, tail, 0);
            brif(b, empty, first, after);
            b.switch_to_block(first);
            b.ins().store(flags(), task, head_addr, 0);
            b.ins().store(flags(), task, tail_addr, 0);
            b.ins().return_(&[]);
            b.switch_to_block(after);
            b.ins().store(flags(), task, tail, TASK_NEXT);
            b.ins().store(flags(), task, tail_addr, 0);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_leave_ready(task): unlink a queued record from the ready queue.
        self.define(leave_ready, &[I64], &[], |b, h| {
            let task = enter(b)[0];
            let head_addr = h.data_addr(b, ready_head);
            let tail_addr = h.data_addr(b, ready_tail);
            let prev = b.ins().load(I64, flags(), task, TASK_PREV);
            let next = b.ins().load(I64, flags(), task, TASK_NEXT);
            let (first, linked) = (b.create_block(), b.create_block());
            let after_prev = b.create_block();
            let no_prev = b.ins().icmp_imm_s(IntCC::Equal, prev, 0);
            brif(b, no_prev, first, linked);
            b.switch_to_block(first);
            b.ins().store(flags(), next, head_addr, 0);
            jump(b, after_prev, &[]);
            b.switch_to_block(linked);
            b.ins().store(flags(), next, prev, TASK_NEXT);
            jump(b, after_prev, &[]);
            b.switch_to_block(after_prev);
            let (last, more) = (b.create_block(), b.create_block());
            let done = b.create_block();
            let no_next = b.ins().icmp_imm_s(IntCC::Equal, next, 0);
            brif(b, no_next, last, more);
            b.switch_to_block(last);
            b.ins().store(flags(), prev, tail_addr, 0);
            jump(b, done, &[]);
            b.switch_to_block(more);
            b.ins().store(flags(), prev, next, TASK_PREV);
            jump(b, done, &[]);
            b.switch_to_block(done);
            let zero = b.ins().iconst(I64, 0);
            b.ins().store(flags(), zero, task, TASK_QUEUED);
            b.ins().store(flags(), zero, task, TASK_NEXT);
            b.ins().store(flags(), zero, task, TASK_PREV);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_wake_task(task): make it ready again. A duplicate notification
        // (already queued) and a notification to a finished or cancelled task
        // are both no-ops, so no wake is ever lost or counted twice.
        self.define(wake_task, &[I64], &[], |b, h| {
            let task = enter(b)[0];
            let (check, skip) = (b.create_block(), b.create_block());
            let live = b.ins().icmp_imm_s(IntCC::NotEqual, task, 0);
            brif(b, live, check, skip);
            b.switch_to_block(skip);
            b.ins().return_(&[]);
            b.switch_to_block(check);
            let status = b.ins().load(I64, flags(), task, TASK_STATUS);
            let queued = b.ins().load(I64, flags(), task, TASK_QUEUED);
            let done = b.ins().icmp_imm_s(IntCC::Equal, status, TASK_DONE);
            let in_queue = b.ins().icmp_imm_s(IntCC::NotEqual, queued, 0);
            let nothing = b.ins().bor(done, in_queue);
            let push = b.create_block();
            brif(b, nothing, skip, push);
            b.switch_to_block(push);
            // Leaving the suspended set.
            let (was_pending, mark) = (b.create_block(), b.create_block());
            let pending = b.ins().icmp_imm_s(IntCC::Equal, status, TASK_PENDING);
            brif(b, pending, was_pending, mark);
            b.switch_to_block(was_pending);
            let base = h.data_addr(b, suspended);
            let n = b.ins().load(I64, flags(), base, 0);
            let less = b.ins().iadd_imm_s(n, -1);
            b.ins().store(flags(), less, base, 0);
            jump(b, mark, &[]);
            b.switch_to_block(mark);
            let ready = b.ins().iconst(I64, TASK_READY);
            b.ins().store(flags(), ready, task, TASK_STATUS);
            h.call(b, push_ready, &[task]);
            b.ins().return_(&[]);
            Ok(())
        })?;

        if let Some(timers) = rt.timers {
            self.define_timers(&rt, timers, current, wake_task, fatal)?;
        }

        // l_rt_wake(): the running task is ready to be polled again.
        self.define(rt.wake, &[], &[], |b, h| {
            enter(b);
            let base = h.data_addr(b, current);
            let task = b.ins().load(I64, flags(), base, 0);
            h.call(b, wake_task, &[task]);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_task_spawn(state, kind) -> task: a fresh record owning the
        // state, queued as ready so that the scheduler starts it.
        self.define(rt.task_spawn, &[I64, I64], &[I64], |b, h| {
            let params = enter(b);
            let (state, kind) = (params[0], params[1]);
            let size = b.ins().iconst(
                I64,
                if timers_enabled {
                    timers::RECORD_SIZE
                } else {
                    TASK_RECORD_SIZE
                },
            );
            let task = h.call(b, rt.alloc, &[size])[0];
            h.call(b, zero, &[task, size]);
            b.ins().store(flags(), state, task, TASK_STATE);
            b.ins().store(flags(), kind, task, TASK_KIND);
            let ready = b.ins().iconst(I64, TASK_READY);
            b.ins().store(flags(), ready, task, TASK_STATUS);
            h.call(b, push_ready, &[task]);
            b.ins().return_(&[task]);
            Ok(())
        })?;

        // l_rt_task_ready(task) -> i64: 1 when the result is available.
        // Otherwise the running task becomes its waiter, so finishing it wakes
        // the waiter: no polling without a notification.
        self.define(rt.task_ready, &[I64], &[I64], |b, h| {
            let task = enter(b)[0];
            let status = b.ins().load(I64, flags(), task, TASK_STATUS);
            let (finished, waiting) = (b.create_block(), b.create_block());
            let done = b.ins().icmp_imm_s(IntCC::Equal, status, TASK_DONE);
            brif(b, done, finished, waiting);
            b.switch_to_block(finished);
            let one = b.ins().iconst(I64, 1);
            b.ins().return_(&[one]);
            b.switch_to_block(waiting);
            let base = h.data_addr(b, current);
            let me = b.ins().load(I64, flags(), base, 0);
            b.ins().store(flags(), me, task, TASK_WAITER);
            let no = b.ins().iconst(I64, 0);
            b.ins().return_(&[no]);
            Ok(())
        })?;

        // Register once, during one scheduler turn. Child completions then
        // decrement the parent's counter without rescanning the collection.
        self.define(rt.group_register, &[I64, I64], &[I64], |b, h| {
            let args = enter(b);
            let (data, len) = (args[0], args[1]);
            let (head, item, done) = (b.create_block(), b.create_block(), b.create_block());
            b.append_block_param(head, I64);
            b.append_block_param(head, I64);
            let zero = b.ins().iconst(I64, 0);
            jump(b, head, &[zero, zero]);
            b.switch_to_block(head);
            let (index, pending) = (b.block_params(head)[0], b.block_params(head)[1]);
            let more = b.ins().icmp(IntCC::UnsignedLessThan, index, len);
            brif(b, more, item, done);
            b.switch_to_block(item);
            let offset = b.ins().imul_imm_s(index, 8);
            let addr = b.ins().iadd(data, offset);
            let task = b.ins().load(I64, flags(), addr, 0);
            let ready = h.call(b, rt.task_ready, &[task])[0];
            let one = b.ins().iconst(I64, 1);
            let waiting = b.ins().isub(one, ready);
            let next = b.ins().iadd_imm_s(index, 1);
            let count = b.ins().iadd(pending, waiting);
            jump(b, head, &[next, count]);
            b.switch_to_block(done);
            let base = h.data_addr(b, current);
            let parent = b.ins().load(I64, flags(), base, 0);
            b.ins().store(flags(), pending, parent, TASK_GROUP_PENDING);
            b.ins().return_(&[pending]);
            Ok(())
        })?;
        self.define(rt.group_pending, &[], &[I64], |b, h| {
            enter(b);
            let base = h.data_addr(b, current);
            let parent = b.ins().load(I64, flags(), base, 0);
            let pending = b.ins().load(I64, flags(), parent, TASK_GROUP_PENDING);
            b.ins().return_(&[pending]);
            Ok(())
        })?;

        // l_rt_task_state(task) -> ptr.
        self.define(rt.task_state, &[I64], &[I64], |b, _| {
            let task = enter(b)[0];
            let state = b.ins().load(I64, flags(), task, TASK_STATE);
            b.ins().return_(&[state]);
            Ok(())
        })?;

        // l_rt_task_cancel(task): destroying the handle of a task. The state
        // destructor releases what the suspended body still owns, including the
        // handles of its own tasks, so cancellation cascades down the tree. The
        // cascade is iterative: while one cancellation is in progress the
        // others are queued in a list of records awaiting destruction and
        // drained here, so the depth of the task tree never costs stack.
        self.define(rt.task_cancel, &[I64], &[], |b, h| {
            let task = enter(b)[0];
            let (live, out) = (b.create_block(), b.create_block());
            let some = b.ins().icmp_imm_s(IntCC::NotEqual, task, 0);
            brif(b, some, live, out);
            b.switch_to_block(out);
            b.ins().return_(&[]);
            b.switch_to_block(live);
            let busy_addr = h.data_addr(b, cancelling);
            let busy = b.ins().load(I64, flags(), busy_addr, 0);
            let (defer, start) = (b.create_block(), b.create_block());
            let nested = b.ins().icmp_imm_s(IntCC::NotEqual, busy, 0);
            brif(b, nested, defer, start);
            b.switch_to_block(defer);
            let head_addr = h.data_addr(b, purge_head);
            let head = b.ins().load(I64, flags(), head_addr, 0);
            b.ins().store(flags(), head, task, TASK_PURGE);
            b.ins().store(flags(), task, head_addr, 0);
            b.ins().return_(&[]);
            b.switch_to_block(start);
            let one = b.ins().iconst(I64, 1);
            b.ins().store(flags(), one, busy_addr, 0);
            h.call(b, purge_task, &[task]);
            let drain = b.create_block();
            jump(b, drain, &[]);
            b.switch_to_block(drain);
            let head_addr = h.data_addr(b, purge_head);
            let next = b.ins().load(I64, flags(), head_addr, 0);
            let (more, done) = (b.create_block(), b.create_block());
            let pending_purge = b.ins().icmp_imm_s(IntCC::NotEqual, next, 0);
            brif(b, pending_purge, more, done);
            b.switch_to_block(more);
            let after = b.ins().load(I64, flags(), next, TASK_PURGE);
            b.ins().store(flags(), after, head_addr, 0);
            h.call(b, purge_task, &[next]);
            jump(b, drain, &[]);
            b.switch_to_block(done);
            let free_again = b.ins().iconst(I64, 0);
            b.ins().store(flags(), free_again, busy_addr, 0);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_purge_task(task): destroys one task record. A record still in
        // the ready queue leaves it first (the queue is doubly linked, so that
        // costs O(1)), and then the record is released: the queue never holds a
        // dangling pointer and a cancelled task never lingers.
        self.define(purge_task, &[I64], &[], |b, h| {
            let task = enter(b)[0];
            if let Some(timers) = rt.timers {
                h.call(b, timers.cancel, &[task]);
            }
            let status = b.ins().load(I64, flags(), task, TASK_STATUS);
            let (drop_pending, counted_done) = (b.create_block(), b.create_block());
            let pending = b.ins().icmp_imm_s(IntCC::Equal, status, TASK_PENDING);
            brif(b, pending, drop_pending, counted_done);
            b.switch_to_block(drop_pending);
            let base = h.data_addr(b, suspended);
            let n = b.ins().load(I64, flags(), base, 0);
            let less = b.ins().iadd_imm_s(n, -1);
            b.ins().store(flags(), less, base, 0);
            jump(b, counted_done, &[]);
            b.switch_to_block(counted_done);
            let state = b.ins().load(I64, flags(), task, TASK_STATE);
            let nothing = b.ins().iconst(I64, 0);
            b.ins().store(flags(), nothing, task, TASK_STATE);
            b.ins().store(flags(), nothing, task, TASK_WAITER);
            let (release, released) = (b.create_block(), b.create_block());
            let has_state = b.ins().icmp_imm_s(IntCC::NotEqual, state, 0);
            brif(b, has_state, release, released);
            b.switch_to_block(release);
            let kind = b.ins().load(I64, flags(), task, TASK_KIND);
            h.call(b, rt.drop_dispatch, &[kind, state]);
            h.call(b, free, &[state]);
            jump(b, released, &[]);
            b.switch_to_block(released);
            let queued = b.ins().load(I64, flags(), task, TASK_QUEUED);
            let (unlink, release_record) = (b.create_block(), b.create_block());
            let in_queue = b.ins().icmp_imm_s(IntCC::NotEqual, queued, 0);
            brif(b, in_queue, unlink, release_record);
            b.switch_to_block(unlink);
            h.call(b, leave_ready, &[task]);
            jump(b, release_record, &[]);
            b.switch_to_block(release_record);
            h.call(b, free, &[task]);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_run(): the scheduler. Round-robin over the FIFO queue of ready
        // tasks; a task that returns Pending leaves the queue until it is
        // notified, which lets the other tasks make progress meanwhile.
        self.define(rt.run, &[], &[], |b, h| {
            enter(b);
            let head_addr = h.data_addr(b, ready_head);
            let tail_addr = h.data_addr(b, ready_tail);
            let current_addr = h.data_addr(b, current);
            let loop_b = b.create_block();
            jump(b, loop_b, &[]);
            b.switch_to_block(loop_b);
            let next_timer = rt.timers.map(|timers| h.call(b, timers.pump, &[])[0]);
            let task = b.ins().load(I64, flags(), head_addr, 0);
            let (drained, pop) = (b.create_block(), b.create_block());
            let empty = b.ins().icmp_imm_s(IntCC::Equal, task, 0);
            brif(b, empty, drained, pop);

            // Nothing ready: either everything finished or no notification can
            // ever arrive for the tasks that are still suspended.
            b.switch_to_block(drained);
            if let (Some(timers), Some(delay)) = (rt.timers, next_timer) {
                let (park, check) = (b.create_block(), b.create_block());
                let timer_pending = b.ins().icmp_imm_s(IntCC::SignedGreaterThan, delay, 0);
                brif(b, timer_pending, park, check);
                b.switch_to_block(park);
                h.call(b, timers.park, &[delay]);
                jump(b, loop_b, &[]);
                b.switch_to_block(check);
            }

            let base = h.data_addr(b, suspended);
            let n = b.ins().load(I64, flags(), base, 0);
            let (stuck, finish) = (b.create_block(), b.create_block());
            let waiting = b.ins().icmp_imm_s(IntCC::SignedGreaterThan, n, 0);
            brif(b, waiting, stuck, finish);
            b.switch_to_block(stuck);
            let (p, l) = h.text(b, DEADLOCK_MESSAGE)?;
            h.call(b, fatal, &[p, l]);
            never(b);
            b.switch_to_block(finish);
            if let Some(timers) = rt.timers {
                h.call(b, timers.finish, &[]);
            }

            b.ins().return_(&[]);

            // Pop the head of the queue.
            b.switch_to_block(pop);
            let next = b.ins().load(I64, flags(), task, TASK_NEXT);
            b.ins().store(flags(), next, head_addr, 0);
            let (clear_tail, popped) = (b.create_block(), b.create_block());
            let was_last = b.ins().icmp_imm_s(IntCC::Equal, next, 0);
            brif(b, was_last, clear_tail, popped);
            b.switch_to_block(clear_tail);
            let nothing = b.ins().iconst(I64, 0);
            b.ins().store(flags(), nothing, tail_addr, 0);
            jump(b, popped, &[]);
            b.switch_to_block(popped);
            let out_of_queue = b.ins().iconst(I64, 0);
            b.ins().store(flags(), out_of_queue, task, TASK_QUEUED);
            b.ins().store(flags(), out_of_queue, task, TASK_NEXT);
            b.ins().store(flags(), out_of_queue, task, TASK_PREV);
            let (clear_back, alive) = (b.create_block(), b.create_block());
            let has_next = b.ins().icmp_imm_s(IntCC::NotEqual, next, 0);
            brif(b, has_next, clear_back, alive);
            b.switch_to_block(clear_back);
            b.ins().store(flags(), out_of_queue, next, TASK_PREV);
            jump(b, alive, &[]);

            // Poll it. A cancelled record is never in the queue: cancelling one
            // unlinks it and frees it there and then.
            b.switch_to_block(alive);
            b.ins().store(flags(), task, current_addr, 0);
            let kind = b.ins().load(I64, flags(), task, TASK_KIND);
            let state = b.ins().load(I64, flags(), task, TASK_STATE);
            let result = h.call(b, rt.poll_dispatch, &[kind, state])[0];
            let none = b.ins().iconst(I64, 0);
            b.ins().store(flags(), none, current_addr, 0);
            let (ready_now, pending_now) = (b.create_block(), b.create_block());
            let is_ready = b.ins().icmp_imm_s(IntCC::Equal, result, 1);
            brif(b, is_ready, ready_now, pending_now);

            // Finished: wake whoever was waiting for its result.
            b.switch_to_block(ready_now);
            let done = b.ins().iconst(I64, TASK_DONE);
            b.ins().store(flags(), done, task, TASK_STATUS);
            let waiter = b.ins().load(I64, flags(), task, TASK_WAITER);
            let cleared = b.ins().iconst(I64, 0);
            b.ins().store(flags(), cleared, task, TASK_WAITER);
            let (notify, group, wake) = (b.create_block(), b.create_block(), b.create_block());
            let has_waiter = b.ins().icmp_imm_s(IntCC::NotEqual, waiter, 0);
            brif(b, has_waiter, notify, loop_b);
            b.switch_to_block(notify);
            let pending = b.ins().load(I64, flags(), waiter, TASK_GROUP_PENDING);
            let single = b.ins().icmp_imm_s(IntCC::Equal, pending, 0);
            brif(b, single, wake, group);
            b.switch_to_block(group);
            let remaining = b.ins().iadd_imm_s(pending, -1);
            b.ins()
                .store(flags(), remaining, waiter, TASK_GROUP_PENDING);
            let last = b.ins().icmp_imm_s(IntCC::Equal, remaining, 0);
            brif(b, last, wake, loop_b);
            b.switch_to_block(wake);
            h.call(b, wake_task, &[waiter]);
            jump(b, loop_b, &[]);

            // Suspended: unless it notified itself while running, it leaves the
            // queue and waits. Counting it is what makes a deadlock visible.
            b.switch_to_block(pending_now);
            counted(b, h, SUSPENDS);
            let queued = b.ins().load(I64, flags(), task, TASK_QUEUED);
            let (requeued, suspend) = (b.create_block(), b.create_block());
            let again = b.ins().icmp_imm_s(IntCC::NotEqual, queued, 0);
            brif(b, again, requeued, suspend);
            b.switch_to_block(requeued);
            jump(b, loop_b, &[]);
            b.switch_to_block(suspend);
            let pending = b.ins().iconst(I64, TASK_PENDING);
            b.ins().store(flags(), pending, task, TASK_STATUS);
            let base = h.data_addr(b, suspended);
            let n = b.ins().load(I64, flags(), base, 0);
            let more = b.ins().iadd_imm_s(n, 1);
            b.ins().store(flags(), more, base, 0);
            jump(b, loop_b, &[]);
            Ok(())
        })?;

        // Regions: bump allocation in a chain of heap blocks. The header lives
        // in the frame that opened the region; an empty region owns nothing.
        self.define(rt.region_alloc, &[I64, I64, I64, I64], &[I64], |b, h| {
            let params = enter(b);
            let (hdr, n, line, col) = (params[0], params[1], params[2], params[3]);
            let (negative, sized) = (b.create_block(), b.create_block());
            let is_negative = b.ins().icmp_imm_s(IntCC::SignedLessThan, n, 0);
            brif(b, is_negative, negative, sized);
            b.switch_to_block(negative);
            let (p, l) = h.text(b, NEGATIVE_SIZE)?;
            h.call(b, rt.panic_at, &[line, col, p, l]);
            never(b);

            b.switch_to_block(sized);
            let block = b.ins().load(I64, flags(), hdr, REGION_BLOCK);
            let offset = b.ins().load(I64, flags(), hdr, REGION_OFFSET);
            let capacity = b.ins().load(I64, flags(), hdr, REGION_CAPACITY);
            // offset <= capacity always holds, so `room` cannot wrap.
            let bumped = b.ins().iadd_imm_s(offset, 7);
            let aligned = b.ins().band_imm_s(bumped, -8);
            let has_block = b.ins().icmp_imm_s(IntCC::NotEqual, block, 0);
            let aligned_fits = b
                .ins()
                .icmp(IntCC::UnsignedLessThanOrEqual, aligned, capacity);
            let room = b.ins().isub(capacity, aligned);
            let n_fits = b.ins().icmp(IntCC::UnsignedLessThanOrEqual, n, room);
            let fits = b.ins().band(aligned_fits, n_fits);
            let fast_ok = b.ins().band(has_block, fits);
            let done = b.create_block();
            let ptr = b.append_block_param(done, I64);
            let (fast, slow) = (b.create_block(), b.create_block());
            brif(b, fast_ok, fast, slow);

            b.switch_to_block(fast);
            let data = b.ins().iadd_imm_s(block, REGION_BLOCK_HEADER);
            let at = b.ins().iadd(data, aligned);
            let end = b.ins().iadd(aligned, n);
            b.ins().store(flags(), end, hdr, REGION_OFFSET);
            jump(b, done, &[at]);

            // New block: max(n, 2 * capacity, REGION_MIN_BLOCK) bytes of data.
            b.switch_to_block(slow);
            let doubled = b.ins().iadd(capacity, capacity);
            let bigger = b.ins().icmp(IntCC::UnsignedGreaterThan, doubled, n);
            let want = b.ins().select(bigger, doubled, n);
            let small = b
                .ins()
                .icmp_imm_u(IntCC::UnsignedLessThan, want, REGION_MIN_BLOCK);
            let min = b.ins().iconst(I64, REGION_MIN_BLOCK);
            let want = b.ins().select(small, min, want);
            let too_big = b.ins().icmp_imm_u(
                IntCC::UnsignedGreaterThan,
                want,
                i64::MAX - REGION_BLOCK_HEADER,
            );
            let (fail, grow) = (b.create_block(), b.create_block());
            brif(b, too_big, fail, grow);
            b.switch_to_block(fail);
            oom(b, h)?;
            b.switch_to_block(grow);
            let total = b.ins().iadd_imm_s(want, REGION_BLOCK_HEADER);
            let fresh = h.call(b, rt.alloc, &[total])[0];
            b.ins().store(flags(), block, fresh, 0);
            b.ins().store(flags(), fresh, hdr, REGION_BLOCK);
            b.ins().store(flags(), want, hdr, REGION_CAPACITY);
            b.ins().store(flags(), n, hdr, REGION_OFFSET);
            let at = b.ins().iadd_imm_s(fresh, REGION_BLOCK_HEADER);
            jump(b, done, &[at]);

            b.switch_to_block(done);
            // Buffers start zeroed: L never exposes uninitialized memory.
            h.call(b, zero, &[ptr, n]);
            if let Some(s) = stats {
                bump(b, h, s, REGION_ALLOCS);
                let base = h.data_addr(b, s);
                let total = b.ins().load(I64, flags(), base, REGION_BYTES);
                let total = b.ins().iadd(total, n);
                b.ins().store(flags(), total, base, REGION_BYTES);
            }
            if options.trace_alloc {
                let low = b.ins().band_imm_s(ptr, 7);
                let misaligned = b.ins().icmp_imm_s(IntCC::NotEqual, low, 0);
                let (bad, ok) = (b.create_block(), b.create_block());
                brif(b, misaligned, bad, ok);
                b.switch_to_block(bad);
                let (p, l) = h.text(b, MISALIGNED)?;
                h.call(b, fatal, &[p, l]);
                never(b);
                b.switch_to_block(ok);
            }
            b.ins().return_(&[ptr]);
            Ok(())
        })?;
        self.define(rt.region_free, &[I64], &[], |b, h| {
            let hdr = enter(b)[0];
            let first = b.ins().load(I64, flags(), hdr, REGION_BLOCK);
            let head = b.create_block();
            let block = b.append_block_param(head, I64);
            let (body, done) = (b.create_block(), b.create_block());
            jump(b, head, &[first]);
            b.switch_to_block(head);
            let more = b.ins().icmp_imm_s(IntCC::NotEqual, block, 0);
            brif(b, more, body, done);
            b.switch_to_block(body);
            let previous = b.ins().load(I64, flags(), block, 0);
            h.call(b, free, &[block]);
            jump(b, head, &[previous]);
            b.switch_to_block(done);
            let zero64 = b.ins().iconst(I64, 0);
            b.ins().store(flags(), zero64, hdr, REGION_BLOCK);
            b.ins().return_(&[]);
            Ok(())
        })?;
        // l_rt_zero(ptr, n): byte fill with 0.
        self.define(zero, &[I64, I64], &[], |b, _| {
            let params = enter(b);
            let (dst, n) = (params[0], params[1]);
            let head = b.create_block();
            let i = b.append_block_param(head, I64);
            let (body, done) = (b.create_block(), b.create_block());
            let start = b.ins().iconst(I64, 0);
            jump(b, head, &[start]);
            b.switch_to_block(head);
            let more = b.ins().icmp(IntCC::UnsignedLessThan, i, n);
            brif(b, more, body, done);
            b.switch_to_block(body);
            let d = b.ins().iadd(dst, i);
            let z = b.ins().iconst(I8, 0);
            b.ins().store(flags(), z, d, 0);
            let next = b.ins().iadd_imm_s(i, 1);
            jump(b, head, &[next]);
            b.switch_to_block(done);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // l_rt_panic_arith(line, column).
        self.define(rt.panic_arith, &[I64, I64], &[], |b, h| {
            let params = enter(b);
            let err = b.ins().iconst(I32, STDERR);
            let (p, l) = h.text(b, "ELE ")?;
            h.call(b, write, &[err, p, l]);
            h.call(b, rt.write_int, &[err, params[0]]);
            let (p, l) = h.text(b, ":")?;
            h.call(b, write, &[err, p, l]);
            h.call(b, rt.write_int, &[err, params[1]]);
            let (p, l) = h.text(b, ARITH_MESSAGE)?;
            h.call(b, fatal, &[p, l]);
            never(b);
            Ok(())
        })?;
        Ok(rt)
    }

    /// `l_start`: runs main; with allocation tracing, reports the counters and
    /// a whole-heap validation on stderr; exits after main and its drops.
    pub(crate) fn entry_point(
        &mut self,
        rt: &Runtime,
        main: FuncId,
        returns_code: bool,
        options: Options,
    ) -> Result<(), Diagnostic> {
        let start = self.declare("l_start", Linkage::Export, &[], &[])?;
        self.define(start, &[], &[], |b, h| {
            let entry = b.create_block();
            b.switch_to_block(entry);
            let result = h.call(b, main, &[]);
            let code = if returns_code {
                let value = result[0];
                let invalid = b.ins().icmp_imm_s(IntCC::UnsignedGreaterThan, value, 255);
                let fallback = b.ins().iconst(types::I64, 255);
                let valid = b.ins().select(invalid, fallback, value);
                b.ins().ireduce(types::I32, valid)
            } else {
                b.ins().iconst(types::I32, 0)
            };
            if let (true, Some(stats)) = (options.trace_alloc, rt.stats) {
                let err = b.ins().iconst(types::I32, STDERR);
                let base = h.data_addr(b, stats);
                let timer_counters: &[(&str, i32)] = if rt.timers.is_some() {
                    &timers::COUNTERS
                } else {
                    &[]
                };
                for (label, offset) in [
                    ("l-alloc: allocs=", ALLOCS),
                    (" reallocs=", REALLOCS),
                    (" frees=", FREES),
                    (" region_allocs=", REGION_ALLOCS),
                    (" region_bytes=", REGION_BYTES),
                    (" region_retired=", REGION_RETIRED),
                    (" suspends=", SUSPENDS),
                ]
                .into_iter()
                .chain(timer_counters.iter().copied())
                {
                    let (p, l) = h.text(b, label)?;
                    h.call(b, rt.write, &[err, p, l]);
                    let n = b.ins().load(types::I64, flags(), base, offset);
                    h.call(b, rt.write_int, &[err, n]);
                }
                if let Some(platform) = &rt.platform {
                    for (index, label) in [
                        " file_opens=",
                        " file_closes=",
                        " file_reads=",
                        " file_short_reads=",
                        " file_open_ticks=",
                        " file_read_ticks=",
                        " file_utf8_ticks=",
                        " file_ticks_hz=",
                    ]
                    .into_iter()
                    .enumerate()
                    {
                        let (p, len) = h.text(b, label)?;
                        h.call(b, rt.write, &[err, p, len]);
                        let index = b.ins().iconst(types::I64, index as i64);
                        let count = h.call(b, platform.file_stat, &[index])[0];
                        h.call(b, rt.write_int, &[err, count]);
                    }
                }
                let heap = h.call(b, rt.get_process_heap, &[])[0];
                let zero32 = b.ins().iconst(types::I32, 0);
                let null = b.ins().iconst(types::I64, 0);
                let valid = h.call(b, rt.heap_validate, &[heap, zero32, null])[0];
                let ok = b.ins().icmp_imm_s(IntCC::NotEqual, valid, 0);
                let ok64 = b.ins().uextend(types::I64, ok);
                let (p, l) = h.text(b, " heap_ok=")?;
                h.call(b, rt.write, &[err, p, l]);
                h.call(b, rt.write_int, &[err, ok64]);
                let (p, l) = h.text(b, "\n")?;
                h.call(b, rt.write, &[err, p, l]);
            }
            h.call(b, rt.exit_process, &[code]);
            never(b);
            Ok(())
        })?;
        Ok(())
    }
}
