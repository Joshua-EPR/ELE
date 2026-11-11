import native_cfg_defs
import native_cfg_types
import x86_64
import native_rt
import native_rt_list

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

pub struct CfgAddr {
    base: Int
    disp: Int
}

// Byte offset of a place inside the storage of its root (the referent when
// the root is a reference). Field -1 is the whole root.
fn cfgPlaceRel(p: &CfgProgram, f: Int, variable: Int, field: Int, subfield: Int) -> Int {
    if field < 0 { return 0 }
    let ty = p.types_code[cfgVarIndex(p, f, variable)]
    let member = p.structs[ty - 2].first_field + field
    let offset = p.fields[member].offset
    if subfield < 0 { return offset }
    let child = p.fields[member].ty
    return offset + p.fields[p.structs[child - 2].first_field + subfield].offset
}

// Base register and displacement of a place. A reference root loads the
// referent's address into R11, and so does every index of the extension
// `ext` (-1 when the place has none): the index is checked unsigned against
// the length of the list, so a negative or too large one leaves through
// exit 127 before any element is touched. Only R8-R11 are clobbered;
// callers access memory before any other code could reuse R11.
pub fn cfgPlaceAddr(code: &mut X64Code, p: &CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, ext: Int, fix: &mut CfgFix) -> CfgAddr {
    let rel = cfgPlaceRel(p, f, variable, field, subfield)
    let index = cfgVarIndex(p, f, variable)
    var base = 5
    var disp = cfgVarBase(p, f, variable) + rel
    if p.var_ref[index] {
        x64LoadSlot(&mut code, 11, p.slot_start[index])
        base = 11
        disp = rel
    }
    if ext < 0 { return CfgAddr(base: base, disp: disp) }
    let prefix = CfgPlace(variable: variable, field: field, subfield: subfield, ext: -1)
    var ty = cfgPlaceType(p, f, &prefix)
    let first = p.ext_first[ext]
    for n in first..(first + p.ext_count[ext]) {
        if p.proj_kind[n] == 1 {
            let list = cfgListIndex(p, ty)
            if list < 0 { code.error = 14; break }
            let elem = p.list_elem[list]
            x64LoadMem64(&mut code, 9, base, disp)
            x64LoadMem64(&mut code, 8, base, disp + 8)
            x64LoadSlot(&mut code, 10, p.slot_start[cfgVarIndex(p, f, p.proj_value[n])])
            x64CmpReg(&mut code, 10, 8)
            fix.bad_index_at.push(x64AboveEqualPlaceholder(&mut code))
            x64MovImm64(&mut code, 8, cfgTypeSize(p, elem))
            x64MulReg(&mut code, 10, 8)
            x64MovReg(&mut code, 11, 9)
            x64AddReg(&mut code, 11, 10)
            base = 11
            disp = 0
            ty = elem
        } else {
            if ty < 2 || ty - 2 >= p.structs.length { code.error = 14; break }
            let member = p.structs[ty - 2].first_field + p.proj_value[n]
            disp += p.fields[member].offset
            ty = p.fields[member].ty
        }
    }
    return CfgAddr(base: base, disp: disp)
}

// RAX = address of a place.
pub fn cfgPlaceAddressRax(code: &mut X64Code, p: &CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, ext: Int, fix: &mut CfgFix) {
    let at = cfgPlaceAddr(&mut code, p, f, variable, field, subfield, ext, &mut fix)
    x64MovReg(&mut code, 0, at.base)
    x64MovImm64(&mut code, 10, at.disp)
    x64AddReg(&mut code, 0, 10)
}

