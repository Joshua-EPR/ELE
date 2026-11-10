import codegen.x86_64
import codegen.elf64

// Native Linux x86-64 proof: ELE constructs MOV RAX,60; MOV RDI,42;
// SYSCALL and wraps the bytes into a loadable ELF64 image.
// The legacy toolchain is only used to bootstrap this ELE program.
// With an output path, writes the ELF file directly. Without arguments it
// retains the hexadecimal output used by existing differential tests.
fn main() -> Int {
    var code = x64New()
    x64MovImm64(&mut code, 0, 60)
    x64MovImm64(&mut code, 7, 42)
    x64Syscall(&mut code)
    if code.error != 0 { return 2 }
    let binary = elf64Executable(&code.bytes)
    if binary.length == 0 { return 3 }
    if processArgCount() == 1 {
        match processArg(0) {
            Ok(path) => {
                let result = writeBytes(path, binary)
                if result != 0 {
                    printError("No se pudo escribir ELF (código {result})")
                    return 4
                }
                return 0
            }
            Err(code) => { return 5 }
        }
    }
    if processArgCount() != 0 { return 6 }
    let hex = elf64Hex(&binary)
    print("ELE_ELF_HEX:{hex}")
    return 0
}
