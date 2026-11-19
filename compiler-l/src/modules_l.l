import lexer
import tokens
import cursor
import ast
import parser
import symbols
import sema_types
import sema_context
import sema
import module_graph_l

fn pathByteToText(b: Int) -> Text {
    if b >= 97 && b <= 122 {
        if b == 97 { return "a" } if b == 98 { return "b" } if b == 99 { return "c" }
        if b == 100 { return "d" } if b == 101 { return "e" } if b == 102 { return "f" }
        if b == 103 { return "g" } if b == 104 { return "h" } if b == 105 { return "i" }
        if b == 106 { return "j" } if b == 107 { return "k" } if b == 108 { return "l" }
        if b == 109 { return "m" } if b == 110 { return "n" } if b == 111 { return "o" }
        if b == 112 { return "p" } if b == 113 { return "q" } if b == 114 { return "r" }
        if b == 115 { return "s" } if b == 116 { return "t" } if b == 117 { return "u" }
        if b == 118 { return "v" } if b == 119 { return "w" } if b == 120 { return "x" }
        if b == 121 { return "y" } return "z"
    }
    if b >= 65 && b <= 90 {
        if b == 65 { return "A" } if b == 66 { return "B" } if b == 67 { return "C" }
        if b == 68 { return "D" } if b == 69 { return "E" } if b == 70 { return "F" }
        if b == 71 { return "G" } if b == 72 { return "H" } if b == 73 { return "I" }
        if b == 74 { return "J" } if b == 75 { return "K" } if b == 76 { return "L" }
        if b == 77 { return "M" } if b == 78 { return "N" } if b == 79 { return "O" }
        if b == 80 { return "P" } if b == 81 { return "Q" } if b == 82 { return "R" }
        if b == 83 { return "S" } if b == 84 { return "T" } if b == 85 { return "U" }
        if b == 86 { return "V" } if b == 87 { return "W" } if b == 88 { return "X" }
        if b == 89 { return "Y" } return "Z"
    }
    if b >= 48 && b <= 57 {
        if b == 48 { return "0" } if b == 49 { return "1" } if b == 50 { return "2" }
        if b == 51 { return "3" } if b == 52 { return "4" } if b == 53 { return "5" }
        if b == 54 { return "6" } if b == 55 { return "7" } if b == 56 { return "8" }
        return "9"
    }
    if b == 47 { return "/" }
    if b == 92 { return "\\" }
    if b == 46 { return "." }
    if b == 95 { return "_" }
    if b == 45 { return "-" }
    if b == 58 { return ":" }
    return ""
}

fn pathSubstring(source: &Text, start: Int, end: Int) -> Text {
    var out = ""
    for i in start..end {
        let ch = pathByteToText(source.byteAt(i))
        out = "{out}{ch}"
    }
    return out
}

fn pathDir(path: &Text) -> Text {
    var last_slash = -1
    for i in 0..path.byteLength {
        let b = path.byteAt(i)
        if b == 47 || b == 92 { last_slash = i }
    }
    if last_slash < 0 { return "." }
    return pathSubstring(path, 0, last_slash)
}

fn pathStem(path: &Text) -> Text {
    var last_slash = -1
    var last_dot = -1
    for i in 0..path.byteLength {
        let b = path.byteAt(i)
        if b == 47 || b == 92 { last_slash = i }
        if b == 46 { last_dot = i }
    }
    var start = 0
    if last_slash >= 0 { start = last_slash + 1 }
    var end = path.byteLength
    if last_dot > start { end = last_dot }
    return pathSubstring(path, start, end)
}

fn listContainsText(list: &List<Text>, item: &Text) -> Bool {
    for i in 0..list.length {
        let elem = &list[i]
        if symbolNameEqualsText(elem, 0, elem.byteLength, item) {
            return true
        }
    }
    return false
}

struct LoadedProgram {
    source: Text
    tree: AstTree
    module_count: Int
    // Per module, in load order (dependencies before importers):
    module_paths: List<Text>
    module_starts: List<Int>
    // Per declaration of the merged tree: the owning module id.
    decl_module: List<Int>
    // Transitive visibility matrix: importer * module_count + definition.
    module_access: List<Int>
}

// `sub.mod` -> `sub/mod.l`, mirroring Stage 0 import resolution.
fn importRelativePath(name: &Text) -> Text {
    var out = ""
    for i in 0..name.byteLength {
        let b = name.byteAt(i)
        if b == 46 {
            out = "{out}/"
        } else {
            out = "{out}{pathByteToText(b)}"
        }
    }
    return "{out}.l"
}

fn listTextIndexOf(list: &List<Text>, item: &Text) -> Int {
    for i in 0..list.length {
        let elem = &list[i]
        if symbolNameEqualsText(elem, 0, elem.byteLength, item) {
            return i
        }
    }
    return -1
}

