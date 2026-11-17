//! Stage 1 semantic modules: real imports (identity, visibility, transitive
//! dependencies, per-file diagnostics) from `main_sema.l`, compared with the
//! Stage 0 module loader for supported cases. The front end runs entirely in
//! the Stage 1 binary; Stage 0 is only a differential oracle.

mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn sema_exe() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn case_dir(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/stage1-tests/modules")
        .join(name);
    fs::create_dir_all(&dir).unwrap();
    dir
}

struct Output {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

fn exec(cmd: &mut Command) -> Output {
    let o = cmd.output().unwrap();
    Output {
        code: o.status.code(),
        stdout: String::from_utf8_lossy(&o.stdout).to_string(),
        stderr: String::from_utf8_lossy(&o.stderr).to_string(),
    }
}

/// Writes the given files (name -> contents) into a fresh case directory and
/// runs Stage 1 (`sema-l entry --emit-lir`) with an empty PATH.
fn emit_lir_multi(name: &str, entry: &str, files: &[(&str, &str)]) -> Output {
    let dir = case_dir(name);
    for (fname, content) in files {
        fs::write(dir.join(fname), content).unwrap();
    }
    exec(
        Command::new(sema_exe())
            .arg(dir.join(entry))
            .arg("--emit-lir")
            .env("PATH", ""),
    )
}

fn program_stderr(stderr: &str) -> String {
    stderr
        .lines()
        .filter(|l| !l.starts_with("l-alloc: "))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Provisional backend: LIR -> executable, then run it.
fn build_and_run_lir(name: &str, lir: &str) -> (Output, Output) {
    let dir = case_dir(name);
    let file = dir.join(format!("{name}.lir"));
    fs::write(&file, lir).unwrap();
    let build = exec(
        Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(&dir)
            .args(["build-lir"])
            .arg(&file)
            .arg("--trace-alloc"),
    );
    assert_eq!(
        build.code,
        Some(0),
        "{name}: {}{}",
        build.stdout,
        build.stderr
    );
    let exe = dir.join(
        build
            .stdout
            .lines()
            .find_map(|l| l.strip_prefix("Build: "))
            .unwrap(),
    );
    (build, exec(&mut Command::new(exe)))
}

/// Stage 0 reference for the same multi-file program.
fn run_stage0(name: &str, entry: &str, files: &[(&str, &str)]) -> Output {
    let dir = case_dir(&format!("{name}-stage0"));
    for (fname, content) in files {
        fs::write(dir.join(fname), content).unwrap();
    }
    let build = exec(
        Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(&dir)
            .args(["build"])
            .arg(dir.join(entry))
            .args(["--backend", "cranelift", "--trace-alloc"]),
    );
    assert_eq!(build.code, Some(0), "{name} stage0: {}", build.stderr);
    let exe = dir.join(
        build
            .stdout
            .lines()
            .find_map(|l| l.strip_prefix("Build: "))
            .unwrap(),
    );
    exec(&mut Command::new(exe))
}

fn compare_multi(name: &str, entry: &str, files: &[(&str, &str)]) {
    let lir = emit_lir_multi(name, entry, files);
    assert_eq!(lir.code, Some(0), "{name}: {}", lir.stderr);
    assert!(
        lir.stdout.starts_with("ELE-LIR 1\n"),
        "{name}: {}",
        lir.stdout
    );
    let (_, one) = build_and_run_lir(name, &lir.stdout);
    let zero = run_stage0(name, entry, files);
    assert_eq!(one.code, zero.code, "{name}: exit code");
    assert_eq!(one.stdout, zero.stdout, "{name}: stdout");
    assert_eq!(
        program_stderr(&one.stderr),
        program_stderr(&zero.stderr),
        "{name}: stderr"
    );
}

#[test]
fn two_modules_resolve_and_run_natively() {
    compare_multi(
        "two_modules",
        "main.l",
        &[
            ("lib.l", "pub fn double(x: Int) -> Int { return x * 2 }\n"),
            (
                "main.l",
                "import lib\nfn main() -> Int { return double(21) }\n",
            ),
        ],
    );
}

#[test]
fn transitive_imports_resolve_in_dependency_order() {
    compare_multi(
        "transitive",
        "a.l",
        &[
            ("c.l", "pub fn three() -> Int { return 3 }\n"),
            (
                "b.l",
                "import c\npub fn six() -> Int { return three() * 2 }\n",
            ),
            ("a.l", "import b\nfn main() -> Int { return six() * 7 }\n"),
        ],
    );
}

#[test]
fn cross_module_types_keep_nominal_identity() {
    compare_multi(
        "cross_module_type",
        "main.l",
        &[
            (
                "lib.l",
                "pub struct Point { x: Int, y: Int }\npub fn origin() -> Point { return Point(x: 40, y: 2) }\n",
            ),
            (
                "main.l",
                "import lib\nfn main() -> Int { let p = origin(); return p.x + p.y }\n",
            ),
        ],
    );
}

#[test]
fn transitive_diamond_imports_deduplicate_and_resolve() {
    compare_multi(
        "diamond",
        "main.l",
        &[
            ("common.l", "pub fn answer() -> Int { return 42 }\n"),
            (
                "a.l",
                "import common\npub fn left() -> Int { return answer() }\n",
            ),
            (
                "b.l",
                "import common\npub fn right() -> Int { return answer() }\n",
            ),
            (
                "main.l",
                "import a\nimport b\nfn main() -> Int { return left() + right() }\n",
            ),
        ],
    );
}

#[test]
fn imported_function_can_reference_a_type_declared_later() {
    // Nominal declarations must be registered before function signatures.
    compare_multi(
        "forward_type",
        "main.l",
        &[
            (
                "lib.l",
                "pub fn origin() -> Point { return Point(x: 42) }\npub struct Point { x: Int }\n",
            ),
            (
                "main.l",
                "import lib\nfn main() -> Int { let p = origin(); return p.x }\n",
            ),
        ],
    );
}

#[test]
fn imported_public_types_with_same_name_are_ambiguous() {
    let out = emit_lir_multi(
        "ambiguous_type",
        "main.l",
        &[
            ("a.l", "pub struct Item { x: Int }\n"),
            ("b.l", "pub struct Item { y: Int }\n"),
            (
                "main.l",
                "import a\nimport b\nfn make(x: Item) -> Int { return 0 }\nfn main() -> Int { return 0 }\n",
            ),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(out.stderr.contains("main.l:"), "{}", out.stderr);
    assert!(out.stderr.contains("error[L0014]"), "{}", out.stderr);
}

#[test]
fn unrelated_sibling_public_symbol_is_not_implicitly_imported() {
    // b is loaded because main imports it; a must not see b's exports
    // unless a explicitly imports b itself.
    let out = emit_lir_multi(
        "sibling_isolation",
        "main.l",
        &[
            ("a.l", "pub fn call() -> Int { return hidden_from_a() }\n"),
            ("b.l", "pub fn hidden_from_a() -> Int { return 42 }\n"),
            (
                "main.l",
                "import a\nimport b\nfn main() -> Int { return call() }\n",
            ),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(out.stderr.contains("a.l:"), "{}", out.stderr);
    assert!(out.stderr.contains("error[L0001]"), "{}", out.stderr);
}

#[test]
fn two_public_imports_with_the_same_name_are_ambiguous() {
    let out = emit_lir_multi(
        "ambiguous_public",
        "main.l",
        &[
            ("a.l", "pub fn clash() -> Int { return 1 }\n"),
            ("b.l", "pub fn clash() -> Int { return 2 }\n"),
            (
                "main.l",
                "import a\nimport b\nfn main() -> Int { return clash() }\n",
            ),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(out.stderr.contains("main.l:"), "{}", out.stderr);
    assert!(out.stderr.contains("error[L0014]"), "{}", out.stderr);
}

#[test]
fn private_symbols_are_not_visible_across_modules() {
    let out = emit_lir_multi(
        "private_access",
        "main.l",
        &[
            ("lib.l", "fn secret() -> Int { return 1 }\n"),
            (
                "main.l",
                "import lib\nfn main() -> Int { return secret() }\n",
            ),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(
        out.stderr.contains("error[L0001]") && !out.stderr.contains("error[ICE]"),
        "{}",
        out.stderr
    );
    // The diagnostic must point at the importing file, not the dependency.
    assert!(out.stderr.contains("main.l:"), "{}", out.stderr);
}

#[test]
fn same_name_private_symbols_do_not_collide() {
    // Two modules each declare a private helper; both remain usable within
    // their own module and are not confused with each other.
    // Stage 0 uses a single global namespace and currently rejects
    // duplicate private names in distinct modules. This test specifically
    // proves Stage 1's module scoping with a real LIR build and execution,
    // rather than asserting unsupported behavior of the Stage 0 oracle.
    let lir = emit_lir_multi(
        "same_name_private",
        "main.l",
        &[
            (
                "a.l",
                "fn helper() -> Int { return 1 }\npub fn from_a() -> Int { return helper() }\n",
            ),
            (
                "b.l",
                "fn helper() -> Int { return 41 }\npub fn from_b() -> Int { return helper() }\n",
            ),
            (
                "main.l",
                "import a\nimport b\nfn main() -> Int { return from_a() + from_b() }\n",
            ),
        ],
    );
    assert_eq!(lir.code, Some(0), "{}", lir.stderr);
    assert!(lir.stdout.starts_with("ELE-LIR 1\n"));
    let (_, run) = build_and_run_lir("same_name_private", &lir.stdout);
    assert_eq!(run.code, Some(42), "{}", run.stderr);
    assert_eq!(run.stdout, "");
    assert_eq!(program_stderr(&run.stderr), "");
}

#[test]
fn missing_import_is_a_diagnostic_not_a_crash() {
    let out = emit_lir_multi(
        "missing_import",
        "main.l",
        &[("main.l", "import nope\nfn main() -> Int { return 0 }\n")],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(!out.stderr.contains("error[ICE]"), "{}", out.stderr);
}

#[test]
fn import_cycles_are_rejected() {
    let out = emit_lir_multi(
        "import_cycle",
        "a.l",
        &[
            ("a.l", "import b\nfn main() -> Int { return 0 }\n"),
            ("b.l", "import a\nfn helper() -> Int { return 1 }\n"),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(out.stderr.contains("L0014"), "{}", out.stderr);
}

#[test]
fn dependency_type_errors_are_attributed_to_the_dependency() {
    let out = emit_lir_multi(
        "dependency_type_error",
        "main.l",
        &[
            // `add` expects Int but its body returns Bool.
            ("lib.l", "pub fn add(x: Int) -> Int { return true }\n"),
            ("main.l", "import lib\nfn main() -> Int { return add(1) }\n"),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(out.stderr.contains("lib.l:"), "{}", out.stderr);
}

// A graph traversal must work independently of dependency numbering. The
// production loader currently assigns lower IDs to dependencies, but the
// visibility algorithm must also terminate safely on cyclic and malformed
// adjacency lists, without granting permissions to unrelated modules.
#[test]
fn module_graph_out_of_order_and_invalid_edges_are_bounded() {
    let graph = fs::read_to_string(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../compiler-l/src/module_graph_l.l"),
    )
    .unwrap();
    // The real ELE module-graph implementation is compiled unchanged, then
    // called from a main in the same source module. No fake graph routine.
    let main = r#"
fn main() -> Int {
    var first: List<Int> = List[]
    first.push(0)
    first.push(2)
    first.push(3)
    first.push(4)
    first.push(5)
    var counts: List<Int> = List[]
    counts.push(2)
    counts.push(1)
    counts.push(1)
    counts.push(1)
    counts.push(0)
    var deps: List<Int> = List[]
    deps.push(2)
    deps.push(999)
    deps.push(0)
    deps.push(3)
    deps.push(1)
    let access = moduleAccessBuild(5, &first, &counts, &deps)
    if access.length != 25 { return 1 }
    // 0 -> 2 -> 3 -> 1 -> 0, despite reverse-numbered edges.
    for src in 0..4 {
        for dst in 0..4 {
            if access[src * 5 + dst] != 1 { return 2 }
        }
        if access[src * 5 + 4] != 0 { return 3 }
    }
    // Module 4 is not imported by the cycle, nor does it import the cycle.
    for dst in 0..4 {
        if access[4 * 5 + dst] != 0 { return 4 }
    }
    if access[4 * 5 + 4] != 1 { return 5 }
    // A corrupted count crossing into module 1's adjacency slice must not
    // grant module 0 access to any dependencies.
    counts[0] = 3
    let invalid = moduleAccessBuild(5, &first, &counts, &deps)
    if invalid[0 * 5 + 2] != 0 { return 6 }
    if invalid[0 * 5 + 0] != 1 { return 7 }
    return 42
}
"#;
    let source = format!("{graph}\n{main}");
    let stage0 = run_stage0(
        "graph_out_of_order_stage0",
        "main.l",
        &[("main.l", &source)],
    );
    assert_eq!(stage0.code, Some(42), "{}{}", stage0.stdout, stage0.stderr);
    let stage1 = check_modules_with_stage1("graph_out_of_order_stage1", &[("main.l", &source)]);
    assert_eq!(stage1.code, Some(0), "{}", stage1.stderr);
}

#[test]
fn two_distinct_public_names_reachable_only_transitively_are_ambiguous() {
    let out = emit_lir_multi(
        "transitive_ambiguous",
        "main.l",
        &[
            ("a.l", "pub fn clash() -> Int { return 1 }\n"),
            ("b.l", "pub fn clash() -> Int { return 2 }\n"),
            ("left.l", "import a\npub fn left() -> Int { return 0 }\n"),
            ("right.l", "import b\npub fn right() -> Int { return 0 }\n"),
            (
                "main.l",
                "import left\nimport right\nfn main() -> Int { return clash() }\n",
            ),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(out.stderr.contains("main.l:"), "{}", out.stderr);
    assert!(out.stderr.contains("error[L0014]"), "{}", out.stderr);
    assert!(!out.stderr.contains("error[ICE]"), "{}", out.stderr);
}

#[test]
fn diamond_imports_do_not_duplicate_the_same_public_symbol() {
    // Stage 0 requires a direct import for unqualified public calls.
    // Explicitly importing common does not load it a second time even
    // though left and right also import it through the diamond.
    compare_multi(
        "diamond_direct_export",
        "main.l",
        &[
            ("common.l", "pub fn answer() -> Int { return 42 }\n"),
            (
                "left.l",
                "import common\npub fn left() -> Int { return 1 }\n",
            ),
            (
                "right.l",
                "import common\npub fn right() -> Int { return 2 }\n",
            ),
            (
                "main.l",
                "import left\nimport right\nimport common\nfn main() -> Int { return answer() }\n",
            ),
        ],
    );
}

#[test]
fn private_name_in_transitive_dependency_is_not_exported() {
    let out = emit_lir_multi(
        "transitive_private",
        "main.l",
        &[
            ("secret.l", "fn secret() -> Int { return 42 }\n"),
            (
                "mid.l",
                "import secret\npub fn middle() -> Int { return 1 }\n",
            ),
            (
                "main.l",
                "import mid\nfn main() -> Int { return secret() }\n",
            ),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(out.stderr.contains("main.l:"), "{}", out.stderr);
    assert!(out.stderr.contains("error[L0001]"), "{}", out.stderr);
}

// Regression for the actual lexer -> tokens/cursor dependency boundary.
// The Stage 1 loader must not treat a symbol imported by main as implicitly
// accessible inside a sibling source.
fn check_modules_with_stage1(name: &str, files: &[(&str, &str)]) -> Output {
    let dir = case_dir(name);
    for (file, content) in files {
        fs::write(dir.join(file), content).unwrap();
    }
    exec(
        Command::new(sema_exe())
            .arg(dir.join("main.l"))
            .arg("--check-ownership")
            .env("PATH", ""),
    )
}

#[test]
fn public_lexer_nominal_types_resolve_in_token_module() {
    let lexer =
        "pub enum LexKind {\n Word\n Eof\n}\npub struct LexToken { kind: LexKind, start: Int }\n";
    let out = check_modules_with_stage1(
        "public_lexer_nominals",
        &[
            ("lexer.l", lexer),
            (
                "tokens.l",
                "import lexer\npub fn tokenStart(t: &LexToken) -> Int { return t.start }\n",
            ),
            (
                "main.l",
                "import lexer\nimport tokens\nfn main() -> Int { return 0 }\n",
            ),
        ],
    );
    assert_eq!(out.code, Some(0), "{}", out.stderr);
    assert!(out.stderr.is_empty(), "{}", out.stderr);
}

#[test]
fn sibling_import_does_not_make_lexer_type_visible_to_tokens() {
    let lexer =
        "pub enum LexKind {\n Word\n Eof\n}\npub struct LexToken { kind: LexKind, start: Int }\n";
    let out = check_modules_with_stage1(
        "missing_lexer_import_in_tokens",
        &[
            ("lexer.l", lexer),
            (
                "tokens.l",
                "pub fn tokenStart(t: &LexToken) -> Int { return t.start }\n",
            ),
            (
                "main.l",
                "import lexer\nimport tokens\nfn main() -> Int { return 0 }\n",
            ),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(out.stderr.contains("tokens.l:"), "{}", out.stderr);
    assert!(out.stderr.contains("error[L0001]"), "{}", out.stderr);
}

// Imported public nominal types must be available while checking signatures
// of dependency modules, not merely in the final entry module's namespace.
#[test]
fn chained_imports_resolve_public_nominal_in_intermediate_signature() {
    let out = check_modules_with_stage1(
        "chained_public_nominal",
        &[
            ("ast.l", "pub struct Node { value: Int }\n"),
            (
                "parser.l",
                "import ast\npub fn nodeValue(node: &Node) -> Int { return node.value }\n",
            ),
            ("main.l", "import parser\nfn main() -> Int { return 0 }\n"),
        ],
    );
    assert_eq!(out.code, Some(0), "{}", out.stderr);
    assert!(out.stderr.is_empty(), "{}", out.stderr);
}

#[test]
fn private_nominal_is_not_usable_in_importing_module_signature() {
    let out = check_modules_with_stage1(
        "chained_private_nominal",
        &[
            ("ast.l", "struct Node { value: Int }\n"),
            (
                "parser.l",
                "import ast\npub fn nodeValue(node: &Node) -> Int { return node.value }\n",
            ),
            ("main.l", "import parser\nfn main() -> Int { return 0 }\n"),
        ],
    );
    assert_eq!(out.code, Some(1), "{}", out.stderr);
    assert!(out.stderr.contains("parser.l:"), "{}", out.stderr);
    assert!(out.stderr.contains("error[L0001]"), "{}", out.stderr);
}

const STAGE1_IMPORT_DEPTH_LIMIT: usize = 128;

fn stage1_import_chain_fixture(name: &str, depth: usize) -> PathBuf {
    let dir = case_dir(name);
    for index in 0..depth {
        let filename = if index == 0 {
            "main.l".to_owned()
        } else {
            format!("m{index:03}.l")
        };
        let mut source = String::new();
        if index + 1 < depth {
            source.push_str(&format!("take m{:03}\n", index + 1));
        }
        if index == 0 {
            source.push_str("flow main() => Int { give 0 }\n");
        } else {
            source.push_str(&format!("flow unused{index:03}() => Int {{ give 0 }}\n"));
        }
        fs::write(dir.join(filename), source).unwrap();
    }
    dir
}

fn check_stage1_directory(dir: &Path) -> Output {
    exec(
        Command::new(sema_exe())
            .arg(dir.join("main.l"))
            .arg("--check-ownership")
            .env("PATH", ""),
    )
}

#[test]
fn stage1_accepts_import_chain_at_depth_limit() {
    let dir =
        stage1_import_chain_fixture("stage1_import_depth_at_limit", STAGE1_IMPORT_DEPTH_LIMIT);
    let result = check_stage1_directory(&dir);
    assert_eq!(result.code, Some(0), "{}", result.stderr);
    assert!(!result.stderr.contains("error[L0014]"), "{}", result.stderr);
}

#[test]
fn stage1_rejects_import_chain_over_depth_limit_with_l0014() {
    let dir = stage1_import_chain_fixture(
        "stage1_import_depth_above_limit",
        STAGE1_IMPORT_DEPTH_LIMIT + 1,
    );
    let stage1 = check_stage1_directory(&dir);
    assert_eq!(stage1.code, Some(1), "{}", stage1.stderr);
    assert!(stage1.stderr.contains("error[L0014]"), "{}", stage1.stderr);
    assert!(
        stage1
            .stderr
            .contains("profundidad de imports excede el límite de 128 módulos"),
        "{}",
        stage1.stderr
    );
    assert!(!stage1.stderr.contains("error[ICE]"), "{}", stage1.stderr);

    // Stage 0 and Stage 1 must reject the same acyclic import chain.
    let stage0 = exec(
        Command::new(env!("CARGO_BIN_EXE_l"))
            .arg("check")
            .arg(dir.join("main.l")),
    );
    assert_ne!(stage0.code, Some(0), "{}", stage0.stderr);
    assert!(stage0.stderr.contains("L0014"), "{}", stage0.stderr);
}

#[test]
fn stage1_accepts_wide_graph_with_more_than_128_modules() {
    // Depth=2, width>128: avoid imposing a total-file limit.
    let dir = case_dir("stage1_import_depth_wide_graph");
    let mut source = String::new();
    for index in 0..(STAGE1_IMPORT_DEPTH_LIMIT + 8) {
        let name = format!("m{index:03}");
        fs::write(
            dir.join(format!("{name}.l")),
            format!("flow unused{index:03}() => Int {{ give 0 }}\n"),
        )
        .unwrap();
        source.push_str(&format!("take {name}\n"));
    }
    source.push_str("flow main() => Int { give 0 }\n");
    fs::write(dir.join("main.l"), source).unwrap();

    let result = check_stage1_directory(&dir);
    assert_eq!(result.code, Some(0), "{}", result.stderr);
    assert!(!result.stderr.contains("error[L0014]"), "{}", result.stderr);
}

#[test]
fn public_borrow_site_constants_are_imported_without_exposing_private_constants() {
    // The real Stage 1 sema_context declares SITE_* values as constants.
    // Sibling semantic modules must import their exported values, but an
    // unrelated private constant must remain inaccessible.
    let shared = (
        "positions.l",
        "pub const SITE_NONE = 0\npub const SITE_ARG = 3\nconst PRIVATE_SITE = 9\n",
    );
    let valid = check_modules_with_stage1(
        "stage1_b1_public_site_constants",
        &[
            shared,
            (
                "main.l",
                "take positions\nflow main() => Int { give SITE_ARG + SITE_NONE }\n",
            ),
        ],
    );
    assert_eq!(valid.code, Some(0), "{}", valid.stderr);
    assert!(!valid.stderr.contains("error["), "{}", valid.stderr);

    let private = check_modules_with_stage1(
        "stage1_b1_private_site_constant",
        &[
            shared,
            (
                "main.l",
                "take positions\nflow main() => Int { give PRIVATE_SITE }\n",
            ),
        ],
    );
    assert_eq!(private.code, Some(1), "{}", private.stderr);
    assert!(private.stderr.contains("main.l:"), "{}", private.stderr);
    assert!(private.stderr.contains("error[L0001]"), "{}", private.stderr);
}
