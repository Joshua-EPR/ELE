take native_cfg_defs
take native_cfg_types
take x86_64
take native_rt
take native_rt_list

// Shared lowering helpers of the CFG backend and the lowering of Text:
// literals, owned buffers, print, append and drop.

// Stack locations are assigned per variable from the actual ELE-LIR type.
// Aggregate addresses point to the lowest address within the allocated slots;
// every direct primitive field is accessed using its calculated byte offset.
expose flow cfgFrameSlots(p: view CfgProgram, f: Int) => Int {
    hold func = view p.functions[f]
    when func.vars == 0 { give 0 }
    hold last = func.first_var + func.vars - 1
    give p.slot_start[last] + p.slot_count[last]
}

expose flow cfgVarIndex(p: view CfgProgram, f: Int, variable: Int) => Int {
    give p.functions[f].first_var + variable
}

expose flow cfgVarBase(p: view CfgProgram, f: Int, variable: Int) => Int {
    hold index = cfgVarIndex(p, f, variable)
    give -8 * (p.slot_start[index] + p.slot_count[index])
}

expose shape CfgAddr {
    base: Int
    disp: Int
}

// Byte offset of a place inside the storage of its root (the referent when
// the root is a reference). Field -1 is the whole root.
flow cfgPlaceRel(p: view CfgProgram, f: Int, variable: Int, field: Int, subfield: Int) => Int {
    when field < 0 { give 0 }
    hold ty = p.types_code[cfgVarIndex(p, f, variable)]
    hold member = p.structs[ty - 2].first_field + field
    hold offset = p.fields[member].offset
    when subfield < 0 { give offset }
    hold child = p.fields[member].ty
    give offset + p.fields[p.structs[child - 2].first_field + subfield].offset
}

// Base register and displacement of a place. A reference root loads the
// referent's address into R11, and so does every index of the extension
// `ext` (-1 when the place has none): the index is checked unsigned against
// the length of the list, so a negative or too large one leaves through
// exit 127 before any element is touched. Only R8-R11 are clobbered;
// callers access memory before any other code could reuse R11.
expose flow cfgPlaceAddr(code: edit X64Code, p: view CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, ext: Int, fix: edit CfgFix) => CfgAddr {
    hold rel = cfgPlaceRel(p, f, variable, field, subfield)
    hold index = cfgVarIndex(p, f, variable)
    change base = 5
    change disp = cfgVarBase(p, f, variable) + rel
    when p.var_ref[index] {
        x64LoadSlot(edit code, 11, p.slot_start[index])
        base = 11
        disp = rel
    }
    when ext < 0 { give CfgAddr(base: base, disp: disp) }
    hold prefix = CfgPlace(variable: variable, field: field, subfield: subfield, ext: -1)
    change ty = cfgPlaceType(p, f, view prefix)
    hold first = p.ext_first[ext]
    each n among first..(first + p.ext_count[ext]) {
        when p.proj_kind[n] == 1 {
            hold list = cfgListIndex(p, ty)
            when list < 0 { code.error = 14; leave }
            hold elem = p.list_elem[list]
            x64LoadMem64(edit code, 9, base, disp)
            x64LoadMem64(edit code, 8, base, disp + 8)
            x64LoadSlot(edit code, 10, p.slot_start[cfgVarIndex(p, f, p.proj_value[n])])
            x64CmpReg(edit code, 10, 8)
            fix.bad_index_at@push(x64AboveEqualPlaceholder(edit code))
            x64MovImm64(edit code, 8, cfgTypeSize(p, elem))
            x64MulReg(edit code, 10, 8)
            x64MovReg(edit code, 11, 9)
            x64AddReg(edit code, 11, 10)
            base = 11
            disp = 0
            ty = elem
        } otherwise {
            when ty < 2 || ty - 2 >= p.structs.length { code.error = 14; leave }
            hold member = p.structs[ty - 2].first_field + p.proj_value[n]
            disp += p.fields[member].offset
            ty = p.fields[member].ty
        }
    }
    give CfgAddr(base: base, disp: disp)
}

// RAX = address of a place.
expose flow cfgPlaceAddressRax(code: edit X64Code, p: view CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, ext: Int, fix: edit CfgFix) {
    hold at = cfgPlaceAddr(edit code, p, f, variable, field, subfield, ext, edit fix)
    x64MovReg(edit code, 0, at.base)
    x64MovImm64(edit code, 10, at.disp)
    x64AddReg(edit code, 0, 10)
}

