import x86_64
import native_heap_dynamic

// Minimal linear owner-slot machine. Each owner occupies three independent
// stack slots: address, raw requested bytes, live flag (0 or 1). These are
// emitted machine-code guards, NOT general Stage 1 move paths or native drops.
// Call heapOwnerInit on every fresh owner before new/move/drop operations.
// Live owners must not be overwritten; moved-from owners become invalid.
//
// Runtime exit statuses: 120 = replace live owner, 121 = use after
// move/drop or double drop, 122 = bad size, 123 = mmap failed, 124 = munmap
// failed. Only Linux x86-64; no GC and no hidden automatic freeing.

fn heapOwnerExit(code: &mut X64Code, status: Int) {
    x64MovImm64(&mut code, 7, status)
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)
}

// RAX = 1 iff exactly live, else exit 121; clobbers RCX and RAX.
fn heapOwnerRequireLive(code: &mut X64Code, slot: Int) {
    x64LoadSlot(&mut code, 0, slot)
    x64MovImm64(&mut code, 1, 1)
    x64CmpReg(&mut code, 0, 1)
    let ok = x64ConditionalPlaceholder(&mut code, true)
    heapOwnerExit(&mut code, 121)
    x64PatchRelative(&mut code, ok, code.bytes.length)
}

// Accept only zero live flag in a destination owner.
fn heapOwnerRequireEmpty(code: &mut X64Code, slot: Int) {
    x64LoadSlot(&mut code, 0, slot)
    x64TestRax(&mut code)
    let ok = x64ConditionalPlaceholder(&mut code, true)
    heapOwnerExit(&mut code, 120)
    x64PatchRelative(&mut code, ok, code.bytes.length)
}

pub fn heapOwnerInit(code: &mut X64Code, ptr: Int, bytes: Int, live: Int) {
    x64MovImm64(&mut code, 0, 0)
    x64StoreSlot(&mut code, ptr, 0)
    x64StoreSlot(&mut code, bytes, 0)
    x64StoreSlot(&mut code, live, 0)
}

// RDI contains raw requested bytes. Creates an owner only when empty.
pub fn heapOwnerNew(code: &mut X64Code, ptr: Int, bytes: Int, live: Int) {
    heapOwnerRequireEmpty(&mut code, live)
    x64StoreSlot(&mut code, bytes, 7)
    heapEmitDynamicMap(&mut code)
    x64StoreSlot(&mut code, ptr, 0)
    x64MovImm64(&mut code, 0, 1)
    x64StoreSlot(&mut code, live, 0)
}

// Exact transfer of one owner. Source invalidated atomically in straight-line
// generated code; destination cannot be overwritten while live. No copying
// of the underlying bytes or pointers to a second live owner is allowed.
pub fn heapOwnerMove(code: &mut X64Code, src_ptr: Int, src_bytes: Int, src_live: Int, dst_ptr: Int, dst_bytes: Int, dst_live: Int) {
    heapOwnerRequireLive(&mut code, src_live)
    heapOwnerRequireEmpty(&mut code, dst_live)
    x64LoadSlot(&mut code, 0, src_ptr)
    x64StoreSlot(&mut code, dst_ptr, 0)
    x64LoadSlot(&mut code, 0, src_bytes)
    x64StoreSlot(&mut code, dst_bytes, 0)
    x64MovImm64(&mut code, 0, 1)
    x64StoreSlot(&mut code, dst_live, 0)
    x64MovImm64(&mut code, 0, 0)
    x64StoreSlot(&mut code, src_live, 0)
    x64StoreSlot(&mut code, src_ptr, 0)
    x64StoreSlot(&mut code, src_bytes, 0)
}

// Abort on double drop and moved-from uses; unmap before invalidation.
// If munmap reports an error, the process terminates without clearing live.
// A successful munmap zeroes pointer, size and live state.
pub fn heapOwnerDrop(code: &mut X64Code, ptr: Int, bytes: Int, live: Int) {
    heapOwnerRequireLive(&mut code, live)
    x64LoadSlot(&mut code, 7, ptr)
    x64LoadSlot(&mut code, 6, bytes)
    heapEmitDynamicUnmap(&mut code)
    x64MovImm64(&mut code, 0, 0)
    x64StoreSlot(&mut code, live, 0)
    x64StoreSlot(&mut code, ptr, 0)
    x64StoreSlot(&mut code, bytes, 0)
}

// Borrow a pointer for immediate native access only while the owner is live.
// Pointer escapes and aliasing are NOT yet tracked by Stage 1.
pub fn heapOwnerPtr(code: &mut X64Code, ptr: Int, live: Int) {
    heapOwnerRequireLive(&mut code, live)
    x64LoadSlot(&mut code, 0, ptr)
}
