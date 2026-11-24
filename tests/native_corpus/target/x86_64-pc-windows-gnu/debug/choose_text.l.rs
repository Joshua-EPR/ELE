#![allow(unused, unused_parens, unconditional_panic)]
struct LText(std::borrow::Cow<'static, str>);
impl std::fmt::Display for LText { fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { f.write_str(self.0.as_ref()) } }
const L_MAX_READ: i64 = 64 * 1024 * 1024;
const L_MAX_PATH_BYTES: usize = 32767 * 4;

fn l_platform_path_valid(bytes: &[u8]) -> bool {
    let slash = |b| b == b'\\' || b == b'/';
    // Keep the standalone Win64 object independent of core's out-of-line memchr.
    let mut has_nul = false;
    for &byte in bytes {
        if byte == 0 {
            has_nul = true;
            break;
        }
    }
    !bytes.is_empty()
        && bytes.len() <= L_MAX_PATH_BYTES
        && !has_nul
        && !matches!(bytes, [a, b, b'.' | b'?', c, ..] if slash(*a) && slash(*b) && slash(*c))
}
fn l_process_arg_count() -> i64 {
    std::env::args_os().skip(1).len() as i64
}

fn l_process_arg(index: i64) -> Result<LText, i64> {
    let index = usize::try_from(index).map_err(|_| 1i64)?;
    let arg = std::env::args_os().skip(1).nth(index).ok_or(1i64)?;
    arg.into_string()
        .map(|s| LText(std::borrow::Cow::Owned(s)))
        .map_err(|_| 2)
}

fn l_print_error(text: &LText) {
    use std::io::Write;
    let _ = writeln!(std::io::stderr().lock(), "{}", text.0);
}

fn l_read_text(path: &LText, limit: i64) -> Result<LText, i64> {
    use std::io::{ErrorKind, Read};
    if !(0..=L_MAX_READ).contains(&limit) || !l_platform_path_valid(path.0.as_bytes()) {
        return Err(1);
    }
    let limit = limit as usize;
    let mut file = std::fs::File::open(path.0.as_ref()).map_err(|e| {
        if e.kind() == ErrorKind::NotFound {
            2i64
        } else {
            3
        }
    })?;
    if !file.metadata().map_err(|_| 3i64)?.is_file() {
        return Err(3);
    }
    let mut bytes = Vec::new();
    let mut chunk = [0; 8192];
    loop {
        let wanted = (limit - bytes.len() + 1).min(chunk.len());
        let count = match file.read(&mut chunk[..wanted]) {
            Ok(0) => break,
            Ok(count) => count,
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return Err(3),
        };
        let needed = bytes.len() + count;
        if needed > limit {
            return Err(5);
        }
        if needed > bytes.capacity() {
            let capacity = (bytes.capacity() * 2).max(8192).max(needed).min(limit);
            bytes.reserve_exact(capacity - bytes.len());
        }
        bytes.extend_from_slice(&chunk[..count]);
    }
    drop(file);
    String::from_utf8(bytes)
        .map(|s| LText(std::borrow::Cow::Owned(s)))
        .map_err(|_| 4)
}

// The first path is the proposed output; the second is an existing source.
// 0 = different (including an absent output), 1 = same, 2 = identity error.
fn l_same_file(path_a: &LText, path_b: &LText) -> i64 {
    if !l_platform_path_valid(path_a.0.as_bytes()) || !l_platform_path_valid(path_b.0.as_bytes()) {
        return 2;
    }
    let Ok(file_b) = std::fs::File::open(path_b.0.as_ref()) else { return 2 };
    let dest = std::path::Path::new(path_a.0.as_ref());
    let file_a = match std::fs::File::open(dest) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // A dangling symlink or absent parent does not prove a safe destination.
            match std::fs::symlink_metadata(dest) {
                Ok(_) => return 2,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(_) => return 2,
            }
            let parent = dest.parent().filter(|p| !p.as_os_str().is_empty())
                .unwrap_or_else(|| std::path::Path::new("."));
            return match std::fs::metadata(parent) {
                Ok(metadata) if metadata.is_dir() => 0,
                _ => 2,
            };
        }
        Err(_) => return 2,
    };
    let (Ok(meta_a), Ok(meta_b)) = (file_a.metadata(), file_b.metadata()) else { return 2 };
    if !meta_a.is_file() || !meta_b.is_file() { return 2; }

    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        #[repr(C)]
        struct FileInfo {
            attributes: u32,
            creation_time: [u32; 2],
            access_time: [u32; 2],
            write_time: [u32; 2],
            volume: u32,
            size_high: u32,
            size_low: u32,
            links: u32,
            index_high: u32,
            index_low: u32,
        }
        unsafe extern "system" {
            fn GetFileInformationByHandle(
                handle: *mut std::ffi::c_void,
                info: *mut FileInfo,
            ) -> i32;
        }
        let mut info_a = std::mem::MaybeUninit::<FileInfo>::uninit();
        let mut info_b = std::mem::MaybeUninit::<FileInfo>::uninit();
        let ok_a = unsafe {
            GetFileInformationByHandle(file_a.as_raw_handle(), info_a.as_mut_ptr())
        };
        let ok_b = unsafe {
            GetFileInformationByHandle(file_b.as_raw_handle(), info_b.as_mut_ptr())
        };
        if ok_a == 0 || ok_b == 0 { return 2; }
        let info_a = unsafe { info_a.assume_init() };
        let info_b = unsafe { info_b.assume_init() };
        i64::from(info_a.volume == info_b.volume
            && info_a.index_high == info_b.index_high
            && info_a.index_low == info_b.index_low)
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        i64::from(meta_a.dev() == meta_b.dev() && meta_a.ino() == meta_b.ino())
    }
    #[cfg(not(any(windows, unix)))]
    {
        2
    }
}

