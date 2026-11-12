//! Stage 1 regression tests for specific public helper APIs used across
//! compiler modules. This intentionally does NOT claim that the full
//! ownership_l.l or lir_verify_core.l compile: their unrelated Stage 1
//! semantic/CFG blockers are tracked separately under B1/B7.
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

fn prepare_imports() -> PathBuf {
    // The real imported ELE modules are copied as-is, including all of
    // their transitive dependencies. No fake interfaces or stubs are used.
    // Using a dedicated temp directory avoids touching compiler-l/src.
    let dir = root().join("target/stage1-tests/b1-helper-exports");
    fs::create_dir_all(&dir).unwrap();
    for entry in fs::read_dir(root().join("compiler-l/src")).unwrap() {
        let entry = entry.unwrap();
        let file = entry.path();
        if file.extension().is_some_and(|ext| ext == "l") {
            fs::copy(&file, dir.join(file.file_name().unwrap())).unwrap();
        }
    }
    dir
}

fn check(dir: &Path, name: &str, source: &str, expected: bool) -> String {
    let path = dir.join(format!("{name}.l"));
    fs::write(&path, source).unwrap();
    let result = Command::new(sema())
        .arg(path)
        .arg("--check-ownership")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&result.stderr).to_string();
    assert_eq!(result.status.success(), expected, "{name}: {stderr}");
    stderr
}

#[test]
fn only_required_cross_module_helper_apis_are_visible() {
    let dir = prepare_imports();

    // The consumers really use those three helpers. A test for a copied
    // declaration alone would not catch a renamed or removed call site.
    let owners = fs::read_to_string(dir.join("ownership_l.l")).unwrap();
    assert!(owners.contains("import flow_cfg"));
    assert!(owners.contains("flowNextPath("));
    let verifier = fs::read_to_string(dir.join("lir_verify_core.l")).unwrap();
    assert!(verifier.contains("import lir_build"));
    assert!(verifier.contains("lirIsVar("));
    assert!(verifier.contains("lirConstId("));

    // Resolve signatures and calls through actual imported source modules,
    // without conflating helper visibility with the rest of B1.
    check(
        &dir,
        "visible_flow_helper",
        "import flow_cfg\nfn probe(graph: &FlowGraph) -> Int { return flowNextPath(graph, 0, 0) }\n",
        true,
    );
    check(
        &dir,
        "visible_lir_helpers",
        "import lir_build\nfn probe(value: Int) -> Int { if lirIsVar(value) { return lirConstId(value) }\n return 0 }\n",
        true,
    );

    // loans_check.l also needs this overlap predicate across module boundaries.
    let loans_check = fs::read_to_string(dir.join("loans_check.l")).unwrap();
    assert!(loans_check.contains("import flow_cfg"));
    assert!(loans_check.contains("loanOverlaps("));
    check(
        &dir,
        "visible_loan_overlaps",
        "import flow_cfg\nfn probe(graph: &FlowGraph) -> Bool { return loanOverlaps(graph, 0, 0) }\n",
        true,
    );

    // A real private helper still cannot cross a module boundary.
    let loans = fs::read_to_string(dir.join("loans_l.l")).unwrap();
    assert!(loans.contains("fn loanRootedAtParams("));
    assert!(!loans.contains("pub fn loanRootedAtParams("));
    let private = check(
        &dir,
        "private_loan_helper",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &FlowGraph) -> Bool { return loanRootedAtParams(graph, 0) }\n",
        false,
    );
    assert!(private.contains("error[L0001]"), "{private}");
}