// Loads a primitive place (Bool as one byte, Int as eight) into `dst`.
expose flow cfgLoadPlace(code: edit X64Code, p: view CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, ext: Int, ty: Int, dst: Int, fix: edit CfgFix) {
    hold at = cfgPlaceAddr(edit code, p, f, variable, field, subfield, ext, edit fix)
    when ty == 1 {
        x64LoadMem8(edit code, dst, at.base, at.disp)
    } otherwise {
        x64LoadMem64(edit code, dst, at.base, at.disp)
    }
}

expose flow cfgLoadOperand(code: edit X64Code, p: view CfgProgram, f: Int, op: view NativeOperand, dst: Int) {
    when op.is_var {
        x64LoadSlot(edit code, dst, p.slot_start[cfgVarIndex(p, f, op.value)])
    } otherwise {
        x64MovImm64(edit code, dst, op.value)
    }
}

// Fixups collected while emitting and resolved once every address is known.
// Call targets >= 0 are functions; target -(k+1) is runtime routine k.
expose shape CfgFix {
    call_at: List of[Int]
    call_to: List of[Int]
    jump_at: List of[Int]
    jump_to: List of[Int]
    overflow_at: List of[Int]
    bad_variant_at: List of[Int]
    bad_index_at: List of[Int]
    text_at: List of[Int]
    text_id: List of[Int]
}

expose flow cfgCall(code: edit X64Code, fix: edit CfgFix, target: Int) {
    fix.call_at@push(x64CallPlaceholder(edit code))
    fix.call_to@push(target)
}

expose flow cfgRuntimeCall(code: edit X64Code, fix: edit CfgFix, routine: Int) {
    cfgCall(edit code, edit fix, -1 - routine)
}

// Loads a Text operand as RAX = address, RDX = byte length, RCX = capacity.
// A literal gets capacity 0 and an address patched in after layout.
expose flow cfgTextWords(code: edit X64Code, p: view CfgProgram, f: Int, op: view NativeOperand, fix: edit CfgFix) {
    when op.is_var {
        // Through a reference only `print` and `append` read a Text here.
        hold at = cfgPlaceAddr(edit code, p, f, op.value, -1, -1, -1, edit fix)
        x64LoadMem64(edit code, 0, at.base, at.disp)
        x64LoadMem64(edit code, 2, at.base, at.disp + 8)
        x64LoadMem64(edit code, 1, at.base, at.disp + 16)
    } otherwise {
        x64MovImm64(edit code, 0, 0)
        fix.text_at@push(code.bytes.length - 8)
        fix.text_id@push(op.value)
        x64MovImm64(edit code, 2, p.text_length[op.value])
        x64MovImm64(edit code, 1, 0)
    }
}

// Stores RAX, RDX, RCX as the three words of a Text variable.
expose flow cfgStoreText(code: edit X64Code, p: view CfgProgram, f: Int, variable: Int) {
    hold base = cfgVarBase(p, f, variable)
    x64StoreMem64(edit code, 5, base, 0)
    x64StoreMem64(edit code, 5, base + 8, 2)
    x64StoreMem64(edit code, 5, base + 16, 1)
}

// RDI = address of a variable's storage, or of its referent.
flow cfgVarAddress(code: edit X64Code, p: view CfgProgram, f: Int, variable: Int, fix: edit CfgFix) {
    cfgPlaceAddressRax(edit code, p, f, variable, -1, -1, -1, edit fix)
    x64MovReg(edit code, 7, 0)
}

// Type of the source of `print`/`append`, seen through a reference.
flow cfgSourceType(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    when inst.op >= 0 {
        hold place = CfgPlace(variable: inst.op, field: inst.src_field, subfield: inst.src_sub, ext: inst.src_ext)
        give cfgPlaceType(p, f, view place)
    }
    give cfgOperandType(p, f, view inst.a)
}

// RAX, RDX, RCX = the Text source of `print`/`append`, which may be a
// projected place (`ref pN.k 0`).
flow cfgSourceTextWords(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, value: view NativeOperand, fix: edit CfgFix) {
    when inst.op < 0 {
        cfgTextWords(edit code, p, f, value, edit fix)
        give
    }
    hold at = cfgPlaceAddr(edit code, p, f, inst.op, inst.src_field, inst.src_sub, inst.src_ext, edit fix)
    x64LoadMem64(edit code, 0, at.base, at.disp)
    x64LoadMem64(edit code, 2, at.base, at.disp + 8)
    x64LoadMem64(edit code, 1, at.base, at.disp + 16)
}

// Loads an Int/Bool source of `print`/`append` into `dst`.
flow cfgLoadSource(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, ty: Int, dst: Int, fix: edit CfgFix) {
    when inst.op >= 0 {
        cfgLoadPlace(edit code, p, f, inst.op, inst.src_field, inst.src_sub, inst.src_ext, ty, dst, edit fix)
    } otherwise {
        cfgLoadOperand(edit code, p, f, view inst.a, dst)
    }
}

