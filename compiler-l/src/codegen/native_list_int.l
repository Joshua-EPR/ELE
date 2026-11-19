take x86_64
take native_heap_owner

// Experimental, bounded native List<Int> buffer layout for Linux ELF64.
// Ownership is explicit in stack slots, NOT yet a Stage 1 List lowering.
// ptr/bytes/live own the allocation, len counts initialized Int elements,
// cap is the capacity in 8-byte words. Two scratch slots are unique.
// Elements are Copy-only Int; no nested resources or GC.
expose shape NativeIntListSlots {
    ptr: Int
    bytes: Int
    live: Int
    len: Int
    cap: Int
    resize_scratch: Int
    cap_scratch: Int
}

flow nativeListSlotsValid(s: view NativeIntListSlots) => Bool {
    change values: List of[Int] = List[]
    values@push(s.ptr)
    values@push(s.bytes)
    values@push(s.live)
    values@push(s.len)
    values@push(s.cap)
    values@push(s.resize_scratch)
    values@push(s.cap_scratch)
    each i among 0..values.length {
        when values[i] < 0 || values[i] >= 64 { give false }
        each j among 0..i {
            when values[i] == values[j] { give false }
        }
    }
    give true
}

flow nativeListExit(code: edit X64Code, status: Int) {
    x64MovImm64(edit code, 7, status)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)
}

// The comparison helpers emit 0 for valid, 1 for a violation in RAX.
flow nativeListRejectFlag(code: edit X64Code) {
    x64TestRax(edit code)
    hold sane = x64ConditionalPlaceholder(edit code, true)
    nativeListExit(edit code, 127)
    hold sane_target = code.bytes.length
    x64PatchRelative(edit code, sane, sane_target)
}

// Guard the *whole* list metadata on every read/write/pop. In particular,
// length must not be negative, capacity must not exceed the bounded heap,
// and capacity*8 must match the actual owner allocation. A corrupted cap
// must never make an index look valid beyond the physical mapped bytes.
flow nativeListGuard(code: edit X64Code, s: view NativeIntListSlots) {
    heapOwnerPtr(edit code, s.ptr, s.live)
    x64LoadSlot(edit code, 0, s.len)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 6) // len < 0
    nativeListRejectFlag(edit code)

    x64LoadSlot(edit code, 0, s.cap)
    x64MovImm64(edit code, 1, 1)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 6) // cap < 1
    nativeListRejectFlag(edit code)

    x64LoadSlot(edit code, 0, s.cap)
    x64MovImm64(edit code, 1, 131072)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 8) // cap > maximum
    nativeListRejectFlag(edit code)

    x64LoadSlot(edit code, 0, s.len)
    x64LoadSlot(edit code, 1, s.cap)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 8) // len > cap
    nativeListRejectFlag(edit code)

    x64LoadSlot(edit code, 0, s.cap)
    x64MovImm64(edit code, 1, 8)
    x64MulReg(edit code, 0, 1)
    x64LoadSlot(edit code, 1, s.bytes)
    x64CmpReg(edit code, 0, 1)
    hold equal = x64ConditionalPlaceholder(edit code, true)
    nativeListExit(edit code, 127)
    hold equal_target = code.bytes.length
    x64PatchRelative(edit code, equal, equal_target)
}

// Initialize empty list with fixed initial capacity, 1..131072 Ints.
expose flow nativeListInit(code: edit X64Code, s: view NativeIntListSlots, initial: Int) {
    when !nativeListSlotsValid(s) || initial < 1 || initial > 131072 {
        code.error = 41
        give
    }
    heapOwnerInit(edit code, s.ptr, s.bytes, s.live)
    x64MovImm64(edit code, 7, initial * 8)
    heapOwnerNew(edit code, s.ptr, s.bytes, s.live)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, s.len, 0)
    x64MovImm64(edit code, 0, initial)
    x64StoreSlot(edit code, s.cap, 0)
}

