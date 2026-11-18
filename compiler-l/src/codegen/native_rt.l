import x86_64

// Runtime of the ELE-written Linux x86-64 backend: output and owned Text.
// Every routine is machine code produced through the ELE x86-64 encoder;
// there is no libc, no Rust and no assembler behind it.
//
// Convention: arguments in RDI, RSI, RDX; results in RAX, RDX. All of RAX,
// RCX, RDX, RSI, RDI and R8-R11 are scratch: the CFG lowering keeps every
// live value in a stack slot, so nothing survives a call in a register.
//
// A Text value is three words: address, byte length, capacity. Capacity 0
// marks a literal stored in the image, which is never freed nor grown.
// Owned buffers come from mmap, grow with mremap and die with munmap.
// Exit statuses: 121 append to a literal, 123 allocation failed, 124
// release failed.

// Indexes into the address list returned by rtEmitAll.
expose flow rtWriteAll() => Int { give 0 }
expose flow rtPrintInt() => Int { give 1 }
expose flow rtPrintBool() => Int { give 2 }
expose flow rtPrintText() => Int { give 3 }
expose flow rtTextNew() => Int { give 4 }
expose flow rtTextAppend() => Int { give 5 }
expose flow rtAppendInt() => Int { give 6 }
expose flow rtAppendBool() => Int { give 7 }
expose flow rtTextDrop() => Int { give 8 }

flow rtExit(code: edit X64Code, status: Int) {
    x64MovImm64(edit code, 7, status)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)
}

// Adds a signed constant to `reg`, using R10 as scratch.
flow rtAdjust(code: edit X64Code, reg: Int, delta: Int) {
    x64MovImm64(edit code, 10, delta)
    x64AddReg(edit code, reg, 10)
}

flow rtCall(code: edit X64Code, target: Int) {
    hold at = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, at, target)
}

// Leaves through `status` when RAX is negative, which is how Linux reports
// a failed system call. Preserves RAX; clobbers RCX and R9.
flow rtFailIfNegative(code: edit X64Code, status: Int) {
    x64MovReg(edit code, 9, 0)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 6)
    x64TestRax(edit code)
    hold ok = x64ConditionalPlaceholder(edit code, true)
    rtExit(edit code, status)
    hold patch_offset_55 = code.bytes.length
    x64PatchRelative(edit code, ok, patch_offset_55)
    x64MovReg(edit code, 0, 9)
}

// write_all(RSI = bytes, RDX = count): repeats write(1, ...) until every
// byte is out. A failed write stops silently: `print` has no error channel.
flow rtEmitWriteAll(code: edit X64Code) {
    x64FrameBegin(edit code, 2)
    hold top = code.bytes.length
    x64MovReg(edit code, 0, 2)
    x64TestRax(edit code)
    hold finished = x64ConditionalPlaceholder(edit code, true)
    x64StoreSlot(edit code, 0, 6)
    x64StoreSlot(edit code, 1, 2)
    x64MovImm64(edit code, 7, 1)
    x64MovImm64(edit code, 0, 1)
    x64Syscall(edit code)
    x64MovReg(edit code, 9, 0)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 7)
    x64TestRax(edit code)
    hold failed = x64ConditionalPlaceholder(edit code, false)
    x64LoadSlot(edit code, 6, 0)
    x64AddReg(edit code, 6, 9)
    x64LoadSlot(edit code, 2, 1)
    x64SubReg(edit code, 2, 9)
    hold again = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, again, top)
    hold patch_offset_84 = code.bytes.length
    x64PatchRelative(edit code, finished, patch_offset_84)
    hold patch_offset_85 = code.bytes.length
    x64PatchRelative(edit code, failed, patch_offset_85)
    x64FrameEnd(edit code)
}

