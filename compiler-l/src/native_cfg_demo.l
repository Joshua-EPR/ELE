import codegen.native_cfg_emit
import codegen.elf64

// Execute as a Stage-0-built ELE compiler component; Stage 0 is bootstrap.
// Usage: native-cfg-demo <input.lir> [output.elf]
//        native-cfg-demo <input.lir> <output.exe> --pe64
// The third form emits a Windows x64 PE32+ image (codegen/pe64.l) instead of
// a Linux ELF64 one; it accepts the subset documented in cfgBuildFor.
// The output is written only after a successful compilation. A file left
// by an earlier run is not removed on failure: ELE has no file removal
// primitive yet, so callers must check the exit status.
flow isPe64Flag(flag: view Text) => Bool {
    hold expected = "--pe64"
    when flag.byteLength != expected.byteLength { give false }
    each i among 0..flag.byteLength {
        when flag@byteAt(i) != expected@byteAt(i) { give false }
    }
    give true
}

// An option where a path is expected (e.g. `in.lir --pe64`) is a usage
// error: it must never become the name of the output file.
flow looksLikeFlag(arg: view Text) => Bool {
    give arg.byteLength >= 2 && arg@byteAt(0) == 45 && arg@byteAt(1) == 45
}

fn main() -> Int {
    when processArgCount() < 1 || processArgCount() > 3 {
        printError("Uso: native-cfg-demo <programa.lir> [salida.elf] | <programa.lir> <salida.exe> --pe64")
        return 2
    }
    change target = 0
    when processArgCount() == 3 {
        choose processArg(2) {
            Ok(flag) : {
                when !isPe64Flag(view flag) {
                    printError("Opción desconocida; se esperaba --pe64")
                    give 2
                }
                target = 1
            }
            Err(code) : { give 6 }
        }
    }
    each i among 0.@processArgCount() {
        when i < 2 {
            choose processArg(i) {
                Ok(positional) : {
                    when looksLikeFlag(view positional) {
                        printError("Se esperaba una ruta, no una opción, en la posición {i}")
                        give 2
                    }
                }
                Err(code) : { give 6 }
            }
        }
    }
    match processArg(0) {
        Ok(path) => {
            match readText(path, 1048576) {
                Ok(source) => {
                    hold compiled = cfgCompileFor(view source, target)
                    if compiled.error != 0 {
                        let code = compiled.error
                        printError("ELE-LIR/CFG rechazado (código {code})")
                        return 3
                    }
                    when processArgCount() >= 2 {
                        match processArg(1) {
                            Ok(outpath) => {
                                let status = writeBytes(outpath, compiled.image)
                                if status != 0 {
                                    when target == 1 {
                                        printError("Error al escribir PE64 (código {status})")
                                    } otherwise {
                                        printError("Error al escribir ELF64 (código {status})")
                                    }
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
