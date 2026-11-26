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

// MOV r32,imm32 (B8+r): 0 <= value < 2^32, zero-extended into the whole
// 64-bit register. Half the size of x64MovImm64 for small constants.
expose flow x64MovImm32Zx(code: edit X64Code, dst: Int, value: Int) {
    when !x64RegisterValid(dst) { code.error = 3; give }
    when value < 0 || value > 4294967295 { code.error = 2; give }
    when dst >= 8 { x64Put(edit code, 65) }
    x64Put(edit code, 184 + dst % 8)
    change n = value
    each i among 0..4 {
        x64Put(edit code, n % 256)
        n = n / 256
    }
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

// OR r/m64,r64 (REX.W 09 /r): destination is ModRM.r/m.
expose flow x64OrReg(code: edit X64Code, dst: Int, src: Int) {
    when !x64RegisterValid(dst) || !x64RegisterValid(src) { code.error = 3; give }
    x64RexRegRm(edit code, src, dst)
    x64Put(edit code, 9)
    x64ModRmRegisters(edit code, src, dst)
}

// NOT r/m64 (REX.W F7 /2).
expose flow x64NotReg(code: edit X64Code, reg: Int) {
    when !x64RegisterValid(reg) { code.error = 3; give }
    change rex = 72
    when reg >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 247)
    x64Put(edit code, 208 + reg % 8)
}

// SHL r/m64,CL (REX.W D3 /4) or SHR r/m64,CL (REX.W D3 /5): the count is
// in CL and the CPU uses only its low 6 bits.
expose flow x64ShiftClReg(code: edit X64Code, reg: Int, left: Bool) {
    when !x64RegisterValid(reg) { code.error = 3; give }
    change rex = 72
    when reg >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 211)
    x64Put(edit code, selectByte(left, 224, 232) + reg % 8)
}

flow selectByte(cond: Bool, yes: Int, no: Int) => Int {
    when cond { give yes }
    give no
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

// ----- SSE2 scalar double (Float). Float values live in the integer slots
// as their IEEE-754 bit pattern; these forms move them through xmm0..xmm5
// only (xmm6-xmm15 are callee-saved on Win64, so nothing needs saving).

// MOVQ xmm,r64 (66 REX.W 0F 6E /r).
expose flow x64MovqToXmm(code: edit X64Code, xmm: Int, gpr: Int) {
    when !x64RegisterValid(gpr) || xmm < 0 || xmm > 7 { code.error = 3; give }
    x64Put(edit code, 102)
    change rex = 72
    when gpr >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 15)
    x64Put(edit code, 110)
    x64Put(edit code, 192 + xmm * 8 + gpr % 8)
}

// MOVQ r64,xmm (66 REX.W 0F 7E /r).
expose flow x64MovqFromXmm(code: edit X64Code, gpr: Int, xmm: Int) {
    when !x64RegisterValid(gpr) || xmm < 0 || xmm > 7 { code.error = 3; give }
    x64Put(edit code, 102)
    change rex = 72
    when gpr >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 15)
    x64Put(edit code, 126)
    x64Put(edit code, 192 + xmm * 8 + gpr % 8)
}

// Scalar double operation `dst op= src` on xmm registers: 1 addsd,
// 2 subsd, 3 mulsd, 4 divsd (F2 0F 58/5C/59/5E).
expose flow x64SdOp(code: edit X64Code, op: Int, dst: Int, src: Int) {
    when dst < 0 || dst > 7 || src < 0 || src > 7 || op < 1 || op > 4 { code.error = 3; give }
    change opcode = 88
    when op == 2 { opcode = 92 }
    when op == 3 { opcode = 89 }
    when op == 4 { opcode = 94 }
    x64Put(edit code, 242)
    x64Put(edit code, 15)
    x64Put(edit code, opcode)
    x64Put(edit code, 192 + dst * 8 + src)
}

// UCOMISD left,right (66 0F 2E): ZF/PF/CF; unordered sets all three.
expose flow x64Ucomisd(code: edit X64Code, left: Int, right: Int) {
    when left < 0 || left > 7 || right < 0 || right > 7 { code.error = 3; give }
    x64Put(edit code, 102)
    x64Put(edit code, 15)
    x64Put(edit code, 46)
    x64Put(edit code, 192 + left * 8 + right)
}

