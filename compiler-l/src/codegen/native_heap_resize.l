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

expose flow heapEmitDynamicResize(code: edit X64Code) => Bool {
    when code.error != 0 { give false }
    heapDynSizeGuard(edit code, 6)
    heapDynSizeGuard(edit code, 2)
    heapDynPageRoundRsi(edit code)
    heapDynPageRoundRdx(edit code)
    x64MovImm64(edit code, 0, 25) // sys_mremap (Linux x86-64)
    x64MovImm64(edit code, 10, 1) // MREMAP_MAYMOVE
    x64Syscall(edit code)
    // Preserve returned pointer across condition setting. Linux syscall
    // clobbers RCX/R11; RDX is safe after the syscall.
    x64MovReg(edit code, 2, 0)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 6) // signed -errno < 0
    x64TestRax(edit code)
    hold success = x64ConditionalPlaceholder(edit code, true)
    heapDynExit(edit code, 125)
    hold end_offset = code.bytes.length
    x64PatchRelative(edit code, success, end_offset)
    x64MovReg(edit code, 0, 2)
    give code.error == 0
}