// Type and operand of the source of `print`/`append`: the referenced
// variable when `inst.op` names one, otherwise operand `a`.
flow cfgSourceOperand(inst: view CfgInst) => NativeOperand {
    when inst.op >= 0 {
        give NativeOperand(is_var: true, value: inst.op, is_bool: false, is_unit: false, is_text: false)
    }
    give NativeOperand(is_var: inst.a.is_var, value: inst.a.value, is_bool: inst.a.is_bool, is_unit: inst.a.is_unit, is_text: inst.a.is_text)
}

expose flow cfgEmitText(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    when inst.kind == 10 {
        hold value = cfgSourceOperand(inst)
        hold ty = cfgSourceType(p, f, inst)
        when ty == cfgTextType() {
            cfgSourceTextWords(edit code, p, f, inst, view value, edit fix)
            x64MovReg(edit code, 7, 0)
            x64MovReg(edit code, 6, 2)
            cfgRuntimeCall(edit code, edit fix, rtPrintText())
        } otherwise {
            cfgLoadSource(edit code, p, f, inst, ty, 7, edit fix)
            when ty == 1 {
                cfgRuntimeCall(edit code, edit fix, rtPrintBool())
            } otherwise {
                cfgRuntimeCall(edit code, edit fix, rtPrintInt())
            }
        }
    } otherwise when inst.kind == 11 {
        x64MovImm64(edit code, 7, inst.callee)
        cfgRuntimeCall(edit code, edit fix, rtTextNew())
        // text_new returns RAX = address, RDX = capacity; length starts at 0.
        x64MovReg(edit code, 1, 2)
        x64MovImm64(edit code, 2, 0)
        cfgStoreText(edit code, p, f, inst.dst)
    } otherwise when inst.kind == 12 {
        hold value = cfgSourceOperand(inst)
        hold ty = cfgSourceType(p, f, inst)
        when ty == cfgTextType() {
            cfgSourceTextWords(edit code, p, f, inst, view value, edit fix)
            x64MovReg(edit code, 6, 0)
            cfgVarAddress(edit code, p, f, inst.place_var, edit fix)
            cfgRuntimeCall(edit code, edit fix, rtTextAppend())
        } otherwise {
            cfgLoadSource(edit code, p, f, inst, ty, 6, edit fix)
            cfgVarAddress(edit code, p, f, inst.place_var, edit fix)
            when ty == 1 {
                cfgRuntimeCall(edit code, edit fix, rtAppendBool())
            } otherwise {
                cfgRuntimeCall(edit code, edit fix, rtAppendInt())
            }
        }
    } otherwise when inst.kind == 13 {
        change skip = -1
        when inst.op >= 0 {
            x64LoadSlot(edit code, 0, p.slot_start[cfgVarIndex(p, f, inst.op)])
            x64TestRax(edit code)
            skip = x64ConditionalPlaceholder(edit code, true)
        }
        // Text or list: the address of the variable, then its release.
        cfgVarAddress(edit code, p, f, inst.place_var, edit fix)
        cfgDropAt(edit code, edit fix, p.types_code[cfgVarIndex(p, f, inst.place_var)])
        when skip >= 0 {
            hold end_offset = code.bytes.length
            x64PatchRelative(edit code, skip, end_offset)
        }
    } otherwise when inst.kind == 17 {
        // dropfield: release the Text or list stored in a field, when the flag
        // says so.
        change skip = -1
        when inst.op >= 0 {
            x64LoadSlot(edit code, 0, p.slot_start[cfgVarIndex(p, f, inst.op)])
            x64TestRax(edit code)
            skip = x64ConditionalPlaceholder(edit code, true)
        }
        cfgPlaceAddressRax(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, -1, edit fix)
        x64MovReg(edit code, 7, 0)
        hold place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: -1)
        cfgDropAt(edit code, edit fix, cfgPlaceType(p, f, view place))
        when skip >= 0 {
            hold end_offset = code.bytes.length
            x64PatchRelative(edit code, skip, end_offset)
        }
    } otherwise when inst.kind == 14 {
        // byteLength or length: the second word of a Text or a list.
        hold at = cfgPlaceAddr(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, edit fix)
        x64LoadMem64(edit code, 0, at.base, at.disp + 8)
        x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } otherwise when inst.kind == 15 {
        // byteAt(i): 0 <= i < length, checked unsigned, or exit 127.
        cfgLoadOperand(edit code, p, f, view inst.a, 1)
        hold at = cfgPlaceAddr(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, edit fix)
        x64LoadMem64(edit code, 2, at.base, at.disp + 8)
        x64CmpReg(edit code, 1, 2)
        fix.bad_index_at@push(x64AboveEqualPlaceholder(edit code))
        x64LoadMem64(edit code, 0, at.base, at.disp)
        x64AddReg(edit code, 0, 1)
        x64LoadMem8(edit code, 0, 0, 0)
        x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } otherwise {
        code.error = 10
    }
}

