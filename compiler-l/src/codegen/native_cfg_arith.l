take lir_tokens
take native_cfg_defs
take native_cfg_types
take native_cfg_text
take x86_64

// Unary operators and checked division of the ELE-written CFG backend.
//
// `i unary vD neg <op>` (Int) and `i unary vD not <op>` (Bool) are kind 16
// with `op` 1 (neg) or 2 (not). Division (binary op 10) and remainder
// (binary op 11) truncate toward zero like Stage 0. As in Stage 0, a zero
// divisor, `Int.MIN / -1`, `Int.MIN % -1` and `-Int.MIN` are the same
// arithmetic failure as an overflow: the program exits with status 125.

expose flow cfgReadUnary(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst) {
    inst.kind = 16
    inst.dst = nativeId(source, edit reader, 118)
    hold name = nativeWord(source, edit reader)
    when nativeEquals(source, view name, "neg") { inst.op = 1 }
    when nativeEquals(source, view name, "not") { inst.op = 2 }
    when nativeEquals(source, view name, "itof") { inst.op = 3 }
    when nativeEquals(source, view name, "ftoi") { inst.op = 4 }
    inst.a = nativeOperand(source, edit reader)
}

// Neg takes and gives Int; not takes and gives Bool.
expose flow cfgCheckUnary(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold dest = p.types_code[p.functions[f].first_var + inst.dst]
    hold operand = cfgOperandType(p, f, view inst.a)
    when inst.op == 1 && dest == 0 && operand == 0 { give 0 }
    when inst.op == 2 && dest == 1 && operand == 1 { give 0 }
    when inst.op == 1 && dest == cfgFloatType() && operand == cfgFloatType() { give 0 }
    when inst.op == 3 && dest == cfgFloatType() && operand == 0 { give 0 }
    when inst.op == 4 && dest == 0 && operand == cfgFloatType() { give 0 }
    give 36
}

// Jumps to the arithmetic failure when RCX equals `value`.
flow cfgTrapIfRcx(code: edit X64Code, fix: edit CfgFix, value: Int) {
    x64MovImm64(edit code, 10, value)
    x64CmpReg(edit code, 1, 10)
    fix.overflow_at@push(x64ConditionalPlaceholder(edit code, true))
}

// RAX = RAX / RCX (op 10) or RAX % RCX (op 11), checked.
expose flow cfgEmitDivRem(code: edit X64Code, fix: edit CfgFix, op: Int) {
    cfgTrapIfRcx(edit code, edit fix, 0)
    // Only Int.MIN / -1 overflows: skip the second test unless RCX is -1.
    x64MovImm64(edit code, 10, -1)
    x64CmpReg(edit code, 1, 10)
    hold not_minus_one = x64ConditionalPlaceholder(edit code, false)
    x64MovImm64(edit code, 10, -9223372036854775807 - 1)
    x64CmpReg(edit code, 0, 10)
    fix.overflow_at@push(x64ConditionalPlaceholder(edit code, true))
    hold after_overflow_check = code.bytes.length
    x64PatchRelative(edit code, not_minus_one, after_overflow_check)
    x64Cqo(edit code)
    x64IdivReg(edit code, 1)
    when op == 11 { x64MovReg(edit code, 0, 2) }
}

// Float binary operation or comparison on bit patterns. Arithmetic never
// traps (IEEE: x / 0 is inf or NaN). Comparisons are ordered: any compare
// with NaN is false except `!=`, which is true. Only xmm0/xmm1 are used.
expose flow cfgEmitFloatBinary(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst) {
    cfgLoadOperand(edit code, p, f, view inst.a, 0)
    cfgLoadOperand(edit code, p, f, view inst.b, 1)
    x64MovqToXmm(edit code, 0, 0)
    x64MovqToXmm(edit code, 1, 1)
    when inst.op >= 1 && inst.op <= 3 {
        x64SdOp(edit code, inst.op, 0, 1)
        x64MovqFromXmm(edit code, 0, 0)
    } otherwise when inst.op == 10 {
        x64SdOp(edit code, 4, 0, 1)
        x64MovqFromXmm(edit code, 0, 0)
    } otherwise when inst.op == 4 || inst.op == 5 {
        x64Ucomisd(edit code, 0, 1)
        x64SetFloatFlag(edit code, inst.op)
    } otherwise when inst.op == 6 || inst.op == 7 {
        // a < b is b > a and a <= b is b >= a: unordered stays false.
        x64Ucomisd(edit code, 1, 0)
        when inst.op == 6 { x64SetFloatFlag(edit code, 7) } otherwise { x64SetFloatFlag(edit code, 3) }
    } otherwise {
        x64Ucomisd(edit code, 0, 1)
        when inst.op == 8 { x64SetFloatFlag(edit code, 7) } otherwise { x64SetFloatFlag(edit code, 3) }
    }
    x64StoreSlot(edit code, p.slot_start[p.functions[f].first_var + inst.dst], 0)
}

expose flow cfgEmitUnary(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    cfgLoadOperand(edit code, p, f, view inst.a, 0)
    when inst.op == 1 && cfgOperandType(p, f, view inst.a) == cfgFloatType() {
        // Sign flip: -0.0 and NaN included, no trap.
        x64MovImm64(edit code, 1, -9223372036854775807 - 1)
        x64XorReg(edit code, 0, 1)
    } otherwise when inst.op == 3 {
        x64Cvtsi2sd(edit code, 0, 0)
        x64MovqFromXmm(edit code, 0, 0)
    } otherwise when inst.op == 4 {
        x64MovqToXmm(edit code, 0, 0)
        x64SaturatingFloatToInt(edit code)
    } otherwise when inst.op == 1 {
        // NEG sets OF exactly for Int.MIN.
        x64NegReg(edit code, 0)
        fix.overflow_at@push(x64OverflowPlaceholder(edit code))
    } otherwise {
        // Bool is 0 or 1: not b = 1 - b.
        x64MovImm64(edit code, 10, 1)
        x64SubReg(edit code, 10, 0)
        x64MovReg(edit code, 0, 10)
    }
    x64StoreSlot(edit code, p.slot_start[p.functions[f].first_var + inst.dst], 0)
}
