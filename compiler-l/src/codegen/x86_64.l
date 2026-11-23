// ELE native backend foundation (x86-64), written in ELE.
// This module creates actual machine-code bytes in memory. It does not call
// Rust, C, Python, an assembler or a linker. The current compiler still
// needs its historical bootstrap to execute this ELE source.
//
// Register numbers: RAX=0, RCX=1, RDX=2, RBX=3, RSP=4, RBP=5,
// RSI=6, RDI=7, R8=8 ... R15=15.
// Bytes are Int values in [0,255], not Unicode code points.

expose shape X64Code {
    bytes: List of[Int]
    error: Int
}

expose flow x64New() => X64Code {
    give X64Code(bytes: List[], error: 0)
}

flow x64RegisterValid(reg: Int) => Bool {
    give reg >= 0 && reg < 16
}

flow x64Put(code: edit X64Code, value: Int) {
    when code.error != 0 { give }
    when value < 0 || value > 255 {
        code.error = 1
        give
    }
    code.bytes@push(value)
}

// Little-endian signed integer, expressed using Euclidean byte remainders.
// This avoids relying on implementation-defined signed right shifts.
flow x64PutSigned(code: edit X64Code, value: Int, count: Int) {
    when count < 1 || count > 8 { code.error = 2; give }
    change remaining = value
    change last = 0
    each i among 0..count {
        change b = remaining % 256
        when b < 0 { b += 256 }
        x64Put(edit code, b)
        last = b
        remaining = (remaining - b) / 256
    }
    // Reject values that cannot fit in the requested signed width.
    when remaining != 0 && remaining != -1 { code.error = 2 }
    when remaining == 0 && last >= 128 { code.error = 2 }
    when remaining == -1 && last < 128 { code.error = 2 }
}

// REX.W with source in ModRM.reg and destination in ModRM.r/m.
flow x64RexRegRm(code: edit X64Code, src: Int, dst: Int) {
    change rex = 72
    when src >= 8 { rex += 4 }
    when dst >= 8 { rex += 1 }
    x64Put(edit code, rex)
}

flow x64ModRmRegisters(code: edit X64Code, reg: Int, rm: Int) {
    x64Put(edit code, 192 + (reg % 8) * 8 + (rm % 8))
}

expose flow x64MovImm64(code: edit X64Code, dst: Int, value: Int) {
    when !x64RegisterValid(dst) { code.error = 3; give }
    change rex = 72
    when dst >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 184 + dst % 8)
    x64PutSigned(edit code, value, 8)
}

// Encoding: MOV r/m64,r64 (destination register encoded as r/m).
expose flow x64MovReg(code: edit X64Code, dst: Int, src: Int) {
    when !x64RegisterValid(dst) || !x64RegisterValid(src) { code.error = 3; give }
    x64RexRegRm(edit code, src, dst)
    x64Put(edit code, 137)
    x64ModRmRegisters(edit code, src, dst)
}

expose flow x64AddReg(code: edit X64Code, dst: Int, src: Int) {
    when !x64RegisterValid(dst) || !x64RegisterValid(src) { code.error = 3; give }
    x64RexRegRm(edit code, src, dst)
    x64Put(edit code, 1)
    x64ModRmRegisters(edit code, src, dst)
}

// AND r/m64,r64, needed for page alignment in the native heap.
// Emitted opcode 0x21: destination is ModRM.r/m.
expose flow x64AndReg(code: edit X64Code, dst: Int, src: Int) {
    when !x64RegisterValid(dst) || !x64RegisterValid(src) { code.error = 3; give }
    x64RexRegRm(edit code, src, dst)
    x64Put(edit code, 33)
    x64ModRmRegisters(edit code, src, dst)
}

expose flow x64SubReg(code: edit X64Code, dst: Int, src: Int) {
    when !x64RegisterValid(dst) || !x64RegisterValid(src) { code.error = 3; give }
    x64RexRegRm(edit code, src, dst)
    x64Put(edit code, 41)
    x64ModRmRegisters(edit code, src, dst)
}

