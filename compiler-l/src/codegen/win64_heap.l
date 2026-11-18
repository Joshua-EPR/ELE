take x86_64
take pe64
take win64_rt
take native_rt
take native_rt_list

// Heap runtime of the ELE-written backend for Windows x64 (PE32+): owned
// Text and `List of[T]` buffers on KERNEL32 VirtualAlloc/VirtualFree. It
// provides the same nine entries as native_rt's rtEmitAll plus
// native_rt_list's list_reserve, with the same contracts, so the CFG
// lowering emits identical calls for both targets.
//
// Why VirtualAlloc and not HeapAlloc: it is the counterpart of the
// anonymous mmap the Linux runtime uses. Buffers are whole pages, start
// zero-filled and are independent mappings with no allocator state shared
// between them; VirtualFree(MEM_RELEASE) checks the address it gets and
// fails on anything that is not the base of a live allocation, the way
// munmap fails on an unaligned address, so a bad release is reported with
// exit 124 instead of corrupting a heap. Capacities are rounded to 4 KiB
// pages exactly as on Linux, so Text and list headers hold the same values
// on both targets. Growth allocates, copies and releases (Linux mremap
// with MAYMOVE also moves); the new capacity is at least twice the old one,
// so appends and pushes stay amortized constant time.
//
// Internal convention, as in native_rt: arguments in RDI, RSI, RDX, RCX,
// results in RAX, RDX; RAX, RCX, RDX, RSI, RDI and R8-R11 are scratch, live
// values stay in frame slots. Every KERNEL32 call realigns RSP and reserves
// the 32-byte shadow space (w64AlignStack). Windows also preserves RBX, RBP,
// RSI, RDI and R12-R15 across those calls; the routines rely on RBP only
// and touch none of the others that the caller could expect preserved.
//
// Exit statuses, the same as on Linux: 121 append to a literal, 123
// allocation failed or request out of range (negative, beyond the list
// limit), 124 release failed.

const W64_MEM_COMMIT_RESERVE = 12288
const W64_PAGE_READWRITE = 4
const W64_MEM_RELEASE = 32768

// RAX = VirtualAlloc(NULL, RDX, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE),
// or exit 123 when it fails or the byte count in RDX is not positive.
flow wheapAlloc(code: edit X64Code, imports: edit Pe64Imports) {
    x64MovReg(edit code, 0, 2)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 8)
    x64TestRax(edit code)
    hold positive = x64ConditionalPlaceholder(edit code, false)
    w64EmitExit(edit code, edit imports, 123)
    hold positive_end = code.bytes.length
    x64PatchRelative(edit code, positive, positive_end)
    w64AlignStack(edit code, 32)
    x64MovImm64(edit code, 1, 0)
    x64MovImm64(edit code, 8, W64_MEM_COMMIT_RESERVE)
    x64MovImm64(edit code, 9, W64_PAGE_READWRITE)
    w64CallImport(edit code, edit imports, pe64ImportVirtualAlloc())
    x64TestRax(edit code)
    hold mapped = x64ConditionalPlaceholder(edit code, false)
    w64EmitExit(edit code, edit imports, 123)
    hold mapped_end = code.bytes.length
    x64PatchRelative(edit code, mapped, mapped_end)
}

// VirtualFree(RCX, 0, MEM_RELEASE), or exit 124 when Windows refuses it
// (not the base of a live allocation: never allocated, or already freed).
flow wheapRelease(code: edit X64Code, imports: edit Pe64Imports) {
    w64AlignStack(edit code, 32)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 8, W64_MEM_RELEASE)
    w64CallImport(edit code, edit imports, pe64ImportVirtualFree())
    x64TestEax(edit code)
    hold released = x64ConditionalPlaceholder(edit code, false)
    w64EmitExit(edit code, edit imports, 124)
    hold released_end = code.bytes.length
    x64PatchRelative(edit code, released, released_end)
}

// Leaves with 123 when the signed comparison `RAX <condition> RCX` holds
// (6 lt, 8 gt), like rtListFailIf. Clobbers RAX.
flow wheapFailIf(code: edit X64Code, imports: edit Pe64Imports, condition: Int) {
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, condition)
    x64TestRax(edit code)
    hold ok = x64ConditionalPlaceholder(edit code, true)
    w64EmitExit(edit code, edit imports, 123)
    hold ok_end = code.bytes.length
    x64PatchRelative(edit code, ok, ok_end)
}

