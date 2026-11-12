mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn sema_exe_path() -> &'static Path {
    static EXE: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn run_sema_on_file(file: &Path) -> (bool, String, String) {
    let exe = sema_exe_path();
    let output = Command::new(exe)
        .arg(file)
        .output()
        .expect("failed to run sema-l");
    let success = output.status.success();
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    (success, stdout, stderr)
}

fn run_sema_on_source(case_name: &str, source: &str) -> (bool, String, String) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let temp_dir = manifest_dir.join("../../target/sema_tests").join(case_name);
    fs::create_dir_all(&temp_dir).unwrap();
    let test_file = temp_dir.join("test.l");
    fs::write(&test_file, source).unwrap();
    run_sema_on_file(&test_file)
}

#[test]
fn test_sema_positive_declarations_and_scopes() {
    let source = r#"
struct Point {
    x: Int
    y: Int
}

enum Color {
    Red
    Green
    Blue
}

fn add(a: Int, b: Int) -> Int {
    return a + b
}

fn main() -> Int {
    let p = Point(x: 10, y: 20)
    var count: Int = 0
    if count == 0 {
        let local_x = p.x
        count = add(count, local_x)
    }
    return count
}
"#;
    let (ok, stdout, stderr) = run_sema_on_source("positive_decls", source);
    assert!(ok, "Semantic analysis failed: {stderr}");
    assert!(stdout.contains("SemaSummary"));
    assert!(stdout.contains("errors=0"));
}

#[test]
fn test_sema_positive_expressions_and_arithmetic() {
    let source = r#"
fn compute(a: Int, b: Int) -> Int {
    let sum = a + b * 2 - 4 / 2
    let is_valid = (sum > 0) && (sum <= 100)
    if is_valid {
        return sum
    }
    return 0
}
"#;
    let (ok, stdout, stderr) = run_sema_on_source("positive_exprs", source);
    assert!(ok, "Semantic analysis of expressions failed: {stderr}");
    assert!(stdout.contains("errors=0"));
}

#[test]
fn test_sema_positive_ownership_valid_moves() {
    let source = r#"
struct Buffer {
    size: Int
}

fn consumeBuffer(b: Buffer) -> Int {
    return b.size
}

fn main() -> Int {
    let b1 = Buffer(size: 42)
    let res = consumeBuffer(b1)
    let b2 = Buffer(size: 100)
    let res2 = consumeBuffer(b2)
    return res + res2
}
"#;
    let (ok, stdout, stderr) = run_sema_on_source("positive_moves", source);
    assert!(ok, "Valid ownership moves failed: {stderr}");
    assert!(stdout.contains("errors=0"));
}

#[test]
fn test_sema_negative_undeclared_identifier() {
    let source = r#"
fn main() -> Int {
    let x = 10
    return x + undeclaredVariable
}
"#;
    let (ok, _stdout, stderr) = run_sema_on_source("neg_undeclared", source);
    assert!(!ok, "Should fail on undeclared identifier");
    assert!(
        stderr.contains("error[L0001]"),
        "Expected error[L0001], got: {stderr}"
    );
}

#[test]
fn test_sema_negative_duplicate_declaration() {
    let source = r#"
fn main() -> Int {
    let x = 10
    let x = 20
    return x
}
"#;
    let (ok, _stdout, stderr) = run_sema_on_source("neg_duplicate", source);
    assert!(!ok, "Should fail on duplicate variable declaration");
    assert!(
        stderr.contains("error[L0002]"),
        "Expected error[L0002], got: {stderr}"
    );
}

#[test]
fn test_sema_negative_type_mismatch_assignment() {
    let source = r#"
fn main() -> Int {
    var x: Int = 10
    x = true
    return x
}
"#;
    let (ok, _stdout, stderr) = run_sema_on_source("neg_type_mismatch", source);
    assert!(!ok, "Should fail on type mismatch in assignment");
    assert!(
        stderr.contains("error[L0003]"),
        "Expected error[L0003], got: {stderr}"
    );
}

#[test]
fn test_sema_negative_call_arity_mismatch() {
    let source = r#"
fn add(a: Int, b: Int) -> Int {
    return a + b
}

fn main() -> Int {
    return add(10)
}
"#;
    let (ok, _stdout, stderr) = run_sema_on_source("neg_arity", source);
    assert!(!ok, "Should fail on wrong argument count");
    assert!(
        stderr.contains("error[L0004]"),
        "Expected error[L0004], got: {stderr}"
    );
}

