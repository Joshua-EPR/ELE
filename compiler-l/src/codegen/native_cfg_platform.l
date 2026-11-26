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
// File streams (codes 9..16). File has the distinct LIR type `h`, stored
// as one word. Only fileopen produces one; close consumes it by value.
// Other operations borrow it without changing ownership.
//   fileopen 2 ref <Text> 0 val <Int>                        -> File
//   fileread 3 ref <File> 0 ref <List of[Int]> 1 val <Int>   -> Int
//   filewrite 3 ref <File> 0 ref <List of[Int]> 0 val <Int>  -> Int
//   fileseek 3 ref <File> 0 val <Int> val <Int>              -> Int
//   filesize 1 ref <File> 0 / fileflush 1 ref <File> 0     -> Int
//   fileclose 1 val <File> / filestatus 1 ref <File> 0     -> Int
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
    when nativeEquals(source, word, "windowcell") { give 26 }
    when nativeEquals(source, word, "windowtextbytes") { give 27 }
    when nativeEquals(source, word, "clipboardwrite") { give 28 }
    when nativeEquals(source, word, "clipboardread") { give 29 }
    when nativeEquals(source, word, "textfrombytes") { give 30 }
    give cfgIntrinsicCode(source, word)
}

// Kernel intrinsics (codes 31..72, lir_build.l): inline code, no runtime
// routine, every argument a `val` Int.
flow cfgIntrinsicCode(source: view Text, word: view NativeWord) => Int {
    when nativeEquals(source, word, "hlt") { give 31 }
    when nativeEquals(source, word, "cli") { give 32 }
    when nativeEquals(source, word, "sti") { give 33 }
    when nativeEquals(source, word, "pause") { give 34 }
    when nativeEquals(source, word, "in8") { give 35 }
    when nativeEquals(source, word, "in16") { give 36 }
    when nativeEquals(source, word, "in32") { give 37 }
    when nativeEquals(source, word, "out8") { give 38 }
    when nativeEquals(source, word, "out16") { give 39 }
    when nativeEquals(source, word, "out32") { give 40 }
    when nativeEquals(source, word, "ld8") { give 41 }
    when nativeEquals(source, word, "ld16") { give 42 }
    when nativeEquals(source, word, "ld32") { give 43 }
    when nativeEquals(source, word, "ld64") { give 44 }
    when nativeEquals(source, word, "st8") { give 45 }
    when nativeEquals(source, word, "st16") { give 46 }
    when nativeEquals(source, word, "st32") { give 47 }
    when nativeEquals(source, word, "st64") { give 48 }
    when nativeEquals(source, word, "reservar") { give 49 }
    when nativeEquals(source, word, "datos64") { give 50 }
    when nativeEquals(source, word, "cadena") { give 51 }
    when nativeEquals(source, word, "cpuid") { give 52 }
    when nativeEquals(source, word, "rdtsc") { give 53 }
    when nativeEquals(source, word, "rdmsr") { give 54 }
    when nativeEquals(source, word, "wrmsr") { give 55 }
    when nativeEquals(source, word, "rdcr0") { give 56 }
    when nativeEquals(source, word, "rdcr2") { give 57 }
    when nativeEquals(source, word, "rdcr3") { give 58 }
    when nativeEquals(source, word, "rdcr4") { give 59 }
    when nativeEquals(source, word, "wrcr0") { give 60 }
    when nativeEquals(source, word, "wrcr3") { give 61 }
    when nativeEquals(source, word, "wrcr4") { give 62 }
    when nativeEquals(source, word, "lgdt") { give 63 }
    when nativeEquals(source, word, "lidt") { give 64 }
    when nativeEquals(source, word, "ltr") { give 65 }
    when nativeEquals(source, word, "reloadseg") { give 66 }
    when nativeEquals(source, word, "invlpg") { give 67 }
    when nativeEquals(source, word, "fxsave") { give 68 }
    when nativeEquals(source, word, "fxrstor") { give 69 }
    when nativeEquals(source, word, "wbinvd") { give 70 }
    when nativeEquals(source, word, "isrstub") { give 71 }
    when nativeEquals(source, word, "rdflags") { give 72 }
    when nativeEquals(source, word, "int3") { give 73 }
    when nativeEquals(source, word, "xzero") { give 74 }
    when nativeEquals(source, word, "xload") { give 75 }
    when nativeEquals(source, word, "xstore") { give 76 }
    when nativeEquals(source, word, "xbcast") { give 77 }
    when nativeEquals(source, word, "xmov") { give 78 }
    when nativeEquals(source, word, "xmul") { give 79 }
    when nativeEquals(source, word, "xadd") { give 80 }
    give -1
}