// Loads a primitive place (Bool as one byte, Int as eight) into `dst`.
pub fn cfgLoadPlace(code: &mut X64Code, p: &CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, ext: Int, ty: Int, dst: Int, fix: &mut CfgFix) {
    let at = cfgPlaceAddr(&mut code, p, f, variable, field, subfield, ext, &mut fix)
    if ty == 1 {
        x64LoadMem8(&mut code, dst, at.base, at.disp)
    } else {
        x64LoadMem64(&mut code, dst, at.base, at.disp)
    }
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
    bad_index_at: List<Int>
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
        // Through a reference only `print` and `append` read a Text here.
        let at = cfgPlaceAddr(&mut code, p, f, op.value, -1, -1, -1, &mut fix)
        x64LoadMem64(&mut code, 0, at.base, at.disp)
        x64LoadMem64(&mut code, 2, at.base, at.disp + 8)
        x64LoadMem64(&mut code, 1, at.base, at.disp + 16)
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

// RDI = address of a variable's storage, or of its referent.
fn cfgVarAddress(code: &mut X64Code, p: &CfgProgram, f: Int, variable: Int, fix: &mut CfgFix) {
    cfgPlaceAddressRax(&mut code, p, f, variable, -1, -1, -1, &mut fix)
    x64MovReg(&mut code, 7, 0)
}

// Type of the source of `print`/`append`, seen through a reference.
fn cfgSourceType(p: &CfgProgram, f: Int, inst: &CfgInst) -> Int {
    if inst.op >= 0 {
        let place = CfgPlace(variable: inst.op, field: inst.src_field, subfield: inst.src_sub, ext: inst.src_ext)
        return cfgPlaceType(p, f, &place)
    }
    return cfgOperandType(p, f, &inst.a)
}

// RAX, RDX, RCX = the Text source of `print`/`append`, which may be a
// projected place (`ref pN.k 0`).
fn cfgSourceTextWords(code: &mut X64Code, p: &CfgProgram, f: Int, inst: &CfgInst, value: &NativeOperand, fix: &mut CfgFix) {
    if inst.op < 0 {
        cfgTextWords(&mut code, p, f, value, &mut fix)
        return
    }
    let at = cfgPlaceAddr(&mut code, p, f, inst.op, inst.src_field, inst.src_sub, inst.src_ext, &mut fix)
    x64LoadMem64(&mut code, 0, at.base, at.disp)
    x64LoadMem64(&mut code, 2, at.base, at.disp + 8)
    x64LoadMem64(&mut code, 1, at.base, at.disp + 16)
}

// Loads an Int/Bool source of `print`/`append` into `dst`.
fn cfgLoadSource(code: &mut X64Code, p: &CfgProgram, f: Int, inst: &CfgInst, ty: Int, dst: Int, fix: &mut CfgFix) {
    if inst.op >= 0 {
        cfgLoadPlace(&mut code, p, f, inst.op, inst.src_field, inst.src_sub, inst.src_ext, ty, dst, &mut fix)
    } else {
        cfgLoadOperand(&mut code, p, f, &inst.a, dst)
    }
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
        let ty = cfgSourceType(p, f, inst)
        if ty == cfgTextType() {
            cfgSourceTextWords(&mut code, p, f, inst, &value, &mut fix)
            x64MovReg(&mut code, 7, 0)
            x64MovReg(&mut code, 6, 2)
            cfgRuntimeCall(&mut code, &mut fix, rtPrintText())
        } else {
            cfgLoadSource(&mut code, p, f, inst, ty, 7, &mut fix)
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
        let ty = cfgSourceType(p, f, inst)
        if ty == cfgTextType() {
            cfgSourceTextWords(&mut code, p, f, inst, &value, &mut fix)
            x64MovReg(&mut code, 6, 0)
            cfgVarAddress(&mut code, p, f, inst.place_var, &mut fix)
            cfgRuntimeCall(&mut code, &mut fix, rtTextAppend())
        } else {
            cfgLoadSource(&mut code, p, f, inst, ty, 6, &mut fix)
            cfgVarAddress(&mut code, p, f, inst.place_var, &mut fix)
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
        // Text or list: the address of the variable, then its release.
        cfgVarAddress(&mut code, p, f, inst.place_var, &mut fix)
        cfgDropAt(&mut code, &mut fix, p.types_code[cfgVarIndex(p, f, inst.place_var)])
        if skip >= 0 { x64PatchRelative(&mut code, skip, code.bytes.length) }
    } else if inst.kind == 17 {
        // dropfield: release the Text or list stored in a field, when the flag
        // says so.
        var skip = -1
        if inst.op >= 0 {
            x64LoadSlot(&mut code, 0, p.slot_start[cfgVarIndex(p, f, inst.op)])
            x64TestRax(&mut code)
            skip = x64ConditionalPlaceholder(&mut code, true)
        }
        cfgPlaceAddressRax(&mut code, p, f, inst.place_var, inst.place_field, inst.place_subfield, -1, &mut fix)
        x64MovReg(&mut code, 7, 0)
        let place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: -1)
        cfgDropAt(&mut code, &mut fix, cfgPlaceType(p, f, &place))
        if skip >= 0 { x64PatchRelative(&mut code, skip, code.bytes.length) }
    } else if inst.kind == 14 {
        // byteLength or length: the second word of a Text or a list.
        let at = cfgPlaceAddr(&mut code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, &mut fix)
        x64LoadMem64(&mut code, 0, at.base, at.disp + 8)
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } else if inst.kind == 15 {
        // byteAt(i): 0 <= i < length, checked unsigned, or exit 127.
        cfgLoadOperand(&mut code, p, f, &inst.a, 1)
        let at = cfgPlaceAddr(&mut code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, &mut fix)
        x64LoadMem64(&mut code, 2, at.base, at.disp + 8)
        x64CmpReg(&mut code, 1, 2)
        fix.bad_index_at.push(x64AboveEqualPlaceholder(&mut code))
        x64LoadMem64(&mut code, 0, at.base, at.disp)
        x64AddReg(&mut code, 0, 1)
        x64LoadMem8(&mut code, 0, 0, 0)
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } else {
        code.error = 10
    }
}

// Releases the value of type `ty` whose address is in RDI: a Text through
// the runtime, a list or a shape through its drop glue (native_cfg_list_emit).
pub fn cfgDropAt(code: &mut X64Code, fix: &mut CfgFix, ty: Int) {
    if ty == cfgTextType() {
        x64LoadMem64(&mut code, 6, 7, 16)
        x64LoadMem64(&mut code, 7, 7, 0)
        cfgRuntimeCall(&mut code, &mut fix, rtTextDrop())
    } else {
        cfgRuntimeCall(&mut code, &mut fix, rtGlueBase() + ty - 2)
    }
}

// Transfer a typed value between memory locations ([base + disp]) without
// copying potentially uninitialized padding. The struct graph is acyclic:
// each nested field is an already-declared struct, so recursion terminates.
// Primitive fields are emitted with their exact declared width (Bool=1,
// Int=8); fields of a nested struct are copied recursively by layout.
// Only RAX is used as scratch, so R9 and R11 may hold addresses.
pub fn cfgCopyValue(code: &mut X64Code, p: &CfgProgram, ty: Int, dst_base: Int, dst_disp: Int, src_base: Int, src_disp: Int) -> () {
    if ty == 0 {
        x64LoadMem64(&mut code, 0, src_base, src_disp)
        x64StoreMem64(&mut code, dst_base, dst_disp, 0)
    } else if ty == cfgTextType() || cfgListIndex(p, ty) >= 0 {
        // A Text or a list: address, length, capacity. Moving the words
        // moves the ownership; the verifier invalidates the source.
        for w in 0..3 {
            x64LoadMem64(&mut code, 0, src_base, src_disp + 8 * w)
            x64StoreMem64(&mut code, dst_base, dst_disp + 8 * w, 0)
        }
    } else if ty == 1 {
        x64LoadMem8(&mut code, 0, src_base, src_disp)
        x64StoreMem8(&mut code, dst_base, dst_disp, 0)
    } else if ty >= 2 && ty - 2 < p.structs.length {
        let st = &p.structs[ty - 2]
        for field in 0..st.fields {
            let member = &p.fields[st.first_field + field]
            cfgCopyValue(&mut code, p, member.ty, dst_base, dst_disp + member.offset, src_base, src_disp + member.offset)
        }
    } else if ty >= 2 + p.structs.length && ty - 2 - p.structs.length < p.enums.length {
        let enum_id = ty - 2 - p.structs.length
        // Both the tag and the optional 8-byte payload slot are ALWAYS
        // initialized by `i variant`, including unit/Bool cases.
        x64LoadMem64(&mut code, 0, src_base, src_disp)
        x64StoreMem64(&mut code, dst_base, dst_disp, 0)
        if p.enums[enum_id].size == 16 {
            x64LoadMem64(&mut code, 0, src_base, src_disp + 8)
            x64StoreMem64(&mut code, dst_base, dst_disp + 8, 0)
        }
    } else {
        code.error = 12
    }
}

// Stores operand `value` of type `ty` at [base + disp]: a Text or an
// aggregate is moved there, a primitive is written with its exact width.
// `base` must not be RAX, RCX or RDX.
pub fn cfgStoreValueAt(code: &mut X64Code, p: &CfgProgram, f: Int, ty: Int, value: &NativeOperand, base: Int, disp: Int, fix: &mut CfgFix) {
    if ty == cfgTextType() {
        cfgTextWords(&mut code, p, f, value, &mut fix)
        x64StoreMem64(&mut code, base, disp, 0)
        x64StoreMem64(&mut code, base, disp + 8, 2)
        x64StoreMem64(&mut code, base, disp + 16, 1)
    } else if ty >= 2 {
        if !value.is_var { code.error = 12; return }
        cfgCopyValue(&mut code, p, ty, base, disp, 5, cfgVarBase(p, f, value.value))
    } else {
        cfgLoadOperand(&mut code, p, f, value, 0)
        if ty == 1 {
            x64StoreMem8(&mut code, base, disp, 0)
        } else {
            x64StoreMem64(&mut code, base, disp, 0)
        }
    }
}
