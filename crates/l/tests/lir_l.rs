//! ELE LIR written by Stage 1 (`sema-l --emit-lir`, compiled by Cranelift
//! from L sources) and compiled by the provisional backend
//! (`l build-lir`), compared with Stage 0 compiling the same source.
//!
//! The front end, ownership, borrow checking, drop elaboration, lowering,
//! LIR verification and serialization all run in the Stage 1 binary (with an
//! empty PATH). The backend only parses the protocol, re-validates the block
//! LIR and generates code: it never runs the Rust front end.
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

fn case_dir(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/stage1-tests/lir")
        .join(name);
    fs::create_dir_all(&dir).unwrap();
    dir
}

struct Output {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

fn exec(cmd: &mut Command) -> Output {
    let o = cmd.output().unwrap();
    Output {
        code: o.status.code(),
        stdout: String::from_utf8_lossy(&o.stdout).to_string(),
        stderr: String::from_utf8_lossy(&o.stderr).to_string(),
    }
}

/// Stage 1: source -> LIR text, run natively with an empty PATH.
fn emit_lir(name: &str, source: &str, flag: &str) -> Output {
    let dir = case_dir(name);
    let file = dir.join(format!("{name}.l"));
    fs::write(&file, source).unwrap();
    exec(
        Command::new(sema_exe())
            .arg(&file)
            .arg(flag)
            .env("PATH", ""),
    )
}

/// Provisional backend: LIR -> executable (traced), then run it.
fn build_and_run_lir(name: &str, lir: &str) -> (Output, Output) {
    let dir = case_dir(name);
    let file = dir.join(format!("{name}.lir"));
    fs::write(&file, lir).unwrap();
    let build = exec(
        Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(&dir)
            .args(["build-lir"])
            .arg(&file)
            .arg("--trace-alloc"),
    );
    assert_eq!(
        build.code,
        Some(0),
        "{name}: {}{}",
        build.stdout,
        build.stderr
    );
    let exe = dir.join(
        build
            .stdout
            .lines()
            .find_map(|l| l.strip_prefix("Build: "))
            .unwrap(),
    );
    (build, exec(&mut Command::new(exe)))
}

/// Stage 0 reference: the same source through the Rust compiler.
fn run_stage0(name: &str, source: &str) -> Output {
    let dir = case_dir(&format!("{name}-stage0"));
    let file = dir.join(format!("{name}.l"));
    fs::write(&file, source).unwrap();
    let build = exec(
        Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(&dir)
            .args(["build"])
            .arg(&file)
            .args(["--backend", "cranelift", "--trace-alloc"]),
    );
    assert_eq!(build.code, Some(0), "{name} stage0: {}", build.stderr);
    let exe = dir.join(
        build
            .stdout
            .lines()
            .find_map(|l| l.strip_prefix("Build: "))
            .unwrap(),
    );
    exec(&mut Command::new(exe))
}

/// Program output without the allocation trace line.
fn program_stderr(stderr: &str) -> String {
    stderr
        .lines()
        .filter(|l| !l.starts_with("l-alloc: "))
        .collect::<Vec<_>>()
        .join("\n")
}

fn compare(name: &str, source: &str) {
    let lir = emit_lir(name, source, "--emit-lir");
    assert_eq!(lir.code, Some(0), "{name}: {}", lir.stderr);
    assert!(
        lir.stdout.starts_with("ELE-LIR 1\n"),
        "{name}: {}",
        lir.stdout
    );
    let (_, one) = build_and_run_lir(name, &lir.stdout);
    let zero = run_stage0(name, source);
    assert_eq!(one.stdout, zero.stdout, "{name}: stdout\n{}", lir.stdout);
    assert_eq!(one.code, zero.code, "{name}: exit code");
    assert_eq!(
        program_stderr(&one.stderr),
        program_stderr(&zero.stderr),
        "{name}: stderr"
    );
    assert_balanced(name, &one.stderr);
    assert_balanced(name, &zero.stderr);
}

#[test]
fn native_lists_match_stage0() {
    let cases = [
        (
            "list_int",
            "fn main() -> Int { var xs: List<Int> = List[]; xs.push(1); xs.push(2); print(xs.length); return xs[0] + xs[1] }",
        ),
        (
            "list_bool",
            "fn main() -> Int { let xs = List[true, false, true]; if xs[0] && !xs[1] && xs[2] { return 3 }; return 0 }",
        ),
        (
            "list_text",
            "fn main() -> Int { var xs: List<Text> = List[]; xs.push(\"a\"); xs.push(\"b\"); print(xs[1]); return xs.length }",
        ),
        (
            "list_store",
            "fn main() -> Int { var xs = List[1, 2]; xs[1] = 7; return xs[1] }",
        ),
        (
            "list_reserve",
            "fn main() -> Int { var xs: List<Int> = List[]; xs.reserve(20); if xs.capacity < 20 { return 10 }; xs.push(5); return xs.length }",
        ),
        (
            "list_foreach",
            "fn main() -> Int { let xs = List[1, 2, 3]; var n = 0; for x in xs { n += x }; return n }",
        ),
        (
            "list_return",
            "fn make() -> List<Int> { return List[1, 2] } fn main() -> Int { let xs = make(); return xs[0] + xs[1] }",
        ),
        (
            "list_struct",
            "struct S { xs: List<Int> } fn main() -> Int { let s = S(xs: List[1, 2]); return s.xs.length }",
        ),
    ];
    for (name, source) in cases {
        compare(name, source);
    }
}

#[test]
fn compiles_real_flow_cfg_functions_natively() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../compiler-l/src");
    let source = root.join("flow_self_harness.l");
    let lir = exec(
        Command::new(sema_exe())
            .arg(&source)
            .arg("--emit-lir")
            .env("PATH", ""),
    );
    assert_eq!(lir.code, Some(0), "{}", lir.stderr);
    let module = project_l::lir_protocol::parse(&lir.stdout).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();
    assert!(module.funcs.iter().any(|f| f.name == "flowNew"));
    assert!(module.funcs.iter().any(|f| f.name == "flowBlock"));
    let (_, one) = build_and_run_lir("flow_self_harness", &lir.stdout);
    let dir = case_dir("flow_self_harness-stage0");
    let build = exec(
        Command::new(env!("CARGO_BIN_EXE_l"))
            .current_dir(&dir)
            .arg("build")
            .arg(&source)
            .args(["--backend", "cranelift", "--trace-alloc"]),
    );
    assert_eq!(build.code, Some(0), "{}", build.stderr);
    let exe = dir.join(
        build
            .stdout
            .lines()
            .find_map(|l| l.strip_prefix("Build: "))
            .unwrap(),
    );
    let zero = exec(&mut Command::new(exe));
    assert_eq!(one.code, Some(2));
    assert_eq!(one.code, zero.code);
    assert_eq!(one.stdout, zero.stdout);
    assert_eq!(program_stderr(&one.stderr), program_stderr(&zero.stderr));
    assert_balanced("flow_self_harness", &one.stderr);
    assert_balanced("flow_self_harness-stage0", &zero.stderr);
}

