import native_cfg_defs
import native_cfg_types
import native_cfg_verify
import x86_64
import elf64
import native_rt
import native_cfg_text
import native_cfg_arith

// x86-64 ELF64 lowering for CFG with move-only drop-free structs and owned
// Text. Calls use an ELE-internal convention: arguments on the stack, results
// in RAX (Int, Bool) or RAX, RDX, RCX (Text). The entry stub performs Linux
// sys_exit(main()), without libc, Rust or a linker.

pub struct CfgImage {
    image: List<Int>
    error: Int
}

fn cfgPlaceKind(p: &CfgProgram, f: Int, variable: Int, field: Int, subfield: Int) -> Int {
    let place = CfgPlace(variable: variable, field: field, subfield: subfield)
    return cfgPlaceType(p, f, &place)
}

// Transfer a typed value between memory locations ([base + disp]) without
// copying potentially uninitialized padding. The struct graph is acyclic:
// each nested field is an already-declared struct, so recursion terminates.
// Primitive fields are emitted with their exact declared width (Bool=1,
// Int=8); fields of a nested struct are copied recursively by layout.
// Only RAX is used as scratch, so R11 may hold a referent address.
fn cfgCopyValue(code: &mut X64Code, p: &CfgProgram, ty: Int, dst_base: Int, dst_disp: Int, src_base: Int, src_disp: Int) -> () {
    if ty == 0 {
        x64LoadMem64(&mut code, 0, src_base, src_disp)
        x64StoreMem64(&mut code, dst_base, dst_disp, 0)
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

// Whole struct transfers use these bytes as the physical representation
// of a MOVE, never as permission to duplicate ownership. The verifier
// invalidates moved source variables. Struct-valued field reads are rejected.
// The place may be reached through a reference parameter.
fn cfgStoreField(code: &mut X64Code, p: &CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, value: &NativeOperand) {
    let ty = cfgPlaceKind(p, f, variable, field, subfield)
    if ty >= 2 {
        if !value.is_var { code.error = 12; return }
        let at = cfgPlaceAddr(&mut code, p, f, variable, field, subfield)
        cfgCopyValue(&mut code, p, ty, at.base, at.disp, 5, cfgVarBase(p, f, value.value))
    } else {
        cfgLoadOperand(&mut code, p, f, value, 0)
        let at = cfgPlaceAddr(&mut code, p, f, variable, field, subfield)
        if ty == 1 {
            x64StoreMem8(&mut code, at.base, at.disp, 0)
        } else {
            x64StoreMem64(&mut code, at.base, at.disp, 0)
        }
    }
}

fn cfgReadField(code: &mut X64Code, p: &CfgProgram, f: Int, dst: Int, variable: Int, field: Int, subfield: Int) {
    let ty = cfgPlaceKind(p, f, variable, field, subfield)
    if ty >= 2 {
        let at = cfgPlaceAddr(&mut code, p, f, variable, field, subfield)
        cfgCopyValue(&mut code, p, ty, 5, cfgVarBase(p, f, dst), at.base, at.disp)
    } else {
        cfgLoadPlace(&mut code, p, f, variable, field, subfield, ty, 0)
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, dst)], 0)
    }
}

fn cfgCopyStruct(code: &mut X64Code, p: &CfgProgram, f: Int, dst: Int, src: Int) {
    let ty = p.types_code[cfgVarIndex(p, f, dst)]
    cfgCopyValue(&mut code, p, ty, 5, cfgVarBase(p, f, dst), 5, cfgVarBase(p, f, src))
}

