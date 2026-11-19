//! Adversarial audit and validation suite for ELE-LIR memory safety and ownership invariants.
//!
//! Exercises both:
//! 1. The Rust LIR validator (`lir_protocol.rs` and `drops.rs`).
//! 2. The ELE self-hosted LIR verifier (`compiler-l/src/lir_verify.l`).
//!
//! Tests adversarial vectors:
//! - Manipulated drop flags (`cb0 -> cb1` double free, `cb1 -> cb0` leak) on `LIR_DROP` and `LIR_DROPFIELD`.
//! - Nested enums with conditional drops, loop back-edges, and diamond CFG joins.
//! - Forged uninitialized operands and reads/uses after move.
//! - Deleted or duplicated unconditional drops (leak at return, double free).
//! - Strict fail-closed verification in both verifiers. In Rust, drop-flag
//!   disagreements are L0017 protocol rejections, while ownership-state
//!   violations are reported as L0007 internal errors (see `assert_diag`);
//!   the ELE verifier reports an ICE naming the violated rule.

mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn sema() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_sema", false))
}

fn temp() -> PathBuf {
    let dir = root().join("target/stage1-tests/adversarial-drops-l");
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn write(name: &str, text: &str) -> PathBuf {
    let path = temp().join(name);
    fs::write(&path, text).unwrap();
    path
}

fn stage1(path: &Path, flag: &str) -> Output {
    Command::new(sema())
        .arg(path)
        .arg(flag)
        .env("PATH", "")
        .output()
        .unwrap()
}

fn emit(name: &str, text: &str) -> String {
    let out = stage1(&write(name, text), "--emit-lir");
    assert!(
        out.status.success(),
        "{name}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let lir = String::from_utf8(out.stdout).unwrap();
    assert!(
        lir.starts_with("ELE-LIR 1\n"),
        "{name}: Stage 1 emitted no canonical ELE-LIR header"
    );
    lir
}

fn validate(lir: &str) -> Result<(), String> {
    let module = project_l::lir_protocol::parse(lir).map_err(|e| format!("{e:?}"))?;
    project_l::lir_protocol::validate(&module).map_err(|e| format!("{e:?}"))
}

fn validate_err(lir: &str) -> String {
    match project_l::lir_protocol::parse(lir) {
        Ok(module) => match project_l::lir_protocol::validate(&module) {
            Ok(()) => panic!("expected LIR validation error, but validation succeeded"),
            Err(diag) => format!("{diag:?}"),
        },
        Err(err) => format!("{err:?}"),
    }
}

/// Exactly one diagnostic code and one specific message: a forged LIR must be
/// rejected for the property under attack, not for any reason at all.
///
/// Observed split (documented, not normalized here): drop-flag disagreements
/// are protocol rejections (`L0017`, "LIR rechazada"), while ownership-state
/// violations (use after move, double drop, leak at return, read before
/// assignment) surface as `L0007` "error interno del compilador" even when
/// the LIR came from outside the compiler.
fn assert_diag(err: &str, code: &str, message: &str) {
    assert!(
        err.contains(&format!("code: \"{code}\"")),
        "expected code {code}: {err}"
    );
    assert!(err.contains(message), "expected {message:?}: {err}");
}

fn mutate(lir: &str, pred: impl Fn(&str) -> bool, dup: bool) -> String {
    let mut lines: Vec<String> = lir.lines().map(str::to_string).collect();
    let at = lines.iter().position(|l| pred(l)).expect("line to mutate");
    let header = (0..=at)
        .rev()
        .find(|&i| lines[i].starts_with("block "))
        .expect("block header");
    let mut parts: Vec<String> = lines[header]
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let count: usize = parts[2].parse().unwrap();
    parts[2] = if dup { count + 1 } else { count - 1 }.to_string();
    lines[header] = parts.join(" ");
    if dup {
        let copy = lines[at].clone();
        lines.insert(at, copy);
    } else {
        lines.remove(at);
    }
    lines.join("\n") + "\n"
}

fn insert_inst_after(lir: &str, pred: impl Fn(&str) -> bool, new_inst: &str) -> String {
    let mut lines: Vec<String> = lir.lines().map(str::to_string).collect();
    let at = lines.iter().position(|l| pred(l)).expect("line to find");
    let header = (0..=at)
        .rev()
        .find(|&i| lines[i].starts_with("block "))
        .expect("block header");
    let mut parts: Vec<String> = lines[header]
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let count: usize = parts[2].parse().unwrap();
    parts[2] = (count + 1).to_string();
    lines[header] = parts.join(" ");
    lines.insert(at + 1, new_inst.to_string());
    lines.join("\n") + "\n"
}

fn stage1_fault(name: &str, source: &str, fault: usize, expected_rule: usize) {
    let path = write(name, source);
    let out = stage1(&path, &format!("--lir-fault={fault}"));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        !out.status.success(),
        "{name} fault {fault} should have failed closed"
    );
    assert!(
        stderr.contains("error[ICE]") && stderr.contains(&format!("(regla {expected_rule},")),
        "{name} fault {fault} unexpected stderr: {stderr}"
    );
    assert!(
        out.stdout.is_empty(),
        "{name} fault {fault} emitted unverified LIR to stdout"
    );
}

// =========================================================================
// Sources under test
// =========================================================================

const B_WILD: &str = r#"fn label(n: Int) -> Text {
    return "item-{n}"
}
fn maybe(n: Int) -> Option<Text> {
    if n < 0 { return None }
    return Some(label(n))
}
fn res(n: Int) -> Result<Text, Text> {
    if n > 0 { return Ok(label(n)) }
    return Err(label(0 - n))
}
fn nested(n: Int) -> Option<Result<Text, Int>> {
    if n == 0 { return None }
    if n > 5 { return Some(Err(n)) }
    return Some(Ok(label(n)))
}

