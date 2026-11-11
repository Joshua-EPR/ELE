//! ELE v2 built-in generic types in the ELE-written Stage 1 frontend.
//! This covers the existing List/Option/Result subset, NOT user generics.
mod stage1_support;

use std::{fs, path::PathBuf, process::Command, sync::OnceLock};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn stage1() -> &'static std::path::Path {
    static BIN: OnceLock<PathBuf> = OnceLock::new();
    BIN.get_or_init(|| stage1_support::build("main_sema", false))
}

fn validate_source(label: &str, source: &str, success: bool) -> String {
    let path = root()
        .join("target/stage1-tests/ele-v2-of-types")
        .join(format!("{label}.l"));
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, source).unwrap();
    let output = Command::new(stage1()).arg(&path).output().unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    assert_eq!(
        output.status.success(),
        success,
        "{label}: expected success={success}, stderr: {stderr}, stdout: {}",
        String::from_utf8_lossy(&output.stdout)
    );
    stderr
}

#[test]
fn stage1_accepts_ele_generic_builtins_with_nested_of_types() {
    let cases = [
        ("list", "List of[Int]", "List<Int>"),
        ("option", "Option of[Int]", "Option<Int>"),
        ("result", "Result of[Int, Text]", "Result<Int, Text>"),
        ("nested", "List of[Option of[Int]]", "List<Option<Int>>"),
    ];
    for (case, canonical, legacy) in cases {
        for (dialect, ty) in [("ele", canonical), ("legacy", legacy)] {
            // A declared parameter exercises type resolution and drop analysis
            // without pretending that the ELF backend can execute generic heaps.
            let source = format!(
                "flow probe(value: {ty}) => Int {{ give 1 }}\nflow main() => Int {{ give 42 }}\n"
            );
            validate_source(&format!("{case}-{dialect}"), &source, true);
        }
    }
}

#[test]
fn stage1_rejects_malformed_generic_syntax_without_dropping_type_checks() {
    for (case, ty) in [
        ("unclosed", "List of[Int"),
        ("empty", "List of[]"),
        ("wrong-arity", "List of[Int, Bool]"),
        ("unknown", "Unknown of[Int]"),
    ] {
        let source = format!(
            "flow probe(value: {ty}) => Int {{ give 1 }}\nflow main() => Int {{ give 42 }}\n"
        );
        validate_source(case, &source, false);
    }
}
