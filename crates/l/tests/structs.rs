//! Phase B: struct declarations, construction, defaults, field access,
//! `impl` with read (`fn`), mutable (`mut fn`) and `static fn` methods.
use project_l::{
    check, lexer,
    lir::{Receiver, Type, ValueKind},
    parser,
};
use std::{fs, path::PathBuf, process::Command};

fn run_file(dir_name: &str, file: &str, source: Option<&str>) -> (String, String, Option<i32>) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/structs")
        .join(dir_name);
    fs::create_dir_all(&dir).unwrap();
    let path = match source {
        Some(source) => {
            let path = dir.join(file);
            fs::write(&path, source).unwrap();
            path
        }
        None => PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join(file),
    };
    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(&dir)
        .arg("run")
        .arg(path)
        .output()
        .expect("CLI");
    (
        String::from_utf8_lossy(&out.stdout).replace("\r\n", "\n"),
        String::from_utf8_lossy(&out.stderr).into_owned(),
        out.status.code(),
    )
}

#[test]
fn contador_example_prints_valor_2() {
    let (stdout, stderr, code) = run_file("contador", "examples/contador.l", None);
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(stdout, "Valor: 2\n");
    assert!(stderr.is_empty(), "{stderr}");
}

#[test]
fn structs_example_runs() {
    let (stdout, stderr, code) = run_file("example", "examples/structs.l", None);
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(
        stdout,
        "Hola Ana\nAna (31) activo=true\norigen: 3,4 suma=7\nAna (31) activo=false\n\
Invitado (0) activo=true\n0\n0\n2\ntotal: 55\n"
    );
}

#[test]
fn parser_builds_struct_impl_and_postfix_ast() {
    let source = "struct P {\n x: Int = 1, y: Int\n}\nimpl P {\n mut fn m() { self.x += 1 }\n static fn s() -> Self = P(y: 2)\n}\nfn main() { var p = P(y: 1)\n p.m()\n print(p.x) }";
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    assert_eq!(ast.structs.len(), 1);
    assert_eq!(ast.structs[0].fields.len(), 2);
    assert!(ast.structs[0].fields[0].default.is_some());
    assert_eq!(ast.impls[0].methods.len(), 2);
    assert_eq!(ast.impls[0].methods[0].kind, parser::FnKind::MutMethod);
    assert_eq!(ast.impls[0].methods[1].kind, parser::FnKind::Static);
    let parser::Stmt::Expr(call, _) = &ast.functions[0].body[1] else {
        panic!("method call statement")
    };
    assert!(matches!(&call.kind, parser::ExprKind::MethodCall(_, m, _) if m == "m"));

    let ir = check(source).unwrap();
    assert_eq!(ir.structs[0].fields[1], ("y".to_string(), Type::Int));
    let method = &ir.functions[1];
    assert_eq!(method.name, "P.m");
    assert!(matches!(
        method.receiver,
        Some((_, Type::Struct(0), Receiver::Exclusive))
    ));
    assert_eq!(ir.functions[2].result, Type::Struct(0));
    assert!(ir.functions[2].receiver.is_none());
}

#[test]
fn construction_order_and_defaults_in_lir() {
    let source = "struct P {\n a: Int = 7\n b: Int\n}\nfn main() { let p = P(b: 1)\n print(p.a) }";
    let ir = check(source).unwrap();
    let project_l::lir::Instruction::Bind(_, _, v) = &ir.functions[ir.main].body[0] else {
        panic!("bind")
    };
    let ValueKind::Construct(0, inits) = &v.kind else {
        panic!("construct")
    };
    assert_eq!(inits[0].0, 1, "call-site fields first");
    assert!(matches!(inits[1], (0, ref d) if matches!(d.kind, ValueKind::Int(7))));
}