#[test]
fn test_sema_negative_call_argument_type_mismatch() {
    let source = r#"
fn add(a: Int, b: Int) -> Int {
    return a + b
}

fn main() -> Int {
    return add(10, true)
}
"#;
    let (ok, _stdout, stderr) = run_sema_on_source("neg_arg_type", source);
    assert!(!ok, "Should fail on argument type mismatch");
    assert!(
        stderr.contains("error[L0004]"),
        "Expected error[L0004], got: {stderr}"
    );
}

#[test]
fn test_sema_negative_use_after_move() {
    let source = r#"
struct Data {
    val: Int
}

fn takeData(d: Data) -> Int {
    return d.val
}

fn main() -> Int {
    let item = Data(val: 50)
    let first = takeData(item)
    let second = takeData(item)
    return first + second
}
"#;
    let (ok, _stdout, stderr) = run_sema_on_source("neg_use_after_move", source);
    assert!(!ok, "Should fail on use-after-move");
    assert!(
        stderr.contains("error[L0005]"),
        "Expected error[L0005] for use-after-move, got: {stderr}"
    );
}

#[test]
fn test_sema_negative_immutable_reassignment() {
    let source = r#"
fn main() -> Int {
    let x = 100
    x = 200
    return x
}
"#;
    let (ok, _stdout, stderr) = run_sema_on_source("neg_immutable", source);
    assert!(!ok, "Should fail on reassigning immutable let variable");
    assert!(
        stderr.contains("error[L0006]"),
        "Expected error[L0006] for immutable assignment, got: {stderr}"
    );
}

#[test]
fn test_sema_differential_parity_with_stage0() {
    let valid_source = r#"
fn square(n: Int) -> Int {
    return n * n
}

fn main() -> Int {
    let a = 5
    let res = square(a)
    return res
}
"#;
    let (sema_ok, _, _) = run_sema_on_source("diff_valid", valid_source);
    let stage0_ast = project_l::lexer::lex(valid_source).and_then(project_l::parser::parse);
    assert!(stage0_ast.is_ok());
    let stage0_check = stage0_ast.and_then(project_l::sema::check);
    assert_eq!(
        sema_ok,
        stage0_check.is_ok(),
        "Differential parity on valid program"
    );

    let invalid_source = r#"
fn main() -> Int {
    let a = 5
    let b = true
    let c = a + b
    return c
}
"#;
    let (sema_err_ok, _, _) = run_sema_on_source("diff_invalid", invalid_source);
    let stage0_ast2 = project_l::lexer::lex(invalid_source).and_then(project_l::parser::parse);
    assert!(stage0_ast2.is_ok());
    let stage0_check2 = stage0_ast2.and_then(project_l::sema::check);
    assert_eq!(
        sema_err_ok,
        stage0_check2.is_ok(),
        "Differential parity on invalid program"
    );
    assert!(!sema_err_ok);
}

#[test]
fn test_sema_memory_safety_trace_alloc() {
    let exe = stage1_support::build("main_sema", true);
    let sample = exe.with_file_name("sample.l");
    fs::write(&sample, "fn main() { let x = \"value\"; print(x) }").unwrap();
    let output = Command::new(exe).arg(sample).output().unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(output.status.success(), "{stderr}");
    stage1_support::assert_heap(&stderr);
}

fn flow_case(name: &str, source: &str, expected: Result<(), &str>) {
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/stage1-tests/cases")
        .join(format!("{name}.l"));
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, source).unwrap();
    let output = Command::new(sema_exe_path())
        .arg(&file)
        .arg("--check-ownership")
        .env("PATH", "")
        .output()
        .unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    match expected {
        Ok(()) => {
            assert_eq!(output.status.code(), Some(0), "{name}: {stderr}");
            assert!(stderr.is_empty(), "{stderr}");
            let stdout = String::from_utf8(output.stdout).unwrap();
            assert!(
                stdout.contains("blocks=") && stdout.contains("iterations="),
                "{stdout}"
            );
            project_l::check(source).unwrap_or_else(|d| panic!("{name}: {d:?}"));
        }
        Err(code) => {
            assert_eq!(output.status.code(), Some(1), "{name}: {stderr}");
            assert!(output.stdout.is_empty());
            assert!(
                stderr.contains(&format!("error[{code}]")),
                "{name}: {stderr}"
            );
            assert!(stderr.contains(&format!("{name}.l:")), "{stderr}");
            if code == "L0005" {
                let stage0 = project_l::check(source).expect_err(name);
                assert_eq!(stage0.code, code, "{name}: {stage0:?}");
            }
        }
    }
}