// Releases the value of type `ty` whose address is in RDI: a Text through
// the runtime, a list or a shape through its drop glue (native_cfg_list_emit).
expose flow cfgDropAt(code: edit X64Code, fix: edit CfgFix, ty: Int) {
    when ty == cfgTextType() {
        x64LoadMem64(edit code, 6, 7, 16)
        x64LoadMem64(edit code, 7, 7, 0)
        cfgRuntimeCall(edit code, edit fix, rtTextDrop())
    } otherwise {
        cfgRuntimeCall(edit code, edit fix, rtGlueBase() + ty - 2)
    }
}

// Transfer a typed value between memory locations ([base + disp]) without
// copying potentially uninitialized padding. The struct graph is acyclic:
// each nested field is an already-declared struct, so recursion terminates.
// Primitive fields are emitted with their exact declared width (Bool=1,
// Int=8); fields of a nested struct are copied recursively by layout.
// Only RAX is used as scratch, so R9 and R11 may hold addresses.
expose flow cfgCopyValue(code: edit X64Code, p: view CfgProgram, ty: Int, dst_base: Int, dst_disp: Int, src_base: Int, src_disp: Int) => () {
    when ty == 0 {
        x64LoadMem64(edit code, 0, src_base, src_disp)
        x64StoreMem64(edit code, dst_base, dst_disp, 0)
    } otherwise when ty == cfgTextType() || cfgListIndex(p, ty) >= 0 {
        // A Text or a list: address, length, capacity. Moving the words
        // moves the ownership; the verifier invalidates the source.
        each w among 0..3 {
            x64LoadMem64(edit code, 0, src_base, src_disp + 8 * w)
            x64StoreMem64(edit code, dst_base, dst_disp + 8 * w, 0)
        }
    } otherwise when ty == 1 {
        x64LoadMem8(edit code, 0, src_base, src_disp)
        x64StoreMem8(edit code, dst_base, dst_disp, 0)
    } otherwise when ty >= 2 && ty - 2 < p.structs.length {
        hold st = view p.structs[ty - 2]
        each field among 0..st.fields {
            hold member = view p.fields[st.first_field + field]
            cfgCopyValue(edit code, p, member.ty, dst_base, dst_disp + member.offset, src_base, src_disp + member.offset)
        }
    } otherwise when ty >= 2 + p.structs.length && ty - 2 - p.structs.length < p.enums.length {
        hold enum_id = ty - 2 - p.structs.length
        // The tag and the whole payload area are ALWAYS initialized by
        // `i variant` (zero-filled before the payload is written), so a
        // word-wise copy moves defined bytes for every variant. Payloads
        // are drop-free (cfgLayoutEnum): copying the words is the move.
        each w among 0..(p.enums[enum_id].size / 8) {
            x64LoadMem64(edit code, 0, src_base, src_disp + 8 * w)
            x64StoreMem64(edit code, dst_base, dst_disp + 8 * w, 0)
        }
    } otherwise {
        code.error = 12
    }
}

// Stores operand `value` of type `ty` at [base + disp]: a Text or an
// aggregate is moved there, a primitive is written with its exact width.
// `base` must not be RAX, RCX or RDX.
expose flow cfgStoreValueAt(code: edit X64Code, p: view CfgProgram, f: Int, ty: Int, value: view NativeOperand, base: Int, disp: Int, fix: edit CfgFix) {
    when ty == cfgTextType() {
        cfgTextWords(edit code, p, f, value, edit fix)
        x64StoreMem64(edit code, base, disp, 0)
        x64StoreMem64(edit code, base, disp + 8, 2)
        x64StoreMem64(edit code, base, disp + 16, 1)
    } otherwise when ty >= 2 {
        when !value.is_var { code.error = 12; give }
        cfgCopyValue(edit code, p, ty, base, disp, 5, cfgVarBase(p, f, value.value))
    } otherwise {
        cfgLoadOperand(edit code, p, f, value, 0)
        when ty == 1 {
            x64StoreMem8(edit code, base, disp, 0)
        } otherwise {
            x64StoreMem64(edit code, base, disp, 0)
        }
    }
}
