//! Stage 1 owned Option/Result drop classification in real .l sources.
//! Drop plans are analyzed but owned unions remain blocked from ELE-LIR
//! until tagged ABI, active-payload moves and recursive drops are verified.
mod stage1_support;

use std::{
    fs,
    path::PathBuf,
    process::{Command, Output},
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
fn checker() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}
fn run(name: &str, src: &str, flag: &str) -> Output {
    let dir = root().join("target/stage1-tests/b3-owned-union-drops");
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join(format!("{name}.l"));
    fs::write(&path, src).unwrap();
    Command::new(checker())
        .arg(&path)
        .arg(flag)
        .env("PATH", "")
        .output()
        .unwrap()
}
fn plan(name: &str, src: &str) -> String {
    let output = run(name, src, "--drop-plan");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{name}: {stderr}");
    String::from_utf8(output.stdout).unwrap()
}
fn drops(dump: &str) -> usize {
    dump.lines()
        .filter(|line| line.starts_with("O drop ") || line.starts_with("O cdrop "))
        .count()
}

#[test]
fn owned_result_from_process_arg_has_drop_plan() {
    let src = "fn main() {\n    let arg = processArg(0)\n}\n";
    let dump = plan("owned_result_arg", src);
    assert!(
        drops(&dump) >= 1,
        "Result<Text,Int> must own its active Text:\n{dump}"
    );
    // No unchecked LIR for the owner-bearing Result.
    let output = run("owned_result_arg", src, "--emit-lir");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("error[L0016]"));
    assert!(output.stdout.is_empty());
}

#[test]
fn owned_result_from_readtext_has_drop_plan() {
    let src =
        "fn main() {\n    let path = \"content.txt\"\n    let value = readText(path, 128)\n}\n";
    let dump = plan("owned_result_readtext", src);
    // One drop for Text path; one for Result<Text,Int>, regardless of
    // whether the runtime outcome is Ok or Err.
    assert!(drops(&dump) >= 2, "path + owned result expected:\n{dump}");
    let output = run("owned_result_readtext", src, "--emit-lir");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("error[L0016]"));
    assert!(output.stdout.is_empty());
}

#[test]
fn non_owned_result_has_no_owner_drop() {
    let src = "fn main() {\n    let a: Result<Int, Int> = Ok(1)\n}\n";
    let dump = plan("dropfree_result", src);
    assert_eq!(
        drops(&dump),
        0,
        "Result<Int,Int> must stay drop-free:\n{dump}"
    );
}

#[test]
fn nested_owned_union_is_one_atomic_drop_leaf() {
    // A parameter uses a fully resolved nested type. Nested Ok inside Some
    // expression constructors need separate contextual propagation (#5),
    // so that unrelated lowering feature is deliberately not claimed here.
    let src = "fn receive(x: Option<Result<Text, Int>>) {}\nfn main() {}\n";
    let dump = plan("nested_owner", src);
    assert_eq!(
        drops(&dump),
        1,
        "nested owned union is an atomic owner:\n{dump}"
    );
    let output = run("nested_owner", src, "--emit-lir");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("error[L0016]"));
    assert!(output.stdout.is_empty());
}

#[test]
fn owned_error_variant_and_option_text_also_need_drops() {
    let cases = [
        (
            "owned_error",
            "fn main() {\n    let error: Result<Int, Text> = Err(\"problem\")\n}\n",
        ),
        ("owned_option", "fn main() {\n    let value = Some(\"ok\")\n}\n"),
    ];
    for (name, src) in cases {
        let dump = plan(name, src);
        assert_eq!(drops(&dump), 1, "{name} must drop its active owner:\n{dump}");
        let output = run(name, src, "--emit-lir");
        assert!(!output.status.success(), "{name} must not emit owner-bearing LIR");
        assert!(String::from_utf8_lossy(&output.stderr).contains("error[L0016]"));
        assert!(output.stdout.is_empty());
    }
}
