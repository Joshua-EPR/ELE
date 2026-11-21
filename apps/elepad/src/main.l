import buffer

// M1 file-cycle utility. It writes a NEW output path and refuses an existing one.
flow main() => Int {
    when processArgCount() != 3 {
        printError("Uso: elepad <entrada.l> <salida-nueva.l> <texto-a-anadir>")
        give 2
    }
    choose processArg(0) {
        Ok(input): {
            choose processArg(1) {
                Ok(output): {
                    choose processArg(2) {
                        Ok(addition): {
                            // Refuse an existing output. Error 2 means absent.
                            choose readText(output, 16 * 1024 * 1024) {
                                Ok(existing): {
                                    printError("La salida ya existe")
                                    give 3
                                },
                                Err(code): {
                                    when code != 2 {
                                        printError("No se pudo verificar la salida")
                                        give 4
                                    }
                                },
                            }
                            choose readText(input, 16 * 1024 * 1024) {
                                Ok(source): {
                                    change document = loadText(view source)
                                    hold end = length(view document)
                                    when !insertText(edit document, end, view addition) {
                                        give 5
                                    }
                                    change bytes = toBytes(view document)
                                    when writeBytes(output, bytes) != 0 {
                                        printError("Error al guardar")
                                        give 6
                                    }
                                    choose readText(output, 16 * 1024 * 1024) {
                                        Ok(reopened): {
                                            when reopened.byteLength != length(view document) { give 7 }
                                            change i = 0
                                            during i < reopened.byteLength {
                                                when reopened@byteAt(i) != byteAt(view document, i) { give 8 }
                                                i += 1
                                            }
                                            print("elepad-saved-ok")
                                            give 0
                                        },
                                        Err(code): { give 9 },
                                    }
                                },
                                Err(code): {
                                    printError("No se pudo abrir la entrada: {code}")
                                    give 10
                                },
                            }
                        },
                        Err(code): { give 11 },
                    }
                },
                Err(code): { give 12 },
            }
        },
        Err(code): { give 13 },
    }
}