#[test]
fn unsupported_list_pop_match_reports_a_diagnostic_not_an_ice() {
    let source = "flow main() {\n    change xs: List of[Int] = List[1, 2]\n    hold x = xs@pop()\n    match x {\n        Some(v) => { print(v) }\n        None => { print(0) }\n    }\n}\n";
    let out = emit_lir("list_pop_option_unsupported", source, "--emit-lir");
    assert_ne!(out.code, Some(0));
    assert!(out.stdout.is_empty(), "{}", out.stdout);
    assert!(out.stderr.contains("error[L0016]"), "{}", out.stderr);
    assert!(!out.stderr.contains("error[ICE]"), "{}", out.stderr);
}

#[test]
fn list_type_and_ownership_errors_are_diagnostics() {
    let cases = [
        (
            "wrong_element",
            "fn main() { var xs: List<Int> = List[]; xs.push(\"bad\") }",
        ),
        (
            "mixed_elements",
            "fn main() { let xs = List[1, true]; print(xs.length) }",
        ),
        (
            "used_after_move",
            "fn take(xs: List<Int>) {} fn main() { let xs = List[1]; take(xs); print(xs.length) }",
        ),
        (
            "immutable_push",
            "fn main() { let xs = List[1]; xs.push(2) }",
        ),
        (
            "owned_element_move",
            "fn main() { let xs = List[\"a\"]; let x = xs[0]; print(x) }",
        ),
        (
            "borrowed_growth",
            "fn main() { var xs = List[1]; let r = &xs[0]; xs.push(2); print(r) }",
        ),
    ];
    for (name, source) in cases {
        let out = emit_lir(name, source, "--emit-lir");
        assert_eq!(out.code, Some(1), "{name}: {}", out.stderr);
        assert!(
            out.stderr.contains("error[L") && !out.stderr.contains("error[ICE]"),
            "{name}: {}",
            out.stderr
        );
    }
}