// CVTSI2SD xmm,r64 (F2 REX.W 0F 2A /r).
expose flow x64Cvtsi2sd(code: edit X64Code, xmm: Int, gpr: Int) {
    when !x64RegisterValid(gpr) || xmm < 0 || xmm > 7 { code.error = 3; give }
    x64Put(edit code, 242)
    change rex = 72
    when gpr >= 8 { rex += 1 }
    x64Put(edit code, rex)
    x64Put(edit code, 15)
    x64Put(edit code, 42)
    x64Put(edit code, 192 + xmm * 8 + gpr % 8)
}

// CVTTSD2SI r64,xmm (F2 REX.W 0F 2C /r): truncates toward zero; NaN and
// out-of-range give 0x8000000000000000 ("integer indefinite").
expose flow x64Cvttsd2si(code: edit X64Code, gpr: Int, xmm: Int) {
    when !x64RegisterValid(gpr) || xmm < 0 || xmm > 7 { code.error = 3; give }
    x64Put(edit code, 242)
    change rex = 72
    when gpr >= 8 { rex += 4 }
    x64Put(edit code, rex)
    x64Put(edit code, 15)
    x64Put(edit code, 44)
    x64Put(edit code, 192 + (gpr % 8) * 8 + xmm)
}

// XOR r/m64,r64 (REX.W 31 /r).
expose flow x64XorReg(code: edit X64Code, dst: Int, src: Int) {
    when !x64RegisterValid(dst) || !x64RegisterValid(src) { code.error = 3; give }
    x64RexRegRm(edit code, src, dst)
    x64Put(edit code, 49)
    x64ModRmRegisters(edit code, src, dst)
}

// Jcc rel32 (0F 80+cc) with a placeholder; cc: 2 B, 3 AE, 4 E, 5 NE,
// 6 BE, 7 A, 10 P, 11 NP, 12 L, 13 GE, 14 LE, 15 G.
expose flow x64JccPlaceholder(code: edit X64Code, cc: Int) => Int {
    x64Put(edit code, 15)
    x64Put(edit code, 128 + cc)
    hold at = code.bytes.length
    each i among 0..4 { x64Put(edit code, 0) }
    give at
}

// Points a placeholder at the current end of the code.
expose flow x64PatchHere(code: edit X64Code, at: Int) {
    hold here = code.bytes.length
    x64PatchRelative(edit code, at, here)
}

// RAX = 0/1 from the flags of `ucomisd`: 4 equal (ordered), 5 not equal
// (true for NaN), 7 above, 3 above-or-equal (both false when unordered).
expose flow x64SetFloatFlag(code: edit X64Code, kind: Int) {
    when kind == 4 {
        x64Put(edit code, 15)
        x64Put(edit code, 148)
        x64Put(edit code, 192) // sete al
        x64Put(edit code, 15)
        x64Put(edit code, 155)
        x64Put(edit code, 193) // setnp cl
        x64Put(edit code, 32)
        x64Put(edit code, 200) // and al,cl
    } otherwise when kind == 5 {
        x64Put(edit code, 15)
        x64Put(edit code, 149)
        x64Put(edit code, 192) // setne al
        x64Put(edit code, 15)
        x64Put(edit code, 154)
        x64Put(edit code, 193) // setp cl
        x64Put(edit code, 8)
        x64Put(edit code, 200) // or al,cl
    } otherwise when kind == 7 {
        x64Put(edit code, 15)
        x64Put(edit code, 151)
        x64Put(edit code, 192) // seta al
    } otherwise when kind == 3 {
        x64Put(edit code, 15)
        x64Put(edit code, 147)
        x64Put(edit code, 192) // setae al
    } otherwise {
        code.error = 8
        give
    }
    x64Put(edit code, 15)
    x64Put(edit code, 182)
    x64Put(edit code, 192) // movzx eax,al
}

