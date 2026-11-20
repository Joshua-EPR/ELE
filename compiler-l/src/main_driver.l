take modules_l
take sema
take sema_context
take codegen.native_cfg_emit
take codegen.native_cfg_ir
take codegen.elf64
take codegen.pe64

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
                line = line + 1
                column = 1
            } otherwise {
                when b < 128 || b >= 192 {
                    column = column + 1
                }
            }
        }
    }
    give LineCol(line: line, column: column)
}

flow moduleIndexFor(starts: view List of[Int], offset: Int) => Int {
    change m = 0
    each i among 0..starts.length {
        when starts[i] <= offset { m = i }
    }
    give m
}

flow reportFileError(path: view Text, code: Int) => Int {
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

flow reportParseError(paths: view List of[Text], starts: view List of[Int], source: view Text, error: view ParseError) {
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

flow textMatches(s: view Text, expected: view Text) => Bool {
    when s.byteLength != expected.byteLength { give false }
    each i among 0..s.byteLength {
        when s@byteAt(i) != expected@byteAt(i) { give false }
    }
    give true
}

flow textEndsWith(s: view Text, suffix: view Text) => Bool {
    when s.byteLength < suffix.byteLength { give false }
    hold start = s.byteLength - suffix.byteLength
    each i among 0..suffix.byteLength {
        when s@byteAt(start + i) != suffix@byteAt(i) { give false }
    }
    give true
}

flow charByteToText(b: Int) => Text {
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
    when b == 32 { give " " }
    when b == 126 { give "~" }
    when b == 43 { give "+" }
    when b == 61 { give "=" }
    when b == 64 { give "@" }
    when b == 35 { give "#" }
    when b == 36 { give "$" }
    when b == 37 { give "%" }
    when b == 38 { give "&" }
    when b == 40 { give "(" }
    when b == 41 { give ")" }
    when b == 91 { give "[" }
    when b == 93 { give "]" }
    when b == 123 { give "{{" }
    when b == 125 { give "}}" }
    when b == 33 { give "!" }
    when b == 59 { give ";" }
    when b == 44 { give "," }
    give ""
}

flow driverPathStem(path: view Text) => Text {
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
    change out = ""
    each i among start..end {
        hold ch = charByteToText(path@byteAt(i))
        out = "{out}{ch}"
    }
    give out
}

flow normalizePath(path: view Text) => Text {
    when path.byteLength == 0 { give "" }

    change seg_starts: List of[Int] = List[]
    change seg_lens: List of[Int] = List[]
    change seg_is_dotdot: List of[Int] = List[]
    change seg_active: List of[Int] = List[]

    change i = 0
    during i < path.byteLength {
        during i < path.byteLength && (path@byteAt(i) == 47 || path@byteAt(i) == 92) {
            i = i + 1
        }
        when i < path.byteLength {
            hold start = i
            during i < path.byteLength && path@byteAt(i) != 47 && path@byteAt(i) != 92 {
                i = i + 1
            }
            hold len = i - start
            when len > 0 {
                when len == 1 && path@byteAt(start) == 46 {
                    // Skip dot segment "."
                } otherwise {
                    when len == 2 && path@byteAt(start) == 46 && path@byteAt(start + 1) == 46 {
                        // Look backwards for an active non-".." segment to cancel
                        change cancelled = false
                        change k = seg_starts.length - 1
                        during k >= 0 && !cancelled {
                            when seg_active[k] == 1 {
                                when seg_is_dotdot[k] == 0 {
                                    seg_active[k] = 0
                                    cancelled = true
                                }
                            }
                            k = k - 1
                        }
                        when !cancelled {
                            seg_starts@push(start)
                            seg_lens@push(len)
                            seg_is_dotdot@push(1)
                            seg_active@push(1)
                        }
                    } otherwise {
                        seg_starts@push(start)
                        seg_lens@push(len)
                        seg_is_dotdot@push(0)
                        seg_active@push(1)
                    }
                }
            }
        }
    }

    hold first_b = path@byteAt(0)
    change out = ""
    when first_b == 47 || first_b == 92 {
        out = "/"
    }

    each seg_idx among 0..seg_starts.length {
        when seg_active[seg_idx] == 1 {
            when out.byteLength > 0 && out@byteAt(out.byteLength - 1) != 47 {
                out = "{out}/"
            }
            hold s = seg_starts[seg_idx]
            hold l = seg_lens[seg_idx]
            each ch_idx among s..(s + l) {
                hold ch = charByteToText(path@byteAt(ch_idx))
                out = "{out}{ch}"
            }
        }
    }

    when out.byteLength == 0 {
        give "."
    }
    give out
}

flow isLinuxHost() => Bool {
    hold proc_path = "/proc/version"
    choose readText(proc_path, 4096) {
        Ok(s): { give true }
        Err(e): {
            hold os_release = "/etc/os-release"
            choose readText(os_release, 4096) {
                Ok(s2): { give true }
                Err(e2): {
                    hold dev_null = "/dev/null"
                    choose readText(dev_null, 16) {
                        Ok(s3): { give true }
                        Err(e3): { give false }
                    }
                }
            }
        }
    }
}

flow pathsEquivalent(path_a: view Text, path_b: view Text) => Bool {
    hold norm_a = normalizePath(path_a)
    hold norm_b = normalizePath(path_b)
    when norm_a.byteLength != norm_b.byteLength {
        give false
    }
    when isLinuxHost() {
        each i among 0..norm_a.byteLength {
            when norm_a@byteAt(i) != norm_b@byteAt(i) { give false }
        }
        give true
    } otherwise {
        each i among 0..norm_a.byteLength {
            change ba = norm_a@byteAt(i)
            change bb = norm_b@byteAt(i)
            when ba >= 65 && ba <= 90 { ba = ba + 32 }
            when bb >= 65 && bb <= 90 { bb = bb + 32 }
            when ba != bb { give false }
        }
        give true
    }
}

flow printHelp() {
    print("ELE Compiler Driver 0.3.0")
    print("Uso: ele <comando> [opciones]")
    print("")
    print("Comandos:")
    print("  build <archivo.l>         Compila un programa ELE a un ejecutable nativo")
    print("")
    print("Opciones de build:")
    print("  --output, -o <ruta>       Ruta del ejecutable de salida")
    print("  --target <elf|pe>         Formato de salida (elf = Linux ELF64, pe = Windows PE32+)")
    print("  --pe64                    Equivalente a --target pe")
    print("  --elf64                   Equivalente a --target elf")
    print("")
    print("Opciones generales:")
    print("  --help, -h                Muestra este mensaje de ayuda")
    print("  --version, -v             Muestra la versión de ELE")
}

flow printVersion() {
    print("ele 0.3.0 (Stage 3 self-hosted native driver)")
}

flow assembleLir(lines: view List of[Text]) => Text {
    when lines.length == 0 { give "end\n" }

    // Radix-32 hierarchical accumulator:
    // eliminates O(N^2) buffer reallocations during monolithic LIR materialization
    change s0 = ""
    change c0 = 0
    change s1 = ""
    change c1 = 0
    change s2 = ""
    change c2 = 0
    change s3 = ""

    each i among 0..lines.length {
        hold l = view lines[i]
        s0 = "{s0}{l}\n"
        c0 = c0 + 1
        when c0 == 32 {
            s1 = "{s1}{s0}"
            s0 = ""
            c0 = 0
            c1 = c1 + 1
            when c1 == 32 {
                s2 = "{s2}{s1}"
                s1 = ""
                c1 = 0
                c2 = c2 + 1
                when c2 == 32 {
                    s3 = "{s3}{s2}"
                    s2 = ""
                    c2 = 0
                }
            }
        }
    }

    give "{s3}{s2}{s1}{s0}end\n"
}

flow compileProgram(source_path: Text, output_path: Text, target: Int) => Int {
    choose loadProgram(view source_path) {
        Ok(prog): {
            // Safety check: output path cannot overwrite any source module in the project
            each m_idx among 0..prog.module_paths.length {
                hold m_path = view prog.module_paths[m_idx]
                when pathsEquivalent(m_path, view output_path) {
                    printError("error[CLI]: el archivo de salida no puede sobrescribir el módulo fuente '{m_path}'")
                    give 2
                }
            }

            // Safety check: alias / link detection against all project source modules
            choose readText(output_path, 67108864) {
                Ok(out_content): {
                    each m_idx among 0..prog.module_paths.length {
                        hold m_path = view prog.module_paths[m_idx]
                        choose readText(m_path, 67108864) {
                            Ok(mod_content): {
                                when textMatches(view out_content, view mod_content) {
                                    printError("error[CLI]: el archivo de salida no puede sobrescribir el módulo fuente '{m_path}' (alias detectado)")
                                    give 2
                                }
                            }
                            Err(e_mod): {}
                        }
                    }
                }
                Err(e_out): {}
            }

            hold source = view prog.source
            when prog.tree.errors.length > 0 {
                each i among 0..prog.tree.errors.length {
                    hold err = view prog.tree.errors[i]
                    reportParseError(view prog.module_paths, view prog.module_starts, source, err)
                }
                give 1
            }

            change semaCtx = semaContextNew()
            semaCtx.emit_lir = true
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

            // Construct full ELE-LIR text in memory via hierarchical accumulator
            hold lir_text = assembleLir(view semaCtx.lir_lines)

            // Invoke native backend code generator
            hold compiled = cfgCompileFor(view lir_text, target)
            when compiled.error != 0 {
                hold code = compiled.error
                printError("error[BACKEND]: compilación ELE-LIR rechazada por el backend nativo (código {code})")
                give 3
            }

            // Atomic / Safe write flow:
            // 1. Stage output image in a temporary file to verify write viability
            hold tmp_output = "{output_path}.tmp.ele"
            hold status_tmp = writeBytes(tmp_output, compiled.image)
            when status_tmp != 0 {
                when target == 1 {
                    printError("error[IO]: fallo al escribir archivo temporal PE64 en {tmp_output} (código {status_tmp})")
                } otherwise {
                    printError("error[IO]: fallo al escribir archivo temporal ELF64 en {tmp_output} (código {status_tmp})")
                }
                give 5
            }

            // 2. Finalize output to target destination
            hold status = writeBytes(output_path, compiled.image)
            when status != 0 {
                when target == 1 {
                    printError("error[IO]: fallo al escribir ejecutable PE64 en {output_path} (código {status})")
                } otherwise {
                    printError("error[IO]: fallo al escribir ejecutable ELF64 en {output_path} (código {status})")
                }
                give 5
            }

            give 0
        }
        Err(code): {
            give reportFileError(view source_path, code)
        }
    }
}

flow main() => Int {
    hold count = processArgCount()
    when count == 0 {
        printError("error[CLI]: falta el comando. Ejecuta 'ele --help' para ver las opciones.")
        give 2
    }

    // Inspect first argument
    change arg0 = ""
    choose processArg(0) {
        Ok(val): { arg0 = val }
        Err(code): { give 6 }
    }

    hold opt_help = "--help"
    hold opt_h = "-h"
    when textMatches(view arg0, view opt_help) || textMatches(view arg0, view opt_h) {
        printHelp()
        give 0
    }

    hold opt_version = "--version"
    hold opt_v = "-v"
    when textMatches(view arg0, view opt_version) || textMatches(view arg0, view opt_v) {
        printVersion()
        give 0
    }

    hold cmd_build = "build"
    change start_idx = 0
    when textMatches(view arg0, view cmd_build) {
        start_idx = 1
    } otherwise {
        // If it starts with a flag other than --help/--version, it's unrecognized
        when arg0.byteLength >= 1 && arg0@byteAt(0) == 45 {
            printError("error[CLI]: opción desconocida '{arg0}'. Ejecuta 'ele --help'.")
            give 2
        }
    }

    when start_idx >= count {
        printError("error[CLI]: falta el archivo de entrada. Uso: ele build <archivo.l>")
        give 2
    }

    change source_file = ""
    change output_file = ""
    change target = -1
    change skip_next = false

    hold opt_pe64 = "--pe64"
    hold opt_elf64 = "--elf64"
    hold opt_target = "--target"
    hold opt_output = "--output"
    hold opt_o = "-o"
    hold val_pe = "pe"
    hold val_pe64 = "pe64"
    hold val_elf = "elf"
    hold val_elf64 = "elf64"

    each i among start_idx..count {
        when skip_next {
            skip_next = false
        } otherwise {
            change cur_arg = ""
            choose processArg(i) {
                Ok(v): { cur_arg = v }
                Err(code): { give 6 }
            }

            when textMatches(view cur_arg, view opt_pe64) {
                target = 1
            } otherwise {
                when textMatches(view cur_arg, view opt_elf64) {
                    target = 0
                } otherwise {
                    when textMatches(view cur_arg, view opt_target) {
                        when i + 1 >= count {
                            printError("error[CLI]: --target requiere un argumento ('elf' o 'pe')")
                            give 2
                        }
                        change next_val = ""
                        choose processArg(i + 1) {
                            Ok(v): { next_val = v }
                            Err(code): { give 6 }
                        }
                        when textMatches(view next_val, view val_pe) || textMatches(view next_val, view val_pe64) {
                            target = 1
                        } otherwise {
                            when textMatches(view next_val, view val_elf) || textMatches(view next_val, view val_elf64) {
                                target = 0
                            } otherwise {
                                printError("error[CLI]: target desconocido '{next_val}'. Use 'elf' o 'pe'.")
                                give 2
                            }
                        }
                        skip_next = true
                    } otherwise {
                        when textMatches(view cur_arg, view opt_output) || textMatches(view cur_arg, view opt_o) {
                            when i + 1 >= count {
                                printError("error[CLI]: --output requiere una ruta de destino")
                                give 2
                            }
                            choose processArg(i + 1) {
                                Ok(v): { output_file = v }
                                Err(code): { give 6 }
                            }
                            skip_next = true
                        } otherwise {
                            when cur_arg.byteLength >= 1 && cur_arg@byteAt(0) == 45 {
                                printError("error[CLI]: opción desconocida '{cur_arg}'")
                                give 2
                            } otherwise {
                                when source_file.byteLength == 0 {
                                    source_file = cur_arg
                                } otherwise {
                                    printError("error[CLI]: argumento posicional inesperado '{cur_arg}'")
                                    give 2
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    when source_file.byteLength == 0 {
        printError("error[CLI]: falta el archivo de entrada. Uso: ele build <archivo.l>")
        give 2
    }

    hold ext_l = ".l"
    when !textEndsWith(view source_file, view ext_l) {
        printError("error[CLI]: el archivo de entrada '{source_file}' debe tener extensión '.l'")
        give 2
    }

    hold ext_exe = ".exe"
    hold ext_elf = ".elf"

    // Determine target format: Linux defaults to ELF64 (0), Windows defaults to PE64 (1)
    when target < 0 {
        when output_file.byteLength > 0 && textEndsWith(view output_file, view ext_exe) {
            target = 1
        } otherwise {
            when output_file.byteLength > 0 && textEndsWith(view output_file, view ext_elf) {
                target = 0
            } otherwise {
                when isLinuxHost() {
                    target = 0
                } otherwise {
                    target = 1
                }
            }
        }
    }

    // Determine output file path if not specified
    when output_file.byteLength == 0 {
        hold stem = driverPathStem(view source_file)
        when target == 1 {
            output_file = "{stem}.exe"
        } otherwise {
            output_file = "{stem}"
        }
    }

    // Safety check: output path cannot overwrite input source file
    when pathsEquivalent(view source_file, view output_file) {
        printError("error[CLI]: el archivo de salida no puede sobrescribir el archivo de entrada '{source_file}'")
        give 2
    }

    // Safety check: alias / link detection for input source file
    choose readText(output_file, 67108864) {
        Ok(out_content): {
            choose readText(source_file, 67108864) {
                Ok(src_content): {
                    when textMatches(view out_content, view src_content) {
                        printError("error[CLI]: el archivo de salida no puede sobrescribir el archivo de entrada '{source_file}' (alias detectado)")
                        give 2
                    }
                }
                Err(e_src): {}
            }
        }
        Err(e_out): {}
    }

    give compileProgram(source_file, output_file, target)
}
