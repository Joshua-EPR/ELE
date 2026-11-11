take native_cfg_defs
take native_cfg_types
take native_cfg_verify
take x86_64
take elf64
take native_rt
take native_cfg_text
take native_cfg_arith
take native_cfg_list_emit

// x86-64 ELF64 lowering for CFG with move-only structs, owned Text and lists
// (native_cfg_list_emit). Calls use an ELE-internal convention: arguments on the stack, results
// in RAX (Int, Bool) or RAX, RDX, RCX (Text). The entry stub performs Linux
// sys_exit(main()), without libc, Rust or a linker.

expose shape CfgImage {
    image: List<Int>
    error: Int
}

flow cfgPlaceKind(p: view CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, ext: Int) => Int {
    hold place = CfgPlace(variable: variable, field: field, subfield: subfield, ext: ext)
    give cfgPlaceType(p, f, view place)
}

// Whole struct transfers use these bytes as the physical representation
// of a MOVE, never as permission to duplicate ownership. The verifier
// invalidates moved source variables. Struct-valued field reads are rejected.
// The place may be reached through a reference parameter or a list index.
flow cfgStoreField(code: edit X64Code, p: view CfgProgram, f: Int, variable: Int, field: Int, subfield: Int, ext: Int, value: view NativeOperand, fix: edit CfgFix) {
    hold ty = cfgPlaceKind(p, f, variable, field, subfield, ext)
    when ext >= 0 && cfgOwnsHeap(p, ty) {
        // Indexed owners have no partial-move flag: the old element is live.
        // Drop it before loading the source, then recompute the address since
        // drop glue may clobber caller-saved registers.
        cfgPlaceAddressRax(edit code, p, f, variable, field, subfield, ext, edit fix)
        x64MovReg(edit code, 7, 0)
        cfgDropAt(edit code, edit fix, ty)
    }
    when ty == cfgTextType() {
        // A Text operand, variable or literal, into the field.
        cfgTextWords(edit code, p, f, value, edit fix)
        hold at = cfgPlaceAddr(edit code, p, f, variable, field, subfield, ext, edit fix)
        x64StoreMem64(edit code, at.base, at.disp, 0)
        x64StoreMem64(edit code, at.base, at.disp + 8, 2)
        x64StoreMem64(edit code, at.base, at.disp + 16, 1)
    } otherwise when ty >= 2 {
        when !value.is_var { code.error = 12; give }
        hold at = cfgPlaceAddr(edit code, p, f, variable, field, subfield, ext, edit fix)
        cfgCopyValue(edit code, p, ty, at.base, at.disp, 5, cfgVarBase(p, f, value.value))
    } otherwise {
        cfgLoadOperand(edit code, p, f, value, 0)
        hold at = cfgPlaceAddr(edit code, p, f, variable, field, subfield, ext, edit fix)
        when ty == 1 {
            x64StoreMem8(edit code, at.base, at.disp, 0)
        } otherwise {
            x64StoreMem64(edit code, at.base, at.disp, 0)
        }
    }
}

flow cfgReadField(code: edit X64Code, p: view CfgProgram, f: Int, dst: Int, variable: Int, field: Int, subfield: Int, ext: Int, fix: edit CfgFix) {
    hold ty = cfgPlaceKind(p, f, variable, field, subfield, ext)
    when ty >= 2 || ty == cfgTextType() {
        hold at = cfgPlaceAddr(edit code, p, f, variable, field, subfield, ext, edit fix)
        cfgCopyValue(edit code, p, ty, 5, cfgVarBase(p, f, dst), at.base, at.disp)
    } otherwise {
        cfgLoadPlace(edit code, p, f, variable, field, subfield, ext, ty, 0, edit fix)
        x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, dst)], 0)
    }
}

flow cfgCopyStruct(code: edit X64Code, p: view CfgProgram, f: Int, dst: Int, src: Int) {
    hold ty = p.types_code[cfgVarIndex(p, f, dst)]
    cfgCopyValue(edit code, p, ty, 5, cfgVarBase(p, f, dst), 5, cfgVarBase(p, f, src))
}

