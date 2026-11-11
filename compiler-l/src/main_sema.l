import lexer
import tokens
import cursor
import ast
import parser
import sema_types
import symbols
import scopes
import ownership_l
import sema_context
import sema_expr
import sema_stmt
import sema
import modules_l

// Keep accesses to CLI pattern bindings behind shared borrows. Stage 0
// forbids moving a field out of a borrowed match-pattern value.
fn cliFlagEquals(flag: &Text, expected: &Text) -> Bool {
    return symbolNameEqualsText(flag, 0, flag.byteLength, expected)
}

fn cliFlagLength(flag: &Text) -> Int {
    return flag.byteLength
}

fn cliFlagByte(flag: &Text, index: Int) -> Int {
    return flag.byteAt(index)
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

// Line:column of `offset` counted from `start` (a module boundary in the
// combined source), so each file reports its own coordinates.
struct LineCol {
    line: Int
    column: Int
}

fn computeLineCol(source: &Text, start: Int, offset: Int) -> LineCol {
    var line = 1
    var column = 1
    for i in start..offset {
        if i < source.byteLength {
            let b = source.byteAt(i)
            if b == 10 {
                line += 1
                column = 1
            } else if b < 128 || b >= 192 {
                column += 1
            }
        }
    }
    return LineCol(line: line, column: column)
}

// The module that owns a byte offset of the combined source.
fn moduleIndexFor(starts: &List<Int>, offset: Int) -> Int {
    var m = 0
    for i in 0..starts.length {
        if starts[i] <= offset { m = i }
    }
    return m
}

fn reportLexError(path: &Text, source: &Text, error: &LexError) {
    let offset = error.offset
    var line = 1
    var column = 1
    for i in 0..offset {
        if i < source.byteLength {
            let b = source.byteAt(i)
            if b == 10 {
                line += 1
                column = 1
            } else if b < 128 || b >= 192 {
                column += 1
            }
        }
    }
    printError("{path}:{line}:{column}: error[LEXER]: error léxico (byte {offset})")
}

fn reportParseError(paths: &List<Text>, starts: &List<Int>, source: &Text, error: &ParseError) {
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
    let m = moduleIndexFor(starts, offset)
    let lc = computeLineCol(source, starts[m], offset)
    let path = &paths[m]
    let exp = &error.expected_token
    if exp.byteLength > 0 {
        printError("{path}:{lc.line}:{lc.column}: error[PARSER]: {message}: '{exp}' (byte {offset})")
    } else {
        printError("{path}:{lc.line}:{lc.column}: error[PARSER]: {message} (byte {offset})")
    }
}

fn reportSemaError(paths: &List<Text>, starts: &List<Int>, source: &Text, error: &SemaError) {
    let offset = error.start
    let m = moduleIndexFor(starts, offset)
    let lc = computeLineCol(source, starts[m], offset)
    let path = &paths[m]
    let code = &error.code
    let msg = &error.message
    printError("{path}:{lc.line}:{lc.column}: error[{code}]: {msg}")
}

fn analyzeFile(path: &Text, dump: Bool, fault: Int, lir: Bool, lir_fault: Int) -> Int {
    match loadProgram(path) {
        Ok(prog) => {
            let source = &prog.source
            if prog.tree.errors.length > 0 {
                for i in 0..prog.tree.errors.length {
                    let err = &prog.tree.errors[i]
                    reportParseError(&prog.module_paths, &prog.module_starts, source, err)
                }
                return 1
            }
            var semaCtx = semaContextNew()
            semaCtx.dump_drops = dump
            semaCtx.drop_fault = fault
            semaCtx.emit_lir = lir
            semaCtx.lir_fault = lir_fault
            semaSetDeclModules(&mut semaCtx, &prog.decl_module)
            semaSetModuleAccess(&mut semaCtx, &prog.module_access, prog.module_count)
            semaAnalyze(&mut semaCtx, source, &prog.tree)
            if semaCtx.errors.length > 0 {
                for i in 0..semaCtx.errors.length {
                    let err = &semaCtx.errors[i]
                    reportSemaError(&prog.module_paths, &prog.module_starts, source, err)
                }
                return 1
            }
            let sym_count = semaCtx.symbols.symbols.length
            let scope_count = semaCtx.scopes.scopes.length
            let type_count = semaCtx.types.types.length
            let blocks = semaCtx.flow_blocks
            let edges = semaCtx.flow_edges
            let paths = semaCtx.flow_paths
            let iterations = semaCtx.flow_iterations
            let loans = semaCtx.flow_loans
            let loan_iterations = semaCtx.loan_iterations
            let drops = semaCtx.drop_count
            let flags = semaCtx.drop_flags
            let drop_ops = semaCtx.drop_ops
            let drop_iterations = semaCtx.drop_iterations
            let lir_insts = semaCtx.lir_insts
            let lir_blocks = semaCtx.lir_blocks
            if lir {
                // The LIR goes to stdout; statistics go to stderr.
                for i in 0..semaCtx.lir_lines.length {
                    let line = &semaCtx.lir_lines[i]
                    print(line)
                }
                print("end")
                printError("LirSummary blocks={lir_blocks} insts={lir_insts} drops={drops} flags={flags}")
                return 0
            }
            let mod_count = prog.module_count
            print("SemaSummary modules={mod_count} symbols={sym_count} scopes={scope_count} types={type_count} blocks={blocks} edges={edges} paths={paths} iterations={iterations} loans={loans} loan_iterations={loan_iterations} drops={drops} flags={flags} drop_ops={drop_ops} drop_iterations={drop_iterations} errors=0")
            return 0
        }
        Err(code) => { return reportFileError(path, code) }
    }
}

fn main() -> Int {
    let count = processArgCount()
    let usage = "Uso: sema-l <archivo.l> [--check-ownership | --drop-plan | --emit-lir]"
    if count < 1 || count > 2 {
        printError(usage)
        return 2
    }
    var dump = false
    var fault = 0
    var lir = false
    var lir_fault = 0
    if count == 2 {
        match processArg(1) {
            Ok(flag) => {
                let check = "--check-ownership"
                let plan = "--drop-plan"
                let fault_flag = "--drop-fault="
                let lir_flag = "--emit-lir"
                let lir_fault_flag = "--lir-fault="
                if cliFlagEquals(flag, lir_flag) {
                    lir = true
                } else if cliFlagLength(flag) == 13 && symbolNameEqualsText(flag, 0, 12, lir_fault_flag) {
                    // Test hook: corrupt the LIR to exercise its verifier.
                    lir = true
                    lir_fault = cliFlagByte(flag, 12) - 48
                } else if cliFlagEquals(flag, plan) {
                    dump = true
                } else if cliFlagLength(flag) == 14 && symbolNameEqualsText(flag, 0, 13, fault_flag) {
                    // Test hook: corrupt the plan to exercise the verifier.
                    fault = cliFlagByte(flag, 13) - 48
                } else if !cliFlagEquals(flag, check) {
                    printError(usage)
                    return 2
                }
            }
            Err(code) => { return 2 }
        }
    }
    match processArg(0) {
        Ok(path) => {
            if path.byteLength == 0 {
                printError(usage)
                return 2
            }
            return analyzeFile(path, dump, fault, lir, lir_fault)
        }
        Err(code) => {
            printError("sema-l: argumento inválido")
            return 2
        }
    }
}
