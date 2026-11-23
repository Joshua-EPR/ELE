//! Focused B1 export contract: real Stage 1 modules, not synthetic stubs.
//! PR #43 B2 loan snapshots are in main; no self-hosting claim.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn prepare_real_imports() -> PathBuf {
    let dir = repo_root().join("target/stage1-tests/b1-loans-drop-state");
    fs::create_dir_all(&dir).unwrap();
    for entry in fs::read_dir(repo_root().join("compiler-l/src")).unwrap() {
        let entry = entry.unwrap();
        let file = entry.path();
        if file.extension().is_some_and(|ext| ext == "l") {
            fs::copy(&file, dir.join(file.file_name().unwrap())).unwrap();
        }
    }
    dir
}

fn check(dir: &Path, name: &str, source: &str, accepted: bool) -> String {
    let path = dir.join(format!("{name}.l"));
    fs::write(&path, source).unwrap();
    let out = Command::new(sema())
        .arg(&path)
        .arg("--check-ownership")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    assert_eq!(out.status.success(), accepted, "{name}: {stderr}");
    stderr
}

#[test]
fn b1_loan_ancestry_and_live_drop_states_are_public_but_not_all_internals() {
    let dir = prepare_real_imports();

    let loans_check = fs::read_to_string(dir.join("loans_check.l")).unwrap();
    assert!(loans_check.contains("take loans_l"));
    assert!(loans_check.contains("loanDescendsFrom("));
    assert!(loans_check.contains("loanPlaceOf("));
    let drop_plan = fs::read_to_string(dir.join("drops_plan.l")).unwrap();
    assert!(drop_plan.contains("take ownership_l"));
    assert!(drop_plan.contains("FLOW_LIVE"));
    assert!(drop_plan.contains("FLOW_MAYBE"));
    assert!(drop_plan.contains("FLOW_UNINIT"));

    let visible_loan = check(
        &dir,
        "visible_loan_ancestry",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &FlowGraph) -> Bool { return loanDescendsFrom(graph, 0, 0) }\n",
        true,
    );
    assert!(visible_loan.is_empty(), "{visible_loan}");
    // loans_check.l needs the place lookup across its direct import.
    let visible_place = check(
        &dir,
        "visible_loan_place",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &mut FlowGraph) -> Int { return loanPlaceOf(&mut graph, 0) }\n",
        true,
    );
    assert!(visible_place.is_empty(), "{visible_place}");
    let visible_states = check(
        &dir,
        "visible_drop_states",
        "import ownership_l\nflow probe() => Int { give FLOW_LIVE + FLOW_MAYBE + FLOW_UNINIT }\n",
        true,
    );
    assert!(visible_states.is_empty(), "{visible_states}");
    let loans = fs::read_to_string(dir.join("loans_l.l")).unwrap();
    assert!(loans.contains("flow loanBind("));
    assert!(!loans.contains("pub fn loanBind("));
    let private_loan = check(
        &dir,
        "private_loan_helper",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &mut FlowGraph) { loanBind(&mut graph, 0, 0) }\n",
        false,
    );
    assert!(private_loan.contains("error[L0001]"), "{private_loan}");
    assert!(
        private_loan.contains("private_loan_helper.l:"),
        "{private_loan}"
    );
    let owners = fs::read_to_string(dir.join("ownership_l.l")).unwrap();
    assert!(owners.contains("const FLOW_MOVED ="));
    assert!(!owners.contains("pub const FLOW_MOVED ="));
    let private_moved = check(
        &dir,
        "private_moved_state",
        "import ownership_l\nflow probe() => Int { give FLOW_MOVED }\n",
        false,
    );
    assert!(private_moved.contains("error[L0001]"), "{private_moved}");
    assert!(
        private_moved.contains("private_moved_state.l:"),
        "{private_moved}"
    );
}
