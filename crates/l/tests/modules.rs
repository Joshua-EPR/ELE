use std::{
    fs,
    path::PathBuf,
    process::{Command, Output},
};

const BACKENDS: [&str; 2] = ["cranelift", "rustc"];

struct ModuleFixture {
    dir: PathBuf,
}

impl ModuleFixture {
    fn new(case: &str) -> Self {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/module-tests")
            .join(case);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Self { dir }
    }

    fn write_file(&self, rel_path: &str, content: &str) {
        let full = self.dir.join(rel_path);
        if let Some(parent) = full.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(full, content).unwrap();
    }

    fn build(&self, entry_file: &str, backend: &str, trace: bool) -> Output {
        let mut build = Command::new(env!("CARGO_BIN_EXE_l"));
        build
            .current_dir(&self.dir)
            .args(["build", entry_file, "--backend", backend]);
        if trace {
            build.arg("--trace-alloc");
        }
        build.output().unwrap()
    }

    fn check(&self, entry_file: &str, expected_stdout: &str) {
        for backend in BACKENDS {
            let build_out = self.build(entry_file, backend, false);
            assert!(
                build_out.status.success(),
                "{backend} build failed: {}",
                String::from_utf8_lossy(&build_out.stderr)
            );
            let stdout = String::from_utf8(build_out.stdout).unwrap();
            let exe = stdout
                .lines()
                .find_map(|s| s.strip_prefix("Build: "))
                .unwrap();
            let mut run = Command::new(self.dir.join(exe));
            if backend == "cranelift" {
                run.env("PATH", "");
            }
            let run_out = run.output().unwrap();
            assert!(
                run_out.status.success(),
                "{backend} run failed: {}",
                String::from_utf8_lossy(&run_out.stderr)
            );
            assert_eq!(
                String::from_utf8_lossy(&run_out.stdout),
                expected_stdout,
                "{backend}"
            );
        }
    }
}

#[test]
fn import_local_single_module() {
    let fix = ModuleFixture::new("single");
    fix.write_file("helper.l", "pub fn sumar(a: Int, b: Int) -> Int = a + b\n");
    fix.write_file(
        "main.l",
        "import helper\n\nfn main() {\n    print(sumar(15, 27))\n}\n",
    );
    fix.check("main.l", "42\n");
}

#[test]
fn import_multiple_modules() {
    let fix = ModuleFixture::new("multiple");
    fix.write_file("calc.l", "pub fn cuadrado(x: Int) -> Int = x * x\n");
    fix.write_file(
        "saludo.l",
        "pub fn saludar(nombre: Text) -> Text = \"Hola {nombre}!\"\n",
    );
    fix.write_file(
        "main.l",
        "import calc\nimport saludo\n\nfn main() {\n    print(cuadrado(6))\n    print(saludar(\"Mundo\"))\n}\n",
    );
    fix.check("main.l", "36\nHola Mundo!\n");
}

#[test]
fn import_transitive_dependencies() {
    let fix = ModuleFixture::new("transitive");
    fix.write_file("datos.l", "pub fn base() -> Int = 100\n");
    fix.write_file(
        "logica.l",
        "import datos\n\npub fn calcular() -> Int = base() + 25\n",
    );
    fix.write_file(
        "main.l",
        "import logica\n\nfn main() {\n    print(calcular())\n}\n",
    );
    fix.check("main.l", "125\n");
}

#[test]
fn import_diamond_dependency_deduplication() {
    let fix = ModuleFixture::new("diamond");
    fix.write_file(
        "comun.l",
        "struct Ajustes {\n    puerto: Int\n}\n\npub fn obtenerAjustes() -> Ajustes = Ajustes(puerto: 8080)\n",
    );
    fix.write_file(
        "servicio_a.l",
        "import comun\n\npub fn puertoA() -> Int = obtenerAjustes().puerto\n",
    );
    fix.write_file(
        "servicio_b.l",
        "import comun\n\npub fn puertoB() -> Int = obtenerAjustes().puerto + 1\n",
    );
    fix.write_file(
        "main.l",
        "import servicio_a\nimport servicio_b\n\nfn main() {\n    print(puertoA())\n    print(puertoB())\n}\n",
    );
    fix.check("main.l", "8080\n8081\n");
}