#[cfg(windows)]
fn move_file_atomic(tmp: &std::path::Path, dest: &std::path::Path) -> bool {
    use std::os::windows::ffi::OsStrExt;
    let mut wide_src: Vec<u16> = tmp.as_os_str().encode_wide().collect();
    wide_src.push(0);
    let mut wide_dst: Vec<u16> = dest.as_os_str().encode_wide().collect();
    wide_dst.push(0);
    unsafe extern "system" {
        fn MoveFileExW(existing: *const u16, new_file: *const u16, flags: u32) -> i32;
    }
    unsafe { MoveFileExW(wide_src.as_ptr(), wide_dst.as_ptr(), 1 | 8) != 0 }
}

#[cfg(unix)]
fn move_file_atomic(tmp: &std::path::Path, dest: &std::path::Path) -> bool {
    std::fs::rename(tmp, dest).is_ok()
}

#[cfg(not(any(windows, unix)))]
fn move_file_atomic(tmp: &std::path::Path, dest: &std::path::Path) -> bool {
    std::fs::rename(tmp, dest).is_ok()
}

// Bootstrap implementation of ELE writeBytes(Text, List<Int>) -> Int with Atomic Write & Safe Publish Contract.
// All bytes are validated before creating temporary file.
// 0=ok, 1=bad path/byte/length, 2=cannot create, 3=write failed.
#[cfg(windows)]
fn l_random_nonce() -> Option<[u8; 16]> {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn LoadLibraryExW(path: *const u16, file: *mut std::ffi::c_void, flags: u32) -> *mut std::ffi::c_void;
        fn GetProcAddress(module: *mut std::ffi::c_void, name: *const u8) -> *mut std::ffi::c_void;
        fn FreeLibrary(module: *mut std::ffi::c_void) -> i32;
    }
    type RandomFn = unsafe extern "system" fn(*mut std::ffi::c_void, *mut u8, u32, u32) -> i32;
    let dll = "bcrypt.dll".encode_utf16().chain(std::iter::once(0)).collect::<Vec<_>>();
    let module = unsafe { LoadLibraryExW(dll.as_ptr(), std::ptr::null_mut(), 0x800) };
    if module.is_null() { return None; }
    let proc = unsafe { GetProcAddress(module, b"BCryptGenRandom\0".as_ptr()) };
    if proc.is_null() {
        unsafe { FreeLibrary(module) };
        return None;
    }
    let random: RandomFn = unsafe { std::mem::transmute(proc) };
    let mut nonce = [0u8; 16];
    let status = unsafe { random(std::ptr::null_mut(), nonce.as_mut_ptr(), 16, 2) };
    unsafe { FreeLibrary(module) };
    (status == 0).then_some(nonce)
}

