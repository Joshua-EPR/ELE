take lir_tokens
take native_cfg_defs
take native_cfg_types
take native_cfg_ref
take native_cfg_text
take x86_64

// `i platform vD <op> <argc> <args>` (instruction kind 24) of ELE-LIR 1:
// the platform builtins processArgCount, processArg, readText, printError
// and writeBytes, lowered to the routines of native_rt_platform (Linux
// ELF64) or win64_rt_platform (Windows PE32+, KERNEL32 only). `op` holds the ELE-LIR platform code, the same numbering as
// Stage 1 (lir_build.l): 0 argcount, 1 arg, 2 readtext, 3 printerror,
// 4 writebytes. Arguments live in the call argument tables from
// `arg_first`, as for `call`, so the verifier treats them alike: `val`
// operands are read, `ref` places must be live and stay owned.
//
// Signatures, checked here exactly as Stage 1's lirVerifyPlatform does:
//   argcount 0                     -> Int
//   arg 1 val <Int>                -> Result<Text,Int>
//   readtext 2 ref <Text> 0 val <Int> -> Result<Text,Int>
//   printerror 1 ref <Text> 0      -> Unit
//   writebytes 2 ref <Text> 0 ref <List of[Int]> 0 -> Int
//   samefile 2 ref <Text> 0 ref <Text> 0 -> Int
//   consolemode 1 val <Int>        -> Int (codes 6 and 7: raw console
//   readevent 0                    -> Int  input, see win64_rt_platform)
//   writeconsole 1 ref <List of[Int]> 0 -> Int (binary stdout, no newline)
// File streams (codes 9..16). A File is an Int below sema: shared `ref`
// for operations on an open file, `val` only for the consuming close.
//   fileopen 2 ref <Text> 0 val <Int>                       -> Int
//   fileread 3 ref <Int> 0 ref <List of[Int]> 1 val <Int>   -> Int
//   filewrite 3 ref <Int> 0 ref <List of[Int]> 0 val <Int>  -> Int
//   fileseek 3 ref <Int> 0 val <Int> val <Int>              -> Int
//   filesize 1 ref <Int> 0 / fileflush 1 ref <Int> 0         -> Int
//   fileclose 1 val <Int> / filestatus 1 ref <Int> 0         -> Int
// fileread is the only platform call with an exclusive borrow: it stores
// into the elements of the caller's list.
// Result<Text,Int> is any declared enum with exactly two variants whose
// payloads are Text (variant 0, Ok) and Int (variant 1, Err).
//
// Rejection codes: 130 unknown operation or wrong arity, 131 argument of
// the wrong mode or type (a platform call never borrows exclusively),
// 132 destination of the wrong type. (133, a platform call on a target
// without the platform runtime, is no longer produced: both targets have it.)

// Platform routine k is called as runtime target cfgPlatformBase() + k,
// far above the native_rt, native_rt_list and drop glue indexes.
expose flow cfgPlatformBase() => Int { give 1048576 }

flow cfgPlatformCode(source: view Text, word: view NativeWord) => Int {
    when nativeEquals(source, word, "argcount") { give 0 }
    when nativeEquals(source, word, "arg") { give 1 }
    when nativeEquals(source, word, "readtext") { give 2 }
    when nativeEquals(source, word, "printerror") { give 3 }
    when nativeEquals(source, word, "writebytes") { give 4 }
    when nativeEquals(source, word, "samefile") { give 5 }
    when nativeEquals(source, word, "consolemode") { give 6 }
    when nativeEquals(source, word, "readevent") { give 7 }
    when nativeEquals(source, word, "writeconsole") { give 8 }
    when nativeEquals(source, word, "fileopen") { give 9 }
    when nativeEquals(source, word, "fileread") { give 10 }
    when nativeEquals(source, word, "filewrite") { give 11 }
    when nativeEquals(source, word, "fileseek") { give 12 }
    when nativeEquals(source, word, "filesize") { give 13 }
    when nativeEquals(source, word, "fileflush") { give 14 }
    when nativeEquals(source, word, "fileclose") { give 15 }
    when nativeEquals(source, word, "filestatus") { give 16 }
    when nativeEquals(source, word, "windowopen") { give 17 }
    when nativeEquals(source, word, "windowstatus") { give 18 }
    when nativeEquals(source, word, "windownext") { give 19 }
    when nativeEquals(source, word, "windowfill") { give 20 }
    when nativeEquals(source, word, "windowtext") { give 21 }
    when nativeEquals(source, word, "windowpresent") { give 22 }
    when nativeEquals(source, word, "windowsend") { give 23 }
    when nativeEquals(source, word, "windowpixel") { give 24 }
    when nativeEquals(source, word, "windowclose") { give 25 }
    give -1
}