#[test]
fn import_missing_module_error() {
    let fix = ModuleFixture::new("missing");
    fix.write_file("main.l", "import modulo_inexistente\n\nfn main() {}\n");
    for backend in BACKENDS {
        let out = fix.build("main.l", backend, false);
        assert!(!out.status.success(), "{backend}");
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(err.contains("L0014"), "{backend}: {err}");
        assert!(
            err.contains("módulo no encontrado: modulo_inexistente"),
            "{backend}: {err}"
        );
    }
}

#[test]
fn import_cycle_detection() {
    let fix = ModuleFixture::new("cycle");
    fix.write_file("nodo_a.l", "import nodo_b\nfn a() {}\n");
    fix.write_file("nodo_b.l", "import nodo_a\nfn b() {}\n");
    fix.write_file("main.l", "import nodo_a\nfn main() {}\n");
    for backend in BACKENDS {
        let out = fix.build("main.l", backend, false);
        assert!(!out.status.success(), "{backend}");
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(err.contains("L0014"), "{backend}: {err}");
        assert!(
            err.contains("nodo_a -> nodo_b -> nodo_a"),
            "{backend}: {err}"
        );
    }
}

#[test]
fn import_submodule_with_dots() {
    let fix = ModuleFixture::new("submodule");
    fix.write_file("sub/motor.l", "pub fn potencia() -> Int = 750\n");
    fix.write_file(
        "main.l",
        "import sub.motor\n\nfn main() {\n    print(potencia())\n}\n",
    );
    fix.check("main.l", "750\n");
}

#[test]
fn import_semicolon_and_newlines() {
    let fix = ModuleFixture::new("semicolon");
    fix.write_file("mod1.l", "pub fn f1() -> Int = 10\n");
    fix.write_file("mod2.l", "pub fn f2() -> Int = 20\n");
    fix.write_file(
        "main.l",
        "import mod1; import mod2;\r\n\r\nfn main() {\n    print(f1() + f2())\n}\n",
    );
    fix.check("main.l", "30\n");
}

#[test]
fn import_unicode_directory_and_spaces() {
    let fix = ModuleFixture::new("unicode_dir");
    fix.write_file(
        "directorio café 👋/util.l",
        "pub fn saludo() -> Text = \"éxito en carpeta unicode\"\n",
    );
    fix.write_file(
        "directorio café 👋/main.l",
        "import util\n\nfn main() {\n    print(saludo())\n}\n",
    );
    fix.check("directorio café 👋/main.l", "éxito en carpeta unicode\n");
}

