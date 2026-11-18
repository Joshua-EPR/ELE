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
fn stage1_sema_core_real_source_passes_borrow_check() {
    // The genuine Stage 1 semantic core used to fail on a nested mutable
    // loan of ctx.lir during parameter registration. Do not mock this input.
    let path = root().join("compiler-l/src/sema.l");
    let (ok, stderr) = check(&path);
    assert!(ok, "sema.l: {stderr}");
}

#[test]
fn stage1_writebytes_borrows_text_and_list_through_verified_lir() {
    // The platform operation must not consume the two heap owners. Validate
    // Stage 1's actual LIR using Stage 0's *independent* parser and verifier,
    // and execute the byte-exact write through the verified protocol.
    let work = root().join("target/stage1-tests/b3-writebytes-platform");
    std::fs::create_dir_all(&work).unwrap();
    let source = work.join("valid.l");
    std::fs::write(
        &source,
        "fn main() -> Int {\n    let path = \"borrowed_bytes.bin\"\n    var bytes: List<Int> = List[0, 127, 128, 255, 10]\n    let status = writeBytes(path, bytes)\n    if bytes.length != 5 { return 9 }\n    let again = writeBytes(path, bytes)\n    return status + again\n}\n",
    )
    .unwrap();
    let emitted = Command::new(sema())
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "Stage 1 LIR: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    assert!(lir.contains("writebytes 2 ref "), "{lir}");
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();
    let file = work.join("valid.lir");
    std::fs::write(&file, &lir).unwrap();
    let bytes_path = work.join("borrowed_bytes.bin");
    let _ = std::fs::remove_file(&bytes_path);
    let ran = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(&work)
        .arg("run-lir")
        .arg(&file)
        .output()
        .unwrap();
    assert!(
        ran.status.success(),
        "run-lir: {}",
        String::from_utf8_lossy(&ran.stderr)
    );
    assert_eq!(std::fs::read(&bytes_path).unwrap(), [0, 127, 128, 255, 10]);
}

#[test]
fn stage1_writebytes_rejects_wrong_types_and_unowned_temporaries() {
    let work = root().join("target/stage1-tests/b3-writebytes-platform");
    std::fs::create_dir_all(&work).unwrap();
    let cases = [
        (
            "wrong_element.l",
            "fn main() -> Int {\n    let path = \"out.bin\"\n    var bytes: List<Text> = List[\"wrong\"]\n    return writeBytes(path, bytes)\n}\n",
            "error[L0004]",
        ),
        (
            "wrong_arity.l",
            "fn main() -> Int {\n    let path = \"out.bin\"\n    return writeBytes(path)\n}\n",
            "error[L0004]",
        ),
        (
            "temporary_owner.l",
            "fn main() -> Int {\n    var bytes: List<Int> = List[1]\n    return writeBytes(\"out.bin\", bytes)\n}\n",
            "error[L0016]",
        ),
    ];
    for (name, source, code) in cases {
        let file = work.join(name);
        std::fs::write(&file, source).unwrap();
        let (ok, stderr) = check(&file);
        assert!(!ok, "{name}: unsupported call must be rejected");
        assert!(stderr.contains(code), "{name}: {stderr}");
    }
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