// Formats the Int in RDI as decimal text that ends at RBP + `end`, growing
// downwards. Leaves RSI = first byte and RDX = byte count. 20 digits, a sign
// and a line feed need 22 bytes of frame below RBP + `end`.
flow rtEmitDigits(code: edit X64Code, end: Int, newline: Bool) {
    // R8 = 1 when negative; R9 = magnitude read as unsigned, so the minimum
    // Int (whose negation is itself) still prints correctly.
    x64MovReg(edit code, 0, 7)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 6)
    x64MovReg(edit code, 8, 0)
    x64MovReg(edit code, 9, 7)
    x64TestRax(edit code)
    hold positive = x64ConditionalPlaceholder(edit code, true)
    x64NegReg(edit code, 9)
    hold patch_offset_104 = code.bytes.length
    x64PatchRelative(edit code, positive, patch_offset_104)
    x64MovReg(edit code, 6, 5)
    rtAdjust(edit code, 6, end)
    when newline {
        rtAdjust(edit code, 6, -1)
        x64MovImm64(edit code, 1, 10)
        x64StoreMem8(edit code, 6, 0, 1)
    }
    x64MovReg(edit code, 0, 9)
    hold digit = code.bytes.length
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 1, 10)
    x64DivUnsignedReg(edit code, 1)
    rtAdjust(edit code, 2, 48)
    rtAdjust(edit code, 6, -1)
    x64StoreMem8(edit code, 6, 0, 2)
    x64TestRax(edit code)
    hold more = x64ConditionalPlaceholder(edit code, false)
    x64PatchRelative(edit code, more, digit)
    x64MovReg(edit code, 0, 8)
    x64TestRax(edit code)
    hold unsigned = x64ConditionalPlaceholder(edit code, true)
    rtAdjust(edit code, 6, -1)
    x64MovImm64(edit code, 1, 45)
    x64StoreMem8(edit code, 6, 0, 1)
    hold patch_offset_129 = code.bytes.length
    x64PatchRelative(edit code, unsigned, patch_offset_129)
    x64MovReg(edit code, 2, 5)
    rtAdjust(edit code, 2, end)
    x64SubReg(edit code, 2, 6)
}

// Loads RAX with "true"/"false" packed little-endian and RDX with its byte
// count, according to the Bool in RAX. `line` appends a line feed.
flow rtEmitBoolWord(code: edit X64Code, line: Bool) {
    x64TestRax(edit code)
    hold is_false = x64ConditionalPlaceholder(edit code, true)
    when line {
        x64MovImm64(edit code, 0, 44651868788)
        x64MovImm64(edit code, 2, 5)
    } otherwise {
        x64MovImm64(edit code, 0, 1702195828)
        x64MovImm64(edit code, 2, 4)
    }
    hold join = x64JumpPlaceholder(edit code)
    hold patch_offset_148 = code.bytes.length
    x64PatchRelative(edit code, is_false, patch_offset_148)
    when line {
        x64MovImm64(edit code, 0, 11430844457318)
        x64MovImm64(edit code, 2, 6)
    } otherwise {
        x64MovImm64(edit code, 0, 435728179558)
        x64MovImm64(edit code, 2, 5)
    }
    hold patch_offset_156 = code.bytes.length
    x64PatchRelative(edit code, join, patch_offset_156)
}

// print_int(RDI = value).
expose flow rtEmitPrintInt(code: edit X64Code, write_all: Int) {
    x64FrameBegin(edit code, 4)
    rtEmitDigits(edit code, 0, true)
    rtCall(edit code, write_all)
    x64FrameEnd(edit code)
}

// print_bool(RDI = value).
expose flow rtEmitPrintBool(code: edit X64Code, write_all: Int) {
    x64FrameBegin(edit code, 2)
    x64MovReg(edit code, 0, 7)
    rtEmitBoolWord(edit code, true)
    x64StoreMem64(edit code, 5, -8, 0)
    x64MovReg(edit code, 6, 5)
    rtAdjust(edit code, 6, -8)
    rtCall(edit code, write_all)
    x64FrameEnd(edit code)
}

// print_text(RDI = bytes, RSI = count): the text, then a line feed.
flow rtEmitPrintText(code: edit X64Code, write_all: Int) {
    x64FrameBegin(edit code, 2)
    x64MovReg(edit code, 2, 6)
    x64MovReg(edit code, 6, 7)
    rtCall(edit code, write_all)
    x64MovImm64(edit code, 0, 10)
    x64StoreMem64(edit code, 5, -8, 0)
    x64MovReg(edit code, 6, 5)
    rtAdjust(edit code, 6, -8)
    x64MovImm64(edit code, 2, 1)
    rtCall(edit code, write_all)
    x64FrameEnd(edit code)
}

// text_new(RDI = wanted capacity) -> RAX = address, RDX = capacity.
// The capacity is rounded up to whole pages and is never zero, so an owned
// buffer can always be told apart from a literal.
flow rtEmitTextNew(code: edit X64Code) {
    x64FrameBegin(edit code, 2)
    x64MovReg(edit code, 6, 7)
    rtAdjust(edit code, 6, 4095)
    x64MovImm64(edit code, 10, -4096)
    x64AndReg(edit code, 6, 10)
    x64MovReg(edit code, 0, 6)
    x64TestRax(edit code)
    hold sized = x64ConditionalPlaceholder(edit code, false)
    x64MovImm64(edit code, 6, 4096)
    hold patch_offset_207 = code.bytes.length
    x64PatchRelative(edit code, sized, patch_offset_207)
    x64StoreSlot(edit code, 0, 6)
    // mmap(0, RSI, READ|WRITE, PRIVATE|ANONYMOUS, -1, 0)
    x64MovImm64(edit code, 7, 0)
    x64MovImm64(edit code, 2, 3)
    x64MovImm64(edit code, 10, 34)
    x64MovImm64(edit code, 8, -1)
    x64MovImm64(edit code, 9, 0)
    x64MovImm64(edit code, 0, 9)
    x64Syscall(edit code)
    rtFailIfNegative(edit code, 123)
    x64LoadSlot(edit code, 2, 0)
    x64FrameEnd(edit code)
}

