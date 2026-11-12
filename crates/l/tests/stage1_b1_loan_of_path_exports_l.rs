//! Verify Stage 1 cross-module loan lookup visibility using the real ELE sources.
//! Exporting a read-only helper must not expose the mutating loan-place helper.
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
    let dir = root().join("target/stage1-tests/b1-loan-of-path");
    fs::create_dir_all(&dir).unwrap();
    for entry in fs::read_dir(root().join("compiler-l/src")).unwrap() {
        let file = entry.unwrap().path();
        if file.extension().is_some_and(|ext| ext == "l") {
            fs::copy(&file, dir.join(file.file_name().unwrap())).unwrap();
        }
    }
    dir
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

#[test]
fn b1_read_only_loan_of_path_is_public_but_mutable_place_lookup_is_private() {
    let dir = prepare_modules();
    let consumer = fs::read_to_string(dir.join("sema_context.l")).unwrap();
    assert!(consumer.contains("import loans_l"));
    assert!(consumer.contains("loanOfPath("));

    let public = check(
        &dir,
        "public_loan_of_path",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &FlowGraph) -> Int { return loanOfPath(graph, 0) }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    let private = check(
        &dir,
        "private_loan_place",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &mut FlowGraph) -> Int { return loanPlaceOf(&mut graph, 0) }\n",
        false,
    );
    assert!(private.contains("error[L0001]"), "{private}");
    assert!(private.contains("private_loan_place.l:"), "{private}");
}
