take lexer
take tokens
take cursor
take ast
take parser
take symbols
take sema_types
take sema_context
take sema
take module_graph_l

flow pathByteToText(b: Int) => Text {
    when b >= 97 && b <= 122 {
        when b == 97 { give "a" } when b == 98 { give "b" } when b == 99 { give "c" }
        when b == 100 { give "d" } when b == 101 { give "e" } when b == 102 { give "f" }
        when b == 103 { give "g" } when b == 104 { give "h" } when b == 105 { give "i" }
        when b == 106 { give "j" } when b == 107 { give "k" } when b == 108 { give "l" }
        when b == 109 { give "m" } when b == 110 { give "n" } when b == 111 { give "o" }
        when b == 112 { give "p" } when b == 113 { give "q" } when b == 114 { give "r" }
        when b == 115 { give "s" } when b == 116 { give "t" } when b == 117 { give "u" }
        when b == 118 { give "v" } when b == 119 { give "w" } when b == 120 { give "x" }
        when b == 121 { give "y" } give "z"
    }
    when b >= 65 && b <= 90 {
        when b == 65 { give "A" } when b == 66 { give "B" } when b == 67 { give "C" }
        when b == 68 { give "D" } when b == 69 { give "E" } when b == 70 { give "F" }
        when b == 71 { give "G" } when b == 72 { give "H" } when b == 73 { give "I" }
        when b == 74 { give "J" } when b == 75 { give "K" } when b == 76 { give "L" }
        when b == 77 { give "M" } when b == 78 { give "N" } when b == 79 { give "O" }
        when b == 80 { give "P" } when b == 81 { give "Q" } when b == 82 { give "R" }
        when b == 83 { give "S" } when b == 84 { give "T" } when b == 85 { give "U" }
        when b == 86 { give "V" } when b == 87 { give "W" } when b == 88 { give "X" }
        when b == 89 { give "Y" } give "Z"
    }
    when b >= 48 && b <= 57 {
        when b == 48 { give "0" } when b == 49 { give "1" } when b == 50 { give "2" }
        when b == 51 { give "3" } when b == 52 { give "4" } when b == 53 { give "5" }
        when b == 54 { give "6" } when b == 55 { give "7" } when b == 56 { give "8" }
        give "9"
    }
    when b == 47 { give "/" }
    when b == 92 { give "\\" }
    when b == 46 { give "." }
    when b == 95 { give "_" }
    when b == 45 { give "-" }
    when b == 58 { give ":" }
    give ""
}

flow pathSubstring(source: view Text, start: Int, end: Int) => Text {
    change out = ""
    each i among start..end {
        hold ch = pathByteToText(source@byteAt(i))
        out = "{out}{ch}"
    }
    give out
}

flow pathDir(path: view Text) => Text {
    change last_slash = -1
    each i among 0..path.byteLength {
        hold b = path@byteAt(i)
        when b == 47 || b == 92 { last_slash = i }
    }
    when last_slash < 0 { give "." }
    give pathSubstring(path, 0, last_slash)
}

flow pathStem(path: view Text) => Text {
    change last_slash = -1
    change last_dot = -1
    each i among 0..path.byteLength {
        hold b = path@byteAt(i)
        when b == 47 || b == 92 { last_slash = i }
        when b == 46 { last_dot = i }
    }
    change start = 0
    when last_slash >= 0 { start = last_slash + 1 }
    change end = path.byteLength
    when last_dot > start { end = last_dot }
    give pathSubstring(path, start, end)
}

flow listContainsText(list: view List of[Text], item: view Text) => Bool {
    each i among 0..list.length {
        hold elem = view list[i]
        when symbolNameEqualsText(elem, 0, elem.byteLength, item) {
            give true
        }
    }
    give false
}

shape LoadedProgram {
    source: Text
    tree: AstTree
    module_count: Int
    // Per module, in load order (dependencies before importers):
    module_paths: List of[Text]
    module_starts: List of[Int]
    // Per declaration of the merged tree: the owning module id.
    decl_module: List of[Int]
    // Transitive visibility matrix: importer * module_count + definition.
    module_access: List of[Int]
}

// `sub.mod` -> `sub/mod.l`, mirroring Stage 0 import resolution.
flow importRelativePath(name: view Text) => Text {
    change out = ""
    each i among 0..name.byteLength {
        hold b = name@byteAt(i)
        when b == 46 {
            out = "{out}/"
        } otherwise {
            out = "{out}{pathByteToText(b)}"
        }
    }
    give "{out}.l"
}