#[test]
fn owned_list_element_replacement_emits_a_typed_store() {
    let source = "fn main() { var xs = List[\"a\"]; xs[0] = \"b\"; print(xs[0]) }";
    let out = emit_lir("owned_element_replace", source, "--emit-lir");
    assert_eq!(out.code, Some(0), "{}", out.stderr);
    assert!(
        out.stdout.contains("i store p") && out.stdout.contains("[v"),
        "{}",
        out.stdout
    );
}

#[test]
fn list_index_out_of_bounds_traps_natively() {
    let source = "fn main() -> Int { let xs = List[1]; return xs[1] }";
    let lir = emit_lir("list_bounds", source, "--emit-lir");
    assert_eq!(lir.code, Some(0), "{}", lir.stderr);
    let (_, one) = build_and_run_lir("list_bounds", &lir.stdout);
    let zero = run_stage0("list_bounds", source);
    assert_ne!(one.code, Some(0));
    assert_eq!(one.code, zero.code);
    assert!(
        one.stderr.contains("índice fuera de rango"),
        "{}",
        one.stderr
    );
    assert!(
        zero.stderr.contains("índice fuera de rango"),
        "{}",
        zero.stderr
    );
}

#[test]
fn backend_rejects_malformed_list_lir() {
    let source = "fn main() -> Int { var xs: List<Int> = List[]; xs.push(1); return xs.length }";
    let good = emit_lir("list_protocol", source, "--emit-lir");
    assert_eq!(good.code, Some(0), "{}", good.stderr);
    let cases = [
        (
            "bad_list_type",
            good.stdout.replacen("list l0 i", "list l0 t", 1),
        ),
        (
            "bad_literal_count",
            good.stdout
                .replacen("listlit v0 l0 0", "listlit v0 l0 99", 1),
        ),
        (
            "bad_push_type",
            good.stdout
                .replacen("listpush p1 ci1", "listpush p1 ct1:97", 1),
        ),
        (
            "unknown_operation",
            good.stdout.replacen("listpush", "listblow", 1),
        ),
    ];
    for (name, lir) in cases {
        let rejected = match project_l::lir_protocol::parse(&lir) {
            Err(_) => true,
            Ok(module) => project_l::lir_protocol::validate(&module).is_err(),
        };
        assert!(rejected, "{name}");
        let dir = case_dir(name);
        let file = dir.join("bad.lir");
        fs::write(&file, &lir).unwrap();
        let out = exec(
            Command::new(env!("CARGO_BIN_EXE_l"))
                .current_dir(&dir)
                .arg("build-lir")
                .arg(&file),
        );
        assert_eq!(out.code, Some(1), "{name}: {}", out.stderr);
        assert!(!out.stderr.contains("panicked"), "{name}: {}", out.stderr);
    }
}

/// Allocation trace: every reservation released and the heap consistent
/// (a program may allocate nothing at all).
fn assert_balanced(name: &str, stderr: &str) {
    let (_, trace) = stderr.rsplit_once("l-alloc: ").expect(stderr);
    let field = |key: &str| -> u64 {
        trace
            .split_whitespace()
            .find_map(|w| w.strip_prefix(key))
            .and_then(|v| v.parse().ok())
            .unwrap_or_else(|| panic!("{name}: missing {key}: {trace}"))
    };
    assert_eq!(field("allocs="), field("frees="), "{name}: {trace}");
    assert_eq!(field("heap_ok="), 1, "{name}: {trace}");
}

