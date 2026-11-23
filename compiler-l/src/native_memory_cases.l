take codegen.x86_64
take codegen.elf64

// Stage-0 bootstrap integration fixture for x86-64 addressing, REX and SIB.
// This fixture checks encoding only; no runtime heap access is performed.
flow main() => Int {
    change code = x64New()
    x64LoadMem64(edit code, 8, 12, 16)       // mov r8,[r12+16]
    x64StoreMem64(edit code, 13, -24, 9)      // mov [r13-24],r9
    x64LoadMem64(edit code, 0, 5, -8)        // mov rax,[rbp-8]
    x64StoreMem64(edit code, 4, 0, 0)        // mov [rsp],rax
    x64LoadMem8(edit code, 10, 12, 17)      // movzx r10,byte [r12+17]
    x64StoreMem8(edit code, 13, -9, 6)      // mov byte [r13-9],sil
    when code.error != 0 { give 1 }
    print("ELE_MEMORY_CODE_HEX:{elf64Hex(&code.bytes)}")

    change invalid = x64New()
    x64LoadMem64(edit invalid, 16, 0, 0)
    when invalid.error != 7 { give 2 }
    change bad_offset = x64New()
    x64StoreMem8(edit bad_offset, 0, 2147483648, 0)
    when bad_offset.error != 9 { give 3 }
    when bad_offset.bytes.length != 0 { give 4 }
    give 0
}
