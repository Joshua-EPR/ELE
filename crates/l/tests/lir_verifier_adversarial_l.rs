//! Forged ELE-LIR against both LIR verifiers, with the same input.
//!
//! Every case lowers one function of `SRC` with Stage 1, rewrites it with a
//! small patch (replace, insert or delete instructions, replace a
//! terminator) and hands the result to:
//! 1. the Rust validator (`lir_protocol::parse` + `validate`), the patch
//!    applied to the emitted text;
//! 2. the self-hosted ELE verifier (`compiler-l/src/lir_verify.l`), the same
//!    patch applied by `main_sema --lir-patch` to the lowered function just
//!    before verification (`compiler-l/src/lir_patch.l`).
//!
//! An unsafe forgery must be rejected by both, for the property under
//! attack: the Rust diagnostic code and message fragment and the ELE rule
//! are asserted, not just a failure. Safe controls must be accepted by both.

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
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_sema", false))
}

fn temp() -> PathBuf {
    let dir = root().join("target/stage1-tests/lir-verifier-adversarial-l");
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// One source, one function per attack surface. Function ids (`fN`) are the
/// declaration order.
const SRC: &str = r#"struct U {
    n: Text,
    c: Text,
}
struct W {
    a: U,
    k: Text,
}
struct P {
    x: Int,
    y: Int,
}
fn mk(s: Text) -> Text {
    return "{s}!"
}
fn take(t: Text) {
    print(t)
}
fn part() -> Int {
    var u = U(n: mk("n"), c: mk("c"))
    take(u.c)
    return 1
}
fn nest() -> Int {
    var w = W(a: U(n: mk("n"), c: mk("c")), k: mk("k"))
    take(w.a.c)
    return 2
}
fn cond(k: Bool) -> Int {
    let t = mk("t")
    if k {
        take(t)
    }
    return 3
}
fn opt(k: Bool) -> Int {
    let o = Some(mk("o"))
    if k {
        match o {
            Some(s) => { take(s) }
            None => {}
        }
    }
    return 4
}
fn lp(n: Int) -> Int {
    var i = 0
    while i < n {
        let t = mk("l")
        take(t)
        i = i + 1
    }
    return 5
}
fn borrow() -> Int {
    var u = U(n: mk("n"), c: mk("c"))
    let r = &u
    print(r.n)
    return 6
}
fn pick(u: &U) -> &Text {
    return &u.n
}
fn mutb() -> Int {
    var a = mk("a")
    let r = &mut a
    print(r)
    let u = U(n: mk("n"), c: mk("c"))
    let p = pick(&u)
    print(p)
    return 7
}
fn mkres(k: Bool) -> Result<Text, Text> {
    if k { return Ok(mk("ok")) }
    return Err(mk("err"))
}
fn res(k: Bool) -> Int {
    let r = mkres(k)
    match r {
        Ok(t) => { take(t) }
        Err(e) => { print(e) }
    }
    return 8
}
fn lp2(n: Int) -> Int {
    let t = mk("l")
    var i = 0
    while i < n {
        print(t)
        i = i + 1
    }
    return 9
}
fn pick2(u: &U) -> &Text {
    let t = mk("x")
    print(t)
    return &u.n
}
fn fl(n: Int) -> Int {
    var i = 0
    while i < n {
        let u = U(n: mk("ln"), c: mk("lc"))
        if i % 2 == 0 {
            take(u.c)
        }
        i = i + 1
    }
    return 10
}
fn pf(k: Bool) -> Int {
    let t = mk("p")
    take(t)
    return 11
}
fn lst(n: Int) -> Int {
    var xs = List[mk("a")]
    let a = mk("b")
    let r = &a
    xs.push(mk("c"))
    print(r)
    return n
}
fn px(p: &P) -> &Int {
    let q = P(x: 1, y: 2)
    return &p.x
}
fn main() -> Int {
    return part() + nest() + cond(true) + opt(true) + lp(2) + borrow() + mutb() + res(true) + lp2(2) + fl(3) + pf(false)
}
"#;