expose flow x64CmpReg(code: edit X64Code, left: Int, right: Int) {
    when !x64RegisterValid(left) || !x64RegisterValid(right) { code.error = 3; give }
    x64RexRegRm(edit code, right, left)
    x64Put(edit code, 57)
    x64ModRmRegisters(edit code, right, left)
}

// IMUL r64,r/m64 (unlike ADD, destination is ModRM.reg).
expose flow x64MulReg(code: edit X64Code, dst: Int, src: Int) {
    when !x64RegisterValid(dst) || !x64RegisterValid(src) { code.error = 3; give }
    x64RexRegRm(edit code, dst, src)
    x64Put(edit code, 15)
    x64Put(edit code, 175)
    x64ModRmRegisters(edit code, dst, src)
}

expose flow x64Ret(code: edit X64Code) {
    x64Put(edit code, 195)
}

expose flow x64Syscall(code: edit X64Code) {
    x64Put(edit code, 15)
    x64Put(edit code, 5)
}

// Writes E9 rel32 with a placeholder and returns the displacement position.
expose flow x64JumpPlaceholder(code: edit X64Code) => Int {
    x64Put(edit code, 233)
    hold at = code.bytes.length
    each i among 0..4 { x64Put(edit code, 0) }
    give at
}

// Writes 0F 84 (JE) or 0F 85 (JNE).
expose flow x64ConditionalPlaceholder(code: edit X64Code, if_equal: Bool) => Int {
    x64Put(edit code, 15)
    when if_equal { x64Put(edit code, 132) } otherwise { x64Put(edit code, 133) }
    hold at = code.bytes.length
    each i among 0..4 { x64Put(edit code, 0) }
    give at
}

// Writes 0F 83 (JAE): unsigned "above or equal", used for bounds checks so
// that a negative index, read as unsigned, is also out of range.
expose flow x64AboveEqualPlaceholder(code: edit X64Code) => Int {
    x64Put(edit code, 15)
    x64Put(edit code, 131)
    hold at = code.bytes.length
    each i among 0..4 { x64Put(edit code, 0) }
    give at
}

// Patch a rel32 displacement. Invalid patches set error without modifying it.
expose flow x64PatchRelative(code: edit X64Code, at: Int, target: Int) {
    when at < 0 || at + 4 > code.bytes.length || target < 0 || target > code.bytes.length {
        code.error = 4
        give
    }
    hold delta = target - (at + 4)
    when delta < -2147483648 || delta > 2147483647 {
        code.error = 5
        give
    }
    change n = delta
    each i among 0..4 {
        change b = n % 256
        when b < 0 { b += 256 }
        code.bytes[at + i] = b
        n = (n - b) / 256
    }
}

// JO rel32: signed arithmetic overflow branch, target patched later.
expose flow x64OverflowPlaceholder(code: edit X64Code) => Int {
    x64Put(edit code, 15)
    x64Put(edit code, 128)
    hold at = code.bytes.length
    each i among 0..4 { x64Put(edit code, 0) }
    give at
}

// ----- Direct native multi-function backend primitives (Linux x86-64). -----
// These use RBP-relative signed disp32 slots; the prologue allocates a
// 16-byte-aligned frame and preserves RBP. RAX/RCX are scratch registers;
// up to two ELE-internal integer arguments use RDI/RSI, return uses RAX.

expose flow x64CallPlaceholder(code: edit X64Code) => Int {
    x64Put(edit code, 232)
    hold at = code.bytes.length
    each i among 0..4 { x64Put(edit code, 0) }
    give at
}

// Largest frame, in 8-byte slots. Slot k lives at [RBP - 8*(k+1)], a signed
// disp32, and the prologue reserves the frame with SUB RSP,imm32 after
// rounding it up to 16 bytes: both must fit a signed 32-bit field, so
// 8 * slots + 8 <= 2^31 - 1. This is an encoding bound, not a policy.
expose flow x64MaxFrameSlots() => Int {
    give 268435454
}