fn main() -> Int {
    var total = 0
    let o = maybe(1)
    match o {
        Some(t) => { print(t) }
        _ => { total += 1 }
    }
    let p = maybe(-1)
    match p {
        Some(t) => { print(t) }
        _ => { total += 2 }
    }
    match maybe(3) {
        _ => { total += 4 }
    }
    match res(-2) {
        Ok(_) => { total += 8 }
        Err(_) => { total += 16 }
    }
    match res(2) {
        Err(e) => { print(e) }
        Ok(_) => { total += 32 }
    }
    return total
}
"#;

const STRUCT_PARTIAL_MOVE_TEXT: &str = r#"struct Pair {
    first: Text,
    second: Text,
}
fn take(t: Text) {}
fn cond_field(c: Bool) {
    var p = Pair(first: "a", second: "b")
    if c {
        take(p.first)
    }
}
fn main() -> Int {
    cond_field(true)
    return 0
}
"#;

const STRUCT_PARTIAL_MOVE_LIST: &str = r#"struct Holder {
    items: List<Int>,
    name: Text,
}
fn take_items(l: List<Int>) {}
fn cond_list(c: Bool) {
    var h = Holder(items: List[1, 2, 3], name: "holder")
    if c {
        take_items(h.items)
    }
}
fn main() -> Int {
    cond_list(true)
    return 0
}
"#;

const NESTED_ENUM_COND: &str = r#"fn take_text(t: Text) {}
fn nested_option_match(c: Bool) {
    var opt: Option<Option<Text>> = Some(Some("nested_value"))
    if c {
        match opt {
            Some(inner) => {
                match inner {
                    Some(s) => { take_text(s) }
                    None => {}
                }
            }
            None => {}
        }
    }
}
fn main() -> Int {
    nested_option_match(true)
    return 0
}
"#;

const LOOP_AND_DIAMOND_CFG: &str = r#"fn take_text(t: Text) {}
fn diamond_union(c: Bool) {
    var opt: Option<Text> = Some("diamond_payload")
    if c {
        match opt {
            Some(s) => { take_text(s) }
            None => {}
        }
    }
}
fn loop_with_reinit(n: Int) {
    var i = 0
    while i < n {
        var opt: Option<Text> = Some("loop_payload")
        match opt {
            Some(s) => { take_text(s) }
            None => {}
        }
        i = i + 1
    }
}
fn main() -> Int {
    diamond_union(true)
    loop_with_reinit(3)
    return 0
}
"#;

const SIMPLE_ARITH: &str = r#"fn consume_text(t: Text) {}
fn arith(a: Int, b: Int) -> Int {
    let x = a + b
    let t = "hello"
    consume_text(t)
    return x
}
fn main() -> Int {
    return arith(1, 2)
}
"#;

// =========================================================================
// Category 1: Drop flags manipulados (cb0 -> cb1, cb1 -> cb0)
// =========================================================================