// text_new(RDI = wanted capacity) -> RAX = address, RDX = capacity.
// The capacity is rounded up to whole pages and is never zero, so an owned
// buffer can always be told apart from a literal (capacity 0).
flow wheapEmitTextNew(code: edit X64Code, imports: edit Pe64Imports) {
    x64FrameBegin(edit code, 2)
    x64MovReg(edit code, 6, 7)
    x64MovImm64(edit code, 10, 4095)
    x64AddReg(edit code, 6, 10)
    x64MovImm64(edit code, 10, -4096)
    x64AndReg(edit code, 6, 10)
    x64MovReg(edit code, 0, 6)
    x64TestRax(edit code)
    hold sized = x64ConditionalPlaceholder(edit code, false)
    x64MovImm64(edit code, 6, 4096)
    hold sized_end = code.bytes.length
    x64PatchRelative(edit code, sized, sized_end)
    x64StoreSlot(edit code, 0, 6)
    x64MovReg(edit code, 2, 6)
    wheapAlloc(edit code, edit imports)
    x64LoadSlot(edit code, 2, 0)
    x64FrameEnd(edit code)
}

// text_append(RDI = address of an owned Text, RSI = bytes, RDX = count).
// Grows the buffer when the bytes do not fit: new capacity =
// pages(needed + old capacity), a fresh allocation that receives the old
// bytes before the old one is released. Slots: 0 header, 1 source,
// 2 count, 3 needed length, 4 new capacity, 5 new buffer.
flow wheapEmitTextAppend(code: edit X64Code, imports: edit Pe64Imports) {
    x64FrameBegin(edit code, 6)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 6)
    x64StoreSlot(edit code, 2, 2)
    x64LoadMem64(edit code, 0, 7, 8)
    x64AddReg(edit code, 0, 2)
    x64StoreSlot(edit code, 3, 0)
    x64LoadMem64(edit code, 1, 7, 16)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 8)
    x64TestRax(edit code)
    hold fits = x64ConditionalPlaceholder(edit code, true)
    // A literal (capacity 0) cannot grow.
    x64LoadSlot(edit code, 7, 0)
    x64LoadMem64(edit code, 0, 7, 16)
    x64TestRax(edit code)
    hold owned = x64ConditionalPlaceholder(edit code, false)
    w64EmitExit(edit code, edit imports, 121)
    hold owned_end = code.bytes.length
    x64PatchRelative(edit code, owned, owned_end)
    // new capacity = pages(needed + old capacity).
    x64LoadSlot(edit code, 2, 3)
    x64AddReg(edit code, 2, 0)
    x64MovImm64(edit code, 10, 4095)
    x64AddReg(edit code, 2, 10)
    x64MovImm64(edit code, 10, -4096)
    x64AndReg(edit code, 2, 10)
    x64StoreSlot(edit code, 4, 2)
    wheapAlloc(edit code, edit imports)
    x64StoreSlot(edit code, 5, 0)
    // Old bytes [0, length) into the new buffer, then release the old one.
    x64MovReg(edit code, 7, 0)
    x64LoadSlot(edit code, 0, 0)
    x64LoadMem64(edit code, 6, 0, 0)
    x64LoadMem64(edit code, 1, 0, 8)
    x64RepMovsb(edit code)
    x64LoadSlot(edit code, 0, 0)
    x64LoadMem64(edit code, 1, 0, 0)
    wheapRelease(edit code, edit imports)
    // Publish the new buffer and capacity; the length is unchanged.
    x64LoadSlot(edit code, 7, 0)
    x64LoadSlot(edit code, 0, 5)
    x64StoreMem64(edit code, 7, 0, 0)
    x64LoadSlot(edit code, 0, 4)
    x64StoreMem64(edit code, 7, 16, 0)
    hold fits_end = code.bytes.length
    x64PatchRelative(edit code, fits, fits_end)
    // Copy to address + length, then publish the new length.
    x64LoadSlot(edit code, 0, 0)
    x64LoadMem64(edit code, 7, 0, 0)
    x64LoadMem64(edit code, 1, 0, 8)
    x64AddReg(edit code, 7, 1)
    x64LoadSlot(edit code, 6, 1)
    x64LoadSlot(edit code, 1, 2)
    x64RepMovsb(edit code)
    x64LoadSlot(edit code, 0, 0)
    x64LoadSlot(edit code, 1, 3)
    x64StoreMem64(edit code, 0, 8, 1)
    x64FrameEnd(edit code)
}

// text_drop(RDI = address, RSI = capacity or byte size): releases an owned
// buffer and does nothing when RSI is 0 (a literal, or a list that never
// had a buffer). The list drop glue releases its buffers through it too.
flow wheapEmitTextDrop(code: edit X64Code, imports: edit Pe64Imports) {
    x64FrameBegin(edit code, 0)
    x64MovReg(edit code, 0, 6)
    x64TestRax(edit code)
    hold literal = x64ConditionalPlaceholder(edit code, true)
    x64MovReg(edit code, 1, 7)
    wheapRelease(edit code, edit imports)
    hold literal_end = code.bytes.length
    x64PatchRelative(edit code, literal, literal_end)
    x64FrameEnd(edit code)
}

