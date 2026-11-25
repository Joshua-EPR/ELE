take x86_64

// Float text for the ELE-written native backend (both targets): a port of
// the Cranelift runtime `l_rt_ftoa` of Stage 0 (crates/l/src/native/runtime.rs),
// as machine code through the ELE x86-64 encoder. Pure computation: no
// system call, so the same bytes serve the ELF64 and the PE32+ runtime.
//
// Format: NaN -> `NaN`, +-inf -> `inf`/`-inf`, +-0 -> `0`/`-0`; otherwise the
// integer part of |x| through a saturating conversion, then up to
// `16 - digits(integer part)` fraction digits by repeated `* 10` and
// truncation, rounded half-up when the remaining fraction is >= 0.5 (carry
// through the fraction digits and, past the first, into the last integer
// digit with no carry check, exactly like Stage 0), trailing zeros trimmed,
// no `.` when no fraction digit is left.
//
// ftoa: RDI = bit pattern, RSI = output buffer (at least 48 bytes; special
// values store a whole word), result RAX = length. Clobbers every scratch
// register and xmm0-xmm2. Slots: 0 out, 1 negative, 2 integer length,
// 3 max fraction digits, 4-7 integer buffer, 8-11 fraction buffer, 12 sign
// width, 13 integer start, 14 scratch.

// Indexes into the list returned by fltEmitAll.
expose flow fltPrintIndex() => Int { give 0 }
expose flow fltAppendIndex() => Int { give 1 }

flow fltAdd(code: edit X64Code, reg: Int, delta: Int) {
    x64MovImm64(edit code, 10, delta)
    x64AddReg(edit code, reg, 10)
}

flow fltCall(code: edit X64Code, target: Int) {
    hold at = x64CallPlaceholder(edit code)
    x64PatchRelative(edit code, at, target)
}

// Stores the packed bytes `word` at the output buffer and leaves
// RAX = `length`, then returns from the routine.
flow fltEmitLiteralReturn(code: edit X64Code, word: Int, length: Int) {
    x64LoadSlot(edit code, 2, 0)
    x64MovImm64(edit code, 0, word)
    x64StoreMem64(edit code, 2, 0, 0)
    x64MovImm64(edit code, 0, length)
    x64FrameEnd(edit code)
}

