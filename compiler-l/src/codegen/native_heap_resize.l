import x86_64
import native_heap_dynamic

// Linux mremap(MREMAP_MAYMOVE) for runtime-sized ELE heap allocations.
// ABI: RDI=owned mmap address, RSI=old raw request, RDX=new raw request.
// Returns RAX=new address (may differ) or exits with:
// 122 (bad size) / 125 (kernel mremap error).
//
// The caller MUST replace the owner pointer and raw size together after
// success and MUST NOT retain a pointer to the old mapping. A failed mremap
// does not invalidate the original mapping, but this bootstrap fail-closes
// by exiting rather than exposing a partly updated allocation.

pub fn heapEmitDynamicResize(code: &mut X64Code) -> Bool {
    if code.error != 0 { return false }
    heapDynSizeGuard(&mut code, 6)
    heapDynSizeGuard(&mut code, 2)
    heapDynPageRoundRsi(&mut code)
    heapDynPageRoundRdx(&mut code)
    x64MovImm64(&mut code, 0, 25) // sys_mremap (Linux x86-64)
    x64MovImm64(&mut code, 10, 1) // MREMAP_MAYMOVE
    x64Syscall(&mut code)
    // Preserve returned pointer across condition setting. Linux syscall
    // clobbers RCX/R11; RDX is safe after the syscall.
    x64MovReg(&mut code, 2, 0)
    x64MovImm64(&mut code, 1, 0)
    x64CmpReg(&mut code, 0, 1)
    x64SetCondition(&mut code, 6) // signed -errno < 0
    x64TestRax(&mut code)
    let success = x64ConditionalPlaceholder(&mut code, true)
    heapDynExit(&mut code, 125)
    x64PatchRelative(&mut code, success, code.bytes.length)
    x64MovReg(&mut code, 0, 2)
    return code.error == 0
}
