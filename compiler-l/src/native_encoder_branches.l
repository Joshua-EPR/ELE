take codegen.x86_64
take codegen.elf64

// Backward rel32 fixture; the four-byte displacement uses two's complement.
flow main() => Int {
    change code = x64New()
    x64Ret(edit code)
    hold conditional = x64ConditionalPlaceholder(edit code, true)
    x64PatchRelative(edit code, conditional, 0)
    hold unconditional = x64JumpPlaceholder(edit code)
    x64PatchRelative(edit code, unconditional, 0)
    when code.error != 0 { give 1 }

    change invalid = x64New()
    x64Ret(edit invalid)
    x64PatchRelative(edit invalid, 100, 0)
    when invalid.error != 4 { give 2 }
    when invalid.bytes.length != 1 { give 3 }

    hold text = elf64Hex(view code.bytes)
    print("ELE_BRANCH_HEX:{text}")
    give 0
}
