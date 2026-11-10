//! Native memory safety: dynamic Text, drops on every control path, moves,
//! allocation failure. Every positive program is built with the rustc backend
//! (reference output) and with the Cranelift backend instrumented with
//! `--trace-alloc`, which counts heap operations, validates every pointer
//! before freeing it and validates the whole heap at exit. A program passes
//! only if outputs match, every allocation was freed exactly once and the heap
//! is intact.
use project_l::{
    Span,
    cfg::{self, Inst, InstKind},
    linker, native,
};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/memory")
        .join(name);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn cli(dir: &Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(dir)
        .args(args)
        .output()
        .expect("CLI")
}

fn build(dir: &Path, file: &str, extra: &[&str]) -> PathBuf {
    let mut args = vec!["build", file];
    args.extend_from_slice(extra);
    let out = cli(dir, &args);
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{file} {extra:?}: {stdout}{}",
        String::from_utf8_lossy(&out.stderr)
    );
    dir.join(
        stdout
            .lines()
            .find_map(|l| l.strip_prefix("Build: "))
            .unwrap(),
    )
}

fn run(exe: &Path) -> (String, String, Option<i32>) {
    let out = Command::new(exe).output().unwrap();
    (
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
        out.status.code(),
    )
}

#[derive(Debug, PartialEq)]
struct Stats {
    allocs: u64,
    reallocs: u64,
    frees: u64,
}

fn stats(stderr: &str) -> Stats {
    let line = stderr
        .lines()
        .find(|l| l.starts_with("l-alloc: "))
        .unwrap_or_else(|| panic!("sin informe de memoria: {stderr}"));
    let field = |name: &str| -> u64 {
        line.split_whitespace()
            .find_map(|w| w.strip_prefix(&format!("{name}=")))
            .unwrap()
            .parse()
            .unwrap()
    };
    assert_eq!(field("heap_ok"), 1, "heap corrupto: {line}");
    Stats {
        allocs: field("allocs"),
        reallocs: field("reallocs"),
        frees: field("frees"),
    }
}

/// Builds `source` with both backends; asserts identical stdout and exit
/// status, no leak, no invalid free, intact heap. Returns stdout and stats.
fn check_program(name: &str, source: &str) -> (String, Stats) {
    let dir = work(name);
    let file = format!("{name}.l");
    fs::write(dir.join(&file), source).unwrap();
    let reference = run(&build(&dir, &file, &[]));
    let native = run(&build(
        &dir,
        &file,
        &["--backend", "cranelift", "--trace-alloc"],
    ));
    assert_eq!(reference.0, native.0, "{name}: stdout difiere");
    assert!(reference.1.is_empty(), "{name}: {}", reference.1);
    assert_eq!(native.1.lines().count(), 1, "{name}: {}", native.1);
    assert_eq!(reference.2, native.2, "{name}: código de salida difiere");
    assert_eq!(native.2, Some(0), "{name}: {}", native.1);
    let s = stats(&native.1);
    assert_eq!(
        s.allocs, s.frees,
        "{name}: cada reserva debe liberarse exactamente una vez: {s:?}"
    );
    (native.0, s)
}

#[test]
fn milestone_examples() {
    let (out, s) = check_program(
        "hola_nombre",
        "fn main() {\n    let nombre = \"Ana\"\n    let mensaje = \"Hola {nombre}\"\n\n    print(mensaje)\n}\n",
    );
    assert_eq!(out, "Hola Ana\n");
    assert_eq!(s.allocs, 1);
    let (out, s) = check_program(
        "crear_mensaje",
        "fn crearMensaje(numero: Int) -> Text {\n    return \"Resultado: {numero}\"\n}\n\nfn main() {\n    let mensaje = crearMensaje(42)\n    print(mensaje)\n}\n",
    );
    assert_eq!(out, "Resultado: 42\n");
    assert_eq!(s.allocs, 1);
}

#[test]
fn static_text_is_never_allocated_or_freed() {
    let (out, s) = check_program(
        "static_only",
        "fn eco(t: Text) -> Text = t\nfn main() {\n let a = \"literal\"\n let b = a\n print(eco(b))\n print(\"\")\n print(\"{{llaves}}\")\n}\n",
    );
    assert_eq!(out, "literal\n\n{llaves}\n");
    assert_eq!(
        s,
        Stats {
            allocs: 0,
            reallocs: 0,
            frees: 0
        }
    );
}

