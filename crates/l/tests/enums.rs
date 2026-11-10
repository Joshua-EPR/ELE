//! Phase C.1/C.2: enums, exhaustive `match`, prelude Option/Result, `??`, `?`
//! and `pub`. Positive cases run native executables and compare exact output.
use project_l::{
    check, lexer,
    lir::{Pattern, Type, ValueKind},
    parser,
};
use std::{fs, path::PathBuf, process::Command};

fn run(name: &str, source: Option<&str>, file: &str) -> (String, String, Option<i32>) {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/enums")
        .join(name);
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
fn cuenta_example_compiles_and_runs() {
    let (stdout, stderr, code) = run("cuenta", None, "ejemplos/cuenta.l");
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(stdout, "50\n");
}

#[test]
fn enums_example_runs() {
    let (stdout, stderr, code) = run("example", None, "examples/enums.l");
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(
        stdout,
        "Pendiente\nCompletado\nFallo de red\n2\nok 2.5\nerror: División entre cero\n\
Invitado\n40\n-1\ntreinta\n"
    );
}

#[test]
fn parser_builds_enum_match_and_types() {
    let source = "pub enum E<T> {\n A\n B(T, Int)\n}\nfn f(x: Int?) -> Result<Int, Text> = Ok(x ?? 0)\nfn main() { match 1 { 0 => print(0), _ => {} } }";
    let ast = parser::parse(lexer::lex(source).unwrap()).unwrap();
    let e = &ast.enums[0];
    assert!(e.public);
    assert_eq!(e.params, vec!["T".to_string()]);
    assert_eq!(e.variants[1].payload.len(), 2);
    let (_, param, _) = &ast.functions[0].params[0];
    assert!(
        matches!(param, parser::TypeExpr::Named(n, args, _) if n == "Option" && args.len() == 1)
    );
    let parser::Stmt::Expr(m, _) = &ast.functions[1].body[0] else {
        panic!("match statement")
    };
    assert!(matches!(&m.kind, parser::ExprKind::Match(_, arms) if arms.len() == 2));
}

#[test]
fn lir_has_discriminants_payloads_and_monomorphized_instances() {
    let source = "enum E {\n A\n B(Int, Text)\n}\nfn main() {\n let o: Int? = Some(1)\n let p = Some(true)\n let e = E.B(2, \"x\")\n match e { E.A => {}, E.B(n, _) => print(n) }\n}";
    let ir = check(source).unwrap();
    let names: Vec<&str> = ir.enums.iter().map(|e| e.name.as_str()).collect();
    assert!(names.contains(&"E"));
    assert!(names.contains(&"Option<Int>"));
    assert!(names.contains(&"Option<Bool>"));
    let e = ir.enums.iter().find(|e| e.name == "E").unwrap();
    assert_eq!(
        e.variants[1],
        ("B".to_string(), vec![Type::Int, Type::Text])
    );
    let body = &ir.functions[ir.main].body;
    let (project_l::lir::Instruction::Eval(m) | project_l::lir::Instruction::Return(m)) = &body[3]
    else {
        panic!("match")
    };
    let ValueKind::Match(scrutinee, arms) = &m.kind else {
        panic!("match value")
    };
    assert!(
        matches!(scrutinee.kind, ValueKind::Local(_)),
        "scrutinee evaluated once"
    );
    assert!(
        matches!(&arms[1].pattern, Pattern::Variant(_, 1, subs) if matches!(subs[0], Pattern::Bind(_)) && subs[1] == Pattern::Wild)
    );
}

#[test]
fn match_semantics_run_natively() {
    let source = r#"
enum Forma {
    Circulo(Float)
    Rect(Float, Float)
    Nombre(Text)
}
struct Tarea {
    estado: Forma
    intentos: Int = 0
}
impl Tarea {
    fn describe() -> Text {
        return match self.estado {
            Forma.Nombre(t) => "nombre {t}",
            Forma.Circulo(r) => "circulo {r}",
            Forma.Rect(a, b) => "rect {a}x{b}",
        }
    }
    mut fn avanzar() {
        self.intentos += 1
        self.estado = Forma.Circulo(1.5)
    }
}
fn consume(t: Text) = "consumido {t}"
fn clasifica(n: Int, b: Bool) -> Text {
    match n {
        0 => return "cero",
        -1 => return "menos uno",
        _ => {}
    }
    return match b {
        true => "si",
        false => "no",
    }
}
fn texto(t: Text) -> Int = match t {
    "uno" => 1,
    "dos" => 2,
    _ => 0,
}
fn primero(o: Int??) -> Int? {
    let interno = o?
    let v = interno?
    return Some(v + 1)
}
var_cuenta_placeholder
fn efecto(n: Int) -> Int {
    print("eval {n}")
    return n
}
fn main() {
    let f = Forma.Nombre("ana")
    match f {
        Forma.Nombre(t) => print("ref {t}"),
        _ => {}
    }
    match f {
        Forma.Nombre(t) => print(consume(t)),
        _ => print("otro"),
    }
    var t = Tarea(estado: Forma.Rect(2.0, 3.0))
    print(t.describe())
    t.avanzar()
    print("{t.describe()} {t.intentos}")
    print(clasifica(0, true))
    print(clasifica(-1, true))
    print(clasifica(5, false))
    print(texto("dos") + texto("tres"))
    print(primero(Some(Some(4))) ?? 0)
    print(primero(Some(None)) ?? 0)
    print(primero(None) ?? -5)
    match efecto(2) {
        1 => print("uno"),
        2 => print("dos"),
        _ => print("otro"),
    }
    print(Some(1) ?? efecto(99))
    var i = 0
    while i < 10 {
        i += 1
        match if_even(i) {
            None => continue,
            Some(9) => break,
            Some(v) => print("par {v}"),
        }
    }
    let anidado: Result<Text?, Text> = Ok(Some("hola"))
    match anidado {
        Ok(Some(s)) => print(s),
        Ok(None) => print("vacio"),
        Err(e) => print(e),
    }
}
fn if_even(n: Int) -> Int? {
    if n % 2 == 0 { return Some(n) }
    if n == 9 { return Some(9) }
    return None
}
"#
    .replace("var_cuenta_placeholder", "");
    let (stdout, stderr, code) = run("semantics", Some(&source), "semantics.l");
    assert_eq!(code, Some(0), "{stderr}");
    assert_eq!(
        stdout,
        "ref ana\nconsumido ana\nrect 2x3\ncirculo 1.5 1\ncero\nmenos uno\nno\n2\n5\n0\n-5\n\
eval 2\ndos\n1\npar 2\npar 4\npar 6\npar 8\nhola\n"
    );
}

#[test]
fn pub_rules() {
    let ok = "pub struct P {\n pub x: Int\n}\nimpl P {\n pub fn get() -> Int = self.x\n}\npub const K = 1\npub fn nada() {}\nfn main() { nada()\n print(P(x: K).get()) }";
    check(ok).unwrap();
    let e = check("pub fn f() { return 1 }\nfn main() {}").expect_err("pub needs return type");
    assert!(e.message.contains("se esperaba ()"), "{e:?}");
    let e = check("pub fn f() = 1\nfn main() {}").expect_err("pub needs return type");
    assert!(e.message.contains("incompatible"), "{e:?}");
    let e = check("pub impl X {}\nfn main() {}").expect_err("pub impl");
    assert!(e.message.contains("pub solo se admite"), "{e:?}");
}

#[test]
fn enum_negative_diagnostics() {
    let e = "enum E {\n A\n B(Int)\n C(Text)\n}\n";
    let cases: Vec<(String, &str, &str)> = vec![
        // Declarations.
        (format!("{e}{e}fn main() {{}}"), "semántica", "enum duplicado"),
        ("enum E { A, A }\nfn main() {}".into(), "semántica", "variante duplicada"),
        ("enum Option { A }\nfn main() {}".into(), "semántica", "reservado"),
        ("struct Some { x: Int }\nfn main() {}".into(), "semántica", "reservado"),
        ("fn Ok() {}\nfn main() {}".into(), "semántica", "reservada"),
        ("enum E { A(E) }\nfn main() {}".into(), "semántica", "tamaño infinito"),
        ("enum E { A(S) }\nstruct S { e: E }\nfn main() {}".into(), "semántica", "tamaño infinito"),
        ("enum L<T> { Cons(T, L<T>), Nil }\nfn main() { let x: L<Int> = L.Nil }".into(), "semántica", "tamaño infinito"),
        ("enum E { A(Nope) }\nfn main() {}".into(), "semántica", "tipo no definido: Nope"),
        ("enum E<T> { A(U) }\nfn main() {}".into(), "semántica", "tipo no definido: U"),
        ("enum E<T, T> { A(T) }\nfn main() {}".into(), "semántica", "duplicado"),
        ("fn main() { let x: Option<Int, Int> = None }".into(), "semántica", "argumento(s) de tipo"),
        ("fn main() { let x: Option = None }".into(), "semántica", "argumento(s) de tipo"),
        (format!("{e}fn main() {{ let x: E<Int> = E.A }}"), "semántica", "argumento(s) de tipo"),
        ("enum E { A }\nimpl E { fn A() {} }\nfn main() {}".into(), "semántica", "coincide con una variante"),
        ("impl Option { fn f() {} }\nfn main() {}".into(), "semántica", "requiere argumentos de tipo"),
        ("fn f<T>(x: U) = x\nfn main() {}".into(), "semántica", "tipo no definido: U"),
        // Construction.
        (format!("{e}fn main() {{ let x = E.Z }}"), "semántica", "no tiene la variante Z"),
        (format!("{e}fn main() {{ let x = E.B }}"), "semántica", "espera 1 valor"),
        (format!("{e}fn main() {{ let x = E.A(1) }}"), "semántica", "espera 0 valor"),
        (format!("{e}fn main() {{ let x = E.B(true) }}"), "semántica", "incompatible"),
        (format!("{e}fn main() {{ let x = E }}"), "semántica", "es un enum"),
        (format!("{e}fn main() {{ let x = E(1) }}"), "semántica", "es un enum"),
        ("fn main() { let x = None }".into(), "semántica", "no se puede inferir el parámetro T"),
        ("fn main() { let x = Ok(1) }".into(), "semántica", "no se puede inferir el parámetro E"),
        ("fn main() { let x: Int? = Some(true) }".into(), "semántica", "incompatible"),
        ("fn main() { let x: Int = None }".into(), "semántica", "no se puede inferir"),
        (format!("{e}fn main() {{ print(E.A) }}"), "semántica", "print soporta"),
        (format!("{e}fn main() {{ print(\"{{E.A}}\") }}"), "semántica", "no convertible"),
        (format!("{e}fn main() {{ let x = E.A == E.A }}"), "semántica", "use match"),
        // Match: exhaustiveness and reachability.
        (format!("{e}fn f(x: E) {{ match x {{ E.A => {{}}, E.B(_) => {{}} }} }}\nfn main() {{}}"), "semántica", "falta el caso E.C(_)"),
        (format!("{e}fn f(x: E) {{ match x {{ E.A => {{}}, E.B(1) => {{}}, E.C(_) => {{}} }} }}\nfn main() {{}}"), "semántica", "falta el caso E.B(_)"),
        ("fn f(x: Int) { match x { 1 => {} } }\nfn main() {}".into(), "semántica", "falta el caso _"),
        ("fn f(x: Bool) { match x { true => {} } }\nfn main() {}".into(), "semántica", "falta el caso false"),
        ("fn f(x: Text) { match x { \"a\" => {} } }\nfn main() {}".into(), "semántica", "no exhaustivo"),
        ("fn f(x: Int??) { match x { Some(Some(_)) => {}, None => {} } }\nfn main() {}".into(), "semántica", "falta el caso Some(None)"),
        ("fn f(x: Result<Int, Text>) { match x { Ok(_) => {} } }\nfn main() {}".into(), "semántica", "falta el caso Err(_)"),
        (format!("{e}fn f(x: E) {{ match x {{ _ => {{}}, E.A => {{}} }} }}\nfn main() {{}}"), "semántica", "inalcanzable"),
        ("fn f(x: Int) { match x { 1 => {}, 1 => {}, _ => {} } }\nfn main() {}".into(), "semántica", "inalcanzable"),
        ("fn f(x: Int?) { match x { Some(n) => {}, None => {}, Some(1) => {} } }\nfn main() {}".into(), "semántica", "inalcanzable"),
        ("fn f(x: Bool) { match x { true => {}, false => {}, _ => {} } }\nfn main() {}".into(), "semántica", "inalcanzable"),
        // Match: invalid patterns and types.
        (format!("{e}fn f(x: E) {{ match x {{ E.Z => {{}}, _ => {{}} }} }}\nfn main() {{}}"), "semántica", "no tiene la variante Z"),
        (format!("{e}fn f(x: E) {{ match x {{ E.B => {{}}, _ => {{}} }} }}\nfn main() {{}}"), "semántica", "tiene 1 dato(s); el patrón da 0"),
        (format!("{e}fn f(x: E) {{ match x {{ E.B(1, 2) => {{}}, _ => {{}} }} }}\nfn main() {{}}"), "semántica", "el patrón da 2"),
        (format!("{e}fn f(x: E) {{ match x {{ E.B(true) => {{}}, _ => {{}} }} }}\nfn main() {{}}"), "semántica", "incompatible con tipo Int"),
        (format!("{e}fn f(x: E) {{ match x {{ A => {{}}, _ => {{}} }} }}\nfn main() {{}}"), "semántica", "califíquela: E.A"),
        (format!("{e}fn f(x: E) {{ match x {{ Some(_) => {{}}, _ => {{}} }} }}\nfn main() {{}}"), "semántica", "incompatible con tipo E"),
        (format!("{e}enum F {{ A }}\nfn f(x: E) {{ match x {{ F.A => {{}}, _ => {{}} }} }}\nfn main() {{}}"), "semántica", "incompatible con tipo E"),
        ("fn f(x: Int) { match x { \"a\" => {}, _ => {} } }\nfn main() {}".into(), "semántica", "incompatible con tipo Int"),
        ("fn f(x: Float) { match x { 1.0 => {}, _ => {} } }\nfn main() {}".into(), "semántica", "Float no permitidos"),
        ("fn f(x: Int?) { match x { Some(a, b) => {}, _ => {} } }\nfn main() {}".into(), "semántica", "el patrón da 2"),
        ("fn f(x: Result<Int, Int>) { match x { Ok(a) => {}, Err(a) => {} }\n print(a) }\nfn main() {}".into(), "semántica", "no definido: a"),
        ("fn f(x: Result<Int, Int>?) { match x { Some(Ok(a)) => {}, _ => {} } }\nfn main() {}".into(), "", ""),
        ("enum P { A(Int, Int) }\nfn f(x: P) { match x { P.A(a, a) => {} } }\nfn main() {}".into(), "semántica", "nombre duplicado: a"),
        ("fn f(x: Int) { match x { _ if true => {} } }\nfn main() {}".into(), "sintaxis", "guardas"),
        ("fn f(x: Int) { match x { _ {} } }\nfn main() {}".into(), "sintaxis", "se esperaba '=>'"),
        ("fn f(x: Int) { match x { } }\nfn main() {}".into(), "semántica", "sin brazos"),
        // Match as expression: consistent arm types.
        ("fn f(x: Int) -> Int = match x { 1 => 1, _ => true }\nfn main() {}".into(), "semántica", "incompatible"),
        ("fn f(x: Int) { let y = match x { 1 => 1, _ => {} } }\nfn main() {}".into(), "semántica", "un brazo no produce valor"),
        ("fn f(x: Int) -> Int { match x { 1 => return 1, _ => {} } }\nfn main() {}".into(), "semántica", "se esperaba Int, encontrado ()"),
        // ?? and ?.
        ("fn main() { let x = 1 ?? 2 }".into(), "semántica", "?? requiere Option"),
        ("fn main() { let x: Int? = None\n let y = x ?? true }".into(), "semántica", "incompatible"),
        ("fn f(x: Int?) -> Int { let y = x?\n return y }\nfn main() {}".into(), "semántica", "requiere que la función devuelva Option"),
        ("fn f(x: Result<Int, Text>) -> Int? { let y = x?\n return Some(y) }\nfn main() {}".into(), "semántica", "no hay conversión implícita"),
        ("fn f(x: Result<Int, Text>) -> Result<Int, Int> { let y = x?\n return Ok(y) }\nfn main() {}".into(), "semántica", "no convierte errores"),
        ("fn f(x: Int?) { let y = x? }\nfn main() {}".into(), "semántica", "requiere que la función declare"),
        ("fn f(x: Int) -> Int? { let y = x?\n return None }\nfn main() {}".into(), "semántica", "? requiere Option o Result"),
        // Ownership through match.
        (format!("{e}fn take(t: Text) {{}}\nfn main() {{ let x = E.C(\"a\")\n match x {{ E.C(t) => take(t), _ => {{}} }}\n match x {{ _ => {{}} }} }}"), "ownership", "después de moverlo"),
        (format!("{e}fn main() {{ var x = E.C(\"a\")\n match x {{ E.C(t) => {{ x = E.A }}, _ => {{}} }} }}"), "ownership", "match examina"),
        (format!("{e}fn main() {{ let x = E.C(\"a\")\n match x {{ E.C(t) => {{ let y = x }}, _ => {{}} }} }}"), "ownership", "examinado por match"),
        (format!("{e}struct S {{ e: E }}\nfn take(t: Text) {{}}\nfn main() {{ let s = S(e: E.A)\n match s.e {{ E.C(t) => take(t), _ => {{}} }} }}"), "ownership", "prestado de un campo"),
        (format!("{e}fn take(t: Text) {{}}\nimpl E {{ fn f() {{ match self {{ E.C(t) => take(t), _ => {{}} }} }} }}\nfn main() {{}}"), "ownership", "prestado"),
        (format!("{e}fn take(t: Text) {{}}\nfn main() {{ let x = E.C(\"a\")\n for i in 0..2 {{ match x {{ E.C(t) => take(t), _ => {{}} }} }} }}"), "ownership", "dentro de bucle"),
        ("fn main() { let t: Text? = Some(\"a\")\n let a = t ?? \"b\"\n let b = t ?? \"c\" }".into(), "ownership", "después de moverlo"),
        ("fn main() { let t = \"a\"\n let o = Some(t)\n print(t) }".into(), "ownership", "después de moverlo"),
    ];
    for (source, category, cause) in cases {
        if category.is_empty() {
            check(&source).unwrap_or_else(|e| panic!("{source}: {e:?}"));
            continue;
        }
        let e = check(&source).expect_err(&source);
        assert_eq!(e.category, category, "{source}: {e:?}");
        assert!(e.message.contains(cause), "{source}: {e:?}");
        assert!(e.span.line > 0 && e.span.column > 0, "{source}: {e:?}");
    }
}

#[test]
fn match_ownership_accepts_safe_programs() {
    let e = "enum E {\n A\n C(Text)\n}\nfn take(t: Text) {}\n";
    for source in [
        // Reading a payload borrows: the scrutinee stays usable.
        format!(
            "{e}fn main() {{ let x = E.C(\"a\")\n match x {{ E.C(t) => print(t), _ => {{}} }}\n match x {{ E.C(t) => take(t), _ => {{}} }} }}"
        ),
        // Arms that return do not affect code after the match.
        format!(
            "{e}fn f(x: E) -> Int {{ match x {{ E.C(t) => {{ take(t)\n return 1 }}, _ => {{}} }}\n return 0 }}\nfn main() {{}}"
        ),
        // A temporary scrutinee gives owned bindings.
        format!(
            "{e}fn mk() -> E = E.C(\"a\")\nfn main() {{ match mk() {{ E.C(t) => take(t), _ => {{}} }} }}"
        ),
        // Reinitializing after a moving match.
        format!(
            "{e}fn main() {{ var x = E.C(\"a\")\n match x {{ E.C(t) => take(t), _ => {{}} }}\n x = E.A\n match x {{ _ => {{}} }} }}"
        ),
    ] {
        check(&source).unwrap_or_else(|err| panic!("{source}: {err:?}"));
    }
}

#[test]
fn malformed_match_inputs_do_not_panic() {
    let alphabet = b"match enum {}(),=>_ .?ABx1\"\nSomeNone";
    let mut seed = 4242u64;
    for _ in 0..1500 {
        let mut source = String::new();
        for _ in 0..40 {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
            source.push(alphabet[(seed >> 32) as usize % alphabet.len()] as char);
        }
        let _ = check(&source);
        let _ = check(&format!("enum E {{ A, B(Int) }}\nfn main() {{ {source} }}"));
    }
}