fn loadModuleRecursive(
    path: &Text,
    loading_stack: &mut List<Text>,
    loaded_paths: &mut List<Text>,
    combined_source: &mut Text,
    tree: &mut AstTree,
    module_paths: &mut List<Text>,
    module_starts: &mut List<Int>,
    module_first_decl: &mut List<Int>,
    module_decl_count: &mut List<Int>,
    dep_first: &mut List<Int>,
    dep_counts: &mut List<Int>,
    dep_ids: &mut List<Int>,
) -> Int {
    if listTextIndexOf(loading_stack, path) >= 0 {
        printError("error[L0014]: ciclo de dependencias detectado: {path}")
        // A loader diagnostic has already been printed: avoid attributing
        // it to the entry file a second time as an unrelated path error.
        return -14
    }
    if listTextIndexOf(loaded_paths, path) >= 0 {
        return 0
    }

    // Match Stage 0's MAX_IMPORT_DEPTH: bound active recursion, not the
    // total number of files in a shallow (wide or diamond-shaped) graph.
    // Check after cycle detection so cyclic imports keep their own L0014.
    // A loader diagnostic is printed once; the caller propagates -14.
    if loading_stack.length >= 128 {
        printError("error[L0014]: profundidad de imports excede el límite de 128 módulos: {path}")
        return -14
    }

    let stack_path = "{path}"
    loading_stack.push(stack_path)

    let own_dir = pathDir(path)
    match readText(path, 16 * 1024 * 1024) {
        Ok(mod_source) => {
            match lexSource(mod_source) {
                Ok(mod_tokens) => {
                    var temp_tree = astNew()
                    parseProgram(&mut temp_tree, &mod_source, &mod_tokens, 0)
                    var direct_deps: List<Int> = List[]

                    // Defer import errors until after the loop. Returning from
                    // inside the nested match/for left owned path temporaries
                    // live in Stage 1's emitted LIR (L0007 in build-lir).
                    // Once an import fails, do not load any subsequent import.
                    var import_error = 0
                    let std_io = "std.io.print"
                    for d in 0..temp_tree.declarations.length {
                        if import_error == 0 {
                            let decl = &temp_tree.declarations[d]
                            match decl.kind {
                                AstDeclKind.Import => {
                                    if !symbolNameEqualsText(mod_source, decl.a, decl.b, std_io) {
                                        let imp_name = pathSubstring(mod_source, decl.a, decl.b)
                                        let dep_path = "{own_dir}/{importRelativePath(&imp_name)}"
                                        let res = loadModuleRecursive(&dep_path, &mut loading_stack, &mut loaded_paths, &mut combined_source, &mut tree, &mut module_paths, &mut module_starts, &mut module_first_decl, &mut module_decl_count, &mut dep_first, &mut dep_counts, &mut dep_ids)
                                        if res != 0 {
                                            import_error = res
                                        } else {
                                            let dep_id = listTextIndexOf(loaded_paths, &dep_path)
                                            if dep_id < 0 {
                                                import_error = 3
                                            } else {
                                                var seen = false
                                                for j in 0..direct_deps.length {
                                                    if direct_deps[j] == dep_id { seen = true }
                                                }
                                                if !seen { direct_deps.push(dep_id) }
                                            }
                                        }
                                    }
                                }
                                _ => {}
                            }
                        }
                    }

                    loading_stack.pop()
                    if import_error != 0 { return import_error }
                    let loaded_path = "{path}"
                    loaded_paths.push(loaded_path)

                    let offset = combined_source.byteLength
                    combined_source = "{combined_source}{mod_source}\n"
                    let file_id = module_paths.length
                    module_paths.push("{path}")
                    module_starts.push(offset)
                    module_first_decl.push(tree.declarations.length)
                    // Lex each source once, using its own BOM and EOF rules.
                    // Keep the legacy combined byte buffer only for AST span
                    // compatibility until source storage is made per-module.
                    // Do not run a second lexer across concatenated files.
                    var tokens: List<LexToken> = List[]
                    for t in 0..mod_tokens.length {
                        let token = &mod_tokens[t]
                        tokens.push(LexToken(kind: tokenKindValue(&token.kind), start: token.start + offset, end: token.end + offset))
                    }
                    parseProgram(&mut tree, combined_source, &tokens, file_id)
                    module_decl_count.push(tree.declarations.length - module_first_decl[module_first_decl.length - 1])
                    dep_first.push(dep_ids.length)
                    dep_counts.push(direct_deps.length)
                    for d in 0..direct_deps.length { dep_ids.push(direct_deps[d]) }
                    return 0
                }
                Err(err) => {
                    loading_stack.pop()
                    return 4
                }
            }
        }
        Err(code) => {
            loading_stack.pop()
            if loading_stack.length > 0 {
                // A missing dependency is an import error, not an absent
                // entry file. Attribute it to the actual dependency path.
                printError("error[L0014]: no se pudo importar {path} (archivo: {code})")
                return -14
            }
            return code
        }
    }
}

pub fn loadProgram(entry_path: &Text) -> Result<LoadedProgram, Int> {
    var loading_stack: List<Text> = List[]
    var loaded_paths: List<Text> = List[]
    var combined_source = ""
    var tree = astNew()
    var module_paths: List<Text> = List[]
    var module_starts: List<Int> = List[]
    var module_first_decl: List<Int> = List[]
    var module_decl_count: List<Int> = List[]
    var dep_first: List<Int> = List[]
    var dep_counts: List<Int> = List[]
    var dep_ids: List<Int> = List[]

    let res = loadModuleRecursive(entry_path, &mut loading_stack, &mut loaded_paths, &mut combined_source, &mut tree, &mut module_paths, &mut module_starts, &mut module_first_decl, &mut module_decl_count, &mut dep_first, &mut dep_counts, &mut dep_ids)
    if res != 0 {
        return Err(res)
    }
    var decl_module: List<Int> = List[]
    for d in 0..tree.declarations.length {
        var owner = 0
        for m in 0..module_first_decl.length {
            let first = module_first_decl[m]
            if d >= first && d < first + module_decl_count[m] {
                owner = m
            }
        }
        decl_module.push(owner)
    }
    let access = moduleAccessBuild(module_paths.length, &dep_first, &dep_counts, &dep_ids)
    return Ok(LoadedProgram(source: combined_source, tree: tree, module_count: module_paths.length, module_paths: module_paths, module_starts: module_starts, decl_module: decl_module, module_access: access))
}
