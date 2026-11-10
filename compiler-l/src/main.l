import lexer
import tokens
import cursor

fn problemMessage(problem: &LexProblem) -> Text {
    match problem {
        LexProblem.UnexpectedByte => { return "carácter inválido o fuera del subconjunto léxico" }
        LexProblem.UnclosedComment => { return "comentario sin cerrar" }
        LexProblem.UnsupportedNumber => { return "literal de punto flotante fuera del subconjunto léxico" }
        LexProblem.UnclosedString => { return "cadena sin cerrar" }
        LexProblem.InvalidEscape => { return "escape no implementado o inválido" }
        LexProblem.InvalidUnicodeEscape => { return "escape Unicode inválido" }
        LexProblem.InvalidUnicodeScalar => { return "scalar Unicode inválido" }
        LexProblem.UnclosedInterpolation => { return "interpolación sin cerrar: falta '}}'" }
        LexProblem.UnopenedBrace => { return "llave '}}' sin apertura en Text; use '}}}}' para una llave literal" }
        LexProblem.ExcessiveDepth => { return "límite de anidamiento Text (64) excedido" }
    }
}

fn reportLexError(path: &Text, source: &Text, error: &LexError) {
    let offset = error.offset
    let message = problemMessage(error.problem)
    var line = 1
    var column = 1
    for i in lexStart(source)..offset {
        let b = source.byteAt(i)
        if b == 10 {
            line += 1
            column = 1
        } else if b < 128 || b >= 192 {
            column += 1
        }
    }
    printError("{path}:{line}:{column}: {message} (byte {offset})")
}

fn reportFileError(path: &Text, code: Int) -> Int {
    if code == 1 {
        printError("{path}: ruta o límite inválido")
        return 2
    }
    if code == 2 {
        printError("{path}: archivo inexistente")
        return 3
    }
    if code == 4 {
        printError("{path}: UTF-8 inválido")
        return 5
    }
    if code == 5 {
        printError("{path}: archivo excede el límite de 16 MiB")
        return 7
    }
    printError("{path}: no se pudo abrir o leer el archivo")
    return 4
}

fn lexFile(path: &Text) -> Int {
    match readText(path, 16 * 1024 * 1024) {
        Ok(source) => {
            match lexSource(source) {
                Ok(tokens) => {
                    emitTokens(tokens)
                    return 0
                }
                Err(error) => {
                    reportLexError(path, source, error)
                    return 6
                }
            }
        }
        Err(code) => { return reportFileError(path, code) }
    }
}

fn main() -> Int {
    if processArgCount() != 1 {
        printError("Uso: lexer-l <archivo.l>")
        return 2
    }
    match processArg(0) {
        Ok(path) => {
            if path.byteLength == 0 {
                printError("Uso: lexer-l <archivo.l>")
                return 2
            }
            return lexFile(path)
        }
        Err(code) => {
            printError("lexer-l: argumento inválido")
            return 2
        }
    }
}