expose flow cfgIsIntrinsic(op: Int) => Bool {
    give op >= 31 && op <= 80
}

// -1: 1..256 arguments (datos64, cadena).
flow cfgIntrinsicArity(op: Int) => Int {
    when op <= 34 { give 0 }
    when op <= 37 { give 1 }
    when op <= 40 { give 2 }
    when op <= 44 { give 1 }
    when op <= 49 { give 2 }
    when op <= 51 { give -1 }
    when op == 52 { give 3 }
    when op == 53 { give 0 }
    when op == 54 { give 1 }
    when op == 55 { give 2 }
    when op <= 59 { give 0 }
    when op <= 65 { give 1 }
    when op == 66 { give 2 }
    when op <= 69 { give 1 }
    when op == 70 { give 0 }
    when op == 71 { give 1 }
    when op == 74 { give 1 }
    when op >= 75 { give 2 }
    give 0
}

flow cfgIntrinsicHasResult(op: Int) => Bool {
    when (op >= 35 && op <= 37) || (op >= 41 && op <= 44) { give true }
    when op >= 49 && op <= 51 { give true }
    when op == 53 || op == 54 || (op >= 56 && op <= 59) { give true }
    give op == 71 || op == 72
}

// Operand width in bytes of in/out (35..40) and ld/st (41..48).
flow cfgIntrinsicWidth(op: Int) => Int {
    when op == 35 || op == 38 || op == 41 || op == 45 { give 1 }
    when op == 36 || op == 39 || op == 42 || op == 46 { give 2 }
    when op == 37 || op == 40 || op == 43 || op == 47 { give 4 }
    give 8
}

// Intrinsics that take their first argument in RAX and their second one
// in RCX (memory access and most CPU forms).
flow cfgIntrinsicRaxRcx(op: Int) => Bool {
    give (op >= 41 && op <= 48) || (op >= 53 && op <= 73)
}

flow cfgCheckIntrinsic(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold arity = cfgIntrinsicArity(inst.op)
    when arity >= 0 && inst.argc != arity { give 130 }
    when arity < 0 && (inst.argc < 1 || inst.argc > 256) { give 130 }
    each i among 0..inst.argc {
        when !cfgPlatformArgOk(p, f, inst.arg_first + i, false, false) { give 131 }
    }
    hold dest = p.types_code[p.functions[f].first_var + inst.dst]
    when cfgIntrinsicHasResult(inst.op) && dest != 0 { give 132 }
    when !cfgIntrinsicHasResult(inst.op) && dest != cfgUnitType() { give 132 }
    give 0
}

// Appends the 8 little-endian bytes of `value` (any Int).
flow cfgPushWord(out: edit List of[Int], value: Int) {
    change x = value
    each i among 0..8 {
        change b = x % 256
        when b < 0 { b += 256 }
        out@push(b)
        x = (x - b) / 256
    }
}

// RAX = address of a static block (kind 0 .rodata, 1 .data, 2 .bss at
// `offset`), patched once the image layout is known (cfgBuildFor).
flow cfgStaticAddress(code: edit X64Code, fix: edit CfgFix, kind: Int, offset: Int) {
    x64MovImm64(edit code, 0, 0)
    fix.static_at@push(code.bytes.length - 8)
    fix.static_kind@push(kind)
    fix.static_off@push(offset)
}

