//! B2 regression: the real Stage 1 semantic/LIR helper modules must no
//! longer lend their context exclusively while evaluating a second argument.
//! These are genuine .l source files, compiled to the Stage 1 checker by
//! Stage 0 for this integration test. The checker itself remains written in ELE.
//! No loan, ownership, drop or LIR verification rule is weakened.
mod stage1_support;

use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn check(path: &Path) -> (bool, String) {
    let output = Command::new(sema())
        .arg(path)
        .arg("--check-ownership")
        .env("PATH", "")
        .output()
        .unwrap();
    (
        output.status.success(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

#[test]
fn stage1_sema_ops_source_passes_borrow_check() {
    let path = root().join("compiler-l/src/sema_ops.l");
    let (ok, stderr) = check(&path);
    assert!(ok, "sema_ops.l: {stderr}");
}

#[test]
fn stage1_lir_module_source_passes_borrow_check() {
    let path = root().join("compiler-l/src/lir_module.l");
    let (ok, stderr) = check(&path);
    assert!(ok, "lir_module.l: {stderr}");
}

#[test]
fn stage1_stmt_lower_source_passes_borrow_check() {
    // B2 first L0012 at stmt_lower.l:264 blocks the real Stage 1
    // semantic entrypoints through transitive imports. Check the actual
    // source, not an isolated mock or a disabled ownership verifier.
    let path = root().join("compiler-l/src/stmt_lower.l");
    let (ok, stderr) = check(&path);
    assert!(ok, "stmt_lower.l: {stderr}");
}

#[test]
fn stage1_sema_expr_real_source_passes_borrow_check() {
    // The imported expression checker requires the public ACCESS_READ mode.
    // All nested LIR operands must be completed before mutating its context.
    let path = root().join("compiler-l/src/sema_expr.l");
    let (ok, stderr) = check(&path);
    assert!(ok, "sema_expr.l: {stderr}");
}

#[test]
fn stage1_sema_stmt_real_source_passes_borrow_check() {
    // Cover the real loop/foreach/match semantic entrypoint with Stage 1,
    // not a mock: its for-range bound must be evaluated before lirForInit.
    let path = root().join("compiler-l/src/sema_stmt.l");
    let (ok, stderr) = check(&path);
    assert!(ok, "sema_stmt.l: {stderr}");
}

#[test]
fn stage1_still_rejects_same_call_mutable_borrow_and_field_read() {
    let work = root().join("target/stage1-tests/b2-semantic-lir-snapshots");
    std::fs::create_dir_all(&work).unwrap();
    let bad = work.join("nested_mutable_and_read.l");
    std::fs::write(
        &bad,
        "shape Cell { value: Int }\nflow update(c: &mut Cell, n: Int) { c.value = n }\nflow probe(c: &mut Cell) { update(&mut c, c.value) }\n",
    )
    .unwrap();
    let (ok, stderr) = check(&bad);
    assert!(!ok, "overlapping mutable/read loans must stay rejected");
    assert!(stderr.contains("error[L0012]"), "{stderr}");

    let good = work.join("snapshotted_mutable_and_read.l");
    std::fs::write(
        &good,
        "shape Cell { value: Int }\nflow update(c: &mut Cell, n: Int) { c.value = n }\nflow probe(c: &mut Cell) { hold n = c.value\n update(&mut c, n) }\n",
    )
    .unwrap();
    let (ok, stderr) = check(&good);
    assert!(ok, "snapshotted primitive field must be accepted: {stderr}");
}
