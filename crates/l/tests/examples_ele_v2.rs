//! Regresión de la migración de todos los ejemplos de usuario a ELE v2.
use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

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
        "fn", "struct", "enum", "impl", "trait", "let", "var", "const",
        "return", "if", "else", "for", "while", "loop", "break", "continue",
        "match", "self", "pub", "import", "module", "region", "async",
        "await", "spawn",
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