#[test]
fn cfg_checks_move_at_branch_joins_and_respects_early_return() {
    let prefix = "fn take(x: Text) -> Int = 1\n";
    flow_case(
        "cfg_join",
        &format!(
            "{prefix}{}",
            r#"
fn f(condition: Bool) -> Int {
    let text = "value"
    if condition { take(text); }
    return take(text)
}
fn main() {}
"#
        ),
        Err("L0005"),
    );
    flow_case(
        "cfg_return",
        &format!(
            "{prefix}{}",
            r#"
fn f(condition: Bool) -> Int {
    let text = "value"
    if condition { return take(text) }
    return take(text)
}
fn main() {}
"#
        ),
        Ok(()),
    );
    flow_case(
        "cfg_reinit",
        &format!(
            "{prefix}{}",
            r#"
fn f(condition: Bool) -> Int {
    var text = "value"
    let moved = text
    if condition { text = "left" } else { text = "right" }
    return take(text)
}
fn main() {}
"#
        ),
        Ok(()),
    );
}

#[test]
fn cfg_checks_loop_backedges_and_fresh_bindings() {
    let prefix = "fn take(x: Text) -> Int = 1\n";
    flow_case(
        "cfg_backedge",
        &format!(
            "{prefix}{}",
            r#"
fn f(condition: Bool) {
    let text = "value"
    while condition {
        take(text);
        continue
    }
}
fn main() {}
"#
        ),
        Err("L0005"),
    );
    flow_case(
        "cfg_fresh",
        &format!(
            "{prefix}{}",
            r#"
fn f(condition: Bool) {
    while condition {
        let text = "value"
        take(text);
        if condition { continue }
        break
    }
}
fn main() {}
"#
        ),
        Ok(()),
    );
}

#[test]
fn cfg_tracks_nested_fields_and_rejects_use_of_partly_moved_root() {
    let prefix = "struct Inner { text: Text, number: Int }\nstruct Outer { inner: Inner }\nfn take(x: Outer) -> Int = x.inner.number\n";
    flow_case(
        "cfg_field",
        &format!(
            "{prefix}{}",
            r#"
fn main() -> Int {
    var item = Outer(inner: Inner(text: "value", number: 3))
    let moved = item.inner.text
    let number = item.inner.number
    item.inner.text = "restored"
    return take(item) + number
}
"#
        ),
        Ok(()),
    );
    flow_case(
        "cfg_parent",
        &format!(
            "{prefix}{}",
            r#"
fn main() -> Int {
    let item = Outer(inner: Inner(text: "value", number: 3))
    let moved = item.inner.text
    return take(item)
}
"#
        ),
        Err("L0005"),
    );
}

#[test]
fn cfg_checks_borrows_and_rejects_unverified_projections() {
    flow_case("cfg_shared", "fn main() { let x = 1; let y = &x }", Ok(()));
    flow_case("cfg_mut", "fn main() { var x = 1; let y = &mut x }", Ok(()));
    flow_case(
        "cfg_escape",
        "fn f() -> &Int { let x = 1; return &x }\nfn main() {}",
        Err("L0013"),
    );
    flow_case(
        "cfg_conflict",
        "fn main() { var x = 1; let y = &x; x = 2; print(y) }",
        Err("L0012"),
    );
    flow_case(
        "cfg_index",
        "fn main() { let x = List[1]; print(x[0]) }",
        Ok(()),
    );
    flow_case(
        "cfg_missing_return",
        "fn f(condition: Bool) -> Text { if condition { return \"x\" } }\nfn main() {}",
        Err("L0003"),
    );
}

