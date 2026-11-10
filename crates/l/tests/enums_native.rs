//! Comprehensive native Cranelift tests for enums, match, variant-sensitive drops,
//! Option, Result, `??`, and `?`.

use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/enums_native")
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
fn test_simple_enum_no_payload() {
    let source = r#"
enum Color {
    Rojo
    Verde
    Azul
}

fn describe(c: Color) -> Text = match c {
    Color.Rojo => "rojo",
    Color.Verde => "verde",
    Color.Azul => "azul",
}

fn main() {
    print(describe(Color.Rojo))
    print(describe(Color.Verde))
    print(describe(Color.Azul))
}
"#;
    check_native_program("simple_enum_no_payload", source, "rojo\nverde\nazul\n");
}

#[test]
fn test_enum_with_payload_single_field() {
    let source = r#"
enum Estado {
    Pendiente
    Completado
    Error(Int)
}

fn main() {
    let estado = Estado.Error(42)

    match estado {
        Estado.Pendiente => print(0),
        Estado.Completado => print(1),
        Estado.Error(codigo) => print(codigo),
    }
}
"#;
    check_native_program("enum_with_payload_single_field", source, "42\n");
}

#[test]
fn test_enum_multi_field_payload() {
    let source = r#"
enum Evento {
    Vacio
    Click(Int, Int)
    Key(Int, Bool)
}

fn main() {
    let e1 = Evento.Click(100, 200)
    let e2 = Evento.Key(27, true)
    let e3 = Evento.Vacio

    match e1 {
        Evento.Vacio => print("vacio"),
        Evento.Click(x, y) => print("click {x} {y}"),
        Evento.Key(k, ctrl) => print("key {k}"),
    }

    match e2 {
        Evento.Vacio => print("vacio"),
        Evento.Click(x, y) => print("click {x} {y}"),
        Evento.Key(k, ctrl) => print("key {k} {ctrl}"),
    }

    match e3 {
        Evento.Vacio => print("vacio"),
        Evento.Click(x, y) => print("click {x} {y}"),
        Evento.Key(k, ctrl) => print("key {k}"),
    }
}
"#;
    check_native_program(
        "enum_multi_field_payload",
        source,
        "click 100 200\nkey 27 true\nvacio\n",
    );
}

#[test]
fn test_enum_variant_sensitive_drops() {
    let source = r#"
enum Mensaje {
    Texto(Text)
    Numero(Int)
}

fn main() {
    var i = 0
    while i < 3 {
        let m = Mensaje.Texto("iter {i}")
        match m {
            Mensaje.Texto(t) => print(t),
            Mensaje.Numero(n) => print(n),
        }
        i += 1
    }

    let m_num = Mensaje.Numero(999)
    match m_num {
        Mensaje.Texto(t) => print(t),
        Mensaje.Numero(n) => print(n),
    }
}
"#;
    check_native_program(
        "enum_variant_sensitive_drops",
        source,
        "iter 0\niter 1\niter 2\n999\n",
    );
}

#[test]
fn test_enum_with_struct_containing_text() {
    let source = r#"
struct Persona {
    nombre: Text
    edad: Int
}

enum Respuesta {
    Exito(Persona)
    Fallo(Int)
}

fn main() {
    let r1 = Respuesta.Exito(Persona(nombre: "Carlos", edad: 30))
    match r1 {
        Respuesta.Exito(p) => print("{p.nombre} {p.edad}"),
        Respuesta.Fallo(code) => print("error {code}"),
    }

    let r2 = Respuesta.Fallo(404)
    match r2 {
        Respuesta.Exito(p) => print("{p.nombre} {p.edad}"),
        Respuesta.Fallo(code) => print("error {code}"),
    }
}
"#;
    check_native_program(
        "enum_with_struct_containing_text",
        source,
        "Carlos 30\nerror 404\n",
    );
}

#[test]
fn test_nested_enums() {
    let source = r#"
enum Sub {
    A(Int)
    B(Text)
}

enum Top {
    Vacio
    Nodo(Sub)
}

fn main() {
    let t1 = Top.Nodo(Sub.B("anidado"))
    let t2 = Top.Nodo(Sub.A(123))
    let t3 = Top.Vacio

    match t1 {
        Top.Vacio => print("vacio"),
        Top.Nodo(sub) => match sub {
            Sub.A(n) => print("a {n}"),
            Sub.B(s) => print("b {s}"),
        },
    }

    match t2 {
        Top.Vacio => print("vacio"),
        Top.Nodo(sub) => match sub {
            Sub.A(n) => print("a {n}"),
            Sub.B(s) => print("b {s}"),
        },
    }

    match t3 {
        Top.Vacio => print("vacio"),
        Top.Nodo(sub) => print("nodo"),
    }
}
"#;
    check_native_program("nested_enums", source, "b anidado\na 123\nvacio\n");
}

#[test]
fn test_enum_parameters_and_sret() {
    let source = r#"
enum Opcion {
    Vacio
    Valor(Int)
}

fn transformar(o: Opcion) -> Opcion {
    return match o {
        Opcion.Vacio => Opcion.Vacio,
        Opcion.Valor(n) => Opcion.Valor(n * 2),
    }
}

fn main() {
    let res1 = transformar(Opcion.Valor(21))
    let res2 = transformar(Opcion.Vacio)

    match res1 {
        Opcion.Vacio => print("vacio"),
        Opcion.Valor(n) => print(n),
    }

    match res2 {
        Opcion.Vacio => print("vacio"),
        Opcion.Valor(n) => print(n),
    }
}
"#;
    check_native_program("enum_parameters_and_sret", source, "42\nvacio\n");
}

#[test]
fn test_option_and_result_native() {
    let source = r#"
fn parse_positive(n: Int) -> Result<Int, Text> {
    if n > 0 {
        return Ok(n)
    } else {
        return Err("debe ser positivo")
    }
}

fn double_positive(n: Int) -> Result<Int, Text> {
    let val = parse_positive(n)?
    return Ok(val * 2)
}

fn main() {
    let o1: Int? = Some(10)
    let o2: Int? = None
    print(o1 ?? 0)
    print(o2 ?? -1)

    match double_positive(5) {
        Ok(v) => print("ok {v}"),
        Err(e) => print("err {e}"),
    }

    match double_positive(-3) {
        Ok(v) => print("ok {v}"),
        Err(e) => print("err {e}"),
    }
}
"#;
    check_native_program(
        "option_and_result_native",
        source,
        "10\n-1\nok 10\nerr debe ser positivo\n",
    );
}

#[test]
fn test_negative_diagnostics_enums() {
    let cases = [
        (
            "enum Color { Rojo, Verde }\nfn main() { let c = Color.Azul }",
            "semántica",
            "no tiene la variante Azul",
        ),
        (
            "enum E { A(Int) }\nfn main() { let e = E.A(1, 2) }",
            "semántica",
            "espera 1",
        ),
        (
            "enum Color { Rojo, Verde, Azul }\nfn main() { let c = Color.Rojo\n match c { Color.Rojo => print(1) } }",
            "semántica",
            "no exhaustivo",
        ),
        (
            "enum E { A, C(Text) }\nfn take(t: Text) {}\nfn main() { let x = E.C(\"a\")\n match x { E.C(t) => take(t), _ => {} }\n match x { _ => {} } }",
            "ownership",
            "después de moverlo",
        ),
    ];

    for (source, category, cause) in cases {
        let err = check(source).expect_err(source);
        assert_eq!(err.category, category, "source: {source}");
        assert!(
            err.message.contains(cause),
            "error '{:?}' should contain '{cause}' in source: {source}",
            err
        );
    }
}