#[test]
fn test_drop_flag_attacks_on_lir_drop_double_free_and_leak() {
    let lir = emit("b_wild.l", B_WILD);
    validate(&lir).expect("clean b_wild must validate");

    // Attack 1a: Double free (change cb0 to cb1 after payload move-out)
    let forged_df = lir.replacen("i use v32 cb0 @22:14", "i use v32 cb1 @22:14", 1);
    assert_ne!(forged_df, lir, "replacement for double free must succeed");
    // The flag claims ownership (On) of a value already moved out.
    let err_df = validate_err(&forged_df);
    assert_diag(
        &err_df,
        "L0017",
        "flag v32 = On no refleja la propiedad de [Place { var: 2, proj: [] }]",
    );

    // Attack 1b: Leak (change cb1 to cb0 when value is owned)
    let forged_leak = lir.replacen("i use v32 cb1 @20:5", "i use v32 cb0 @20:5", 1);
    assert_ne!(forged_leak, lir, "replacement for leak must succeed");
    // The flag denies ownership (Off) of a value still owned.
    let err_leak = validate_err(&forged_leak);
    assert_diag(
        &err_leak,
        "L0017",
        "flag v32 = Off no refleja la propiedad de [Place { var: 2, proj: [] }]",
    );

    // Self-hosted ELE verifier checks (fail-closed rule 6)
    stage1_fault("b_wild_fault17.l", B_WILD, 17, 6);
    stage1_fault("b_wild_fault18.l", B_WILD, 18, 6);
}

#[test]
fn test_dropfield_flag_attacks_on_struct_text_and_list() {
    // 1. Struct with Text field
    let lir_text = emit("struct_text.l", STRUCT_PARTIAL_MOVE_TEXT);
    validate(&lir_text).expect("clean struct text must validate");
    assert!(
        lir_text.contains("i dropfield p2.0 v5"),
        "must have flagged dropfield: {lir_text}"
    );

    // Attack 1a: Double free (cb0 -> cb1)
    let forged_df = if lir_text.contains("val v3 @9:9\r\ni use v5 cb0") {
        lir_text.replacen(
            "val v3 @9:9\r\ni use v5 cb0",
            "val v3 @9:9\r\ni use v5 cb1",
            1,
        )
    } else {
        lir_text.replacen("val v3 @9:9\ni use v5 cb0", "val v3 @9:9\ni use v5 cb1", 1)
    };
    assert_ne!(forged_df, lir_text);
    let err_df = validate_err(&forged_df);
    assert_diag(
        &err_df,
        "L0017",
        "flag v5 = On no refleja la propiedad de [Place { var: 2, proj: [Field(0)] }]",
    );

    // Attack 1b: Leak (cb1 -> cb0)
    let forged_leak = lir_text.replacen("i use v5 cb1", "i use v5 cb0", 1);
    assert_ne!(forged_leak, lir_text);
    let err_leak = validate_err(&forged_leak);
    assert_diag(
        &err_leak,
        "L0017",
        "flag v5 = Off no refleja la propiedad de [Place { var: 2, proj: [Field(0)] }]",
    );

    // 2. Struct with List field
    let lir_list = emit("struct_list.l", STRUCT_PARTIAL_MOVE_LIST);
    validate(&lir_list).expect("clean struct list must validate");
    assert!(
        lir_list.contains("i dropfield p3.0 v6"),
        "must have flagged dropfield: {lir_list}"
    );

    let forged_df_l = if lir_list.contains("val v4 @9:9\r\ni use v6 cb0") {
        lir_list.replacen(
            "val v4 @9:9\r\ni use v6 cb0",
            "val v4 @9:9\r\ni use v6 cb1",
            1,
        )
    } else {
        lir_list.replacen("val v4 @9:9\ni use v6 cb0", "val v4 @9:9\ni use v6 cb1", 1)
    };
    assert_ne!(forged_df_l, lir_list);
    let err_df_l = validate_err(&forged_df_l);
    assert_diag(
        &err_df_l,
        "L0017",
        "flag v6 = On no refleja la propiedad de [Place { var: 3, proj: [Field(0)] }]",
    );

    let forged_leak_l = lir_list.replacen("i use v6 cb1", "i use v6 cb0", 1);
    assert_ne!(forged_leak_l, lir_list);
    let err_leak_l = validate_err(&forged_leak_l);
    assert_diag(
        &err_leak_l,
        "L0017",
        "flag v6 = Off no refleja la propiedad de [Place { var: 3, proj: [Field(0)] }]",
    );

    // Self-hosted ELE verifier checks on both structs (fail-closed rule 6)
    stage1_fault("struct_text_fault17.l", STRUCT_PARTIAL_MOVE_TEXT, 17, 6);
    stage1_fault("struct_text_fault18.l", STRUCT_PARTIAL_MOVE_TEXT, 18, 6);
    stage1_fault("struct_list_fault17.l", STRUCT_PARTIAL_MOVE_LIST, 17, 6);
    stage1_fault("struct_list_fault18.l", STRUCT_PARTIAL_MOVE_LIST, 18, 6);
}