flow fltEmitFtoa(code: edit X64Code) {
    x64FrameBegin(edit code, 16)
    x64StoreSlot(edit code, 0, 6)
    // negative = bits < 0 (signed); RDI = |bits|.
    x64MovReg(edit code, 0, 7)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 0, 1)
    x64SetCondition(edit code, 6)
    x64StoreSlot(edit code, 1, 0)
    x64MovImm64(edit code, 0, 9223372036854775807)
    x64AndReg(edit code, 7, 0)
    // R8 = biased exponent, R9 = mantissa.
    x64MovReg(edit code, 0, 7)
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 1, 4503599627370496)
    x64DivUnsignedReg(edit code, 1)
    x64MovReg(edit code, 8, 0)
    x64MovReg(edit code, 9, 2)
    x64MovImm64(edit code, 1, 2047)
    x64CmpReg(edit code, 8, 1)
    hold special = x64JccPlaceholder(edit code, 4)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 7, 1)
    hold zero = x64JccPlaceholder(edit code, 4)

    // ----- finite, non-zero -----
    x64MovqToXmm(edit code, 0, 7)
    x64SaturatingFloatToInt(edit code)
    x64StoreSlot(edit code, 14, 0)
    x64Cvtsi2sd(edit code, 1, 0)
    x64SdOp(edit code, 2, 0, 1)
    // Integer digits, written backwards from RBP-32.
    x64LeaMem(edit code, 6, 5, -32)
    hold digit = code.bytes.length
    x64MovImm64(edit code, 2, 0)
    x64MovImm64(edit code, 1, 10)
    x64DivUnsignedReg(edit code, 1)
    fltAdd(edit code, 2, 48)
    fltAdd(edit code, 6, -1)
    x64StoreMem8(edit code, 6, 0, 2)
    x64TestRax(edit code)
    hold more = x64ConditionalPlaceholder(edit code, false)
    x64PatchRelative(edit code, more, digit)
    x64StoreSlot(edit code, 13, 6)
    x64LeaMem(edit code, 1, 5, -32)
    x64SubReg(edit code, 1, 6)
    x64StoreSlot(edit code, 2, 1)
    // Sign.
    x64LoadSlot(edit code, 0, 1)
    x64TestRax(edit code)
    hold unsigned = x64ConditionalPlaceholder(edit code, true)
    x64LoadSlot(edit code, 2, 0)
    x64MovImm64(edit code, 1, 45)
    x64StoreMem8(edit code, 2, 0, 1)
    x64MovImm64(edit code, 0, 1)
    hold signed_join = x64JumpPlaceholder(edit code)
    x64PatchHere(edit code, unsigned)
    x64MovImm64(edit code, 0, 0)
    x64PatchHere(edit code, signed_join)
    x64StoreSlot(edit code, 12, 0)
    // Copy the integer digits after the sign.
    x64LoadSlot(edit code, 7, 0)
    x64AddReg(edit code, 7, 0)
    x64LoadSlot(edit code, 6, 13)
    x64LoadSlot(edit code, 1, 2)
    x64RepMovsb(edit code)
    // max fraction digits = max(0, 16 - integer length).
    x64MovImm64(edit code, 0, 16)
    x64LoadSlot(edit code, 1, 2)
    x64SubReg(edit code, 0, 1)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 0, 1)
    hold positive_room = x64JccPlaceholder(edit code, 15)
    x64MovImm64(edit code, 0, 0)
    x64PatchHere(edit code, positive_room)
    x64StoreSlot(edit code, 3, 0)
    // Fraction digits: R8 = k, R9 = max, xmm2 = 10.0, xmm0 = fraction.
    x64MovReg(edit code, 9, 0)
    x64MovImm64(edit code, 0, 10)
    x64Cvtsi2sd(edit code, 2, 0)
    x64MovImm64(edit code, 8, 0)
    hold head = code.bytes.length
    x64CmpReg(edit code, 8, 9)
    hold digits_done = x64JccPlaceholder(edit code, 13)
    x64SdOp(edit code, 3, 0, 2)
    x64Cvttsd2si(edit code, 0, 0)
    x64Cvtsi2sd(edit code, 1, 0)
    x64SdOp(edit code, 2, 0, 1)
    fltAdd(edit code, 0, 48)
    x64LeaMem(edit code, 2, 5, -96)
    x64AddReg(edit code, 2, 8)
    x64StoreMem8(edit code, 2, 0, 0)
    fltAdd(edit code, 8, 1)
    hold again = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, again, head)
    x64PatchHere(edit code, digits_done)
    // Round half-up when there are fraction digits and fraction >= 0.5.
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 9, 1)
    hold no_round_a = x64JccPlaceholder(edit code, 14)
    x64MovImm64(edit code, 0, 4602678819172646912)
    x64MovqToXmm(edit code, 1, 0)
    x64Ucomisd(edit code, 0, 1)
    hold no_round_b = x64JccPlaceholder(edit code, 2)
    x64MovReg(edit code, 8, 9)
    fltAdd(edit code, 8, -1)
    hold round_head = code.bytes.length
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 8, 1)
    hold carry_out = x64JccPlaceholder(edit code, 12)
    x64LeaMem(edit code, 2, 5, -96)
    x64AddReg(edit code, 2, 8)
    x64LoadMem8(edit code, 0, 2, 0)
    fltAdd(edit code, 0, 1)
    x64MovImm64(edit code, 1, 58)
    x64CmpReg(edit code, 0, 1)
    hold overflow_digit = x64JccPlaceholder(edit code, 4)
    x64StoreMem8(edit code, 2, 0, 0)
    hold rounded = x64JumpPlaceholder(edit code)
    x64PatchHere(edit code, overflow_digit)
    x64MovImm64(edit code, 0, 48)
    x64StoreMem8(edit code, 2, 0, 0)
    fltAdd(edit code, 8, -1)
    hold round_again = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, round_again, round_head)
    x64PatchHere(edit code, carry_out)
    // The carry leaves the fraction: bump the last integer digit.
    x64LoadSlot(edit code, 2, 0)
    x64LoadSlot(edit code, 0, 12)
    x64AddReg(edit code, 2, 0)
    x64LoadSlot(edit code, 0, 2)
    x64AddReg(edit code, 2, 0)
    fltAdd(edit code, 2, -1)
    x64LoadMem8(edit code, 0, 2, 0)
    fltAdd(edit code, 0, 1)
    x64StoreMem8(edit code, 2, 0, 0)
    x64PatchHere(edit code, no_round_a)
    x64PatchHere(edit code, no_round_b)
    x64PatchHere(edit code, rounded)
    // Trim trailing zeros: R8 = last candidate index.
    x64LoadSlot(edit code, 8, 3)
    fltAdd(edit code, 8, -1)
    hold trim_head = code.bytes.length
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 8, 1)
    hold all_zero = x64JccPlaceholder(edit code, 12)
    x64LeaMem(edit code, 2, 5, -96)
    x64AddReg(edit code, 2, 8)
    x64LoadMem8(edit code, 0, 2, 0)
    x64MovImm64(edit code, 1, 48)
    x64CmpReg(edit code, 0, 1)
    hold last_digit = x64JccPlaceholder(edit code, 5)
    fltAdd(edit code, 8, -1)
    hold trim_again = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, trim_again, trim_head)
    x64PatchHere(edit code, all_zero)
    x64PatchHere(edit code, last_digit)
    // R8 = index of the last kept digit (-1 when none): count = R8 + 1.
    fltAdd(edit code, 8, 1)
    x64LoadSlot(edit code, 0, 12)
    x64LoadSlot(edit code, 1, 2)
    x64AddReg(edit code, 0, 1)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 8, 1)
    hold no_fraction = x64JccPlaceholder(edit code, 14)
    x64StoreSlot(edit code, 14, 0)
    x64LoadSlot(edit code, 2, 0)
    x64AddReg(edit code, 2, 0)
    x64MovImm64(edit code, 1, 46)
    x64StoreMem8(edit code, 2, 0, 1)
    x64MovReg(edit code, 7, 2)
    fltAdd(edit code, 7, 1)
    x64LeaMem(edit code, 6, 5, -96)
    x64MovReg(edit code, 1, 8)
    x64RepMovsb(edit code)
    x64LoadSlot(edit code, 0, 14)
    fltAdd(edit code, 0, 1)
    x64AddReg(edit code, 0, 8)
    x64PatchHere(edit code, no_fraction)
    x64FrameEnd(edit code)

    // ----- zero -----
    x64PatchHere(edit code, zero)
    x64LoadSlot(edit code, 0, 1)
    x64TestRax(edit code)
    hold positive_zero = x64ConditionalPlaceholder(edit code, true)
    fltEmitLiteralReturn(edit code, 12333, 2)
    x64PatchHere(edit code, positive_zero)
    fltEmitLiteralReturn(edit code, 48, 1)

    // ----- exponent 0x7FF: NaN or infinity -----
    x64PatchHere(edit code, special)
    x64MovImm64(edit code, 1, 0)
    x64CmpReg(edit code, 9, 1)
    hold infinity = x64JccPlaceholder(edit code, 4)
    fltEmitLiteralReturn(edit code, 5136718, 3)
    x64PatchHere(edit code, infinity)
    x64LoadSlot(edit code, 0, 1)
    x64TestRax(edit code)
    hold positive_inf = x64ConditionalPlaceholder(edit code, true)
    fltEmitLiteralReturn(edit code, 1718511917, 4)
    x64PatchHere(edit code, positive_inf)
    fltEmitLiteralReturn(edit code, 6712937, 3)
}