#[cfg(unix)]
fn l_random_nonce() -> Option<[u8; 16]> {
    use std::io::Read;
    let mut nonce = [0u8; 16];
    std::fs::File::open("/dev/urandom").ok()?.read_exact(&mut nonce).ok()?;
    Some(nonce)
}

#[cfg(not(any(windows, unix)))]
fn l_random_nonce() -> Option<[u8; 16]> { None }

fn l_write_bytes(path: &LText, bytes: &[i64]) -> i64 {
    if bytes.len() > 64 * 1024 * 1024 || !l_platform_path_valid(path.0.as_bytes()) {
        return 1;
    }
    let mut out = Vec::with_capacity(bytes.len());
    for byte in bytes {
        if !(0..=255).contains(byte) { return 1; }
        out.push(*byte as u8);
    }
    let dest_path = std::path::Path::new(path.0.as_ref());
    let parent = dest_path.parent().unwrap_or_else(|| std::path::Path::new(""));
    let file_stem = dest_path.file_name().and_then(|s| s.to_str()).unwrap_or("out");
    let mut attempts = 0u8;
    let (mut tmp_file, tmp_path) = loop {
        let nonce = match l_random_nonce() { Some(nonce) => nonce, None => return 2 };
        let suffix = nonce.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        let candidate_name = format!("{file_stem}.tmp.{suffix}");
        let candidate = if parent.as_os_str().is_empty() {
            std::path::PathBuf::from(candidate_name)
        } else {
            parent.join(candidate_name)
        };
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => break (file, candidate),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists && attempts < 15 => {
                attempts += 1;
                continue;
            }
            Err(_) => return 2,
        }
    };
    use std::io::Write;
    if tmp_file.write_all(&out).is_err() {
        drop(tmp_file);
        let _ = std::fs::remove_file(&tmp_path);
        return 3;
    }
    if tmp_file.sync_all().is_err() {
        drop(tmp_file);
        let _ = std::fs::remove_file(&tmp_path);
        return 3;
    }
    drop(tmp_file);

    if !move_file_atomic(&tmp_path, dest_path) {
        let _ = std::fs::remove_file(&tmp_path);
        return 3;
    }
    0
}
fn l_write<T: std::fmt::Display>(out: &mut String, value: &T) { use std::fmt::Write; if write!(out, "{value}").is_err() { panic!("falló formato Text"); } }
fn l_panic(line: usize, column: usize, msg: &str) -> ! { eprintln!("ELE {line}:{column}: {msg}"); std::process::abort() }
struct LRegion(std::cell::RefCell<Vec<LRegionBlock>>);

struct LRegionBlock(*mut u8, std::alloc::Layout);

impl Drop for LRegionBlock {
    fn drop(&mut self) {
        unsafe { std::alloc::dealloc(self.0, self.1) }
    }
}

impl LRegion {
    fn new() -> Self {
        Self(std::cell::RefCell::new(Vec::new()))
    }

    fn allocate(&self, size: usize, align: usize, line: usize, column: usize) -> *mut u8 {
        let layout = std::alloc::Layout::from_size_align(size.max(1), align)
            .unwrap_or_else(|_| l_panic(line, column, "capacidad de List desbordada"));
        let mut blocks = self.0.borrow_mut();
        if blocks.try_reserve(1).is_err() {
            l_panic(line, column, "memoria insuficiente");
        }
        let ptr = unsafe { std::alloc::alloc_zeroed(layout) };
        if ptr.is_null() {
            l_panic(line, column, "memoria insuficiente");
        }
        blocks.push(LRegionBlock(ptr, layout));
        ptr
    }

