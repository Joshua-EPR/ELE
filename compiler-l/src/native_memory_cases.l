import codegen.x86_64
import codegen.elf64

// Stage-0 bootstrap integration fixture for x86-64 addressing, REX and SIB.
// This fixture checks encoding only; no runtime heap access is performed.
fn main() -> Int {
    var code = x64New()
    x64LoadMem64(&mut code, 8, 12, 16)       // mov r8,[r12+16]
    x64StoreMem64(&mut code, 13, -24, 9)      // mov [r13-24],r9
    x64LoadMem64(&mut code, 0, 5, -8)        // mov rax,[rbp-8]
    x64StoreMem64(&mut code, 4, 0, 0)        // mov [rsp],rax
    x64LoadMem8(&mut code, 10, 12, 17)      // movzx r10,byte [r12+17]
    x64StoreMem8(&mut code, 13, -9, 6)      // mov byte [r13-9],sil
    if code.error != 0 { return 1 }
    print("ELE_MEMORY_CODE_HEX:{elf64Hex(&code.bytes)}")

    var invalid = x64New()
    x64LoadMem64(&mut invalid, 16, 0, 0)
    if invalid.error != 7 { return 2 }
    var bad_offset = x64New()
    x64StoreMem8(&mut bad_offset, 0, 2147483648, 0)
    if bad_offset.error != 9 { return 3 }
    if bad_offset.bytes.length != 0 { return 4 }
    return 0
}