fn cfgEmitInstruction(code: &mut X64Code, p: &CfgProgram, f: Int, inst: &CfgInst, fix: &mut CfgFix) {
    if inst.kind == 1 {
        if p.types_code[cfgVarIndex(p, f, inst.dst)] == cfgTextType() {
            cfgTextWords(&mut code, p, f, &inst.a, &mut fix)
            cfgStoreText(&mut code, p, f, inst.dst)
        } else if p.types_code[cfgVarIndex(p, f, inst.dst)] >= 2 {
            cfgCopyStruct(&mut code, p, f, inst.dst, inst.a.value)
        } else {
            cfgLoadOperand(&mut code, p, f, &inst.a, 0)
            x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
        }
    } else if inst.kind == 2 {
        cfgLoadOperand(&mut code, p, f, &inst.a, 0)
        cfgLoadOperand(&mut code, p, f, &inst.b, 1)
        if inst.op == 1 {
            x64AddReg(&mut code, 0, 1)
            fix.overflow_at.push(x64OverflowPlaceholder(&mut code))
        } else if inst.op == 2 {
            x64SubReg(&mut code, 0, 1)
            fix.overflow_at.push(x64OverflowPlaceholder(&mut code))
        } else if inst.op == 3 {
            x64MulReg(&mut code, 0, 1)
            fix.overflow_at.push(x64OverflowPlaceholder(&mut code))
        } else if inst.op >= 10 {
            cfgEmitDivRem(&mut code, &mut fix, inst.op)
        } else {
            x64CmpReg(&mut code, 0, 1)
            x64SetCondition(&mut code, inst.op)
        }
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } else if inst.kind == 3 {
        // Arguments travel on the stack. They are pushed from the last word
        // of the last argument down to the first word of the first one, so
        // the callee finds them in order at RBP+16 upwards.
        var words = 0
        for n in 0..inst.argc {
            let k = inst.arg_first + inst.argc - 1 - n
            let arg = &p.call_args[k]
            if p.call_ref[k] >= 0 {
                // A reference argument is the address of its place.
                cfgPlaceAddressRax(&mut code, p, f, arg.value, p.call_field[k], p.call_sub[k])
                x64PushReg(&mut code, 0)
                words += 1
            } else if cfgOperandType(p, f, &arg) == cfgTextType() {
                cfgTextWords(&mut code, p, f, &arg, &mut fix)
                x64PushReg(&mut code, 1)
                x64PushReg(&mut code, 2)
                x64PushReg(&mut code, 0)
                words += 3
            } else {
                cfgLoadOperand(&mut code, p, f, &arg, 0)
                x64PushReg(&mut code, 0)
                words += 1
            }
        }
        cfgCall(&mut code, &mut fix, inst.callee)
        if words > 0 {
            x64MovImm64(&mut code, 10, words * 8)
            x64AddReg(&mut code, 4, 10)
        }
        if p.types_code[cfgVarIndex(p, f, inst.dst)] == cfgTextType() {
            cfgStoreText(&mut code, p, f, inst.dst)
        } else {
            x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
        }
    } else if inst.kind == 4 {
        cfgStoreField(&mut code, p, f, inst.dst, 0, -1, &inst.a)
        if inst.argc >= 2 { cfgStoreField(&mut code, p, f, inst.dst, 1, -1, &inst.b) }
        if inst.argc >= 3 { cfgStoreField(&mut code, p, f, inst.dst, 2, -1, &inst.c) }
        if inst.argc == 4 { cfgStoreField(&mut code, p, f, inst.dst, 3, -1, &inst.d) }
    } else if inst.kind == 5 {
        cfgReadField(&mut code, p, f, inst.dst, inst.place_var, inst.place_field, inst.place_subfield)
    } else if inst.kind == 6 {
        cfgStoreField(&mut code, p, f, inst.place_var, inst.place_field, inst.place_subfield, &inst.a)
    } else if inst.kind == 7 {
        let kind = &p.enums[inst.op]
        let dest = cfgVarBase(p, f, inst.dst)
        x64MovImm64(&mut code, 0, inst.place_field)
        x64StoreMem64(&mut code, 5, dest, 0)
        if kind.size == 16 {
            // Zero-fill to keep the complete slot initialized and make
            // moves of unit variants and Bool payloads well-defined.
            x64MovImm64(&mut code, 0, 0)
            x64StoreMem64(&mut code, 5, dest + 8, 0)
            if inst.argc == 1 {
                cfgLoadOperand(&mut code, p, f, &inst.a, 0)
                let payload = p.variants[kind.first_variant + inst.place_field].payload_type
                if payload == 1 {
                    x64StoreMem8(&mut code, 5, dest + 8, 0)
                } else {
                    x64StoreMem64(&mut code, 5, dest + 8, 0)
                }
            }
        }
    } else if inst.kind == 8 {
        cfgLoadPlace(&mut code, p, f, inst.place_var, -1, -1, 0, 0)
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } else if inst.kind == 9 {
        // Checked payload extraction: an unmatched variant exits with 126.
        // Never read [enum+8] until the actual discriminant has been tested.
        let at = cfgPlaceAddr(&mut code, p, f, inst.place_var, -1, -1)
        let owner = at.disp
        x64LoadMem64(&mut code, 0, at.base, owner)
        x64MovImm64(&mut code, 1, inst.place_field)
        x64CmpReg(&mut code, 0, 1)
        fix.bad_variant_at.push(x64ConditionalPlaceholder(&mut code, false))
        let e = &p.enums[inst.op]
        let payload = p.variants[e.first_variant + inst.place_field].payload_type
        if payload == 1 {
            x64LoadMem8(&mut code, 0, at.base, owner + 8)
        } else {
            x64LoadMem64(&mut code, 0, at.base, owner + 8)
        }
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } else if inst.kind == 16 {
        cfgEmitUnary(&mut code, p, f, inst, &mut fix)
    } else {
        cfgEmitText(&mut code, p, f, inst, &mut fix)
    }
}