fn source_path() -> &'static Path {
    static P: OnceLock<PathBuf> = OnceLock::new();
    P.get_or_init(|| {
        let path = temp().join("adversarial.l");
        fs::write(&path, SRC).unwrap();
        path
    })
}

/// The verified LIR Stage 1 emits for `SRC`.
fn baseline() -> &'static str {
    static L: OnceLock<String> = OnceLock::new();
    L.get_or_init(|| {
        let out = Command::new(sema())
            .arg(source_path())
            .arg("--emit-lir")
            .env("PATH", "")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let lir = String::from_utf8(out.stdout).unwrap().replace("\r\n", "\n");
        assert!(lir.starts_with("ELE-LIR 1\n"), "no ELE-LIR header");
        lir
    })
}

/// Apply `ops` (the `lir_patch.l` syntax) to function `func` of `lir`.
fn apply_patch(lir: &str, func: usize, ops: &[&str]) -> String {
    let mut lines: Vec<String> = lir.lines().map(str::to_string).collect();
    let start = lines
        .iter()
        .position(|l| l.starts_with(&format!("func f{func} ")))
        .expect("function to patch");
    for op in ops {
        let words: Vec<&str> = op.splitn(3, ' ').collect();
        let block: usize = words[1].parse().unwrap();
        let end = (start..lines.len())
            .find(|&i| lines[i] == "endfunc")
            .unwrap();
        let header = (start..end)
            .find(|&i| lines[i].starts_with(&format!("block {block} ")))
            .expect("block to patch");
        let count: usize = lines[header].split(' ').nth(2).unwrap().parse().unwrap();
        if words[0] == "term" {
            lines[header + 1 + count] = words[2].to_string();
            continue;
        }
        let (index, inst) = match words[2].split_once(' ') {
            Some((j, rest)) => (j.parse::<usize>().unwrap(), rest),
            None => (words[2].parse::<usize>().unwrap(), ""),
        };
        let at = header + 1 + index;
        let count = match words[0] {
            "set" => {
                assert!(index < count, "{op}");
                lines[at] = inst.to_string();
                count
            }
            "ins" => {
                assert!(index <= count, "{op}");
                lines.insert(at, inst.to_string());
                count + 1
            }
            "del" => {
                assert!(index < count, "{op}");
                lines.remove(at);
                count - 1
            }
            other => panic!("unknown patch operation {other}"),
        };
        lines[header] = format!("block {block} {count}");
    }
    lines.join("\n") + "\n"
}

/// Rust validator: `Ok` or the debug text of the diagnostic.
fn rust_check(lir: &str) -> Result<(), String> {
    let module = project_l::lir_protocol::parse(lir).map_err(|e| format!("{e:?}"))?;
    project_l::lir_protocol::validate(&module).map_err(|e| format!("{e:?}"))
}

/// ELE verifier: `Ok` or the violated rule (`regla N`), with fail-closed
/// output (no LIR on stdout after a rejection).
fn ele_check(name: &str, func: usize, ops: &[&str]) -> Result<(), String> {
    let patch = temp().join(format!("{name}.patch"));
    let mut text = format!("f {func}\n");
    for op in ops {
        text.push_str(op);
        text.push('\n');
    }
    fs::write(&patch, text).unwrap();
    let out = Command::new(sema())
        .arg(source_path())
        .arg("--lir-patch")
        .arg(&patch)
        .env("PATH", "")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();
    if out.status.success() {
        assert!(!stderr.contains("error"), "{name}: {stderr}");
        let lir = String::from_utf8_lossy(&out.stdout).replace("\r\n", "\n");
        // The accepted function is exactly the forged one the Rust validator saw.
        let ours = apply_patch(baseline(), func, ops);
        assert_eq!(
            function_text(&lir, func),
            function_text(&ours, func),
            "{name}: ELE and Rust saw different LIR"
        );
        return Ok(());
    }
    assert!(out.stdout.is_empty(), "{name}: rejected LIR was written");
    assert!(stderr.contains("error[ICE]"), "{name}: {stderr}");
    assert!(
        !stderr.contains("parche de LIR inválido"),
        "{name}: {stderr}"
    );
    Err(stderr)
}