    fn bytes(&self, n: i64, line: usize, column: usize) -> LBytes {
        if n < 0 {
            l_panic(line, column, "tamaño de buffer negativo");
        }
        LBytes(self.allocate(n as usize, 8, line, column), n as usize)
    }
}

struct LRegionList<'r, T> {
    region: &'r LRegion,
    data: *mut T,
    len: usize,
    cap: usize,
}

impl<'r, T> LRegionList<'r, T> {
    fn new(region: &'r LRegion) -> Self {
        Self {
            region,
            data: std::ptr::NonNull::dangling().as_ptr(),
            len: 0,
            cap: 0,
        }
    }

    fn capacity(&self) -> usize {
        self.cap
    }

    fn reserve(&mut self, n: i64, min: i64, line: usize, column: usize) {
        if n < 0 {
            l_panic(line, column, "reserve con tamaño negativo");
        }
        if n as usize <= self.cap - self.len {
            return;
        }
        let overflow = || l_panic(line, column, "capacidad de List desbordada");
        let need = (self.len as i64).checked_add(n).unwrap_or_else(overflow);
        let cap = need
            .max((self.cap as i64).checked_mul(2).unwrap_or(need))
            .max(min);
        let bytes = cap
            .checked_mul(std::mem::size_of::<T>().max(1) as i64)
            .unwrap_or_else(overflow);
        let data = self
            .region
            .allocate(bytes as usize, std::mem::align_of::<T>(), line, column)
            .cast();
        // The allocation is disjoint. Ownership of the initialized prefix
        // transfers to data. The obsolete bytes are never read or dropped.
        unsafe { std::ptr::copy_nonoverlapping(self.data, data, self.len) };
        self.data = data;
        self.cap = cap as usize;
    }

    fn push(&mut self, value: T, line: usize, column: usize) {
        self.reserve(1, 4, line, column);
        unsafe { self.data.add(self.len).write(value) };
        self.len += 1;
    }

    fn pop(&mut self) -> Option<T> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        Some(unsafe { self.data.add(self.len).read() })
    }
}

impl<T> std::ops::Deref for LRegionList<'_, T> {
    type Target = [T];

    fn deref(&self) -> &[T] {
        unsafe { std::slice::from_raw_parts(self.data, self.len) }
    }
}

impl<T> std::ops::DerefMut for LRegionList<'_, T> {
    fn deref_mut(&mut self) -> &mut [T] {
        unsafe { std::slice::from_raw_parts_mut(self.data, self.len) }
    }
}

impl<T> Drop for LRegionList<'_, T> {
    fn drop(&mut self) {
        // The region outlives this header. It frees storage after element drops.
        unsafe { std::ptr::drop_in_place(std::ptr::slice_from_raw_parts_mut(self.data, self.len)) }
    }
}
const L_MAX_SLEEP_MS: i64 = 922337203685477;
// Reference clock and ordered timer queue. All access occurs in a scheduler turn.
thread_local! {
    static L_TIMERS: std::cell::RefCell<std::collections::BTreeSet<(std::time::Instant, usize)>> =
        const { std::cell::RefCell::new(std::collections::BTreeSet::new()) };
}

fn l_check_sleep(ms: i64, line: usize, col: usize) -> i64 {
    if !(0..=L_MAX_SLEEP_MS).contains(&ms) {
        l_panic(line, col, "duración de sleepMs fuera de rango");
    }
    ms
}

async fn l_sleep(ms: i64) {
    if ms == 0 {
        return;
    }
    let task = l_current();
    let deadline = std::time::Instant::now()
        .checked_add(std::time::Duration::from_millis(ms as u64))
        .unwrap_or_else(|| l_panic(1, 1, "deadline de sleepMs fuera de rango"));
    l_with(task, |r| r.timer = Some(deadline));
    L_TIMERS.with(|timers| timers.borrow_mut().insert((deadline, task)));
    std::future::poll_fn(|_| {
        if l_with(task, |r| r.timer.is_none()) == Some(true) {
            std::task::Poll::Ready(())
        } else {
            std::task::Poll::Pending
        }
    }).await
}

