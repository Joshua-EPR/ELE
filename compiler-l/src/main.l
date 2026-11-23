take lexer
take tokens
take cursor

flow problemMessage(problem: view LexProblem) => Text {
    choose problem {
        LexProblem.UnexpectedByte : { give "carácter inválido o fuera del subconjunto léxico" }
        LexProblem.UnclosedComment : { give "comentario sin cerrar" }
        LexProblem.UnsupportedNumber : { give "literal de punto flotante fuera del subconjunto léxico" }
        LexProblem.UnclosedString : { give "cadena sin cerrar" }
        LexProblem.InvalidEscape : { give "escape no implementado o inválido" }
        LexProblem.InvalidUnicodeEscape : { give "escape Unicode inválido" }
        LexProblem.InvalidUnicodeScalar : { give "scalar Unicode inválido" }
        LexProblem.UnclosedInterpolation : { give "interpolación sin cerrar: falta '}}'" }
        LexProblem.UnopenedBrace : { give "llave '}}' sin apertura en Text; use '}}}}' para una llave literal" }
        LexProblem.ExcessiveDepth : { give "límite de anidamiento Text (64) excedido" }
    }
}

flow reportLexError(path: view Text, source: view Text, error: view LexError) {
    hold offset = error.offset
    hold message = problemMessage(error.problem)
    change line = 1
    change column = 1
    each i among lexStart(source)..offset {
        hold b = source@byteAt(i)
        when b == 10 {
            line += 1
            column = 1
        } otherwise when b < 128 || b >= 192 {
            column += 1
        }
    }
    printError("{path}:{line}:{column}: {message} (byte {offset})")
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
