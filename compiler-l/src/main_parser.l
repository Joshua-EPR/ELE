import lexer
import tokens
import cursor
import ast
import parser

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

fn reportLexError(path: &Text, source: &Text, error: &LexError) {
    let offset = error.offset
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
    printError("{path}:{line}:{column}: error[LEXER]: error léxico (byte {offset})")
}

fn reportParseError(path: &Text, source: &Text, error: &ParseError) {
    let offset = error.token_start
    var message = "error sintáctico"
    match error.problem {
        ParseProblem.ExpectedExpression => { message = "se esperaba expresión" }
        ParseProblem.ExpectedIdentifier => { message = "se esperaba identificador" }
        ParseProblem.ExpectedType => { message = "se esperaba tipo" }
        ParseProblem.ExpectedStatement => { message = "se esperaba sentencia" }
        ParseProblem.ExpectedDeclaration => { message = "se esperaba declaración" }
        ParseProblem.ExpectedToken => { message = "se esperaba token" }
        ParseProblem.UnclosedBlock => { message = "bloque sin cerrar" }
        ParseProblem.UnclosedParenthesis => { message = "paréntesis sin cerrar" }
        ParseProblem.UnclosedBracket => { message = "corchete sin cerrar" }
        ParseProblem.UnclosedInterpolation => { message = "expresión interpolada sin cerrar" }
        ParseProblem.ChainedComparisonsProhibited => { message = "comparaciones encadenadas prohibidas" }
        ParseProblem.NestingLimitExceeded => { message = "límite de anidamiento (128) excedido" }
        ParseProblem.UnexpectedToken => { message = "token inesperado" }
    }
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
    let exp = &error.expected_token
    if exp.byteLength > 0 {
        printError("{path}:{line}:{column}: error[PARSER]: {message}: '{exp}' (byte {offset})")
    } else {
        printError("{path}:{line}:{column}: error[PARSER]: {message} (byte {offset})")
    }
}

fn parseFile(path: &Text) -> Int {
    match readText(path, 16 * 1024 * 1024) {
        Ok(source) => {
            match lexSource(source) {
                Ok(tokens) => {
                    var tree = astNew()
                    let ok = parseProgram(&mut tree, source, tokens, 0)
                    if !ok || tree.errors.length > 0 {
                        for i in 0..tree.errors.length {
                            let err = &tree.errors[i]
                            reportParseError(path, source, err)
                        }
                        return 1
                    }
                    astDumpCanonical(tree)
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
        printError("Uso: parser-l <archivo.l>")
        return 2
    }
    match processArg(0) {
        Ok(path) => {
            if path.byteLength == 0 {
                printError("Uso: parser-l <archivo.l>")
                return 2
            }
            return parseFile(path)
        }
        Err(code) => {
            printError("parser-l: argumento inválido")
            return 2
        }
    }
}
