//! Indexed monotonic deadline heap and Windows parking, behind the scheduler ABI.
use super::*;

const TICKS_PER_MS: i64 = 10_000;
const DEADLINE: i32 = 72;
const HEAP_INDEX: i32 = 80; // Index plus one. Zero means not registered.
pub(super) const RECORD_SIZE: i64 = 88;
pub(super) const STATS_SIZE: usize = 104;
const REGISTERS: i32 = 64;
const WAKES: i32 = 72;
const CANCELS: i32 = 80;
const PARKS: i32 = 88;
const PEAK: i32 = 96;
pub(super) const COUNTERS: [(&str, i32); 5] = [
    (" timer_registers=", REGISTERS),
    (" timer_wakes=", WAKES),
    (" timer_cancels=", CANCELS),
    (" timer_parks=", PARKS),
    (" timer_peak=", PEAK),
];

#[derive(Clone, Copy)]
pub(crate) struct Timers {
    pub(crate) check: FuncId,
    pub(crate) start: FuncId,
    pub(crate) pending: FuncId,
    pub(super) cancel: FuncId,
    pub(super) pump: FuncId,
    pub(super) park: FuncId,
    pub(super) finish: FuncId,
}

fn local(
    g: &mut Gen,
    name: &str,
    params: &[ir::Type],
    ret: &[ir::Type],
) -> Result<FuncId, Diagnostic> {
    g.declare(name, Linkage::Local, params, ret)
}

impl Timers {
    pub(super) fn declare(g: &mut Gen) -> Result<Self, Diagnostic> {
        use types::I64;
        Ok(Self {
            check: local(g, "l_rt_sleep_check", &[I64, I64, I64], &[I64])?,
            start: local(g, "l_rt_timer_start", &[I64], &[I64])?,
            pending: local(g, "l_rt_timer_pending", &[], &[I64])?,
            cancel: local(g, "l_rt_timer_cancel", &[I64], &[])?,
            pump: local(g, "l_rt_timer_pump", &[], &[I64])?,
            park: local(g, "l_rt_timer_park", &[I64], &[])?,
            finish: local(g, "l_rt_timer_finish", &[], &[])?,
        })
    }
}

fn cell(b: &mut FunctionBuilder, base: ir::Value, index: ir::Value) -> ir::Value {
    let offset = b.ins().ishl_imm_s(index, 3);
    b.ins().iadd(base, offset)
}

fn node(b: &mut FunctionBuilder, base: ir::Value, index: ir::Value) -> ir::Value {
    let addr = cell(b, base, index);
    b.ins().load(types::I64, flags(), addr, 0)
}

fn before(b: &mut FunctionBuilder, a: ir::Value, z: ir::Value) -> ir::Value {
    let a = b.ins().load(types::I64, flags(), a, DEADLINE);
    let z = b.ins().load(types::I64, flags(), z, DEADLINE);
    b.ins().icmp(IntCC::UnsignedLessThan, a, z)
}

fn record(b: &mut FunctionBuilder, h: &mut Helpers, current: DataId) -> ir::Value {
    let addr = h.data_addr(b, current);
    b.ins().load(types::I64, flags(), addr, 0)
}

fn report(b: &mut FunctionBuilder, h: &mut Helpers, stats: Option<DataId>, offset: i32) {
    if let Some(stats) = stats {
        bump(b, h, stats, offset);
    }
}

fn fail(
    b: &mut FunctionBuilder,
    h: &mut Helpers,
    fatal: FuncId,
    message: &str,
) -> Result<(), Diagnostic> {
    let (msg, len) = h.text(b, message)?;
    h.call(b, fatal, &[msg, len]);
    never(b);
    Ok(())
}