/// A semantic error inside an imported module names that module, with the
/// line and column inside it, not the entry file (Stage 0 defect 1).
#[test]
fn semantic_errors_in_imported_modules_name_their_own_file() {
    let fix = ModuleFixture::new("diagnostic-file");
    fix.write_file(
        "sub/ayudante.l",
        "pub fn ayuda() -> Int {\n    return 1\n}\n\nfn rota() -> Int {\n    return verdadero\n}\n",
    );
    fix.write_file(
        "intermedio.l",
        "import sub.ayudante\n\npub fn doble() -> Int = ayuda() * 2\n",
    );
    fix.write_file(
        "main.l",
        "import intermedio\n\nfn main() {\n    print(doble())\n}\n",
    );
    let check = |entry: &str| {
        let out = Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(&fix.dir)
            .args(["check", entry])
            .output()
            .unwrap();
        assert!(!out.status.success());
        String::from_utf8_lossy(&out.stderr).into_owned()
    };
    let err = check("main.l");
    let first = err.lines().next().unwrap();
    assert!(
        first.contains("ayudante.l:6:12: L0001 [semántica]"),
        "{err}"
    );
    assert!(first.contains("verdadero"), "{err}");
    assert!(!first.contains("main.l"), "{err}");

    // The same program with the error moved to the entry file names it.
    fix.write_file(
        "sub/ayudante.l",
        "pub fn ayuda() -> Int {\n    return 1\n}\n",
    );
    fix.write_file(
        "main.l",
        "import intermedio\n\nfn main() {\n    print(doble())\n    print(nada)\n}\n",
    );
    let err = check("main.l");
    assert!(err.starts_with("main.l:5:11: L0001"), "{err}");

    // And so does the library entry point.
    let error = project_l::check_file(&fix.dir.join("main.l")).unwrap_err();
    assert!(
        error.file.as_deref().unwrap().ends_with("main.l"),
        "{error:?}"
    );
    fix.write_file(
        "intermedio.l",
        "import sub.ayudante\n\npub fn doble() -> Int = ayuda() * verdad\n",
    );
    fix.write_file(
        "main.l",
        "import intermedio\n\nfn main() {\n    print(doble())\n}\n",
    );
    let error = project_l::check_file(&fix.dir.join("main.l")).unwrap_err();
    let file = error.file.expect("file of an imported module");
    assert!(file.ends_with("intermedio.l"), "{file}");
    assert_eq!((error.span.line, error.span.column), (3, 35));
}

#[test]
fn unambiguous_private_function_stays_in_its_module() {
    let fix = ModuleFixture::new("private_single_nonexported");
    fix.write_file("lib.l", "flow secret() => Int { give 42 }\n");
    fix.write_file("main.l", "take lib\nflow main() { print(secret()) }\n");
    for backend in BACKENDS {
        let out = fix.build("main.l", backend, false);
        assert!(!out.status.success(), "{backend}");
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(
            err.contains("función no definida: secret"),
            "{backend}: {err}"
        );
        assert!(err.contains("main.l"), "{backend}: {err}");
    }
}

#[test]
fn unambiguous_private_generic_stays_in_its_module() {
    let fix = ModuleFixture::new("private_generic_nonexported");
    fix.write_file("lib.l", "flow secret of[T](value: T) => Int { give 42 }\n");
    fix.write_file(
        "main.l",
        "take lib\nflow main() { print(secret of[Int](0)) }\n",
    );
    for backend in BACKENDS {
        let out = fix.build("main.l", backend, false);
        assert!(!out.status.success(), "{backend}");
        let err = String::from_utf8_lossy(&out.stderr);
        assert!(
            err.contains("función no definida: secret"),
            "{backend}: {err}"
        );
        assert!(err.contains("main.l"), "{backend}: {err}");
    }
}

#[test]
fn private_functions_with_equal_names_are_resolved_in_their_own_modules() {
    // Regression for issue #31. Neither Stage 0 backend may conflate the
    // private helpers of two imported modules. Source syntax is ELE v2.
    let fix = ModuleFixture::new("private_name_identity");
    fix.write_file(
        "a.l",
        "flow helper() => Int { give 1 }\nexpose flow from_a() => Int { give helper() }\n",
    );
    fix.write_file(
        "b.l",
        "flow helper() => Int { give 41 }\nexpose flow from_b() => Int { give helper() }\n",
    );
    fix.write_file(
        "main.l",
        "take a\ntake b\nflow main() { print(from_a() + from_b()) }\n",
    );
    fix.check("main.l", "42\n");
}

#[test]
fn ambiguous_private_function_is_not_resolved_from_another_module() {
    let fix = ModuleFixture::new("private_ambiguous");
    fix.write_file("a.l", "flow helper() => Int { give 1 }\n");
    fix.write_file("b.l", "flow helper() => Int { give 41 }\n");
    fix.write_file(
        "main.l",
        "take a\ntake b\nflow main() { print(helper()) }\n",
    );
    for backend in BACKENDS {
        let output = fix.build("main.l", backend, false);
        assert!(!output.status.success(), "{backend}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("función no definida: helper"),
            "{backend}: {stderr}"
        );
    }
}