flow cfgEmitInstruction(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    when inst.kind == 1 {
        when p.types_code[cfgVarIndex(p, f, inst.dst)] == cfgTextType() {
            cfgTextWords(edit code, p, f, view inst.a, edit fix)
            cfgStoreText(edit code, p, f, inst.dst)
        } otherwise when p.types_code[cfgVarIndex(p, f, inst.dst)] >= 2 {
            cfgCopyStruct(edit code, p, f, inst.dst, inst.a.value)
        } otherwise {
            cfgLoadOperand(edit code, p, f, view inst.a, 0)
            x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
        }
    } otherwise when inst.kind == 2 {
        cfgLoadOperand(edit code, p, f, view inst.a, 0)
        cfgLoadOperand(edit code, p, f, view inst.b, 1)
        when inst.op == 1 {
            x64AddReg(edit code, 0, 1)
            fix.overflow_at@push(x64OverflowPlaceholder(edit code))
        } otherwise when inst.op == 2 {
            x64SubReg(edit code, 0, 1)
            fix.overflow_at@push(x64OverflowPlaceholder(edit code))
        } otherwise when inst.op == 3 {
            x64MulReg(edit code, 0, 1)
            fix.overflow_at@push(x64OverflowPlaceholder(edit code))
        } otherwise when inst.op >= 10 {
            cfgEmitDivRem(edit code, edit fix, inst.op)
        } otherwise {
            x64CmpReg(edit code, 0, 1)
            x64SetCondition(edit code, inst.op)
        }
        x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } otherwise when inst.kind == 3 {
        // Arguments travel on the stack. They are pushed from the last word
        // of the last argument down to the first word of the first one, so
        // the callee finds them in order at RBP+16 upwards.
        change words = 0
        each n among 0..inst.argc {
            hold k = inst.arg_first + inst.argc - 1 - n
            hold arg = view p.call_args[k]
            when p.call_ref[k] >= 0 {
                // A reference argument is the address of its place.
                cfgPlaceAddressRax(edit code, p, f, arg.value, p.call_field[k], p.call_sub[k], p.call_ext[k], edit fix)
                x64PushReg(edit code, 0)
                words += 1
            } otherwise when cfgOperandType(p, f, view arg) == cfgTextType() {
                cfgTextWords(edit code, p, f, view arg, edit fix)
                x64PushReg(edit code, 1)
                x64PushReg(edit code, 2)
                x64PushReg(edit code, 0)
                words += 3
            } otherwise when cfgOperandType(p, f, view arg) >= 2 {
                // A moved shape/choice: every word of its storage, last first.
                hold base = cfgVarBase(p, f, arg.value)
                hold count = p.slot_count[cfgVarIndex(p, f, arg.value)]
                each w among 0..count {
                    x64LoadMem64(edit code, 0, 5, base + 8 * (count - 1 - w))
                    x64PushReg(edit code, 0)
                }
                words += count
            } otherwise {
                cfgLoadOperand(edit code, p, f, view arg, 0)
                x64PushReg(edit code, 0)
                words += 1
            }
        }
        hold result_type = p.functions[inst.callee].result_type
        when result_type >= 2 {
            // Hidden result pointer: the callee writes into the destination.
            cfgPlaceAddressRax(edit code, p, f, inst.dst, -1, -1, -1, edit fix)
            x64PushReg(edit code, 0)
            words += 1
        }
        cfgCall(edit code, edit fix, inst.callee)
        when words > 0 {
            x64MovImm64(edit code, 10, words * 8)
            x64AddReg(edit code, 4, 10)
        }
        when result_type >= 2 {
            // Already stored through the hidden pointer.
        } otherwise when p.types_code[cfgVarIndex(p, f, inst.dst)] == cfgTextType() {
            cfgStoreText(edit code, p, f, inst.dst)
        } otherwise {
            x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
        }
    } otherwise when inst.kind == 4 {
        each n among 0..inst.argc {
            hold arg = view p.struct_args[inst.arg_first + n]
            cfgStoreField(edit code, p, f, inst.dst, n, -1, -1, view arg, edit fix)
            when code.error != 0 { leave }
        }
    } otherwise when inst.kind == 5 {
        cfgReadField(edit code, p, f, inst.dst, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, edit fix)
    } otherwise when inst.kind == 6 {
        cfgStoreField(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, view inst.a, edit fix)
    } otherwise when inst.kind == 7 {
        hold kind = view p.enums[inst.op]
        hold dest = cfgVarBase(p, f, inst.dst)
        x64MovImm64(edit code, 0, inst.place_field)
        x64StoreMem64(edit code, 5, dest, 0)
        when kind.size == 16 {
            // Zero-fill to keep the complete slot initialized and make
            // moves of unit variants and Bool payloads well-defined.
            x64MovImm64(edit code, 0, 0)
            x64StoreMem64(edit code, 5, dest + 8, 0)
            when inst.argc == 1 {
                cfgLoadOperand(edit code, p, f, view inst.a, 0)
                hold payload = p.variants[kind.first_variant + inst.place_field].payload_type
                when payload == 1 {
                    x64StoreMem8(edit code, 5, dest + 8, 0)
                } otherwise {
                    x64StoreMem64(edit code, 5, dest + 8, 0)
                }
            }
        }
    } otherwise when inst.kind == 8 {
        cfgLoadPlace(edit code, p, f, inst.place_var, -1, -1, -1, 0, 0, edit fix)
        x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } otherwise when inst.kind == 9 {
        // Checked payload extraction: an unmatched variant exits with 126.
        // Never read [enum+8] until the actual discriminant has been tested.
        hold at = cfgPlaceAddr(edit code, p, f, inst.place_var, -1, -1, -1, edit fix)
        hold owner = at.disp
        x64LoadMem64(edit code, 0, at.base, owner)
        x64MovImm64(edit code, 1, inst.place_field)
        x64CmpReg(edit code, 0, 1)
        fix.bad_variant_at@push(x64ConditionalPlaceholder(edit code, false))
        hold e = view p.enums[inst.op]
        hold payload = p.variants[e.first_variant + inst.place_field].payload_type
        when payload == 1 {
            x64LoadMem8(edit code, 0, at.base, owner + 8)
        } otherwise {
            x64LoadMem64(edit code, 0, at.base, owner + 8)
        }
        x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } otherwise when inst.kind == 16 {
        cfgEmitUnary(edit code, p, f, inst, edit fix)
    } otherwise when inst.kind >= 18 && inst.kind <= 21 {
        cfgEmitList(edit code, p, f, inst, edit fix)
    } otherwise when inst.kind == 22 {
        // loan: the address of the place becomes the local reference.
        cfgPlaceAddressRax(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, edit fix)
        x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } otherwise {
        cfgEmitText(edit code, p, f, inst, edit fix)
    }
}