/// A function's text without the `@line:col` suffixes (an inserted
/// instruction borrows a neighbour's position).
fn function_text(lir: &str, func: usize) -> String {
    let mut out = String::new();
    let mut on = false;
    for line in lir.lines() {
        if line.starts_with(&format!("func f{func} ")) {
            on = true;
        }
        if on {
            let line = match line.rsplit_once(" @") {
                Some((head, _)) => head,
                None => line,
            };
            out.push_str(line);
            out.push('\n');
            if line == "endfunc" {
                break;
            }
        }
    }
    out
}

/// Expected verdict of one verifier.
#[derive(Clone, Copy, Debug)]
enum Expect {
    Accept,
    /// Rust: diagnostic code and message fragment.
    Rust(&'static str, &'static str),
    /// ELE: violated rule.
    Rule(usize),
}

struct Case {
    name: &'static str,
    func: usize,
    ops: &'static [&'static str],
    rust: Expect,
    ele: Expect,
}

fn run(case: &Case) {
    let forged = apply_patch(baseline(), case.func, case.ops);
    let rust = rust_check(&forged);
    let ele = ele_check(case.name, case.func, case.ops);
    match (case.rust, &rust) {
        (Expect::Accept, Ok(())) => {}
        (Expect::Rust(code, message), Err(err)) => {
            assert!(
                err.contains(&format!("code: \"{code}\"")) && err.contains(message),
                "{}: Rust expected {code} {message:?}, got {err}",
                case.name
            );
        }
        (want, got) => panic!("{}: Rust expected {want:?}, got {got:?}", case.name),
    }
    match (case.ele, &ele) {
        (Expect::Accept, Ok(())) => {}
        (Expect::Rule(rule), Err(err)) => {
            assert!(
                err.contains(&format!("(regla {rule},")),
                "{}: ELE expected rule {rule}, got {err}",
                case.name
            );
        }
        (want, got) => panic!("{}: ELE expected {want:?}, got {got:?}", case.name),
    }
}

/// Prints both verdicts for every case (`--ignored --nocapture`).
#[test]
#[ignore]
fn probe() {
    for case in CASES {
        let forged = apply_patch(baseline(), case.func, case.ops);
        let rust = rust_check(&forged);
        let ele = ele_check(case.name, case.func, case.ops);
        let short = |r: &Result<(), String>| match r {
            Ok(()) => "ACCEPT".to_string(),
            Err(e) => {
                let line = e.lines().next().unwrap_or("");
                let from = line.find("regla").or(line.find("message")).unwrap_or(0);
                line[from..].chars().take(200).collect()
            }
        };
        println!(
            "{} | rust: {} | ele: {}",
            case.name,
            short(&rust),
            short(&ele)
        );
    }
}

const fn case(
    name: &'static str,
    func: usize,
    ops: &'static [&'static str],
    rust: Expect,
    ele: Expect,
) -> Case {
    Case {
        name,
        func,
        ops,
        rust,
        ele,
    }
}

use Expect::{Accept, Rule, Rust};