#[test]
fn empty_long_and_unicode_text() {
    let (out, _) = check_program(
        "empty",
        "fn vacio() -> Text = \"\"\nfn main() {\n let e = vacio()\n let x = \"{e}\"\n print(x)\n print(\"[{e}{e}]\")\n print(\"{vacio()}\")\n}\n",
    );
    assert_eq!(out, "\n[]\n\n");
    let (out, s) = check_program(
        "long",
        "fn main() {\n var s = \"\"\n for i in 0..3000 {\n  s = \"{s}{i},\"\n }\n print(s)\n}\n",
    );
    assert!(out.len() > 13000, "{}", out.len());
    assert!(out.starts_with("0,1,2,3,") && out.ends_with("2998,2999,\n"));
    // One fresh buffer per iteration, each freed when `s` is overwritten.
    assert!(s.allocs >= 3000, "{s:?}");
    let (out, _) = check_program(
        "unicode",
        "fn main() {\n let n = 7\n let t = \"ñandú 👋 {n} 日本語 {\"é\"}\"\n print(t)\n print(\"{t}|{t}\")\n}\n",
    );
    assert_eq!(
        out,
        "ñandú 👋 7 日本語 é\nñandú 👋 7 日本語 é|ñandú 👋 7 日本語 é\n"
    );
}

#[test]
fn interpolation_forms() {
    let (out, _) = check_program(
        "interpolation",
        r#"fn doble(n: Int) -> Int = n * 2
fn nombre(n: Int) -> Text = "n{n}"
fn main() {
    let a = 5
    let b = true
    print("a={a} b={b} doble={doble(a)} neg={-a} min={-9223372036854775807 - 1}")
    print("anidado: {"{a}-{"{b}"}"} y {nombre(a)}")
    let t = "x{a}"
    let u = "{t}{t}{t}"
    print(u)
    print(t)
}
"#,
    );
    assert_eq!(
        out,
        "a=5 b=true doble=10 neg=-5 min=-9223372036854775808\nanidado: 5-true y n5\nx5x5x5\nx5\n"
    );
}

#[test]
fn moves_scopes_returns_branches_and_loops() {
    let (out, _) = check_program(
        "control_paths",
        r#"fn consume(t: Text) -> Int {
    print(t)
    return 1
}
fn eco(t: Text) -> Text = t
fn temprano(n: Int) -> Text {
    let a = "a{n}"
    let b = "b{n}"
    if n > 2 {
        return a
    }
    if n > 1 {
        return b
    }
    let c = "c{n}"
    return c
}
fn main() {
    // Move then use the new owner only.
    let m = "mov{1}"
    let m2 = eco(m)
    print(m2)
    // Inner scopes release their values.
    {
        let interno = "interno{2}"
        print(interno)
    }
    // Moved on one branch only: dropped through a drop flag otherwise.
    for i in 0..4 {
        let t = "rama{i}"
        if i % 2 == 0 {
            consume(t)
        }
    }
    // Early returns from a function owning several values.
    print(temprano(3))
    print(temprano(2))
    print(temprano(1))
    // break and continue leave the loop body scope.
    var k = 0
    while true {
        k += 1
        let v = "it{k}"
        if k == 2 {
            continue
        }
        if k == 4 {
            break
        }
        print(v)
    }
    // Reassignment releases the previous value.
    var r = "r{1}"
    r = "r{2}"
    r = eco(r)
    print(r)
    // Temporaries of discarded calls are released.
    eco("tmp{9}")
    let mut_loop = 3
    loop {
        let x = "loop{mut_loop}"
        print(x)
        break
    }
}
"#,
    );
    assert_eq!(
        out,
        "mov1\ninterno2\nrama0\nrama2\na3\nb2\nc1\nit1\nit3\nr2\nloop3\n"
    );
}

#[test]
fn text_match_and_borrowed_bindings() {
    let (out, _) = check_program(
        "text_match",
        r#"fn clasifica(t: Text) -> Int = match t {
    "uno" => 1,
    "dos" => 2,
    _ => 0,
}
fn main() {
    let n = 2
    let t = "do{"s"}"
    print(clasifica(t))
    let u = "x{n}"
    match u {
        "x1" => print("no"),
        otro => print("visto {otro}"),
    }
    print(u)
}
"#,
    );
    assert_eq!(out, "2\nvisto x2\nx2\n");
}

