//! B2: the native List<Int> emitter (`codegen/native_list_int.l`) passes the
//! Stage 1 ownership checker after its patch targets are read before the
//! exclusive `edit code` borrow. The fix is in the source, not in the
//! checker: the original pattern, an `edit` borrow of `code` while the same
//! call reads `code.bytes.length`, must still be rejected with L0012.
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

fn sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn check_ownership(file: &Path) -> (bool, String) {
    let result = Command::new(sema())
        .arg(file)
        .arg("--check-ownership")
        .output()
        .unwrap();
    (
        result.status.success(),
        String::from_utf8_lossy(&result.stderr).into_owned(),
    )
}

#[test]
fn b2_native_list_int_emitter_passes_stage1_ownership() {
    let source = root().join("compiler-l/src/codegen/native_list_int.l");
    let text = fs::read_to_string(&source).unwrap();
    // Every patch target is snapshotted before the exclusive borrow.
    assert!(!text.contains("(edit code, sane, code.bytes.length)"));
    assert!(text.contains("hold sane_target = code.bytes.length"));
    let (ok, stderr) = check_ownership(&source);
    assert!(ok, "{stderr}");
    assert!(!stderr.contains("L0012"), "{stderr}");
}

#[test]
fn b2_edit_borrow_with_same_call_read_is_still_rejected() {
    // A copy of the real codegen modules, plus a probe that keeps the
    // original pattern: the checker must still reject it.
    let dir = root().join("target/stage1-tests/b2-native-list-int");
    fs::create_dir_all(&dir).unwrap();
    for entry in fs::read_dir(root().join("compiler-l/src/codegen")).unwrap() {
        let file = entry.unwrap().path();
        if file.extension().is_some_and(|ext| ext == "l") {
            fs::copy(&file, dir.join(file.file_name().unwrap())).unwrap();
        }
    }
    let probe = dir.join("b2_same_call_read.l");
    fs::write(
        &probe,
        "import x86_64\n\nflow parche(code: edit X64Code) {\n    hold at = x64JumpPlaceholder(edit code)\n    x64PatchRelative(edit code, at, code.bytes.length)\n}\n",
    )
    .unwrap();
    let (ok, stderr) = check_ownership(&probe);
    assert!(!ok, "the original pattern must stay rejected: {stderr}");
    assert!(stderr.contains("error[L0012]"), "{stderr}");
    assert!(stderr.contains("b2_same_call_read.l:"), "{stderr}");

    // The snapshotted form of the same code is accepted.
    let fixed = dir.join("b2_snapshot.l");
    fs::write(
        &fixed,
        "import x86_64\n\nflow parche(code: edit X64Code) {\n    hold at = x64JumpPlaceholder(edit code)\n    hold target = code.bytes.length\n    x64PatchRelative(edit code, at, target)\n}\n",
    )
    .unwrap();
    let (ok, stderr) = check_ownership(&fixed);
    assert!(ok, "{stderr}");
}