#[test]
fn stage1_checks_collection_indices_and_method_signatures() {
    flow_case(
        "index_wrong_type",
        "fn main() { let xs = List[1]; print(xs[true]) }",
        Err("L0003"),
    );
    flow_case(
        "push_wrong_element",
        "fn main() { var xs = List[1]; xs.push(\"text\") }",
        Err("L0003"),
    );
    flow_case(
        "push_immutable_receiver",
        "fn main() { let xs = List[1]; xs.push(2) }",
        Err("L0006"),
    );
    flow_case(
        "pop_wrong_arity",
        "fn main() { var xs = List[1]; xs.pop(1) }",
        Err("L0003"),
    );
    flow_case(
        "reserve_wrong_type",
        "fn main() { var xs = List[1]; xs.reserve(\"text\") }",
        Err("L0003"),
    );
    flow_case(
        "byte_at_wrong_type",
        "fn main() { let text = \"hi\"; print(text.byteAt(true)) }",
        Err("L0003"),
    );
}

#[test]
fn stage1_negative_constants_require_minus() {
    flow_case(
        "negative_constant",
        "const MINUS_FIVE = -5\nfn main() -> Int { return MINUS_FIVE }",
        Ok(()),
    );
    flow_case(
        "invalid_unary_constant",
        "const BAD = !1\nfn main() {}",
        Err("L0016"),
    );
}

#[test]
fn cfg_checks_large_functions_and_reports_analysis_limit() {
    use std::fmt::Write as _;
    let mut source = String::from("fn main() -> Int {\n");
    for i in 0..1_000 {
        writeln!(source, "let n{i} = {i}").unwrap();
    }
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/stage1-tests/cases/cfg_large.l");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, format!("{source}return n999\n}}")).unwrap();
    let exe = sema_exe_path();
    let output = Command::new(exe).arg(&file).output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("paths=1000"));
    for _ in 0..700 {
        source.push_str("if true {}\n");
    }
    source.push_str("return n999\n}");
    fs::write(&file, source).unwrap();
    let output = Command::new(exe).arg(file).output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("límite del análisis de flujo excedido")
    );
}

#[test]
fn stage1_resolves_list_type_annotations() {
    flow_case(
        "list_annotations",
        "struct Arena { items: List<Int>, names: List<Text> }\nfn total(l: List<Int>) -> Int = 1\nfn main() {\n let a: List<Int> = List[1, 2]\n let n = List[\"x\"]\n let ar = Arena(items: a, names: n)\n print(total(ar.items))\n}",
        Ok(()),
    );
    flow_case(
        "list_annotation_mismatch",
        "fn main() { let a: List<Text> = List[1] }",
        Err("L0003"),
    );
    flow_case(
        "other_generic_arguments",
        "struct Box { v: Int }\nfn main() { let b: Box<Int> = Box(v: 1) }",
        Err("L0016"),
    );
}

#[test]
fn exhaustive_builtin_match_returns_on_all_paths() {
    flow_case(
        "exhaustive_result_return",
        r#"
fn readValue(input: Result<Int, Int>) -> Int {
    match input {
        Ok(value) => { return value }
        Err(reason) => { return reason }
    }
}
fn main() {}
"#,
        Ok(()),
    );
    flow_case(
        "exhaustive_option_return",
        r#"
fn readOrDefault(input: Option<Int>) -> Int {
    match input {
        Some(value) => { return value }
        None => { return 0 }
    }
}
fn main() {}
"#,
        Ok(()),
    );
}

#[test]
fn incomplete_or_duplicate_builtin_matches_cannot_satisfy_return_analysis() {
    flow_case(
        "incomplete_result_return",
        r#"
fn readValue(input: Result<Int, Int>) -> Int {
    match input {
        Ok(value) => { return value }
    }
}
fn main() {}
"#,
        Err("L0003"),
    );
    flow_case(
        "duplicate_result_return",
        r#"
fn readValue(input: Result<Int, Int>) -> Int {
    match input {
        Ok(value) => { return value }
        Ok(again) => { return again }
    }
}
fn main() {}
"#,
        Err("L0003"),
    );
    flow_case(
        "incomplete_option_return",
        r#"
fn readValue(input: Option<Int>) -> Int {
    match input {
        Some(value) => { return value }
    }
}
fn main() {}
"#,
        Err("L0003"),
    );
}

#[test]
fn actual_lexer_scan_has_no_reachable_missing_return() {
    // This checks the real compiler source including Result/Option matches,
    // not a reduced fixture. It is not evidence of native LIR support.
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../compiler-l/src/lexer.l");
    let output = Command::new(sema_exe_path())
        .arg(&source)
        .arg("--check-ownership")
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(0),
        "real lexer.l ownership: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}