// =========================================================================
// Category 2: Enums anidados, bucles y joins de CFG
// =========================================================================

#[test]
fn test_nested_enums_conditional_drops_and_cfg_joins() {
    let lir = emit("nested_enum.l", NESTED_ENUM_COND);
    validate(&lir).expect("clean nested enum must validate");

    // Attack 2.1: Double move of inner payload using block-adjusted mutation
    let twice_inner = mutate(&lir, |l| l.contains("i payload v10 p7 e0 1"), true);
    // The second payload read finds the inner union (v7) already consumed.
    let err_move_inner = validate_err(&twice_inner);
    assert_diag(
        &err_move_inner,
        "L0007",
        "Place { var: 7, proj: [] }: uso tras movimiento o inicialización parcial",
    );

    // Attack 2.2: Double move of outer payload
    let twice_outer = mutate(&lir, |l| l.contains("i payload v6 p3 e1 1"), true);
    let err_move_outer = validate_err(&twice_outer);
    assert_diag(
        &err_move_outer,
        "L0007",
        "Place { var: 3, proj: [] }: uso tras movimiento o inicialización parcial",
    );

    // Attack 2.3: Double drop of inner union. Both drops are flagged, so the
    // second one is caught by the flag analysis (flag state Unknown after the
    // first conditional drop), not by the unflagged "doble liberación" rule.
    let double_inner_drop = mutate(&lir, |l| l.contains("i drop v7 v14"), true);
    let err_inner_drop = validate_err(&double_inner_drop);
    assert_diag(
        &err_inner_drop,
        "L0017",
        "flag v14 = Unknown no coincide con la propiedad de Place { var: 7, proj: [] }",
    );

    // Attack 2.4: Double drop of outer union
    let double_outer_drop = mutate(&lir, |l| l.contains("i drop v3 v13"), true);
    let err_outer_drop = validate_err(&double_outer_drop);
    assert_diag(
        &err_outer_drop,
        "L0017",
        "flag v13 = Unknown no coincide con la propiedad de Place { var: 3, proj: [] }",
    );

    // Attack 2.5: Tamper inner drop flag: cb0 -> cb1 after payload move-out
    let forged_inner_flag = lir.replacen("i use v14 cb0 @8:26", "i use v14 cb1 @8:26", 1);
    assert_ne!(forged_inner_flag, lir);
    let err_inner_flag = validate_err(&forged_inner_flag);
    assert_diag(
        &err_inner_flag,
        "L0017",
        "flag v14 = On no coincide con la propiedad de Place { var: 7, proj: [] }",
    );

    // Self-hosted ELE verifier rejects nested enum mutations
    // Fault 14: wrong variant payload -> Rule 3
    stage1_fault("nested_fault14.l", NESTED_ENUM_COND, 14, 3);
    // Fault 15: unflagged drop of conditionally moved union -> Rule 6
    stage1_fault("nested_fault15.l", NESTED_ENUM_COND, 15, 6);
    // Fault 16: use after payload consumed union -> Rule 5
    stage1_fault("nested_fault16.l", NESTED_ENUM_COND, 16, 5);
    // Fault 17: forged cb1 double free -> Rule 6
    stage1_fault("nested_fault17.l", NESTED_ENUM_COND, 17, 6);
    // Fault 18: forged cb0 leak -> Rule 6
    stage1_fault("nested_fault18.l", NESTED_ENUM_COND, 18, 6);
}