#[test]
fn allocation_failure_is_a_clean_panic() {
    let dir = work("oom");
    // Two allocation attempts: one per interpolation (the second part of
    // "{n}{n}" fits in the first buffer).
    let source = "fn main() {\n let n = 1\n print(\"antes\")\n let t = \"{n}{n}\"\n print(t)\n let u = \"{n}\"\n print(u)\n}\n";
    fs::write(dir.join("oom.l"), source).unwrap();
    for (limit, printed) in [("0", "antes\n"), ("1", "antes\n11\n")] {
        let exe = build(
            &dir,
            "oom.l",
            &["--backend", "cranelift", "--alloc-fail-after", limit],
        );
        let (stdout, stderr, code) = run(&exe);
        assert_eq!(stdout, printed, "limit {limit}");
        assert_eq!(stderr, "ELE: memoria insuficiente\n");
        assert_eq!(code, Some(native::PANIC_EXIT_CODE as i32));
    }
    // With enough allocations the same program runs normally.
    let exe = build(
        &dir,
        "oom.l",
        &["--backend", "cranelift", "--alloc-fail-after", "2"],
    );
    assert_eq!(run(&exe).0, "antes\n11\n1\n");
}

#[test]
fn runtime_detects_double_free_if_verifier_is_bypassed() {
    // Build a program, then deliberately duplicate a drop. The verifier must
    // reject it; compiled anyway (bypassing it), the instrumented runtime must
    // detect the invalid free and abort instead of corrupting memory.
    let ir = project_l::check("fn main() {\n let n = 1\n let t = \"{n}\"\n print(t)\n}").unwrap();
    let mut m = project_l::lower_to_cfg(&ir).unwrap();
    let f = &mut m.funcs[m.main];
    let drop = f
        .blocks
        .iter()
        .flat_map(|b| &b.insts)
        .find(|i| matches!(i.kind, InstKind::Drop(_, None)))
        .cloned()
        .expect("unconditional drop");
    let block = f
        .blocks
        .iter_mut()
        .find(|b| b.insts.contains(&drop))
        .unwrap();
    block.insts.push(Inst {
        kind: drop.kind.clone(),
        span: Span::default(),
    });
    let e = cfg::verify(&m).unwrap_err();
    assert!(e.message.contains("doble liberación"), "{e:?}");
    let object = native::compile(
        &m,
        native::Options {
            trace_alloc: true,
            fail_alloc_after: None,
        },
    )
    .unwrap();
    let dir = work("double_free");
    fs::write(dir.join("df.obj"), object).unwrap();
    linker::link(
        &linker::find().unwrap(),
        &dir.join("df.obj"),
        &dir.join("df.exe"),
    )
    .unwrap();
    let (stdout, stderr, code) = run(&dir.join("df.exe"));
    assert_eq!(stdout, "1\n");
    assert_eq!(stderr, "ELE: liberación de memoria inválida\n");
    assert_eq!(code, Some(native::PANIC_EXIT_CODE as i32));
}

#[test]
fn unsafe_programs_are_rejected_at_compile_time() {
    for (source, cause) in [
        (
            "fn main() {\n let n = 1\n let a = \"{n}\"\n let b = a\n print(a)\n}",
            "después de moverlo",
        ),
        (
            "fn f(t: Text) {}\nfn main() {\n let n = 1\n let a = \"{n}\"\n f(a)\n f(a)\n}",
            "después de moverlo",
        ),
        (
            "fn f(t: Text) {}\nfn main() {\n let n = 1\n let a = \"{n}\"\n if n > 0 { f(a) }\n print(a)\n}",
            "movido en alguna rama",
        ),
        (
            "fn f(t: Text) {}\nfn main() {\n let n = 1\n let a = \"{n}\"\n for i in 0..2 { f(a) }\n}",
            "dentro de bucle",
        ),
        ("fn main() {\n let a: Text\n}", "se esperaba '='"),
        (
            "fn main() {\n var a = \"x\"\n let b = a\n print(\"{a}\")\n}",
            "después de moverlo",
        ),
    ] {
        let e = project_l::check(source).expect_err(source);
        assert!(e.message.contains(cause), "{source}: {e:?}");
    }
}