// Static storage intrinsics (49 reservar, 50 datos64, 51 cadena): every
// argument must be a constant (error 78 otherwise).
flow cfgEmitStatic(code: edit X64Code, p: view CfgProgram, inst: view CfgInst, fix: edit CfgFix) {
    hold first = inst.arg_first
    each i among 0..inst.argc {
        when p.call_args[first + i].is_var { fix.static_error = 78 }
    }
    when fix.static_error != 0 { give }
    when inst.op == 49 {
        hold bytes = p.call_args[first].value
        hold align = p.call_args[first + 1].value
        change power = 1
        during power < align && power < 4096 { power = power * 2 }
        when bytes < 1 || bytes > 1073741824 || align < 1 || align > 4096 || power != align {
            fix.static_error = 78
            give
        }
        hold offset = (fix.static_bss + align - 1) / align * align
        fix.static_bss = offset + bytes
        cfgStaticAddress(edit code, edit fix, 2, offset)
    } otherwise when inst.op == 50 {
        hold offset = fix.static_data.length
        each i among 0..inst.argc { cfgPushWord(edit fix.static_data, p.call_args[first + i].value) }
        cfgStaticAddress(edit code, edit fix, 1, offset)
    } otherwise {
        during fix.static_rodata.length % 8 != 0 { fix.static_rodata@push(0) }
        hold offset = fix.static_rodata.length
        hold length = p.call_args[first].value
        when length < 0 || (length + 7) / 8 != inst.argc - 1 {
            fix.static_error = 78
            give
        }
        cfgPushWord(edit fix.static_rodata, length)
        change bytes: List of[Int] = List[]
        each i among 1..inst.argc { cfgPushWord(edit bytes, p.call_args[first + i].value) }
        each i among 0..length { fix.static_rodata@push(bytes[i]) }
        cfgStaticAddress(edit code, edit fix, 0, offset)
    }
}

// XMM register number of argument `k`: a constant 6..15, else error 80.
flow cfgXmmArg(p: view CfgProgram, k: Int, fix: edit CfgFix) => Int {
    hold a = view p.call_args[k]
    when a.is_var || a.value < 6 || a.value > 15 {
        fix.static_error = 80
        give 6
    }
    give a.value
}

// Packed single SSE intrinsics (74..80); memory operands in RAX.
flow cfgEmitSse(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    hold first = inst.arg_first
    hold op = inst.op
    when op == 74 {
        hold r = cfgXmmArg(p, first, edit fix)
        x64SsePacked(edit code, 87, r, r)
        give
    }
    when op == 75 || op == 77 {
        hold r = cfgXmmArg(p, first, edit fix)
        hold address = view p.call_args[first + 1]
        cfgLoadOperand(edit code, p, f, view address, 0)
        when op == 75 { x64SseMemory(edit code, false, 16, r) } otherwise {
            x64SseMemory(edit code, true, 16, r)
            x64Shufps0(edit code, r)
        }
        give
    }
    when op == 76 {
        hold address = view p.call_args[first]
        cfgLoadOperand(edit code, p, f, view address, 0)
        hold r = cfgXmmArg(p, first + 1, edit fix)
        x64SseMemory(edit code, false, 17, r)
        give
    }
    hold d = cfgXmmArg(p, first, edit fix)
    hold s = cfgXmmArg(p, first + 1, edit fix)
    when op == 78 { x64SsePacked(edit code, 40, d, s) }
    when op == 79 { x64SsePacked(edit code, 89, d, s) }
    when op == 80 { x64SsePacked(edit code, 88, d, s) }
}

