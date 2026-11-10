//! Comprehensive test suite for the static effect system, `@noalloc`, and effect contracts.

use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/effects_test")
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
        String::from_utf8_lossy(&out.stdout).replace("\r\n", "\n"),
        String::from_utf8_lossy(&out.stderr).replace("\r\n", "\n"),
        out.status.code(),
    )
}

fn check_native_program(name: &str, source: &str, expected_stdout: &str) {
    let dir = work(name);
    let file = format!("{name}.l");
    fs::write(dir.join(&file), source).unwrap();

    // 1. Rustc backend reference execution
    let ref_exe = build(&dir, &file, &[]);
    let (ref_out, ref_err, ref_code) = run(&ref_exe);
    assert_eq!(ref_code, Some(0), "rustc failed: {ref_err}");
    assert_eq!(ref_out, expected_stdout, "rustc stdout mismatch");

    // 2. Cranelift backend native execution with memory trace
    let clif_exe = build(&dir, &file, &["--backend", "cranelift", "--trace-alloc"]);
    let (clif_out, clif_err, clif_code) = run(&clif_exe);
    assert_eq!(clif_code, Some(0), "cranelift failed: {clif_err}");
    assert_eq!(clif_out, expected_stdout, "cranelift stdout mismatch");

    // 3. Differential comparison
    assert_eq!(ref_out, clif_out, "differential stdout mismatch");
    assert_eq!(ref_code, clif_code, "differential exit code mismatch");

    // 4. Memory trace verification
    let line = clif_err
        .lines()
        .find(|l| l.starts_with("l-alloc: "))
        .unwrap_or_else(|| panic!("sin informe de memoria: {clif_err}"));
    let field = |field_name: &str| -> u64 {
        line.split_whitespace()
            .find_map(|w| w.strip_prefix(&format!("{field_name}=")))
            .unwrap()
            .parse()
            .unwrap()
    };
    assert_eq!(field("heap_ok"), 1, "heap corrupto: {line}");
    assert_eq!(field("allocs"), field("frees"), "fuga detectada: {line}");
}

#[test]
fn test_pure_float_functions_pass_pure_contract() {
    let source = r#"
fn multiplicar(a: Float, b: Float) -> Float !{} {
    return a * b
}

fn cuadrado(x: Float) -> Float !{} = x * x

fn main() {
    let m = multiplicar(3.0, 4.0)
    let c = cuadrado(5.0)
    print(m)
    print(c)
}
"#;
    check_native_program("pure_float", source, "12\n25\n");
}

#[test]
fn test_noalloc_attribute_with_locals_and_structs() {
    let source = r#"
struct Punto {
    x: Float,
    y: Float
}

@noalloc
fn distancia_cuadrada(p: Punto) -> Float {
    return p.x * p.x + p.y * p.y
}

@noalloc
fn calcular(a: Float, b: Float) -> Float {
    let p = Punto(x: a, y: b)
    return distancia_cuadrada(p)
}

fn main() {
    let d = calcular(3.0, 4.0)
    print(d)
}
"#;
    check_native_program("noalloc_struct", source, "25\n");
}

#[test]
fn test_noalloc_with_static_strings() {
    let source = r#"
@noalloc
fn mensaje_fijo() -> Text {
    return "mensaje puramente estático"
}

fn main() {
    let m = mensaje_fijo()
    print(m)
}
"#;
    check_native_program(
        "noalloc_static_text",
        source,
        "mensaje puramente estático\n",
    );
}

