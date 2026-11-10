import codegen.native_cfg_emit
import codegen.elf64

// Execute as a Stage-0-built ELE compiler component; Stage 0 is bootstrap.
// Usage: native-cfg-demo <input.lir> [output.elf].
fn main() -> Int {
    if processArgCount() != 1 && processArgCount() != 2 {
        printError("Uso: native-cfg-demo <programa.lir> [salida.elf]")
        return 2
    }
    match processArg(0) {
        Ok(path) => {
            match readText(path, 1048576) {
                Ok(source) => {
                    let compiled = cfgCompile(&source)
                    if compiled.error != 0 {
                        let code = compiled.error
                        printError("ELE-LIR/CFG rechazado (código {code})")
                        return 3
                    }
                    if processArgCount() == 2 {
                        match processArg(1) {
                            Ok(outpath) => {
                                let status = writeBytes(outpath, compiled.image)
                                if status != 0 {
                                    printError("Error al escribir ELF64 (código {status})")
                                    return 5
                                }
                                return 0
                            }
                            Err(code) => { return 6 }
                        }
                    }
                    let hex = elf64Hex(&compiled.image)
                    print("ELE_CFG_ELF_HEX:{hex}")
                    return 0
                }
                Err(code) => { return 4 }
            }
        }
        Err(code) => { return 6 }
    }
}