// RAX = Int(xmm0): truncates toward zero and saturates; NaN gives 0
// (Stage 0 fcvt_to_sint_sat). Clobbers RCX and xmm1.
expose flow x64SaturatingFloatToInt(code: edit X64Code) {
    x64Cvttsd2si(edit code, 0, 0)
    x64MovImm64(edit code, 1, -9223372036854775807 - 1)
    x64CmpReg(edit code, 0, 1)
    hold done_plain = x64JccPlaceholder(edit code, 5)
    x64Ucomisd(edit code, 0, 0)
    hold is_nan = x64JccPlaceholder(edit code, 10)
    x64MovImm64(edit code, 1, 0)
    x64Cvtsi2sd(edit code, 1, 1)
    x64Ucomisd(edit code, 0, 1)
    hold not_positive = x64JccPlaceholder(edit code, 6)
    x64MovImm64(edit code, 0, 9223372036854775807)
    hold done_max = x64JumpPlaceholder(edit code)
    x64PatchHere(edit code, is_nan)
    x64MovImm64(edit code, 0, 0)
    x64PatchHere(edit code, done_plain)
    x64PatchHere(edit code, not_positive)
    x64PatchHere(edit code, done_max)
}

// ---- Privileged and port instructions (kernel intrinsics) ----------------

// HLT (F4).
expose flow x64Hlt(code: edit X64Code) { x64Put(edit code, 244) }
// CLI (FA).
expose flow x64Cli(code: edit X64Code) { x64Put(edit code, 250) }
// STI (FB).
expose flow x64Sti(code: edit X64Code) { x64Put(edit code, 251) }
// PAUSE (F3 90).
expose flow x64Pause(code: edit X64Code) {
    x64Put(edit code, 243)
    x64Put(edit code, 144)
}

// CLI; HLT; JMP back to the HLT (FA F4 EB FD): stops this CPU for good;
// an NMI resumes into the HLT again.
expose flow x64HaltForever(code: edit X64Code) {
    x64Put(edit code, 250)
    x64Put(edit code, 244)
    x64Put(edit code, 235)
    x64Put(edit code, 253)
}

// RAX = zero-extended IN from port DX: XOR EAX,EAX (31 C0), then
// IN AL,DX (EC), IN AX,DX (66 ED) or IN EAX,DX (ED).
expose flow x64InDx(code: edit X64Code, width: Int) {
    x64Put(edit code, 49)
    x64Put(edit code, 192)
    when width == 1 {
        x64Put(edit code, 236)
    } otherwise {
        when width == 2 { x64Put(edit code, 102) }
        x64Put(edit code, 237)
    }
}

// OUT DX,AL (EE), OUT DX,AX (66 EF) or OUT DX,EAX (EF).
expose flow x64OutDx(code: edit X64Code, width: Int) {
    when width == 1 {
        x64Put(edit code, 238)
    } otherwise {
        when width == 2 { x64Put(edit code, 102) }
        x64Put(edit code, 239)
    }
}

// RAX = zero-extended [RAX]: MOVZX RAX,BYTE (48 0F B6 00), MOVZX RAX,WORD
// (48 0F B7 00), MOV EAX,[RAX] (8B 00) or MOV RAX,[RAX] (48 8B 00).
expose flow x64LoadRaxWidth(code: edit X64Code, width: Int) {
    when width == 1 || width == 2 {
        x64Put(edit code, 72)
        x64Put(edit code, 15)
        when width == 1 { x64Put(edit code, 182) } otherwise { x64Put(edit code, 183) }
        x64Put(edit code, 0)
        give
    }
    when width == 8 { x64Put(edit code, 72) }
    x64Put(edit code, 139)
    x64Put(edit code, 0)
}

// [RAX] = low bytes of RCX: MOV [RAX],CL (88 08), MOV [RAX],CX (66 89 08),
// MOV [RAX],ECX (89 08) or MOV [RAX],RCX (48 89 08).
expose flow x64StoreRcxWidth(code: edit X64Code, width: Int) {
    when width == 1 {
        x64Put(edit code, 136)
        x64Put(edit code, 8)
        give
    }
    when width == 2 { x64Put(edit code, 102) }
    when width == 8 { x64Put(edit code, 72) }
    x64Put(edit code, 137)
    x64Put(edit code, 8)
}

