import lir_tokens
import x86_64
import elf64

// First *real* ELE-LIR -> x86-64 -> ELF64 path implemented in ELE.
// Restricted to one function, one block, <=8 Int locals, no parameters,
// and instructions `use`/`binary add|sub|mul` + `return`.
// Unsupported or malformed input is rejected. This does NOT implement
// full ELE-LIR v1, globals, heap, imports, drops or general calling ABI.

pub struct NativeBuild {
    image: List<Int>
    error: Int
}

fn nativeFail(code: Int) -> NativeBuild {
    return NativeBuild(image: List[], error: code)
}

fn nativeValidVariable(id: Int, count: Int) -> Bool {
    return id >= 0 && id < count
}

fn nativeLoad(code: &mut X64Code, op: &NativeOperand, dst: Int, assigned: &List<Bool>) {
    // The legacy linear subset is Int-only. A newly tokenized cb0/cb1
    // must not silently become an integer operand here.
    if op.is_bool { code.error = 8; return }
    if op.is_var {
        if op.value < 0 || op.value >= assigned.length {
            code.error = 8
            return
        }
        if !assigned[op.value] {
            code.error = 9
            return
        }
        x64MovReg(&mut code, dst, op.value + 8)
    } else {
        x64MovImm64(&mut code, dst, op.value)
    }
}

pub fn nativeCompileSubset(source: &Text) -> NativeBuild {
    if source.byteLength == 0 || source.byteLength > 33554432 { return nativeFail(10) }
    var reader = nativeReaderNew()
    nativeExpect(source, &mut reader, "ELE-LIR")
    nativeExpect(source, &mut reader, "1")
    nativeEndLine(source, &mut reader)

    nativeExpect(source, &mut reader, "module")
    nativeExpect(source, &mut reader, "structs")
    let structs = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "funcs")
    let functions = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "main")
    let main_func = nativeId(source, &mut reader, 102)
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || structs != 0 || functions != 1 || main_func != 0 {
        return nativeFail(11)
    }

    nativeExpect(source, &mut reader, "func")
    let fid = nativeId(source, &mut reader, 102)
    nativeExpect(source, &mut reader, "4:109,97,105,110") // exact serialized name "main"
    nativeExpect(source, &mut reader, "params")
    let params = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "result")
    nativeExpect(source, &mut reader, "i")
    let ret_ref = nativeNumber(source, &mut reader)
    let ret_mut = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "vars")
    let var_count = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "blocks")
    let blocks = nativeNumber(source, &mut reader)
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || fid != 0 || params != 0 || ret_ref != 0 || ret_mut != 0 || blocks != 1 || var_count < 0 || var_count > 8 {
        return nativeFail(12)
    }

    var assigned: List<Bool> = List[]
    for i in 0..var_count {
        nativeExpect(source, &mut reader, "var")
        let vid = nativeId(source, &mut reader, 118)
        nativeExpect(source, &mut reader, "val")
        nativeExpect(source, &mut reader, "i")
        nativeEndLine(source, &mut reader)
        if vid != i || reader.error != 0 { return nativeFail(13) }
        assigned.push(false)
    }

    nativeExpect(source, &mut reader, "block")
    let bid = nativeNumber(source, &mut reader)
    let count = nativeNumber(source, &mut reader)
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || bid != 0 || count < 0 || count > 10000 {
        return nativeFail(14)
    }

    var code = x64New()
    var overflow_jumps: List<Int> = List[]
    for i in 0..count {
        nativeExpect(source, &mut reader, "i")
        let kind = nativeWord(source, &mut reader)
        if nativeEquals(source, &kind, "use") {
            let dest = nativeId(source, &mut reader, 118)
            let operand = nativeOperand(source, &mut reader)
            nativeEndLine(source, &mut reader)
            if !nativeValidVariable(dest, var_count) || reader.error != 0 { return nativeFail(15) }
            nativeLoad(&mut code, &operand, dest + 8, &assigned)
            if code.error != 0 { return nativeFail(16) }
            assigned[dest] = true
        } else if nativeEquals(source, &kind, "binary") {
            let dest = nativeId(source, &mut reader, 118)
            let opcode = nativeWord(source, &mut reader)
            let left = nativeOperand(source, &mut reader)
            let right = nativeOperand(source, &mut reader)
            nativeEndLine(source, &mut reader)
            if !nativeValidVariable(dest, var_count) || reader.error != 0 { return nativeFail(17) }
            // Load the right operand first. It may live in the destination
            // register; RAX is always reserved as an instruction scratch.
            nativeLoad(&mut code, &right, 0, &assigned)
            nativeLoad(&mut code, &left, dest + 8, &assigned)
            if code.error != 0 { return nativeFail(18) }
            if nativeEquals(source, &opcode, "add") {
                x64AddReg(&mut code, dest + 8, 0)
            } else if nativeEquals(source, &opcode, "sub") {
                x64SubReg(&mut code, dest + 8, 0)
            } else if nativeEquals(source, &opcode, "mul") {
                x64MulReg(&mut code, dest + 8, 0)
            } else {
                return nativeFail(19)
            }
            overflow_jumps.push(x64OverflowPlaceholder(&mut code))
            if code.error != 0 { return nativeFail(20) }
            assigned[dest] = true
        } else {
            return nativeFail(21)
        }
    }

    nativeExpect(source, &mut reader, "t")
    nativeExpect(source, &mut reader, "return")
    let result = nativeOperand(source, &mut reader)
    nativeEndLine(source, &mut reader)
    nativeExpect(source, &mut reader, "endfunc")
    nativeEndLine(source, &mut reader)
    nativeExpect(source, &mut reader, "end")
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || !nativeAtEnd(source, &reader) { return nativeFail(22) }

    // Linux x86-64 sys_exit(result): RAX=60, RDI=exit status.
    nativeLoad(&mut code, &result, 7, &assigned)
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)
    let overflow_handler = code.bytes.length
    // Signed integer overflow exits with diagnostic status 125.
    x64MovImm64(&mut code, 7, 125)
    x64MovImm64(&mut code, 0, 60)
    x64Syscall(&mut code)
    for i in 0..overflow_jumps.length {
        x64PatchRelative(&mut code, overflow_jumps[i], overflow_handler)
    }
    if code.error != 0 { return nativeFail(23) }
    let image = elf64Executable(&code.bytes)
    if image.length == 0 { return nativeFail(24) }
    return NativeBuild(image: image, error: 0)
}