#[test]
fn test_noalloc_recursive_function() {
    let source = r#"
@noalloc
fn fib(n: Int) -> Int {
    if n <= 1 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

fn main() {
    let res = fib(10)
    print(res)
}
"#;
    check_native_program("noalloc_fib", source, "55\n");
}

#[test]
fn test_trait_pure_contract_and_static_dispatch() {
    let source = r#"
trait Calculable {
    fn calcular(x: Float) -> Float !{}
}

struct Duplicador {}

impl Calculable for Duplicador {
    fn calcular(x: Float) -> Float !{} {
        return x * 2.0
    }
}

fn ejecutar<T: Calculable>(calc: T, val: Float) -> Float {
    return calc.calcular(val)
}

fn main() {
    let d = Duplicador()
    let res = ejecutar(d, 21.0)
    print(res)
}
"#;
    check_native_program("trait_pure", source, "42\n");
}

#[test]
fn test_effects_negative_diagnostics() {
    let cases = vec![
        // 1. Integer checked arithmetic in !{} causes panic effect.
        (
            "fn suma(a: Int, b: Int) -> Int !{} = a + b\nfn main() {}",
            "efectos",
            "violación de contrato de efectos !{}",
        ),
        (
            "fn suma(a: Int, b: Int) -> Int !{} = a + b\nfn main() {}",
            "efectos",
            "aritmética entera con verificación de desbordamiento",
        ),
        // 2. Dynamic string interpolation in @noalloc causes alloc effect.
        (
            "@noalloc\nfn saludo(n: Text) -> Text = \"Hola {n}\"\nfn main() {}",
            "efectos",
            "violación de @noalloc",
        ),
        (
            "@noalloc\nfn saludo(n: Text) -> Text = \"Hola {n}\"\nfn main() {}",
            "efectos",
            "interpolación dinámica de texto en el heap",
        ),
        // 3. Calling print in !{} causes io/block/alloc/panic.
        (
            "fn f() !{} { print(\"hola\") }\nfn main() {}",
            "efectos",
            "violación de contrato de efectos !{}",
        ),
        // 4. Calling print in @noalloc causes alloc.
        (
            "@noalloc\nfn f() { print(\"hola\") }\nfn main() {}",
            "efectos",
            "violación de @noalloc",
        ),
        // 5. Transitive call chain: @noalloc caller calling function that allocates dynamically.
        (
            "fn genera(n: Int) -> Text = \"num: {n}\"\n@noalloc\nfn proceso() { let s = genera(42) }\nfn main() {}",
            "efectos",
            "Ruta de llamadas",
        ),
        // 6. Transitive call chain shows caller and callee in diagnostic.
        (
            "fn genera(n: Int) -> Text = \"num: {n}\"\n@noalloc\nfn proceso() { let s = genera(42) }\nfn main() {}",
            "efectos",
            "└── genera()",
        ),
        // 7. Trait method contract violation: trait declares !{}, impl introduces io via print.
        (
            "trait T { fn m() !{} }\nstruct S {}\nimpl T for S { fn m() { print(\"x\") } }\nfn main() {}",
            "efectos",
            "viola el contrato de efectos !{} del trait 'T'",
        ),
        // 8. Explicit !{panic} allows integer arithmetic.
        // But integer arithmetic under !{alloc, io} lacks panic -> rejected.
        (
            "fn f(x: Int) -> Int !{alloc, io} = x + 1\nfn main() {}",
            "efectos",
            "introduce efectos no permitidos [panic]",
        ),
    ];

    for (source, category, cause) in cases {
        let e = check(source).expect_err(source);
        assert_eq!(e.category, category, "{source}: {e:?}");
        assert!(e.message.contains(cause), "{source}: {e:?}");
    }
}

/// Regression: a trait's effect contract must hold for *every* implementation,
/// whatever the declaration order (previously only the last impl was checked).
#[test]
fn trait_contract_checks_every_implementation() {
    let pure = "impl T for A {\n    fn m() -> Int !{} {\n        return self.x\n    }\n}\n";
    let impure = "impl T for B {\n    fn m() -> Int {\n        print(\"efecto\")\n        return self.x\n    }\n}\n";
    let head = "trait T {\n    fn m() -> Int !{}\n}\nstruct A {\n    x: Int\n}\nstruct B {\n    x: Int\n}\n";
    let tail = "fn main() {\n    print(A(x: 1).m())\n}\n";
    for order in [[pure, impure], [impure, pure]] {
        let source = format!("{head}{}{}{tail}", order[0], order[1]);
        let e = check(&source).expect_err(&source);
        assert_eq!(e.code, "L0010", "{e:?}");
        assert!(e.message.contains("B.m()"), "{}", e.message);
    }
}

/// `@noalloc` on a generic function is checked per instantiation, through the
/// trait bound's implementation.
#[test]
fn noalloc_generic_checked_per_instance() {
    let base = "trait Show {\n    fn show() -> Int\n}\nstruct A {\n    x: Int\n}\nstruct B {\n    x: Int\n}\nimpl Show for A {\n    fn show() -> Int = self.x\n}\nimpl Show for B {\n    fn show() -> Int {\n        let t = \"{self.x}\"\n        return self.x\n    }\n}\n@noalloc\nfn usa<T: Show>(v: T) -> Int = v.show()\n";
    check(&format!(
        "{base}fn main() {{\n    print(usa(A(x: 1)))\n}}\n"
    ))
    .unwrap();
    let e = check(&format!(
        "{base}fn main() {{\n    print(usa(B(x: 2)))\n}}\n"
    ))
    .unwrap_err();
    assert_eq!(e.code, "L0010");
    assert!(
        e.message.contains("usa<B>") && e.message.contains("B.show()"),
        "{}",
        e.message
    );
}