// text_append(RDI = address of an owned Text, RSI = bytes, RDX = count).
// Grows the buffer when the bytes do not fit; the new capacity is at least
// twice the old one, so repeated appends cost amortized constant time.
flow rtEmitTextAppend(code: edit X64Code) {
    x64FrameBegin(edit code, 4)
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
    rtExit(edit code, 121)
    hold patch_offset_244 = code.bytes.length
    x64PatchRelative(edit code, owned, patch_offset_244)
    // R8 = new capacity = pages(needed + old capacity).
    x64MovReg(edit code, 6, 0)
    x64LoadSlot(edit code, 2, 3)
    x64AddReg(edit code, 2, 6)
    rtAdjust(edit code, 2, 4095)
    x64MovImm64(edit code, 10, -4096)
    x64AndReg(edit code, 2, 10)
    x64MovReg(edit code, 8, 2)
    // mremap(address, old capacity, new capacity, MAYMOVE)
    x64MovReg(edit code, 9, 7)
    x64LoadMem64(edit code, 7, 9, 0)
    x64MovImm64(edit code, 10, 1)
    x64MovImm64(edit code, 0, 25)
    x64Syscall(edit code)
    rtFailIfNegative(edit code, 123)
    x64LoadSlot(edit code, 7, 0)
    x64StoreMem64(edit code, 7, 0, 0)
    x64StoreMem64(edit code, 7, 16, 8)
    hold patch_offset_263 = code.bytes.length
    x64PatchRelative(edit code, fits, patch_offset_263)
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

// append_int(RDI = address of an owned Text, RSI = value).
flow rtEmitAppendInt(code: edit X64Code, append: Int) {
    x64FrameBegin(edit code, 6)
    x64StoreSlot(edit code, 0, 7)
    x64MovReg(edit code, 7, 6)
    rtEmitDigits(edit code, -8, false)
    x64LoadSlot(edit code, 7, 0)
    rtCall(edit code, append)
    x64FrameEnd(edit code)
}

// append_bool(RDI = address of an owned Text, RSI = value).
flow rtEmitAppendBool(code: edit X64Code, append: Int) {
    x64FrameBegin(edit code, 2)
    x64StoreSlot(edit code, 0, 7)
    x64MovReg(edit code, 0, 6)
    rtEmitBoolWord(edit code, false)
    x64StoreSlot(edit code, 1, 0)
    x64MovReg(edit code, 6, 5)
    rtAdjust(edit code, 6, -16)
    x64LoadSlot(edit code, 7, 0)
    rtCall(edit code, append)
    x64FrameEnd(edit code)
}

// text_drop(RDI = address, RSI = capacity): releases an owned buffer and
// does nothing for a literal.
flow rtEmitTextDrop(code: edit X64Code) {
    x64FrameBegin(edit code, 0)
    x64MovReg(edit code, 0, 6)
    x64TestRax(edit code)
    hold literal = x64ConditionalPlaceholder(edit code, true)
    x64MovImm64(edit code, 0, 11)
    x64Syscall(edit code)
    x64TestRax(edit code)
    hold released = x64ConditionalPlaceholder(edit code, true)
    rtExit(edit code, 124)
    hold patch_offset_315 = code.bytes.length
    x64PatchRelative(edit code, literal, patch_offset_315)
    hold patch_offset_316 = code.bytes.length
    x64PatchRelative(edit code, released, patch_offset_316)
    x64FrameEnd(edit code)
}

// Emits the whole runtime and returns the address of each routine, indexed
// by the rt* functions above.
expose flow rtEmitAll(code: edit X64Code) => List<Int> {
    change at: List<Int> = List[]
    hold write_all = code.bytes.length
    at.push(write_all)
    rtEmitWriteAll(edit code)
    at.push(code.bytes.length)
    rtEmitPrintInt(edit code, write_all)
    at.push(code.bytes.length)
    rtEmitPrintBool(edit code, write_all)
    at.push(code.bytes.length)
    rtEmitPrintText(edit code, write_all)
    at.push(code.bytes.length)
    rtEmitTextNew(edit code)
    hold append = code.bytes.length
    at.push(append)
    rtEmitTextAppend(edit code)
    at.push(code.bytes.length)
    rtEmitAppendInt(edit code, append)
    at.push(code.bytes.length)
    rtEmitAppendBool(edit code, append)
    at.push(code.bytes.length)
    rtEmitTextDrop(edit code)
    give at
}
