// Cooperative single-thread scheduler for the reference backend. The semantics
// match the native runtime (`native/runtime.rs`): futures are lazy and only
// progress when polled, tasks wait in a FIFO queue of ready tasks (intrusive
// and doubly linked, so leaving it costs O(1)), a pending task is not polled
// again until it is notified, destroying a handle cancels its task at once, and
// no thread is ever created or blocked.
const L_READY: u8 = 0;
const L_PENDING: u8 = 1;
const L_DONE: u8 = 2;

type LFuture<T> = std::pin::Pin<Box<dyn std::future::Future<Output = T>>>;

struct LRecord {
    future: Option<std::pin::Pin<Box<dyn std::future::Future<Output = ()>>>>,
    status: u8,
    queued: bool,
    /// Neighbours in the ready queue (ids, 0 = none).
    next: usize,
    prev: usize,
    /// Task waiting for this one to finish (its id), or 0.
    waiter: usize,
    pending_children: usize,
    timer: Option<std::time::Instant>,
}

thread_local! {
    /// Task records by id - 1; a free slot is reused by the next spawn.
    static L_TASKS: std::cell::RefCell<Vec<Option<LRecord>>> = const { std::cell::RefCell::new(Vec::new()) };
    /// Free slots, so registering a task never scans the table.
    static L_FREE: std::cell::RefCell<Vec<usize>> = const { std::cell::RefCell::new(Vec::new()) };
    /// Ends of the ready queue (ids, 0 = empty).
    static L_HEAD: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    static L_TAIL: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    /// Task being polled (0 outside the scheduler).
    static L_CURRENT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    /// Tasks suspended with no notification pending.
    static L_SUSPENDED: std::cell::Cell<i64> = const { std::cell::Cell::new(0) };
    /// Set while a cancellation is in progress, so the cascade stays iterative.
    static L_CANCELLING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    /// Tasks waiting to be destroyed by the cancellation in progress.
    static L_PURGE: std::cell::RefCell<Vec<usize>> = const { std::cell::RefCell::new(Vec::new()) };
}

fn l_current() -> usize {
    L_CURRENT.with(|c| c.get())
}

fn l_with<R>(id: usize, f: impl FnOnce(&mut LRecord) -> R) -> Option<R> {
    L_TASKS.with(|t| {
        t.borrow_mut()
            .get_mut(id.wrapping_sub(1))
            .and_then(|slot| slot.as_mut())
            .map(f)
    })
}

/// Appends to the tail of the ready queue.
fn l_push_ready(id: usize) {
    let tail = L_TAIL.with(|c| c.get());
    l_with(id, |r| {
        r.next = 0;
        r.prev = tail;
        r.queued = true;
    });
    if tail == 0 {
        L_HEAD.with(|c| c.set(id));
    } else {
        l_with(tail, |r| r.next = id);
    }
    L_TAIL.with(|c| c.set(id));
}

/// Unlinks a queued record from the ready queue.
fn l_leave_ready(id: usize) {
    let (prev, next) = match l_with(id, |r| {
        r.queued = false;
        (std::mem::take(&mut r.prev), std::mem::take(&mut r.next))
    }) {
        Some(x) => x,
        None => return,
    };
    if prev == 0 {
        L_HEAD.with(|c| c.set(next));
    } else {
        l_with(prev, |r| r.next = next);
    }
    if next == 0 {
        L_TAIL.with(|c| c.set(prev));
    } else {
        l_with(next, |r| r.prev = prev);
    }
}

fn l_pop_ready() -> usize {
    let id = L_HEAD.with(|c| c.get());
    if id != 0 {
        l_leave_ready(id);
    }
    id
}

/// Makes a task ready again. A duplicate notification, and one sent to a task
/// that already finished, are both no-ops: no wake is lost and none is counted
/// twice. A cancelled task no longer exists, so none can reach it.
fn l_wake(id: usize) {
    if id == 0 {
        return;
    }
    let push = l_with(id, |r| {
        if r.status == L_DONE || r.queued {
            return false;
        }
        if r.status == L_PENDING {
            L_SUSPENDED.with(|c| c.set(c.get() - 1));
        }
        r.status = L_READY;
        true
    });
    if push == Some(true) {
        l_push_ready(id);
    }
}

