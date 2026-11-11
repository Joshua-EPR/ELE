import native_cfg_defs
import native_cfg_verify
import x86_64
import elf64
import native_rt_print

// x86-64 ELF64 lowering for CFG with move-only drop-free structs.
// The ENTRY stub invokes main using an ELE-internal two-register convention.
// It performs Linux sys_exit(main()), without libc, Rust or a linker.

pub struct CfgImage {
    image: List<Int>
    error: Int
}

// Stack locations are assigned per variable from the actual ELE-LIR type.
// Aggregate addresses point to the lowest address within the allocated slots;
// every direct primitive field is accessed using its calculated byte offset.
fn cfgFrameSlots(p: &CfgProgram, f: Int) -> Int {
    let func = &p.functions[f]
    if func.vars == 0 { return 0 }
    let last = func.first_var + func.vars - 1
    return p.slot_start[last] + p.slot_count[last]
}

fn cfgVarIndex(p: &CfgProgram, f: Int, variable: Int) -> Int {
    return p.functions[f].first_var + variable
}

fn cfgVarBase(p: &CfgProgram, f: Int, variable: Int) -> Int {
    let index = cfgVarIndex(p, f, variable)
    return -8 * (p.slot_start[index] + p.slot_count[index])
}

fn cfgFieldOffset(p: &CfgProgram, f: Int, variable: Int, field: Int) -> Int {
    let index = cfgVarIndex(p, f, variable)
    let ty = p.types_code[index]
    let st = &p.structs[ty - 2]
    return cfgVarBase(p, f, variable) + p.fields[st.first_field + field].offset
}

fn cfgFieldTy(p: &CfgProgram, f: Int, variable: Int, field: Int) -> Int {
    let ty = p.types_code[cfgVarIndex(p, f, variable)]
    let st = &p.structs[ty - 2]
    return p.fields[st.first_field + field].ty
}

fn cfgPlaceDisp(p: &CfgProgram, f: Int, variable: Int, field: Int, subfield: Int) -> Int {
    let offset = cfgFieldOffset(p, f, variable, field)
    if subfield < 0 { return offset }
    let child_ty = cfgFieldTy(p, f, variable, field)
    let child = &p.structs[child_ty - 2]
    return offset + p.fields[child.first_field + subfield].offset
}

fn cfgPlaceKind(p: &CfgProgram, f: Int, variable: Int, field: Int, subfield: Int) -> Int {
    let ty = cfgFieldTy(p, f, variable, field)
    if subfield < 0 { return ty }
    let st = &p.structs[ty - 2]
    return p.fields[st.first_field + subfield].ty
}

fn cfgLoadOperand(code: &mut X64Code, p: &CfgProgram, f: Int, op: &NativeOperand, dst: Int) {
    if op.is_var {
        x64LoadSlot(&mut code, dst, p.slot_start[cfgVarIndex(p, f, op.value)])
    } else {
        x64MovImm64(&mut code, dst, op.value)
    }
}

// Transfer a typed value between stack-memory locations without
// copying potentially uninitialized padding. The struct graph is acyclic:
// each nested field is an already-declared struct, so recursion terminates.
// Primitive fields are emitted with their exact declared width (Bool=1,
// Int=8); fields of a nested struct are copied recursively by layout.
fn cfgCopyValue(code: &mut X64Code, p: &CfgProgram, ty: Int, dst_disp: Int, src_disp: Int) -> () {
    if ty == 0 {
        x64LoadMem64(&mut code, 0, 5, src_disp)
        x64StoreMem64(&mut code, 5, dst_disp, 0)
    } else if ty == 1 {
        x64LoadMem8(&mut code, 0, 5, src_disp)
        x64StoreMem8(&mut code, 5, dst_disp, 0)
    } else if ty >= 2 && ty - 2 < p.structs.length {
        let st = &p.structs[ty - 2]
        for field in 0..st.fields {
            let member = &p.fields[st.first_field + field]
            cfgCopyValue(&mut code, p, member.ty, dst_disp + member.offset, src_disp + member.offset)
        }
    } else if ty >= 2 + p.structs.length && ty - 2 - p.structs.length < p.enums.length {
        let enum_id = ty - 2 - p.structs.length
        // Both the tag and the optional 8-byte payload slot are ALWAYS
        // initialized by `i variant`, including unit/Bool cases.
        x64LoadMem64(&mut code, 0, 5, src_disp)
        x64StoreMem64(&mut code, 5, dst_disp, 0)
        if p.enums[enum_id].size == 16 {
            x64LoadMem64(&mut code, 0, 5, src_disp + 8)
            x64StoreMem64(&mut code, 5, dst_disp + 8, 0)
        }
    } else {
        code.error = 12
    }
}

