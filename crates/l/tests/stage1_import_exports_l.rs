//! Stage 1 regression tests for specific public helper APIs used across
//! compiler modules. This intentionally does NOT claim that the full
//! ownership_l.l or lir_verify_core.l compile: their unrelated Stage 1
//! semantic/CFG blockers are tracked separately under B1/B7.
mod stage1_support;

use std::{
    fs,
    ops::Deref,
    path::{Path, PathBuf},
    process::Command,
    sync::{
        OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

struct ImportFixture(PathBuf);

impl Deref for ImportFixture {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.0
    }
}

impl Drop for ImportFixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn prepare_imports() -> ImportFixture {
    // The real imported ELE modules are copied as-is, including all of
    // their transitive dependencies. No fake interfaces or stubs are used.
    // Using a dedicated temp directory avoids touching compiler-l/src.
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let parent = root().join("target/stage1-tests/b1-helper-exports");
    fs::create_dir_all(&parent).unwrap();
    let dir = parent.join(format!(
        "{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir(&dir).unwrap();
    let fixture = ImportFixture(dir);
    for entry in fs::read_dir(root().join("compiler-l/src")).unwrap() {
        let entry = entry.unwrap();
        let file = entry.path();
        if file.extension().is_some_and(|ext| ext == "l") {
            fs::copy(&file, fixture.join(file.file_name().unwrap())).unwrap();
        }
    }
    fixture
}

#[test]
fn import_fixtures_do_not_share_mutable_sources() {
    let first = prepare_imports();
    let second = prepare_imports();
    assert_ne!(
        first.0, second.0,
        "parallel tests must not share writable imports"
    );
    fs::write(first.join("fixture_isolation.l"), "first").unwrap();
    assert!(!second.join("fixture_isolation.l").exists());
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
    assert!(owners.contains("take flow_cfg"));
    assert!(owners.contains("flowNextPath("));
    let verifier = fs::read_to_string(dir.join("lir_verify_core.l")).unwrap();
    assert!(verifier.contains("take lir_build"));
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
    assert!(loans_check.contains("take flow_cfg"));
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

#[test]
fn parser_export_chain_exposes_only_cross_module_entrypoints() {
    let dir = prepare_imports();
    let decl = fs::read_to_string(dir.join("decl.l")).unwrap();
    let parser = fs::read_to_string(dir.join("parser.l")).unwrap();
    assert!(decl.contains("take stmt"));
    assert!(decl.contains("parseStmt("));
    assert!(parser.contains("take decl"));
    assert!(parser.contains("parseDecl("));

    // Real Stage 1 source modules, not dummy interfaces.
    let types = "import lexer\nimport tokens\nimport cursor\nimport ast\n";
    check(
        &dir,
        "visible_parser_stmt",
        &format!(
            "{types}import stmt\nfn probe(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) -> Int {{ return parseStmt(&mut tree, source, &mut cursor, tokens, 0) }}\n"
        ),
        true,
    );
    check(
        &dir,
        "visible_parser_decl",
        &format!(
            "{types}import decl\nfn probe(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) -> Int {{ return parseDecl(&mut tree, source, &mut cursor, tokens) }}\n"
        ),
        true,
    );

    // decl.l also calls parseBlock directly for function bodies, so this
    // is a required cross-module interface, not a private implementation.
    let stmt = fs::read_to_string(dir.join("stmt.l")).unwrap();
    assert!(decl.contains("parseBlock("));
    assert!(stmt.contains("expose flow parseBlock("));
    check(
        &dir,
        "visible_parser_block",
        &format!(
            "{types}import stmt\nfn probe(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) -> Int {{ return parseBlock(&mut tree, source, &mut cursor, tokens, 0) }}\n"
        ),
        true,
    );
    // Cross-module private visibility is separately covered by
    // private_loan_helper above. Do not make other helpers public.
}

#[test]
fn lir_place_field_is_public_for_actual_cross_module_consumers() {
    let dir = prepare_imports();
    let lower = fs::read_to_string(dir.join("sema_lower.l")).unwrap();
    let finish = fs::read_to_string(dir.join("lir_finish.l")).unwrap();
    let ops = fs::read_to_string(dir.join("sema_ops.l")).unwrap();
    for source in [&lower, &finish, &ops] {
        assert!(source.contains("take lir_build"));
        assert!(source.contains("lirPlaceField("));
    }

    check(
        &dir,
        "visible_lir_place_field",
        "import lir_build\nfn probe(l: &mut LirFn) -> Int { return lirPlaceField(&mut l, 0, 0) }\n",
        true,
    );

    // The verifier instruction walker is internal and must stay private.
    let private = check(
        &dir,
        "private_lir_verify_inst_b1",
        "import lir_verify\nflow probe() => Int { give lirVerifyInst() }\n",
        false,
    );
    assert!(
        private.lines().any(|line| {
            line.contains("private_lir_verify_inst_b1.l:2:") && line.contains("error[L0001]")
        }),
        "{private}"
    );
}