#[test]
fn homonymous_private_generic_functions_keep_distinct_instantiations() {
    // Each generic helper produces a distinct result; one global function
    // template table would either reject the module or call the wrong body.
    let fix = ModuleFixture::new("generic_private_identity");
    fix.write_file(
        "a.l",
        "flow helper of[T](value: T) => Int { give 1 }\nexpose flow from_a() => Int { give helper of[Int](0) }\n",
    );
    fix.write_file(
        "b.l",
        "flow helper of[T](value: T) => Int { give 41 }\nexpose flow from_b() => Int { give helper of[Int](0) }\n",
    );
    fix.write_file(
        "main.l",
        "take a\ntake b\nflow main() { print(from_a() + from_b()) }\n",
    );
    fix.check("main.l", "42\n");
}

#[test]
fn homonymous_private_generic_function_is_not_exported_ambiguously() {
    let fix = ModuleFixture::new("generic_private_ambiguous");
    fix.write_file("a.l", "flow helper of[T](value: T) => Int { give 1 }\n");
    fix.write_file("b.l", "flow helper of[T](value: T) => Int { give 41 }\n");
    fix.write_file(
        "main.l",
        "take a\ntake b\nflow main() { print(helper of[Int](0)) }\n",
    );
    for backend in BACKENDS {
        let output = fix.build("main.l", backend, false);
        assert!(!output.status.success(), "{backend}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("función no definida: helper"),
            "{backend}: {stderr}"
        );
    }
}

#[test]
fn homonymous_generic_declaration_in_one_module_still_fails() {
    let fix = ModuleFixture::new("generic_duplicate_local");
    fix.write_file(
        "main.l",
        "flow helper of[T](value: T) => Int { give 1 }\nflow helper of[T](value: T) => Int { give 2 }\nflow main() { print(42) }\n",
    );
    for backend in BACKENDS {
        let output = fix.build("main.l", backend, false);
        assert!(!output.status.success(), "{backend}");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("función duplicada o reservada: helper"),
            "{backend}: {stderr}"
        );
    }
}