// print_float(RDI = bit pattern): the text, then a line feed.
flow fltEmitPrint(code: edit X64Code, write_all: Int, ftoa: Int) {
    x64FrameBegin(edit code, 10)
    x64LeaMem(edit code, 6, 5, -80)
    fltCall(edit code, ftoa)
    x64LeaMem(edit code, 1, 5, -80)
    x64AddReg(edit code, 1, 0)
    x64MovImm64(edit code, 2, 10)
    x64StoreMem8(edit code, 1, 0, 2)
    x64MovReg(edit code, 2, 0)
    fltAdd(edit code, 2, 1)
    x64LeaMem(edit code, 6, 5, -80)
    fltCall(edit code, write_all)
    x64FrameEnd(edit code)
}

// append_float(RDI = address of an owned Text, RSI = bit pattern).
flow fltEmitAppend(code: edit X64Code, append: Int, ftoa: Int) {
    x64FrameBegin(edit code, 12)
    x64StoreSlot(edit code, 0, 7)
    x64MovReg(edit code, 7, 6)
    x64LeaMem(edit code, 6, 5, -96)
    fltCall(edit code, ftoa)
    x64MovReg(edit code, 2, 0)
    x64LeaMem(edit code, 6, 5, -96)
    x64LoadSlot(edit code, 7, 0)
    fltCall(edit code, append)
    x64FrameEnd(edit code)
}

// Emits the Float routines; `write_all` and `append` are the code offsets
// of the target runtime's routines. Returns the offsets of print_float and
// append_float (fltPrintIndex(), fltAppendIndex()).
expose flow fltEmitAll(code: edit X64Code, write_all: Int, append: Int) => List of[Int] {
    change at: List of[Int] = List[]
    hold ftoa = code.bytes.length
    fltEmitFtoa(edit code)
    at@push(code.bytes.length)
    fltEmitPrint(edit code, write_all, ftoa)
    at@push(code.bytes.length)
    fltEmitAppend(edit code, append, ftoa)
    give at
}
