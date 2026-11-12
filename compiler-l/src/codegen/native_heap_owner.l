import x86_64
import native_heap_dynamic
import native_heap_resize

// Minimal linear owner-slot machine. Each owner occupies three independent
// stack slots: address, raw requested bytes, live flag (0 or 1). These are
// emitted machine-code guards, NOT general Stage 1 move paths or native drops.
// Call heapOwnerInit on every fresh owner before new/move/drop operations.
// Live owners must not be overwritten; moved-from owners become invalid.
//
// Runtime exit statuses: 120 = replace live owner, 121 = use after
// move/drop or double drop, 122 = bad size, 123 = mmap failed, 124 = munmap
// failed. Only Linux x86-64; no GC and no hidden automatic freeing.

flow heapOwnerExit(code: edit X64Code, status: Int) {
    x64MovImm64(edit code, 7, status)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)
}

// RAX = 1 iff exactly live, else exit 121; clobbers RCX and RAX.
flow heapOwnerRequireLive(code: edit X64Code, slot: Int) {
    x64LoadSlot(edit code, 0, slot)
    x64MovImm64(edit code, 1, 1)
    x64CmpReg(edit code, 0, 1)
    hold ok = x64ConditionalPlaceholder(edit code, true)
    heapOwnerExit(edit code, 121)
    hold after_check = code.bytes.length
    x64PatchRelative(edit code, ok, after_check)
}

// Accept only zero live flag in a destination owner.
flow heapOwnerRequireEmpty(code: edit X64Code, slot: Int) {
    x64LoadSlot(edit code, 0, slot)
    x64TestRax(edit code)
    hold ok = x64ConditionalPlaceholder(edit code, true)
    heapOwnerExit(edit code, 120)
    hold after_check = code.bytes.length
    x64PatchRelative(edit code, ok, after_check)
}

expose flow heapOwnerInit(code: edit X64Code, ptr: Int, bytes: Int, live: Int) {
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, ptr, 0)
    x64StoreSlot(edit code, bytes, 0)
    x64StoreSlot(edit code, live, 0)
}

// RDI contains raw requested bytes. Creates an owner only when empty.
expose flow heapOwnerNew(code: edit X64Code, ptr: Int, bytes: Int, live: Int) {
    heapOwnerRequireEmpty(edit code, live)
    x64StoreSlot(edit code, bytes, 7)
    heapEmitDynamicMap(edit code)
    x64StoreSlot(edit code, ptr, 0)
    x64MovImm64(edit code, 0, 1)
    x64StoreSlot(edit code, live, 0)
}

// Exact transfer of one owner. Source invalidated atomically in straight-line
// generated code; destination cannot be overwritten while live. No copying
// of the underlying bytes or pointers to a second live owner is allowed.
expose flow heapOwnerMove(code: edit X64Code, src_ptr: Int, src_bytes: Int, src_live: Int, dst_ptr: Int, dst_bytes: Int, dst_live: Int) {
    heapOwnerRequireLive(edit code, src_live)
    heapOwnerRequireEmpty(edit code, dst_live)
    x64LoadSlot(edit code, 0, src_ptr)
    x64StoreSlot(edit code, dst_ptr, 0)
    x64LoadSlot(edit code, 0, src_bytes)
    x64StoreSlot(edit code, dst_bytes, 0)
    x64MovImm64(edit code, 0, 1)
    x64StoreSlot(edit code, dst_live, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, src_live, 0)
    x64StoreSlot(edit code, src_ptr, 0)
    x64StoreSlot(edit code, src_bytes, 0)
}

// Abort on double drop and moved-from uses; unmap before invalidation.
// If munmap reports an error, the process terminates without clearing live.
// A successful munmap zeroes pointer, size and live state.
expose flow heapOwnerDrop(code: edit X64Code, ptr: Int, bytes: Int, live: Int) {
    heapOwnerRequireLive(edit code, live)
    x64LoadSlot(edit code, 7, ptr)
    x64LoadSlot(edit code, 6, bytes)
    heapEmitDynamicUnmap(edit code)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, live, 0)
    x64StoreSlot(edit code, ptr, 0)
    x64StoreSlot(edit code, bytes, 0)
}

// Borrow a pointer for immediate native access only while the owner is live.
// Pointer escapes and aliasing are NOT yet tracked by Stage 1.
expose flow heapOwnerPtr(code: edit X64Code, ptr: Int, live: Int) {
    heapOwnerRequireLive(edit code, live)
    x64LoadSlot(edit code, 0, ptr)
}

// Resize a live owner. RDI carries the new raw byte count. The separate
// scratch slot must not alias the owner's three slots. The old owner state
// remains unchanged until Linux mremap succeeds; then the possibly moved
// pointer and the new raw length are both stored. Access after a move is
// still prohibited by heapOwnerRequireLive.
expose flow heapOwnerResize(code: edit X64Code, ptr: Int, bytes: Int, live: Int, scratch: Int) {
    when ptr < 0 || ptr >= 64 || bytes < 0 || bytes >= 64 || live < 0 || live >= 64 || scratch < 0 || scratch >= 64 {
        code.error = 31
        give
    }
    when ptr == bytes || ptr == live || bytes == live || scratch == ptr || scratch == bytes || scratch == live {
        code.error = 31
        give
    }
    heapOwnerRequireLive(edit code, live)
    x64StoreSlot(edit code, scratch, 7)
    x64LoadSlot(edit code, 7, ptr)
    x64LoadSlot(edit code, 6, bytes)
    x64LoadSlot(edit code, 2, scratch)
    heapEmitDynamicResize(edit code)
    x64StoreSlot(edit code, ptr, 0)
    x64LoadSlot(edit code, 0, scratch)
    x64StoreSlot(edit code, bytes, 0)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, scratch, 0)
}