/// Runnable programs covering the Stage 1 LIR subset.
pub const PROGRAMS: &[(&str, &str)] = &[
    ("empty_main", "fn main() {}"),
    ("return_int", "fn main() -> Int {\n return 7\n}"),
    (
        "first_program",
        "fn main() -> Int {\n    let numero = 40 + 2\n\n    print(numero)\n\n    return 0\n}",
    ),
    (
        "arithmetic",
        "fn main() {\n let a = 7\n let b = 3\n print(a + b * 2 - 1)\n print(a / b)\n print(a % b)\n print(-a)\n}",
    ),
    (
        "comparisons",
        "fn main() {\n let a = 2\n print(a < 3)\n print(a >= 3)\n print(a == 2)\n print(a != 2)\n print(!(a > 1))\n print(true == false)\n}",
    ),
    (
        "variables_assign",
        "fn main() {\n var x = 1\n x = x + 4\n x += 2\n x -= 1\n x *= 3\n print(x)\n}",
    ),
    (
        "if_else",
        "fn sign(n: Int) -> Int {\n if n > 0 { return 1 } else if n < 0 { return -1 }\n return 0\n}\nfn main() {\n print(sign(5))\n print(sign(-2))\n print(sign(0))\n}",
    ),
    (
        "while_loop",
        "fn main() {\n var i = 0\n var s = 0\n while i < 10 { s = s + i\n i = i + 1 }\n print(s)\n}",
    ),
    (
        "for_loop_continue",
        "fn main() {\n var s = 0\n for i in 0..10 { if i % 2 == 0 { continue }\n s = s + i }\n print(s)\n}",
    ),
    (
        "nested_loops_break",
        "fn main() {\n var n = 0\n for i in 0..5 { var j = 0\n while true { if j == i { break }\n n = n + 1\n j = j + 1 } }\n print(n)\n}",
    ),
    (
        "loop_break",
        "fn main() {\n var i = 0\n loop { i = i + 3\n if i > 10 { break } }\n print(i)\n}",
    ),
    (
        "params_calls",
        "fn add(a: Int, b: Int) -> Int = a + b\nfn twice(n: Int) -> Int { return add(n, n) }\nfn main() {\n print(twice(add(2, 3)))\n}",
    ),
    (
        "recursion",
        "fn fib(n: Int) -> Int {\n if n < 2 { return n }\n return fib(n - 1) + fib(n - 2)\n}\nfn main() {\n print(fib(15))\n}",
    ),
    (
        "early_return_drops",
        "fn f(c: Bool) -> Int {\n let a = \"x\"\n var b = \"y\"\n if c { return 2 }\n print(a)\n return 1\n}\nfn main() {\n print(f(true))\n print(f(false))\n}",
    ),
    (
        "short_circuit",
        "fn yes(n: Int) -> Bool { print(n)\n return true }\nfn no(n: Int) -> Bool { print(n)\n return false }\nfn main() {\n if no(1) && yes(2) { print(9) }\n if yes(3) || no(4) { print(8) }\n print(no(5) || yes(6))\n}",
    ),
    (
        "text_values",
        "fn main() {\n let t = \"hola\\n\"\n print(t)\n let u = \"á\\u{1F600}\"\n print(u)\n print(\"lit\")\n}",
    ),
    (
        "interpolation",
        "fn mk() -> Text = \"q\"\nfn main() {\n let n = 3\n let t = \"x\"\n print(\"a{n}b{t}c{mk()}{true}\")\n let s = \"{{lit}}\"\n print(s)\n}",
    ),
    (
        "move_text",
        "fn take(t: Text) -> Int { print(t)\n return 1 }\nfn main() {\n let a = \"x\"\n let b = a\n print(take(b))\n}",
    ),
    (
        "reassign_text",
        "fn main() {\n var a = \"x\"\n a = \"y\"\n a = \"{a}z\"\n print(a)\n}",
    ),
    (
        "conditional_drop",
        "fn take(t: Text) -> Int = 1\nfn f(c: Bool) {\n var b = \"y\"\n if c { take(b); }\n b = \"z\"\n print(b)\n}\nfn main() {\n f(true)\n f(false)\n}",
    ),
    (
        "partial_move",
        "struct U { n: Text, c: Text, e: Int }\nfn take(t: Text) -> Int { print(t)\n return 1 }\nfn main() {\n let u = U(n: \"a\", c: \"b\", e: 1)\n let n = u.n\n print(u.c)\n print(u.e)\n print(take(n))\n}",
    ),
    (
        "nested_struct_maybe",
        "struct I { a: Text, b: Text }\nstruct O { i: I, t: Text }\nfn take(t: Text) -> Int = 1\nfn f(k: Bool) {\n let o = O(i: I(a: \"1\", b: \"2\"), t: \"3\")\n if k { take(o.i.a); }\n print(o.t)\n}\nfn main() {\n f(true)\n f(false)\n}",
    ),
    (
        "struct_fields",
        "struct P { x: Int, y: Int }\nfn norm(p: P) -> Int = p.x * p.x + p.y * p.y\nfn main() {\n var p = P(x: 3, y: 4)\n p.x = p.x + 1\n print(norm(p))\n}",
    ),
    (
        "field_reassign",
        "struct U { n: Text, c: Text }\nfn take(t: Text) -> Int = 1\nfn f(k: Bool) {\n var u = U(n: \"a\", c: \"b\")\n u.c = \"z\"\n if k { take(u.n); }\n u = U(n: \"x\", c: \"y\")\n print(u.n)\n}\nfn main() {\n f(true)\n f(false)\n}",
    ),
    (
        "shared_refs",
        "fn main() {\n let x = 5\n let a = &x\n let b = &x\n print(a + b)\n}",
    ),
    (
        "mutable_ref_write",
        "fn bump(n: &mut Int) { n = n + 1 }\nfn main() {\n var x = 1\n bump(&mut x)\n let r = &mut x\n r = r * 10\n print(x)\n}",
    ),
    (
        "text_mut_ref",
        "fn set(t: &mut Text) { t = \"nuevo\" }\nfn main() {\n var t = \"viejo\"\n set(&mut t)\n print(t)\n}",
    ),
    (
        "struct_mut_ref",
        "struct U { n: Text, c: Int }\nfn g(u: &mut U) { u.c = 3\n u.n = \"w\" }\nfn main() {\n var u = U(n: \"q\", c: 2)\n g(&mut u)\n print(u.n)\n print(u.c)\n}",
    ),
    (
        "borrowed_return",
        "fn pick(c: Bool, a: &Int, b: &Int) -> &Int {\n if c { return a }\n return &b\n}\nfn main() {\n let x = 1\n let y = 2\n let r = pick(false, &x, &y)\n print(r)\n}",
    ),
    (
        "implicit_shared_arg",
        "fn show(t: &Text) -> Int { print(t)\n return 0 }\nfn main() {\n let t = \"hola\"\n show(t);\n print(t)\n}",
    ),
    (
        "loop_owned_locals",
        "fn main() {\n var i = 0\n while i < 3 { let t = \"w\"\n if i == 1 { i = i + 1\n continue }\n let s = \"{t}{i}\"\n print(s)\n i = i + 1 }\n}",
    ),
    (
        "temporaries",
        "fn mk() -> Text = \"q\"\nfn main() {\n mk();\n print(mk())\n print(\"{mk()}{mk()}\")\n}",
    ),
    (
        "constants",
        "const LIMIT = 4\nconst NAME = \"ele\"\nfn main() {\n print(LIMIT * 2)\n print(NAME)\n}",
    ),
    (
        "exit_code",
        "fn main() -> Int {\n var s = 0\n for i in 1..5 { s = s + i }\n return s\n}",
    ),
];