fn cfgEmitTerm(code: &mut X64Code, p: &CfgProgram, f: Int, block: &CfgBlock, func: &CfgFunc, fix: &mut CfgFix) {
    if block.term == 1 {
        if func.result_unit {
            // Unit has no representation; a unit `main` exits with status 0.
            x64MovImm64(&mut code, 0, 0)
        } else if func.result_text {
            // RAX, RDX, RCX: address, byte length, capacity.
            cfgTextWords(&mut code, p, f, &block.value, &mut fix)
        } else {
            cfgLoadOperand(&mut code, p, f, &block.value, 0)
        }
        x64FrameEnd(&mut code)
    } else if block.term == 2 {
        fix.jump_at.push(x64JumpPlaceholder(&mut code))
        fix.jump_to.push(func.first_block + block.yes)
    } else if block.term == 3 {
        cfgLoadOperand(&mut code, p, f, &block.value, 0)
        x64TestRax(&mut code)
        fix.jump_at.push(x64ConditionalPlaceholder(&mut code, false))
        fix.jump_to.push(func.first_block + block.yes)
        fix.jump_at.push(x64JumpPlaceholder(&mut code))
        fix.jump_to.push(func.first_block + block.no)
    } else if block.term == 4 {
        x64Unreachable(&mut code)
    } else {
        code.error = 11
    }
}

// Copies the stack arguments of a call into the parameter variables.
fn cfgEmitParams(code: &mut X64Code, p: &CfgProgram, f: Int) {
    let func = &p.functions[f]
    var word = 0
    for i in 0..func.params {
        let base = cfgVarBase(p, f, i)
        for k in 0..p.slot_count[func.first_var + i] {
            x64LoadMem64(&mut code, 0, 5, 16 + 8 * word)
            x64StoreMem64(&mut code, 5, base + 8 * k, 0)
            word += 1
        }
    }
}

fn cfgNeedsRuntime(p: &CfgProgram) -> Bool {
    for i in 0..p.insts.length {
        if p.insts[i].kind >= 10 && p.insts[i].kind <= 13 { return true }
    }
    return false
}

fn cfgUsesKind(p: &CfgProgram, kind: Int) -> Bool {
    for i in 0..p.insts.length {
        if p.insts[i].kind == kind { return true }
    }
    return false
}

