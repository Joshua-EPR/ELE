//! Adversarial ELE-LIR against the ELE-written native backend
//! (`native_cfg_demo`, ELF64 by default and PE32+ with `--pe64`).
//!
//! Static half: hostile inputs (truncated files, counts near the Int32 and
//! Int64 limits, negative or out-of-range indexes, branches to missing
//! blocks, call arity mismatches, bad field indexes, malformed Text
//! literals, oversized files) must be rejected with exit status 3 and the
//! specific `rechazado (código N)` diagnostic (status 4 for unreadable
//! input), and NO output file may be written, for both targets.
//!
//! Runtime half: programs that fail at run time (list index out of bounds,
//! division by zero, `Int.MIN / -1`, overflow, unbounded recursion, very
//! long Text) are compiled for both targets and executed. ELF64 images run
//! natively on Linux x86-64 or through WSL (`ELE_TEST_WSL_DISTRO=Ubuntu`)
//! under `strace -f`: the exit status must be the documented trap code, the
//! process must not die from a signal, and only syscalls of the ELE runtime
//! may appear. PE32+ images run directly on Windows x86-64. Every run that
//! cannot happen on this host prints `NOT RUN[native-exec] ...` and fails
//! under `ELE_REQUIRE_NATIVE_EXEC=1`.
mod image_support;
#[allow(dead_code)]
mod stage1_support;

use image_support::{
    ALLOWED_SYSCALLS, Exec, not_run, run_elf, scratch, validate_elf64, validate_pe32plus,
};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn native() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build_self_executing("native_cfg_demo"))
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Target {
    Elf,
    Pe,
}

const TARGETS: [Target; 2] = [Target::Elf, Target::Pe];

struct Built {
    status: Option<i32>,
    stderr: String,
    image: Option<Vec<u8>>,
}