#[test]
fn stage1_lir_runs_like_stage0() {
    for (name, source) in PROGRAMS {
        compare(name, source);
    }
}

#[test]
fn projected_text_length_uses_byte_length_in_backend() {
    compare(
        "projected_text_len",
        "struct Boxed { value: Text }\nfn main() -> Int { let boxed = Boxed(value: \"é\"); return boxed.value.byteLength }",
    );
}

/// Compiles every accepted borrow-checker and drop program from Stage 1
/// LIR: the backend re-validates the block LIR and its ownership (no use
/// after move, no double drop, no leak) before generating code. Programs
/// using constructs outside LIR v1 (for example arrays) are rejected by Stage 1
/// with L0016, never with an internal error. Runnable programs are also
/// executed against Stage 0.
#[test]
fn stage1_lir_compiles_the_borrow_and_drop_corpora() {
    let mut compiled = 0;
    let mut outside = Vec::new();
    let mut cases: Vec<(String, String)> = Vec::new();
    for (name, source, stage1, _) in stage1_support::borrow_cases::CASES {
        if *stage1 == "OK" {
            cases.push((format!("borrow_{name}"), source.to_string()));
        }
    }
    for (name, body) in stage1_support::drop_cases::DROP_CASES {
        let source = format!(
            "{}{body}\nfn main() {{}}",
            stage1_support::drop_cases::PRELUDE
        );
        cases.push((format!("drop_{name}"), source));
    }
    for (name, source) in &cases {
        let lir = emit_lir(name, source, "--emit-lir");
        if lir.code != Some(0) {
            assert!(
                lir.stderr.contains("error[L0016]") && !lir.stderr.contains("ICE"),
                "{name}: {}",
                lir.stderr
            );
            outside.push(name.clone());
            continue;
        }
        let (_, one) = build_and_run_lir(name, &lir.stdout);
        let zero = run_stage0(name, source);
        assert_eq!(one.stdout, zero.stdout, "{name}");
        assert_eq!(one.code, zero.code, "{name}");
        compiled += 1;
    }
    println!("compiled {compiled}, outside LIR v1: {outside:?}");
    assert!(compiled >= 110, "{compiled}");
}