// Like x64PatchAbsolute64, for any 64-bit address including the negative
// Int of a higher-half one (0xFFFFFFFF80000000 = -2147483648).
expose flow x64PatchAddress64(code: edit X64Code, at: Int, value: Int) {
    when at < 0 || at + 8 > code.bytes.length {
        code.error = 4
        give
    }
    change n = value
    each i among 0..8 {
        change b = n % 256
        when b < 0 { b += 256 }
        code.bytes[at + i] = b
        n = (n - b) / 256
    }
}

// ---- System instructions (kernel intrinsics, part 2) ---------------------

flow x64Bytes2(code: edit X64Code, a: Int, b: Int) {
    x64Put(edit code, a)
    x64Put(edit code, b)
}

flow x64Bytes3(code: edit X64Code, a: Int, b: Int, c: Int) {
    x64Put(edit code, a)
    x64Put(edit code, b)
    x64Put(edit code, c)
}

flow x64Bytes4(code: edit X64Code, a: Int, b: Int, c: Int, d: Int) {
    x64Bytes2(edit code, a, b)
    x64Bytes2(edit code, c, d)
}

// RAX = RDX:EAX: SHL RDX,32 (48 C1 E2 20); MOV EAX,EAX (89 C0); OR RAX,RDX
// (48 09 D0).
flow x64JoinEdxEax(code: edit X64Code) {
    x64Bytes4(edit code, 72, 193, 226, 32)
    x64Bytes2(edit code, 137, 192)
    x64Bytes3(edit code, 72, 9, 208)
}

// CPUID with EAX = leaf, ECX = subleaf; R8 = output address. RBX is saved
// around it (PUSH RBX 53 / POP RBX 5B). Stores EAX, EBX, ECX, EDX as four
// u32: MOV [R8],EAX (41 89 00), [R8+4],EBX (41 89 58 04),
// [R8+8],ECX (41 89 48 08), [R8+12],EDX (41 89 50 0C).
expose flow x64CpuidToR8(code: edit X64Code) {
    x64Put(edit code, 83)
    x64Bytes2(edit code, 15, 162)
    x64Bytes3(edit code, 65, 137, 0)
    x64Bytes4(edit code, 65, 137, 88, 4)
    x64Bytes4(edit code, 65, 137, 72, 8)
    x64Bytes4(edit code, 65, 137, 80, 12)
    x64Put(edit code, 91)
}

// RDTSC (0F 31), RAX = 64-bit counter.
expose flow x64Rdtsc(code: edit X64Code) {
    x64Bytes2(edit code, 15, 49)
    x64JoinEdxEax(edit code)
}

// RAX = MSR[RAX]: MOV RCX,RAX (48 89 C1); RDMSR (0F 32).
expose flow x64Rdmsr(code: edit X64Code) {
    x64Bytes3(edit code, 72, 137, 193)
    x64Bytes2(edit code, 15, 50)
    x64JoinEdxEax(edit code)
}

// MSR[RAX] = RCX: MOV RDX,RCX (48 89 CA); MOV RCX,RAX (48 89 C1);
// MOV RAX,RDX (48 89 D0); SHR RDX,32 (48 C1 EA 20); WRMSR (0F 30).
expose flow x64Wrmsr(code: edit X64Code) {
    x64Bytes3(edit code, 72, 137, 202)
    x64Bytes3(edit code, 72, 137, 193)
    x64Bytes3(edit code, 72, 137, 208)
    x64Bytes4(edit code, 72, 193, 234, 32)
    x64Bytes2(edit code, 15, 48)
}

// Control register number of index 0..3 of leerCr0/2/3/4 (RAX = CRn:
// 0F 20 /r with mod 11, reg = n, rm = RAX).
flow x64CrNumber(index: Int) => Int {
    when index == 0 { give 0 }
    when index == 1 { give 2 }
    when index == 2 { give 3 }
    give 4
}

expose flow x64ReadCr(code: edit X64Code, index: Int) {
    x64Bytes3(edit code, 15, 32, 192 + 8 * x64CrNumber(index))
}

// CRn = RAX for escribirCr0/3/4 (index 0, 1, 2): 0F 22 /r.
expose flow x64WriteCr(code: edit X64Code, index: Int) {
    change n = 0
    when index == 1 { n = 3 }
    when index == 2 { n = 4 }
    x64Bytes3(edit code, 15, 34, 192 + 8 * n)
}

