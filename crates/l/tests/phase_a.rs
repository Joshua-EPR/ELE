//! Phase A completion: `for` over integer ranges, return-type inference and
//! `loop` divergence in return-path analysis.
use project_l::{
    check,
    lir::{Instruction, Type},
};
use std::{fs, path::PathBuf, process::Command};

fn run(name: &str, source: &str) -> (String, String, Option<i32>) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/phase_a")
        .join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join(format!("{name}.l")), source).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(&dir)
        .args(["run", &format!("{name}.l")])
        .output()
        .expect("CLI");
    (
        String::from_utf8_lossy(&out.stdout).replace("\r\n", "\n"),
        String::from_utf8_lossy(&out.stderr).into_owned(),
        out.status.code(),
    )
}

#[test]
fn for_ranges_run_natively() {
    let source = r#"
fn siguiente() -> Int {
    print("bound")
    return 3
}
fn main() {
    var s = 0
    for n in 1..=5 { s += n }
    print("s={s}")
    for i in 0..siguiente() {
        if i == 1 { continue }
        print(i)
    }
    for i in 5..1 { print("nunca") }
    for i in 3..=3 { print("una vez {i}") }
    for i in 9223372036854775806..=9223372036854775807 { print(i) }
    for i in 0..10 {
        if i == 2 { break }
        for j in 0..2 { print("{i}{j}") }
    }
    for n in 0..2 {
        let n = n * 10
        print(n)
    }
}
"#;
    let (stdout, stderr, code) = run("ranges", source);
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(
        stdout,
        "s=15\nbound\n0\n2\nuna vez 3\n9223372036854775806\n9223372036854775807\n00\n01\n10\n11\n0\n10\n"
    );
    assert!(stderr.is_empty(), "{stderr}");
}

#[test]
fn inferred_returns_and_diverging_loops() {
    let source = r#"
fn multiplicar(a: Int, b: Int) = a * b
fn doble(a: Int) = multiplicar(a, 2)
fn usa_posterior() = posterior() + 1
fn posterior() = 41
fn saludo(n: Text) = "hola {n}"
fn signo(x: Int) {
    if x < 0 { return "neg" }
    return "pos"
}
fn primero() -> Int {
    loop {
        while true { break }
        return 7
    }
}
fn nada() {
    print("nada")
}
fn main() {
    print(doble(multiplicar(2, 3)))
    print(usa_posterior())
    print(saludo("L"))
    print(signo(-1))
    print(primero())
    nada()
}
"#;
    let ir = check(source).unwrap();
    let results: Vec<Type> = ir.functions.iter().map(|f| f.result).collect();
    assert_eq!(
        &results[..7],
        &[
            Type::Int,
            Type::Int,
            Type::Int,
            Type::Int,
            Type::Text,
            Type::Text,
            Type::Int
        ]
    );
    assert_eq!(ir.functions[7].result, Type::Unit);
    let (stdout, stderr, code) = run("inference", source);
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(stdout, "12\n42\nhola L\nneg\n7\nnada\n");
}

#[test]
fn for_lowers_to_dedicated_lir() {
    let ir = check("fn main() { for i in 0..=2 { print(i) } }").unwrap();
    assert!(matches!(
        ir.functions[ir.main].body[0],
        Instruction::ForRange(_, _, _, true, _)
    ));
}

#[test]
fn phase_a_negative_diagnostics() {
    for (source, category, cause) in [
        (
            "fn f(n: Int) = f(n - 1)\nfn main() {}",
            "inferencia",
            "no se puede inferir",
        ),
        (
            "fn a() = b()\nfn b() = a()\nfn main() {}",
            "inferencia",
            "anote '-> Tipo'",
        ),
        (
            "fn f(c: Bool) { if c { return 1 } }\nfn main() {}",
            "semántica",
            "falta retorno",
        ),
        (
            "fn f(c: Bool) { if c { return 1 }\n return true }\nfn main() {}",
            "semántica",
            "incompatible",
        ),
        ("fn main() { 1 }", "semántica", "main debe tener firma"),
        (
            "fn f() -> Int { loop { break }\n}\nfn main() {}",
            "semántica",
            "falta retorno",
        ),
        (
            "fn f() -> Int { loop { if true { break } }\n}\nfn main() {}",
            "semántica",
            "falta retorno",
        ),
        (
            "fn main() { for i in 1..true {} }",
            "semántica",
            "incompatible",
        ),
        (
            "fn main() { for i in 0.0..1.0 {} }",
            "semántica",
            "incompatible",
        ),
        (
            "fn main() { for i in 0..3 { i = 2 } }",
            "semántica",
            "inmutable",
        ),
        (
            "fn main() { for i in 0..3 {}\n print(i) }",
            "semántica",
            "no definido",
        ),
        (
            "fn main() { for x in lista {} }",
            "semántica",
            "símbolo no definido",
        ),
        (
            "fn main() { for 1 in 0..2 {} }",
            "sintaxis",
            "identificador",
        ),
        (
            "fn main() { let t = \"a\"\n for i in 0..2 { let u = t } }",
            "ownership",
            "dentro de bucle",
        ),
        (
            "fn f() -> Int !{desconocido} = 1\nfn main() {}",
            "sintaxis",
            "efecto desconocido",
        ),
    ] {
        let e = check(source).expect_err(source);
        assert_eq!(e.category, category, "{source}: {e:?}");
        assert!(e.message.contains(cause), "{source}: {e:?}");
        assert!(e.span.line > 0 && e.span.column > 0, "{source}: {e:?}");
    }
}
