//! Win64 platform object. Built once with Stage 0, linked on demand.
#![no_std]

use core::{
    ffi::c_void,
    ptr,
    sync::atomic::{AtomicU64, Ordering},
};

type Handle = *mut c_void;
const UTF8: u32 = 65001;
const INVALID_UTF8: u32 = 8;
const INVALID_UTF16: u32 = 128;
const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const CREATE_ALWAYS: u32 = 2;
const MAX_BINARY_BYTES: i64 = 64 * 1024 * 1024;
const SHARE_READ_WRITE_DELETE: u32 = 7;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const FILE_TYPE_DISK: u32 = 1;
include!("../platform_contract.inc.rs");
static FILE_OPENS: AtomicU64 = AtomicU64::new(0);
static FILE_CLOSES: AtomicU64 = AtomicU64::new(0);
static READ_CALLS: AtomicU64 = AtomicU64::new(0);
static SHORT_READS: AtomicU64 = AtomicU64::new(0);
static OPEN_TICKS: AtomicU64 = AtomicU64::new(0);
static READ_TICKS: AtomicU64 = AtomicU64::new(0);
static UTF8_TICKS: AtomicU64 = AtomicU64::new(0);

unsafe extern "system" {
    fn GetCommandLineW() -> *const u16;
    fn CommandLineToArgvW(command_line: *const u16, argc: *mut i32) -> *mut *const u16;
    fn LocalFree(allocation: Handle) -> Handle;
    fn WideCharToMultiByte(
        code: u32,
        flags: u32,
        wide: *const u16,
        wide_len: i32,
        bytes: *mut u8,
        len: i32,
        default: *const u8,
        used_default: *mut i32,
    ) -> i32;
    fn MultiByteToWideChar(
        code: u32,
        flags: u32,
        bytes: *const u8,
        len: i32,
        wide: *mut u16,
        wide_len: i32,
    ) -> i32;
    fn CreateFileW(
        path: *const u16,
        access: u32,
        share: u32,
        security: Handle,
        disposition: u32,
        flags: u32,
        template: Handle,
    ) -> Handle;
    fn WriteFile(
        handle: Handle,
        data: *const u8,
        bytes: u32,
        count: *mut u32,
        overlapped: Handle,
    ) -> i32;
    fn ReadFile(
        handle: Handle,
        out: *mut u8,
        bytes: u32,
        count: *mut u32,
        overlapped: Handle,
    ) -> i32;
    fn CloseHandle(handle: Handle) -> i32;
    fn GetLastError() -> u32;
    fn GetFileType(handle: Handle) -> u32;
    fn GetFileSizeEx(handle: Handle, size: *mut i64) -> i32;
    fn QueryPerformanceCounter(ticks: *mut i64) -> i32;
    fn QueryPerformanceFrequency(ticks_per_second: *mut i64) -> i32;
    fn l_rt_alloc(bytes: usize) -> *mut u8;
    fn l_rt_realloc(data: *mut u8, bytes: usize) -> *mut u8;
    fn l_rt_free(data: *mut u8);
}

// The output is zero initialized by the caller. A successful nonempty
// result transfers one allocation to the L Text drop implementation.
#[repr(C)]
pub struct TextOut {
    data: *mut u8,
    len: usize,
    capacity: usize,
}

struct Buffer {
    data: *mut u8,
    capacity: usize,
}

impl Buffer {
    fn new() -> Self {
        Self {
            data: ptr::null_mut(),
            capacity: 0,
        }
    }

    fn grow(&mut self, capacity: usize) {
        self.data = unsafe {
            if self.capacity == 0 {
                l_rt_alloc(capacity)
            } else {
                l_rt_realloc(self.data, capacity)
            }
        };
        self.capacity = capacity;
    }

    fn into_text(mut self, len: usize) -> TextOut {
        let text = TextOut {
            data: self.data,
            len,
            capacity: self.capacity,
        };
        self.capacity = 0;
        text
    }
}

impl Drop for Buffer {
    fn drop(&mut self) {
        if self.capacity != 0 {
            unsafe { l_rt_free(self.data) };
        }
    }
}

struct Arguments {
    wide: *mut *const u16,
    count: i32,
}

impl Arguments {
    fn get() -> Option<Self> {
        let mut count = 0;
        let wide = unsafe { CommandLineToArgvW(GetCommandLineW(), &mut count) };
        if wide.is_null() {
            None
        } else {
            Some(Self { wide, count })
        }
    }
}

