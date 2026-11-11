import x86_64

// Runtime-sized mmap/munmap emission for ELF64 Linux x86-64. This is a
// bounded allocation primitive, not yet an allocator for ELE's Text/List.
// The caller is responsible for retaining the pointer and the exact original
// request size until unmap; the owner-slot helpers can enforce single drop.
//
// Caller ABI (raw machine registers, NOT a Stage 1 function ABI):
// map: RDI=request bytes; returns RAX=address or exits 122/123.
// unmap: RDI=mapped address, RSI=original bytes; exits 122/124 on error.
// No Rust/C runtime, libc, GC, or linked object is used by emitted ELF code.

pub fn heapDynExit(code: &mut X64Code, status: Int) {
    x64MovImm64(&mut code, 7, status)
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)
}

// Reject signed sizes outside [1,1048576] at runtime, before any syscall.
// Input size is kept unchanged in the specified register (RDI or RSI).
pub fn heapDynSizeGuard(code: &mut X64Code, reg: Int) {
    x64MovImm64(&mut code, 1, 0)
    x64CmpReg(&mut code, reg, 1)
    x64SetCondition(&mut code, 7) // signed <= 0
    x64TestRax(&mut code)
    let good_min = x64ConditionalPlaceholder(&mut code, true)
    heapDynExit(&mut code, 122)
    x64PatchRelative(&mut code, good_min, code.bytes.length)

    x64MovImm64(&mut code, 1, 1048576)
    x64CmpReg(&mut code, reg, 1)
    x64SetCondition(&mut code, 9) // signed > max
    x64TestRax(&mut code)
    let good_max = x64ConditionalPlaceholder(&mut code, true)
    heapDynExit(&mut code, 122)
    x64PatchRelative(&mut code, good_max, code.bytes.length)
}

// Given a validated positive size in RSI, round it up to 4 KiB without
// arithmetic overflow. Bound 1 MiB guarantees size+4095 fits signed Int.
// This new primitive is emitted as AND rsi,-4096 after adding 4095.
pub fn heapDynPageRoundRsi(code: &mut X64Code) {
    x64MovImm64(&mut code, 1, 4095)
    x64AddReg(&mut code, 6, 1)
    x64MovImm64(&mut code, 1, -4096)
    x64AndReg(&mut code, 6, 1)
}

// Same bounded round-up, but for RDX (new size in Linux mremap).
// The size guard must be applied before calling this helper.
pub fn heapDynPageRoundRdx(code: &mut X64Code) {
    x64MovImm64(&mut code, 1, 4095)
    x64AddReg(&mut code, 2, 1)
    x64MovImm64(&mut code, 1, -4096)
    x64AndReg(&mut code, 2, 1)
}

pub fn heapEmitDynamicMap(code: &mut X64Code) -> Bool {
    if code.error != 0 { return false }
    // RDI holds caller's runtime length; RSI holds the rounded syscall length.
    x64MovReg(&mut code, 6, 7)
    heapDynSizeGuard(&mut code, 6)
    heapDynPageRoundRsi(&mut code)
    x64MovImm64(&mut code, 0, 9)   // mmap
    x64MovImm64(&mut code, 7, 0)   // address hint NULL
    x64MovImm64(&mut code, 2, 3)   // PROT_READ | PROT_WRITE
    x64MovImm64(&mut code, 10, 34) // MAP_PRIVATE | MAP_ANONYMOUS
    x64MovImm64(&mut code, 8, -1)  // anonymous fd
    x64MovImm64(&mut code, 9, 0)   // offset
    x64Syscall(&mut code)

    // A Linux syscall destroys RCX and R11, but preserves RDX. Preserve
    // pointer in RDX while setcc overwrites RAX to inspect the signed errno.
    x64MovReg(&mut code, 2, 0)
    x64MovImm64(&mut code, 1, 0)
    x64CmpReg(&mut code, 0, 1)
    x64SetCondition(&mut code, 6) // rax < 0
    x64TestRax(&mut code)
    let success = x64ConditionalPlaceholder(&mut code, true)
    heapDynExit(&mut code, 123)
    x64PatchRelative(&mut code, success, code.bytes.length)
    x64MovReg(&mut code, 0, 2)
    return code.error == 0
}

pub fn heapEmitDynamicUnmap(code: &mut X64Code) -> Bool {
    if code.error != 0 { return false }
    heapDynSizeGuard(&mut code, 6)
    heapDynPageRoundRsi(&mut code)
    x64MovImm64(&mut code, 0, 11)  // munmap
    x64Syscall(&mut code)
    x64TestRax(&mut code)
    let success = x64ConditionalPlaceholder(&mut code, true)
    heapDynExit(&mut code, 124)
    x64PatchRelative(&mut code, success, code.bytes.length)
    return code.error == 0
}