#[test]
fn ownership_and_borrow_semantics_run_natively() {
    let source = r#"
struct Nombre {
    texto: Text
}
struct Caja {
    nombre: Nombre
    usos: Int = 0
}
impl Nombre {
    fn largo() = 3
}
impl Caja {
    static fn nueva(t: Text) -> Self = Caja(nombre: Nombre(texto: t))
    mut fn usar(veces: Int) -> Int {
        self.usos += veces
        return self.usos
    }
    mut fn usar_dos() {
        self.usar(1)
        self.usar(1)
    }
    fn describe() = "{self.nombre.texto}:{self.usos}:{self.nombre.largo()}"
}
fn consume(c: Caja) -> Int = c.usos
fn main() {
    var c = Caja.nueva("uno")
    c.usar_dos()
    print(c.usar(c.usar(1)))
    print(c.describe())
    print("{c.nombre.texto} {consume(c)}")
    c = Caja.nueva("dos")
    print(c.describe())
    print(Caja.nueva("tmp").describe())
    print(Caja.nueva("campo").nombre.texto)
    var i = 0
    while i < 2 {
        let local = Caja.nueva("bucle")
        print(consume(local))
        c.usar(1)
        i += 1
    }
    print(c.usos)
}
"#;
    let (stdout, stderr, code) = run_file("ownership", "ownership.l", Some(source));
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(
        stdout,
        "6\nuno:6:3\nuno 6\ndos:0:3\ntmp:0:3\ncampo\n0\n0\n2\n"
    );
}

#[test]
fn struct_runtime_overflow_aborts_with_location() {
    let source = "struct C {\n v: Int = 9223372036854775807\n}\nimpl C {\n mut fn inc() { self.v += 1 }\n}\nfn main() { var c = C()\n c.inc() }";
    let (stdout, stderr, code) = run_file("overflow", "overflow.l", Some(source));
    assert_ne!(code, Some(0));
    assert!(stdout.is_empty());
    assert!(stderr.contains("ELE 5:"), "{stderr}");
}