#[test]
fn panic_aborts_without_running_drops() {
    // Documented behaviour (panic = abort): no drops, no trace report, the
    // process terminates; the OS reclaims its memory.
    let dir = work("panic_abort");
    fs::write(
        dir.join("p.l"),
        "fn main() {\n var x = 9223372036854775807\n let t = \"{x}\"\n print(t)\n x += 1\n}\n",
    )
    .unwrap();
    let exe = build(&dir, "p.l", &["--backend", "cranelift", "--trace-alloc"]);
    let (stdout, stderr, code) = run(&exe);
    assert_eq!(stdout, "9223372036854775807\n");
    assert!(stderr.starts_with("ELE 5:"), "{stderr}");
    assert!(!stderr.contains("l-alloc"), "{stderr}");
    assert_eq!(code, Some(native::PANIC_EXIT_CODE as i32));
}

#[test]
fn native_struct_layout_returns_and_partial_moves() {
    let (out, s) = check_program(
        "struct_partial",
        r#"
struct Pair { a: Text, b: Text }
struct Outer { flag: Bool, pair: Pair, n: Int }
fn make(n: Int) -> Outer = Outer(flag: true, pair: Pair(a: "a{n}", b: "b{n}"), n: n)
fn main() {
 var p = make(7)
 let a = p.pair.a
 print(a)
 print(p.pair.b)
 print(p.flag)
 print(p.n)
 p.pair.a = "restored{8}"
 let all = p
 print(all.pair.a)
 print(all.pair.b)
 let temporary = make(9).pair.a
 print(temporary)
}
"#,
    );
    assert_eq!(out, "a7\nb7\ntrue\n7\nrestored8\nb7\na9\n");
    assert_eq!(s.allocs, 4);
}

#[test]
fn native_struct_conditional_drops_and_overwrites() {
    let (out, s) = check_program(
        "struct_branches",
        r#"
struct Pair { a: Text, b: Text }
fn consume(t: Text) { print(t) }
fn branch(flag: Bool) {
 var p = Pair(a: "a{1}", b: "b{2}")
 if flag { consume(p.a) }
 p.b = "next{3}"
 print(p.b)
}
fn main() {
 branch(true)
 branch(false)
 for i in 0..5 {
  var p = Pair(a: "x{i}", b: "y{i}")
  let a = p.a
  if i == 1 { continue }
  if i == 3 { break }
  p.b = "{p.b}!"
  print(a)
 }
}
"#,
    );
    assert_eq!(out, "a1\nnext3\nnext3\nx0\nx2\n");
    assert_eq!(s.allocs, 10);
}

#[test]
fn native_struct_restores_subtrees_on_both_branches() {
    let (out, _) = check_program(
        "struct_restore",
        r#"
struct P { a: Text, b: Text }
struct O { p: P, tail: Bool }
fn main() {
 var o = O(p: P(a: "{1}", b: "{2}"), tail: true)
 let a = o.p.a
 if o.tail { o.p.a = "{3}" } else { o.p.a = "{4}" }
 let p = o.p
 o.p = P(a: "{5}", b: "{6}")
 let all = o
 print(p.a)
 print(all.p.b)
}
"#,
    );
    assert_eq!(out, "3\n6\n");
}

#[test]
fn native_struct_parameters_recursion_and_replacement() {
    let (out, s) = check_program(
        "struct_params",
        r#"
struct P { a: Text, b: Text, n: Int, flag: Bool }
fn make(n: Int) -> P = P(a: "a{n}", b: "b{n}", n: n, flag: true)
fn recurse(p: P, n: Int) -> P {
 if n == 0 { return p }
 return recurse(p, n - 1)
}
fn take(p: P) -> Text { return p.a }
fn main() {
 var p = recurse(make(5), 4)
 p = p
 p = make(8)
 print(p.flag)
 print(p.n)
 print(take(p))
}
"#,
    );
    assert_eq!(out, "true\n8\na8\n");
    assert_eq!(s.allocs, 4);
}

#[test]
fn native_build_and_fibonacci_work_without_rustc_on_path() {
    let dir = work("without_rustc");
    let source = r#"
struct Point { x: Int, y: Int }
fn fibonacci(n: Int) -> Int {
 if n <= 1 { return n }
 return fibonacci(n - 1) + fibonacci(n - 2)
}
fn main() {
 let p = Point(x: 10, y: 20)
 print(p.x + p.y)
 let resultado = fibonacci(10)
 print("Fibonacci: {resultado}")
}
"#;
    fs::write(dir.join("native.l"), source).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(&dir)
        .env("PATH", "")
        .args(["run", "native.l", "--backend", "cranelift"])
        .output()
        .unwrap();
    assert_eq!(
        out.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(out.stdout, b"30\nFibonacci: 55\n");
    assert!(out.stderr.is_empty());
}
