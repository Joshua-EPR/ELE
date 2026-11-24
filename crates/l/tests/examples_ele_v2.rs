//! Regresión de la migración de todos los ejemplos de usuario a ELE v2.
use project_l::check;
use std::{fs, path::PathBuf, process::Command};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn example_files() -> Vec<PathBuf> {
    let mut stack = vec![root().join("examples")];
    let mut result = Vec::new();
    while let Some(directory) = stack.pop() {
        for entry in fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|extension| extension == "l") {
                result.push(path);
            }
        }
    }
    result.sort();
    assert!(result.len() >= 40, "faltan ejemplos del repositorio");
    result
}

// Eliminar literales y comentarios antes de buscar palabras antiguas.
// Un mensaje como "la palabra fn" no debe fallar la comprobación.
fn code_without_comments_and_strings(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut clean = Vec::with_capacity(bytes.len());
    let mut i = 0;
    let mut block_depth = 0usize;
    while i < bytes.len() {
        if block_depth > 0 {
            if bytes[i..].starts_with(b"/*") {
                block_depth += 1;
                i += 2;
            } else if bytes[i..].starts_with(b"*/") {
                block_depth -= 1;
                i += 2;
            } else {
                i += 1;
            }
            clean.push(b' ');
            continue;
        }
        if bytes[i..].starts_with(b"//") {
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            clean.push(b' ');
            continue;
        }
        if bytes[i..].starts_with(b"/*") {
            block_depth = 1;
            i += 2;
            clean.push(b' ');
            continue;
        }
        if bytes[i] == b'"' {
            i += 1;
            while i < bytes.len() {
                if bytes[i] == b'\\' {
                    i += 2;
                } else if bytes[i] == b'"' {
                    i += 1;
                    break;
                } else {
                    i += 1;
                }
            }
            clean.push(b' ');
            continue;
        }
        clean.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&clean).into_owned()
}

#[test]
fn all_example_sources_use_canonical_ele_syntax() {
    let legacy = [
        "fn", "struct", "enum", "impl", "trait", "let", "var", "const", "return", "if", "else",
        "for", "while", "loop", "break", "continue", "match", "self", "pub", "import", "module",
        "region", "async", "await", "spawn",
    ];
    for file in example_files() {
        let source = fs::read_to_string(&file).unwrap();
        let clean = code_without_comments_and_strings(&source);
        for token in clean.split(|c: char| !c.is_ascii_alphanumeric() && c != '_') {
            assert!(
                !legacy.contains(&token),
                "{}: todavía utiliza la palabra histórica {token}",
                file.display()
            );
        }
        assert!(
            !clean.contains("->") && !clean.contains("&mut"),
            "{}: todavía utiliza operadores de la sintaxis histórica",
            file.display()
        );
    }
}

#[test]
fn valid_examples_continue_to_pass_the_stage_zero_frontend() {
    for file in example_files() {
        if file.components().any(|c| c.as_os_str() == "invalid") {
            continue;
        }
        let source = fs::read_to_string(&file).unwrap();
        assert!(
            check(&source).is_ok(),
            "Stage 0 rechazó el ejemplo válido {}",
            file.display()
        );
    }
}

#[test]
fn intentionally_invalid_examples_remain_rejected() {
    for file in example_files() {
        if !file.components().any(|c| c.as_os_str() == "invalid") {
            continue;
        }
        let source = fs::read_to_string(&file).unwrap();
        assert!(
            check(&source).is_err(),
            "Stage 0 aceptó un ejemplo negativo {}",
            file.display()
        );
    }
}

fn run_example(name: &str) -> std::process::Output {
    let directory = root().join("target/examples-ele-v2").join(name);
    fs::create_dir_all(&directory).unwrap();
    let file = format!("{name}.l");
    fs::copy(root().join("examples").join(&file), directory.join(&file)).unwrap();
    Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(directory)
        .arg("run")
        .arg(file)
        .output()
        .unwrap()
}

#[test]
fn migrated_examples_preserve_observable_output() {
    for (name, expected) in [
        ("arithmetic", "42\n"),
        ("constants", "42\n43\ntrue\n"),
        ("contador", "Valor: 2\n"),
        ("control_flow", "15\n"),
        ("fibonacci", "Fibonacci: 55\n"),
        ("hello", "42\n"),
        ("loops", "12\n"),
    ] {
        let result = run_example(name);
        assert!(
            result.status.success(),
            "{name}: {}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert_eq!(
            String::from_utf8(result.stdout).unwrap(),
            expected,
            "{name}"
        );
    }
}

// Mantener el núcleo del backend ELE en la sintaxis oficial. Esta prueba
// controla la superficie; las pruebas native_* compilan Stage 1 y ejecutan
// ELF64 para validar el comportamiento y el ownership por separado.
#[test]
fn migrated_native_cfg_core_uses_ele_v2_surface() {
    let migrated = [
        "native_cfg_verify.l",
        "native_cfg_emit.l",
        "native_cfg_ir.l",
        "native_cfg_inst.l",
        "native_cfg_types.l",
        "native_cfg_paths.l",
        "native_cfg_fields.l",
        "native_cfg_list.l",
        "native_cfg_list_emit.l",
        "native_cfg_loan.l",
        "native_cfg_ref.l",
        "native_cfg_arith.l",
        "native_heap_dynamic.l",
        "native_heap_owner.l",
        "native_heap_resize.l",
        "native_list_int.l",
        "native_rt_list.l",
        "native_trap.l",
    ];
    let legacy = [
        "fn", "struct", "enum", "impl", "trait", "let", "var", "const", "return", "if", "else",
        "for", "while", "loop", "break", "continue", "match", "self", "pub", "import", "module",
    ];
    for name in migrated {
        let file = root().join("compiler-l/src/codegen").join(name);
        let source = fs::read_to_string(&file).unwrap();
        let clean = code_without_comments_and_strings(&source);
        for token in clean.split(|c: char| !c.is_ascii_alphanumeric() && c != '_') {
            assert!(
                !legacy.contains(&token),
                "{}: palabra de la sintaxis histórica: {token}",
                file.display()
            );
        }
        assert!(
            !clean.contains("->")
                && !clean.contains("&mut")
                && !clean.contains("&view")
                && !clean.contains("List<"),
            "{}: el módulo conserva operadores o tipos de la gramática histórica",
            file.display()
        );
    }
}