flow cfgEmitTerm(code: edit X64Code, p: view CfgProgram, f: Int, block: view CfgBlock, func: view CfgFunc, fix: edit CfgFix) {
    when block.term == 1 {
        when func.result_unit {
            // Unit has no representation; a unit `main` exits with status 0.
            x64MovImm64(edit code, 0, 0)
        } otherwise when func.result_type >= 2 {
            // Copy the aggregate through the hidden pointer at [RBP+16].
            x64LoadMem64(edit code, 11, 5, 16)
            cfgCopyValue(edit code, p, func.result_type, 11, 0, 5, cfgVarBase(p, f, block.value.value))
            x64MovReg(edit code, 0, 11)
        } otherwise when func.result_text {
            // RAX, RDX, RCX: address, byte length, capacity.
            cfgTextWords(edit code, p, f, view block.value, edit fix)
        } otherwise {
            cfgLoadOperand(edit code, p, f, view block.value, 0)
        }
        x64FrameEnd(edit code)
    } otherwise when block.term == 2 {
        fix.jump_at@push(x64JumpPlaceholder(edit code))
        fix.jump_to@push(func.first_block + block.yes)
    } otherwise when block.term == 3 {
        cfgLoadOperand(edit code, p, f, view block.value, 0)
        x64TestRax(edit code)
        fix.jump_at@push(x64ConditionalPlaceholder(edit code, false))
        fix.jump_to@push(func.first_block + block.yes)
        fix.jump_at@push(x64JumpPlaceholder(edit code))
        fix.jump_to@push(func.first_block + block.no)
    } otherwise when block.term == 4 {
        x64Unreachable(edit code)
    } otherwise {
        code.error = 11
    }
}

// Copies the stack arguments of a call into the parameter variables.
flow cfgEmitParams(code: edit X64Code, p: view CfgProgram, f: Int) {
    hold func = view p.functions[f]
    // An aggregate result's hidden pointer occupies the first stack word.
    change word = 0
    when func.result_type >= 2 { word = 1 }
    each i among 0..func.params {
        hold base = cfgVarBase(p, f, i)
        each k among 0..p.slot_count[func.first_var + i] {
            x64LoadMem64(edit code, 0, 5, 16 + 8 * word)
            x64StoreMem64(edit code, 5, base + 8 * k, 0)
            word += 1
        }
    }
}

flow cfgNeedsRuntime(p: view CfgProgram) => Bool {
    // A list type brings its growth routine and drop glue, which release
    // Text elements through the runtime.
    when p.decl_lists > 0 { give true }
    each i among 0..p.insts.length {
        when (p.insts[i].kind >= 10 && p.insts[i].kind <= 13) || p.insts[i].kind == 17 { give true }
    }
    give false
}