// list_reserve(RDI = header address, RSI = extra elements wanted,
// RDX = element size, RCX = minimum capacity when it grows), with the
// checks and capacity policy of rtEmitListReserve: 0 <= request <= limit,
// new capacity = max(length + request, 2 * capacity, minimum) <= limit,
// byte size pages(capacity * element size). The header changes only after
// the new buffer exists and holds the elements. Slots: 0 header, 1 element
// size, 2 minimum, 3 new capacity, 4 new bytes, 5 new buffer.
flow wheapEmitListReserve(code: edit X64Code, imports: edit Pe64Imports) {
    x64FrameBegin(edit code, 6)
    x64StoreSlot(edit code, 0, 7)
    x64StoreSlot(edit code, 1, 2)
    x64StoreSlot(edit code, 2, 1)
    x64MovReg(edit code, 0, 6)
    x64MovImm64(edit code, 1, 0)
    wheapFailIf(edit code, edit imports, 6)
    x64MovReg(edit code, 0, 6)
    x64MovImm64(edit code, 1, rtListLimit())
    wheapFailIf(edit code, edit imports, 8)
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
    hold grow_end = code.bytes.length
    x64PatchRelative(edit code, grow, grow_end)
    x64LoadSlot(edit code, 7, 0)
    x64LoadMem64(edit code, 0, 7, 16)
    x64AddReg(edit code, 0, 0)
    rtListMaxSlot(edit code, 3)
    x64LoadSlot(edit code, 0, 2)
    rtListMaxSlot(edit code, 3)
    x64LoadSlot(edit code, 0, 3)
    x64MovImm64(edit code, 1, rtListLimit())
    wheapFailIf(edit code, edit imports, 8)
    x64LoadSlot(edit code, 0, 3)
    x64LoadSlot(edit code, 1, 1)
    rtListBytes(edit code)
    x64StoreSlot(edit code, 4, 0)
    x64MovReg(edit code, 2, 0)
    wheapAlloc(edit code, edit imports)
    x64StoreSlot(edit code, 5, 0)
    // A previous buffer: its length * size bytes move over, then it goes.
    x64LoadSlot(edit code, 7, 0)
    x64LoadMem64(edit code, 0, 7, 16)
    x64TestRax(edit code)
    hold fresh = x64ConditionalPlaceholder(edit code, true)
    x64LoadMem64(edit code, 0, 7, 8)
    x64LoadSlot(edit code, 1, 1)
    x64MulReg(edit code, 0, 1)
    x64MovReg(edit code, 1, 0)
    x64LoadMem64(edit code, 6, 7, 0)
    x64LoadSlot(edit code, 7, 5)
    x64RepMovsb(edit code)
    x64LoadSlot(edit code, 7, 0)
    x64LoadMem64(edit code, 1, 7, 0)
    wheapRelease(edit code, edit imports)
    hold fresh_end = code.bytes.length
    x64PatchRelative(edit code, fresh, fresh_end)
    // Publish the buffer and the capacity; the length is unchanged.
    x64LoadSlot(edit code, 7, 0)
    x64LoadSlot(edit code, 0, 5)
    x64StoreMem64(edit code, 7, 0, 0)
    x64LoadSlot(edit code, 0, 3)
    x64StoreMem64(edit code, 7, 16, 0)
    x64FrameEnd(edit code)
}

// Number of entries w64EmitHeapRuntime returns: rtEmitAll's nine plus
// list_reserve (rtListReserve()).
expose flow w64HeapRuntimeCount() => Int { give 10 }

// Emits the whole Windows runtime and returns the address of each routine,
// indexed like native_rt's rtEmitAll (rtWriteAll() .. rtTextDrop()) and
// then rtListReserve(). Output routines come from win64_rt; append_int,
// append_bool and print_text are the target-independent ones of native_rt.
expose flow w64EmitHeapRuntime(code: edit X64Code, imports: edit Pe64Imports) => List of[Int] {
    change at = w64EmitRuntime(edit code, edit imports)
    hold write_all = at[rtWriteAll()]
    at@push(code.bytes.length)
    rtEmitPrintText(edit code, write_all)
    at@push(code.bytes.length)
    wheapEmitTextNew(edit code, edit imports)
    hold append = code.bytes.length
    at@push(append)
    wheapEmitTextAppend(edit code, edit imports)
    at@push(code.bytes.length)
    rtEmitAppendInt(edit code, append)
    at@push(code.bytes.length)
    rtEmitAppendBool(edit code, append)
    at@push(code.bytes.length)
    wheapEmitTextDrop(edit code, edit imports)
    at@push(code.bytes.length)
    wheapEmitListReserve(edit code, edit imports)
    give at
}