impl Gen {
    pub(super) fn define_timers(
        &mut self,
        rt: &Runtime,
        timers: Timers,
        current: DataId,
        wake: FuncId,
        fatal: FuncId,
    ) -> Result<(), Diagnostic> {
        use types::{I32, I64};
        let clock = self.declare(
            "QueryUnbiasedInterruptTimePrecise",
            Linkage::Import,
            &[I64],
            &[],
        )?;
        let create = self.declare(
            "CreateWaitableTimerExW",
            Linkage::Import,
            &[I64, I64, I32, I32],
            &[I64],
        )?;
        let set = self.declare(
            "SetWaitableTimer",
            Linkage::Import,
            &[I64, I64, I32, I64, I64, I32],
            &[I32],
        )?;
        let wait = self.declare("WaitForSingleObject", Linkage::Import, &[I64, I32], &[I32])?;
        let close = self.declare("CloseHandle", Linkage::Import, &[I64], &[I32])?;
        let heap = self.zeroed("l_timer_heap", 24)?;
        let os_timer = self.zeroed("l_timer_handle", 8)?;
        let now = local(self, "l_timer_now", &[], &[I64])?;
        let swap = local(self, "l_timer_swap", &[I64, I64, I64], &[])?;
        let repair = local(self, "l_timer_repair", &[I64, I64, I64], &[])?;
        let remove = local(self, "l_timer_remove", &[I64], &[])?;

        self.define(now, &[], &[I64], |b, h| {
            enter(b);
            let space = slot(b, 8);
            let ptr = b.ins().stack_addr(I64, space, 0);
            h.call(b, clock, &[ptr]);
            let ticks = b.ins().stack_load(I64, I64, space, 0);
            b.ins().return_(&[ticks]);
            Ok(())
        })?;

        self.define(swap, &[I64, I64, I64], &[], |b, _| {
            let p = enter(b);
            let (base, i, j) = (p[0], p[1], p[2]);
            let x = cell(b, base, i);
            let y = cell(b, base, j);
            let a = b.ins().load(I64, flags(), x, 0);
            let z = b.ins().load(I64, flags(), y, 0);
            b.ins().store(flags(), z, x, 0);
            b.ins().store(flags(), a, y, 0);
            let i1 = b.ins().iadd_imm_s(i, 1);
            let j1 = b.ins().iadd_imm_s(j, 1);
            b.ins().store(flags(), i1, z, HEAP_INDEX);
            b.ins().store(flags(), j1, a, HEAP_INDEX);
            b.ins().return_(&[]);
            Ok(())
        })?;

        // Replacing a removed node with the last element may require either
        // direction. First move toward the root, then toward the leaves.
        self.define(repair, &[I64, I64, I64], &[], |b, h| {
            let p = enter(b);
            let (base, len, start) = (p[0], p[1], p[2]);
            let (up, parent, up_swap, down) = (
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
            );
            b.append_block_param(up, I64);
            b.append_block_param(down, I64);
            jump(b, up, &[start]);
            b.switch_to_block(up);
            let index = b.block_params(up)[0];
            let root = b.ins().icmp_imm_s(IntCC::Equal, index, 0);
            b.ins().brif(root, down, &[index.into()], parent, &[]);
            b.switch_to_block(parent);
            let previous = b.ins().iadd_imm_s(index, -1);
            let ancestor = b.ins().ushr_imm_s(previous, 1);
            let child = node(b, base, index);
            let above = node(b, base, ancestor);
            let rise = before(b, child, above);
            b.ins().brif(rise, up_swap, &[], down, &[index.into()]);
            b.switch_to_block(up_swap);
            h.call(b, swap, &[base, index, ancestor]);
            jump(b, up, &[ancestor]);

            b.switch_to_block(down);
            let index = b.block_params(down)[0];
            let double = b.ins().ishl_imm_s(index, 1);
            let left = b.ins().iadd_imm_s(double, 1);
            let (children, right_check, compare, down_swap, done) = (
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
            );
            b.append_block_param(compare, I64);
            let has_left = b.ins().icmp(IntCC::UnsignedLessThan, left, len);
            brif(b, has_left, children, done);
            b.switch_to_block(children);
            let right = b.ins().iadd_imm_s(left, 1);
            let has_right = b.ins().icmp(IntCC::UnsignedLessThan, right, len);
            b.ins()
                .brif(has_right, right_check, &[], compare, &[left.into()]);
            b.switch_to_block(right_check);
            let a = node(b, base, left);
            let z = node(b, base, right);
            let take_right = before(b, z, a);
            let best = b.ins().select(take_right, right, left);
            jump(b, compare, &[best]);
            b.switch_to_block(compare);
            let best = b.block_params(compare)[0];
            let a = node(b, base, best);
            let z = node(b, base, index);
            let sink = before(b, a, z);
            brif(b, sink, down_swap, done);
            b.switch_to_block(down_swap);
            h.call(b, swap, &[base, index, best]);
            jump(b, down, &[best]);
            b.switch_to_block(done);
            b.ins().return_(&[]);
            Ok(())
        })?;

        self.define(remove, &[I64], &[], |b, h| {
            let task = enter(b)[0];
            let header = h.data_addr(b, heap);
            let base = b.ins().load(I64, flags(), header, LIST_PTR);
            let old_len = b.ins().load(I64, flags(), header, LIST_LEN);
            let last = b.ins().iadd_imm_s(old_len, -1);
            let pos = b.ins().load(I64, flags(), task, HEAP_INDEX);
            let index = b.ins().iadd_imm_s(pos, -1);
            let zero = b.ins().iconst(I64, 0);
            b.ins().store(flags(), zero, task, HEAP_INDEX);
            b.ins().store(flags(), last, header, LIST_LEN);
            let (replace, done) = (b.create_block(), b.create_block());
            let different = b.ins().icmp(IntCC::NotEqual, index, last);
            brif(b, different, replace, done);
            b.switch_to_block(replace);
            let moved = node(b, base, last);
            let target = cell(b, base, index);
            b.ins().store(flags(), moved, target, 0);
            b.ins().store(flags(), pos, moved, HEAP_INDEX);
            h.call(b, repair, &[base, last, index]);
            jump(b, done, &[]);
            b.switch_to_block(done);
            b.ins().return_(&[]);
            Ok(())
        })?;

        self.define(timers.check, &[I64, I64, I64], &[I64], |b, h| {
            let args = enter(b);
            let (invalid, valid) = (b.create_block(), b.create_block());
            let bad = b.ins().icmp_imm_s(
                IntCC::UnsignedGreaterThan,
                args[0],
                crate::lir::MAX_SLEEP_MS,
            );
            brif(b, bad, invalid, valid);
            b.switch_to_block(invalid);
            let (msg, len) = h.text(b, &format!(": {}\n", crate::lir::INVALID_SLEEP))?;
            h.call(b, rt.panic_at, &[args[1], args[2], msg, len]);
            never(b);
            b.switch_to_block(valid);
            b.ins().return_(&[args[0]]);
            Ok(())
        })?;

        self.define(timers.start, &[I64], &[I64], |b, h| {
            let ms = enter(b)[0];
            let (immediate, deadline, overflow, insert) = (
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
            );
            let zero = b.ins().iconst(I64, 0);
            let no_wait = b.ins().icmp_imm_s(IntCC::Equal, ms, 0);
            brif(b, no_wait, immediate, deadline);
            b.switch_to_block(immediate);
            b.ins().return_(&[zero]);
            b.switch_to_block(deadline);
            let start = h.call(b, now, &[])[0];
            let ticks = b.ins().imul_imm_s(ms, TICKS_PER_MS);
            let end = b.ins().iadd(start, ticks);
            let wrapped = b.ins().icmp(IntCC::UnsignedLessThan, end, start);
            brif(b, wrapped, overflow, insert);
            b.switch_to_block(overflow);
            fail(b, h, fatal, "ELE: deadline de sleepMs fuera de rango\n")?;
            b.switch_to_block(insert);
            let task = record(b, h, current);
            let header = h.data_addr(b, heap);
            let one = b.ins().iconst(I64, 1);
            let stride = b.ins().iconst(I64, 8);
            h.call(
                b,
                rt.list_reserve,
                &[header, one, stride, stride, zero, zero, zero],
            );
            let base = b.ins().load(I64, flags(), header, LIST_PTR);
            let index = b.ins().load(I64, flags(), header, LIST_LEN);
            let len = b.ins().iadd_imm_s(index, 1);
            let entry = cell(b, base, index);
            b.ins().store(flags(), task, entry, 0);
            b.ins().store(flags(), len, task, HEAP_INDEX);
            b.ins().store(flags(), end, task, DEADLINE);
            b.ins().store(flags(), len, header, LIST_LEN);
            h.call(b, repair, &[base, len, index]);
            report(b, h, rt.stats, REGISTERS);
            if let Some(stats) = rt.stats {
                let stats = h.data_addr(b, stats);
                let offset = PEAK;
                let old = b.ins().load(I64, flags(), stats, offset);
                let higher = b.ins().icmp(IntCC::UnsignedGreaterThan, len, old);
                let peak = b.ins().select(higher, len, old);
                b.ins().store(flags(), peak, stats, offset);
            }
            b.ins().return_(&[one]);
            Ok(())
        })?;

        self.define(timers.pending, &[], &[I64], |b, h| {
            enter(b);
            let task = record(b, h, current);
            let pending = b.ins().load(I64, flags(), task, HEAP_INDEX);
            b.ins().return_(&[pending]);
            Ok(())
        })?;

        self.define(timers.cancel, &[I64], &[], |b, h| {
            let task = enter(b)[0];
            let (cancel, done) = (b.create_block(), b.create_block());
            let index = b.ins().load(I64, flags(), task, HEAP_INDEX);
            let present = b.ins().icmp_imm_s(IntCC::NotEqual, index, 0);
            brif(b, present, cancel, done);
            b.switch_to_block(cancel);
            h.call(b, remove, &[task]);
            report(b, h, rt.stats, CANCELS);
            jump(b, done, &[]);
            b.switch_to_block(done);
            b.ins().return_(&[]);
            Ok(())
        })?;

        self.define(timers.pump, &[], &[I64], |b, h| {
            enter(b);
            let header = h.data_addr(b, heap);
            let (empty, sample, head, next, expired, remaining) = (
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
            );
            let len = b.ins().load(I64, flags(), header, LIST_LEN);
            let no_timers = b.ins().icmp_imm_s(IntCC::Equal, len, 0);
            brif(b, no_timers, empty, sample);
            b.switch_to_block(empty);
            let none = b.ins().iconst(I64, -1);
            b.ins().return_(&[none]);
            b.switch_to_block(sample);
            let time = h.call(b, now, &[])[0];
            let base = b.ins().load(I64, flags(), header, LIST_PTR);
            jump(b, head, &[]);
            b.switch_to_block(head);
            let len = b.ins().load(I64, flags(), header, LIST_LEN);
            let no_timers = b.ins().icmp_imm_s(IntCC::Equal, len, 0);
            brif(b, no_timers, empty, next);
            b.switch_to_block(next);
            let task = b.ins().load(I64, flags(), base, 0);
            let deadline = b.ins().load(I64, flags(), task, DEADLINE);
            let due = b.ins().icmp(IntCC::UnsignedLessThanOrEqual, deadline, time);
            brif(b, due, expired, remaining);
            b.switch_to_block(expired);
            h.call(b, remove, &[task]);
            report(b, h, rt.stats, WAKES);
            h.call(b, wake, &[task]);
            jump(b, head, &[]);
            b.switch_to_block(remaining);
            let delay = b.ins().isub(deadline, time);
            b.ins().return_(&[delay]);
            Ok(())
        })?;

        self.define(timers.park, &[I64], &[], |b, h| {
            let delay = enter(b)[0];
            let address = h.data_addr(b, os_timer);
            let existing = b.ins().load(I64, flags(), address, 0);
            let zero = b.ins().iconst(I64, 0);
            let zero32 = b.ins().iconst(I32, 0);
            let (open, fallback, save, arm, park, done, failure) = (
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
                b.create_block(),
            );
            b.append_block_param(save, I64);
            b.append_block_param(arm, I64);
            let have = b.ins().icmp_imm_s(IntCC::NotEqual, existing, 0);
            b.ins().brif(have, arm, &[existing.into()], open, &[]);
            b.switch_to_block(open);
            let high_res = b.ins().iconst(I32, 2);
            let access = b.ins().iconst(I32, 0x10_0002);
            let handle = h.call(b, create, &[zero, zero, high_res, access])[0];
            let opened = b.ins().icmp_imm_s(IntCC::NotEqual, handle, 0);
            b.ins().brif(opened, save, &[handle.into()], fallback, &[]);
            b.switch_to_block(fallback);
            let handle = h.call(b, create, &[zero, zero, zero32, access])[0];
            let opened = b.ins().icmp_imm_s(IntCC::NotEqual, handle, 0);
            b.ins().brif(opened, save, &[handle.into()], failure, &[]);
            b.switch_to_block(save);
            let handle = b.block_params(save)[0];
            b.ins().store(flags(), handle, address, 0);
            jump(b, arm, &[handle]);
            b.switch_to_block(arm);
            let handle = b.block_params(arm)[0];
            let due = b.ins().ineg(delay);
            let storage = slot(b, 8);
            b.ins().stack_store(I64, due, storage, 0);
            let ptr = b.ins().stack_addr(I64, storage, 0);
            let ok = h.call(b, set, &[handle, ptr, zero32, zero, zero, zero32])[0];
            let armed = b.ins().icmp_imm_s(IntCC::NotEqual, ok, 0);
            brif(b, armed, park, failure);
            b.switch_to_block(park);
            report(b, h, rt.stats, PARKS);
            let forever = b.ins().iconst(I32, -1);
            let status = h.call(b, wait, &[handle, forever])[0];
            let signaled = b.ins().icmp_imm_s(IntCC::Equal, status, 0);
            brif(b, signaled, done, failure);
            b.switch_to_block(failure);
            fail(
                b,
                h,
                fatal,
                "ELE: no se pudo esperar el temporizador de Windows\n",
            )?;
            b.switch_to_block(done);
            b.ins().return_(&[]);
            Ok(())
        })?;

        self.define(timers.finish, &[], &[], |b, h| {
            enter(b);
            let header = h.data_addr(b, heap);
            let base = b.ins().load(I64, flags(), header, LIST_PTR);
            let (free, cleared) = (b.create_block(), b.create_block());
            let allocated = b.ins().icmp_imm_s(IntCC::NotEqual, base, 0);
            brif(b, allocated, free, cleared);
            b.switch_to_block(free);
            h.call(b, rt.free, &[base]);
            jump(b, cleared, &[]);
            b.switch_to_block(cleared);
            let bytes = b.ins().iconst(I64, 24);
            h.call(b, rt.zero, &[header, bytes]);
            let address = h.data_addr(b, os_timer);
            let handle = b.ins().load(I64, flags(), address, 0);
            let (release, done) = (b.create_block(), b.create_block());
            let opened = b.ins().icmp_imm_s(IntCC::NotEqual, handle, 0);
            brif(b, opened, release, done);
            b.switch_to_block(release);
            h.call(b, close, &[handle]);
            let zero = b.ins().iconst(I64, 0);
            b.ins().store(flags(), zero, address, 0);
            jump(b, done, &[]);
            b.switch_to_block(done);
            b.ins().return_(&[]);
            Ok(())
        })?;
        Ok(())
    }
}