fn l_cancel_timer(task: usize) {
    if let Some(Some(deadline)) = l_with(task, |r| r.timer.take()) {
        L_TIMERS.with(|timers| timers.borrow_mut().remove(&(deadline, task)));
    }
}

fn l_pump_timers() -> Option<std::time::Duration> {
    L_TIMERS.with(|timers| {
        let mut queue = timers.borrow_mut();
        if queue.is_empty() {
            return None;
        }
        let now = std::time::Instant::now();
        while let Some(&(deadline, task)) = queue.first() {
            if let Some(delay) = deadline.checked_duration_since(now)
                && !delay.is_zero()
            {
                return Some(delay);
            }
            queue.pop_first();
            if l_with(task, |r| r.timer.take()) == Some(Some(deadline)) {
                l_wake(task);
            }
        }
        None
    })
}
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
#[derive(Clone, Copy)] struct LBytes(*mut u8, usize);
fn l_bytes_get(b: &LBytes, i: i64, line: usize, column: usize) -> i64 { if i < 0 || i as usize >= b.1 { l_panic(line, column, "índice de buffer fuera de rango") } unsafe { *b.0.add(i as usize) as i64 } }
fn l_bytes_set(b: &LBytes, i: i64, v: i64, line: usize, column: usize) { if i < 0 || i as usize >= b.1 { l_panic(line, column, "índice de buffer fuera de rango") } if !(0..=255).contains(&v) { l_panic(line, column, "valor de byte fuera de rango (0..=255)") } unsafe { *b.0.add(i as usize) = v as u8 } }
fn l_at<T>(s: &[T], i: i64, line: usize, column: usize) -> &T { if i < 0 || i as usize >= s.len() { l_panic(line, column, "índice fuera de rango") } &s[i as usize] }
fn l_at_mut<T>(s: &mut [T], i: i64, line: usize, column: usize) -> &mut T { if i < 0 || i as usize >= s.len() { l_panic(line, column, "índice fuera de rango") } &mut s[i as usize] }
fn l_push<T>(v: &mut Vec<T>, x: T) { if v.len() == v.capacity() { let cap = std::cmp::max(4, v.capacity() * 2); v.reserve_exact(cap - v.len()); } v.push(x) }
fn l_reserve<T>(v: &mut Vec<T>, n: i64, line: usize, column: usize) { if n < 0 { l_panic(line, column, "reserve con tamaño negativo") } let (len, cap) = (v.len() as i64, v.capacity() as i64); if cap - len >= n { return } let need = len.checked_add(n); let double = cap.checked_mul(2); let new = match need { Some(need) => std::cmp::max(need, double.unwrap_or(need)), None => l_panic(line, column, "capacidad de List desbordada") }; if new.checked_mul(std::cmp::max(std::mem::size_of::<T>(), 1) as i64).is_none() { l_panic(line, column, "capacidad de List desbordada") } v.reserve_exact((new - len) as usize); }
fn l_checked(v: Option<i64>, line: usize, column: usize) -> i64 { match v { Some(n) => n, None => { eprintln!("ELE {line}:{column}: overflow entero o división/resto por cero"); std::process::abort() } } }
struct S0 { m0: LText, m1: i64 }
fn f0(v0: i64) -> LText {
match v0 {
0i64 => {
return LText(std::borrow::Cow::Borrowed(""));
}
1i64 => {
return LText(std::borrow::Cow::Borrowed("uno"));
}
-1i64 => {
return LText(std::borrow::Cow::Borrowed("menos"));
}
1000i64 => {
return LText(std::borrow::Cow::Borrowed("mil"));
}
_ => {
return LText(std::borrow::Cow::Borrowed("otro"));
}
};
}
fn f1(v0: &LText) -> i64 {
match (*v0) {
ref l_p0 if l_p0.0.as_ref() == "" => {
return 0i64;
}
ref l_p1 if l_p1.0.as_ref() == "uno" => {
return 1i64;
}
ref l_p2 if l_p2.0.as_ref() == "unos" => {
return 2i64;
}
ref l_p3 if l_p3.0.as_ref() == "café" => {
return 3i64;
}
ref l_p4 if l_p4.0.as_ref() == "{x}" => {
return 4i64;
}
ref l_p5 if l_p5.0.as_ref() == "a\"b" => {
return 5i64;
}
_ => {
return 9i64;
}
};
}
fn f2() -> i64 {
let mut v0: i64 = 0i64;
{ let l_start: i64 = l_checked((1i64).checked_neg(), 33, 18); let l_end: i64 = 3i64; for v1 in l_start..l_end {
match f0(v1) {
ref l_p0 if l_p0.0.as_ref() == "uno" => {
v0 = l_checked((v0).checked_add(10i64), 35, 30);
}
ref l_p1 if l_p1.0.as_ref() == "menos" => {
v0 = l_checked((v0).checked_add(100i64), 36, 32);
}
ref l_p2 if l_p2.0.as_ref() == "" => {
v0 = l_checked((v0).checked_add(1000i64), 37, 27);
}
_ => {
v0 = l_checked((v0).checked_add(1i64), 38, 26);
}
};
} }
let v2: LText = f0(1000i64);
let v3: S0 = S0 { m0: LText(std::borrow::Cow::Borrowed("café")), m1: 2i64 };
match (v3).m0 {
ref l_p3 if l_p3.0.as_ref() == "café" => {
v0 = l_checked((v0).checked_add(20000i64), 44, 27);
}
_ => {
}
};
let v4: LText = LText(std::borrow::Cow::Borrowed(""));
let v5: LText = LText(std::borrow::Cow::Borrowed("uno"));
let v6: LText = LText(std::borrow::Cow::Borrowed("unos"));
let v7: LText = LText(std::borrow::Cow::Borrowed("café"));
let v8: LText = LText(std::borrow::Cow::Borrowed("{x}"));
let v9: LText = LText(std::borrow::Cow::Borrowed("a\"b"));
let v10: LText = LText(std::borrow::Cow::Borrowed("un"));
println!("{}", { let mut l_text = String::with_capacity(6);
l_text.push_str("");
l_write(&mut l_text, &({ f1(&v4) }));
l_text.push_str(" ");
l_write(&mut l_text, &({ f1(&v5) }));
l_text.push_str(" ");
l_write(&mut l_text, &({ f1(&v6) }));
l_text.push_str(" ");
l_write(&mut l_text, &({ f1(&v7) }));
l_text.push_str(" ");
l_write(&mut l_text, &({ f1(&v8) }));
l_text.push_str(" ");
l_write(&mut l_text, &({ f1(&v9) }));
l_text.push_str(" ");
l_write(&mut l_text, &({ f1(&v10) }));
l_text.push_str("");
LText(std::borrow::Cow::Owned(l_text)) });
let v11: bool = (((v3).m1) > (1i64));
match v11 {
false => {
v0 = l_checked((v0).checked_add(7i64), 57, 26);
}
true => {
v0 = l_checked((v0).checked_add(300000i64), 58, 25);
}
};
println!("{}", { let mut l_text = String::with_capacity(2);
l_text.push_str("");
l_write(&mut l_text, &(v2));
l_text.push_str(" ");
l_write(&mut l_text, &((v3).m0));
l_text.push_str(" ");
l_write(&mut l_text, &(v0));
l_text.push_str("");
LText(std::borrow::Cow::Owned(l_text)) });
return l_checked((v0).checked_rem(100i64), 61, 10);
}
fn main() -> std::process::ExitCode { std::process::ExitCode::from(u8::try_from(f2()).unwrap_or(255)) }
