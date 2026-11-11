import native_cfg_defs
import native_cfg_types
import x86_64
import native_rt

// Shared lowering helpers of the CFG backend and the lowering of Text:
// literals, owned buffers, print, append and drop.

// Stack locations are assigned per variable from the actual ELE-LIR type.
// Aggregate addresses point to the lowest address within the allocated slots;
// every direct primitive field is accessed using its calculated byte offset.
pub fn cfgFrameSlots(p: &CfgProgram, f: Int) -> Int {
    let func = &p.functions[f]
    if func.vars == 0 { return 0 }
    let last = func.first_var + func.vars - 1
    return p.slot_start[last] + p.slot_count[last]
}

pub fn cfgVarIndex(p: &CfgProgram, f: Int, variable: Int) -> Int {
    return p.functions[f].first_var + variable
}

pub fn cfgVarBase(p: &CfgProgram, f: Int, variable: Int) -> Int {
    let index = cfgVarIndex(p, f, variable)
    return -8 * (p.slot_start[index] + p.slot_count[index])
}

pub fn cfgLoadOperand(code: &mut X64Code, p: &CfgProgram, f: Int, op: &NativeOperand, dst: Int) {
    if op.is_var {
        x64LoadSlot(&mut code, dst, p.slot_start[cfgVarIndex(p, f, op.value)])
    } else {
        x64MovImm64(&mut code, dst, op.value)
    }
}

// Fixups collected while emitting and resolved once every address is known.
// Call targets >= 0 are functions; target -(k+1) is runtime routine k.
pub struct CfgFix {
    call_at: List<Int>
    call_to: List<Int>
    jump_at: List<Int>
    jump_to: List<Int>
    overflow_at: List<Int>
    bad_variant_at: List<Int>
    text_at: List<Int>
    text_id: List<Int>
}

pub fn cfgCall(code: &mut X64Code, fix: &mut CfgFix, target: Int) {
    fix.call_at.push(x64CallPlaceholder(&mut code))
    fix.call_to.push(target)
}

pub fn cfgRuntimeCall(code: &mut X64Code, fix: &mut CfgFix, routine: Int) {
    cfgCall(&mut code, &mut fix, -1 - routine)
}

// Loads a Text operand as RAX = address, RDX = byte length, RCX = capacity.
// A literal gets capacity 0 and an address patched in after layout.
pub fn cfgTextWords(code: &mut X64Code, p: &CfgProgram, f: Int, op: &NativeOperand, fix: &mut CfgFix) {
    if op.is_var {
        let base = cfgVarBase(p, f, op.value)
        x64LoadMem64(&mut code, 0, 5, base)
        x64LoadMem64(&mut code, 2, 5, base + 8)
        x64LoadMem64(&mut code, 1, 5, base + 16)
    } else {
        x64MovImm64(&mut code, 0, 0)
        fix.text_at.push(code.bytes.length - 8)
        fix.text_id.push(op.value)
        x64MovImm64(&mut code, 2, p.text_length[op.value])
        x64MovImm64(&mut code, 1, 0)
    }
}

// Stores RAX, RDX, RCX as the three words of a Text variable.
pub fn cfgStoreText(code: &mut X64Code, p: &CfgProgram, f: Int, variable: Int) {
    let base = cfgVarBase(p, f, variable)
    x64StoreMem64(&mut code, 5, base, 0)
    x64StoreMem64(&mut code, 5, base + 8, 2)
    x64StoreMem64(&mut code, 5, base + 16, 1)
}

// RDI = address of a variable's storage.
fn cfgVarAddress(code: &mut X64Code, p: &CfgProgram, f: Int, variable: Int) {
    x64MovReg(&mut code, 7, 5)
    x64MovImm64(&mut code, 10, cfgVarBase(p, f, variable))
    x64AddReg(&mut code, 7, 10)
}

// Type and operand of the source of `print`/`append`: the referenced
// variable when `inst.op` names one, otherwise operand `a`.
fn cfgSourceOperand(inst: &CfgInst) -> NativeOperand {
    if inst.op >= 0 {
        return NativeOperand(is_var: true, value: inst.op, is_bool: false, is_unit: false, is_text: false)
    }
    return NativeOperand(is_var: inst.a.is_var, value: inst.a.value, is_bool: inst.a.is_bool, is_unit: inst.a.is_unit, is_text: inst.a.is_text)
}

pub fn cfgEmitText(code: &mut X64Code, p: &CfgProgram, f: Int, inst: &CfgInst, fix: &mut CfgFix) {
    if inst.kind == 10 {
        let value = cfgSourceOperand(inst)
        let ty = cfgOperandType(p, f, &value)
        if ty == cfgTextType() {
            cfgTextWords(&mut code, p, f, &value, &mut fix)
            x64MovReg(&mut code, 7, 0)
            x64MovReg(&mut code, 6, 2)
            cfgRuntimeCall(&mut code, &mut fix, rtPrintText())
        } else {
            cfgLoadOperand(&mut code, p, f, &value, 7)
            if ty == 1 {
                cfgRuntimeCall(&mut code, &mut fix, rtPrintBool())
            } else {
                cfgRuntimeCall(&mut code, &mut fix, rtPrintInt())
            }
        }
    } else if inst.kind == 11 {
        x64MovImm64(&mut code, 7, inst.callee)
        cfgRuntimeCall(&mut code, &mut fix, rtTextNew())
        // text_new returns RAX = address, RDX = capacity; length starts at 0.
        x64MovReg(&mut code, 1, 2)
        x64MovImm64(&mut code, 2, 0)
        cfgStoreText(&mut code, p, f, inst.dst)
    } else if inst.kind == 12 {
        let value = cfgSourceOperand(inst)
        let ty = cfgOperandType(p, f, &value)
        if ty == cfgTextType() {
            cfgTextWords(&mut code, p, f, &value, &mut fix)
            x64MovReg(&mut code, 6, 0)
            cfgVarAddress(&mut code, p, f, inst.place_var)
            cfgRuntimeCall(&mut code, &mut fix, rtTextAppend())
        } else {
            cfgLoadOperand(&mut code, p, f, &value, 6)
            cfgVarAddress(&mut code, p, f, inst.place_var)
            if ty == 1 {
                cfgRuntimeCall(&mut code, &mut fix, rtAppendBool())
            } else {
                cfgRuntimeCall(&mut code, &mut fix, rtAppendInt())
            }
        }
    } else if inst.kind == 13 {
        var skip = -1
        if inst.op >= 0 {
            x64LoadSlot(&mut code, 0, p.slot_start[cfgVarIndex(p, f, inst.op)])
            x64TestRax(&mut code)
            skip = x64ConditionalPlaceholder(&mut code, true)
        }
        let base = cfgVarBase(p, f, inst.place_var)
        x64LoadMem64(&mut code, 7, 5, base)
        x64LoadMem64(&mut code, 6, 5, base + 16)
        cfgRuntimeCall(&mut code, &mut fix, rtTextDrop())
        if skip >= 0 { x64PatchRelative(&mut code, skip, code.bytes.length) }
    } else {
        code.error = 10
    }
}
