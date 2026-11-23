take lexer
take tokens
take cursor
take ast
take parser

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

flow reportLexError(path: view Text, source: view Text, error: view LexError) {
    hold offset = error.offset
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
    printError("{path}:{line}:{column}: error[LEXER]: error léxico (byte {offset})")
}

flow reportParseError(path: view Text, source: view Text, error: view ParseError) {
    hold offset = error.token_start
    change message = "error sintáctico"
    choose error.problem {
        ParseProblem.ExpectedExpression: { message = "se esperaba expresión" }
        ParseProblem.ExpectedIdentifier: { message = "se esperaba identificador" }
        ParseProblem.ExpectedType: { message = "se esperaba tipo" }
        ParseProblem.ExpectedStatement: { message = "se esperaba sentencia" }
        ParseProblem.ExpectedDeclaration: { message = "se esperaba declaración" }
        ParseProblem.ExpectedToken: { message = "se esperaba token" }
        ParseProblem.UnclosedBlock: { message = "bloque sin cerrar" }
        ParseProblem.UnclosedParenthesis: { message = "paréntesis sin cerrar" }
        ParseProblem.UnclosedBracket: { message = "corchete sin cerrar" }
        ParseProblem.UnclosedInterpolation: { message = "expresión interpolada sin cerrar" }
        ParseProblem.ChainedComparisonsProhibited: { message = "comparaciones encadenadas prohibidas" }
        ParseProblem.NestingLimitExceeded: { message = "límite de anidamiento (128) excedido" }
        ParseProblem.UnexpectedToken: { message = "token inesperado" }
    }
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
    hold exp = view error.expected_token
    when exp.byteLength > 0 {
        printError("{path}:{line}:{column}: error[PARSER]: {message}: '{exp}' (byte {offset})")
    } otherwise {
        printError("{path}:{line}:{column}: error[PARSER]: {message} (byte {offset})")
    }
}

flow parseFile(path: view Text) => Int {
    choose readText(path, 16 * 1024 * 1024) {
        Ok(source): {
            choose lexSource(source) {
                Ok(tokens): {
                    change tree = astNew()
                    hold ok = parseProgram(edit tree, source, tokens, 0)
                    when !ok || tree.errors.length > 0 {
                        each i among 0..tree.errors.length {
                            hold err = view tree.errors[i]
                            reportParseError(path, source, err)
                        }
                        give 1
                    }
                    astDumpCanonical(tree)
                    give 0
                }
                Err(error): {
                    reportLexError(path, source, error)
                    give 6
                }
            }
        }
        Err(code): { give reportFileError(path, code) }
    }
}

flow main() => Int {
    when processArgCount() != 1 {
        printError("Uso: parser-l <archivo.l>")
        give 2
    }
    choose processArg(0) {
        Ok(path): {
            when path.byteLength == 0 {
                printError("Uso: parser-l <archivo.l>")
                give 2
            }
            give parseFile(path)
        }
        Err(code): {
            printError("parser-l: argumento inválido")
            give 2
        }
    }
}
