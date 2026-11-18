//! Stage 1 owned Option/Result drop classification in real .l sources.
//! Since #5 the planned drop reaches ELE-LIR as one atomic `drop` of the
//! union (its active payload only), checked by the Rust protocol validator.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
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
/// The owned union lowers to verified LIR that drops it.
fn lowered(name: &str, src: &str) {
    let output = run(name, src, "--emit-lir");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{name}: {stderr}");
    let lir = String::from_utf8(output.stdout).unwrap();
    assert!(lir.contains("i drop "), "{name}: {lir}");
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();
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
    lowered("owned_result_arg", src);
}

#[test]
fn owned_result_from_readtext_has_drop_plan() {
    let src =
        "fn main() {\n    let path = \"content.txt\"\n    let value = readText(path, 128)\n}\n";
    let dump = plan("owned_result_readtext", src);
    // One drop for Text path; one for Result<Text,Int>, regardless of
    // whether the runtime outcome is Ok or Err.
    assert!(drops(&dump) >= 2, "path + owned result expected:\n{dump}");
    lowered("owned_result_readtext", src);
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
    // A parameter uses a fully resolved nested type (nested constructors
    // are covered by stage1_owned_union_lir_l).
    let src = "fn receive(x: Option<Result<Text, Int>>) {}\nfn main() {}\n";
    let dump = plan("nested_owner", src);
    assert_eq!(
        drops(&dump),
        1,
        "nested owned union is an atomic owner:\n{dump}"
    );
    lowered("nested_owner", src);
}

#[test]
fn owned_error_variant_and_option_text_also_need_drops() {
    let cases = [
        (
            "owned_error",
            "fn main() {\n    let error: Result<Int, Text> = Err(\"problem\")\n}\n",
        ),
        (
            "owned_option",
            "fn main() {\n    let value = Some(\"ok\")\n}\n",
        ),
    ];
    for (name, src) in cases {
        let dump = plan(name, src);
        assert_eq!(
            drops(&dump),
            1,
            "{name} must drop its active owner:\n{dump}"
        );
        lowered(name, src);
    }
}
