import codegen.x86_64
import codegen.elf64

// Backward rel32 fixture; the four-byte displacement uses two's complement.
fn main() -> Int {
    var code = x64New()
    x64Ret(&mut code)
    let conditional = x64ConditionalPlaceholder(&mut code, true)
    x64PatchRelative(&mut code, conditional, 0)
    let unconditional = x64JumpPlaceholder(&mut code)
    x64PatchRelative(&mut code, unconditional, 0)
    if code.error != 0 { return 1 }

    var invalid = x64New()
    x64Ret(&mut invalid)
    x64PatchRelative(&mut invalid, 100, 0)
    if invalid.error != 4 { return 2 }
    if invalid.bytes.length != 1 { return 3 }

    let text = elf64Hex(&code.bytes)
    print("ELE_BRANCH_HEX:{text}")
    return 0
}
