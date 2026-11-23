take lexer
take tokens
take cursor
take ast
take parser
take sema_types
take symbols
take scopes
take ownership_l
take sema_context
take sema_expr
take sema_stmt
take sema
take modules_l

flow reportFileError(path: view Text, code: Int) => Int {
    // loadModuleRecursive has already reported the import path/cycle.
    when code == -14 { give 1 }
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

// Line:column of `offset` counted from `start` (a module boundary in the
// combined source), so each file reports its own coordinates.
shape LineCol {
    line: Int
    column: Int
}

flow computeLineCol(source: view Text, start: Int, offset: Int) => LineCol {
    change line = 1
    change column = 1
    each i among start..offset {
        when i < source.byteLength {
            hold b = source@byteAt(i)
            when b == 10 {
                line += 1
                column = 1
            } otherwise when b < 128 || b >= 192 {
                column += 1
            }
        }
    }
    give LineCol(line: line, column: column)
}

// The module that owns a byte offset of the combined source.
flow moduleIndexFor(starts: view List of[Int], offset: Int) => Int {
    change m = 0
    each i among 0..starts.length {
        when starts[i] <= offset { m = i }
    }
    give m
}

flow reportLexError(path: view Text, source: view Text, error: view LexError) {
    hold offset = error.offset
    change line = 1
    change column = 1
    each i among 0..offset {
        when i < source.byteLength {
            hold b = source@byteAt(i)
            when b == 10 {
                line += 1
                column = 1
            } otherwise when b < 128 || b >= 192 {
                column += 1
            }
        }
    }
    printError("{path}:{line}:{column}: error[LEXER]: error léxico (byte {offset})")
}

flow reportParseError(paths: view List of[Text], starts: view List of[Int], source: view Text, error: view ParseError) {
    hold offset = error.token_start
    change message = "error sintáctico"
    choose error.problem {
        ParseProblem.ExpectedExpression : { message = "se esperaba expresión" }
        ParseProblem.ExpectedIdentifier : { message = "se esperaba identificador" }
        ParseProblem.ExpectedType : { message = "se esperaba tipo" }
        ParseProblem.ExpectedStatement : { message = "se esperaba sentencia" }
        ParseProblem.ExpectedDeclaration : { message = "se esperaba declaración" }
        ParseProblem.ExpectedToken : { message = "se esperaba token" }
        ParseProblem.UnclosedBlock : { message = "bloque sin cerrar" }
        ParseProblem.UnclosedParenthesis : { message = "paréntesis sin cerrar" }
        ParseProblem.UnclosedBracket : { message = "corchete sin cerrar" }
        ParseProblem.UnclosedInterpolation : { message = "expresión interpolada sin cerrar" }
        ParseProblem.ChainedComparisonsProhibited : { message = "comparaciones encadenadas prohibidas" }
        ParseProblem.NestingLimitExceeded : { message = "límite de anidamiento (128) excedido" }
        ParseProblem.UnexpectedToken : { message = "token inesperado" }
    }
    hold m = moduleIndexFor(starts, offset)
    hold lc = computeLineCol(source, starts[m], offset)
    hold path = view paths[m]
    hold exp = view error.expected_token
    when exp.byteLength > 0 {
        printError("{path}:{lc.line}:{lc.column}: error[PARSER]: {message}: '{exp}' (byte {offset})")
    } otherwise {
        printError("{path}:{lc.line}:{lc.column}: error[PARSER]: {message} (byte {offset})")
    }
}

flow reportSemaError(paths: view List of[Text], starts: view List of[Int], source: view Text, error: view SemaError) {
    hold offset = error.start
    hold m = moduleIndexFor(starts, offset)
    hold lc = computeLineCol(source, starts[m], offset)
    hold path = view paths[m]
    hold code = view error.code
    hold msg = view error.message
    printError("{path}:{lc.line}:{lc.column}: error[{code}]: {msg}")
}

flow analyzeFile(path: view Text, dump: Bool, fault: Int, lir: Bool, lir_fault: Int, patch: Text) => Int {
    choose loadProgram(path) {
        Ok(prog) : {
            hold source = view prog.source
            when prog.tree.errors.length > 0 {
                each i among 0..prog.tree.errors.length {
                    hold err = view prog.tree.errors[i]
                    reportParseError(view prog.module_paths, view prog.module_starts, source, err)
                }
                give 1
            }
            change semaCtx = semaContextNew()
            semaCtx.dump_drops = dump
            semaCtx.drop_fault = fault
            semaCtx.emit_lir = lir
            semaCtx.lir_fault = lir_fault
            semaCtx.lir_patch = patch
            semaSetDeclModules(edit semaCtx, view prog.decl_module)
            semaSetModuleAccess(edit semaCtx, view prog.module_access, prog.module_count)
            semaAnalyze(edit semaCtx, source, view prog.tree)
            when semaCtx.errors.length > 0 {
                each i among 0..semaCtx.errors.length {
                    hold err = view semaCtx.errors[i]
                    reportSemaError(view prog.module_paths, view prog.module_starts, source, err)
                }
                give 1
            }
            hold sym_count = semaCtx.symbols.symbols.length
            hold scope_count = semaCtx.scopes.scopes.length
            hold type_count = semaCtx.types.types.length
            hold blocks = semaCtx.flow_blocks
            hold edges = semaCtx.flow_edges
            hold paths = semaCtx.flow_paths
            hold iterations = semaCtx.flow_iterations
            hold loans = semaCtx.flow_loans
            hold loan_iterations = semaCtx.loan_iterations
            hold drops = semaCtx.drop_count
            hold flags = semaCtx.drop_flags
            hold drop_ops = semaCtx.drop_ops
            hold drop_iterations = semaCtx.drop_iterations
            hold lir_insts = semaCtx.lir_insts
            hold lir_blocks = semaCtx.lir_blocks
            when lir {
                // The LIR goes to stdout; statistics go to stderr.
                each i among 0..semaCtx.lir_lines.length {
                    hold line = view semaCtx.lir_lines[i]
                    print(line)
                }
                each i among 0..semaCtx.lir_functions.length {
                    hold line = view semaCtx.lir_functions[i]
                    print(line)
                }
                print("end")
                printError("LirSummary blocks={lir_blocks} insts={lir_insts} drops={drops} flags={flags}")
                give 0
            }
            hold mod_count = prog.module_count
            print("SemaSummary modules={mod_count} symbols={sym_count} scopes={scope_count} types={type_count} blocks={blocks} edges={edges} paths={paths} iterations={iterations} loans={loans} loan_iterations={loan_iterations} drops={drops} flags={flags} drop_ops={drop_ops} drop_iterations={drop_iterations} errors=0")
            give 0
        }
        Err(code) : { give reportFileError(path, code) }
    }
}

flow main() => Int {
    hold count = processArgCount()
    hold usage = "Uso: sema-l <archivo.l> [--check-ownership | --drop-plan | --emit-lir] | sema-l <archivo.l> --lir-patch <parche>"
    when count < 1 || count > 3 {
        printError(usage)
        give 2
    }
    change dump = false
    change fault = 0
    change lir = false
    change lir_fault = 0
    change patch = ""
    when count == 3 {
        // Test hook: verify a lowered function rewritten by a patch file.
        hold patch_flag = "--lir-patch"
        change known = false
        choose processArg(1) {
            Ok(flag): { known = symbolNameEqualsText(flag, 0, flag.byteLength, patch_flag) }
            Err(code): {}
        }
        when !known {
            printError(usage)
            give 2
        }
        choose processArg(2) {
            Ok(file): {
                choose readText(file, 1048576) {
                    Ok(text): { patch = text }
                    Err(code): {
                        printError("sema-l: no se pudo leer el parche de LIR")
                        give 2
                    }
                }
            }
            Err(code): { give 2 }
        }
        lir = true
    }
    when count == 2 {
        choose processArg(1) {
            Ok(flag) : {
                hold check = "--check-ownership"
                hold plan = "--drop-plan"
                hold fault_flag = "--drop-fault="
                hold lir_flag = "--emit-lir"
                hold lir_fault_flag = "--lir-fault="
                when symbolNameEqualsText(flag, 0, flag.byteLength, lir_flag) {
                    lir = true
                } otherwise when (flag.byteLength == 13 || flag.byteLength == 14) && symbolNameEqualsText(flag, 0, 12, lir_fault_flag) {
                    // Two-digit injection ids cover platform contract faults.
                    hold digit = flag@byteAt(12)
                    when digit < 48 || digit > 57 { printError(usage); give 2 }
                    lir_fault = digit - 48
                    when flag.byteLength == 14 {
                        hold second = flag@byteAt(13)
                        when second < 48 || second > 57 { printError(usage); give 2 }
                        lir_fault = lir_fault * 10 + second - 48
                    }
                    lir = true
                } otherwise when symbolNameEqualsText(flag, 0, flag.byteLength, plan) {
                    dump = true
                } otherwise when flag.byteLength == 14 && symbolNameEqualsText(flag, 0, 13, fault_flag) {
                    // Test hook: corrupt the plan to exercise the verifier.
                    fault = flag@byteAt(13) - 48
                } otherwise when !symbolNameEqualsText(flag, 0, flag.byteLength, check) {
                    printError(usage)
                    give 2
                }
            }
            Err(code) : { give 2 }
        }
    }
    choose processArg(0) {
        Ok(path) : {
            when path.byteLength == 0 {
                printError(usage)
                give 2
            }
            give analyzeFile(path, dump, fault, lir, lir_fault, patch)
        }
        Err(code) : {
            printError("sema-l: argumento inválido")
            give 2
        }
    }
}
