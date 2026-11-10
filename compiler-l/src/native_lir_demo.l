import codegen.lir_subset
import codegen.elf64

// Prototype direct native backend CLI, implemented in ELE itself.
// Accepts a single ELE-LIR 1 file from the deliberately small supported
// subset. With an output path, writes ELF bytes directly using the
// bootstrap writeBytes platform primitive; one argument preserves the old
// hexadecimal diagnostic mode for differential tests.
fn main() -> Int {
    if processArgCount() != 1 && processArgCount() != 2 {
        printError("Uso: native-lir-demo <programa.lir> [salida.elf]")
        return 2
    }
    match processArg(0) {
        Ok(path) => {
            match readText(path, 1048576) {
                Ok(source) => {
                    let compiled = nativeCompileSubset(&source)
                    if compiled.error != 0 {
                        let code = compiled.error
                        printError("ELE-LIR rechazado por el backend nativo (código {code})")
                        return 3
                    }
                    if processArgCount() == 2 {
                        match processArg(1) {
                            Ok(output_path) => {
                                let written = writeBytes(output_path, compiled.image)
                                if written != 0 {
                                    printError("No se pudo escribir ELF binario (código {written})")
                                    return 6
                                }
                                return 0
                            }
                            Err(code) => {
                                printError("Ruta de salida inválida")
                                return 5
                            }
                        }
                    }
                    let hex = elf64Hex(&compiled.image)
                    print("ELE_ELF_HEX:{hex}")
                    return 0
                }
                Err(code) => {
                    printError("No se pudo leer ELE-LIR")
                    return 4
                }
            }
        }
        Err(code) => {
            printError("Ruta de ELE-LIR inválida")
            return 5
        }
    }
}