#[test]
fn invalid_programs_are_rejected_before_lir() {
    let cases = [
        ("type_mismatch", "fn main() { let x: Int = true }", "L0003"),
        (
            "use_after_move",
            "fn take(t: Text) -> Int = 1\nfn main() { let a = \"x\"\n take(a);\n print(a)\n}",
            "L0005",
        ),
        (
            "maybe_uninitialized",
            "fn take(t: Text) -> Int = 1\nfn main() { let a = \"x\"\n if true { take(a); }\n print(a)\n}",
            "L0005",
        ),
        (
            "incompatible_borrow",
            "fn main() { var x = 1\n let r = &x\n x = 2\n print(r)\n}",
            "L0012",
        ),
        (
            "dangling_return",
            "fn f() -> &Int { let x = 1\n return &x }\nfn main() {}",
            "L0013",
        ),
        (
            "immutable_assign",
            "fn main() { let x = 1\n x = 2\n}",
            "L0006",
        ),
        ("unknown_name", "fn main() { print(nada)\n}", "L0001"),
        ("outside_lir_v1", "fn main() { let l = List[]\n}", "L0016"),
    ];
    for (name, source, code) in cases {
        let out = emit_lir(name, source, "--emit-lir");
        assert_eq!(out.code, Some(1), "{name}: {}", out.stdout);
        assert!(
            out.stdout.is_empty(),
            "{name}: LIR written for an invalid program"
        );
        assert!(
            out.stderr.contains(&format!("error[{code}]")),
            "{name}: {}",
            out.stderr
        );
        assert!(!out.stderr.contains("ICE"), "{name}: {}", out.stderr);
    }
}

#[test]
fn lir_verifier_rejects_corrupted_functions() {
    // Each fault corrupts a verified function in one way (lir_module.l).
    let source = "fn take(t: Text) -> Int = 1\nstruct P { x: Int, t: Text }\nfn f(c: Bool) -> Int {\n var p = P(x: 1, t: \"a\")\n p.x = p.x + 2\n if c { take(p.t); }\n return p.x\n}\nfn main() -> Int {\n var s = 0\n for i in 0..3 { s = s + f(i == 1) }\n return s\n}";
    let ok = emit_lir("fault_none", source, "--emit-lir");
    assert_eq!(ok.code, Some(0), "{}", ok.stderr);
    for (fault, rule) in [
        (1, 1),
        (2, 2),
        (3, 3),
        (4, 5),
        (5, 4),
        (6, 6),
        (7, 7),
        (8, 8),
    ] {
        let out = emit_lir(
            &format!("fault_{fault}"),
            source,
            &format!("--lir-fault={fault}"),
        );
        assert_eq!(out.code, Some(1), "fault {fault}: {}", out.stdout);
        assert!(
            out.stderr.contains("error[ICE]")
                && out.stderr.contains(&format!("LIR inválida (regla {rule},")),
            "fault {fault}: {}",
            out.stderr
        );
    }
}

