//! Verify the Stage 1 cross-module exports consumed by sema_lower.l,
//! drops_plan.l, stmt.l and loans_check.l, using the real ELE sources.
//! Each exported symbol must resolve from another module while a
//! neighbouring private helper of the same module is still rejected.
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

fn prepare_modules() -> PathBuf {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        let dir = root().join("target/stage1-tests/b1-export-chain");
        fs::create_dir_all(&dir).unwrap();
        for entry in fs::read_dir(root().join("compiler-l/src")).unwrap() {
            let file = entry.unwrap().path();
            if file.extension().is_some_and(|ext| ext == "l") {
                fs::copy(&file, dir.join(file.file_name().unwrap())).unwrap();
            }
        }
        dir
    })
    .clone()
}

fn check(dir: &Path, name: &str, source: &str, expected: bool) -> String {
    let file = dir.join(format!("{name}.l"));
    fs::write(&file, source).unwrap();
    let result = Command::new(sema())
        .arg(file)
        .arg("--check-ownership")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&result.stderr).into_owned();
    assert_eq!(result.status.success(), expected, "{name}: {stderr}");
    stderr
}

fn assert_consumer(dir: &Path, consumer: &str, import: &str, call: &str) {
    let text = fs::read_to_string(dir.join(consumer)).unwrap();
    assert!(text.contains(&format!("import {import}")), "{consumer}");
    assert!(text.contains(call), "{consumer} no longer uses {call}");
}

fn assert_private(dir: &Path, name: &str, source: &str) {
    let private = check(dir, name, source, false);
    assert!(private.contains("error[L0001]"), "{private}");
    assert!(private.contains(&format!("{name}.l:")), "{private}");
}

#[test]
fn b1_lir_emit_and_arg_are_public_but_index_place_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "sema_lower.l", "lir_build", "lirEmit(");
    assert_consumer(&dir, "sema_lower.l", "lir_build", "lirArg(");

    let public = check(
        &dir,
        "public_lir_emit",
        "import lir_build\nfn probe(l: &mut LirFn) -> Int {\n    lirEmit(&mut l, 0, 0, 0, 0, 0, 0, 0)\n    return lirArg(&mut l, false, 0, false)\n}\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_private(
        &dir,
        "private_lir_place_index",
        "import lir_build\nfn probe(l: &mut LirFn) -> Int { return lirPlaceIndex(&mut l, 0, 0) }\n",
    );
}

#[test]
fn b1_flow_apply_and_uninit_are_public_but_moved_state_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "drops_plan.l", "ownership_l", "flowApply(");
    assert_consumer(&dir, "drops_plan.l", "ownership_l", "FLOW_UNINIT");

    let public = check(
        &dir,
        "public_flow_apply",
        "import flow_cfg\nimport ownership_l\nfn probe(graph: &FlowGraph, state: &mut List<Int>, ev: &FlowEvent) -> Bool {\n    state.push(FLOW_UNINIT)\n    return flowApply(graph, &mut state, ev, false)\n}\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_private(
        &dir,
        "private_flow_moved",
        "import flow_cfg\nimport ownership_l\nfn probe() -> Int { return FLOW_MOVED }\n",
    );
}

#[test]
fn b1_parse_expr_is_public_but_primary_expr_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "stmt.l", "expr", "parseExpr(");

    let public = check(
        &dir,
        "public_parse_expr",
        "import expr\nfn probe(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) -> Int { return parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, 0) }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_private(
        &dir,
        "private_parse_primary_expr",
        "import expr\nfn probe(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) -> Int { return parsePrimaryExpr(&mut tree, source, &mut cursor, tokens, 0, 0) }\n",
    );
}

#[test]
fn b1_loan_overlap_and_mutability_are_public_but_param_root_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "loans_check.l", "flow_cfg", "loanOverlaps(");
    assert_consumer(&dir, "loans_check.l", "loans_l", "loanIsMut(");

    let public = check(
        &dir,
        "public_loan_overlaps",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &FlowGraph) -> Bool { return loanOverlaps(graph, 0, 1) || loanIsMut(graph, 0) }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_private(
        &dir,
        "private_loan_rooted_at_params",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &FlowGraph) -> Bool { return loanRootedAtParams(graph, 0) }\n",
    );
}
