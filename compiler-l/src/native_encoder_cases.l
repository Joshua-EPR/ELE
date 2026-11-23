take codegen.x86_64
take codegen.elf64

// Executable integration fixture for instruction encoding and patching.
// stdout is machine-code hex; the Rust test only acts as an external oracle.
flow main() => Int {
    change invalid = x64New()
    x64MovImm64(edit invalid, 16, 1)
    when invalid.error != 3 { give 5 }

    change code = x64New()
    x64MovImm64(edit code, 8, -1)
    x64MovReg(edit code, 9, 8)
    x64AddReg(edit code, 9, 8)
    x64SubReg(edit code, 9, 8)
    x64CmpReg(edit code, 9, 8)
    x64MulReg(edit code, 9, 8)
    hold at = x64JumpPlaceholder(edit code)
    x64Ret(edit code)
    hold target = code.bytes.length
    x64PatchRelative(edit code, at, target)
    when code.error != 0 { give 6 }
    hold bytes = elf64Hex(view code.bytes)
    print("ELE_CODE_HEX:{bytes}")
    give 0
}
