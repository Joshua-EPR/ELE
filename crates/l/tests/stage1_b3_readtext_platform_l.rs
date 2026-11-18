//! Regression for #90: readText must snapshot its borrowed path before
//! evaluating max_len, and must fail closed for owner temporaries.
//! No Stage 2/self-hosting or owned Result<Text,Int> backend claim.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn checker() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn check(path: &Path) -> (bool, String) {
    let out = Command::new(checker())
        .arg(path)
        .arg("--check-ownership")
        .output()
        .unwrap();
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

fn file(name: &str, source: &str) -> PathBuf {
    let dir = root().join("target/stage1-tests/b3-readtext-platform");
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join(name);
    fs::write(&path, source).unwrap();
    path
}

#[test]
fn readtext_borrows_stable_path_with_independent_length() {
    let valid = file(
        "stable_path.l",
        "fn main() -> Int {\n    let path = \"payload.txt\"\n    let max_len = 4\n    let content = readText(path, max_len)\n    return 0\n}\n",
    );
    let (ok, stderr) = check(&valid);
    assert!(ok, "readText(path, max_len): {stderr}");

    // #5: the owned Result<Text,Int> is a registered builtin union with an
    // atomic drop; the independent Rust protocol validator accepts it.
    let out = Command::new(checker())
        .arg(&valid)
        .arg("--emit-lir")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    let lir = String::from_utf8(out.stdout).unwrap();
    assert!(lir.contains("i platform "), "{lir}");
    assert!(
        lir.contains("i drop "),
        "owned result must be dropped: {lir}"
    );
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();
}

#[test]
fn readtext_rejects_wrong_types_arity_and_unstable_path() {
    let cases = [
        (
            "wrong_path.l",
            "fn main() -> Int {\n    let n = 5\n    let result = readText(n, 4)\n    return 0\n}\n",
            "error[L0004]",
        ),
        (
            "wrong_length.l",
            "fn main() -> Int {\n    let path = \"file.txt\"\n    let result = readText(path, \"four\")\n    return 0\n}\n",
            "error[L0004]",
        ),
        (
            "wrong_arity.l",
            "fn main() -> Int {\n    let path = \"file.txt\"\n    let result = readText(path)\n    return 0\n}\n",
            "error[L0004]",
        ),
        (
            "unstable_path.l",
            "fn main() -> Int {\n    let result = readText(\"file.txt\", 4)\n    return 0\n}\n",
            "error[L0016]",
        ),
    ];
    for (name, source, expected) in cases {
        let path = file(name, source);
        let (ok, stderr) = check(&path);
        assert!(!ok, "{name}: invalid input must fail");
        assert!(
            stderr.contains(expected),
            "{name}: expected {expected}, got {stderr}"
        );
    }
}
