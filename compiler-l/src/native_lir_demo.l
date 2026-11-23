take codegen.lir_subset
take codegen.elf64

// Prototype direct native backend CLI, implemented in ELE itself.
// Accepts a single ELE-LIR 1 file from the deliberately small supported
// subset. With an output path, writes ELF bytes directly using the
// bootstrap writeBytes platform primitive; one argument preserves the old
// hexadecimal diagnostic mode for differential tests.
flow main() => Int {
    when processArgCount() != 1 && processArgCount() != 2 {
        printError("Uso: native-lir-demo <programa.lir> [salida.elf]")
        give 2
    }
    choose processArg(0) {
        Ok(path) : {
            choose readText(path, 1048576) {
                Ok(source) : {
                    hold compiled = nativeCompileSubset(view source)
                    when compiled.error != 0 {
                        hold code = compiled.error
                        printError("ELE-LIR rechazado por el backend nativo (código {code})")
                        give 3
                    }
                    when processArgCount() == 2 {
                        choose processArg(1) {
                            Ok(output_path) : {
                                hold written = writeBytes(output_path, compiled.image)
                                when written != 0 {
                                    printError("No se pudo escribir ELF binario (código {written})")
                                    give 6
                                }
                                give 0
                            }
                            Err(code) : {
                                printError("Ruta de salida inválida")
                                give 5
                            }
                        }
                    }
                    hold hex = elf64Hex(view compiled.image)
                    print("ELE_ELF_HEX:{hex}")
                    give 0
                }
                Err(code) : {
                    printError("No se pudo leer ELE-LIR")
                    give 4
                }
            }
        }
        Err(code) : {
            printError("Ruta de ELE-LIR inválida")
            give 5
        }
    }
}