#[test]
fn public_symbol_from_unrelated_sibling_is_not_visible() {
    // main's import of b must never make b's exports visible inside a.
    let fix = ModuleFixture::new("sibling_public_not_imported");
    fix.write_file(
        "a.l",
        "expose flow from_a() => Int { give only_b() }\n",
    );
    fix.write_file("b.l", "expose flow only_b() => Int { give 42 }\n");
    fix.write_file(
        "main.l",
        "take a\ntake b\nflow main() { print(from_a()) }\n",
    );
    for backend in BACKENDS {
        let out = fix.build("main.l", backend, false);
        assert!(!out.status.success(), "{backend}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("función no definida: only_b"), "{backend}: {stderr}");
        assert!(stderr.contains("a.l"), "{backend}: {stderr}");
    }
}

#[test]
fn transitive_public_symbol_requires_direct_import() {
    // a may call b after take b, but main may not call b without take b.
    let fix = ModuleFixture::new("transitive_public_not_imported");
    fix.write_file("b.l", "expose flow only_b() => Int { give 42 }\n");
    fix.write_file(
        "a.l",
        "take b\nexpose flow from_a() => Int { give only_b() }\n",
    );
    fix.write_file("main.l", "take a\nflow main() { print(only_b()) }\n");
    for backend in BACKENDS {
        let out = fix.build("main.l", backend, false);
        assert!(!out.status.success(), "{backend}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("función no definida: only_b"), "{backend}: {stderr}");
        assert!(stderr.contains("main.l"), "{backend}: {stderr}");
    }
}

#[test]
fn direct_import_in_dependency_still_resolves() {
    let fix = ModuleFixture::new("nested_direct_import_valid");
    fix.write_file("b.l", "expose flow only_b() => Int { give 42 }\n");
    fix.write_file(
        "a.l",
        "take b\nexpose flow from_a() => Int { give only_b() }\n",
    );
    fix.write_file("main.l", "take a\nflow main() { print(from_a()) }\n");
    fix.check("main.l", "42\n");
}

#[test]
fn public_generic_from_sibling_is_not_visible() {
    let fix = ModuleFixture::new("sibling_generic_not_imported");
    fix.write_file(
        "a.l",
        "expose flow from_a() => Int { give only_b of[Int](0) }\n",
    );
    fix.write_file(
        "b.l",
        "expose flow only_b of[T](value: T) => Int { give 42 }\n",
    );
    fix.write_file(
        "main.l",
        "take a\ntake b\nflow main() { print(from_a()) }\n",
    );
    for backend in BACKENDS {
        let out = fix.build("main.l", backend, false);
        assert!(!out.status.success(), "{backend}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("función no definida: only_b"), "{backend}: {stderr}");
        assert!(stderr.contains("a.l"), "{backend}: {stderr}");
    }
}

#[test]
fn direct_generic_import_in_dependency_still_resolves() {
    let fix = ModuleFixture::new("nested_generic_direct_valid");
    fix.write_file(
        "b.l",
        "expose flow only_b of[T](value: T) => Int { give 42 }\n",
    );
    fix.write_file(
        "a.l",
        "take b\nexpose flow from_a() => Int { give only_b of[Int](0) }\n",
    );
    fix.write_file("main.l", "take a\nflow main() { print(from_a()) }\n");
    fix.check("main.l", "42\n");
}

#[test]
fn identical_public_names_in_unrelated_modules_keep_identity() {
    let fix = ModuleFixture::new("public_same_name_per_module");
    fix.write_file(
        "a.l",
        "expose flow shared() => Int { give 1 }\nexpose flow from_a() => Int { give shared() }\n",
    );
    fix.write_file(
        "b.l",
        "expose flow shared() => Int { give 41 }\nexpose flow from_b() => Int { give shared() }\n",
    );
    fix.write_file(
        "main.l",
        "take a\ntake b\nflow main() { print(from_a() + from_b()) }\n",
    );
    fix.check("main.l", "42\n");
}

#[test]
fn two_direct_public_imports_with_same_name_are_ambiguous() {
    let fix = ModuleFixture::new("ambiguous_direct_public");
    fix.write_file("a.l", "expose flow shared() => Int { give 1 }\n");
    fix.write_file("b.l", "expose flow shared() => Int { give 41 }\n");
    fix.write_file(
        "main.l",
        "take a\ntake b\nflow main() { print(shared()) }\n",
    );
    for backend in BACKENDS {
        let out = fix.build("main.l", backend, false);
        assert!(!out.status.success(), "{backend}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("función ambigua: shared"), "{backend}: {stderr}");
        assert!(stderr.contains("main.l"), "{backend}: {stderr}");
    }
}

#[test]
fn two_direct_public_generic_imports_are_ambiguous() {
    let fix = ModuleFixture::new("ambiguous_direct_generic");
    fix.write_file(
        "a.l",
        "expose flow shared of[T](value: T) => Int { give 1 }\n",
    );
    fix.write_file(
        "b.l",
        "expose flow shared of[T](value: T) => Int { give 41 }\n",
    );
    fix.write_file(
        "main.l",
        "take a\ntake b\nflow main() { print(shared of[Int](0)) }\n",
    );
    for backend in BACKENDS {
        let out = fix.build("main.l", backend, false);
        assert!(!out.status.success(), "{backend}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains("función genérica ambigua: shared"), "{backend}: {stderr}");
        assert!(stderr.contains("main.l"), "{backend}: {stderr}");
    }
}