// 0F 01 /n with [RAX]: /2 LGDT, /3 LIDT, /7 INVLPG.
expose flow x64DescriptorOp(code: edit X64Code, reg: Int) {
    x64Bytes3(edit code, 15, 1, 8 * reg)
}

// LTR AX (0F 00 D8).
expose flow x64Ltr(code: edit X64Code) {
    x64Bytes3(edit code, 15, 0, 216)
}

// FXSAVE64 [RAX] (48 0F AE 00) or FXRSTOR64 [RAX] (48 0F AE 08).
expose flow x64Fxsave(code: edit X64Code, restore: Bool) {
    change modrm = 0
    when restore { modrm = 8 }
    x64Bytes4(edit code, 72, 15, 174, modrm)
}

// WBINVD (0F 09).
expose flow x64Wbinvd(code: edit X64Code) {
    x64Bytes2(edit code, 15, 9)
}

// REX prefix for SSE forms with ModRM.reg = `reg` and ModRM.rm = `rm`,
// only when one of them is XMM8..XMM15.
flow x64SseRex(code: edit X64Code, reg: Int, rm: Int) {
    change rex = 64
    when reg >= 8 { rex += 4 }
    when rm >= 8 { rex += 1 }
    when rex != 64 { x64Put(edit code, rex) }
}

// Register-register packed single: 0F <opcode> /r with mod 11 (MOVAPS 28,
// ADDPS 58, MULPS 59, XORPS 57).
expose flow x64SsePacked(code: edit X64Code, opcode: Int, dst: Int, src: Int) {
    x64SseRex(edit code, dst, src)
    x64Put(edit code, 15)
    x64Put(edit code, opcode)
    x64Put(edit code, 192 + (dst % 8) * 8 + src % 8)
}

// [RAX] form: MOVUPS xmm,[RAX] (0F 10), MOVUPS [RAX],xmm (0F 11), or with
// `scalar` MOVSS xmm,[RAX] (F3 0F 10).
expose flow x64SseMemory(code: edit X64Code, scalar: Bool, opcode: Int, xmm: Int) {
    when scalar { x64Put(edit code, 243) }
    x64SseRex(edit code, xmm, 0)
    x64Put(edit code, 15)
    x64Put(edit code, opcode)
    x64Put(edit code, (xmm % 8) * 8)
}

// SHUFPS xmm,xmm,0 (0F C6 /r 00): lane 0 to all four lanes.
expose flow x64Shufps0(code: edit X64Code, xmm: Int) {
    x64SseRex(edit code, xmm, xmm)
    x64Put(edit code, 15)
    x64Put(edit code, 198)
    x64Put(edit code, 192 + (xmm % 8) * 9)
    x64Put(edit code, 0)
}

// acc += factor * [RAX + disp] through XMM0: MOVUPS XMM0,[RAX+disp32]
// (0F 10 80 disp32); MULPS XMM0,factor (0F 59 /r); ADDPS acc,XMM0
// (0F 58 /r). XMM0 holds no value between statements (Float keeps its
// values in stack slots), so using it here is safe.
expose flow x64MulAddFromRax(code: edit X64Code, acc: Int, factor: Int, disp: Int) {
    x64Put(edit code, 15)
    x64Put(edit code, 16)
    x64Put(edit code, 128)
    x64PutSigned(edit code, disp, 4)
    x64SsePacked(edit code, 89, 0, factor)
    x64SsePacked(edit code, 88, acc, 0)
}

// xmm = [RAX + disp] in all four lanes: MOVSS xmm,[RAX+disp32]
// (F3 0F 10 /r, mod 10) then SHUFPS xmm,xmm,0.
expose flow x64BroadcastFromRax(code: edit X64Code, xmm: Int, disp: Int) {
    x64Put(edit code, 243)
    x64SseRex(edit code, xmm, 0)
    x64Put(edit code, 15)
    x64Put(edit code, 16)
    x64Put(edit code, 128 + (xmm % 8) * 8)
    x64PutSigned(edit code, disp, 4)
    x64Shufps0(edit code, xmm)
}