flow cfgUsesKind(p: view CfgProgram, kind: Int) => Bool {
    each i among 0..p.insts.length {
        when p.insts[i].kind == kind { give true }
    }
    give false
}

expose flow cfgBuild(p: view CfgProgram) => CfgImage {
    change result = CfgImage(image: List[], error: 0)
    hold verified = cfgVerify(p)
    when verified != 0 {
        result.error = verified
        give result
    }
    change code = x64New()
    change func_at: List<Int> = List[]
    change block_at: List<Int> = List[]
    change fix = CfgFix(call_at: List[], call_to: List[], jump_at: List[], jump_to: List[], overflow_at: List[], bad_variant_at: List[], bad_index_at: List[], text_at: List[], text_id: List[])
    each f among 0..p.functions.length { func_at@push(-1) }
    each b among 0..p.blocks.length { block_at@push(-1) }

    // ELF entry point: sys_exit(main()).
    cfgCall(edit code, edit fix, p.main)
    x64MovReg(edit code, 7, 0)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)
    hold overflow_handler = code.bytes.length
    x64MovImm64(edit code, 7, 125)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)

    hold bad_variant_handler = code.bytes.length
    x64MovImm64(edit code, 7, 126)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)

    // Index out of range (byteAt, list element): exit 127, emitted only when
    // used.
    change bad_index_handler = -1
    when cfgUsesKind(p, 15) || p.proj_kind.length > 0 {
        bad_index_handler = code.bytes.length
        x64MovImm64(edit code, 7, 127)
        x64MovImm64(edit code, 0, 60)
        x64Syscall(edit code)
    }

    // The runtime is emitted only for programs that print or own Text.
    change runtime_at: List<Int> = List[]
    when cfgNeedsRuntime(p) { runtime_at = rtEmitAll(edit code) }
    when p.decl_lists > 0 { cfgEmitListRuntime(edit code, p, edit fix, edit runtime_at) }

    each f among 0..p.functions.length {
        hold func = view p.functions[f]
        func_at[f] = code.bytes.length
        x64FrameBegin(edit code, cfgFrameSlots(p, f))
        cfgEmitParams(edit code, p, f)
        each b among 0..func.blocks {
            hold index = func.first_block + b
            block_at[index] = code.bytes.length
            hold block = view p.blocks[index]
            each i among block.first..(block.first + block.count) {
                hold inst = view p.insts[i]
                cfgEmitInstruction(edit code, p, f, view inst, edit fix)
                when code.error != 0 { leave }
            }
            when code.error != 0 { leave }
            cfgEmitTerm(edit code, p, f, block, func, edit fix)
            when code.error != 0 { leave }
        }
        when code.error != 0 { leave }
    }

    when code.error != 0 {
        result.error = 70
        give result
    }
    each i among 0..fix.call_at.length {
        hold target = fix.call_to[i]
        when target >= 0 {
            x64PatchRelative(edit code, fix.call_at[i], func_at[target])
        } otherwise when -1 - target < runtime_at.length {
            x64PatchRelative(edit code, fix.call_at[i], runtime_at[-1 - target])
        } otherwise {
            code.error = 13
        }
    }
    each i among 0..fix.jump_at.length {
        x64PatchRelative(edit code, fix.jump_at[i], block_at[fix.jump_to[i]])
    }
    each i among 0..fix.bad_index_at.length {
        x64PatchRelative(edit code, fix.bad_index_at[i], bad_index_handler)
    }
    each i among 0..fix.overflow_at.length {
        x64PatchRelative(edit code, fix.overflow_at[i], overflow_handler)
    }
    each i among 0..fix.bad_variant_at.length {
        x64PatchRelative(edit code, fix.bad_variant_at[i], bad_variant_handler)
    }
    // Text literals follow the code inside the same read-only segment, one
    // copy per occurrence in the LIR.
    change literal_at: List<Int> = List[]
    each t among 0..p.text_start.length {
        literal_at@push(code.bytes.length)
        each i among 0..p.text_length[t] {
            code.bytes@push(p.text_bytes[p.text_start[t] + i])
        }
    }
    each i among 0..fix.text_at.length {
        x64PatchAbsolute64(edit code, fix.text_at[i], elf64CodeAddress() + literal_at[fix.text_id[i]])
    }
    when code.error != 0 {
        result.error = 71
        give result
    }
    result.image = elf64Executable(view code.bytes)
    when result.image.length == 0 { result.error = 72 }
    give result
}

expose flow cfgCompile(source: view Text) => CfgImage {
    hold parsed = cfgParse(source)
    give cfgBuild(view parsed)
}
