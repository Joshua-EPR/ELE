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
    assert_eq!(build.code, Some(0), "{name}: {}{}", build.stdout, build.stderr);
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
    assert!(lir.stdout.starts_with("ELE-LIR 1\n"), "{name}: {}", lir.stdout);
    let (_, one) = build_and_run_lir(name, &lir.stdout);
    let zero = run_stage0(name, entry, files);
    assert_eq!(one.code, zero.code, "{name}: exit code");
    assert_eq!(one.stdout, zero.stdout, "{name}: stdout");
    assert_eq!(program_stderr(&one.stderr), program_stderr(&zero.stderr), "{name}: stderr");
}

#[test]
fn two_modules_resolve_and_run_natively() {
    compare_multi(
        "two_modules",
        "main.l",
        &[
            ("lib.l", "pub fn double(x: Int) -> Int { return x * 2 }\n"),
            ("main.l", "import lib\nfn main() -> Int { return double(21) }\n"),
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
            ("b.l", "import c\npub fn six() -> Int { return three() * 2 }\n"),
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
                "pub struct Point { x: Int y: Int }\npub fn origin() -> Point { return Point(x: 40, y: 2) }\n",
            ),
            ("main.l", "import lib\nfn main() -> Int { let p = origin(); return p.x + p.y }\n"),
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
            ("a.l", "import common\npub fn left() -> Int { return answer() }\n"),
            ("b.l", "import common\npub fn right() -> Int { return answer() }\n"),
            ("main.l", "import a\nimport b\nfn main() -> Int { return left() + right() }\n"),
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
            ("lib.l", "pub fn origin() -> Point { return Point(x: 42) }\npub struct Point { x: Int }\n"),
            ("main.l", "import lib\nfn main() -> Int { let p = origin(); return p.x }\n"),
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
            ("main.l", "import a\nimport b\nfn make(x: Item) -> Int { return 0 }\nfn main() -> Int { return 0 }\n"),
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
            ("main.l", "import a\nimport b\nfn main() -> Int { return call() }\n"),
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
            ("main.l", "import a\nimport b\nfn main() -> Int { return clash() }\n"),
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
            ("main.l", "import lib\nfn main() -> Int { return secret() }\n"),
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
    compare_multi(
        "same_name_private",
        "main.l",
        &[
            ("a.l", "fn helper() -> Int { return 1 }\npub fn from_a() -> Int { return helper() }\n"),
            ("b.l", "fn helper() -> Int { return 41 }\npub fn from_b() -> Int { return helper() }\n"),
            ("main.l", "import a\nimport b\nfn main() -> Int { return from_a() + from_b() }\n"),
        ],
    );
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