#[test]
fn lir_emission_is_deterministic_and_parses() {
    let (name, source) = PROGRAMS[PROGRAMS.len() - 4];
    let first = emit_lir(name, source, "--emit-lir");
    let second = emit_lir(name, source, "--emit-lir");
    assert_eq!(first.code, Some(0));
    assert_eq!(first.stdout, second.stdout);
    let module = project_l::lir_protocol::parse(&first.stdout).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();
    assert_eq!(module.funcs[module.main].name, "main");
}

#[test]
fn backend_rejects_malformed_lir_without_crashing() {
    let good = emit_lir("proto_base", "struct P { x: Int, t: Text }\nfn main() -> Int {\n let p = P(x: 2, t: \"z\")\n print(p.t)\n return p.x\n}", "--emit-lir").stdout;
    assert!(project_l::lir_protocol::parse(&good).is_ok());
    let mutate = |from: &str, to: &str| -> String {
        assert!(good.contains(from), "{from}");
        good.replacen(from, to, 1)
    };
    let cases: Vec<(&str, String)> = vec![
        ("version", mutate("ELE-LIR 1", "ELE-LIR 2")),
        (
            "truncated",
            good.lines().take(8).collect::<Vec<_>>().join("\n"),
        ),
        ("trailing", format!("{good}extra\n")),
        ("unknown_inst", mutate("i print", "i jump")),
        (
            "var_out_of_range",
            mutate("i print ref p", "i print ref p99"),
        ),
        ("block_out_of_range", mutate("t unreachable", "t jump 7")),
        ("int_overflow", mutate("ci2", "ci99999999999999999999")),
        ("bad_bytes", mutate("ct1:122", "ct2:122")),
        ("bad_utf8", mutate("ct1:122", "ct1:255")),
        ("bad_field", mutate(" p1.1 0", " p1.7 0")),
        ("huge_count", mutate("vars 3", "vars 99999999999")),
        ("bad_separator", mutate("i print", "i  print")),
        ("type_mismatch", mutate("i read v2 p1.0", "i read v2 p1.1")),
        ("double_drop", {
            let line = good
                .lines()
                .find(|l| l.starts_with("i dropfield"))
                .unwrap()
                .to_string();
            good.replacen(
                &line,
                &format!(
                    "{line}
{line}"
                ),
                1,
            )
            .replacen("block 0 5", "block 0 6", 1)
        }),
        ("leak", {
            let line = good
                .lines()
                .find(|l| l.starts_with("i dropfield"))
                .unwrap()
                .to_string();
            good.replacen(
                &format!(
                    "{line}
"
                ),
                "",
                1,
            )
            .replacen("block 0 5", "block 0 4", 1)
        }),
    ];
    for (name, lir) in cases {
        let parsed = project_l::lir_protocol::parse(&lir);
        let rejected = match parsed {
            Err(e) => {
                assert!(!e.message.is_empty());
                true
            }
            Ok(module) => project_l::lir_protocol::validate(&module).is_err(),
        };
        assert!(rejected, "{name} accepted");
        let dir = case_dir("protocol");
        let file = dir.join(format!("{name}.lir"));
        fs::write(&file, &lir).unwrap();
        let out = exec(
            Command::new(env!("CARGO_BIN_EXE_l"))
                .current_dir(&dir)
                .arg("build-lir")
                .arg(&file),
        );
        assert_eq!(out.code, Some(1), "{name}: {}", out.stderr);
        assert!(
            out.stderr.contains(&format!("{name}.lir:")),
            "{name}: {}",
            out.stderr
        );
        assert!(!out.stderr.contains("panicked"), "{name}: {}", out.stderr);
    }
}