// Window ops (17..25), re-checked here independently of Stage 1's table:
// the arity, then the kind of each argument as in cfgFileArgOk, plus
// 4 = shared `ref` to a Text.
flow cfgWindowArity(op: Int) => Int {
    when op == 17 || op == 24 { give 3 }
    when op == 20 { give 6 }
    when op == 21 { give 5 }
    when op == 23 { give 4 }
    give 1
}

flow cfgWindowArgKind(op: Int, i: Int) => Int {
    when op == 17 {
        when i == 0 { give 4 }
        give 0
    }
    when op == 25 { give 0 }
    when i == 0 { give 1 }
    when op == 21 && i == 3 { give 4 }
    give 0
}

flow cfgCheckWindowPlatform(p: view CfgProgram, f: Int, inst: view CfgInst) => Bool {
    each i among 0..inst.argc {
        hold kind = cfgWindowArgKind(inst.op, i)
        hold k = inst.arg_first + i
        when kind == 4 {
            when !cfgPlatformArgOk(p, f, k, true, false) { give false }
        } otherwise when !cfgFileArgOk(p, f, k, kind) { give false }
    }
    give true
}

// Window op argument registers in the internal convention: RDI, RSI, RDX,
// RCX, R8, R9. Ref arguments (positions 0 and 3 only) are addressed first,
// because address computations clobber RAX and R8-R11; then values load.
flow cfgEmitWindowArgs(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    hold regs: List of[Int] = List[7, 6, 2, 1, 8, 9]
    each i among 0..inst.argc {
        hold kind = cfgWindowArgKind(inst.op, i)
        when kind == 1 || kind == 4 {
            cfgPlatformArgAddress(edit code, p, f, inst.arg_first + i, edit fix)
            when kind == 1 { x64LoadMem64(edit code, regs[i], 0, 0) }
            otherwise { x64MovReg(edit code, regs[i], 0) }
        }
    }
    each i among 0..inst.argc {
        hold kind = cfgWindowArgKind(inst.op, i)
        when kind == 0 {
            hold operand = view p.call_args[inst.arg_first + i]
            cfgLoadOperand(edit code, p, f, view operand, regs[i])
        }
    }
}

expose flow cfgReadPlatform(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst) {
    inst.kind = 24
    inst.dst = nativeId(source, edit reader, 118)
    hold name = nativeWord(source, edit reader)
    inst.op = cfgPlatformCode(source, view name)
    inst.argc = nativeNumber(source, edit reader)
    when reader.error != 0 || inst.op < 0 || inst.argc < 0 || inst.argc > 6 {
        p.error = 130
        give
    }
    inst.arg_first = p.call_args.length
    each n among 0..inst.argc {
        hold arg_error = cfgReadCallArg(edit p, f, source, edit reader)
        when arg_error != 0 {
            p.error = arg_error
            leave
        }
    }
}

flow cfgPlatformArity(op: Int) => Int {
    when op >= 17 { give cfgWindowArity(op) }
    when op == 0 || op == 7 { give 0 }
    when op == 1 || op == 3 || op == 6 || op == 8 || op >= 13 { give 1 }
    when op >= 10 && op <= 12 { give 3 }
    give 2
}

// File argument `k`: 0 `val` Int, 1 shared `ref` to an Int (the File),
// 2 shared `ref` to a List of[Int], 3 exclusive `ref` to a List of[Int].
flow cfgFileArgOk(p: view CfgProgram, f: Int, k: Int, want: Int) => Bool {
    hold ty = cfgPlatformArgType(p, f, k)
    when want == 0 { give p.call_ref[k] == -1 && ty == 0 }
    when want == 1 { give p.call_ref[k] == 0 && ty == 0 }
    when want == 2 && p.call_ref[k] != 0 { give false }
    when want == 3 && p.call_ref[k] != 1 { give false }
    hold index = cfgListIndex(p, ty)
    give index >= 0 && p.list_elem[index] == 0
}