// Emit append of a constant Int. At runtime, first check len <= cap.
// If full, double capacity (up to 1MiB) with checked owner mremap.
// Never write to [ptr + len*8] unless capacity has been secured.
expose flow nativeListPush(code: edit X64Code, s: view NativeIntListSlots, value: Int) {
    when code.error != 0 { give }
    nativeListGuard(edit code, s)

    x64LoadSlot(edit code, 0, s.len)
    x64LoadSlot(edit code, 1, s.cap)
    x64CmpReg(edit code, 0, 1)
    hold has_capacity = x64ConditionalPlaceholder(edit code, false)
    x64LoadSlot(edit code, 0, s.cap)
    x64MovImm64(edit code, 1, 2)
    x64MulReg(edit code, 0, 1)
    x64StoreSlot(edit code, s.cap_scratch, 0)
    x64MovImm64(edit code, 1, 131072)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 8)
    x64TestRax(edit code)
    hold grow_ok = x64ConditionalPlaceholder(edit code, true)
    nativeListExit(edit code, 122)
    hold grow_ok_target = code.bytes.length
    x64PatchRelative(edit code, grow_ok, grow_ok_target)
    x64LoadSlot(edit code, 7, s.cap_scratch)
    x64MovImm64(edit code, 1, 8)
    x64MulReg(edit code, 7, 1)
    heapOwnerResize(edit code, s.ptr, s.bytes, s.live, s.resize_scratch)
    x64LoadSlot(edit code, 0, s.cap_scratch)
    x64StoreSlot(edit code, s.cap, 0)
    hold has_capacity_target = code.bytes.length
    x64PatchRelative(edit code, has_capacity, has_capacity_target)

    heapOwnerPtr(edit code, s.ptr, s.live)
    x64LoadSlot(edit code, 1, s.len)
    x64MovImm64(edit code, 2, 8)
    x64MulReg(edit code, 1, 2)
    x64AddReg(edit code, 0, 1)
    x64MovImm64(edit code, 2, value)
    x64StoreMem64(edit code, 0, 0, 2)
    x64LoadSlot(edit code, 0, s.len)
    x64MovImm64(edit code, 1, 1)
    x64AddReg(edit code, 0, 1)
    x64StoreSlot(edit code, s.len, 0)
}

// Return element at a constant index in RAX; exit 127 on out-of-bounds.
expose flow nativeListRead(code: edit X64Code, s: view NativeIntListSlots, index: Int) {
    when index < 0 || index >= 131072 { code.error = 42; give }
    nativeListGuard(edit code, s)
    x64MovImm64(edit code, 1, index)
    x64LoadSlot(edit code, 2, s.len)
    x64CmpReg(edit code, 1, 2)
    x64SetCondition(edit code, 9) // index >= len
    x64TestRax(edit code)
    hold valid = x64ConditionalPlaceholder(edit code, true)
    nativeListExit(edit code, 127)
    hold valid_target = code.bytes.length
    x64PatchRelative(edit code, valid, valid_target)
    heapOwnerPtr(edit code, s.ptr, s.live)
    x64MovImm64(edit code, 1, index * 8)
    x64AddReg(edit code, 0, 1)
    x64LoadMem64(edit code, 0, 0, 0)
}

// Remove the last initialized Int and return its value in RAX.
expose flow nativeListPop(code: edit X64Code, s: view NativeIntListSlots) {
    nativeListGuard(edit code, s)
    x64LoadSlot(edit code, 0, s.len)
    x64TestRax(edit code)
    hold valid = x64ConditionalPlaceholder(edit code, false)
    nativeListExit(edit code, 127)
    hold valid_target = code.bytes.length
    x64PatchRelative(edit code, valid, valid_target)
    x64LoadSlot(edit code, 1, s.len)
    x64MovImm64(edit code, 2, 1)
    x64SubReg(edit code, 1, 2)
    x64StoreSlot(edit code, s.len, 1)
    heapOwnerPtr(edit code, s.ptr, s.live)
    x64LoadSlot(edit code, 1, s.len)
    x64MovImm64(edit code, 2, 8)
    x64MulReg(edit code, 1, 2)
    x64AddReg(edit code, 0, 1)
    x64LoadMem64(edit code, 0, 0, 0)
}

expose flow nativeListDrop(code: edit X64Code, s: view NativeIntListSlots) {
    nativeListGuard(edit code, s)
    heapOwnerDrop(edit code, s.ptr, s.bytes, s.live)
    x64MovImm64(edit code, 0, 0)
    x64StoreSlot(edit code, s.len, 0)
    x64StoreSlot(edit code, s.cap, 0)
}