flow listTextIndexOf(list: view List of[Text], item: view Text) => Int {
    each i among 0..list.length {
        hold elem = view list[i]
        when symbolNameEqualsText(elem, 0, elem.byteLength, item) {
            give i
        }
    }
    give -1
}

flow loadModuleRecursive(
    path: view Text,
    lib_root: view Text,
    loading_stack: edit List of[Text],
    loaded_paths: edit List of[Text],
    combined_source: edit Text,
    tree: edit AstTree,
    module_paths: edit List of[Text],
    module_starts: edit List of[Int],
    module_first_decl: edit List of[Int],
    module_decl_count: edit List of[Int],
    dep_first: edit List of[Int],
    dep_counts: edit List of[Int],
    dep_ids: edit List of[Int],
) => Int {
    when listTextIndexOf(loading_stack, path) >= 0 {
        printError("error[L0014]: ciclo de dependencias detectado: {path}")
        // A loader diagnostic has already been printed: avoid attributing
        // it to the entry file a second time as an unrelated path error.
        give -14
    }
    when listTextIndexOf(loaded_paths, path) >= 0 {
        give 0
    }

    // Match Stage 0's MAX_IMPORT_DEPTH: bound active recursion, not the
    // total number of files in a shallow (wide or diamond-shaped) graph.
    // Check after cycle detection so cyclic imports keep their own L0014.
    // A loader diagnostic is printed once; the caller propagates -14.
    when loading_stack.length >= 128 {
        printError("error[L0014]: profundidad de imports excede el límite de 128 módulos: {path}")
        give -14
    }

    hold stack_path = "{path}"
    loading_stack@push(stack_path)

    hold own_dir = pathDir(path)
    choose readText(path, 16 * 1024 * 1024) {
        Ok(mod_source) : {
            choose lexSource(mod_source) {
                Ok(mod_tokens) : {
                    change temp_tree = astNew()
                    parseProgram(edit temp_tree, view mod_source, view mod_tokens, 0)
                    change direct_deps: List of[Int] = List[]

                    // Defer import errors until after the loop. Returning from
                    // inside the nested match/for left owned path temporaries
                    // live in Stage 1's emitted LIR (L0007 in build-lir).
                    // Once an import fails, do not load any subsequent import.
                    change import_error = 0
                    hold std_io = "std.io.print"
                    // Kernel intrinsic modules: recognized by sema, no file.
                    hold nucleo_cpu = "nucleo.cpu"
                    hold nucleo_mem = "nucleo.mem"
                    each d among 0..temp_tree.declarations.length {
                        when import_error == 0 {
                            hold decl = view temp_tree.declarations[d]
                            choose decl.kind {
                                AstDeclKind.Import : {
                                    when !symbolNameEqualsText(mod_source, decl.a, decl.b, std_io) && !symbolNameEqualsText(mod_source, decl.a, decl.b, nucleo_cpu) && !symbolNameEqualsText(mod_source, decl.a, decl.b, nucleo_mem) {
                                        hold imp_name = pathSubstring(mod_source, decl.a, decl.b)
                                        hold relative_file = importRelativePath(view imp_name)
                                        change dep_path = "{own_dir}/{relative_file}"

                                        // Local imports win. Only an absent local module (I/O
                                        // code 2) may fall back to the explicit --lib root.
                                        // Invalid UTF-8, permissions and size errors must
                                        // not be silently masked by a library copy.
                                        when lib_root.byteLength > 0 {
                                            choose readText(dep_path, 16 * 1024 * 1024) {
                                                Ok(local_module): {}
                                                Err(code): {
                                                    when code == 2 {
                                                        dep_path = "{lib_root}/{relative_file}"
                                                    }
                                                }
                                            }
                                        }
                                        hold res = loadModuleRecursive(view dep_path, lib_root, edit loading_stack, edit loaded_paths, edit combined_source, edit tree, edit module_paths, edit module_starts, edit module_first_decl, edit module_decl_count, edit dep_first, edit dep_counts, edit dep_ids)
                                        when res != 0 {
                                            import_error = res
                                        } otherwise {
                                            hold dep_id = listTextIndexOf(loaded_paths, view dep_path)
                                            when dep_id < 0 {
                                                import_error = 3
                                            } otherwise {
                                                change seen = false
                                                each j among 0..direct_deps.length {
                                                    when direct_deps[j] == dep_id { seen = true }
                                                }
                                                when !seen { direct_deps@push(dep_id) }
                                            }
                                        }
                                    }
                                }
                                _ : {}
                            }
                        }
                    }

                    loading_stack@pop()
                    when import_error != 0 { give import_error }
                    hold loaded_path = "{path}"
                    loaded_paths@push(loaded_path)

                    hold offset = combined_source.byteLength
                    combined_source = "{combined_source}{mod_source}\n"
                    hold file_id = module_paths.length
                    module_paths@push("{path}")
                    module_starts@push(offset)
                    module_first_decl@push(tree.declarations.length)
                    // Lex each source once, using its own BOM and EOF rules.
                    // Keep the legacy combined byte buffer only for AST span
                    // compatibility until source storage is made per-module.
                    // Do not run a second lexer across concatenated files.
                    change tokens: List of[LexToken] = List[]
                    each t among 0..mod_tokens.length {
                        hold token = view mod_tokens[t]
                        tokens@push(LexToken(kind: tokenKindValue(view token.kind), start: token.start + offset, end: token.end + offset))
                    }
                    parseProgram(edit tree, combined_source, view tokens, file_id)
                    module_decl_count@push(tree.declarations.length - module_first_decl[module_first_decl.length - 1])
                    dep_first@push(dep_ids.length)
                    dep_counts@push(direct_deps.length)
                    each d among 0..direct_deps.length { dep_ids@push(direct_deps[d]) }
                    give 0
                }
                Err(err) : {
                    // readText already proved the bytes are valid UTF-8:
                    // this is a lexical error of this module, reported with
                    // its own position (never as an I/O or UTF-8 failure).
                    hold prefix = "error[LEXER]: "
                    printError(lexDiagnostic(path, view mod_source, view err, view prefix))
                    loading_stack@pop()
                    give -14
                }
            }
        }
        Err(code) : {
            loading_stack@pop()
            when loading_stack.length > 0 {
                // A missing dependency is an import error, not an absent
                // entry file. Attribute it to the actual dependency path.
                printError("error[L0014]: no se pudo importar {path} (archivo: {code})")
                give -14
            }
            give code
        }
    }
}