// MOV RAX,RSP (48 89 E0).
expose flow x64ReadRsp(code: edit X64Code) {
    x64Put(edit code, 72)
    x64Put(edit code, 137)
    x64Put(edit code, 224)
}

// INT3 (CC).
expose flow x64Int3(code: edit X64Code) { x64Put(edit code, 204) }

// PUSHFQ; POP RAX (9C 58).
expose flow x64ReadFlags(code: edit X64Code) {
    x64Bytes2(edit code, 156, 88)
}

// After LGDT: DS=ES=SS=FS=GS=CX (8E D9, 8E C1, 8E D1, 8E E1, 8E E9), then
// a far return to CS=AX: PUSH RAX (50); LEA RDX,[RIP+3] (48 8D 15 03 00 00
// 00); PUSH RDX (52); RETFQ (48 CB).
expose flow x64ReloadSegments(code: edit X64Code) {
    x64Bytes2(edit code, 142, 217)
    x64Bytes2(edit code, 142, 193)
    x64Bytes2(edit code, 142, 209)
    x64Bytes2(edit code, 142, 225)
    x64Bytes2(edit code, 142, 233)
    x64Put(edit code, 80)
    x64Bytes3(edit code, 72, 141, 21)
    x64Bytes4(edit code, 3, 0, 0, 0)
    x64Put(edit code, 82)
    x64Bytes2(edit code, 72, 203)
}

// RAX = RAX * 12 + RCX: IMUL RAX,RAX,12 (48 6B C0 0C); ADD RAX,RCX
// (48 01 C8).
expose flow x64IsrStubAddress(code: edit X64Code) {
    x64Bytes4(edit code, 72, 107, 192, 12)
    x64Bytes3(edit code, 72, 1, 200)
}

// Whether the CPU pushes an error code for exception `vector`.
flow x64VectorHasError(vector: Int) => Bool {
    give vector == 8 || (vector >= 10 && vector <= 14) || vector == 17 || vector == 21 || vector == 29 || vector == 30
}

// 256 interrupt stubs of 12 bytes each (stub v at table + 12 * v): a zero
// error code where the CPU pushes none (6A 00, else 66 90), PUSH vector
// (68 imm32), JMP to the common entry (E9 rel32). Returns the common
// entry's JMP placeholders' target: the caller emits it next.
expose flow x64EmitIsrStubs(code: edit X64Code) => List of[Int] {
    change jumps: List of[Int] = List[]
    each v among 0..256 {
        when x64VectorHasError(v) {
            x64Bytes2(edit code, 102, 144)
        } otherwise {
            x64Bytes2(edit code, 106, 0)
        }
        x64Put(edit code, 104)
        x64PutSigned(edit code, v, 4)
        jumps@push(x64JumpPlaceholder(edit code))
    }
    give jumps
}

// Common interrupt entry: CLD; push the 15 general registers (RAX first,
// R15 last); push RSP (the frame address) as the only argument of the
// handler flow; CALL it (placeholder returned); drop the argument; pop the
// registers; drop vector and error code; IRETQ. Frame layout (offsets in
// the address the handler receives): 0 R15 .. 56 R8, 64 RDI, 72 RSI,
// 80 RBP, 88 RBX, 96 RDX, 104 RCX, 112 RAX, 120 vector, 128 error code,
// 136 RIP, 144 CS, 152 RFLAGS, 160 RSP, 168 SS.
expose flow x64EmitIsrCommon(code: edit X64Code) => Int {
    x64Put(edit code, 252)
    hold order: List of[Int] = List[0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    each i among 0..15 { x64PushReg(edit code, order[i]) }
    x64Bytes3(edit code, 72, 137, 224)
    x64PushReg(edit code, 0)
    hold call = x64CallPlaceholder(edit code)
    x64Bytes4(edit code, 72, 131, 196, 8)
    each i among 0..15 { x64PopReg(edit code, order[14 - i]) }
    x64Bytes4(edit code, 72, 131, 196, 16)
    x64Bytes2(edit code, 72, 207)
    give call
}

// POP r64 (58+r, REX.B for R8..R15).
expose flow x64PopReg(code: edit X64Code, reg: Int) {
    when reg >= 8 { x64Put(edit code, 65) }
    x64Put(edit code, 88 + reg % 8)
}
