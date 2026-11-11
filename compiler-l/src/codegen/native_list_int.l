import x86_64
import native_heap_owner

// Experimental, bounded native List<Int> buffer layout for Linux ELF64.
// Ownership is explicit in stack slots, NOT yet a Stage 1 List lowering.
// ptr/bytes/live own the allocation, len counts initialized Int elements,
// cap is the capacity in 8-byte words. Two scratch slots are unique.
// Elements are Copy-only Int; no nested resources or GC.
pub struct NativeIntListSlots {
    ptr: Int
    bytes: Int
    live: Int
    len: Int
    cap: Int
    resize_scratch: Int
    cap_scratch: Int
}

fn nativeListSlotsValid(s: &NativeIntListSlots) -> Bool {
    var values: List<Int> = List[]
    values.push(s.ptr)
    values.push(s.bytes)
    values.push(s.live)
    values.push(s.len)
    values.push(s.cap)
    values.push(s.resize_scratch)
    values.push(s.cap_scratch)
    for i in 0..values.length {
        if values[i] < 0 || values[i] >= 64 { return false }
        for j in 0..i {
            if values[i] == values[j] { return false }
        }
    }
    return true
}

fn nativeListExit(code: &mut X64Code, status: Int) {
    x64MovImm64(&mut code, 7, status)
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)
}

// The comparison helpers emit 0 for valid, 1 for a violation in RAX.
fn nativeListRejectFlag(code: &mut X64Code) {
    x64TestRax(&mut code)
    let sane = x64ConditionalPlaceholder(&mut code, true)
    nativeListExit(&mut code, 127)
    x64PatchRelative(&mut code, sane, code.bytes.length)
}

// Guard the *whole* list metadata on every read/write/pop. In particular,
// length must not be negative, capacity must not exceed the bounded heap,
// and capacity*8 must match the actual owner allocation. A corrupted cap
// must never make an index look valid beyond the physical mapped bytes.
fn nativeListGuard(code: &mut X64Code, s: &NativeIntListSlots) {
    heapOwnerPtr(&mut code, s.ptr, s.live)
    x64LoadSlot(&mut code, 0, s.len)
    x64MovImm64(&mut code, 1, 0)
    x64CmpReg(&mut code, 0, 1)
    x64SetCondition(&mut code, 6) // len < 0
    nativeListRejectFlag(&mut code)

    x64LoadSlot(&mut code, 0, s.cap)
    x64MovImm64(&mut code, 1, 1)
    x64CmpReg(&mut code, 0, 1)
    x64SetCondition(&mut code, 6) // cap < 1
    nativeListRejectFlag(&mut code)

    x64LoadSlot(&mut code, 0, s.cap)
    x64MovImm64(&mut code, 1, 131072)
    x64CmpReg(&mut code, 0, 1)
    x64SetCondition(&mut code, 8) // cap > maximum
    nativeListRejectFlag(&mut code)

    x64LoadSlot(&mut code, 0, s.len)
    x64LoadSlot(&mut code, 1, s.cap)
    x64CmpReg(&mut code, 0, 1)
    x64SetCondition(&mut code, 8) // len > cap
    nativeListRejectFlag(&mut code)

    x64LoadSlot(&mut code, 0, s.cap)
    x64MovImm64(&mut code, 1, 8)
    x64MulReg(&mut code, 0, 1)
    x64LoadSlot(&mut code, 1, s.bytes)
    x64CmpReg(&mut code, 0, 1)
    let equal = x64ConditionalPlaceholder(&mut code, true)
    nativeListExit(&mut code, 127)
    x64PatchRelative(&mut code, equal, code.bytes.length)
}

// Initialize empty list with fixed initial capacity, 1..131072 Ints.
pub fn nativeListInit(code: &mut X64Code, s: &NativeIntListSlots, initial: Int) {
    if !nativeListSlotsValid(s) || initial < 1 || initial > 131072 {
        code.error = 41
        return
    }
    heapOwnerInit(&mut code, s.ptr, s.bytes, s.live)
    x64MovImm64(&mut code, 7, initial * 8)
    heapOwnerNew(&mut code, s.ptr, s.bytes, s.live)
    x64MovImm64(&mut code, 0, 0)
    x64StoreSlot(&mut code, s.len, 0)
    x64MovImm64(&mut code, 0, initial)
    x64StoreSlot(&mut code, s.cap, 0)
}

