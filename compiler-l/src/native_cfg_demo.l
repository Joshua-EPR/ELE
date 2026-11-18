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
fn isPe64Flag(flag: &Text) -> Bool {
    let expected = "--pe64"
    if flag.byteLength != expected.byteLength { return false }
    for i in 0..flag.byteLength {
        if flag.byteAt(i) != expected.byteAt(i) { return false }
    }
    return true
}

// An option where a path is expected (e.g. `in.lir --pe64`) is a usage
// error: it must never become the name of the output file.
fn looksLikeFlag(arg: &Text) -> Bool {
    return arg.byteLength >= 2 && arg.byteAt(0) == 45 && arg.byteAt(1) == 45
}

fn main() -> Int {
    if processArgCount() < 1 || processArgCount() > 3 {
        printError("Uso: native-cfg-demo <programa.lir> [salida.elf] | <programa.lir> <salida.exe> --pe64")
        return 2
    }
    var target = 0
    if processArgCount() == 3 {
        match processArg(2) {
            Ok(flag) => {
                if !isPe64Flag(&flag) {
                    printError("Opción desconocida; se esperaba --pe64")
                    return 2
                }
                target = 1
            }
            Err(code) => { return 6 }
        }
    }
    for i in 0..processArgCount() {
        if i < 2 {
            match processArg(i) {
                Ok(positional) => {
                    if looksLikeFlag(&positional) {
                        printError("Se esperaba una ruta, no una opción, en la posición {i}")
                        return 2
                    }
                }
                Err(code) => { return 6 }
            }
        }
    }
    match processArg(0) {
        Ok(path) => {
            match readText(path, 1048576) {
                Ok(source) => {
                    let compiled = cfgCompileFor(&source, target)
                    if compiled.error != 0 {
                        let code = compiled.error
                        printError("ELE-LIR/CFG rechazado (código {code})")
                        return 3
                    }
                    if processArgCount() >= 2 {
                        match processArg(1) {
                            Ok(outpath) => {
                                let status = writeBytes(outpath, compiled.image)
                                if status != 0 {
                                    if target == 1 {
                                        printError("Error al escribir PE64 (código {status})")
                                    } else {
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