#[test]
fn struct_negative_diagnostics() {
    let p = "struct P {\n x: Int\n}\n";
    let c = "struct C {\n v: Int = 0\n}\nimpl C {\n mut fn inc() { self.v += 1 }\n fn get() = self.v\n static fn make() -> C = C()\n}\n";
    let u = "struct U {\n nombre: Text\n}\n";
    let cases: Vec<(String, &str, &str)> = vec![
        // Declarations.
        (format!("{p}fn main() {{ let a = P() }}"), "semántica", "falta el campo obligatorio x"),
        (format!("{p}fn main() {{ let a = P(z: 1) }}"), "semántica", "no tiene campo z"),
        (format!("{p}fn main() {{ let a = P(x: 1, x: 2) }}"), "semántica", "más de una vez"),
        (format!("{p}fn main() {{ let a = P(1) }}"), "semántica", "argumentos con nombre"),
        (format!("{p}fn main() {{ let a = P(x: true) }}"), "semántica", "incompatible"),
        (format!("{p}fn main() {{ let a: P = 1 }}"), "semántica", "se esperaba P, encontrado Int"),
        (format!("{p}{p}fn main() {{}}"), "semántica", "struct duplicado"),
        ("struct Int {}\nfn main() {}".into(), "semántica", "reservado"),
        ("struct P { x: Int\n x: Int }\nfn main() {}".into(), "semántica", "campo duplicado"),
        (format!("{p}fn P() {{}}\nfn main() {{}}"), "semántica", "duplicada o reservada"),
        ("struct A { a: A }\nfn main() {}".into(), "semántica", "tamaño infinito"),
        ("struct A { b: B }\nstruct B { a: A }\nfn main() {}".into(), "semántica", "tamaño infinito"),
        ("struct A { b: Nope }\nfn main() {}".into(), "semántica", "tipo no definido: Nope"),
        ("struct A { u: () }\nfn main() {}".into(), "semántica", "()"),
        ("fn f() -> Int = 1\nstruct A { x: Int = f() }\nfn main() {}".into(), "const", "debe ser constante"),
        (format!("{p}struct A {{ p: P = P(x: 1) }}\nfn main() {{}}"), "const", "debe ser constante"),
        ("struct A { x: Int = true }\nfn main() {}".into(), "semántica", "incompatible"),
        ("struct A<T> { x: T }\nfn f(a: A) {}\nfn main() {}".into(), "semántica", "requiere 1 argumento(s) de tipo"),
        // Field access and mutation.
        (format!("{p}fn main() {{ let a = P(x: 1)\n a.x = 2 }}"), "semántica", "binding inmutable"),
        (format!("{p}fn f(a: P) {{ a.x = 2 }}\nfn main() {{}}"), "semántica", "binding inmutable"),
        (format!("{p}fn main() {{ let a = P(x: 1)\n print(a.y) }}"), "semántica", "no tiene campo y"),
        (format!("{p}fn main() {{ print(P.x) }}"), "semántica", "requiere una instancia"),
        (format!("{p}fn main() {{ let a = P }}"), "semántica", "es un tipo"),
        (format!("{p}fn main() {{ var a = P(x: 1)\n a.x = true }}"), "semántica", "incompatible"),
        // Methods.
        (format!("{c}fn main() {{ let c = C()\n c.inc() }}"), "semántica", "receptor mutable"),
        (format!("{c}fn main() {{ C().inc() }}"), "semántica", "binding var"),
        (format!("{c}fn main() {{ var c = C()\n c.make() }}"), "semántica", "static fn"),
        (format!("{c}fn main() {{ print(C.get()) }}"), "semántica", "método de instancia"),
        (format!("{c}fn main() {{ var c = C()\n c.nope() }}"), "semántica", "no tiene método nope"),
        (format!("{c}fn main() {{ var c = C()\n print(c.get(1)) }}"), "semántica", "número de argumentos"),
        ("struct C { v: Int }\nimpl C { fn f() { self.v = 1 } }\nfn main() {}".into(), "semántica", "binding inmutable"),
        ("struct C { v: Int }\nimpl C {\n mut fn inc() { self.v += 1 }\n fn f() { self.inc() }\n}\nfn main() {}".into(), "semántica", "receptor mutable"),
        ("struct C { v: Int }\nimpl C { static fn s() = self.v }\nfn main() {}".into(), "semántica", "self solo está disponible"),
        ("fn f() = self\nfn main() {}".into(), "semántica", "self solo está disponible"),
        ("struct C { v: Int }\nimpl C { fn f(self: Int) {} }\nfn main() {}".into(), "sintaxis", "self es implícito"),
        ("struct C { v: Int }\nimpl C { mut fn f() { self = C(v: 1) } }\nfn main() {}".into(), "semántica", "reasignar self"),
        ("fn main() { let self = 1 }".into(), "sintaxis", "reservada"),
        ("struct C { v: Int }\nimpl C {\n fn f() {}\n fn f() {}\n}\nfn main() {}".into(), "semántica", "método duplicado"),
        ("impl Nope { fn f() {} }\nfn main() {}".into(), "semántica", "impl requiere un struct"),
        ("struct C { v: Int }\nimpl Unknown for C {}\nfn main() {}".into(), "semántica", "trait no definido"),
        ("struct C { v: Int }\ntrait T { fn m() }\nimpl T for C {}\nfn main() {}".into(), "semántica", "falta el método"),
        ("fn f(x: Int) {}\nfn main() { f(x: 1) }".into(), "semántica", "solo se admite en constructores"),
        (format!("{c}fn main() {{ print(C()) }}"), "semántica", "print soporta"),
        (format!("{c}fn main() {{ print(\"{{C()}}\") }}"), "semántica", "no convertible"),
        (format!("{c}fn main() {{ let x = C() == C() }}"), "semántica", "sobre struct C"),
        (format!("{c}fn main() {{ var c = C()\n c.get = 1 }}"), "semántica", "no tiene campo get"),
        // Ownership.
        (format!("{u}fn main() {{ let a = U(nombre: \"x\")\n let n = a.nombre\n print(a.nombre) }}"), "ownership", "parcialmente movido"),
        (format!("{u}fn f(t: Text) {{}}\nfn main() {{ let a = U(nombre: \"x\")\n f(a.nombre)\n f(a.nombre) }}"), "ownership", "parcialmente movido"),
        (format!("{p}fn main() {{ let a = P(x: 1)\n let b = a\n print(a.x) }}"), "ownership", "después de moverlo"),
        (format!("{p}fn main() {{ var a = P(x: 1)\n let b = a\n a.x = 2 }}"), "ownership", "ya movido"),
        (format!("{p}fn main() {{ let a = P(x: 1)\n for i in 0..2 {{ let b = a }} }}"), "ownership", "dentro de bucle"),
        (format!("{p}fn main() {{ let t = \"a\"\n let a = U(nombre: t)\n print(t) }}\n{u}"), "ownership", "después de moverlo"),
        ("struct C { v: Int }\nfn take(c: C) = 1\nimpl C { fn f() = take(self) }\nfn main() {}".into(), "ownership", "no se puede mover self"),
        ("struct C { v: Int }\nimpl C { fn f(o: C) = 1 }\nfn main() { var c = C(v: 1)\n c.f(c); }".into(), "ownership", "receptor se mueve"),
        (format!("{p}fn main() {{ let a = P(x: 1)\n if true {{ let b = a }}\n print(a.x) }}"), "ownership", "después de moverlo"),
    ];
    for (source, category, cause) in cases {
        let e = check(&source).expect_err(&source);
        assert_eq!(e.category, category, "{source}: {e:?}");
        assert!(e.message.contains(cause), "{source}: {e:?}");
        assert!(e.span.line > 0 && e.span.column > 0, "{source}: {e:?}");
    }
}