// Whole struct transfers use these bytes as the physical representation
// of a MOVE, never as permission to duplicate ownership. The verifier
// invalidates moved source variables. Struct-valued field reads are rejected.
fn cfgStoreField(code: &mut X64Code, p: &CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, value: &NativeOperand) {
    let ty = cfgPlaceKind(p, f, variable, field, subfield)
    let disp = cfgPlaceDisp(p, f, variable, field, subfield)
    if ty >= 2 {
        if !value.is_var { code.error = 12; return }
        cfgCopyValue(&mut code, p, ty, disp, cfgVarBase(p, f, value.value))
    } else {
        cfgLoadOperand(&mut code, p, f, value, 0)
        if ty == 1 {
            x64StoreMem8(&mut code, 5, disp, 0)
        } else {
            x64StoreMem64(&mut code, 5, disp, 0)
        }
    }
}

fn cfgReadField(code: &mut X64Code, p: &CfgProgram, f: Int, dst: Int, variable: Int, field: Int, subfield: Int) {
    let ty = cfgPlaceKind(p, f, variable, field, subfield)
    let disp = cfgPlaceDisp(p, f, variable, field, subfield)
    if ty >= 2 {
        cfgCopyValue(&mut code, p, ty, cfgVarBase(p, f, dst), disp)
    } else {
        if ty == 1 {
            x64LoadMem8(&mut code, 0, 5, disp)
        } else {
            x64LoadMem64(&mut code, 0, 5, disp)
        }
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, dst)], 0)
    }
}

fn cfgCopyStruct(code: &mut X64Code, p: &CfgProgram, f: Int, dst: Int, src: Int) {
    let ty = p.types_code[cfgVarIndex(p, f, dst)]
    cfgCopyValue(&mut code, p, ty, cfgVarBase(p, f, dst), cfgVarBase(p, f, src))
}