flow cfgCheckFilePlatform(p: view CfgProgram, f: Int, inst: view CfgInst) => Bool {
    hold first = inst.arg_first
    when inst.op == 9 { give cfgPlatformArgOk(p, f, first, true, false) && cfgFileArgOk(p, f, first + 1, 0) }
    when inst.op == 10 { give cfgFileArgOk(p, f, first, 1) && cfgFileArgOk(p, f, first + 1, 3) && cfgFileArgOk(p, f, first + 2, 0) }
    when inst.op == 11 { give cfgFileArgOk(p, f, first, 1) && cfgFileArgOk(p, f, first + 1, 2) && cfgFileArgOk(p, f, first + 2, 0) }
    when inst.op == 12 { give cfgFileArgOk(p, f, first, 1) && cfgFileArgOk(p, f, first + 1, 0) && cfgFileArgOk(p, f, first + 2, 0) }
    when inst.op == 15 { give cfgFileArgOk(p, f, first, 0) }
    give cfgFileArgOk(p, f, first, 1)
}

// Type of argument `k` (an index into the call argument tables): the place
// type of a `ref`, the operand type of a `val`.
flow cfgPlatformArgType(p: view CfgProgram, f: Int, k: Int) => Int {
    hold arg = view p.call_args[k]
    when p.call_ref[k] < 0 { give cfgOperandType(p, f, view arg) }
    hold place = CfgPlace(variable: arg.value, field: p.call_field[k], subfield: p.call_sub[k], ext: p.call_ext[k])
    give cfgPlaceType(p, f, view place)
}

// 0 when argument `k` is `val` with type Int; for `ref`, a shared borrow
// of a Text (`list` false) or of a List of[Int] (`list` true).
flow cfgPlatformArgOk(p: view CfgProgram, f: Int, k: Int, by_ref: Bool, list: Bool) => Bool {
    hold ty = cfgPlatformArgType(p, f, k)
    when !by_ref { give p.call_ref[k] == -1 && ty == 0 }
    when p.call_ref[k] != 0 { give false }
    when !list { give ty == cfgTextType() }
    hold index = cfgListIndex(p, ty)
    give index >= 0 && p.list_elem[index] == 0
}

// Whether `ty` is a Result<Text,Int> as Stage 1 lays it out.
flow cfgIsTextResult(p: view CfgProgram, ty: Int) => Bool {
    hold e = ty - 2 - p.structs.length
    when ty < 2 || e < 0 || e >= p.enums.length { give false }
    hold item = view p.enums[e]
    when item.variants != 2 { give false }
    give p.variants[item.first_variant].payload_type == cfgTextType() && p.variants[item.first_variant + 1].payload_type == 0
}

expose flow cfgCheckPlatform(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    when inst.op < 0 || inst.op > 25 || inst.argc != cfgPlatformArity(inst.op) { give 130 }
    hold first = inst.arg_first
    when inst.op >= 9 && inst.op <= 16 && !cfgCheckFilePlatform(p, f, inst) { give 131 }
    when inst.op >= 17 && !cfgCheckWindowPlatform(p, f, inst) { give 131 }
    when (inst.op == 1 || inst.op == 6) && !cfgPlatformArgOk(p, f, first, false, false) { give 131 }
    when inst.op == 2 {
        when !cfgPlatformArgOk(p, f, first, true, false) || !cfgPlatformArgOk(p, f, first + 1, false, false) { give 131 }
    }
    when inst.op == 3 && !cfgPlatformArgOk(p, f, first, true, false) { give 131 }
    when inst.op == 4 {
        when !cfgPlatformArgOk(p, f, first, true, false) || !cfgPlatformArgOk(p, f, first + 1, true, true) { give 131 }
    }
    when inst.op == 5 {
        when !cfgPlatformArgOk(p, f, first, true, false) || !cfgPlatformArgOk(p, f, first + 1, true, false) { give 131 }
    }
    when inst.op == 8 && !cfgPlatformArgOk(p, f, first, true, true) { give 131 }
    hold dest = p.types_code[p.functions[f].first_var + inst.dst]
    when (inst.op == 0 || inst.op == 4) && dest != 0 { give 132 }
    when inst.op == 3 && dest != cfgUnitType() { give 132 }
    when inst.op >= 5 && dest != 0 { give 132 }
    when (inst.op == 1 || inst.op == 2) && !cfgIsTextResult(p, dest) { give 132 }
    give 0
}