const CASES: &[Case] = &[
    // 1. Partial moves.
    case(
        "part_move_field_drop_whole",
        2,
        &["set 0 6 i drop v3 -"],
        Rust(
            "L0007",
            "Place { var: 3, proj: [Field(1)] }: doble liberación",
        ),
        Rule(6),
    ),
    case(
        "part_move_whole_store_field_drop_both",
        2,
        &[
            "set 0 4 i use v2 v3",
            "set 0 5 i read v4 p2.1",
            "set 0 6 i store p3.1 v4",
            "ins 0 7 i dropfield p3.1 -",
            "ins 0 8 i drop v3 -",
            "ins 0 9 i dropfield p2.0 -",
        ],
        Rust(
            "L0007",
            "Place { var: 3, proj: [Field(0)] }: doble liberación",
        ),
        Rule(6),
    ),
    case(
        "nest_moved_inner_drop_parent",
        3,
        &["set 0 9 i dropfield p5.0 -"],
        Rust(
            "L0007",
            "Place { var: 5, proj: [Field(0), Field(1)] }: doble liberación",
        ),
        Rule(6),
    ),
    case(
        "nest_drop_field_of_moved_parent",
        3,
        &["set 0 6 i use v4 v5", "set 0 7 i dropfield p5.0.1 -"],
        Rust(
            "L0007",
            "Place { var: 5, proj: [Field(0), Field(1)] }: doble liberación",
        ),
        Rule(6),
    ),
    case(
        "flag_of_one_field_guards_other",
        14,
        &["set 6 2 i dropfield p6.0 v12", "set 6 4 i dropfield p6.1 -"],
        Rust(
            "L0007",
            "Place { var: 6, proj: [Field(1)] }: doble liberación",
        ),
        Rule(6),
    ),
    case(
        "flag_reused_for_two_places",
        14,
        &["set 6 4 i dropfield p6.0 v12"],
        Rust(
            "L0017",
            "flag v12 = Off no refleja la propiedad de [Place { var: 6, proj: [Field(1)] }, Place { var: 6, proj: [Field(0)] }]",
        ),
        Rule(6),
    ),
    // 2. Control flow.
    case(
        "join_maybe_text_unflagged_drop",
        4,
        &["set 3 0 i drop v2 -"],
        Rust("L0007", "Place { var: 2, proj: [] }: doble liberación"),
        Rule(6),
    ),
    case(
        "early_return_owned_leak",
        4,
        &["term 2 t return ci3"],
        Rust(
            "L0007",
            "Place { var: 2, proj: [] } sigue poseyendo un valor al retornar: fuga",
        ),
        Rule(10),
    ),
    case(
        "control_early_return_after_move",
        4,
        &["term 1 t return ci3"],
        Accept,
        Accept,
    ),
    case(
        "control_early_return_after_drop",
        4,
        &["ins 2 0 i drop v2 -", "term 2 t return ci3"],
        Accept,
        Accept,
    ),
    case(
        "loop_drop_in_body",
        12,
        &["ins 3 3 i drop v2 -"],
        Rust("L0007", "Place { var: 2, proj: [] }: doble liberación"),
        Rule(6),
    ),
    case(
        "loop_flag_cleared_owned_at_head",
        14,
        &["del 6 2"],
        Rust(
            "L0007",
            "Place { var: 6, proj: [Field(1)] } sigue poseyendo un valor al retornar: fuga",
        ),
        Rule(6),
    ),
    case(
        "loop_flag_kept_after_drop",
        14,
        &["del 6 3"],
        Rust(
            "L0017",
            "flag v12 = Unknown no refleja la propiedad de [Place { var: 6, proj: [Field(1)] }] al salir del bloque",
        ),
        Rule(6),
    ),
    // 3. Forged flags.
    case(
        "flag_on_while_moved",
        4,
        &["set 1 1 i use v4 cb1"],
        Rust(
            "L0017",
            "flag v4 = On no refleja la propiedad de [Place { var: 2, proj: [] }] al salir del bloque",
        ),
        Rule(6),
    ),
    case(
        "flag_never_initialized",
        4,
        &["del 0 3", "del 0 0", "del 1 1", "del 3 1"],
        Rust("L0007", "v4 se usa antes de asignarse en alguna ruta"),
        Rule(6),
    ),
    case(
        "flag_wrong_type",
        4,
        &["set 3 0 i drop v2 v3"],
        Rust("L0007", "drop flag: se esperaba Bool, encontrado Unit"),
        Rule(6),
    ),
    case(
        "flag_is_bool_parameter",
        15,
        &["ins 0 3 i drop v2 v0"],
        Rust("L0017", "v0 es un parámetro y no puede ser un drop flag"),
        Rule(6),
    ),
    case(
        "flag_set_in_one_predecessor",
        4,
        &["del 1 1"],
        Rust(
            "L0017",
            "flag v4 = On no refleja la propiedad de [Place { var: 2, proj: [] }] al salir del bloque",
        ),
        Rule(6),
    ),
    case(
        "flag_forged_nonconstant_at_join",
        4,
        &["ins 3 0 i binary v4 eq ci1 ci1"],
        Rust(
            "L0017",
            "flag v4 = Forged no coincide con la propiedad de Place { var: 2, proj: [] }",
        ),
        Rule(6),
    ),
    // 4. Loans.
    case(
        "drop_while_view_loan_live",
        7,
        &["ins 0 5 i dropfield p3.0 -", "del 0 8"],
        Rust(
            "L0017",
            "v4: préstamo usado tras mover o liberar Place { var: 3, proj: [] }",
        ),
        Rule(5),
    ),
    case(
        "move_and_drop_while_loan_live",
        7,
        &[
            "ins 0 5 i use v2 v3",
            "ins 0 6 i drop v2 -",
            "del 0 8",
            "del 0 8",
        ],
        Rust(
            "L0017",
            "v4: préstamo usado tras mover o liberar Place { var: 3, proj: [] }",
        ),
        Rule(5),
    ),
    // Aliasing alone: no ELE-LIR 1 instruction frees or moves a value
    // through a reference except a list mutation (next cases).
    case(
        "two_edit_loans",
        9,
        &["ins 0 3 i loan v7 p1 1"],
        Accept,
        Accept,
    ),
    case(
        "list_element_loan_then_push",
        16,
        &["set 0 5 i loan v6 p3[v0] 0"],
        Rust(
            "L0017",
            "v6: préstamo de un elemento usado tras modificar su lista",
        ),
        Rule(5),
    ),
    case(
        "control_list_element_loan_after_push",
        16,
        &["del 0 5", "ins 0 7 i loan v6 p3[v0] 0"],
        Accept,
        Accept,
    ),
    case(
        "return_loan_of_dropped_local",
        13,
        &["set 0 3 i loan v3 p2 0"],
        Rust(
            "L0017",
            "v3: préstamo usado tras mover o liberar Place { var: 2, proj: [] }",
        ),
        Rule(5),
    ),
    case(
        "return_loan_of_copy_local",
        17,
        &["set 0 2 i loan v3 p2.0 0"],
        Rust(
            "L0017",
            "returnref v3 devuelve un préstamo de una variable local",
        ),
        Rule(7),
    ),
    // 5. Owned unions (Option/Result).
    case(
        "union_drop_after_payload_move",
        11,
        &["ins 2 3 i drop v2 -"],
        Rust("L0007", "Place { var: 2, proj: [] }: doble liberación"),
        Rule(6),
    ),
    // The payload read is guarded at run time by a discriminant check.
    case(
        "union_payload_of_inactive_variant",
        11,
        &["set 2 0 i payload v5 p2 e0 1"],
        Accept,
        Accept,
    ),
    case(
        "union_maybe_unflagged_drop",
        5,
        &["set 3 0 i drop v3 -"],
        Rust("L0007", "Place { var: 3, proj: [] }: doble liberación"),
        Rule(6),
    ),
    case(
        "union_drop_after_move",
        11,
        &["ins 0 2 i drop v1 -"],
        Rust("L0007", "Place { var: 1, proj: [] }: doble liberación"),
        Rule(6),
    ),
    case(
        "union_flag_on_after_payload_move",
        5,
        &["set 5 1 i use v9 cb1"],
        Rust(
            "L0017",
            "flag v9 = On no coincide con la propiedad de Place { var: 3, proj: [] }",
        ),
        Rule(6),
    ),
    case(
        "union_forged_flag_at_join",
        5,
        &["ins 3 0 i binary v9 eq ci1 ci1"],
        Rust(
            "L0017",
            "flag v9 = Forged no coincide con la propiedad de Place { var: 3, proj: [] }",
        ),
        Rule(6),
    ),
    case(
        "leak_deleted_field_drop",
        2,
        &["del 0 6"],
        Rust(
            "L0007",
            "Place { var: 3, proj: [Field(0)] } sigue poseyendo un valor al retornar: fuga",
        ),
        Rule(10),
    ),
    case(
        "control_identity",
        4,
        &["set 3 0 i drop v2 v4"],
        Accept,
        Accept,
    ),
];

#[test]
fn forged_lir_is_judged_identically_by_both_verifiers() {
    // Every case runs; the failures are reported together.
    let failed: Vec<&str> = CASES
        .iter()
        .filter(|c| std::panic::catch_unwind(|| run(c)).is_err())
        .map(|c| c.name)
        .collect();
    assert!(failed.is_empty(), "failed cases: {failed:?}");
}