// Every access is emitted exactly once, in program order: the backend
// keeps no value in a register across instructions.
flow cfgEmitIntrinsic(code: edit X64Code, p: view CfgProgram, f: Int, inst: view CfgInst, fix: edit CfgFix) {
    hold first = inst.arg_first
    hold op = inst.op
    hold width = cfgIntrinsicWidth(op)
    when cfgIntrinsicRaxRcx(op) && inst.argc >= 1 {
        hold a0 = view p.call_args[first]
        cfgLoadOperand(edit code, p, f, view a0, 0)
        when inst.argc >= 2 {
            hold a1 = view p.call_args[first + 1]
            cfgLoadOperand(edit code, p, f, view a1, 1)
        }
    }
    when op == 31 { x64Hlt(edit code) }
    when op == 32 { x64Cli(edit code) }
    when op == 33 { x64Sti(edit code) }
    when op == 34 { x64Pause(edit code) }
    // in/out: port in RDX (DX), value in RAX.
    when op >= 35 && op <= 37 {
        hold port = view p.call_args[first]
        cfgLoadOperand(edit code, p, f, view port, 2)
        x64InDx(edit code, width)
    }
    when op >= 38 && op <= 40 {
        hold port = view p.call_args[first]
        cfgLoadOperand(edit code, p, f, view port, 2)
        hold value = view p.call_args[first + 1]
        cfgLoadOperand(edit code, p, f, view value, 0)
        x64OutDx(edit code, width)
    }
    when op >= 41 && op <= 44 { x64LoadRaxWidth(edit code, width) }
    when op >= 45 && op <= 48 { x64StoreRcxWidth(edit code, width) }
    when op >= 49 && op <= 51 { cfgEmitStatic(edit code, p, inst, edit fix) }
    when op == 52 {
        hold leaf = view p.call_args[first]
        hold sub = view p.call_args[first + 1]
        hold out = view p.call_args[first + 2]
        cfgLoadOperand(edit code, p, f, view out, 8)
        cfgLoadOperand(edit code, p, f, view sub, 1)
        cfgLoadOperand(edit code, p, f, view leaf, 0)
        x64CpuidToR8(edit code)
    }
    when op == 53 { x64Rdtsc(edit code) }
    when op == 54 { x64Rdmsr(edit code) }
    when op == 55 { x64Wrmsr(edit code) }
    when op >= 56 && op <= 59 { x64ReadCr(edit code, op - 56) }
    when op >= 60 && op <= 62 { x64WriteCr(edit code, op - 60) }
    when op == 63 { x64DescriptorOp(edit code, 2) }
    when op == 64 { x64DescriptorOp(edit code, 3) }
    when op == 65 { x64Ltr(edit code) }
    when op == 66 { x64ReloadSegments(edit code) }
    when op == 67 { x64DescriptorOp(edit code, 7) }
    when op == 68 { x64Fxsave(edit code, false) }
    when op == 69 { x64Fxsave(edit code, true) }
    when op == 70 { x64Wbinvd(edit code) }
    when op == 71 {
        // RAX = vector * 12 + address of the stub table (cfgBuildFor).
        x64MovImm64(edit code, 1, 0)
        fix.isr_at@push(code.bytes.length - 8)
        x64IsrStubAddress(edit code)
    }
    when op == 72 { x64ReadFlags(edit code) }
    when op == 73 { x64Int3(edit code) }
    when op >= 74 { cfgEmitSse(edit code, p, f, inst, edit fix) }
    when cfgIntrinsicHasResult(op) {
        x64StoreSlot(edit code, p.slot_start[cfgVarIndex(p, f, inst.dst)], 0)
    }
}

// Window ops (17..27), re-checked here independently of Stage 1's table:
// the arity, then the kind of each argument: 0 `val` Int, 1 shared `ref`
// Window, 2 shared `ref` List of[Int], 4 shared `ref` Text, 5 `val` Window
// (the consuming close).
flow cfgWindowArity(op: Int) => Int {
    when op == 17 || op == 24 { give 3 }
    when op == 20 || op == 27 { give 6 }
    when op == 21 { give 5 }
    when op == 23 { give 4 }
    give 1
}

flow cfgWindowArgKind(op: Int, i: Int) => Int {
    when op == 17 {
        when i == 0 { give 4 }
        give 0
    }
    when op == 25 { give 5 }
    when i == 0 { give 1 }
    when op == 21 && i == 3 { give 4 }
    when op == 27 && i == 3 { give 2 }
    give 0
}