impl Drop for Arguments {
    fn drop(&mut self) {
        unsafe { LocalFree(self.wide.cast()) };
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn l_platform_arg_count() -> i64 {
    Arguments::get().map_or(-1, |args| i64::from(args.count) - 1)
}

/// `out` points to one writable TextOut provided by the verified backend.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn l_platform_arg(index: i64, out: *mut TextOut) -> i64 {
    let Some(args) = Arguments::get() else {
        return 3;
    };
    let count = i64::from(args.count) - 1;
    if index < 0 || index >= count {
        return 1;
    }
    // argv[0] is the executable. The range was checked against argc.
    let wide = unsafe { *args.wide.add(index as usize + 1) };
    let convert = |bytes, len| unsafe {
        WideCharToMultiByte(
            UTF8,
            INVALID_UTF16,
            wide,
            -1,
            bytes,
            len,
            ptr::null(),
            ptr::null_mut(),
        )
    };
    let size = convert(ptr::null_mut(), 0);
    if size <= 0 {
        return 2;
    }
    if size == 1 {
        return 0;
    }
    let mut buffer = Buffer::new();
    buffer.grow(size as usize);
    if convert(buffer.data, size) != size {
        return 2;
    }
    unsafe { out.write(buffer.into_text((size - 1) as usize)) };
    0
}

struct File {
    handle: Handle,
    trace: bool,
}

impl File {
    fn read(&self, out: *mut u8, len: usize) -> Option<usize> {
        let mut count = 0;
        let ok = unsafe { ReadFile(self.handle, out, len as u32, &mut count, ptr::null_mut()) };
        if self.trace {
            READ_CALLS.fetch_add(1, Ordering::Relaxed);
            if ok != 0 && count > 0 && (count as usize) < len {
                SHORT_READS.fetch_add(1, Ordering::Relaxed);
            }
        }
        (ok != 0 && count as usize <= len).then_some(count as usize)
    }
}

impl Drop for File {
    fn drop(&mut self) {
        if unsafe { CloseHandle(self.handle) } != 0 && self.trace {
            FILE_CLOSES.fetch_add(1, Ordering::Relaxed);
        }
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn l_platform_file_stat(index: i64) -> u64 {
    let counter = match index {
        0 => &FILE_OPENS,
        1 => &FILE_CLOSES,
        2 => &READ_CALLS,
        3 => &SHORT_READS,
        4 => &OPEN_TICKS,
        5 => &READ_TICKS,
        6 => &UTF8_TICKS,
        _ => {
            let mut frequency = 0;
            unsafe { QueryPerformanceFrequency(&mut frequency) };
            return frequency as u64;
        }
    };
    counter.load(Ordering::Relaxed)
}

struct Phase {
    start: i64,
    counter: &'static AtomicU64,
}

impl Phase {
    fn start(trace: bool, counter: &'static AtomicU64) -> Option<Self> {
        let mut start = 0;
        if trace && unsafe { QueryPerformanceCounter(&mut start) } != 0 {
            Some(Self { start, counter })
        } else {
            None
        }
    }
}

impl Drop for Phase {
    fn drop(&mut self) {
        let mut now = 0;
        if unsafe { QueryPerformanceCounter(&mut now) } != 0 && now >= self.start {
            self.counter
                .fetch_add(now.wrapping_sub(self.start) as u64, Ordering::Relaxed);
        }
    }
}

fn open_file(path: *const u8, len: usize, trace: bool) -> Result<File, i64> {
    if len == 0 || len > L_MAX_PATH_BYTES {
        return Err(1);
    }
    let bytes = unsafe { core::slice::from_raw_parts(path, len) };
    if !l_platform_path_valid(bytes) {
        return Err(1);
    }
    let mut wide = Buffer::new();
    wide.grow((len + 1) * 2);
    let dest = wide.data.cast::<u16>();
    let size =
        unsafe { MultiByteToWideChar(UTF8, INVALID_UTF8, path, len as i32, dest, len as i32) };
    if size <= 0 {
        return Err(1);
    }
    unsafe { dest.add(size as usize).write(0) };
    let handle = unsafe {
        CreateFileW(
            dest,
            GENERIC_READ,
            SHARE_READ_WRITE_DELETE,
            ptr::null_mut(),
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            ptr::null_mut(),
        )
    };
    if handle as usize == usize::MAX {
        let error = unsafe { GetLastError() };
        return Err(if matches!(error, 2 | 3) { 2 } else { 3 });
    }
    if trace {
        FILE_OPENS.fetch_add(1, Ordering::Relaxed);
    }
    let file = File { handle, trace };
    if unsafe { GetFileType(handle) } != FILE_TYPE_DISK {
        return Err(3);
    }
    Ok(file)
}

/// The backend lends a valid Text buffer for the call and provides writable
/// TextOut storage. All intermediate resources remain local to this routine.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn l_platform_read_text(
    path: *const u8,
    path_len: usize,
    limit: i64,
    out: *mut TextOut,
    trace: i64,
) -> i64 {
    if !(0..=L_MAX_READ).contains(&limit) {
        return 1;
    }
    let trace = trace != 0;
    let opening = Phase::start(trace, &OPEN_TICKS);
    let file = match open_file(path, path_len, trace) {
        Ok(file) => file,
        Err(code) => return code,
    };
    drop(opening);
    let reading = Phase::start(trace, &READ_TICKS);
    let limit = limit as usize;
    let mut buffer = Buffer::new();
    // Size the buffer once from the file length so typical reads never
    // reallocate. The extra byte lets EOF be observed without a probe. The
    // doubling loop below remains the fallback if the query fails or the
    // file grows while it is being read.
    let mut size = 0i64;
    if unsafe { GetFileSizeEx(file.handle, &mut size) } != 0 && size > 0 {
        let initial = (size as u64).saturating_add(1).min(limit as u64) as usize;
        if initial > 0 {
            buffer.grow(initial);
        }
    }
    let mut len = 0;
    loop {
        if len == buffer.capacity {
            let mut byte = 0;
            match file.read(&mut byte, 1) {
                Some(0) => break,
                Some(_) if len == limit => return 5,
                Some(_) => {
                    let next = (buffer.capacity * 2).max(8192).min(limit);
                    buffer.grow(next);
                    unsafe { buffer.data.add(len).write(byte) };
                    len += 1;
                }
                None => return 3,
            }
        } else {
            let count = (buffer.capacity - len).min(65536);
            match file.read(unsafe { buffer.data.add(len) }, count) {
                Some(0) => break,
                Some(count) => len += count,
                None => return 3,
            }
        }
    }
    drop(reading);
    drop(file);
    if len == 0 {
        return 0;
    }
    let validation = Phase::start(trace, &UTF8_TICKS);
    // Query-only conversion validates UTF-8 without creating a UTF-16 copy.
    if unsafe {
        MultiByteToWideChar(
            UTF8,
            INVALID_UTF8,
            buffer.data,
            len as i32,
            ptr::null_mut(),
            0,
        )
    } == 0
    {
        return 4;
    }
    drop(validation);
    unsafe { out.write(buffer.into_text(len)) };
    0
}

/// Bootstrap Win64 binary writer for ELE's writeBytes(Text, List<Int>).
/// Takes borrowed pointers with layout verified by Stage 1 and the backend.
/// 0=ok; 1=invalid argument/byte, 2=open failure, 3=write/close failure.
/// No file is opened until all byte values have been verified.
#[unsafe(no_mangle)]
pub unsafe extern "system" fn l_platform_write_bytes(
    path: *const u8,
    path_len: usize,
    data: *const i64,
    count: i64,
) -> i64 {
    if count < 0 || count > MAX_BINARY_BYTES || path_len == 0 || path_len > L_MAX_PATH_BYTES {
        return 1;
    }
    if count > 0 && data.is_null() { return 1; }
    let path_bytes = unsafe { core::slice::from_raw_parts(path, path_len) };
    if !l_platform_path_valid(path_bytes) { return 1; }
    for i in 0..count as usize {
        let byte = unsafe { *data.add(i) };
        if !(0..=255).contains(&byte) { return 1; }
    }
    let mut wide = Buffer::new();
    wide.grow((path_len + 1) * 2);
    let dest = wide.data.cast::<u16>();
    let size = unsafe {
        MultiByteToWideChar(UTF8, INVALID_UTF8, path, path_len as i32, dest, path_len as i32)
    };
    if size <= 0 { return 1; }
    unsafe { dest.add(size as usize).write(0) };
    let handle = unsafe {
        CreateFileW(
            dest, GENERIC_WRITE, SHARE_READ_WRITE_DELETE, ptr::null_mut(),
            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, ptr::null_mut(),
        )
    };
    if handle as usize == usize::MAX { return 2; }
    // A 4096-byte stack array emits __chkstk and memset on MSVC. This
    // standalone no_std platform object is linked with /NODEFAULTLIB, so
    // neither CRT helper is available. Use the existing ELE allocator for
    // scratch bytes instead, preserving the same bounded chunked writes.
    let mut chunk = Buffer::new();
    chunk.grow(4096);
    if chunk.data.is_null() {
        unsafe { CloseHandle(handle) };
        return 3;
    }
    let mut error = 0;
    let mut pos = 0usize;
    while pos < count as usize {
        let amount = (count as usize - pos).min(chunk.capacity);
        let mut offset = 0usize;
        while offset < amount {
            // Each source byte was validated before opening the file.
            unsafe { chunk.data.add(offset).write(*data.add(pos + offset) as u8) };
            offset += 1;
        }
        let mut written = 0usize;
        while written < amount {
            let mut done = 0u32;
            let ok = unsafe { WriteFile(
                handle, chunk.data.add(written), (amount - written) as u32,
                &mut done, ptr::null_mut(),
            ) };
            if ok == 0 || done == 0 || done as usize > amount - written {
                error = 3;
                break;
            }
            written += done as usize;
        }
        if error != 0 { break; }
        pos += amount;
    }
    if unsafe { CloseHandle(handle) } == 0 { error = 3; }
    error
}
