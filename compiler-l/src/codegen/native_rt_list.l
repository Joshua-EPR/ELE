import x86_64

// Runtime of `List of[T]` for the ELE-written Linux x86-64 backend: one
// routine that grows a list buffer. Machine code produced through the ELE
// encoder; no libc, no Rust.
//
// A list header is three words: buffer address, length and capacity, both
// in elements. Capacity 0 means that no buffer exists yet. A buffer of
// capacity C and element size S occupies pages(C * S) bytes of an anonymous
// private mapping, so its byte size is recomputed from the header whenever
// it grows (mremap) or is released (munmap, in the drop glue).
//
// The capacity policy is the one of Stage 0, so `capacity` prints the same
// numbers: when the spare capacity is smaller than the request, the new
// capacity is max(length + request, 2 * capacity, minimum).
//
// Exit status 123: negative or oversized request, or the kernel refused the
// memory. The header is only updated after the mapping succeeded.

// Indexes into the runtime address list of the CFG lowering, after the nine
// routines of native_rt. Drop glue of type code `ty` is rtGlueBase() + ty - 2.
expose flow rtListReserve() => Int { give 9 }
expose flow rtGlueBase() => Int { give 10 }

// Largest capacity in elements. With elements of at most 512 bytes every
// byte size stays far below the Int range.
expose flow rtListLimit() => Int { give 4294967296 }

flow rtListExit(code: edit X64Code, status: Int) {
    x64MovImm64(edit code, 7, status)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)
}

// Leaves with 123 when the signed comparison `RAX <condition> RCX` holds.
// Conditions as in x64SetCondition (6 lt, 8 gt). Clobbers RAX.
flow rtListFailIf(code: edit X64Code, condition: Int) {
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, condition)
    x64TestRax(edit code)
    hold ok = x64ConditionalPlaceholder(edit code, true)
    rtListExit(edit code, 123)
    hold patch_offset_43 = code.bytes.length
    x64PatchRelative(edit code, ok, patch_offset_43)
}

// slot = max(slot, RAX), signed. Clobbers RAX, RCX and R9.
expose flow rtListMaxSlot(code: edit X64Code, slot: Int) {
    x64MovReg(edit code, 9, 0)
    x64LoadSlot(edit code, 1, slot)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 8)
    x64TestRax(edit code)
    hold keep = x64ConditionalPlaceholder(edit code, true)
    x64StoreSlot(edit code, slot, 9)
    hold patch_offset_55 = code.bytes.length
    x64PatchRelative(edit code, keep, patch_offset_55)
}

// RAX = pages(RAX * RCX): the byte size of a buffer, a multiple of 4096.
expose flow rtListBytes(code: edit X64Code) {
    x64MulReg(edit code, 0, 1)
    x64MovImm64(edit code, 10, 4095)
    x64AddReg(edit code, 0, 10)
    x64MovImm64(edit code, 10, -4096)
    x64AndReg(edit code, 0, 10)
}

// list_reserve(RDI = header address, RSI = extra elements wanted,
// RDX = element size, RCX = minimum capacity when it grows).
// Slots: 0 header, 1 element size, 2 minimum, 3 new capacity, 4 new bytes.
expose flow rtEmitListReserve(code: edit X64Code) {
    x64FrameBegin(edit code, 6)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 2)
    x64StoreSlot(edit code, 2, 1)
    // 0 <= request <= limit.
    x64MovReg(edit code, 0, 6)
    x64MovImm64(edit code, 1, 0)
    rtListFailIf(edit code, 6)
    x64MovReg(edit code, 0, 6)
    x64MovImm64(edit code, 1, rtListLimit())
    rtListFailIf(edit code, 8)
    // needed = length + request.
    x64LoadMem64(edit code, 0, 7, 8)
    x64AddReg(edit code, 0, 6)
    x64StoreSlot(edit code, 3, 0)
    // Enough capacity already: nothing to do.
    x64LoadMem64(edit code, 1, 7, 16)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 8)
    x64TestRax(edit code)
    hold grow = x64ConditionalPlaceholder(edit code, false)
    x64FrameEnd(edit code)
    hold patch_offset_93 = code.bytes.length
    x64PatchRelative(edit code, grow, patch_offset_93)
    // new capacity = max(needed, 2 * capacity, minimum) <= limit.
    x64LoadSlot(edit code, 7, 0)
    x64LoadMem64(edit code, 0, 7, 16)
    x64AddReg(edit code, 0, 0)
    rtListMaxSlot(edit code, 3)
    x64LoadSlot(edit code, 0, 2)
    rtListMaxSlot(edit code, 3)
    x64LoadSlot(edit code, 0, 3)
    x64MovImm64(edit code, 1, rtListLimit())
    rtListFailIf(edit code, 8)
    // new bytes = pages(new capacity * element size).
    x64LoadSlot(edit code, 0, 3)
    x64LoadSlot(edit code, 1, 1)
    rtListBytes(edit code)
    x64StoreSlot(edit code, 4, 0)
    x64LoadSlot(edit code, 7, 0)
    x64LoadMem64(edit code, 0, 7, 16)
    x64TestRax(edit code)
    hold fresh = x64ConditionalPlaceholder(edit code, true)
    // mremap(buffer, old bytes, new bytes, MAYMOVE)
    x64LoadSlot(edit code, 1, 1)
    rtListBytes(edit code)
    x64MovReg(edit code, 6, 0)
    x64LoadSlot(edit code, 2, 4)
    x64LoadMem64(edit code, 7, 7, 0)
    x64MovImm64(edit code, 10, 1)
    x64MovImm64(edit code, 0, 25)
    x64Syscall(edit code)
    hold mapped = x64JumpPlaceholder(edit code)
    hold patch_offset_123 = code.bytes.length
    x64PatchRelative(edit code, fresh, patch_offset_123)
    // mmap(0, new bytes, READ|WRITE, PRIVATE|ANONYMOUS, -1, 0)
    x64LoadSlot(edit code, 6, 4)
    x64MovImm64(edit code, 7, 0)
    x64MovImm64(edit code, 2, 3)
    x64MovImm64(edit code, 10, 34)
    x64MovImm64(edit code, 8, -1)
    x64MovImm64(edit code, 9, 0)
    x64MovImm64(edit code, 0, 9)
    x64Syscall(edit code)
    hold patch_offset_133 = code.bytes.length
    x64PatchRelative(edit code, mapped, patch_offset_133)
    // Linux reports a failed call as a negative result.
    x64MovReg(edit code, 8, 0)
    x64MovImm64(edit code, 1, 0)
    rtListFailIf(edit code, 6)
    // Publish the buffer and the capacity; the length is unchanged.
    x64LoadSlot(edit code, 7, 0)
    x64StoreMem64(edit code, 7, 0, 8)
    x64LoadSlot(edit code, 0, 3)
    x64StoreMem64(edit code, 7, 16, 0)
    x64FrameEnd(edit code)
}