#[test]
fn test_loop_and_diamond_cfg_joins_with_unions() {
    let lir = emit("loop_cfg.l", LOOP_AND_DIAMOND_CFG);
    validate(&lir).expect("clean loop and diamond cfg must validate");

    // Attack 2.6: Diamond join flag tampering: cb0 -> cb1 after branch move
    let forged_diamond_df = lir.replacen("i use v8 cb0 @6:18", "i use v8 cb1 @6:18", 1);
    assert_ne!(forged_diamond_df, lir);
    let err_diamond = validate_err(&forged_diamond_df);
    assert_diag(
        &err_diamond,
        "L0017",
        "flag v8 = On no coincide con la propiedad de Place { var: 2, proj: [] }",
    );

    // Attack 2.7: Loop back-edge flag corruption: cb0 -> cb1 in loop body
    let forged_loop_df = lir.replacen("i use v11 cb0 @16:18", "i use v11 cb1 @16:18", 1);
    assert_ne!(forged_loop_df, lir);
    let err_loop = validate_err(&forged_loop_df);
    assert_diag(
        &err_loop,
        "L0017",
        "flag v11 = On no coincide con la propiedad de Place { var: 4, proj: [] }",
    );

    // Attack 2.8: Loop duplicate drop
    let double_loop_drop = mutate(&lir, |l| l.contains("i drop v4 v11"), true);
    let err_loop_drop = validate_err(&double_loop_drop);
    assert_diag(
        &err_loop_drop,
        "L0017",
        "flag v11 = Unknown no coincide con la propiedad de Place { var: 4, proj: [] }",
    );

    // Self-hosted ELE verifier on loops and diamond CFG joins
    stage1_fault("loop_fault15.l", LOOP_AND_DIAMOND_CFG, 15, 6);
    stage1_fault("loop_fault16.l", LOOP_AND_DIAMOND_CFG, 16, 5);
    stage1_fault("loop_fault17.l", LOOP_AND_DIAMOND_CFG, 17, 6);
    stage1_fault("loop_fault18.l", LOOP_AND_DIAMOND_CFG, 18, 6);
}

// =========================================================================
// Category 3: Forjado de operandos no inicializados y lecturas después de mover
// =========================================================================

#[test]
fn test_forged_uninitialized_operands_fail_closed() {
    let lir = emit("simple_arith.l", SIMPLE_ARITH);
    validate(&lir).expect("clean simple arith must validate");

    // Attack 3.1: Read unassigned variable v3 in binary operation before it is defined
    let forged_uninit = lir.replacen(
        "i binary v2 add v0 v1 @3:13",
        "i binary v2 add v3 v1 @3:13",
        1,
    );
    assert_ne!(forged_uninit, lir);
    let err_uninit = validate_err(&forged_uninit);
    assert_diag(
        &err_uninit,
        "L0007",
        "v3 se usa antes de asignarse en alguna ruta",
    );

    // Attack 3.2: Self-use of v4 before initialization
    let forged_self = lir.replacen(
        "i use v4 ct5:104,101,108,108,111 @4:5",
        "i use v4 v4 @4:5",
        1,
    );
    assert_ne!(forged_self, lir);
    let err_self = validate_err(&forged_self);
    assert_diag(
        &err_self,
        "L0007",
        "v4 se usa antes de asignarse en alguna ruta",
    );

    // Self-hosted ELE verifier rejects use of unassigned variable (Fault 4 -> Rule 5)
    stage1_fault("simple_fault4.l", SIMPLE_ARITH, 4, 5);
}

#[test]
fn test_read_and_use_after_move_fail_closed() {
    let lir = emit("loop_cfg_reads.l", LOOP_AND_DIAMOND_CFG);
    validate(&lir).expect("clean cfg must validate");

    // Attack 3.3: Place read (i disc) of consumed place p2 after payload extraction into Int variable v3
    let forged_disc_consumed = insert_inst_after(
        &lir,
        |l| l.contains("i use v6 v5 @6:13"),
        "i disc v3 p2 @6:13",
    );
    let err_disc = validate_err(&forged_disc_consumed);
    assert_diag(
        &err_disc,
        "L0007",
        "Place { var: 2, proj: [] }: uso tras movimiento o inicialización parcial",
    );

    // Attack 3.4: Place loan (i loan) of consumed place p2 after payload extraction
    // Attempting to borrow a place whose root was consumed by payload
    let forged_payload_twice = mutate(&lir, |l| l.contains("i payload v5 p2 e0 1"), true);
    let err_payload = validate_err(&forged_payload_twice);
    assert_diag(
        &err_payload,
        "L0007",
        "Place { var: 2, proj: [] }: uso tras movimiento o inicialización parcial",
    );

    // Attack 3.5: By-value Text use after move into function call in SIMPLE_ARITH
    let lir_arith = emit("arith_use_move.l", SIMPLE_ARITH);
    // In SIMPLE_ARITH, v4 (Text) is passed by value to f0 at `i call v5 f0 1 val v4 @5:5`
    // Inserting another use of v4 `i call v5 f0 1 val v4 @5:5` after it attempts to move v4 twice
    let forged_call_twice = mutate(
        &lir_arith,
        |l| l.contains("i call v5 f0 1 val v4 @5:5"),
        true,
    );
    let err_call_twice = validate_err(&forged_call_twice);
    assert_diag(
        &err_call_twice,
        "L0007",
        "Place { var: 4, proj: [] }: uso tras movimiento o inicialización parcial",
    );

    // Self-hosted ELE verifier rejects use after move (Fault 16 -> Rule 5)
    stage1_fault("diamond_fault16.l", LOOP_AND_DIAMOND_CFG, 16, 5);
}

