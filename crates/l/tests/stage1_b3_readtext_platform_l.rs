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
    let platform_line = lir
        .lines()
        .find(|line| line.contains(" readtext 2 "))
        .expect("readText platform instruction absent");
    assert!(
        platform_line.contains(" ref p"),
        "path must be passed as ref place: {platform_line}"
    );
    assert!(
        platform_line.contains(" val v") || platform_line.contains(" val ci"),
        "max_len must be passed as val: {platform_line}"
    );
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

#[test]
fn readtext_evaluates_max_len_with_calls_and_temporaries_preserving_borrow() {
    // 1. max_len evaluated from a function call with local variables and arithmetic
    let call_case = file(
        "call_len.l",
        r#"fn compute_len(factor: Int) -> Int {
    let base = 10
    return base + factor
}

fn main() -> Int {
    let path = "payload.txt"
    let content = readText(path, compute_len(6))
    return 0
}
"#,
    );
    let (ok, stderr) = check(&call_case);
    assert!(ok, "readText with function call in max_len: {stderr}");
    let out = Command::new(checker())
        .arg(&call_case)
        .arg("--emit-lir")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    let lir = String::from_utf8(out.stdout).unwrap();
    assert!(lir.contains("i call "), "call in max_len must be lowered: {lir}");
    let platform_line = lir
        .lines()
        .find(|line| line.contains(" readtext 2 "))
        .expect("readText platform instruction absent");
    assert!(platform_line.contains(" ref p"), "path must be ref: {platform_line}");
    assert!(platform_line.contains(" val v"), "max_len must be val: {platform_line}");
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();

    // 2. max_len evaluated with temporary list collection passed to helper
    let temp_list_case = file(
        "temp_list_len.l",
        r#"fn sum_list(xs: List<Int>) -> Int {
    var total = 0
    for x in xs {
        total = total + x
    }
    return total
}

fn main() -> Int {
    let path = "payload.txt"
    let content = readText(path, sum_list(List[10, 20, 30]))
    return 0
}
"#,
    );
    let (ok, stderr) = check(&temp_list_case);
    assert!(ok, "readText with temporary list in max_len: {stderr}");
    let out = Command::new(checker())
        .arg(&temp_list_case)
        .arg("--emit-lir")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    let lir = String::from_utf8(out.stdout).unwrap();
    assert!(lir.contains("i listlit "), "list literal must be lowered: {lir}");
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();

    // 3. max_len shared re-borrow of path (&Text) is compatible with readText's loan
    let reborrow_case = file(
        "shared_reborrow_len.l",
        r#"fn inspect(p: &Text) -> Int {
    return 16
}

fn main() -> Int {
    let path = "payload.txt"
    let content = readText(path, inspect(&path))
    return 0
}
"#,
    );
    let (ok, stderr) = check(&reborrow_case);
    assert!(ok, "readText with shared re-borrow in max_len: {stderr}");
    let out = Command::new(checker())
        .arg(&reborrow_case)
        .arg("--emit-lir")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    let lir = String::from_utf8(out.stdout).unwrap();
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();

    // 4. match on readText result with Ok/Err branches and computed max_len
    let match_case = file(
        "match_readtext.l",
        r#"fn compute_limit(factor: Int) -> Int {
    return factor * 1024
}

fn main() -> Int {
    let path = "payload.txt"
    match readText(path, compute_limit(4)) {
        Ok(content) => {
            return 0
        }
        Err(code) => {
            return code
        }
    }
}
"#,
    );
    let (ok, stderr) = check(&match_case);
    assert!(ok, "match on readText with computed max_len: {stderr}");
    let out = Command::new(checker())
        .arg(&match_case)
        .arg("--emit-lir")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    let lir = String::from_utf8(out.stdout).unwrap();
    let readtext = lir.lines()
        .find(|line| line.contains(" readtext 2 "))
        .expect("readText platform instruction required");
    assert!(readtext.contains(" ref p"), "path must be a loaned place: {readtext}");
    assert!(
        readtext.contains(" val v") || readtext.contains(" val ci"),
        "computed max_len must be passed by value: {readtext}"
    );
    assert!(lir.contains("i disc "), "variant discriminant required");
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();
}

#[test]
fn readtext_adversarial_rejects_borrow_conflicts_during_max_len() {
    let cases = [
        (
            "mut_borrow_conflict.l",
            r#"fn touch(p: &mut Text) -> Int {
    return 10
}

fn main() -> Int {
    var path = "test.txt"
    let content = readText(path, touch(&mut path))
    return 0
}
"#,
            "error[L0012]",
        ),
        (
            "move_conflict.l",
            r#"fn consume(p: Text) -> Int {
    return 10
}

fn main() -> Int {
    let path = "test.txt"
    let content = readText(path, consume(path))
    return 0
}
"#,
            "error[L0012]",
        ),
        (
            "unstable_path_with_computed_len.l",
            r#"fn compute(n: Int) -> Int { return n * 2 }

fn main() -> Int {
    let content = readText("test.txt", compute(10))
    return 0
}
"#,
            "error[L0016]",
        ),
    ];
    for (name, source, expected) in cases {
        let path = file(name, source);
        let (ok, stderr) = check(&path);
        assert!(!ok, "{name}: adversarial borrow violation must fail");
        assert!(
            stderr.contains(expected),
            "{name}: expected {expected}, got {stderr}"
        );
    }
}