// Emit append of a constant Int. At runtime, first check len <= cap.
// If full, double capacity (up to 1MiB) with checked owner mremap.
// Never write to [ptr + len*8] unless capacity has been secured.
pub fn nativeListPush(code: &mut X64Code, s: &NativeIntListSlots, value: Int) {
    if code.error != 0 { return }
    nativeListGuard(&mut code, s)

    x64LoadSlot(&mut code, 0, s.len)
    x64LoadSlot(&mut code, 1, s.cap)
    x64CmpReg(&mut code, 0, 1)
    let has_capacity = x64ConditionalPlaceholder(&mut code, false)
    x64LoadSlot(&mut code, 0, s.cap)
    x64MovImm64(&mut code, 1, 2)
    x64MulReg(&mut code, 0, 1)
    x64StoreSlot(&mut code, s.cap_scratch, 0)
    x64MovImm64(&mut code, 1, 131072)
    x64CmpReg(&mut code, 0, 1)
    x64SetCondition(&mut code, 8)
    x64TestRax(&mut code)
    let grow_ok = x64ConditionalPlaceholder(&mut code, true)
    nativeListExit(&mut code, 122)
    x64PatchRelative(&mut code, grow_ok, code.bytes.length)
    x64LoadSlot(&mut code, 7, s.cap_scratch)
    x64MovImm64(&mut code, 1, 8)
    x64MulReg(&mut code, 7, 1)
    heapOwnerResize(&mut code, s.ptr, s.bytes, s.live, s.resize_scratch)
    x64LoadSlot(&mut code, 0, s.cap_scratch)
    x64StoreSlot(&mut code, s.cap, 0)
    x64PatchRelative(&mut code, has_capacity, code.bytes.length)

    heapOwnerPtr(&mut code, s.ptr, s.live)
    x64LoadSlot(&mut code, 1, s.len)
    x64MovImm64(&mut code, 2, 8)
    x64MulReg(&mut code, 1, 2)
    x64AddReg(&mut code, 0, 1)
    x64MovImm64(&mut code, 2, value)
    x64StoreMem64(&mut code, 0, 0, 2)
    x64LoadSlot(&mut code, 0, s.len)
    x64MovImm64(&mut code, 1, 1)
    x64AddReg(&mut code, 0, 1)
    x64StoreSlot(&mut code, s.len, 0)
}

// Return element at a constant index in RAX; exit 127 on out-of-bounds.
pub fn nativeListRead(code: &mut X64Code, s: &NativeIntListSlots, index: Int) {
    if index < 0 || index >= 131072 { code.error = 42; return }
    nativeListGuard(&mut code, s)
    x64MovImm64(&mut code, 1, index)
    x64LoadSlot(&mut code, 2, s.len)
    x64CmpReg(&mut code, 1, 2)
    x64SetCondition(&mut code, 9) // index >= len
    x64TestRax(&mut code)
    let valid = x64ConditionalPlaceholder(&mut code, true)
    nativeListExit(&mut code, 127)
    x64PatchRelative(&mut code, valid, code.bytes.length)
    heapOwnerPtr(&mut code, s.ptr, s.live)
    x64MovImm64(&mut code, 1, index * 8)
    x64AddReg(&mut code, 0, 1)
    x64LoadMem64(&mut code, 0, 0, 0)
}

// Remove the last initialized Int and return its value in RAX.
pub fn nativeListPop(code: &mut X64Code, s: &NativeIntListSlots) {
    nativeListGuard(&mut code, s)
    x64LoadSlot(&mut code, 0, s.len)
    x64TestRax(&mut code)
    let valid = x64ConditionalPlaceholder(&mut code, false)
    nativeListExit(&mut code, 127)
    x64PatchRelative(&mut code, valid, code.bytes.length)
    x64LoadSlot(&mut code, 1, s.len)
    x64MovImm64(&mut code, 2, 1)
    x64SubReg(&mut code, 1, 2)
    x64StoreSlot(&mut code, s.len, 1)
    heapOwnerPtr(&mut code, s.ptr, s.live)
    x64LoadSlot(&mut code, 1, s.len)
    x64MovImm64(&mut code, 2, 8)
    x64MulReg(&mut code, 1, 2)
    x64AddReg(&mut code, 0, 1)
    x64LoadMem64(&mut code, 0, 0, 0)
}

pub fn nativeListDrop(code: &mut X64Code, s: &NativeIntListSlots) {
    nativeListGuard(&mut code, s)
    heapOwnerDrop(&mut code, s.ptr, s.bytes, s.live)
    x64MovImm64(&mut code, 0, 0)
    x64StoreSlot(&mut code, s.len, 0)
    x64StoreSlot(&mut code, s.cap, 0)
}