/// An owned handle to a spawned task: awaiting it yields the result, dropping
/// it cancels the task. Not `Copy` and not `Clone`, like `TaskHandle<T>`.
struct LTask<T> {
    id: usize,
    slot: std::rc::Rc<std::cell::RefCell<Option<T>>>,
}

impl<T> LTask<T> {
    fn ready(&self) -> bool {
        if self.slot.borrow().is_some() {
            return true;
        }
        let me = l_current();
        l_with(self.id, |r| r.waiter = me);
        false
    }

    fn take_result(&self) -> T {
        self.slot.borrow_mut().take().expect("resultado listo de una tarea")
    }
}

impl<T> std::future::Future for LTask<T> {
    type Output = T;
    fn poll(
        self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<T> {
        if self.ready() {
            std::task::Poll::Ready(self.take_result())
        } else {
            std::task::Poll::Pending
        }
    }
}

async fn l_join<A, B>(a: LTask<A>, b: LTask<B>) -> (A, B) {
    std::future::poll_fn(|_| {
        let a_ready = a.ready();
        let b_ready = b.ready();
        if a_ready && b_ready {
            std::task::Poll::Ready((a.take_result(), b.take_result()))
        } else {
            std::task::Poll::Pending
        }
    })
    .await
}

async fn l_join_all<T>(tasks: Vec<LTask<T>>) -> Vec<T> {
    let parent = l_current();
    let pending = tasks.iter().filter(|task| !task.ready()).count();
    l_with(parent, |r| r.pending_children = pending);
    std::future::poll_fn(|_| {
        if l_with(parent, |r| r.pending_children) == Some(0) {
            std::task::Poll::Ready(())
        } else {
            std::task::Poll::Pending
        }
    }).await;
    let mut results = Vec::with_capacity(tasks.len());
    for task in tasks {
        results.push(task.take_result());
    }
    results
}

impl<T> Drop for LTask<T> {
    fn drop(&mut self) {
        l_cancel(self.id);
    }
}

/// Destroys a task: its future is dropped, which releases what it owns and in
/// cascade cancels the tasks whose handles it holds. The cascade is iterative:
/// while one cancellation is in progress the others wait in a list and are
/// drained here, so the depth of the task tree never costs stack.
fn l_cancel(id: usize) {
    if id == 0 {
        return;
    }
    if L_CANCELLING.with(|c| c.get()) {
        L_PURGE.with(|p| p.borrow_mut().push(id));
        return;
    }
    L_CANCELLING.with(|c| c.set(true));
    l_purge(id);
    while let Some(next) = L_PURGE.with(|p| p.borrow_mut().pop()) {
        l_purge(next);
    }
    L_CANCELLING.with(|c| c.set(false));
}

/// Destroys one task record. A record still in the ready queue leaves it first,
/// so the queue never holds a dangling id and a cancelled task never lingers.
fn l_purge(id: usize) {
    let (future, queued) = match l_with(id, |r| {
        if r.status == L_PENDING {
            L_SUSPENDED.with(|c| c.set(c.get() - 1));
        }
        r.waiter = 0;
        (r.future.take(), r.queued)
    }) {
        Some(x) => x,
        None => return,
    };
    l_cancel_timer(id);
    drop(future);
    if queued {
        l_leave_ready(id);
    }
    l_release(id);
}

fn l_release(id: usize) {
    L_TASKS.with(|t| {
        if let Some(slot) = t.borrow_mut().get_mut(id.wrapping_sub(1)) {
            *slot = None;
        }
    });
    L_FREE.with(|f| f.borrow_mut().push(id));
}

/// `spawn f(args)`: registers the future as an independent task, ready to be
/// polled, and returns the handle that owns it.
fn l_spawn<T: 'static>(future: impl std::future::Future<Output = T> + 'static) -> LTask<T> {
    let slot = std::rc::Rc::new(std::cell::RefCell::new(None));
    let out = slot.clone();
    let record = LRecord {
        future: Some(Box::pin(async move {
            *out.borrow_mut() = Some(future.await);
        })),
        status: L_READY,
        queued: false,
        next: 0,
        prev: 0,
        waiter: 0,
        pending_children: 0,
        timer: None,
    };
    let reused = L_FREE.with(|f| f.borrow_mut().pop());
    let id = L_TASKS.with(|t| {
        let mut tasks = t.borrow_mut();
        match reused {
            Some(id) => {
                tasks[id - 1] = Some(record);
                id
            }
            None => {
                tasks.push(Some(record));
                tasks.len()
            }
        }
    });
    l_push_ready(id);
    LTask { id, slot }
}