#[test]
fn malformed_struct_inputs_do_not_panic() {
    let alphabet = b"struct impl fn mut static self P{}():.,=\nxyv1";
    let mut seed = 99u64;
    for _ in 0..1000 {
        let mut source = String::new();
        for _ in 0..40 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            source.push(alphabet[(seed >> 32) as usize % alphabet.len()] as char);
        }
        let _ = check(&source);
        let _ = check(&format!("struct P {{ x: Int }}\nfn main() {{ {source} }}"));
    }
}

#[test]
fn field_ownership_rejects_invalid_paths() {
    let prefix =
        "struct Pair { a: Text, b: Text }\nstruct Outer { pair: Pair }\nfn eat(p: Pair) {}\n";
    for body in [
        "let p = Pair(a: \"a\", b: \"b\")\n let a = p.a\n print(p.a)",
        "let p = Pair(a: \"a\", b: \"b\")\n let a = p.a\n eat(p)",
        "let p = Pair(a: \"a\", b: \"b\")\n if true { let a = p.a }\n print(p.a)",
        "var p = Outer(pair: Pair(a: \"a\", b: \"b\"))\n let pair = p.pair\n p.pair.a = \"new\"",
        "let p = Pair(a: \"a\", b: \"b\")\n for i in 0..2 { let a = p.a }",
    ] {
        let source = format!("{prefix}fn main() {{ {body} }}");
        let error = check(&source).expect_err(&source);
        assert!(!error.message.is_empty());
    }
    let source = "struct P { a: Text }\nimpl P { fn take() -> Text = self.a }\nfn main() {}";
    assert!(check(source).is_err(), "cannot move from borrowed self");
}

#[test]
fn field_layout_has_padding_and_nested_offsets() {
    let ir = check("struct P { flag: Bool, n: Int, t: Text }\nstruct O { flag: Bool, p: P, tail: Bool }\nfn main() {}").unwrap();
    let layouts = project_l::layout::Layouts::windows_x64(&ir.structs, &ir.enums).unwrap();
    let p = layouts.get(Type::Struct(0)).unwrap();
    assert_eq!((p.size, p.align, p.fields), (40, 8, vec![0, 8, 16]));
    let o = layouts.get(Type::Struct(1)).unwrap();
    assert_eq!((o.size, o.align, o.fields), (56, 8, vec![0, 8, 48]));
    assert_eq!(
        o.components.iter().map(|c| c.offset).collect::<Vec<_>>(),
        vec![0, 8, 16, 24, 32, 40, 48]
    );
}

#[test]
fn layout_rejects_exponential_aggregate_expansion() {
    let mut source = "struct S0 { n: Int }\n".to_string();
    for i in 1..15 {
        source.push_str(&format!("struct S{i} {{ a: S{}, b: S{} }}\n", i - 1, i - 1));
    }
    source.push_str("fn main() {}");
    let ir = check(&source).unwrap();
    let error = project_l::layout::Layouts::windows_x64(&ir.structs, &ir.enums).unwrap_err();
    assert!(error.contains("4096 componentes"), "{error}");
}
