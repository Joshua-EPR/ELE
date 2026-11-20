import x86_64

// First Linux x86-64 native heap bootstrap, written in ELE.
// Emits mmap/munmap syscalls into an ELF64 program. Requested byte sizes
// are compile-time constants, NOT a general dynamic allocator, Text or List.
// Stage 0 is still used to compile this ELE source during bootstrap.
//
// Linux syscall ABI: rax = number, rdi/rsi/rdx/r10/r8/r9 = arguments.
// mmap returns a pointer or -errno. munmap returns 0 or -errno.
// These routines emit failure exits rather than permitting a failed map
// to be dereferenced or an invalid unmap to pass silently.
const NATIVE_HEAP_PAGE = 4096
const NATIVE_HEAP_MAX = 33554432

// Fail closed for zero/negative inputs or beyond the current 32 MiB bound.
// Rounded allocations are page-aligned, so munmap can reuse this size.
pub fn heapPageRound(bytes: Int) -> Int {
    if bytes <= 0 || bytes > NATIVE_HEAP_MAX { return -1 }
    let rem = bytes % NATIVE_HEAP_PAGE
    if rem == 0 { return bytes }
    return bytes + NATIVE_HEAP_PAGE - rem
}

// Emit checked Linux mmap(NULL, rounded, PROT_READ|WRITE,
// MAP_PRIVATE|MAP_ANONYMOUS, -1, 0). Success leaves mapped address in RAX;
// failure exits process with code 123. The size is fixed at emission time.
pub fn heapEmitCheckedMap(code: &mut X64Code, bytes: Int) -> Bool {
    let rounded = heapPageRound(bytes)
    if rounded < 0 || code.error != 0 { return false }
    x64MovImm64(&mut code, 0, 9)       // sys_mmap
    x64MovImm64(&mut code, 7, 0)       // requested address
    x64MovImm64(&mut code, 6, rounded)
    x64MovImm64(&mut code, 2, 3)       // PROT_READ | PROT_WRITE
    x64MovImm64(&mut code, 10, 34)     // MAP_PRIVATE | MAP_ANONYMOUS
    x64MovImm64(&mut code, 8, -1)      // fd
    x64MovImm64(&mut code, 9, 0)       // offset
    x64Syscall(&mut code)
    // Save the pointer before setcc overwrites EAX. Linux syscall clobbers
    // RCX and R11, but not RBX. All user-space mapped pointers are >= 0.
    x64MovReg(&mut code, 3, 0)
    x64MovImm64(&mut code, 1, 0)
    x64CmpReg(&mut code, 0, 1)
    x64SetCondition(&mut code, 6)     // signed rax < 0 -> error
    x64TestRax(&mut code)
    let success = x64ConditionalPlaceholder(&mut code, true)
    x64MovImm64(&mut code, 7, 123)    // fail closed
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)
    hold patch_offset_49 = code.bytes.length
    x64PatchRelative(&mut code, success, patch_offset_49)
    x64MovReg(&mut code, 0, 3)        // restore pointer to RAX
    return code.error == 0
}

// On entry RDI is the exact pointer from heapEmitCheckedMap. The requested
// size must be the same as for mmap; no ownership tracking exists yet.
// A failed munmap exits with code 124 rather than returning success.
pub fn heapEmitCheckedUnmap(code: &mut X64Code, bytes: Int) -> Bool {
    let rounded = heapPageRound(bytes)
    if rounded < 0 || code.error != 0 { return false }
    x64MovImm64(&mut code, 6, rounded)
    x64MovImm64(&mut code, 0, 11)      // sys_munmap
    x64Syscall(&mut code)
    x64TestRax(&mut code)
    let success = x64ConditionalPlaceholder(&mut code, true)
    x64MovImm64(&mut code, 7, 124)
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)
    hold patch_offset_68 = code.bytes.length
    x64PatchRelative(&mut code, success, patch_offset_68)
    return code.error == 0
}