// The prologue allocates a 16-byte-aligned frame and preserves RBP. A frame
// larger than one 4 KiB page is reserved page by page, touching each page
// (OR QWORD [RSP],0) before moving below it: Windows commits the stack only
// through its single guard page, and on Linux a large SUB could jump over
// the stack guard gap. A frame beyond the stack limit therefore faults
// deterministically on the guard instead of writing past it. R11 is the loop
// counter; it is scratch at every function entry of this backend.
expose flow x64FrameBegin(code: edit X64Code, slots: Int) {
    when slots < 0 || slots > x64MaxFrameSlots() { code.error = 6; give }
    x64Put(edit code, 85) // push rbp
    x64MovReg(edit code, 5, 4) // mov rbp,rsp
    change size = slots * 8
    when size % 16 != 0 { size += 8 }
    change rest = size
    when size > 4096 {
        hold pages = size / 4096
        rest = size % 4096
        x64MovImm64(edit code, 11, pages)
        // loop: sub rsp,4096 / or qword [rsp],0 / dec r11 / jnz loop
        x64Put(edit code, 72)
        x64Put(edit code, 129)
        x64Put(edit code, 236)
        x64PutSigned(edit code, 4096, 4)
        x64Put(edit code, 72)
        x64Put(edit code, 131)
        x64Put(edit code, 12)
        x64Put(edit code, 36)
        x64Put(edit code, 0)
        x64Put(edit code, 73)
        x64Put(edit code, 255)
        x64Put(edit code, 203)
        x64Put(edit code, 117)
        x64Put(edit code, 239) // rel8 -17: back to the SUB
    }
    when rest > 0 {
        x64Put(edit code, 72)
        x64Put(edit code, 129)
        x64Put(edit code, 236) // sub rsp,imm32
        x64PutSigned(edit code, rest, 4)
    }
}

expose flow x64FrameEnd(code: edit X64Code) {
    x64Put(edit code, 201) // leave
    x64Ret(edit code)
}

// Memory accesses by [base + signed displacement]. This uses mod=10 and
// disp32 consistently, including displacement zero, to simplify fixups and
// keep stack-field offsets independent of operand size. RSP and R12 require
// the special SIB byte 0x24; RBP and R13 work with mod=10 as usual.
flow x64MemoryAddress(code: edit X64Code, reg: Int, base: Int, displacement: Int) {
    x64Put(edit code, 128 + (reg % 8) * 8 + base % 8)
    when base % 8 == 4 { x64Put(edit code, 36) }
    x64PutSigned(edit code, displacement, 4)
}

flow x64MemoryValid(code: edit X64Code, reg: Int, base: Int, displacement: Int) => Bool {
    when code.error != 0 { give false }
    when !x64RegisterValid(reg) || !x64RegisterValid(base) {
        code.error = 7
        give false
    }
    when displacement < -2147483648 || displacement > 2147483647 {
        code.error = 9
        give false
    }
    give code.error == 0
}

expose flow x64LoadMem64(code: edit X64Code, dst: Int, base: Int, displacement: Int) {
    when !x64MemoryValid(edit code, dst, base, displacement) { give }
    x64RexRegRm(edit code, dst, base)
    x64Put(edit code, 139) // mov r64, r/m64
    x64MemoryAddress(edit code, dst, base, displacement)
}

expose flow x64LoadMem32(code: edit X64Code, dst: Int, base: Int, displacement: Int) {
    when !x64MemoryValid(edit code, dst, base, displacement) { give }
    when dst >= 8 || base >= 8 {
        x64Put(edit code, 64 + (dst / 8) * 4 + base / 8)
    }
    x64Put(edit code, 139) // mov r32, r/m32
    x64MemoryAddress(edit code, dst, base, displacement)
}

