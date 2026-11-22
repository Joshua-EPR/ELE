take std.ui.clipboard

flow main() => Int {
    change bytes: List of[Int] = List[]
    when processArgCount() == 0 {
        hold sample = "Acentos: áéíóú ñ. Emoji: 😀. Línea 1\r\nLínea 2"
        each i among 0..sample.byteLength { bytes@push(sample@byteAt(i)) }
    } otherwise {
        choose processArg(0) {
            Ok(path): {
                choose readText(path, CLIPBOARD_LIMIT) {
                    Ok(sample): { each i among 0..sample.byteLength { bytes@push(sample@byteAt(i)) } },
                    Err(code): { give 3 },
                }
            },
            Err(code): { give 4 },
        }
    }
    hold status = clipboardWrite(view bytes)
    when status != 0 { printError("clipboardWrite: {status}"); give 1 }
    give 0
}
