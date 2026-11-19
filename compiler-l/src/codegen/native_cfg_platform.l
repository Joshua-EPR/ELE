take lir_tokens
take native_cfg_defs
take native_cfg_types
take native_cfg_ref
take native_cfg_text
take x86_64

// `i platform vD <op> <argc> <args>` (instruction kind 24) of ELE-LIR 1:
// the platform builtins processArgCount, processArg, readText, printError
// and writeBytes, lowered to the routines of native_rt_platform (Linux
// ELF64 only). `op` holds the ELE-LIR platform code, the same numbering as
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
// Result<Text,Int> is any declared enum with exactly two variants whose
// payloads are Text (variant 0, Ok) and Int (variant 1, Err).
//
// Rejection codes: 130 unknown operation or wrong arity, 131 argument of
// the wrong mode or type (a platform call never borrows exclusively),
// 132 destination of the wrong type, 133 platform call on a target
// without the platform runtime (PE32+).

// Platform routine k is called as runtime target cfgPlatformBase() + k,
// far above the native_rt, native_rt_list and drop glue indexes.
expose flow cfgPlatformBase() => Int { give 1048576 }

flow cfgPlatformCode(source: view Text, word: view NativeWord) => Int {
    when nativeEquals(source, word, "argcount") { give 0 }
    when nativeEquals(source, word, "arg") { give 1 }
    when nativeEquals(source, word, "readtext") { give 2 }
    when nativeEquals(source, word, "printerror") { give 3 }
    when nativeEquals(source, word, "writebytes") { give 4 }
    give -1
}

expose flow cfgReadPlatform(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst) {
    inst.kind = 24
    inst.dst = nativeId(source, edit reader, 118)
    hold name = nativeWord(source, edit reader)
    inst.op = cfgPlatformCode(source, view name)
    inst.argc = nativeNumber(source, edit reader)
    when reader.error != 0 || inst.op < 0 || inst.argc < 0 || inst.argc > 2 {
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
    when op == 0 { give 0 }
    when op == 1 || op == 3 { give 1 }
    give 2
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
    when inst.op < 0 || inst.op > 4 || inst.argc != cfgPlatformArity(inst.op) { give 130 }
    hold first = inst.arg_first
    when inst.op == 1 && !cfgPlatformArgOk(p, f, first, false, false) { give 131 }
    when inst.op == 2 {
        when !cfgPlatformArgOk(p, f, first, true, false) || !cfgPlatformArgOk(p, f, first + 1, false, false) { give 131 }
    }
    when inst.op == 3 && !cfgPlatformArgOk(p, f, first, true, false) { give 131 }
    when inst.op == 4 {
        when !cfgPlatformArgOk(p, f, first, true, false) || !cfgPlatformArgOk(p, f, first + 1, true, true) { give 131 }
    }
    hold dest = p.types_code[p.functions[f].first_var + inst.dst]
    when (inst.op == 0 || inst.op == 4) && dest != 0 { give 132 }
    when inst.op == 3 && dest != cfgUnitType() { give 132 }
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
    }
    cfgRuntimeCall(edit code, edit fix, cfgPlatformBase() + inst.op)
    when inst.op == 0 || inst.op == 4 {
        x64StoreSlot(edit code, dst_slot, 0)
    }
}