flow cfgCheckWindowPlatform(p: view CfgProgram, f: Int, inst: view CfgInst) => Bool {
    each i among 0..inst.argc {
        hold kind = cfgWindowArgKind(inst.op, i)
        hold k = inst.arg_first + i
        when kind == 4 {
            when !cfgPlatformArgOk(p, f, k, true, false) { give false }
        } otherwise when kind == 1 || kind == 5 {
            change mode = 0
            when kind == 5 { mode = -1 }
            when p.call_ref[k] != mode || cfgPlatformArgType(p, f, k) != cfgWindowType() { give false }
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
        when kind == 1 || kind == 2 || kind == 4 {
            cfgPlatformArgAddress(edit code, p, f, inst.arg_first + i, edit fix)
            when kind == 1 { x64LoadMem64(edit code, regs[i], 0, 0) }
            otherwise { x64MovReg(edit code, regs[i], 0) }
        }
    }
    each i among 0..inst.argc {
        hold kind = cfgWindowArgKind(inst.op, i)
        when kind == 0 || kind == 5 {
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
    change max_args = 6
    when inst.op == 50 || inst.op == 51 { max_args = 256 }
    when reader.error != 0 || inst.op < 0 || inst.argc < 0 || inst.argc > max_args {
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
    when cfgIsIntrinsic(op) { give cfgIntrinsicArity(op) }
    when op == 28 || op == 29 || op == 30 { give 2 }
    when op >= 17 { give cfgWindowArity(op) }
    when op == 0 || op == 7 { give 0 }
    when op == 1 || op == 3 || op == 6 || op == 8 || op >= 13 { give 1 }
    when op >= 10 && op <= 12 { give 3 }
    give 2
}

// File argument `k`: 0 `val` Int, 1 shared `ref` File,
// 2 shared `ref` List<Int>, 3 exclusive `ref` List<Int>, 4 `val` File.
flow cfgFileArgOk(p: view CfgProgram, f: Int, k: Int, want: Int) => Bool {
    hold ty = cfgPlatformArgType(p, f, k)
    when want == 0 { give p.call_ref[k] == -1 && ty == 0 }
    when want == 1 { give p.call_ref[k] == 0 && ty == cfgFileType() }
    when want == 4 { give p.call_ref[k] == -1 && ty == cfgFileType() }
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
    when inst.op == 15 { give cfgFileArgOk(p, f, first, 4) }
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
    when cfgIsIntrinsic(inst.op) { give cfgCheckIntrinsic(p, f, inst) }
    when inst.op < 0 || inst.op > 30 || inst.argc != cfgPlatformArity(inst.op) { give 130 }
    hold first = inst.arg_first
    when inst.op >= 9 && inst.op <= 16 && !cfgCheckFilePlatform(p, f, inst) { give 131 }
    when inst.op >= 17 && inst.op <= 27 && !cfgCheckWindowPlatform(p, f, inst) { give 131 }
    when inst.op == 30 {
        when !cfgFileArgOk(p, f, first, 2) || !cfgFileArgOk(p, f, first + 1, 0) { give 131 }
        hold text_dest = p.types_code[p.functions[f].first_var + inst.dst]
        when !cfgIsTextResult(p, text_dest) { give 132 }
        give 0
    }
    when inst.op == 28 && (!cfgFileArgOk(p, f, first, 2) || !cfgFileArgOk(p, f, first + 1, 0)) { give 131 }
    when inst.op == 29 && (!cfgFileArgOk(p, f, first, 3) || !cfgFileArgOk(p, f, first + 1, 0)) { give 131 }
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
    when inst.op == 9 && dest != cfgFileType() { give 132 }
    when inst.op == 17 && dest != cfgWindowType() { give 132 }
    when inst.op >= 5 && inst.op != 9 && inst.op != 17 && dest != 0 { give 132 }
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
    when cfgIsIntrinsic(inst.op) {
        cfgEmitIntrinsic(edit code, p, f, inst, edit fix)
        give
    }
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
    } otherwise when inst.op == 30 {
        cfgPlaceAddressRax(edit code, p, f, inst.dst, -1, -1, -1, edit fix)
        x64MovReg(edit code, 2, 0)
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64MovReg(edit code, 7, 0)
        hold count = view p.call_args[first + 1]
        cfgLoadOperand(edit code, p, f, view count, 6)
    } otherwise when inst.op == 28 || inst.op == 29 {
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64MovReg(edit code, 7, 0)
        hold limit = view p.call_args[first + 1]
        cfgLoadOperand(edit code, p, f, view limit, 6)
    } otherwise when inst.op >= 17 {
        cfgEmitWindowArgs(edit code, p, f, inst, edit fix)
    } otherwise when inst.op >= 13 {
        cfgPlatformArgAddress(edit code, p, f, first, edit fix)
        x64LoadMem64(edit code, 7, 0, 0)
    }
    cfgRuntimeCall(edit code, edit fix, cfgPlatformBase() + inst.op)
    when inst.op == 0 || (inst.op >= 4 && inst.op != 30) {
        x64StoreSlot(edit code, dst_slot, 0)
    }
}
