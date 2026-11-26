take native_cfg_defs
take native_cfg_types
take native_cfg_verify
take x86_64
take elf64
take elf64_kernel
take pe64
take win64_rt
take win64_heap
take native_rt
take native_rt_list
take native_cfg_text
take native_cfg_arith
take native_cfg_list_emit
take native_cfg_fields
take native_cfg_ir
take native_cfg_platform
take native_rt_platform
take win64_rt_platform
take native_trap
take native_rt_float

// x86-64 ELF64 lowering for CFG with move-only structs, owned Text and lists
// (native_cfg_list_emit). Calls use an ELE-internal convention: arguments on the stack, results
// in RAX (Int, Bool) or RAX, RDX, RCX (Text). The entry stub performs Linux
// sys_exit(main()), without libc, Rust or a linker.

expose shape CfgImage {
    image: List of[Int]
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
    hold whole_referent = field < 0 && ext < 0
    when (ext >= 0 || whole_referent) && cfgOwnsHeap(p, ty) {
        // Indexed owners have no partial-move flag: the old element is live.
        // A whole referent is live too (native_cfg_verify requires it whole).
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
    } otherwise when inst.kind == 2 && cfgOperandType(p, f, view inst.a) == cfgFloatType() {
        cfgEmitFloatBinary(edit code, p, f, inst)
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
        } otherwise when inst.op >= 12 {
            cfgEmitBitwise(edit code, edit fix, inst.op)
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
        when kind.size > 8 {
            // Zero-fill the whole payload area to keep the complete value
            // initialized: moves of unit variants, Bool payloads and
            // aggregates smaller than the largest payload copy defined words.
            x64MovImm64(edit code, 0, 0)
            each w among 1..(kind.size / 8) {
                x64StoreMem64(edit code, 5, dest + 8 * w, 0)
            }
            when inst.argc == 1 {
                hold payload = p.variants[kind.first_variant + inst.place_field].payload_type
                when payload == cfgTextType() {
                    cfgTextWords(edit code, p, f, view inst.a, edit fix)
                    x64StoreMem64(edit code, 5, dest + 8, 0)
                    x64StoreMem64(edit code, 5, dest + 16, 2)
                    x64StoreMem64(edit code, 5, dest + 24, 1)
                } otherwise when payload >= 2 {
                    // A shape/choice moved in (the verifier kills
                    // the source): copy its layout into the payload area.
                    cfgCopyValue(edit code, p, payload, 5, dest + 8, 5, cfgVarBase(p, f, inst.a.value))
                } otherwise {
                    cfgLoadOperand(edit code, p, f, view inst.a, 0)
                    when payload == 1 {
                        x64StoreMem8(edit code, 5, dest + 8, 0)
                    } otherwise {
                        x64StoreMem64(edit code, 5, dest + 8, 0)
                    }
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
        when payload >= 2 || payload == cfgTextType() {
            // Aggregate or Text payload: copied by layout only after the check. The
            // verifier treats this as a move of the whole (owned) enum.
            cfgCopyValue(edit code, p, payload, 5, cfgVarBase(p, f, inst.dst), at.base, owner + 8)
        } otherwise when payload == 1 {
            x64LoadMem8(edit code, 0, at.base, owner + 8)
            x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
        } otherwise {
            x64LoadMem64(edit code, 0, at.base, owner + 8)
            x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
        }
    } otherwise when inst.kind == 16 {
        cfgEmitUnary(edit code, p, f, inst, edit fix)
    } otherwise when (inst.kind >= 18 && inst.kind <= 21) || inst.kind == 23 {
        cfgEmitList(edit code, p, f, inst, edit fix)
    } otherwise when inst.kind == 22 {
        // loan: the address of the place becomes the local reference.
        cfgPlaceAddressRax(edit code, p, f, inst.place_var, inst.place_field, inst.place_subfield, inst.place_ext, edit fix)
        x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    } otherwise when inst.kind == 24 {
        cfgEmitPlatform(edit code, p, f, inst, edit fix)
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
    } otherwise when block.term == 5 {
        // returnref: the reference's slot holds the referent's address.
        x64LoadSlot(edit code, 0, p.slot_start[cfgVarIndex(p, f, block.value.value)])
        x64FrameEnd(edit code)
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

// The drop glue table (cfgEmitDropGlue) is emitted when a list type exists,
// when some `i drop` releases a whole union (cfgEmitUnionGlue), or when a
// shape- or union-typed value is released by `dropfield` or replaced by a
// whole `store` through a reference. Other programs keep their glue-free
// image.
flow cfgNeedsGlue(p: view CfgProgram) => Bool {
    when p.decl_lists > 0 { give true }
    hold first_enum = 2 + p.decl_structs
    each f among 0..p.functions.length {
        hold func = view p.functions[f]
        each b among func.first_block..(func.first_block + func.blocks) {
            hold block = view p.blocks[b]
            each i among block.first..(block.first + block.count) {
                hold inst = view p.insts[i]
                when inst.kind == 13 {
                    hold owner = p.types_code[func.first_var + inst.place_var]
                    when owner >= first_enum && owner < first_enum + p.decl_enums { give true }
                }
                hold whole_store = inst.kind == 6 && inst.place_field < 0 && inst.place_ext < 0
                when inst.kind == 17 || whole_store {
                    hold place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: -1)
                    hold ty = cfgPlaceType(p, f, view place)
                    when ty >= 2 && cfgOwnsHeap(p, ty) { give true }
                }
            }
        }
    }
    give false
}

flow cfgNeedsRuntime(p: view CfgProgram) => Bool {
    // A list type brings its growth routine and drop glue, which release
    // Text elements through the runtime; so does an owning union.
    when cfgNeedsGlue(p) { give true }
    each i among 0..p.insts.length {
        // The platform runtime allocates and releases through native_rt.
        when (p.insts[i].kind >= 10 && p.insts[i].kind <= 13) || p.insts[i].kind == 17 { give true }
        when p.insts[i].kind == 24 && !cfgIsIntrinsic(p.insts[i].op) { give true }
    }
    give false
}

// Platform calls served by a runtime routine (not the inline intrinsics).
flow cfgUsesPlatformRuntime(p: view CfgProgram) => Bool {
    each i among 0..p.insts.length {
        when p.insts[i].kind == 24 && !cfgIsIntrinsic(p.insts[i].op) { give true }
    }
    give false
}

// Whether the program calls the console input operations (platform codes 6
// consolemode, 7 readevent). Their routines, and on Windows their imports
// (GetConsoleMode, SetConsoleMode, ReadConsoleInputW), are emitted only
// then, so other images keep their import tables unchanged.
flow cfgUsesConsole(p: view CfgProgram) => Bool {
    each i among 0..p.insts.length {
        when p.insts[i].kind == 24 && (p.insts[i].op == 6 || p.insts[i].op == 7) { give true }
    }
    give false
}

flow cfgUsesConsoleOutput(p: view CfgProgram) => Bool {
    each i among 0..p.insts.length {
        when p.insts[i].kind == 24 && p.insts[i].op == 8 { give true }
    }
    give false
}

// File stream routines (platform codes 9..16) only for programs using them,
// so every other image keeps its exact bytes and imports.
flow cfgUsesFiles(p: view CfgProgram) => Bool {
    each i among 0..p.insts.length {
        when p.insts[i].kind == 24 && p.insts[i].op >= 9 && p.insts[i].op <= 16 { give true }
    }
    give false
}

// textFromBytes (platform code 30), likewise only when used.
flow cfgUsesTextBytes(p: view CfgProgram) => Bool {
    each i among 0..p.insts.length {
        when p.insts[i].kind == 24 && p.insts[i].op == 30 { give true }
    }
    give false
}

// Window routines (platform codes 17..27), likewise only when used.
flow cfgUsesWindows(p: view CfgProgram) => Bool {
    each i among 0..p.insts.length {
        when p.insts[i].kind == 24 && p.insts[i].op >= 17 && p.insts[i].op <= 27 { give true }
    }
    give false
}

flow cfgUsesClipboard(p: view CfgProgram) => Bool {
    each i among 0..p.insts.length {
        when p.insts[i].kind == 24 && (p.insts[i].op == 28 || p.insts[i].op == 29) { give true }
    }
    give false
}

// Index of the function named `name` (decoded LIR names), or -1.
flow cfgFindFunction(p: view CfgProgram, name: view Text) => Int {
    each f among 0..p.name_start.length {
        when p.name_length[f] == name.byteLength {
            change same = true
            each i among 0..name.byteLength {
                when p.name_bytes[p.name_start[f] + i] != name@byteAt(i) { same = false }
            }
            when same { give f }
        }
    }
    give -1
}

expose flow cfgBuild(p: view CfgProgram) => CfgImage {
    give cfgBuildFor(p, 0)
}

// Target 0 is Linux x86-64 ELF64; target 1 is Windows x64 PE32+, whose
// runtime (win64_rt output, win64_heap owned Text and lists on
// VirtualAlloc/VirtualFree) provides the same entries as native_rt and
// native_rt_list. A call to a runtime entry the target does not have is
// rejected with error 73 instead of emitting Linux system calls. A
// rejection by the PE writer (pe64.l codes 1..8) is reported as 111..118.
expose flow cfgBuildFor(p: view CfgProgram, target: Int) => CfgImage {
    change result = CfgImage(image: List[], error: 0)
    hold verified = cfgVerify(p)
    when verified != 0 {
        result.error = verified
        give result
    }
    change code = x64New()
    change func_at: List of[Int] = List[]
    change block_at: List of[Int] = List[]
    change fix = CfgFix(call_at: List[], call_to: List[], jump_at: List[], jump_to: List[], overflow_at: List[], bad_variant_at: List[], bad_index_at: List[], text_at: List[], text_id: List[], static_at: List[], static_kind: List[], static_off: List[], static_rodata: List[], static_data: List[], static_bss: 0, static_error: 0, isr_at: List[])
    each f among 0..p.functions.length { func_at@push(-1) }
    each b among 0..p.blocks.length { block_at@push(-1) }
    when target < 0 || target > 2 {
        result.error = 73
        give result
    }
    // Target 2 (`--target kernel`) has no runtime: nothing that allocates,
    // prints or calls the system (75). cfgParse already requires an entry
    // flow without parameters (50).
    when target == 2 && (cfgNeedsRuntime(p) || cfgNeedsGlue(p) || cfgUsesFloatText(p)) {
        result.error = 75
        give result
    }
    // Platform builtins (native_cfg_platform): native_rt_platform on Linux
    // ELF64, win64_rt_platform (KERNEL32 only) on Windows PE32+.
    hold platform = cfgUsesPlatformRuntime(p)
    change imports = pe64NewImports()
    // Immediates holding the address of the ELF read-write data page.
    change data_at: List of[Int] = List[]

    when target == 1 {
        // PE entry point: ExitProcess(main()).
        hold main_call = w64EmitEntry(edit code, edit imports)
        fix.call_at@push(main_call)
        fix.call_to@push(p.main)
    } otherwise when target == 2 {
        // Kernel entry point: the bootloader jumps here with a valid stack;
        // if the entry flow returns, this CPU stops (CLI; HLT forever).
        cfgCall(edit code, edit fix, p.main)
        x64HaltForever(edit code)
    } otherwise {
        when platform {
            // Keep the initial stack pointer (argc, argv) in the first word
            // of the data page for native_rt_platform. At process entry RSP
            // is 16-byte aligned; the CALL below leaves main's frame as
            // before.
            x64MovImm64(edit code, 0, 0)
            data_at@push(code.bytes.length - 8)
            x64MovReg(edit code, 1, 4)
            x64StoreMem64(edit code, 0, 0, 1)
        }
        // ELF entry point: sys_exit(main()).
        cfgCall(edit code, edit fix, p.main)
        x64MovReg(edit code, 7, 0)
        x64MovImm64(edit code, 0, 60)
        x64Syscall(edit code)
    }
    // Run-time checks (overflow 125, inactive variant 126, index 127) are
    // reported after the functions by native_trap, with their source
    // position; `spans` follows the check lists of `fix`.
    change spans = trapNewSpans()

    // The runtime is emitted only for programs that print or own Text.
    change runtime_at: List of[Int] = List[]
    when cfgNeedsRuntime(p) {
        when target == 1 {
            runtime_at = w64EmitHeapRuntime(edit code, edit imports)
        } otherwise {
            runtime_at = rtEmitAll(edit code)
        }
    }
    when cfgNeedsGlue(p) {
        when target == 1 {
            // list_reserve is already rtListReserve() of the Windows runtime.
            cfgEmitDropGlue(edit code, p, edit fix, edit runtime_at, 1)
        } otherwise {
            cfgEmitListRuntime(edit code, p, edit fix, edit runtime_at)
        }
    }
    // Float text routines, only for programs that print or append a Float.
    change float_at: List of[Int] = List[]
    when cfgUsesFloatText(p) {
        float_at = fltEmitAll(edit code, runtime_at[rtWriteAll()], runtime_at[rtTextAppend()])
    }
    // Runtime and drop-glue indexes share the call target space with the
    // platform routines from cfgPlatformBase() on: they must stay below it.
    when runtime_at.length >= cfgPlatformBase() {
        result.error = 74
        give result
    }
    change platform_at: List of[Int] = List[]
    when platform {
        hold rt = PfRuntime(text_new: runtime_at[rtTextNew()], text_drop: runtime_at[rtTextDrop()])
        hold console = cfgUsesConsole(p)
        hold console_output = cfgUsesConsoleOutput(p)
        hold files = cfgUsesFiles(p)
        hold windows = cfgUsesWindows(p)
        hold clipboard = cfgUsesClipboard(p)
        hold text_bytes = cfgUsesTextBytes(p)
        when target == 1 {
            platform_at = w64EmitPlatform(edit code, edit imports, view rt, console, console_output, files, windows, clipboard, text_bytes, runtime_at[rtListReserve()])
        } otherwise {
            platform_at = pfEmitAll(edit code, view rt, edit data_at, console, console_output, files, windows, clipboard, text_bytes)
        }
    }

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
                trapTag(edit spans, view fix, 0)
                cfgEmitInstruction(edit code, p, f, view inst, edit fix)
                trapTag(edit spans, view fix, trapPack(inst.line, inst.col))
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
    hold functions_end = code.bytes.length
    when fix.static_error != 0 {
        result.error = fix.static_error
        give result
    }
    // Static storage and interrupt stubs exist only in kernel images (77).
    when target != 2 && (fix.static_at.length > 0 || fix.isr_at.length > 0) {
        result.error = 77
        give result
    }
    // Interrupt stubs: emitted when stubInterrupcion is used; the common
    // entry calls the flow `kinterrupcion(marco: Int)` (79 if missing).
    change isr_table = -1
    when fix.isr_at.length > 0 {
        hold handler_name = "kinterrupcion"
        hold handler = cfgFindFunction(p, view handler_name)
        when handler < 0 || p.functions[handler].params != 1 || p.functions[handler].result_type >= 2 {
            result.error = 79
            give result
        }
        isr_table = code.bytes.length
        hold jumps = x64EmitIsrStubs(edit code)
        hold common = code.bytes.length
        each i among 0..jumps.length { x64PatchRelative(edit code, jumps[i], common) }
        hold handler_call = x64EmitIsrCommon(edit code)
        fix.call_at@push(handler_call)
        fix.call_to@push(handler)
    }
    trapTag(edit spans, view fix, 0)
    trapEmitAll(edit code, edit imports, target, view fix, view spans)
    // A runtime routine this target lacks: a safety net, since win64_heap
    // provides every entry of native_rt and native_rt_list.
    change missing_routine = false
    each i among 0..fix.call_at.length {
        hold routine = -1 - fix.call_to[i] - cfgPlatformBase()
        hold platform_routine = routine >= 0 && routine < platform_at.length
        hold float_index = -1 - fix.call_to[i] - cfgFloatRoutineBase()
        hold float_routine = float_index >= 0 && float_index < float_at.length
        when target == 1 && fix.call_to[i] < 0 && -1 - fix.call_to[i] >= runtime_at.length && !platform_routine && !float_routine { missing_routine = true }
        when fix.call_to[i] < 0 && float_index >= 0 && !float_routine { missing_routine = true }
        // A platform routine left out of this image (-1) is never a target.
        when platform_routine && platform_at[routine] < 0 { missing_routine = true }
    }
    when missing_routine {
        result.error = 73
        give result
    }
    each i among 0..fix.call_at.length {
        hold callee = fix.call_to[i]
        hold routine = -1 - callee - cfgPlatformBase()
        when callee >= 0 {
            x64PatchRelative(edit code, fix.call_at[i], func_at[callee])
        } otherwise when -1 - callee - cfgFloatRoutineBase() >= 0 {
            x64PatchRelative(edit code, fix.call_at[i], float_at[-1 - callee - cfgFloatRoutineBase()])
        } otherwise when routine >= 0 && routine < platform_at.length {
            x64PatchRelative(edit code, fix.call_at[i], platform_at[routine])
        } otherwise when -1 - callee < runtime_at.length {
            x64PatchRelative(edit code, fix.call_at[i], runtime_at[-1 - callee])
        } otherwise {
            code.error = 13
        }
    }
    each i among 0..fix.jump_at.length {
        x64PatchRelative(edit code, fix.jump_at[i], block_at[fix.jump_to[i]])
    }
    // Text literals follow the code inside the same read-only segment, one
    // copy per occurrence in the LIR. The kernel image keeps them apart in
    // .rodata (readable, never executable).
    change literal_at: List of[Int] = List[]
    change rodata: List of[Int] = List[]
    hold text_length = code.bytes.length
    each t among 0..p.text_start.length {
        when target == 2 {
            literal_at@push(rodata.length)
            each i among 0..p.text_length[t] {
                rodata@push(p.text_bytes[p.text_start[t] + i])
            }
        } otherwise {
            literal_at@push(code.bytes.length)
            each i among 0..p.text_length[t] {
                code.bytes@push(p.text_bytes[p.text_start[t] + i])
            }
        }
    }
    when target == 2 {
        hold rodata_address = elf64KernelRodataAddress(text_length)
        each i among 0..fix.text_at.length {
            x64PatchAddress64(edit code, fix.text_at[i], rodata_address + literal_at[fix.text_id[i]])
        }
        // cadena records follow the literals, 8-aligned.
        during rodata.length % 8 != 0 { rodata@push(0) }
        hold records_at = rodata.length
        each i among 0..fix.static_rodata.length { rodata@push(fix.static_rodata[i]) }
        hold data_address = elf64KernelDataAddress(text_length, rodata.length)
        hold bss_address = elf64KernelBssAddress(text_length, rodata.length, fix.static_data.length)
        each i among 0..fix.static_at.length {
            change base = rodata_address + records_at
            when fix.static_kind[i] == 1 { base = data_address }
            when fix.static_kind[i] == 2 { base = bss_address }
            x64PatchAddress64(edit code, fix.static_at[i], base + fix.static_off[i])
        }
        each i among 0..fix.isr_at.length {
            x64PatchAddress64(edit code, fix.isr_at[i], elf64KernelTextAddress() + isr_table)
        }
        when code.error != 0 {
            result.error = 71
            give result
        }
        // One .symtab entry per flow, sized up to the next flow.
        change sym_size: List of[Int] = List[]
        each f among 0..func_at.length {
            change end = functions_end
            when f + 1 < func_at.length { end = func_at[f + 1] }
            sym_size@push(end - func_at[f])
        }
        result.image = elf64KernelImage(view code.bytes, view rodata, view fix.static_data, fix.static_bss, view p.name_bytes, view p.name_start, view p.name_length, view func_at, view sym_size)
        when result.image.length == 0 { result.error = 72 }
        give result
    }
    change code_address = elf64CodeAddress()
    when target == 1 { code_address = pe64CodeAddress() }
    each i among 0..fix.text_at.length {
        x64PatchAbsolute64(edit code, fix.text_at[i], code_address + literal_at[fix.text_id[i]])
    }
    // The data page follows the final code and literals (elf64.l).
    hold data_address = elf64DataAddress(code.bytes.length)
    each i among 0..data_at.length {
        x64PatchAbsolute64(edit code, data_at[i], data_address)
    }
    when code.error != 0 {
        result.error = 71
        give result
    }
    when target == 1 {
        // The Text literal addresses are the only absolute addresses in
        // the code: each gets a DIR64 base relocation, so the image is
        // relocatable (DYNAMIC_BASE, HIGH_ENTROPY_VA) instead of fixed.
        hold pe = pe64ExecutableRelocatable(view code.bytes, 0, view imports, view fix.text_at)
        when pe.error != 0 {
            // pe64.l writer codes 1..8 are reported as 111..118.
            result.error = 110 + pe.error
            give result
        }
        result.image = pe.bytes
    } otherwise {
        change data_pages = 0
        when data_at.length > 0 { data_pages = 1 }
        result.image = elf64ExecutableData(view code.bytes, data_pages)
    }
    when result.image.length == 0 { result.error = 72 }
    give result
}

expose flow cfgCompile(source: view Text) => CfgImage {
    hold parsed = cfgParse(source)
    give cfgBuild(view parsed)
}

expose flow cfgCompileFor(source: view Text, target: Int) => CfgImage {
    hold parsed = cfgParse(source)
    give cfgBuildFor(view parsed, target)
}