/// Suspension that asks to be resumed at once: a yield, not a wait.
struct LYield(bool);
fn l_yield() -> LYield {
    LYield(false)
}
impl std::future::Future for LYield {
    type Output = ();
    fn poll(
        mut self: std::pin::Pin<&mut Self>,
        _cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<()> {
        if self.0 {
            return std::task::Poll::Ready(());
        }
        self.0 = true;
        l_wake(l_current());
        std::task::Poll::Pending
    }
}

fn l_waker() -> std::task::Waker {
    fn nop(_: *const ()) {}
    fn clone(p: *const ()) -> std::task::RawWaker {
        std::task::RawWaker::new(p, &L_VTABLE)
    }
    static L_VTABLE: std::task::RawWakerVTable =
        std::task::RawWakerVTable::new(clone, nop, nop, nop);
    unsafe { std::task::Waker::from_raw(std::task::RawWaker::new(std::ptr::null(), &L_VTABLE)) }
}

/// The scheduler: round-robin over the queue of ready tasks. A task that
/// returns Pending leaves the queue until it is notified, which is what lets
/// the other tasks make progress meanwhile.
fn l_run() {
    let waker = l_waker();
    let mut cx = std::task::Context::from_waker(&waker);
    loop {
        let timer = l_pump_timers();

        let id = l_pop_ready();
        if id == 0 {
            if let Some(delay) = timer {
                std::thread::sleep(delay);
                continue;
            }

            if L_SUSPENDED.with(|c| c.get()) > 0 {
                eprintln!("ELE: tarea suspendida sin notificación (interbloqueo)");
                std::process::abort()
            }
            return;
        }
        let mut future = match l_with(id, |r| r.future.take()).flatten() {
            Some(f) => f,
            None => continue,
        };
        L_CURRENT.with(|c| c.set(id));
        let polled = future.as_mut().poll(&mut cx);
        L_CURRENT.with(|c| c.set(0));
        match polled {
            std::task::Poll::Ready(()) => {
                let waiter = l_with(id, |r| {
                    r.status = L_DONE;
                    r.future = None;
                    std::mem::replace(&mut r.waiter, 0)
                });
                let waiter = waiter.unwrap_or(0);
                let notify = l_with(waiter, |r| {
                    if r.pending_children != 0 {
                        r.pending_children -= 1;
                    }
                    r.pending_children == 0
                });
                if notify == Some(true) {
                    l_wake(waiter);
                }
            }
            std::task::Poll::Pending => {
                let requeued = l_with(id, |r| {
                    r.future = Some(future);
                    if r.queued {
                        return true;
                    }
                    r.status = L_PENDING;
                    false
                });
                if requeued == Some(false) {
                    L_SUSPENDED.with(|c| c.set(c.get() + 1));
                }
            }
        }
    }
}

/// Entry point of a program with an async `main`: the task of `main` is
/// registered in the scheduler and the scheduler runs until no task is ready.
fn l_run_main(future: impl std::future::Future<Output = ()> + 'static) {
    let root = l_spawn(future);
    l_run();
    drop(root);
}
