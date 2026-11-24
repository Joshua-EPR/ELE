take lexer
take tokens
take cursor

flow reportLexError(path: view Text, source: view Text, error: view LexError) {
    hold no_prefix = ""
    printError(lexDiagnostic(path, source, error, view no_prefix))
}

flow reportFileError(path: view Text, code: Int) => Int {
    when code == 1 {
        printError("{path}: ruta o límite inválido")
        give 2
    }
    when code == 2 {
        printError("{path}: archivo inexistente")
        give 3
    }
    when code == 4 {
        printError("{path}: UTF-8 inválido")
        give 5
    }
    when code == 5 {
        printError("{path}: archivo excede el límite de 16 MiB")
        give 7
    }
    printError("{path}: no se pudo abrir o leer el archivo")
    give 4
}

flow lexFile(path: view Text) => Int {
    choose readText(path, 16 * 1024 * 1024) {
        Ok(source) : {
            choose lexSource(source) {
                Ok(tokens) : {
                    emitTokens(tokens)
                    give 0
                }
                Err(error) : {
                    reportLexError(path, source, error)
                    give 6
                }
            }
        }
        Err(code) : { give reportFileError(path, code) }
    }
}

flow main() => Int {
    when processArgCount() != 1 {
        printError("Uso: lexer-l <archivo.l>")
        give 2
    }
    choose processArg(0) {
        Ok(path) : {
            when path.byteLength == 0 {
                printError("Uso: lexer-l <archivo.l>")
                give 2
            }
            give lexFile(path)
        }
        Err(code) : {
            printError("lexer-l: argumento inválido")
            give 2
        }
    }
}
