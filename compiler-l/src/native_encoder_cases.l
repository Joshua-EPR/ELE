import codegen.x86_64
import codegen.elf64

// Executable integration fixture for instruction encoding and patching.
// stdout is machine-code hex; the Rust test only acts as an external oracle.
fn main() -> Int {
    var invalid = x64New()
    x64MovImm64(&mut invalid, 16, 1)
    if invalid.error != 3 { return 5 }

    var code = x64New()
    x64MovImm64(&mut code, 8, -1)
    x64MovReg(&mut code, 9, 8)
    x64AddReg(&mut code, 9, 8)
    x64SubReg(&mut code, 9, 8)
    x64CmpReg(&mut code, 9, 8)
    x64MulReg(&mut code, 9, 8)
    let at = x64JumpPlaceholder(&mut code)
    x64Ret(&mut code)
    let target = code.bytes.length
    x64PatchRelative(&mut code, at, target)
    if code.error != 0 { return 6 }
    let bytes = elf64Hex(&code.bytes)
    print("ELE_CODE_HEX:{bytes}")
    return 0
}