expose flow x64StoreMem64(code: edit X64Code, base: Int, displacement: Int, src: Int) {
    when !x64MemoryValid(edit code, src, base, displacement) { give }
    x64RexRegRm(edit code, src, base)
    x64Put(edit code, 137) // mov r/m64, r64
    x64MemoryAddress(edit code, src, base, displacement)
}

// Bool and packed-byte aggregates require byte loads and stores. For stores,
// emit a REX prefix even for low registers 4..7 to select SPL/BPL/SIL/DIL
// rather than the legacy high-byte registers AH/CH/DH/BH.
expose flow x64LoadMem8(code: edit X64Code, dst: Int, base: Int, displacement: Int) {
    when !x64MemoryValid(edit code, dst, base, displacement) { give }
    x64RexRegRm(edit code, dst, base)
    x64Put(edit code, 15)
    x64Put(edit code, 182) // movzx r64,r/m8
    x64MemoryAddress(edit code, dst, base, displacement)
}

expose flow x64StoreMem8(code: edit X64Code, base: Int, displacement: Int, src: Int) {
    when !x64MemoryValid(edit code, src, base, displacement) { give }
    change rex = 64
    when src >= 8 { rex += 4 }
    when base >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 136) // mov r/m8,r8
    x64MemoryAddress(edit code, src, base, displacement)
}

// Slot accesses within the frame bound of x64MaxFrameSlots (disp32).
expose flow x64LoadSlot(code: edit X64Code, dst: Int, slot: Int) {
    when slot < 0 || slot >= x64MaxFrameSlots() { code.error = 7; give }
    x64LoadMem64(edit code, dst, 5, -8 * (slot + 1))
}

expose flow x64StoreSlot(code: edit X64Code, slot: Int, src: Int) {
    when slot < 0 || slot >= x64MaxFrameSlots() { code.error = 7; give }
    x64StoreMem64(edit code, 5, -8 * (slot + 1), src)
}

expose flow x64TestRax(code: edit X64Code) {
    x64Put(edit code, 72)
    x64Put(edit code, 133)
    x64Put(edit code, 192) // test rax,rax
}

// Setcc AL followed by movzx eax,al. Uses signed comparisons on Int.
// 4 eq, 5 ne, 6 lt, 7 le, 8 gt, 9 ge.
expose flow x64SetCondition(code: edit X64Code, condition: Int) {
    change opcode = 0
    when condition == 4 { opcode = 148 }
    when condition == 5 { opcode = 149 }
    when condition == 6 { opcode = 156 }
    when condition == 7 { opcode = 158 }
    when condition == 8 { opcode = 159 }
    when condition == 9 { opcode = 157 }
    when opcode == 0 { code.error = 8; give }
    x64Put(edit code, 15)
    x64Put(edit code, opcode)
    x64Put(edit code, 192) // AL
    x64Put(edit code, 15)
    x64Put(edit code, 182) // movzx eax,al
    x64Put(edit code, 192)
}

expose flow x64Unreachable(code: edit X64Code) {
    x64Put(edit code, 15)
    x64Put(edit code, 11) // ud2: deterministic invalid-op trap
}

// NEG r/m64 (REX.W F7 /3). Negating the minimum Int leaves the same bit
// pattern, which is its magnitude when read as unsigned.
expose flow x64NegReg(code: edit X64Code, reg: Int) {
    when !x64RegisterValid(reg) { code.error = 3; give }
    change rex = 72
    when reg >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 247)
    x64Put(edit code, 216 + reg % 8)
}

// DIV r/m64 (REX.W F7 /6): unsigned RDX:RAX / reg -> RAX quotient, RDX
// remainder. The caller must zero RDX and guarantee a nonzero divisor.
expose flow x64DivUnsignedReg(code: edit X64Code, reg: Int) {
    when !x64RegisterValid(reg) { code.error = 3; give }
    change rex = 72
    when reg >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 247)
    x64Put(edit code, 240 + reg % 8)
}

// CQO (REX.W 99): sign-extends RAX into RDX before a signed division.
expose flow x64Cqo(code: edit X64Code) {
    x64Put(edit code, 72)
    x64Put(edit code, 153)
}

