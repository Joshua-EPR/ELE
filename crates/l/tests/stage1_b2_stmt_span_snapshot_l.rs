//! B2: the Stage 1 statement parser (`stmt.l`) passes the Stage 1 ownership
//! checker after the expression span is read before `tree` is lent
//! exclusively to `astAddStmt`. The fix is in the source, not in the checker:
//! the original pattern, an `&mut tree` argument while the same call reads
//! `tree.expressions[e].start`, must still be rejected with L0012.
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
fn b2_stmt_parser_passes_stage1_ownership() {
    let source = root().join("compiler-l/src/stmt.l");
    let text = fs::read_to_string(&source).unwrap();
    // Every span is snapshotted before the exclusive borrow of `tree`.
    assert!(!text.contains("(&mut tree, AstStmtKind.Assign, tree.expressions[e].start"));
    assert!(!text.contains("(&mut tree, AstStmtKind.Expr, tree.expressions[e].start"));
    assert!(text.contains("let target_start = tree.expressions[e].start"));
    let (ok, stderr) = check_ownership(&source);
    assert!(ok, "{stderr}");
    assert!(!stderr.contains("L0012"), "{stderr}");
}

#[test]
fn b2_mut_tree_with_same_call_read_is_still_rejected() {
    // A copy of the real Stage 1 modules, plus a probe that keeps the
    // original pattern: the checker must still reject it.
    let dir = root().join("target/stage1-tests/b2-stmt-span");
    fs::create_dir_all(&dir).unwrap();
    for entry in fs::read_dir(root().join("compiler-l/src")).unwrap() {
        let file = entry.unwrap().path();
        if file.extension().is_some_and(|ext| ext == "l") {
            fs::copy(&file, dir.join(file.file_name().unwrap())).unwrap();
        }
    }
    let probe = dir.join("b2_stmt_same_call_read.l");
    fs::write(
        &probe,
        "import ast\nfn probe(tree: &mut AstTree, e: Int) -> Int {\n    return astAddStmt(&mut tree, AstStmtKind.Expr, tree.expressions[e].start, 0, e, 0, 0, 0, 0)\n}\n",
    )
    .unwrap();
    let (ok, stderr) = check_ownership(&probe);
    assert!(!ok, "the original pattern must stay rejected: {stderr}");
    assert!(stderr.contains("error[L0012]"), "{stderr}");
    assert!(stderr.contains("b2_stmt_same_call_read.l:"), "{stderr}");

    // The snapshotted form of the same code is accepted.
    let fixed = dir.join("b2_stmt_snapshot.l");
    fs::write(
        &fixed,
        "import ast\nfn probe(tree: &mut AstTree, e: Int) -> Int {\n    let start = tree.expressions[e].start\n    return astAddStmt(&mut tree, AstStmtKind.Expr, start, 0, e, 0, 0, 0, 0)\n}\n",
    )
    .unwrap();
    let (ok, stderr) = check_ownership(&fixed);
    assert!(ok, "{stderr}");
}