// =========================================================================
// Category 4: Verificación canónica Fail-Closed en ambos verificadores
// =========================================================================

#[test]
fn test_canonical_fail_closed_error_codes() {
    // 1. Rust validator must consistently reject illegal LIR with canonical diagnostics:
    // a) Structural CFG / definite assignment violation -> L0007
    let lir = emit("simple_canonical.l", SIMPLE_ARITH);
    let forged = lir.replacen(
        "i binary v2 add v0 v1 @3:13",
        "i binary v2 add v3 v1 @3:13",
        1,
    );
    let parsed = project_l::lir_protocol::parse(&forged).expect("protocol parse succeeds");
    let diag =
        project_l::lir_protocol::validate(&parsed).expect_err("must fail closed on unassigned var");
    assert_eq!(
        diag.code, "L0007",
        "Rust validator must emit canonical diagnostic code L0007 for CFG violation"
    );

    // b) Drop flag disagreement / double-free violation -> L0017
    let lir_drop = emit("b_wild_canonical.l", B_WILD);
    let forged_flag = lir_drop.replacen("i use v32 cb0 @22:14", "i use v32 cb1 @22:14", 1);
    let parsed_flag =
        project_l::lir_protocol::parse(&forged_flag).expect("protocol parse succeeds");
    let diag_flag = project_l::lir_protocol::validate(&parsed_flag)
        .expect_err("must fail closed on flag tampering");
    assert_eq!(
        diag_flag.code, "L0017",
        "Rust validator must emit canonical diagnostic code L0017 for drop flag violation"
    );

    // 2. ELE self-hosted verifier must fail closed with error[ICE] (regla N, bloque B)
    // and must NEVER emit unchecked LIR to stdout when verification fails
    for (fault, expected_rule) in [
        (4, 5),  // use of unassigned variable -> Rule 5
        (14, 3), // wrong variant payload -> Rule 3
        (15, 6), // unflagged drop of conditionally moved union -> Rule 6
        (16, 5), // use after move -> Rule 5
        (17, 6), // drop flag cb1 double free -> Rule 6
        (18, 6), // drop flag cb0 leak -> Rule 6
    ] {
        stage1_fault("fail_closed.l", LOOP_AND_DIAMOND_CFG, fault, expected_rule);
    }
}

// =========================================================================
// Category 5: Deleting or duplicating an unconditional drop
// =========================================================================

/// `t` is owned, never moved and released by one unconditional `drop`.
const UNCONDITIONAL_DROP: &str = r#"fn keep(n: Int) -> Int {
    let t = "owned"
    return n
}
fn main() -> Int {
    return keep(7)
}
"#;

fn is_unflagged_drop(line: &str) -> bool {
    line.starts_with("i drop ") && line.split_whitespace().nth(3) == Some("-")
}

#[test]
fn test_deleted_unconditional_drop_is_a_leak_at_return() {
    let lir = emit("unconditional_drop.l", UNCONDITIONAL_DROP);
    validate(&lir).expect("clean unconditional drop must validate");
    assert_eq!(
        lir.lines().filter(|l| is_unflagged_drop(l)).count(),
        1,
        "expected exactly one unflagged drop: {lir}"
    );
    let leaked = mutate(&lir, is_unflagged_drop, false);
    let err = validate_err(&leaked);
    assert_diag(
        &err,
        "L0007",
        "Place { var: 1, proj: [] } sigue poseyendo un valor al retornar: fuga",
    );
}

#[test]
fn test_duplicated_unconditional_drop_is_a_double_free() {
    let lir = emit("unconditional_drop_twice.l", UNCONDITIONAL_DROP);
    let twice = mutate(&lir, is_unflagged_drop, true);
    let err = validate_err(&twice);
    assert_diag(
        &err,
        "L0007",
        "Place { var: 1, proj: [] }: doble liberación",
    );
    assert!(!err.contains("fuga"), "a double free is not a leak: {err}");
}
