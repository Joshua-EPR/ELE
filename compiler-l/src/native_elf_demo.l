take codegen.x86_64
take codegen.elf64

// Native Linux x86-64 proof: ELE constructs MOV RAX,60; MOV RDI,42;
// SYSCALL and wraps the bytes into a loadable ELF64 image.
// The legacy toolchain is only used to bootstrap this ELE program.
// With an output path, writes the ELF file directly. Without arguments it
// retains the hexadecimal output used by existing differential tests.
flow main() => Int {
    change code = x64New()
    x64MovImm64(edit code, 0, 60)
    x64MovImm64(edit code, 7, 42)
    x64Syscall(edit code)
    when code.error != 0 { give 2 }
    hold binary = elf64Executable(view code.bytes)
    when binary.length == 0 { give 3 }
    when processArgCount() == 1 {
        choose processArg(0) {
            Ok(path) : {
                hold result = writeBytes(path, binary)
                when result != 0 {
                    printError("No se pudo escribir ELF (código {result})")
                    give 4
                }
                give 0
            }
            Err(code) : { give 5 }
        }
    }
    when processArgCount() != 0 { give 6 }
    hold hex = elf64Hex(view binary)
    print("ELE_ELF_HEX:{hex}")
    give 0
}
