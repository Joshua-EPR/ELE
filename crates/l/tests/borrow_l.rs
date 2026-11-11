//! Stage 1 borrow checker (loans, NLL, provenance, borrowed returns) run
//! natively from `sema-l --check-ownership` and compared with Stage 0.
//!
//! Each case lists the Stage 1 verdict and the Stage 0 verdict ("OK" or the
//! diagnostic code). The suite asserts both, and asserts that Stage 1 never
//! accepts a program Stage 0 rejects. Where the verdicts differ Stage 1 is
//! stricter (references stored in structs or lists are outside its subset).
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

fn case_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../target/stage1-tests/borrow")
}

struct Stage1 {
    code: String,
    stderr: String,
    stdout: String,
}

/// Runs the native Stage 1 checker with an empty PATH so no Rust tool can
/// take part in the decision.
fn stage1(name: &str, source: &str) -> Stage1 {
    let file = case_dir().join(format!("{name}.l"));
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, source).unwrap();
    let output = Command::new(sema_exe())
        .arg(&file)
        .arg("--check-ownership")
        .env("PATH", "")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let code = if output.status.success() {
        assert!(stderr.is_empty(), "{name}: {stderr}");
        "OK".to_string()
    } else {
        assert_eq!(output.status.code(), Some(1), "{name}: {stderr}");
        assert!(stderr.contains(&format!("{name}.l:")), "{name}: {stderr}");
        let tail = stderr.split("error[").nth(1).expect(&stderr);
        tail[..tail.find(']').unwrap()].to_string()
    };
    Stage1 {
        code,
        stderr,
        stdout,
    }
}

fn stage0(source: &str) -> String {
    match project_l::check(source) {
        Ok(_) => "OK".to_string(),
        Err(d) => d.code.to_string(),
    }
}

use stage1_support::borrow_cases::CASES;

/// Cases whose L0012 diagnostic names the same loan origin and the same
/// live use (line:column) in both compilers.
const SAME_RELATION: &[&str] = &[
    "shared_conflict_write",
    "mut_overlap_shared",
    "call_mut_arg_conflict_use_after",
    "loop_loan_live_across_backedge",
    "loan_live_across_loop_write",
    "result_conflict",
    "cond_conflict",
    "mixed_conflict_first",
    "mixed_conflict_distinct",
    "mixed_write_second",
    "read_between_mut_loan",
    "write_through_parent_while_reborrow",
    "read_parent_between_reborrow",
    "shared_read_during_mut_loan",
    "implicit_shared_during_mut",
    "mixed_mut_shared_ret",
    "shared_binding_arg_conflict",
    "branch_conflict_join",
    "loop_break_live",
    "nested_loop_conflict",
    "for_loop_conflict",
    "early_return_conflict",
    "ret_field_of_param",
    "ret_unused_param_write",
    "ret_chain_two",
    "multi_reborrow_write_second",
];

#[test]
fn stage1_borrow_checker_matches_stage0_on_supported_subset() {
    let mut same = 0;
    let mut stricter = Vec::new();
    for (name, source, expected1, expected0) in CASES {
        let s1 = stage1(name, source);
        assert_eq!(&s1.code, expected1, "{name}: Stage 1 {}", s1.stderr);
        let s0 = stage0(source);
        assert_eq!(&s0, expected0, "{name}: Stage 0");
        if s1.code == "OK" {
            assert_eq!(
                s0, "OK",
                "{name}: Stage 1 accepted a program Stage 0 rejects"
            );
            assert!(s1.stdout.contains("loans="), "{name}: {}", s1.stdout);
        }
        if s1.code == s0 {
            same += 1;
        } else if s0 == "OK" {
            stricter.push(*name);
        }
    }
    assert!(same >= 160, "only {same} identical verdicts");
    assert_eq!(
        stricter,
        [
            "struct_field_of_ref_type",
            "list_of_borrows",
            "struct_ref_nll",
            "struct_ref_move",
            "struct_ref_annot",
            "list_ref_len",
        ]
    );
}

#[test]
fn stage1_conflicts_name_the_same_loan_and_live_use_as_stage0() {
    let relation = |message: &str| -> String {
        let at = message.find("iniciado en ").expect(message);
        message[at..].split(". Termine").next().unwrap().to_string()
    };
    for name in SAME_RELATION {
        let (_, source, _, _) = CASES.iter().find(|c| c.0 == *name).unwrap();
        let s1 = stage1(name, source);
        let s0 = project_l::check(source).unwrap_err();
        assert_eq!(s0.code, "L0012");
        assert_eq!(relation(&s1.stderr), relation(&s0.message), "{name}");
    }
}

#[test]
fn stage1_borrow_checker_scales_and_frees_its_memory() {
    use std::fmt::Write as _;
    // 500 shared and 500 mutable loans of distinct owners: each mutable
    // loan starts after the last use of the shared one (NLL) inside a loop
    // and a branch. The parameter of `g` carries one more loan.
    let mut source = String::from("fn g(n: &Int) -> Int = 1\nfn main() {\n");
    for i in 0..500 {
        writeln!(source, "var v{i} = {i}\nlet a{i} = &v{i}\nprint(g(a{i}))").unwrap();
    }
    source.push_str("var k = 0\nwhile k < 2 {\nif k == 0 {\n");
    for i in 0..500 {
        writeln!(source, "let m{i} = &mut v{i}\nm{i} = k").unwrap();
    }
    source.push_str("}\nk = k + 1\n}\n}\n");
    let s1 = stage1("borrow_scale", &source);
    assert_eq!(s1.code, "OK", "{}", s1.stderr);
    assert!(s1.stdout.contains("loans=1501"), "{}", s1.stdout);
    // Stage 0 is the reference again: the old CORE-1 limit of 4 096 tokens
    // per file, which this source exceeds, no longer exists.
    assert_eq!(stage0(&source), "OK");

    let traced = stage1_support::build("main_sema", true);
    let file = case_dir().join("borrow_trace.l");
    fs::write(
        &file,
        "fn f(n: &mut Int) -> &mut Int { return n }\nfn main() { var x = 1\n let r = f(&mut x)\n r = 2\n print(x)\n let a = &x\n x = 3\n print(a)\n}",
    )
    .unwrap();
    let output = Command::new(traced)
        .arg(&file)
        .arg("--check-ownership")
        .output()
        .unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert_eq!(output.status.code(), Some(1), "{stderr}");
    assert!(stderr.contains("error[L0012]"), "{stderr}");
    stage1_support::assert_heap(&stderr);
}
