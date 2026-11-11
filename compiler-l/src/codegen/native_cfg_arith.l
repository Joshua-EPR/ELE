import lir_tokens
import native_cfg_defs
import native_cfg_types
import native_cfg_text
import x86_64

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
    inst.a = nativeOperand(source, edit reader)
}

// Neg takes and gives Int; not takes and gives Bool.
expose flow cfgCheckUnary(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold dest = p.types_code[p.functions[f].first_var + inst.dst]
    hold operand = cfgOperandType(p, f, view inst.a)
    when inst.op == 1 && dest == 0 && operand == 0 { give 0 }
    when inst.op == 2 && dest == 1 && operand == 1 { give 0 }
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
    x64PatchRelative(edit code, not_minus_one, code.bytes.length)
    x64Cqo(edit code)
    x64IdivReg(edit code, 1)
    when op == 11 { x64MovReg(edit code, 0, 2) }
}

expose flow cfgEmitUnary(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    cfgLoadOperand(edit code, p, f, view inst.a, 0)
    when inst.op == 1 {
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
