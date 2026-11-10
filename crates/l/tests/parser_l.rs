mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn parser_exe_path() -> &'static Path {
    static EXE: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_parser", false))
}

fn run_parser_on_file(file: &Path) -> (bool, String, String) {
    let exe = parser_exe_path();
    let output = Command::new(exe)
        .arg(file)
        .output()
        .expect("failed to run parser-l");
    let success = output.status.success();
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    (success, stdout, stderr)
}

fn run_parser_on_source(case_name: &str, source: &str) -> (bool, String, String) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let temp_dir = manifest_dir
        .join("../../target/parser_tests")
        .join(case_name);
    fs::create_dir_all(&temp_dir).unwrap();
    let test_file = temp_dir.join("test.l");
    fs::write(&test_file, source).unwrap();
    run_parser_on_file(&test_file)
}

#[test]
fn stage1_rejects_integer_literal_overflow_without_panicking() {
    let (ok, _, stderr) =
        run_parser_on_source("int_overflow", "fn main() { let n = 9223372036854775808 }");
    assert!(!ok);
    assert!(stderr.contains("error[PARSER]"), "{stderr}");
    let (ok, _, stderr) =
        run_parser_on_source("int_max", "fn main() { let n = 9223372036854775807 }");
    assert!(ok, "{stderr}");
}

#[test]
fn test_parse_top_level_declarations() {
    let source = r#"
import std.io
import std.math.matrix

pub const MAX_SIZE: Int = 1024

struct Point {
    x: Int
    y: Int
    pub label: Text
}

enum Color {
    Red
    Green
    Blue
    Rgb(Int, Int, Int)
}

fn add(a: Int, b: Int) -> Int {
    return a + b
}

pub async fn fetchData(url: Text) -> Text {
    return "response"
}
"#;
    let (ok, stdout, stderr) = run_parser_on_source("decls", source);
    assert!(ok, "Parsing declarations failed: {stderr}");
    assert!(stdout.contains("AstSummary decls=7"));
    assert!(stdout.contains("errors=0"));
    assert!(stdout.contains("Decl::Import"));
    assert!(stdout.contains("Decl::Const"));
    assert!(stdout.contains("Decl::Struct"));
    assert!(stdout.contains("Decl::Enum"));
    assert!(stdout.contains("Decl::Function"));
}

#[test]
fn test_parse_complex_expressions_and_precedence() {
    let source = r#"
fn main() {
    let a = 1 + 2 * 3 - 4 / 2
    let b = (a > 0) && (a <= 10) || !(a == 5)
    let p = Point(x: 10, y: 20)
    let dist = p.x * p.x + p.y * p.y
    let list = List[1, 2, 3]
    let first = list[0]
}
"#;
    let (ok, stdout, stderr) = run_parser_on_source("exprs", source);
    assert!(ok, "Parsing expressions failed: {stderr}");
    assert!(stdout.contains("errors=0"));
    assert!(stdout.contains("AstSummary decls=1"));
}

#[test]
fn test_parse_control_flow_and_blocks() {
    let source = r#"
fn main() {
    var count = 0
    if count == 0 {
        count = 1
    } else if count == 1 {
        count = 2
    } else {
        count = 3
    }

    while count > 0 {
        count -= 1
        if count == 5 {
            break
        } else {
            continue
        }
    }

    loop {
        break
    }

    region r {
        let x = 42
    }
}
"#;
    let (ok, stdout, stderr) = run_parser_on_source("control_flow", source);
    assert!(ok, "Parsing control flow failed: {stderr}");
    assert!(stdout.contains("errors=0"));
    assert!(stdout.contains("AstSummary decls=1"));
}

#[test]
fn test_parse_pattern_matching_statement() {
    let source = r#"
enum Status {
    Ok
    Err(Int)
}

fn handle(status: Status) -> Int {
    match status {
        Status.Ok => { return 0 }
        Status.Err(code) => { return code }
        _ => { return -1 }
    }
}
"#;
    let (ok, stdout, stderr) = run_parser_on_source("match_stmt", source);
    assert!(ok, "Parsing pattern match failed: {stderr}");
    assert!(stdout.contains("errors=0"));
    assert!(stdout.contains("AstSummary decls=2"));
}

#[test]
fn test_parse_all_compiler_sources_self_hosting() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let src_dir = manifest_dir.join("../../compiler-l/src");
    let files = [
        "ast.l",
        "cursor.l",
        "decl.l",
        "expr.l",
        "lexer.l",
        "main.l",
        "main_parser.l",
        "main_sema.l",
        "ownership_l.l",
        "parser.l",
        "parse_util.l",
        "scopes.l",
        "sema.l",
        "sema_context.l",
        "sema_expr.l",
        "sema_stmt.l",
        "sema_types.l",
        "stmt.l",
        "symbols.l",
        "tokens.l",
        "types.l",
    ];

    for file_name in files {
        let path = src_dir.join(file_name);
        assert!(
            path.exists(),
            "Source file does not exist: {}",
            path.display()
        );
        let (ok, stdout, stderr) = run_parser_on_file(&path);
        assert!(
            ok,
            "Self-hosted parser failed on {}: {}\n{}",
            file_name, stderr, stdout
        );
        assert!(
            stdout.contains("errors=0"),
            "Parsing {} reported errors:\n{}",
            file_name,
            stdout
        );
    }
}

#[test]
fn test_parse_error_diagnostics_and_recovery() {
    let source = r#"
fn bad(a: Int {
    let x = ;
}
"#;
    let (ok, _stdout, stderr) = run_parser_on_source("bad_syntax", source);
    assert!(!ok, "Parser should fail on malformed syntax");
    assert!(
        stderr.contains("error[PARSER]"),
        "Diagnostic should contain error[PARSER]: {stderr}"
    );
}

#[test]
fn test_parser_memory_safety_trace_alloc() {
    let exe = stage1_support::build("main_parser", true);
    let sample = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../compiler-l/src/tokens.l");
    let output = Command::new(exe).arg(sample).output().unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(output.status.success(), "{stderr}");
    stage1_support::assert_heap(&stderr);
}

#[test]
fn test_differential_ast_with_stage0() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = manifest_dir.parent().unwrap().parent().unwrap();
    let target_file = root.join("compiler-l/src/tokens.l");

    // Run Stage 0 parser
    let stage0_tokens = project_l::lexer::lex(&fs::read_to_string(&target_file).unwrap()).unwrap();
    let stage0_prog = project_l::parser::parse(stage0_tokens).unwrap();

    // Run parser-l
    let (ok, stdout, stderr) = run_parser_on_file(&target_file);
    assert!(ok, "parser-l failed on tokens.l: {stderr}");

    // Compare top-level function count
    let stage0_fn_count = stage0_prog.functions.len();
    assert!(
        stdout.contains(&format!("AstSummary decls={stage0_fn_count}")),
        "Decl count mismatch between Stage 0 ({stage0_fn_count}) and parser-l output:\n{stdout}"
    );
}