fn cfgEmitInstruction(code: &mut X64Code, p: &CfgProgram, f: Int, inst: &CfgInst, call_at: &mut List<Int>, call_target: &mut List<Int>, overflow_at: &mut List<Int>, bad_variant_at: &mut List<Int>) {
    if inst.kind == 1 {
        if p.types_code[cfgVarIndex(p, f, inst.dst)] >= 2 {
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
            overflow_at.push(x64OverflowPlaceholder(&mut code))
        } else if inst.op == 2 {
            x64SubReg(&mut code, 0, 1)
            overflow_at.push(x64OverflowPlaceholder(&mut code))
        } else if inst.op == 3 {
            x64MulReg(&mut code, 0, 1)
            overflow_at.push(x64OverflowPlaceholder(&mut code))
        } else {
            x64CmpReg(&mut code, 0, 1)
            x64SetCondition(&mut code, inst.op)
        }
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } else if inst.kind == 3 {
        if inst.argc >= 1 { cfgLoadOperand(&mut code, p, f, &inst.a, 7) }
        if inst.argc == 2 { cfgLoadOperand(&mut code, p, f, &inst.b, 6) }
        call_at.push(x64CallPlaceholder(&mut code))
        call_target.push(inst.callee)
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
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
        x64LoadMem64(&mut code, 0, 5, cfgVarBase(p, f, inst.place_var))
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } else if inst.kind == 9 {
        // Checked payload extraction: an unmatched variant exits with 126.
        // Never read [enum+8] until the actual discriminant has been tested.
        let owner = cfgVarBase(p, f, inst.place_var)
        x64LoadMem64(&mut code, 0, 5, owner)
        x64MovImm64(&mut code, 1, inst.place_field)
        x64CmpReg(&mut code, 0, 1)
        bad_variant_at.push(x64ConditionalPlaceholder(&mut code, false))
        let e = &p.enums[inst.op]
        let payload = p.variants[e.first_variant + inst.place_field].payload_type
        if payload == 1 {
            x64LoadMem8(&mut code, 0, 5, owner + 8)
        } else {
            x64LoadMem64(&mut code, 0, 5, owner + 8)
        }
        x64StoreSlot(&mut code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } else if inst.kind == 10 {
        // Runtime routines are addressed by negative call targets:
        // -1 print Int, -2 print Bool. Value travels in RDI.
        cfgLoadOperand(&mut code, p, f, &inst.a, 7)
        call_at.push(x64CallPlaceholder(&mut code))
        if cfgOperandType(p, f, &inst.a) == 1 {
            call_target.push(-2)
        } else {
            call_target.push(-1)
        }
    } else {
        code.error = 10
    }
}

fn cfgEmitTerm(code: &mut X64Code, p: &CfgProgram, f: Int, block: &CfgBlock, func: &CfgFunc, jump_at: &mut List<Int>, jump_target: &mut List<Int>) {
    if block.term == 1 {
        if func.result_unit {
            // Unit has no representation; a unit `main` exits with status 0.
            x64MovImm64(&mut code, 0, 0)
        } else {
            cfgLoadOperand(&mut code, p, f, &block.value, 0)
        }
        x64FrameEnd(&mut code)
    } else if block.term == 2 {
        jump_at.push(x64JumpPlaceholder(&mut code))
        jump_target.push(func.first_block + block.yes)
    } else if block.term == 3 {
        cfgLoadOperand(&mut code, p, f, &block.value, 0)
        x64TestRax(&mut code)
        jump_at.push(x64ConditionalPlaceholder(&mut code, false))
        jump_target.push(func.first_block + block.yes)
        jump_at.push(x64JumpPlaceholder(&mut code))
        jump_target.push(func.first_block + block.no)
    } else if block.term == 4 {
        x64Unreachable(&mut code)
    } else {
        code.error = 11
    }
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
    var call_at: List<Int> = List[]
    var call_to: List<Int> = List[]
    var jump_at: List<Int> = List[]
    var jump_to: List<Int> = List[]
    var overflow_at: List<Int> = List[]
    var bad_variant_at: List<Int> = List[]
    for f in 0..p.functions.length { func_at.push(-1) }
    for b in 0..p.blocks.length { block_at.push(-1) }

    // ELF entry point. At process startup RSP is aligned to 16 bytes;
    // CALL enters main with 8-byte return-address alignment.
    call_at.push(x64CallPlaceholder(&mut code))
    call_to.push(p.main)
    x64MovReg(&mut code, 7, 0) // sys_exit argument RDI = return RAX
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

    // The print runtime is emitted only for programs that print, so images
    // of programs without output keep their previous exact bytes.
    var prints = false
    for i in 0..p.insts.length {
        if p.insts[i].kind == 10 { prints = true }
    }
    var print_int_at = -1
    var print_bool_at = -1
    if prints {
        print_int_at = code.bytes.length
        rtEmitPrintInt(&mut code)
        print_bool_at = code.bytes.length
        rtEmitPrintBool(&mut code)
    }

    for f in 0..p.functions.length {
        let func = &p.functions[f]
        func_at[f] = code.bytes.length
        x64FrameBegin(&mut code, cfgFrameSlots(p, f))
        if func.params >= 1 { x64StoreSlot(&mut code, p.slot_start[func.first_var], 7) }
        if func.params == 2 { x64StoreSlot(&mut code, p.slot_start[func.first_var + 1], 6) }
        for b in 0..func.blocks {
            let index = func.first_block + b
            block_at[index] = code.bytes.length
            let block = &p.blocks[index]
            for i in block.first..(block.first + block.count) {
                let inst = &p.insts[i]
            cfgEmitInstruction(&mut code, p, f, &inst, &mut call_at, &mut call_to, &mut overflow_at, &mut bad_variant_at)
                if code.error != 0 { break }
            }
            if code.error != 0 { break }
            cfgEmitTerm(&mut code, p, f, block, func, &mut jump_at, &mut jump_to)
            if code.error != 0 { break }
        }
        if code.error != 0 { break }
    }

    if code.error != 0 {
        result.error = 70
        return result
    }
    for i in 0..call_at.length {
        let target = call_to[i]
        if target == -1 {
            x64PatchRelative(&mut code, call_at[i], print_int_at)
        } else if target == -2 {
            x64PatchRelative(&mut code, call_at[i], print_bool_at)
        } else {
            x64PatchRelative(&mut code, call_at[i], func_at[target])
        }
    }
    for i in 0..jump_at.length {
        x64PatchRelative(&mut code, jump_at[i], block_at[jump_to[i]])
    }
    for i in 0..overflow_at.length {
        x64PatchRelative(&mut code, overflow_at[i], overflow_handler)
    }
    for i in 0..bad_variant_at.length {
        x64PatchRelative(&mut code, bad_variant_at[i], bad_variant_handler)
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