// --lib is a search root containing the std/ directory, not std/ itself.
expose flow loadProgramWithLibRoot(entry_path: view Text, lib_root: view Text) => Result of[LoadedProgram, Int] {
    change loading_stack: List of[Text] = List[]
    change loaded_paths: List of[Text] = List[]
    change combined_source = ""
    change tree = astNew()
    change module_paths: List of[Text] = List[]
    change module_starts: List of[Int] = List[]
    change module_first_decl: List of[Int] = List[]
    change module_decl_count: List of[Int] = List[]
    change dep_first: List of[Int] = List[]
    change dep_counts: List of[Int] = List[]
    change dep_ids: List of[Int] = List[]

    hold res = loadModuleRecursive(entry_path, lib_root, edit loading_stack, edit loaded_paths, edit combined_source, edit tree, edit module_paths, edit module_starts, edit module_first_decl, edit module_decl_count, edit dep_first, edit dep_counts, edit dep_ids)
    when res != 0 {
        give Err(res)
    }
    change decl_module: List of[Int] = List[]
    each d among 0..tree.declarations.length {
        change owner = 0
        each m among 0..module_first_decl.length {
            hold first = module_first_decl[m]
            when d >= first && d < first + module_decl_count[m] {
                owner = m
            }
        }
        decl_module@push(owner)
    }
    hold access = moduleAccessBuild(module_paths.length, view dep_first, view dep_counts, view dep_ids)
    give Ok(LoadedProgram(source: combined_source, tree: tree, module_count: module_paths.length, module_paths: module_paths, module_starts: module_starts, decl_module: decl_module, module_access: access))
}

// Preserve the historic loader signature for main_sema and Stage 0 fixtures.
// Projects that do not opt into --lib remain strictly relative-only.
expose flow loadProgram(entry_path: view Text) => Result of[LoadedProgram, Int] {
    hold empty_root = ""
    give loadProgramWithLibRoot(entry_path, view empty_root)
}