// IDIV r/m64 (REX.W F7 /7): signed RDX:RAX / reg -> RAX quotient, RDX
// remainder, truncating toward zero. The caller must exclude a zero
// divisor and Int.MIN / -1, which trap in hardware.
expose flow x64IdivReg(code: edit X64Code, reg: Int) {
    when !x64RegisterValid(reg) { code.error = 3; give }
    change rex = 72
    when reg >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 247)
    x64Put(edit code, 248 + reg % 8)
}

// PUSH r64 (50+r, REX.B for R8-R15).
expose flow x64PushReg(code: edit X64Code, reg: Int) {
    when !x64RegisterValid(reg) { code.error = 3; give }
    when reg >= 8 { x64Put(edit code, 65) }
    x64Put(edit code, 80 + reg % 8)
}

// REP MOVSB: copies RCX bytes from [RSI] to [RDI], ascending. The direction
// flag is clear at process entry and this backend never sets it.
expose flow x64RepMovsb(code: edit X64Code) {
    x64Put(edit code, 243)
    x64Put(edit code, 164)
}

// Overwrites the 8-byte immediate of an earlier MOV r64,imm64.
expose flow x64PatchAbsolute64(code: edit X64Code, at: Int, value: Int) {
    when at < 0 || at + 8 > code.bytes.length || value < 0 {
        code.error = 4
        give
    }
    change n = value
    each i among 0..8 {
        code.bytes[at + i] = n % 256
        n = n / 256
    }
}

// ----- Forms used by the Windows x64 (PE32+) target. -----
// None of them is emitted by the ELF64 path, whose images stay unchanged.

// CALL [RIP+disp32] (FF 15): indirect call through an import address table
// slot. Returns the position of the displacement, which the image writer
// patches once the slot's RVA is known. The displacement is relative to the
// end of the instruction, i.e. to the position returned plus 4.
expose flow x64CallRipPlaceholder(code: edit X64Code) => Int {
    x64Put(edit code, 255)
    x64Put(edit code, 21)
    hold at = code.bytes.length
    each i among 0..4 { x64Put(edit code, 0) }
    give at
}

// CALL r64 (FF /2), used for an OS function resolved at runtime.
expose flow x64CallReg(code: edit X64Code, reg: Int) {
    when !x64RegisterValid(reg) { code.error = 3; give }
    when reg >= 8 { x64Put(edit code, 65) }
    x64Put(edit code, 255)
    x64Put(edit code, 208 + reg % 8)
}

// LEA r64,[RIP+disp32] (REX.W 8D, ModRM mod=00 r/m=101). Returns the
// displacement position; it ends the instruction, so x64PatchRelative can
// point it at a later byte of the same code buffer.
expose flow x64LeaRipPlaceholder(code: edit X64Code, dst: Int) => Int {
    when !x64RegisterValid(dst) { code.error = 3; give -1 }
    change rex = 72
    when dst >= 8 { rex += 4 }
    x64Put(edit code, rex)
    x64Put(edit code, 141)
    x64Put(edit code, 5 + (dst % 8) * 8)
    hold at = code.bytes.length
    each i among 0..4 { x64Put(edit code, 0) }
    give at
}

// LEA r64,[base+disp32] (REX.W 8D), e.g. the address of a stack local
// passed by pointer to a Windows API.
expose flow x64LeaMem(code: edit X64Code, dst: Int, base: Int, displacement: Int) {
    when !x64MemoryValid(edit code, dst, base, displacement) { give }
    x64RexRegRm(edit code, dst, base)
    x64Put(edit code, 141)
    x64MemoryAddress(edit code, dst, base, displacement)
}

// TEST EAX,EAX (85 C0): a Win32 BOOL is defined only in its low 32 bits.
expose flow x64TestEax(code: edit X64Code) {
    x64Put(edit code, 133)
    x64Put(edit code, 192)
}