// RAX = address of the place of `ref` argument `k`.
flow cfgPlatformArgAddress(code: edit X64Code, p: view CfgProgram, f: Int, k: Int, fix: edit CfgFix) {
    hold arg = view p.call_args[k]
    cfgPlaceAddressRax(edit code, p, f, arg.value, p.call_field[k], p.call_sub[k], p.call_ext[k], edit fix)
}

// Loads the routine arguments (native_rt_platform convention) and calls it.
// Address computations clobber RAX and R8-R11 only, so registers loaded
// before them survive.
expose flow cfgEmitPlatform(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    hold first = inst.arg_first
    hold dst_slot = p.slot_start[cfgVarIndex(p, f, inst.dst)]
    when inst.op == 1 {
        hold index = view p.call_args[first]
        cfgLoadOperand(edit code, p, f, view index, 7)
        cfgPlaceAddressRax(edit code, p, f, inst.dst, -1, -1, -1, edit fix)
        x64MovReg(edit code, 6, 0)
    } otherwise when inst.op == 2 {
        cfgPlaceAddressRax(edit code, p, f, inst.dst, -1, -1, -1, edit fix)
        x64MovReg(edit code, 2, 0)
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64MovReg(edit code, 7, 0)
        hold limit = view p.call_args[first + 1]
        cfgLoadOperand(edit code, p, f, view limit, 6)
    } otherwise when inst.op == 3 {
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64LoadMem64(edit code, 7, 0, 0)
        x64LoadMem64(edit code, 6, 0, 8)
    } otherwise when inst.op == 4 {
        cfgPlatformArgAddress(edit code, p, f, first + 1, edit fix)
        x64MovReg(edit code, 6, 0)
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64MovReg(edit code, 7, 0)
    } otherwise when inst.op == 5 {
        cfgPlatformArgAddress(edit code, p, f, first + 1, edit fix)
        x64MovReg(edit code, 6, 0)
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64MovReg(edit code, 7, 0)
    } otherwise when inst.op == 6 {
        hold mode = view p.call_args[first]
        cfgLoadOperand(edit code, p, f, view mode, 7)
    } otherwise when inst.op == 8 {
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64MovReg(edit code, 7, 0)
    } otherwise when inst.op == 9 {
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64MovReg(edit code, 7, 0)
        hold mode = view p.call_args[first + 1]
        cfgLoadOperand(edit code, p, f, view mode, 6)
    } otherwise when inst.op == 10 || inst.op == 11 {
        cfgPlatformArgAddress(edit code, p, f, first + 1, edit fix)
        x64MovReg(edit code, 6, 0)
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64LoadMem64(edit code, 7, 0, 0)
        hold count = view p.call_args[first + 2]
        cfgLoadOperand(edit code, p, f, view count, 2)
    } otherwise when inst.op == 12 {
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64LoadMem64(edit code, 7, 0, 0)
        hold offset = view p.call_args[first + 1]
        cfgLoadOperand(edit code, p, f, view offset, 6)
        hold whence = view p.call_args[first + 2]
        cfgLoadOperand(edit code, p, f, view whence, 2)
    } otherwise when inst.op == 15 {
        hold file = view p.call_args[first]
        cfgLoadOperand(edit code, p, f, view file, 7)
    } otherwise when inst.op >= 17 {
        cfgEmitWindowArgs(edit code, p, f, inst, edit fix)
    } otherwise when inst.op >= 13 {
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64LoadMem64(edit code, 7, 0, 0)
    }
    cfgRuntimeCall(edit code, edit fix, cfgPlatformBase() + inst.op)
    when inst.op == 0 || inst.op >= 4 {
        x64StoreSlot(edit code, dst_slot, 0)
    }
}