fn compile(name: &str, lir: &[u8], target: Target) -> Built {
    let dir = scratch("native-adversarial");
    let input = dir.join(format!("{name}.lir"));
    fs::write(&input, lir).unwrap();
    let output = dir.join(match target {
        Target::Elf => format!("{name}.elf"),
        Target::Pe => format!("{name}.exe"),
    });
    let _ = fs::remove_file(&output);
    let mut cmd = Command::new(native());
    cmd.arg(&input).arg(&output);
    if target == Target::Pe {
        cmd.arg("--pe64");
    }
    let out = cmd.output().unwrap();
    Built {
        status: out.status.code(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
        image: fs::read(&output).ok(),
    }
}

/// `main` with the given variables, one block and a terminator.
fn main_only(vars: &[&str], body: &[&str], term: &str) -> String {
    let mut s = format!(
        "ELE-LIR 1\nmodule structs 0 funcs 1 main f0\n\
         func f0 4:109,97,105,110 params 0 result i 0 0 vars {} blocks 1\n",
        vars.len()
    );
    for (i, ty) in vars.iter().enumerate() {
        s.push_str(&format!("var v{i} val {ty}\n"));
    }
    s.push_str(&format!("block 0 {}\n", body.len()));
    for line in body {
        s.push_str(line);
        s.push('\n');
    }
    s.push_str(&format!("t {term}\nendfunc\nend\n"));
    s
}

/// `main` calling `f1(Int) -> Int` (which returns its argument).
fn with_callee(call: &str) -> String {
    format!(
        "ELE-LIR 1\nmodule structs 0 funcs 2 main f0\n\
         func f0 4:109,97,105,110 params 0 result i 0 0 vars 1 blocks 1\n\
         var v0 val i\nblock 0 1\n{call}\nt return v0\nendfunc\n\
         func f1 2:105,100 params 1 result i 0 0 vars 1 blocks 1\n\
         var v0 val i\nblock 0 0\nt return v0\nendfunc\nend\n"
    )
}

/// `main` reading `field` of a three-field struct.
fn with_struct(read: &str) -> String {
    format!(
        "ELE-LIR 1\nmodule structs 1 funcs 1 main f0\n\
         struct s0 4:80,97,105,114 fields 3\n\
         field 1:97 i\nfield 1:98 b\nfield 1:99 i\n\
         func f0 4:109,97,105,110 params 0 result i 0 0 vars 3 blocks 1\n\
         var v0 val s0\nvar v1 val s0\nvar v2 val i\n\
         block 0 3\ni struct v0 s0 3 ci1 cb1 ci2\ni use v1 v0\n{read}\n\
         t return v2\nendfunc\nend\n"
    )
}

fn header(module: &str) -> String {
    format!(
        "ELE-LIR 1\n{module}\n\
         func f0 4:109,97,105,110 params 0 result i 0 0 vars 0 blocks 1\n\
         block 0 0\nt return ci0\nendfunc\nend\n"
    )
}

fn func_header(sig: &str) -> String {
    format!(
        "ELE-LIR 1\nmodule structs 0 funcs 1 main f0\n\
         func f0 4:109,97,105,110 {sig}\nvar v0 val i\n\
         block 0 0\nt return ci0\nendfunc\nend\n"
    )
}

/// Hostile inputs and the rejection code each one must get. `None` as the
/// code means exit status 4 (input not readable as ELE-LIR text at all).
fn static_cases() -> Vec<(&'static str, Vec<u8>, Option<u32>)> {
    let i3 = ["i", "i", "i"];
    let ok = |body: &[&str], term: &str| main_only(&i3, body, term).into_bytes();
    let mut cases: Vec<(&'static str, Vec<u8>, Option<u32>)> = vec![
        ("empty_file", Vec::new(), Some(47)),
        ("header_only", b"ELE-LIR 1\n".to_vec(), Some(48)),
        (
            "wrong_version",
            header("module structs 0 funcs 1 main f0")
                .replace("LIR 1", "LIR 2")
                .into_bytes(),
            Some(48),
        ),
        // Counts near the Int32 parse limit, past it and near Int64.
        (
            "funcs_zero",
            header("module structs 0 funcs 0 main f0").into_bytes(),
            Some(48),
        ),
        (
            "funcs_negative",
            header("module structs 0 funcs -1 main f0").into_bytes(),
            Some(48),
        ),
        (
            "funcs_i32_max",
            header("module structs 0 funcs 2147483647 main f0").into_bytes(),
            Some(44),
        ),
        (
            "funcs_i32_overflow",
            header("module structs 0 funcs 2147483648 main f0").into_bytes(),
            Some(48),
        ),
        (
            "funcs_i64_max",
            header("module structs 0 funcs 9223372036854775807 main f0").into_bytes(),
            Some(48),
        ),
        (
            "funcs_i64_overflow",
            header("module structs 0 funcs 99999999999999999999999 main f0").into_bytes(),
            Some(48),
        ),
        (
            "structs_i64_min",
            header("module structs -9223372036854775808 funcs 1 main f0").into_bytes(),
            Some(48),
        ),
        (
            "lists_huge",
            header("module structs 0 lists 2147483647 funcs 1 main f0").into_bytes(),
            Some(48),
        ),
        (
            "main_negative",
            header("module structs 0 funcs 1 main f-1").into_bytes(),
            Some(48),
        ),
        (
            "main_past_funcs",
            header("module structs 0 funcs 1 main f1").into_bytes(),
            Some(48),
        ),
        (
            "vars_huge",
            func_header("params 0 result i 0 0 vars 2147483647 blocks 1").into_bytes(),
            Some(45),
        ),
        (
            "vars_negative",
            func_header("params 0 result i 0 0 vars -1 blocks 1").into_bytes(),
            Some(44),
        ),
        (
            "vars_i64_overflow",
            func_header("params 0 result i 0 0 vars 9223372036854775808 blocks 1").into_bytes(),
            Some(44),
        ),
        (
            "blocks_zero",
            func_header("params 0 result i 0 0 vars 1 blocks 0").into_bytes(),
            Some(44),
        ),
        (
            "blocks_huge",
            func_header("params 0 result i 0 0 vars 1 blocks 2147483647").into_bytes(),
            Some(44),
        ),
        (
            "params_negative",
            func_header("params -1 result i 0 0 vars 1 blocks 1").into_bytes(),
            Some(44),
        ),
        (
            "params_more_than_vars",
            func_header("params 2 result i 0 0 vars 1 blocks 1").into_bytes(),
            Some(44),
        ),
        (
            "inst_count_negative",
            main_only(&i3, &[], "return ci0")
                .replace("block 0 0", "block 0 -1")
                .into_bytes(),
            Some(38),
        ),
        (
            "inst_count_huge",
            main_only(&i3, &[], "return ci0")
                .replace("block 0 0", "block 0 2147483647")
                .into_bytes(),
            Some(38),
        ),
        // Claims more instructions than the block holds: the terminator is
        // read as an instruction.
        (
            "inst_count_short",
            main_only(&i3, &["i use v0 ci0"], "return v0")
                .replace("block 0 1", "block 0 2")
                .into_bytes(),
            Some(31),
        ),
        (
            "block_id_mismatch",
            main_only(&i3, &[], "return ci0")
                .replace("block 0 0", "block 5 0")
                .into_bytes(),
            Some(38),
        ),
        // Negative and out-of-range variable indexes.
        (
            "dst_negative",
            ok(&["i use v-1 ci0"], "return v0"),
            Some(33),
        ),
        (
            "dst_past_vars",
            ok(&["i use v3 ci0"], "return v0"),
            Some(33),
        ),
        (
            "dst_i32_max",
            ok(&["i use v2147483647 ci0"], "return v0"),
            Some(33),
        ),
        (
            "operand_negative",
            ok(&["i use v0 v-1"], "return v0"),
            Some(34),
        ),
        (
            "operand_past_vars",
            ok(&["i use v0 v3"], "return v0"),
            Some(34),
        ),
        (
            "operand_i32_overflow",
            ok(&["i use v0 v2147483648"], "return v0"),
            Some(33),
        ),
        (
            "binary_operand_negative",
            ok(&["i binary v0 add v-1 ci1"], "return v0"),
            Some(36),
        ),
        ("return_negative_var", ok(&[], "return v-1"), Some(41)),
        ("return_past_vars", ok(&[], "return v9"), Some(41)),
        // Int constants one past the Int64 range on each side.
        (
            "const_i64_max_plus_one",
            ok(&["i use v0 ci9223372036854775808"], "return v0"),
            Some(33),
        ),
        (
            "const_i64_min_minus_one",
            ok(&["i use v0 ci-9223372036854775809"], "return v0"),
            Some(33),
        ),
        // Branches to missing blocks.
        ("jump_past_blocks", ok(&[], "jump 1"), Some(43)),
        ("jump_negative", ok(&[], "jump -1"), Some(43)),
        ("jump_i32_overflow", ok(&[], "jump 2147483648"), Some(40)),
        (
            "branch_past_blocks",
            main_only(&["b"], &["i use v0 cb1"], "branch v0 0 7").into_bytes(),
            Some(43),
        ),
        (
            "branch_negative",
            main_only(&["b"], &["i use v0 cb1"], "branch v0 -3 0").into_bytes(),
            Some(43),
        ),
        ("unknown_terminator", ok(&[], "goto"), Some(39)),
        // An unknown terminator with operands: the line reader fails first.
        (
            "unknown_terminator_with_operand",
            ok(&[], "goto 0"),
            Some(40),
        ),
        // Calls: arity, unknown and negative callee, absurd argument counts.
        (
            "call_too_few_args",
            with_callee("i call v0 f1 0").into_bytes(),
            Some(52),
        ),
        (
            "call_too_many_args",
            with_callee("i call v0 f1 2 val ci1 val ci2").into_bytes(),
            Some(52),
        ),
        (
            "call_unknown_function",
            with_callee("i call v0 f9 1 val ci1").into_bytes(),
            Some(51),
        ),
        (
            "call_negative_function",
            with_callee("i call v0 f-1 1 val ci1").into_bytes(),
            Some(51),
        ),
        (
            "call_argc_negative",
            with_callee("i call v0 f1 -1").into_bytes(),
            Some(32),
        ),
        (
            "call_argc_huge",
            with_callee("i call v0 f1 2147483647").into_bytes(),
            Some(32),
        ),
        // Struct field projections out of range.
        (
            "field_past_struct",
            with_struct("i read v2 p1.3").into_bytes(),
            Some(33),
        ),
        (
            "field_negative",
            with_struct("i read v2 p1.-1").into_bytes(),
            Some(33),
        ),
        (
            "field_i32_max",
            with_struct("i read v2 p1.2147483647").into_bytes(),
            Some(33),
        ),
        (
            "place_negative_var",
            with_struct("i read v2 p-1.0").into_bytes(),
            Some(33),
        ),
        (
            "struct_literal_arity",
            with_struct("i read v2 p1.0")
                .replace("s0 3 ci1 cb1 ci2", "s0 2 ci1 cb1")
                .into_bytes(),
            Some(65),
        ),
        // Malformed Text literals.
        (
            "text_byte_256",
            main_only(&["i"], &["i print val ct1:256"], "return ci0").into_bytes(),
            Some(33),
        ),
        (
            "text_length_mismatch",
            main_only(&["i"], &["i print val ct5:104,105"], "return ci0").into_bytes(),
            Some(33),
        ),
        (
            "text_length_huge",
            main_only(&["i"], &["i print val ct2147483647:104"], "return ci0").into_bytes(),
            Some(33),
        ),
        (
            "text_length_negative",
            main_only(&["i"], &["i print val ct-1:"], "return ci0").into_bytes(),
            Some(33),
        ),
        // Garbage after `end`, a NUL byte, CR-only line ends.
        (
            "trailing_garbage",
            [ok(&[], "return ci0"), b"x\n".to_vec()].concat(),
            Some(49),
        ),
        ("nul_byte", ok(&["i use v0\0 ci0"], "return v0"), Some(33)),
        // Not UTF-8: readText fails before parsing (status 4).
        (
            "not_utf8",
            [ok(&[], "return ci0"), vec![0xff, 0xfe]].concat(),
            None,
        ),
    ];
    // One byte over the 16 MiB input limit of native_cfg_demo (status 4).
    let mut big = ok(&[], "return ci0");
    big.resize(16_777_217, b'\n');
    cases.push(("over_one_mib", big, None));
    // Exactly 16 MiB of LIR whose padding is not LIR: rejected by the parser.
    let mut limit = ok(&[], "return ci0");
    limit.resize(16_777_216, b'\n');
    cases.push(("exactly_one_mib_padding", limit, Some(49)));
    cases
}

fn rejection(built: &Built, code: Option<u32>) -> Result<(), String> {
    match code {
        Some(code) => {
            if built.status != Some(3) {
                return Err(format!(
                    "status {:?}, expected 3; stderr: {}",
                    built.status, built.stderr
                ));
            }
            if !built.stderr.contains(&format!("rechazado (código {code})")) {
                return Err(format!(
                    "expected código {code}, got: {}",
                    built.stderr.trim()
                ));
            }
        }
        None => {
            if built.status != Some(4) {
                return Err(format!(
                    "status {:?}, expected 4; stderr: {}",
                    built.status, built.stderr
                ));
            }
        }
    }
    if built.image.is_some() {
        return Err("an output image was written".into());
    }
    Ok(())
}

/// Every hostile input is rejected by both targets with its specific code,
/// the backend never crashes, and no image is written.
#[test]
fn hostile_lir_is_rejected_with_specific_codes_and_writes_nothing() {
    let mut failures = Vec::new();
    for (name, lir, code) in static_cases() {
        for target in TARGETS {
            let built = compile(name, &lir, target);
            if let Err(why) = rejection(&built, code) {
                failures.push(format!("{name} [{target:?}]: {why}"));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} failures:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

/// Every strict prefix of a valid multi-function program (except the one
/// that only lacks the final line feed) is rejected without an image.
#[test]
fn every_truncation_of_a_valid_program_is_rejected() {
    let full = fs::read(
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../examples/native_cfg_recursive.lir"),
    )
    .unwrap();
    let full: Vec<u8> = String::from_utf8(full)
        .unwrap()
        .replace("\r\n", "\n")
        .into_bytes();
    assert_eq!(full.last(), Some(&b'\n'));
    let mut failures = Vec::new();
    for target in TARGETS {
        let built = compile("truncation_full", &full, target);
        assert_eq!(built.status, Some(0), "{target:?}: {}", built.stderr);
        let without_lf = compile("truncation_no_lf", &full[..full.len() - 1], target);
        assert_eq!(
            without_lf.status,
            Some(0),
            "{target:?}: {}",
            without_lf.stderr
        );
        for len in 0..full.len() - 1 {
            let built = compile("truncation", &full[..len], target);
            if built.status != Some(3)
                || built.image.is_some()
                || !built.stderr.contains("rechazado (código")
            {
                failures.push(format!(
                    "{target:?} prefix of {len} bytes: status {:?}, image {}, stderr {}",
                    built.status,
                    built.image.is_some(),
                    built.stderr.trim()
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} failures:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

/// Expected outcome of a runtime case.
#[derive(Clone, Copy, Debug)]
enum Outcome {
    /// Normal exit with this status and stdout of `len` bytes.
    Exit(i32),
}

fn runtime_cases() -> Vec<(&'static str, String, Outcome)> {
    let list = |idx: &str| {
        format!(
            "ELE-LIR 1\nmodule structs 0 lists 1 funcs 1 main f0\nlist l0 i\n\
             func f0 4:109,97,105,110 params 0 result i 0 0 vars 3 blocks 1\n\
             var v0 val l0\nvar v1 val i\nvar v2 val i\nblock 0 4\n\
             i listlit v0 l0 2 ci40 ci2\ni use v1 {idx}\ni read v2 p0[v1]\ni drop v0 -\n\
             t return v2\nendfunc\nend\n"
        )
    };
    let list_store = |idx: &str| {
        format!(
            "ELE-LIR 1\nmodule structs 0 lists 1 funcs 1 main f0\nlist l0 i\n\
             func f0 4:109,97,105,110 params 0 result i 0 0 vars 2 blocks 1\n\
             var v0 val l0\nvar v1 val i\nblock 0 4\n\
             i listlit v0 l0 2 ci40 ci2\ni use v1 {idx}\ni store p0[v1] ci7\ni drop v0 -\n\
             t return ci0\nendfunc\nend\n"
        )
    };
    let reserve = |n: &str| {
        format!(
            "ELE-LIR 1\nmodule structs 0 lists 1 funcs 1 main f0\nlist l0 i\n\
             func f0 4:109,97,105,110 params 0 result i 0 0 vars 2 blocks 1\n\
             var v0 val l0\nvar v1 val i\nblock 0 4\n\
             i listlit v0 l0 0\ni listreserve p0 {n}\ni len v1 p0\ni drop v0 -\n\
             t return v1\nendfunc\nend\n"
        )
    };
    let arith = |op: &str, a: &str, b: &str| {
        main_only(
            &["i", "i", "i"],
            &[
                &format!("i use v0 {a}"),
                &format!("i binary v1 {op} v0 {b}"),
            ],
            "return v1",
        )
    };
    vec![
        ("list_index_len", list("ci2"), Outcome::Exit(127)),
        ("list_index_minus_one", list("ci-1"), Outcome::Exit(127)),
        (
            "list_index_i64_max",
            list("ci9223372036854775807"),
            Outcome::Exit(127),
        ),
        (
            "list_index_i64_min",
            list("ci-9223372036854775808"),
            Outcome::Exit(127),
        ),
        // 2^61: index * 8 wraps to 0 in 64 bits.
        (
            "list_index_wraps_times_8",
            list("ci2305843009213693952"),
            Outcome::Exit(127),
        ),
        (
            "list_store_out_of_bounds",
            list_store("ci2"),
            Outcome::Exit(127),
        ),
        (
            "list_store_i64_min",
            list_store("ci-9223372036854775808"),
            Outcome::Exit(127),
        ),
        ("list_index_in_bounds", list("ci1"), Outcome::Exit(2)),
        (
            "empty_list_index_zero",
            list("ci0").replace("l0 2 ci40 ci2", "l0 0"),
            Outcome::Exit(127),
        ),
        // Capacity requests whose byte size (n * 8) overflows Int64 or wraps
        // to 0 must fail closed (123), never allocate a short buffer.
        (
            "list_reserve_i64_max",
            reserve("ci9223372036854775807"),
            Outcome::Exit(123),
        ),
        (
            "list_reserve_wraps_to_zero",
            reserve("ci2305843009213693952"),
            Outcome::Exit(123),
        ),
        (
            "list_reserve_i64_min",
            reserve("ci-9223372036854775808"),
            Outcome::Exit(123),
        ),
        (
            "div_by_zero",
            arith("div", "ci7", "ci0"),
            Outcome::Exit(125),
        ),
        (
            "rem_by_zero",
            arith("rem", "ci7", "ci0"),
            Outcome::Exit(125),
        ),
        (
            "div_min_by_minus_one",
            arith("div", "ci-9223372036854775808", "ci-1"),
            Outcome::Exit(125),
        ),
        (
            "rem_min_by_minus_one",
            arith("rem", "ci-9223372036854775808", "ci-1"),
            Outcome::Exit(125),
        ),
        (
            "add_overflow",
            arith("add", "ci9223372036854775807", "ci1"),
            Outcome::Exit(125),
        ),
        (
            "sub_overflow",
            arith("sub", "ci-9223372036854775808", "ci1"),
            Outcome::Exit(125),
        ),
        (
            "mul_overflow",
            arith("mul", "ci4611686018427387904", "ci2"),
            Outcome::Exit(125),
        ),
        (
            "mul_min_by_minus_one",
            arith("mul", "ci-9223372036854775808", "ci-1"),
            Outcome::Exit(125),
        ),
        (
            "neg_min",
            main_only(
                &["i", "i"],
                &["i use v0 ci-9223372036854775808", "i unary v1 neg v0"],
                "return v1",
            ),
            Outcome::Exit(125),
        ),
        (
            "div_min_by_one_ok",
            arith("div", "ci-9223372036854775808", "ci1"),
            Outcome::Exit(0),
        ),
    ]
}

fn run_pe(image: &Path) -> Result<(Option<i32>, Vec<u8>), String> {
    if !cfg!(all(windows, target_arch = "x86_64")) {
        return Err("this host is not Windows x86-64".into());
    }
    let out = Command::new(image).output().map_err(|e| e.to_string())?;
    Ok((out.status.code(), out.stdout))
}

/// Compiles `lir` for both targets, checks the image structure and runs
/// it; returns the failures found.
fn check_runtime(
    name: &str,
    lir: &str,
    expected: Outcome,
    stdout_len: Option<usize>,
) -> Vec<String> {
    let Outcome::Exit(status) = expected;
    let mut failures = Vec::new();
    let dir = scratch("native-adversarial");
    for target in TARGETS {
        let built = compile(name, lir.as_bytes(), target);
        let Some(bytes) = built.image.filter(|_| built.status == Some(0)) else {
            failures.push(format!(
                "{name} [{target:?}]: not compiled: {:?} {}",
                built.status, built.stderr
            ));
            continue;
        };
        match target {
            Target::Elf => {
                if let Err(e) = validate_elf64(&bytes) {
                    failures.push(format!("{name} [Elf]: invalid image: {e:?}"));
                }
                match run_elf(
                    &dir.join(format!("{name}.elf")),
                    &dir.join(format!("{name}-run")),
                    &[],
                    true,
                ) {
                    Exec::NotRun(why) => not_run(&format!("{name}.elf"), &why),
                    Exec::Ran(run) => {
                        if run.signal.is_some() || run.code != Some(status) {
                            failures.push(format!(
                                "{name} [Elf]: expected exit {status}, got exit {:?} signal {:?}",
                                run.code, run.signal
                            ));
                        }
                        let unexpected: Vec<_> = run
                            .syscalls
                            .iter()
                            .filter(|s| !ALLOWED_SYSCALLS.contains(&s.as_str()))
                            .collect();
                        if !unexpected.is_empty() {
                            failures
                                .push(format!("{name} [Elf]: unexpected syscalls {unexpected:?}"));
                        }
                        if let Some(len) = stdout_len
                            && run.stdout.len() != len
                        {
                            failures.push(format!(
                                "{name} [Elf]: stdout {} bytes, expected {len}",
                                run.stdout.len()
                            ));
                        }
                    }
                }
            }
            Target::Pe => {
                if let Err(e) = validate_pe32plus(&bytes) {
                    failures.push(format!("{name} [Pe]: invalid image: {e:?}"));
                }
                match run_pe(&dir.join(format!("{name}.exe"))) {
                    Err(why) => not_run(&format!("{name}.exe"), &why),
                    Ok((code, stdout)) => {
                        if code != Some(status) {
                            failures
                                .push(format!("{name} [Pe]: expected exit {status}, got {code:?}"));
                        }
                        if let Some(len) = stdout_len
                            && stdout.len() != len
                        {
                            failures.push(format!(
                                "{name} [Pe]: stdout {} bytes, expected {len}",
                                stdout.len()
                            ));
                        }
                    }
                }
            }
        }
    }
    failures
}

/// Runtime traps exit with their documented status (127 list bounds,
/// 125 arithmetic), never with a signal, on both targets.
#[test]
fn runtime_failures_trap_with_documented_codes() {
    let mut failures = Vec::new();
    for (name, lir, expected) in runtime_cases() {
        failures.extend(check_runtime(name, &lir, expected, Some(0)));
    }
    assert!(
        failures.is_empty(),
        "{} failures:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

fn literal(len: usize) -> String {
    format!("ct{len}:{}", vec!["97"; len].join(","))
}

/// The largest Text literal the reader accepts (65 536 bytes) is printed
/// whole; one byte more is rejected (code 33) by both targets.
#[test]
fn very_long_text_literal_is_printed_whole_and_the_limit_is_enforced() {
    let max = 65_536;
    let lir = main_only(
        &["i"],
        &[&format!("i print val {}", literal(max))],
        "return ci0",
    );
    let failures = check_runtime("long_text", &lir, Outcome::Exit(0), Some(max + 1));
    assert!(failures.is_empty(), "{}", failures.join("\n"));
    let over = main_only(
        &["i"],
        &[&format!("i print val {}", literal(max + 1))],
        "return ci0",
    );
    for target in TARGETS {
        let built = compile("long_text_over", over.as_bytes(), target);
        rejection(&built, Some(33)).unwrap_or_else(|e| panic!("{target:?}: {e}"));
    }
}

/// An owned Text grown at run time to 2 MiB (32 appends of the largest
/// literal) is printed whole on both targets.
#[test]
fn very_long_owned_text_grows_and_prints_whole() {
    let chunk = 65_536;
    let rounds = 32;
    let lir = format!(
        "ELE-LIR 1\nmodule structs 0 funcs 1 main f0\n\
         func f0 4:109,97,105,110 params 0 result i 0 0 vars 3 blocks 4\n\
         var v0 val t\nvar v1 val i\nvar v2 val b\n\
         block 0 2\ni textbuf v0 0\ni use v1 ci0\nt jump 1\n\
         block 1 1\ni binary v2 lt v1 ci{rounds}\nt branch v2 2 3\n\
         block 2 2\ni append v0 val {}\ni binary v1 add v1 ci1\nt jump 1\n\
         block 3 2\ni print ref p0 0\ni drop v0 -\nt return ci0\n\
         endfunc\nend\n",
        literal(chunk)
    );
    let failures = check_runtime(
        "long_owned_text",
        &lir,
        Outcome::Exit(0),
        Some(chunk * rounds + 1),
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

fn recursion(depth: &str) -> String {
    // f1(n) = n <= 0 ? 0 : f1(n - 1); main returns f1(depth) % 256 == 0.
    format!(
        "ELE-LIR 1\nmodule structs 0 funcs 2 main f0\n\
         func f0 4:109,97,105,110 params 0 result i 0 0 vars 1 blocks 1\n\
         var v0 val i\nblock 0 1\ni call v0 f1 1 val {depth}\nt return v0\nendfunc\n\
         func f1 1:114 params 1 result i 0 0 vars 4 blocks 3\n\
         var v0 val i\nvar v1 val b\nvar v2 val i\nvar v3 val i\n\
         block 0 1\ni binary v1 le v0 ci0\nt branch v1 1 2\n\
         block 1 0\nt return ci0\n\
         block 2 2\ni binary v2 sub v0 ci1\ni call v3 f1 1 val v2\nt return v3\n\
         endfunc\nend\n"
    )
}

/// Unbounded recursion must fail predictably: the stack overflow ends the
/// process the same way on every run, without output and without any
/// syscall outside the runtime's set.
#[test]
fn unbounded_recursion_fails_predictably() {
    let lir = recursion("ci9223372036854775807");
    let dir = scratch("native-adversarial");
    let mut observed = Vec::new();
    for target in TARGETS {
        let built = compile("recursion_unbounded", lir.as_bytes(), target);
        assert_eq!(built.status, Some(0), "{target:?}: {}", built.stderr);
        for attempt in 0..2 {
            match target {
                Target::Elf => match run_elf(
                    &dir.join("recursion_unbounded.elf"),
                    &dir.join(format!("recursion_unbounded-run{attempt}")),
                    &[],
                    true,
                ) {
                    Exec::NotRun(why) => not_run("recursion_unbounded.elf", &why),
                    Exec::Ran(run) => {
                        let unexpected: Vec<_> = run
                            .syscalls
                            .iter()
                            .filter(|s| !ALLOWED_SYSCALLS.contains(&s.as_str()))
                            .collect();
                        assert!(unexpected.is_empty(), "{unexpected:?}");
                        assert!(run.stdout.is_empty());
                        observed.push(format!("Elf: exit {:?} signal {:?}", run.code, run.signal));
                    }
                },
                Target::Pe => match run_pe(&dir.join("recursion_unbounded.exe")) {
                    Err(why) => not_run("recursion_unbounded.exe", &why),
                    Ok((code, stdout)) => {
                        assert!(stdout.is_empty());
                        observed.push(format!("Pe: exit {:?}", code.map(|c| c as u32)));
                    }
                },
            }
        }
    }
    // Current contract (documented in docs/BACKEND.md: no stack probes, no
    // trap code for stack exhaustion): Linux kills the process with SIGSEGV
    // at the guard gap; Windows, whose 8 MiB stack is fully committed and so
    // has no guard page, ends with STATUS_ACCESS_VIOLATION (0xC0000005),
    // not STATUS_STACK_OVERFLOW. Both are identical on every run.
    for line in &observed {
        assert!(
            line == "Elf: exit None signal Some(\"SIGSEGV\")"
                || line == "Pe: exit Some(3221225477)",
            "unpredictable stack overflow outcome: {observed:?}"
        );
    }
}

/// Bounded recursion 10 000 deep fits in the default stack on both targets.
#[test]
fn bounded_deep_recursion_completes() {
    let failures = check_runtime(
        "recursion_10000",
        &recursion("ci10000"),
        Outcome::Exit(0),
        Some(0),
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// A program exactly at the reader's limits (256 functions in a call
/// chain, 256 variables and 1024 blocks in one function) compiles and runs
/// on both targets; one more function, variable or block is rejected.
fn at_limits(funcs: usize, vars: usize, blocks: usize) -> String {
    let mut s = format!("ELE-LIR 1\nmodule structs 0 funcs {funcs} main f0\n");
    for f in 0..funcs - 1 {
        s.push_str(&format!(
            "func f{f} 1:102 params 0 result i 0 0 vars 1 blocks 1\nvar v0 val i\n\
             block 0 1\ni call v0 f{} 0\nt return v0\nendfunc\n",
            f + 1
        ));
    }
    s.push_str(&format!(
        "func f{} 1:103 params 0 result i 0 0 vars {vars} blocks {blocks}\n",
        funcs - 1
    ));
    for v in 0..vars {
        s.push_str(&format!("var v{v} val i\n"));
    }
    for b in 0..blocks - 1 {
        s.push_str(&format!(
            "block {b} 1\ni use v{} ci{b}\nt jump {}\n",
            b % vars,
            b + 1
        ));
    }
    s.push_str(&format!(
        "block {} 0\nt return ci42\nendfunc\nend\n",
        blocks - 1
    ));
    s
}

#[test]
fn programs_at_the_reader_limits_compile_and_run() {
    let failures = check_runtime(
        "at_limits",
        &at_limits(256, 256, 1024),
        Outcome::Exit(42),
        Some(0),
    );
    assert!(failures.is_empty(), "{}", failures.join("\n"));
    for (name, lir, code) in [("over_blocks", at_limits(256, 256, 1025), 44)] {
        for target in TARGETS {
            let built = compile(name, lir.as_bytes(), target);
            rejection(&built, Some(code)).unwrap_or_else(|e| panic!("{name} [{target:?}]: {e}"));
        }
    }
}

/// I/O failures of the driver: a missing input or a directory as input is
/// status 4, an output path inside a missing directory or naming a
/// directory is status 5; none of them leaves a file behind.
#[test]
fn driver_io_failures_write_nothing() {
    let dir = scratch("native-adversarial/io");
    let ok = dir.join("ok.lir");
    fs::write(&ok, main_only(&["i"], &["i use v0 ci7"], "return v0")).unwrap();
    let missing_dir = dir.join("no-such-dir");
    let _ = fs::remove_dir_all(&missing_dir);
    for target in TARGETS {
        let flag: &[&str] = if target == Target::Pe {
            &["--pe64"]
        } else {
            &[]
        };
        let run = |input: &Path, output: &Path| {
            Command::new(native())
                .arg(input)
                .arg(output)
                .args(flag)
                .output()
                .unwrap()
                .status
                .code()
        };
        let out = dir.join("out.img");
        let _ = fs::remove_file(&out);
        assert_eq!(run(&dir.join("missing.lir"), &out), Some(4), "{target:?}");
        assert_eq!(run(&dir, &out), Some(4), "{target:?}");
        assert!(!out.exists(), "{target:?}");
        assert_eq!(run(&ok, &missing_dir.join("x.img")), Some(5), "{target:?}");
        assert!(!missing_dir.exists(), "{target:?}");
        let as_dir = dir.join("is-a-dir");
        fs::create_dir_all(&as_dir).unwrap();
        assert_eq!(run(&ok, &as_dir), Some(5), "{target:?}");
        assert!(as_dir.is_dir(), "{target:?}");
    }
}
