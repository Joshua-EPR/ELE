import x86_64

// Output runtime of the ELE-written Linux x86-64 backend. Each routine is
// machine code produced through the x86-64 encoder: no libc, no Rust, no
// assembler. Convention: the value arrives in RDI; RAX, RCX, RDX, RSI, RDI,
// R8-R11 are scratch (the CFG lowering keeps every live value in a stack
// slot, so no caller register survives a call anyway).
// The text goes to stdout with one write(2) system call. A short or failed
// write is not retried and not reported: `print` has no error channel yet.

// Moves `reg` by a signed byte count using R10 as scratch.
fn rtAdjust(code: &mut X64Code, reg: Int, delta: Int) {
    x64MovImm64(&mut code, 10, delta)
    x64AddReg(&mut code, reg, 10)
}

// write(1, RSI, RDX); leave; ret.
fn rtWriteAndReturn(code: &mut X64Code) {
    x64MovImm64(&mut code, 7, 1)
    x64MovImm64(&mut code, 0, 1)
    x64Syscall(&mut code)
    x64FrameEnd(&mut code)
}

// print(Int): decimal digits built backwards below RBP, optional '-', then
// a line feed. 20 digits + sign + line feed fit in the 32-byte frame.
pub fn rtEmitPrintInt(code: &mut X64Code) {
    x64FrameBegin(&mut code, 4)
    // R8 = 1 when negative; R9 = magnitude as an unsigned 64-bit value.
    x64MovReg(&mut code, 0, 7)
    x64MovImm64(&mut code, 1, 0)
    x64CmpReg(&mut code, 0, 1)
    x64SetCondition(&mut code, 6)
    x64MovReg(&mut code, 8, 0)
    x64MovReg(&mut code, 9, 7)
    x64TestRax(&mut code)
    let positive = x64ConditionalPlaceholder(&mut code, true)
    x64NegReg(&mut code, 9)
    x64PatchRelative(&mut code, positive, code.bytes.length)
    // RSI walks down from RBP; the line feed is the last byte written out.
    x64MovReg(&mut code, 6, 5)
    rtAdjust(&mut code, 6, -1)
    x64MovImm64(&mut code, 1, 10)
    x64StoreMem8(&mut code, 6, 0, 1)
    x64MovReg(&mut code, 0, 9)
    let digit_loop = code.bytes.length
    x64MovImm64(&mut code, 2, 0)
    x64MovImm64(&mut code, 1, 10)
    x64DivUnsignedReg(&mut code, 1)
    rtAdjust(&mut code, 2, 48)
    rtAdjust(&mut code, 6, -1)
    x64StoreMem8(&mut code, 6, 0, 2)
    x64TestRax(&mut code)
    let again = x64ConditionalPlaceholder(&mut code, false)
    x64PatchRelative(&mut code, again, digit_loop)
    x64MovReg(&mut code, 0, 8)
    x64TestRax(&mut code)
    let unsigned = x64ConditionalPlaceholder(&mut code, true)
    rtAdjust(&mut code, 6, -1)
    x64MovImm64(&mut code, 1, 45)
    x64StoreMem8(&mut code, 6, 0, 1)
    x64PatchRelative(&mut code, unsigned, code.bytes.length)
    // Length = RBP - RSI.
    x64MovReg(&mut code, 2, 5)
    x64SubReg(&mut code, 2, 6)
    rtWriteAndReturn(&mut code)
}

// print(Bool): the text is packed little-endian into one 8-byte slot.
pub fn rtEmitPrintBool(code: &mut X64Code) {
    x64FrameBegin(&mut code, 2)
    x64MovReg(&mut code, 0, 7)
    x64TestRax(&mut code)
    let is_false = x64ConditionalPlaceholder(&mut code, true)
    x64MovImm64(&mut code, 0, 44651868788) // "true\n"
    x64MovImm64(&mut code, 2, 5)
    let join = x64JumpPlaceholder(&mut code)
    x64PatchRelative(&mut code, is_false, code.bytes.length)
    x64MovImm64(&mut code, 0, 11430844457318) // "false\n"
    x64MovImm64(&mut code, 2, 6)
    x64PatchRelative(&mut code, join, code.bytes.length)
    x64StoreMem64(&mut code, 5, -8, 0)
    x64MovReg(&mut code, 6, 5)
    rtAdjust(&mut code, 6, -8)
    rtWriteAndReturn(&mut code)
}
