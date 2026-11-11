//! Integration tests for Generics, Traits, and Static Monomorphization.

use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/generics_traits")
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

    // 2. Cranelift backend native execution with memory instrumentation
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
    assert_eq!(
        field("allocs"),
        field("frees"),
        "fuga de memoria detectada: {line}"
    );
}

#[test]
fn test_ele_v2_generic_of_executes_on_both_backends() {
    let source = r#"
flow identity of[T](value: T) => T = value

flow main() {
    hold value = identity of[Int](42)
    print(value)
}
"#;
    check_native_program("ele_v2_generic_of", source, "42\n");
}

#[test]
fn test_generic_functions() {
    let source = r#"
fn id<T>(x: T) -> T = x

fn main() {
    let i = id(42)
    let b = id(true)
    let s = id("hola mundo")
    print(i)
    if b {
        print(s)
    }
}
"#;
    check_native_program("generic_fn", source, "42\nhola mundo\n");
}

#[test]
fn test_generic_functions_explicit_type_args() {
    let source = r#"
fn id<T>(x: T) -> T = x

fn main() {
    let i = id<Int>(99)
    let s = id<Text>("explicit")
    print(i)
    print(s)
}
"#;
    check_native_program("generic_fn_explicit", source, "99\nexplicit\n");
}

#[test]
fn test_generic_structs_and_methods() {
    let source = r#"
struct Caja<T> {
    valor: T
}

impl<T> Caja<T> {
    fn obtener() -> T = self.valor
    mut fn poner(nuevo: T) {
        self.valor = nuevo
    }
}

fn main() {
    var c = Caja(valor: 10)
    print(c.obtener())
    c.poner(25)
    print(c.obtener())
}
"#;
    check_native_program("generic_struct_methods", source, "10\n25\n");
}

#[test]
fn test_traits_and_static_dispatch() {
    let source = r#"
trait Resumen {
    fn codigo() -> Int
}

struct Articulo {
    id: Int
}

impl Resumen for Articulo {
    fn codigo() -> Int = self.id
}

fn imprimir_codigo<T: Resumen>(item: T) {
    print(item.codigo())
}

fn main() {
    let art = Articulo(id: 777)
    imprimir_codigo(art)
}
"#;
    check_native_program("traits_static_dispatch", source, "777\n");
}

#[test]
fn test_generic_ownership_and_drops() {
    let source = r#"
struct Caja<T> {
    contenido: T
}

fn main() {
    let c1 = Caja(contenido: "cadena dinámica en heap 1")
    let c2 = Caja(contenido: "cadena dinámica en heap 2")
    print(c1.contenido)
    print(c2.contenido)
}
"#;
    check_native_program(
        "generic_ownership",
        source,
        "cadena dinámica en heap 1\ncadena dinámica en heap 2\n",
    );
}

#[test]
fn test_generics_traits_negative_diagnostics() {
    let cases = vec![
        (
            "trait Tr { fn m() }\nfn f<T: Tr>(x: T) {}\nfn main() { f(1) }",
            "semántica",
            "no implementa el trait Tr",
        ),
        (
            "trait Tr {}\nstruct S {}\nimpl Tr for S {}\nimpl Tr for S {}\nfn main() {}",
            "semántica",
            "implementación duplicada",
        ),
        (
            "trait Tr { fn m() }\nstruct S {}\nimpl Tr for S {}\nfn main() {}",
            "semántica",
            "falta el método m",
        ),
        (
            "struct Caja<T> { v: T }\nfn main() { let c: Caja<Int, Int> = Caja(v: 1) }",
            "semántica",
            "requiere 1 argumento(s) de tipo",
        ),
        (
            "fn f<T: Inexistente>(x: T) {}\nfn main() {}",
            "semántica",
            "trait no definido: Inexistente",
        ),
    ];

    for (source, category, cause) in cases {
        let e = check(source).expect_err(source);
        assert_eq!(e.category, category, "{source}: {e:?}");
        assert!(e.message.contains(cause), "{source}: {e:?}");
    }
}
