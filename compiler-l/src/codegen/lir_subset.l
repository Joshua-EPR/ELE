take lir_tokens
take x86_64
take elf64

// First *real* ELE-LIR -> x86-64 -> ELF64 path implemented in ELE.
// Restricted to one function, one block, <=8 Int locals, no parameters,
// and instructions `use`/`binary add|sub|mul` + `return`.
// Unsupported or malformed input is rejected. This does NOT implement
// full ELE-LIR v1, globals, heap, imports, drops or general calling ABI.

expose shape NativeBuild {
    image: List of[Int]
    error: Int
}

flow nativeFail(code: Int) => NativeBuild {
    give NativeBuild(image: List[], error: code)
}

flow nativeValidVariable(id: Int, count: Int) => Bool {
    give id >= 0 && id < count
}

flow nativeLoad(code: edit X64Code, op: view NativeOperand, dst: Int, assigned: view List of[Bool]) {
    // The legacy linear subset is Int-only. A newly tokenized cb0/cb1
    // must not silently become an integer operand here.
    when op.is_bool { code.error = 8; give }
    when op.is_var {
        when op.value < 0 || op.value >= assigned.length {
            code.error = 8
            give
        }
        when !assigned[op.value] {
            code.error = 9
            give
        }
        x64MovReg(edit code, dst, op.value + 8)
    } otherwise {
        x64MovImm64(edit code, dst, op.value)
    }
}

expose flow nativeCompileSubset(source: view Text) => NativeBuild {
    when source.byteLength == 0 || source.byteLength > 33554432 { give nativeFail(10) }
    change reader = nativeReaderNew()
    nativeExpect(source, edit reader, "ELE-LIR")
    nativeExpect(source, edit reader, "1")
    nativeEndLine(source, edit reader)

    nativeExpect(source, edit reader, "module")
    nativeExpect(source, edit reader, "structs")
    hold structs = nativeNumber(source, edit reader)
    nativeExpect(source, edit reader, "funcs")
    hold functions = nativeNumber(source, edit reader)
    nativeExpect(source, edit reader, "main")
    hold main_func = nativeId(source, edit reader, 102)
    nativeEndLine(source, edit reader)
    when reader.error != 0 || structs != 0 || functions != 1 || main_func != 0 {
        give nativeFail(11)
    }

    nativeExpect(source, edit reader, "func")
    hold fid = nativeId(source, edit reader, 102)
    nativeExpect(source, edit reader, "4:109,97,105,110") // exact serialized name "main"
    nativeExpect(source, edit reader, "params")
    hold params = nativeNumber(source, edit reader)
    nativeExpect(source, edit reader, "result")
    nativeExpect(source, edit reader, "i")
    hold ret_ref = nativeNumber(source, edit reader)
    hold ret_mut = nativeNumber(source, edit reader)
    nativeExpect(source, edit reader, "vars")
    hold var_count = nativeNumber(source, edit reader)
    nativeExpect(source, edit reader, "blocks")
    hold blocks = nativeNumber(source, edit reader)
    nativeEndLine(source, edit reader)
    when reader.error != 0 || fid != 0 || params != 0 || ret_ref != 0 || ret_mut != 0 || blocks != 1 || var_count < 0 || var_count > 8 {
        give nativeFail(12)
    }

    change assigned: List of[Bool] = List[]
    each i among 0..var_count {
        nativeExpect(source, edit reader, "var")
        hold vid = nativeId(source, edit reader, 118)
        nativeExpect(source, edit reader, "val")
        nativeExpect(source, edit reader, "i")
        nativeEndLine(source, edit reader)
        when vid != i || reader.error != 0 { give nativeFail(13) }
        assigned@push(false)
    }

    nativeExpect(source, edit reader, "block")
    hold bid = nativeNumber(source, edit reader)
    hold count = nativeNumber(source, edit reader)
    nativeEndLine(source, edit reader)
    when reader.error != 0 || bid != 0 || count < 0 || count > 10000 {
        give nativeFail(14)
    }

    change code = x64New()
    change overflow_jumps: List of[Int] = List[]
    each i among 0..count {
        nativeExpect(source, edit reader, "i")
        hold kind = nativeWord(source, edit reader)
        when nativeEquals(source, view kind, "use") {
            hold dest = nativeId(source, edit reader, 118)
            hold operand = nativeOperand(source, edit reader)
            nativeEndLine(source, edit reader)
            when !nativeValidVariable(dest, var_count) || reader.error != 0 { give nativeFail(15) }
            nativeLoad(edit code, view operand, dest + 8, view assigned)
            when code.error != 0 { give nativeFail(16) }
            assigned[dest] = true
        } otherwise when nativeEquals(source, view kind, "binary") {
            hold dest = nativeId(source, edit reader, 118)
            hold opcode = nativeWord(source, edit reader)
            hold left = nativeOperand(source, edit reader)
            hold right = nativeOperand(source, edit reader)
            nativeEndLine(source, edit reader)
            when !nativeValidVariable(dest, var_count) || reader.error != 0 { give nativeFail(17) }
            // Load the right operand first. It may live in the destination
            // register; RAX is always reserved as an instruction scratch.
            nativeLoad(edit code, view right, 0, view assigned)
            nativeLoad(edit code, view left, dest + 8, view assigned)
            when code.error != 0 { give nativeFail(18) }
            when nativeEquals(source, view opcode, "add") {
                x64AddReg(edit code, dest + 8, 0)
            } otherwise when nativeEquals(source, view opcode, "sub") {
                x64SubReg(edit code, dest + 8, 0)
            } otherwise when nativeEquals(source, view opcode, "mul") {
                x64MulReg(edit code, dest + 8, 0)
            } otherwise {
                give nativeFail(19)
            }
            overflow_jumps@push(x64OverflowPlaceholder(edit code))
            when code.error != 0 { give nativeFail(20) }
            assigned[dest] = true
        } otherwise {
            give nativeFail(21)
        }
    }

    nativeExpect(source, edit reader, "t")
    nativeExpect(source, edit reader, "return")
    hold result = nativeOperand(source, edit reader)
    nativeEndLine(source, edit reader)
    nativeExpect(source, edit reader, "endfunc")
    nativeEndLine(source, edit reader)
    nativeExpect(source, edit reader, "end")
    nativeEndLine(source, edit reader)
    when reader.error != 0 || !nativeAtEnd(source, view reader) { give nativeFail(22) }

    // Linux x86-64 sys_exit(result): RAX=60, RDI=exit status.
    nativeLoad(edit code, view result, 7, view assigned)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)
    hold overflow_handler = code.bytes.length
    // Signed integer overflow exits with diagnostic status 125.
    x64MovImm64(edit code, 7, 125)
    x64MovImm64(edit code, 0, 60)
    x64Syscall(edit code)
    each i among 0..overflow_jumps.length {
        x64PatchRelative(edit code, overflow_jumps[i], overflow_handler)
    }
    when code.error != 0 { give nativeFail(23) }
    hold image = elf64Executable(view code.bytes)
    when image.length == 0 { give nativeFail(24) }
    give NativeBuild(image: image, error: 0)
}