pub fn cfgBuild(p: &CfgProgram) -> CfgImage {
    var result = CfgImage(image: List[], error: 0)
    let verified = cfgVerify(p)
    if verified != 0 {
        result.error = verified
        return result
    }
    var code = x64New()
    var func_at: List<Int> = List[]
    var block_at: List<Int> = List[]
    var fix = CfgFix(call_at: List[], call_to: List[], jump_at: List[], jump_to: List[], overflow_at: List[], bad_variant_at: List[], bad_index_at: List[], text_at: List[], text_id: List[])
    for f in 0..p.functions.length { func_at.push(-1) }
    for b in 0..p.blocks.length { block_at.push(-1) }

    // ELF entry point: sys_exit(main()).
    cfgCall(&mut code, &mut fix, p.main)
    x64MovReg(&mut code, 7, 0)
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)
    let overflow_handler = code.bytes.length
    x64MovImm64(&mut code, 7, 125)
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)

    let bad_variant_handler = code.bytes.length
    x64MovImm64(&mut code, 7, 126)
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)

    // Index out of range (byteAt): exit 127, emitted only when used.
    var bad_index_handler = -1
    if cfgUsesKind(p, 15) {
        bad_index_handler = code.bytes.length
        x64MovImm64(&mut code, 7, 127)
        x64MovImm64(&mut code, 0, 60)
        x64Syscall(&mut code)
    }

    // The runtime is emitted only for programs that print or own Text.
    var runtime_at: List<Int> = List[]
    if cfgNeedsRuntime(p) { runtime_at = rtEmitAll(&mut code) }

    for f in 0..p.functions.length {
        let func = &p.functions[f]
        func_at[f] = code.bytes.length
        x64FrameBegin(&mut code, cfgFrameSlots(p, f))
        cfgEmitParams(&mut code, p, f)
        for b in 0..func.blocks {
            let index = func.first_block + b
            block_at[index] = code.bytes.length
            let block = &p.blocks[index]
            for i in block.first..(block.first + block.count) {
                let inst = &p.insts[i]
                cfgEmitInstruction(&mut code, p, f, &inst, &mut fix)
                if code.error != 0 { break }
            }
            if code.error != 0 { break }
            cfgEmitTerm(&mut code, p, f, block, func, &mut fix)
            if code.error != 0 { break }
        }
        if code.error != 0 { break }
    }

    if code.error != 0 {
        result.error = 70
        return result
    }
    for i in 0..fix.call_at.length {
        let target = fix.call_to[i]
        if target >= 0 {
            x64PatchRelative(&mut code, fix.call_at[i], func_at[target])
        } else if -1 - target < runtime_at.length {
            x64PatchRelative(&mut code, fix.call_at[i], runtime_at[-1 - target])
        } else {
            code.error = 13
        }
    }
    for i in 0..fix.jump_at.length {
        x64PatchRelative(&mut code, fix.jump_at[i], block_at[fix.jump_to[i]])
    }
    for i in 0..fix.bad_index_at.length {
        x64PatchRelative(&mut code, fix.bad_index_at[i], bad_index_handler)
    }
    for i in 0..fix.overflow_at.length {
        x64PatchRelative(&mut code, fix.overflow_at[i], overflow_handler)
    }
    for i in 0..fix.bad_variant_at.length {
        x64PatchRelative(&mut code, fix.bad_variant_at[i], bad_variant_handler)
    }
    // Text literals follow the code inside the same read-only segment, one
    // copy per occurrence in the LIR.
    var literal_at: List<Int> = List[]
    for t in 0..p.text_start.length {
        literal_at.push(code.bytes.length)
        for i in 0..p.text_length[t] {
            code.bytes.push(p.text_bytes[p.text_start[t] + i])
        }
    }
    for i in 0..fix.text_at.length {
        x64PatchAbsolute64(&mut code, fix.text_at[i], elf64CodeAddress() + literal_at[fix.text_id[i]])
    }
    if code.error != 0 {
        result.error = 71
        return result
    }
    result.image = elf64Executable(&code.bytes)
    if result.image.length == 0 { result.error = 72 }
    return result
}

pub fn cfgCompile(source: &Text) -> CfgImage {
    let parsed = cfgParse(source)
    return cfgBuild(&parsed)
}
