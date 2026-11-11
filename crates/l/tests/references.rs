//! Positive and negative tests for safe references and native struct methods
//! (immutable, mutable and static) on Cranelift backend.

use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/references")
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
    assert!(ref_err.is_empty(), "rustc stderr: {ref_err}");
    assert_eq!(ref_out, expected_stdout, "rustc stdout mismatch");

    // 2. Cranelift backend native execution with memory instrumentation
    let clif_exe = build(&dir, &file, &["--backend", "cranelift", "--trace-alloc"]);
    let (clif_out, clif_err, clif_code) = run(&clif_exe);
    assert_eq!(clif_code, Some(0), "cranelift failed: {clif_err}");
    assert_eq!(clif_err.lines().count(), 1, "cranelift stderr: {clif_err}");
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
        "fuga de memoria o doble liberación detectada: {line}"
    );
}

#[test]
fn test_contador_canonical_example() {
    let src = r#"
struct Contador {
    valor: Int = 0
}

impl Contador {
    fn obtener() -> Int {
        return self.valor
    }

    mut fn incrementar() {
        self.valor += 1
    }

    static fn nuevo() -> Contador {
        return Contador(valor: 0)
    }
}

fn main() {
    var contador = Contador.nuevo()

    contador.incrementar()
    contador.incrementar()

    print(contador.obtener())
}
"#;
    check_native_program("contador_canonical", src, "2\n");
}

#[test]
fn test_nested_structs_and_methods() {
    let src = r#"
struct Posicion {
    x: Int = 0,
    y: Int = 0
}

impl Posicion {
    mut fn mover(dx: Int, dy: Int) {
        self.x += dx
        self.y += dy
    }

    fn suma() -> Int {
        return self.x + self.y
    }
}

struct Entidad {
    id: Int,
    pos: Posicion,
    nombre: Text
}

impl Entidad {
    mut fn trasladar(dx: Int, dy: Int) {
        self.pos.mover(dx, dy)
    }

    fn info() -> Int {
        return self.pos.suma()
    }
}

fn main() {
    var e = Entidad(id: 1, pos: Posicion(x: 10, y: 20), nombre: "Heroe")
    e.trasladar(5, -2)
    print(e.info())
}
"#;
    check_native_program("nested_structs", src, "33\n");
}

#[test]
fn test_nested_method_calls_and_value_returns() {
    let src = r#"
struct Acumulador {
    total: Int = 0
}

impl Acumulador {
    mut fn agregar(n: Int) {
        self.total += n
    }

    fn valor() -> Int {
        return self.total
    }

    static fn crear(inicial: Int) -> Acumulador {
        var a = Acumulador(total: 0)
        a.agregar(inicial)
        return a
    }
}

fn procesar(inicial: Int) -> Int {
    var a = Acumulador.crear(inicial)
    a.agregar(10)
    a.agregar(20)
    return a.valor()
}

fn main() {
    let res = procesar(5)
    print(res)
}
"#;
    check_native_program("nested_calls", src, "35\n");
}

#[test]
fn test_references_and_drops_with_text() {
    let src = r#"
struct Elemento {
    etiqueta: Text,
    cuenta: Int
}

impl Elemento {
    fn mostrar() {
        print("{self.etiqueta}: {self.cuenta}")
    }

    mut fn inc() {
        self.cuenta += 1
    }
}

fn main() {
    var e = Elemento(etiqueta: "Contador", cuenta: 10)
    e.inc()
    e.mostrar()
}
"#;
    check_native_program("refs_and_drops", src, "Contador: 11\n");
}

#[test]
fn test_negative_diagnostics_references_and_methods() {
    let cases = [
        // 1. Mutar mediante &T / método inmutable
        (
            "struct C { v: Int }\nimpl C { fn f() { self.v = 1 } }\nfn main() {}",
            "semántica",
            "binding inmutable",
        ),
        // 2. Modificar variable inmutable mediante método mutable
        (
            "struct C { v: Int }\nimpl C { mut fn f() { self.v += 1 } }\nfn main() { let c = C(v: 0)\n c.f() }",
            "semántica",
            "receptor mutable",
        ),
        // 3. Acceder a self desde static fn
        (
            "struct C { v: Int }\nimpl C { static fn f() -> Int { return self.v } }\nfn main() {}",
            "semántica",
            "self solo está disponible",
        ),
        // 4. Invocar método estático sobre instancia
        (
            "struct C { v: Int }\nimpl C { static fn f() -> Int = 1 }\nfn main() { let c = C(v: 0)\n c.f() }",
            "semántica",
            "static fn",
        ),
        // 5. Devolver referencia a variable local que deja de existir
        (
            "fn f() { let x = 1\n return &x }\nfn main() {}",
            "semántica",
            "devolver una referencia a una variable local que deja de existir",
        ),
        // 6. Préstamo mutable de variable inmutable
        (
            "struct C { v: Int }\nimpl C { mut fn inc() { self.v += 1 } }\nfn modificar(c: &mut C) { c.inc() }\nfn main() { let c = C(v: 1)\n modificar(&mut c) }",
            "semántica",
            "no se puede prestar mutablemente",
        ),
        // 7. Usar variable después de mover su valor
        (
            "struct C { v: Int }\nfn mover(c: C) = c.v\nfn main() { let c = C(v: 1)\n mover(c)\n print(c.v) }",
            "ownership",
            "después de moverlo",
        ),
        // 8. Mover el receptor en sus propios argumentos
        (
            "struct C { v: Int }\nimpl C { fn f(otro: C) = 1 }\nfn main() { var c = C(v: 1)\n c.f(c); }",
            "ownership",
            "receptor se mueve",
        ),
        // 9. Reasignar self completo
        (
            "struct C { v: Int }\nimpl C { mut fn f() { self = C(v: 1) } }\nfn main() {}",
            "semántica",
            "no se puede reasignar self completo",
        ),
    ];

    for (src, expected_category, expected_msg_part) in cases {
        let err = check(src).expect_err(&format!("Debe fallar:\n{src}"));
        assert_eq!(
            err.category, expected_category,
            "Categoría incorrecta para:\n{src}\nDiagnóstico: {err:?}"
        );
        assert!(
            err.message.contains(expected_msg_part),
            "Mensaje '{:?}' no contiene '{}' en:\n{src}",
            err.message,
            expected_msg_part
        );
    }
}

/// Regression: references may only be passed as arguments to reference
/// parameters. Every way of storing or returning one used to be accepted
/// (dangling references) or to crash the compiler with an internal LIR error;
/// all must now be readable semantic errors.
#[test]
fn reference_escapes_are_rejected_with_readable_errors() {
    let cases = [
        // Returned through a call: used to compile into a dangling pointer.
        "fn pick(a: &Int, b: &Int) -> &Int = a\nfn g() -> &Int {\n let x = 41\n let y = 2\n return pick(&x, &y)\n}\nfn main() {}",
        // Struct field holding a reference to a local.
        "struct H {\n r: &Int\n}\nfn mk() -> H {\n let x = 1\n return H(r: &x)\n}\nfn main() {}",
        // Reference stored in a local, then returned.
        "fn g() {\n let x = 1\n let r = &x\n return &r\n}\nfn main() {}",
        // Reference inside Option.
        "fn g() -> Option<&Int> {\n let x = 1\n return Some(&x)\n}\nfn main() {}",
        // Reference outliving an inner scope.
        "fn main() {\n let y = 0\n var r = &y\n {\n  let x = 5\n  r = &x\n }\n}",
        // Wrapped through a helper that builds a struct.
        "struct H {\n r: &Int\n}\nfn wrap(a: &Int) -> H = H(r: a)\nfn main() {}",
        // Direct return of a local borrow.
        "fn f() {\n let x = 1\n return &x\n}\nfn main() {}",
        // Borrow inside an interpolation or an arithmetic expression.
        "fn main() {\n let x = 1\n print(\"{&x}\")\n}",
        // Borrow passed to a by-value parameter.
        "fn f(a: Int) = a\nfn main() {\n let x = 1\n print(f(&x))\n}",
        // &mut where &T is expected and vice versa.
        "fn f(a: &Int) = 1\nfn main() {\n var x = 1\n print(f(&mut x))\n}",
        "fn f(a: &mut Int) = 1\nfn main() {\n var x = 1\n print(f(&x))\n}",
        // A temporary cannot be borrowed implicitly.
        "fn f(a: &Int) = 1\nfn main() {\n print(f(1 + 2))\n}",
    ];
    for src in cases {
        let err = check(src).expect_err(src);
        assert!(
            matches!(err.category, "semántica" | "préstamos"),
            "{src}\n{err:?}"
        );
        assert_ne!(err.code, "L0007", "error interno en:\n{src}");
    }
}

#[test]
fn shared_reference_parameters_borrow_places_implicitly() {
    let src = r#"
struct P {
    x: Int
    nombre: Text
}
fn mostrar(p: &P) {
    print("{p.nombre}={p.x}")
}
fn inc(p: &mut P) {
    p.x += 1
}
fn total(a: &P, b: &P) -> Int = a.x + b.x
fn main() {
    var p = P(x: 1, nombre: "p")
    let q = P(x: 10, nombre: "q")
    inc(&mut p)
    mostrar(p)
    mostrar(&p)
    print(total(p, q))
    print(total(&p, q))
    // `p` and `q` are still owned and usable after implicit borrows.
    print("{p.nombre}{q.nombre}")
}
"#;
    check_native_program("implicit_borrow", src, "p=2\np=2\n12\n12\npq\n");
}

/// Regression: every borrow passed to one call lives for the whole call, so a
/// `&mut` argument may not overlap any other borrow (or the receiver).
#[test]
fn simultaneous_borrows_in_one_call_respect_exclusivity() {
    let p = "struct Q {\n a: Int\n b: Int\n}\nstruct P {\n q: Q\n x: Int\n}\n";
    for call in [
        "dos(&mut p, &p)",
        "dos(&mut p, p)",
        "mm(&mut p, &mut p)",
        "campos(&mut p.q, &p.q)",
        "campo_y_todo(&mut p.q, &p)",
    ] {
        let src = format!(
            "{p}fn dos(a: &mut P, b: &P) {{}}\nfn mm(a: &mut P, b: &mut P) {{}}\nfn campos(a: &mut Q, b: &Q) {{}}\nfn campo_y_todo(a: &mut Q, b: &P) {{}}\nfn main() {{\n var p = P(q: Q(a: 1, b: 2), x: 3)\n {call}\n}}"
        );
        let err = check(&src).expect_err(call);
        assert_eq!(err.category, "ownership", "{call}: {err:?}");
        assert!(err.message.contains("préstamo"), "{call}: {err:?}");
    }
    // Disjoint fields and shared-only borrows are fine.
    check(&format!(
        "{p}fn f(a: &mut Q, b: &Int) {{}}\nfn g(a: &P, b: &P) {{}}\nfn main() {{\n var p = P(q: Q(a: 1, b: 2), x: 3)\n f(&mut p.q, &p.x)\n g(p, p)\n}}"
    ))
    .unwrap();
}

#[test]
fn local_loans_end_at_last_use_and_reborrow_fields() {
    check_native_program(
        "local_loans",
        r#"
struct Point { x: Int, y: Int }
fn increment(x: &mut Int) { x += 1 }
fn main() {
 var n = 42
 let a = &n
 let b: &Int = &n
 print(a + b)
 n = 10
 let w = &mut n
 let child = &mut w
 increment(&mut child)
 print(child)
 w += 1
 print(n)
 var p = Point(x: 1, y: 2)
 let px = &mut p.x
 let py = &mut p.y
 px += 10
 py += 20
 print(px + py)
}
"#,
        "84\n11\n12\n33\n",
    );
}

#[test]
fn regional_list_and_array_element_loans() {
    check_native_program(
        "element_loans",
        r#"
fn display(xs: &[Int]) {
 let vista = &xs
 let first = &vista[0]
 print(first)
}
fn main() {
 var a = [7, 8]
 let m = &mut a[1]
 m = 9
 display(a)
 print(a[1])
 var xs = List[10, 20]
 let x = &xs[0]
 print(x)
 xs.push(30)
 region r {
  var names = r.list<Text>()
  names.push("a{10 + 1}")
  let entry = &mut names[0]
  var n = 12
  entry = "b{n}"
  print(entry)
  names.reserve(100)
  print(names[0])
 }
}
"#,
        "7\n9\n10\nb12\nb12\n",
    );
}

#[test]
fn loans_follow_branches_and_loop_back_edges() {
    check_native_program(
        "loan_flow",
        r#"
fn show(flag: Bool) {
 var n = 10
 let r = &n
 if flag { print(r) } else { n = 20 }
 n += 1
 print(n)
}
fn main() {
 show(true)
 show(false)
 var n = 0
 for i in 0..3 {
  let p = &mut n
  p += i
  if i == 1 { continue }
  print(p)
 }
 print(n)
}
"#,
        "10\n11\n21\n0\n3\n3\n",
    );
}

#[test]
fn conflicting_local_loans_report_origins_and_live_uses() {
    for source in [
        "fn main() { var n = 0\n let r = &n\n let m = &mut n\n print(r) }",
        "fn main() { var n = 0\n let r = &mut n\n print(n)\n print(r) }",
        "fn main() { var n = 0\n let p = &mut n\n let r = &p\n p = 1\n print(r) }",
        "fn main() { var xs = List[1]\n let r = &xs[0]\n xs.push(2)\n print(r) }",
        "fn main() { region r { var xs = r.list<Int>()\n xs.push(1)\n let y = &xs[0]\n xs.reserve(8)\n print(y) } }",
        "fn main() { var n = 0\n let r = &n\n for i in 0..3 { print(r)\n n = 1 } }",
        "fn main() { var xs = List[1, 2]\n let x = &mut xs[0]\n let y = &mut xs[1]\n print(x + y) }",
        "fn main() { let xs = List[1]\n let r = &xs[0]\n let ys = xs\n print(r) }",
    ] {
        let error = check(source).expect_err(source);
        assert_eq!(error.code, "L0012", "{source}: {error:?}");
        assert!(
            error.message.contains("Préstamo iniciado") && error.message.contains("uso vivo"),
            "{error:?}"
        );
    }
}

#[test]
fn conflicting_call_reborrows_use_normalized_origins() {
    let source = "fn f(a: &mut Int, b: &Int) { print(b) }\nfn main() { var n = 0\n let p = &mut n\n f(&mut p, &p) }";
    assert!(check(source).is_err());
    let source = "fn f(a: &mut Int, b: &Int) { print(b) }\nfn main() { var n = 0\n let p = &mut n\n let q = &p\n f(&mut p, &q) }";
    assert_eq!(check(source).unwrap_err().code, "L0012");
}

#[test]
fn slice_locals_keep_the_owner_borrowed_until_last_use() {
    check_native_program(
        "local_slices",
        r#"
fn main() {
 region r {
  var xs = r.list<Int>()
  xs.push(7)
  xs.push(8)
  let vista: &mut [Int] = &mut xs
  vista[0] = 9
  let read: &[Int] = &vista
  print(read.length)
  print(read[0])
  xs.push(10)
  print(xs.length)
 }
}
"#,
        "2\n9\n3\n",
    );
    let source =
        "fn main() { var xs = List[1]\n let vista: &[Int] = &xs\n xs.push(2)\n print(vista[0]) }";
    assert_eq!(check(source).unwrap_err().code, "L0012");
}

#[test]
fn loans_activate_after_index_and_call_value_arguments() {
    check_native_program(
        "loan_eval_order",
        r#"
fn idx(xs: &mut List<Int>) -> Int {
 xs.push(8)
 return 1
}
fn add_to(a: &mut Int, n: Int) { a += n }
fn main() {
 var xs = List[3]
 let x = &mut xs[idx(&mut xs)]
 add_to(&mut x, x)
 print(x)
}
"#,
        "16\n",
    );
}

#[test]
fn loans_reject_computed_places_and_respect_iteration() {
    for (source, code) in [
        (
            "fn main() { let xs = List[1]\n let r = &xs.length }",
            "L0012",
        ),
        (
            "fn main() { var xs = List[1]\n for x in xs { let w = &mut xs\n w.push(2) } }",
            "L0005",
        ),
        (
            "fn main() { var xs = List[1]\n let m = &mut xs\n for x in m { let w = &mut m\n w.push(2) } }",
            "L0005",
        ),
    ] {
        assert_eq!(check(source).unwrap_err().code, code, "{source}");
    }
}

#[test]
fn cfg_loan_preserves_place_mode_and_referent_type() {
    use project_l::{
        cfg::{self, InstKind, Proj, Rvalue},
        lir::Type,
    };
    let ir = check("fn main() { var a = [1, 2]\n let x = &mut a[0]\n x = 3\n print(x) }").unwrap();
    let mut cfg = project_l::lower_to_cfg(&ir).unwrap();
    let loan = cfg.funcs[cfg.main]
        .blocks
        .iter_mut()
        .flat_map(|b| &mut b.insts)
        .find_map(|i| match &mut i.kind {
            InstKind::Assign(_, Rvalue::Loan(place, true, ty)) => Some((place, ty)),
            _ => None,
        })
        .expect("mutable element loan");
    assert!(matches!(loan.0.proj.as_slice(), [Proj::Index(_)]));
    assert_eq!(*loan.1, Type::Int);
    *loan.1 = Type::Bool;
    assert!(
        cfg::verify(&cfg)
            .unwrap_err()
            .message
            .contains("origen del préstamo")
    );
}

#[test]
fn reference_returns_follow_parameter_through_calls_and_control_flow() {
    check_native_program(
        "return_chain",
        r#"
fn identidad(valor: &Int) -> &Int { return valor }
fn generica<T>(valor: &T) -> &T = valor
fn elegir(x: &Int, temprano: Bool) -> &Int {
 if temprano { return identidad(x) }
 let r = generica<Int>(x)
 return r
}
fn main() {
 var n = 42
 let a = elegir(n, true)
 let b: &Int = elegir(n, false)
 print(a)
 print(b)
 n = 7
 print(n)
}
"#,
        "42\n42\n7\n",
    );
}

#[test]
fn borrowed_text_fields_and_mutable_methods_return_addresses() {
    check_native_program(
        "return_field",
        r#"
struct User { name: Text, age: Int }
struct Outer { user: User }
fn name(x: &Outer) -> &Text { return &x.user.name }
impl User {
 mut fn age_ref() -> &mut Int { return &mut self.age }
}
fn identity(n: &mut Int) -> &mut Int = n
fn main() {
 var i = 1
 var x = Outer(user: User(name: "Ana {i}", age: 30))
 let a = name(x)
 print(a)
 let edad = x.user.age_ref()
 let r = identity(&mut edad)
 r += 2
 print(r)
 x.user.age += 1
 print(x.user.age)
}
"#,
        "Ana 1\n32\n33\n",
    );
}

#[test]
fn returned_collection_elements_retain_slice_origin() {
    check_native_program(
        "return_slice_element",
        r#"
fn first(xs: &[Int]) -> &Int { return &xs[0] }
fn elem(xs: &mut [Int], i: Int) -> &mut Int { return &mut xs[i] }
fn main() {
 var a = [1, 2]
 let x = elem(&mut a, 1)
 x = 3
 print(first_value(a))
 var heap = List[4, 5]
 let h = first(heap)
 print(h)
 heap.push(6)
 region arena {
  var nums = arena.list<Int>()
  nums.push(7)
  let r = elem(&mut nums, 0)
  r += 1
  print(r)
  nums.push(9)
  print(nums.length)
 }
}
fn first_value(xs: &[Int]) -> Int {
 let r = first(xs)
 return r + xs[1]
}
"#,
        "4\n4\n8\n2\n",
    );
}

#[test]
fn reference_return_escapes_are_rejected_before_codegen() {
    for source in [
        "fn f() -> &Int { let a = 1\n return &a }\nfn main() {}",
        "fn f(p: &Int) -> &Int { return &(p + 1) }\nfn main() {}",
        "fn f(p: &Int) -> &Int { let a = List[1]\n return &a[0] }\nfn main() {}",
        "fn f(p: &Int) -> &Int { region r { var a = r.list<Int>()\n a.push(1)\n return &a[0] } }\nfn main() {}",
        "fn f(a: &Int, b: &Int) -> &Int { let local = 1\n return &local }\nfn main() {}",
        "fn f(p: &Int) -> &mut Int { return p }\nfn main() {}",
        "fn id(p: &Int) -> &Int = p\nfn f(p: &Int) -> &Int { let a = 1\n return id(a) }\nfn main() {}",
    ] {
        let error = check(source).expect_err(source);
        assert_eq!(error.code, "L0013", "{source}: {error:?}");
    }
}

#[test]
fn callers_cannot_invalidate_a_returned_loan() {
    for source in [
        "fn first(xs: &[Int]) -> &Int = &xs[0]\nfn main() { var xs = List[1]\n let r = first(xs)\n xs.push(2)\n print(r) }",
        "fn first(xs: &[Int]) -> &Int = &xs[0]\nfn main() { let xs = List[1]\n let r = first(xs)\n let other = xs\n print(r) }",
        "fn id(x: &mut Int) -> &mut Int = x\nfn main() { var n = 1\n let a = id(&mut n)\n let b = id(&mut n)\n print(a) }",
        "fn read(x: &mut Int) -> &Int = &x\nfn main() { var n = 1\n let a = read(&mut n)\n print(n)\n print(a) }",
        "fn first(xs: &[Int]) -> &Int = &xs[0]\nfn main() { region r { var a = r.list<Int>()\n a.push(1)\n let x = first(a)\n a.reserve(100)\n print(x) } }",
    ] {
        assert_eq!(check(source).unwrap_err().code, "L0012", "{source}");
    }
}

#[test]
fn cfg_reference_return_is_pointer_typed_and_has_contract() {
    use project_l::{
        cfg::{self, Terminator, VarTy},
        lir::Type,
    };
    let ir =
        check("fn id(x: &Int) -> &Int = x\nfn main() { let x = 2\n let r = id(x)\n print(r) }")
            .unwrap();
    let mut module = project_l::lower_to_cfg(&ir).unwrap();
    let id = module.funcs.iter_mut().find(|f| f.name == "id").unwrap();
    assert_eq!(id.borrow_return.as_ref().unwrap().params, [0]);
    assert!(id.blocks.iter().any(|b| matches!(b.term, Some(Terminator::ReturnRef(v, _)) if id.vars[v] == VarTy::Ref(Type::Int))));
    id.borrow_return = None;
    assert!(
        cfg::verify(&module)
            .unwrap_err()
            .message
            .contains("sin contrato")
    );
}

#[test]
fn recursive_return_and_mutable_text_replacement_preserve_drops() {
    check_native_program(
        "return_recursion",
        r#"
fn select(n: Int, text: &mut Text) -> &mut Text {
 let scratch = "scratch {n}"
 if n == 0 { return text }
 return select(n - 1, &mut text)
}
fn main() {
 var n = 42
 var data = "before {n}"
 let r = select(3, &mut data)
 r = "after {n}"
 print(r)
 print(data)
}
"#,
        "after 42\nafter 42\n",
    );
}

#[test]
fn result_origin_cannot_be_consumed_during_argument_evaluation() {
    let source = "fn f(a: &Text, b: Text) -> &Text = a\nfn main() { let x = \"test\"\n let r = f(x, x)\n print(r) }";
    assert_eq!(check(source).unwrap_err().code, "L0005");
}

#[test]
fn multiple_origins_survive_recursion_and_disjoint_field_reborrows() {
    check_native_program(
        "escape_multi",
        r#"
struct Pair { first: Int, second: Int }
fn elegir(a: &Int, b: &Int, first: Bool) -> &Int {
 if first { return a }
 return b
}
fn left(a: &Int, b: &Int, n: Int) -> &Int {
 if n == 0 { return elegir(a, b, false) }
 return right(b, a, n - 1)
}
fn right(a: &Int, b: &Int, n: Int) -> &Int = left(a, b, n)
fn choose_mut(a: &mut Int, b: &mut Int, first: Bool) -> &mut Int {
 if first { return a }
 return b
}
fn main() {
 var p = Pair(first: 10, second: 20)
 let a = &mut p.first
 let b = &mut p.second
 let selected = choose_mut(&mut a, &mut b, false)
 selected += 2
 print(selected)
 let read = left(p.first, p.second, 1)
 print(read)
 p.first += 1
 print(p.first)
}
"#,
        "22\n10\n11\n",
    );
}

#[test]
fn returned_slices_borrow_heap_and_regional_lists() {
    check_native_program(
        "escape_slices",
        r#"
fn vista(a: &[Int], b: &[Int], first: Bool) -> &[Int] {
 if first { return a }
 return b
}
fn write_view(xs: &mut [Int]) -> &mut [Int] = xs
fn main() {
 var heap = List[10, 11]
 region r {
  var regional = r.list<Int>()
  regional.push(20)
  let a = write_view(&mut regional)
  a[0] = 21
  let b = vista(heap, a, false)
  print(b[0])
  regional.push(22)
  let c = vista(heap, regional, true)
  print(c.length)
  print(c[1])
  heap.reserve(40)
 }
}
"#,
        "21\n2\n11\n",
    );
}

#[test]
fn all_possible_origins_remain_live_and_must_outlive_the_result() {
    let elegir =
        "fn elegir(a: &Int, b: &Int, first: Bool) -> &Int { if first { return a }\n return b }\n";
    for source in [
        "fn main() { var a = 1\n var b = 2\n let x = elegir(a, b, true)\n b = 3\n print(x) }",
        "fn main() { var a = 1\n var b = 2\n let x = elegir(a, b, false)\n a = 3\n print(x) }",
    ] {
        assert_eq!(
            check(&format!("{elegir}{source}")).unwrap_err().code,
            "L0012"
        );
    }
    let err = check(&format!("{elegir}fn bad(a: &Int) -> &Int {{ let b = 3\n return elegir(a, b, true) }}\nfn main() {{}}")).unwrap_err();
    assert_eq!(err.code, "L0013");
    assert!(err.message.contains("posible origen"));
    let overlap = "fn elegir(a: &mut Int, b: &mut Int) -> &mut Int = a\nfn main() { var x = 1\n let a = &mut x\n let r = elegir(&mut a, &mut x)\n print(r) }";
    assert_eq!(check(overlap).unwrap_err().code, "L0012");
    let regional = "fn pick(a: &[Int], b: &[Int]) -> &[Int] = a\nfn bad(a: &[Int]) -> &[Int] { region r { var xs = r.list<Int>()\n xs.push(1)\n return pick(a, xs) } }\nfn main() {}";
    assert_eq!(check(regional).unwrap_err().code, "L0013");
}

#[test]
fn attempted_aggregate_storage_is_classified_before_codegen() {
    for (source, code) in [
        (
            "struct View { p: &Text }\nstruct Holder { v: View }\nfn main() {}",
            "L0014",
        ),
        ("struct View<T> { p: &T }\nfn main() {}", "L0014"),
        ("enum View<T> { Borrowed(&T) }\nfn main() {}", "L0014"),
        (
            "struct H { val: Int }\nfn id(x: &Int) -> &Int = x\nfn main() { let x = 1\n let h = H(val: id(x)) }",
            "L0014",
        ),
        (
            "fn id(x: &Int) -> &Int = x\nfn main() { let x = 1\n var xs = List[2]\n xs.push(id(x)) }",
            "L0014",
        ),
        (
            "fn main() { let x = 1\n var xs = [2]\n xs[0] = &x }",
            "L0001",
        ),
    ] {
        let err = check(source).expect_err(source);
        assert_eq!(err.code, code, "{source}: {err:?}");
    }
}

#[test]
fn escape_summaries_distinguish_return_call_and_local_uses() {
    use std::collections::BTreeSet;
    let ir = check(
        r#"
fn read(x: &Int) -> Int = x
fn elegir(a: &Int, b: &Int, first: Bool) -> &Int {
 if first { return a }
 return b
}
fn forward(a: &Int, b: &Int, first: Bool) -> &Int = elegir(a, b, first)
fn call_only(a: &Int, b: &Int) -> Int = read(a) + b
struct P { left: Int, right: Int }
fn field(p: &P) -> &Int = &p.right
fn index(xs: &[Int]) -> &Int = &xs[0]
struct View { field: &Int }
fn packed(x: &Int) -> Int { let v = View(field: &x)
 return v.field }
fn main() {}
"#,
    )
    .unwrap();
    let module = project_l::lower_to_cfg(&ir).unwrap();
    let summaries = project_l::escape_summaries(&module).unwrap();
    let summary = |name| &summaries[module.funcs.iter().position(|f| f.name == name).unwrap()];
    let returned = |name| {
        summary(name)
            .return_origins
            .iter()
            .map(|o| o.parameter)
            .collect::<BTreeSet<_>>()
    };
    assert_eq!(returned("elegir"), BTreeSet::from([0, 1]));
    assert!(summary("elegir").forwarded_params.is_empty());
    assert_eq!(returned("forward"), BTreeSet::from([0, 1]));
    assert_eq!(summary("forward").forwarded_params, BTreeSet::from([0, 1]));
    assert!(returned("call_only").is_empty());
    assert_eq!(summary("call_only").forwarded_params, BTreeSet::from([0]));
    assert!(returned("read").is_empty());
    use project_l::{EscapeProjection, ReturnOrigin};
    for (name, projection) in [
        ("field", EscapeProjection::Field(1)),
        ("index", EscapeProjection::Indexed),
    ] {
        assert_eq!(
            summary(name).return_origins,
            BTreeSet::from([ReturnOrigin {
                parameter: 0,
                projection: vec![projection]
            }])
        );
    }
    assert!(summary("read").forwarded_params.is_empty());
    assert!(summary("packed").return_origins.is_empty());
    assert_eq!(summary("packed").local_view_params, BTreeSet::from([0]));
}

#[test]
fn local_view_keeps_shared_scalar_origin_through_a_move() {
    check_native_program(
        "view_scalar",
        r#"
struct Vista { valor: &Int }
struct Pair { a: Int, b: Int }
fn main() {
 var numero = 42
 let vista: Vista = Vista(valor: &numero)
 let otra = vista
 print(otra.valor)
 numero = 7
 print(numero)
 var p = Pair(a: 12, b: 2)
 let field = Vista(valor: &p.a)
 p.b = 3
 print(field.valor + p.b)
}
"#,
        "42\n7\n15\n",
    );
}

#[test]
fn local_view_drops_its_owned_fields_but_keeps_the_referent() {
    check_native_program(
        "view_drop",
        r#"
struct Owned { label: Text }
struct View { label: &Text, count: &Int, active: &Bool, score: &Float, owned: Owned }
fn show(x: Int) {
 let source = "data {x}"
 let active = true
 let score = 1.25
 {
  let vista = View(label: &source, count: &x, active: &active, score: &score, owned: Owned(label: "owned {x}"))
  let moved = vista
  print(moved.label)
  print(moved.count)
  print(moved.active)
  print(moved.score)
  print(moved.owned.label)
  if x == 7 { return }
 }
 print(source)
}
fn main() {
 show(7)
 show(8)
}
"#,
        "data 7\n7\ntrue\n1.25\nowned 7\ndata 8\n8\ntrue\n1.25\nowned 8\ndata 8\n",
    );
}

#[test]
fn view_of_regional_element_keeps_the_list_borrowed() {
    check_native_program(
        "view_region",
        r#"
struct V { x: &Int }
fn main() {
 region r {
  var xs = r.list<Int>()
  xs.push(21)
  let v = V(x: &xs[0])
  let moved = v
  print(moved.x)
  xs.push(22)
  print(xs.length)
 }
}
"#,
        "21\n2\n",
    );
    let source = "struct V { x: &Int }\nfn main() { region r { var xs = r.list<Int>()\n xs.push(21)\n let v = V(x: &xs[0])\n xs.reserve(100)\n print(v.x) } }";
    assert_eq!(check(source).unwrap_err().code, "L0012");
}

#[test]
fn views_reject_invalidated_owners_and_moved_bindings() {
    for (source, code) in [
        (
            "struct V { x: &Int }\nfn main() { var x = 1\n let v = V(x: &x)\n x = 2\n print(v.x) }",
            "L0012",
        ),
        (
            "struct V { x: &Int }\nfn main() { let xs = List[1]\n let v = V(x: &xs[0])\n let moved = xs\n print(v.x) }",
            "L0012",
        ),
        (
            "struct V { x: &Int }\nfn main() { let x = 1\n let v = V(x: &x)\n let moved = v\n print(v.x) }",
            "L0005",
        ),
        (
            "struct V { x: &Text }\nfn main() { let x = \"s\"\n let v = V(x: &x)\n let own = v.x }",
            "L0005",
        ),
        (
            "struct V { x: &Int }\nfn main() { var x = 1\n let parent = &mut x\n let v = V(x: &parent)\n parent = 2\n print(v.x) }",
            "L0012",
        ),
    ] {
        let error = check(source).expect_err(source);
        assert_eq!(error.code, code, "{source}: {error:?}");
    }
}

#[test]
fn views_cannot_escape_or_change_their_origin() {
    for source in [
        "struct V { x: &Int }\nfn main() { let v = V(x: &(1+2)) }",
        "struct V { x: &Int }\nfn make() -> V { let x = 1\n return V(x: &x) }\nfn main() {}",
        "struct V { x: &Int }\nfn make() { let x = 1\n let v = V(x: &x)\n return v }\nfn main() {}",
        "struct V { x: &Int }\nfn make() { region r { var xs = r.list<Int>()\n xs.push(1)\n return V(x: &xs[0]) } }\nfn main() {}",
        "struct V { x: &Int }\nfn main() { let x = 1\n let v = V(x: &x)\n let vs = List[v] }",
        "struct V { x: &Int }\nfn main() { let x = 1\n let v = V(x: &x)\n let vs = Option.Some(v) }",
        "struct V { x: &Int }\nstruct Outer { v: V }\nfn main() {}",
        "struct V { x: &Int }\nfn main() { let x = 1\n let v = V(x: &x)\n print(V(x: &x).x) }",
    ] {
        let error = check(source).expect_err(source);
        assert_eq!(error.code, "L0014", "{source}: {error:?}");
    }
}

#[test]
fn cfg_view_uses_a_typed_pointer_field() {
    use project_l::{
        cfg::{self, InstKind, Proj, Rvalue, VarTy},
        lir::Type,
    };
    let ir = check("struct V { x: &Int, y: Int }\nfn main() { let x = 1\n let v = V(x: &x, y: 2)\n print(v.x) }").unwrap();
    let mut module = project_l::lower_to_cfg(&ir).unwrap();
    let f = &mut module.funcs[module.main];
    let (dest, place) = f
        .blocks
        .iter_mut()
        .flat_map(|b| &mut b.insts)
        .find_map(|inst| match &mut inst.kind {
            InstKind::Assign(dest, Rvalue::FieldLoan(place)) => Some((*dest, place)),
            _ => None,
        })
        .unwrap();
    assert_eq!(f.vars[dest], VarTy::Ref(Type::Int));
    assert_eq!(place.proj, [Proj::Field(0)]);
    place.proj[0] = Proj::Field(1);
    assert!(
        cfg::verify(&module)
            .unwrap_err()
            .message
            .contains("puntero prestado")
    );
}

#[test]
fn test_returned_view_struct_canonical() {
    check_native_program(
        "view_return_canonical",
        r#"
struct Usuario {
    nombre: Text
    edad: Int
}

struct VistaUsuario {
    nombre: &Text
}

fn crearVista(usuario: &Usuario) -> VistaUsuario {
    return VistaUsuario(
        nombre: &usuario.nombre
    )
}

fn main() {
    let usuario = Usuario(
        nombre: "Ana",
        edad: 25
    )

    let vista = crearVista(usuario)

    print(vista.nombre)
}
"#,
        "Ana\n",
    );
}

#[test]
fn test_returned_view_struct_forwarding_and_chaining() {
    check_native_program(
        "view_return_forward",
        r#"
struct Usuario {
    nombre: Text
    edad: Int
}

struct VistaUsuario {
    nombre: &Text
}

fn crearVista(usuario: &Usuario) -> VistaUsuario {
    return VistaUsuario(nombre: &usuario.nombre)
}

fn reenviarVista(usuario: &Usuario) -> VistaUsuario {
    return crearVista(usuario)
}

fn main() {
    let usuario = Usuario(nombre: "Carlos", edad: 40)
    let vista1 = reenviarVista(usuario)
    print(vista1.nombre)
    print(crearVista(usuario).nombre)
}
"#,
        "Carlos\nCarlos\n",
    );
}

#[test]
fn test_returned_view_struct_with_owned_fields() {
    check_native_program(
        "view_return_mixed",
        r#"
struct Usuario {
    nombre: Text
}

struct VistaConEtiqueta {
    etiqueta: Text
    ref_nombre: &Text
}

fn crearEtiquetada(u: &Usuario, prefijo: Text) -> VistaConEtiqueta {
    return VistaConEtiqueta(
        etiqueta: prefijo,
        ref_nombre: &u.nombre
    )
}

fn main() {
    let u = Usuario(nombre: "Elena")
    let v = crearEtiquetada(u, "usuario")
    print(v.etiqueta)
    print(v.ref_nombre)
}
"#,
        "usuario\nElena\n",
    );
}

#[test]
fn test_returned_view_struct_disjoint_fields_and_conflict_rejection() {
    check_native_program(
        "view_disjoint_ok",
        r#"
struct Usuario {
    nombre: Text
    edad: Int
}

struct VistaUsuario {
    nombre: &Text
}

fn crearVista(usuario: &Usuario) -> VistaUsuario {
    return VistaUsuario(nombre: &usuario.nombre)
}

fn main() {
    var usuario = Usuario(nombre: "David", edad: 20)
    let vista = crearVista(usuario)
    usuario.edad = 21
    print(vista.nombre)
    print(usuario.edad)
}
"#,
        "David\n21\n",
    );

    let src_field_conflict = r#"
struct Usuario {
    nombre: Text
    edad: Int
}
struct VistaUsuario {
    nombre: &Text
}
fn crearVista(usuario: &Usuario) -> VistaUsuario {
    return VistaUsuario(nombre: &usuario.nombre)
}
fn main() {
    var usuario = Usuario(nombre: "David", edad: 20)
    let vista = crearVista(usuario)
    usuario.nombre = "Daniel"
    print(vista.nombre)
}
"#;
    let err = check(src_field_conflict).expect_err("mutating borrowed field");
    assert_eq!(err.code, "L0012", "{err:?}");

    let src_move_conflict = r#"
struct Usuario {
    nombre: Text
    edad: Int
}
struct VistaUsuario {
    nombre: &Text
}
fn crearVista(usuario: &Usuario) -> VistaUsuario {
    return VistaUsuario(nombre: &usuario.nombre)
}
fn main() {
    let usuario = Usuario(nombre: "David", edad: 20)
    let vista = crearVista(usuario)
    let moved = usuario
    print(vista.nombre)
}
"#;
    let err = check(src_move_conflict).expect_err("moving borrowed owner");
    assert_eq!(err.code, "L0012", "{err:?}");
}

#[test]
fn test_returned_view_struct_methods_and_branches() {
    check_native_program(
        "view_methods_branches",
        r#"
struct Usuario {
    nombre: Text
    edad: Int
}

struct VistaUsuario {
    nombre: &Text
}

impl Usuario {
    fn vista() -> VistaUsuario {
        return VistaUsuario(nombre: &self.nombre)
    }
}

fn elegirVista(u1: &Usuario, u2: &Usuario, primero: Bool) -> VistaUsuario {
    if primero {
        return u1.vista()
    } else {
        return u2.vista()
    }
}

fn main() {
    let u1 = Usuario(nombre: "Alice", edad: 30)
    let u2 = Usuario(nombre: "Bob", edad: 25)
    let v1 = elegirVista(u1, u2, true)
    let v2 = elegirVista(u1, u2, false)
    print(v1.nombre)
    print(v2.nombre)
}
"#,
        "Alice\nBob\n",
    );
}

#[test]
fn test_returned_view_struct_invalid_escapes_rejected() {
    let src_local_scalar = r#"
struct Vista { valor: &Int }
fn crear() -> Vista {
    let n = 42
    return Vista(valor: &n)
}
fn main() {}
"#;
    let err = check(src_local_scalar).expect_err("escape local scalar");
    assert_eq!(err.code, "L0014", "{err:?}");

    let src_local_struct = r#"
struct Datos { x: Int }
struct Vista { valor: &Int }
fn crear() -> Vista {
    let d = Datos(x: 10)
    return Vista(valor: &d.x)
}
fn main() {}
"#;
    let err = check(src_local_struct).expect_err("escape local struct field");
    assert_eq!(err.code, "L0014", "{err:?}");

    let src_temp = r#"
struct Vista { valor: &Int }
fn crear() -> Vista {
    return Vista(valor: &(1 + 2))
}
fn main() {}
"#;
    let err = check(src_temp).expect_err("escape temporary");
    assert_eq!(err.code, "L0014", "{err:?}");

    let src_list = r#"
struct Vista { valor: &Int }
fn crear() -> Vista {
    let xs = List[1, 2, 3]
    return Vista(valor: &xs[0])
}
fn main() {}
"#;
    let err = check(src_list).expect_err("escape list element");
    assert_eq!(err.code, "L0014", "{err:?}");

    let src_region = r#"
struct Vista { valor: &Int }
fn crear() -> Vista {
    region r {
        var xs = r.list<Int>()
        xs.push(9)
        return Vista(valor: &xs[0])
    }
}
fn main() {}
"#;
    let err = check(src_region).expect_err("escape region list element");
    assert_eq!(err.code, "L0014", "{err:?}");

    let src_indirect = r#"
struct Vista { valor: &Int }
fn paso1() -> Vista {
    let x = 100
    return Vista(valor: &x)
}
fn paso2() -> Vista {
    return paso1()
}
fn main() {}
"#;
    let err = check(src_indirect).expect_err("escape indirect");
    assert_eq!(err.code, "L0014", "{err:?}");
}

#[test]
fn test_mutable_view_struct_canonical() {
    check_native_program(
        "mutable_view_canonical",
        r#"
struct VistaMutable {
    valor: &mut Int
}

impl VistaMutable {
    mut fn incrementar() {
        self.valor += 1
    }
}

fn main() {
    var numero = 10

    var vista = VistaMutable(
        valor: &mut numero
    )

    vista.incrementar()

    print(vista.valor)
}
"#,
        "11\n",
    );
}

#[test]
fn test_mutable_view_direct_field_assignment() {
    check_native_program(
        "mutable_view_field_assignment",
        r#"
struct VistaMutable {
    valor: &mut Int
}

fn main() {
    var numero = 10
    var vista = VistaMutable(valor: &mut numero)
    vista.valor = 42
    print(vista.valor)
    print(numero)
}
"#,
        "42\n42\n",
    );
}

#[test]
fn test_mutable_view_return_from_function() {
    check_native_program(
        "mutable_view_return",
        r#"
struct VistaMutable {
    valor: &mut Int
}

fn crearVista(numero: &mut Int) -> VistaMutable {
    return VistaMutable(valor: &mut numero)
}

fn main() {
    var x = 100
    var v = crearVista(&mut x)
    v.valor += 25
    print(v.valor)
    print(x)
}
"#,
        "125\n125\n",
    );
}

#[test]
fn test_mutable_view_move_semantics_rejects_used_source() {
    let src = r#"
struct VistaMutable { valor: &mut Int }
fn main() {
    var n = 10
    let v1 = VistaMutable(valor: &mut n)
    let v2 = v1
    print(v1.valor)
}
"#;
    let err = check(src).expect_err("use of moved view");
    assert_eq!(err.code, "L0005");
}

#[test]
fn test_mutable_view_conflicts_rejected() {
    let src1 = r#"
struct VistaMutable { valor: &mut Int }
fn main() {
    var numero = 10
    let a = VistaMutable(valor: &mut numero)
    let b = VistaMutable(valor: &mut numero)
    print(a.valor)
    print(b.valor)
}
"#;
    let err1 = check(src1).expect_err("overlapping mutable views");
    assert_eq!(err1.code, "L0012");

    let src2 = r#"
struct VistaMutable { valor: &mut Int }
fn main() {
    var numero = 10
    let a = VistaMutable(valor: &mut numero)
    numero = 20
    print(a.valor)
}
"#;
    let err2 = check(src2).expect_err("mutating owner while view alive");
    assert_eq!(err2.code, "L0012");

    let src3 = r#"
struct VistaMutable { valor: &mut Int }
fn main() {
    var numero = 10
    let a = VistaMutable(valor: &mut numero)
    print(numero)
    print(a.valor)
}
"#;
    let err3 = check(src3).expect_err("reading owner while mutable view alive");
    assert_eq!(err3.code, "L0012");

    let src4 = r#"
struct VistaMutable { valor: &mut Int }
fn main() {
    let numero = 10
    let a = VistaMutable(valor: &mut numero)
}
"#;
    let err4 = check(src4).expect_err("borrowing immutable binding mutably");
    assert_eq!(err4.code, "L0012");
}

#[test]
fn test_mutable_view_disjoint_fields() {
    check_native_program(
        "mutable_view_disjoint",
        r#"
struct Punto {
    x: Int
    y: Int
}

struct VistaInt {
    val: &mut Int
}

fn main() {
    var p = Punto(x: 10, y: 20)
    var vx = VistaInt(val: &mut p.x)
    var vy = VistaInt(val: &mut p.y)
    vx.val += 5
    vy.val += 15
    print(vx.val)
    print(vy.val)
    print(p.x)
    print(p.y)
}
"#,
        "15\n35\n15\n35\n",
    );
}

#[test]
fn test_view_reassignment() {
    check_native_program(
        "view_reassign",
        r#"
struct Vista {
    val: &Int
}

fn main() {
    let a = 10
    let b = 20
    var v = Vista(val: &a)
    print(v.val)
    v = Vista(val: &b)
    print(v.val)
}
"#,
        "10\n20\n",
    );
}

#[test]
fn test_mutable_view_reassignment() {
    check_native_program(
        "mutable_view_reassign",
        r#"
struct VistaMutable {
    val: &mut Int
}

fn main() {
    var a = 10
    var b = 20
    var v = VistaMutable(val: &mut a)
    v.val += 5
    print(v.val)
    v = VistaMutable(val: &mut b)
    v.val += 7
    print(v.val)
    print(a)
    print(b)
}
"#,
        "15\n27\n15\n27\n",
    );
}

#[test]
fn test_view_reassignment_in_conditional() {
    check_native_program(
        "view_reassign_cond",
        r#"
struct Vista {
    val: &Int
}

fn elegir(cond: Bool) {
    let a = 100
    let b = 200
    var v = Vista(val: &a)
    if cond {
        v = Vista(val: &b)
    }
    print(v.val)
}

fn main() {
    elegir(true)
    elegir(false)
}
"#,
        "200\n100\n",
    );
}

#[test]
fn test_mutate_through_shared_field_rejected() {
    let src = r#"
struct Vista { val: &Int }
fn main() {
    var n = 10
    var v = Vista(val: &n)
    v.val = 20
}
"#;
    let err = check(src).expect_err("mutating through shared field");
    assert!(err.message.contains("referencia inmutable &T"));
}

#[test]
fn test_option_shared_reference() {
    check_native_program(
        "option_shared",
        r#"
fn find_even(cond: Bool, n: &Int) -> Option<&Int> {
    if cond {
        return Option.Some(&n)
    }
    return Option.None
}

fn main() {
    let a = 42
    let b = 17
    let opt_a = find_even(true, &a)
    match opt_a {
        Some(v) => print(v),
        None => print(-1),
    }
    let opt_b = find_even(false, &b)
    match opt_b {
        Some(v) => print(v),
        None => print(-1),
    }
}
"#,
        "42\n-1\n",
    );
}

#[test]
fn test_option_mutable_reference() {
    check_native_program(
        "option_mut",
        r#"
fn get_mut_opt(cond: Bool, x: &mut Int) -> Option<&mut Int> {
    if cond {
        return Option.Some(&mut x)
    }
    return Option.None
}

fn main() {
    var a = 10
    var b = 20
    let opt_a = get_mut_opt(true, &mut a)
    match opt_a {
        Some(val) => {
            val += 5
        },
        None => {},
    }
    print(a)
    let opt_b = get_mut_opt(false, &mut b)
    match opt_b {
        Some(val) => {
            val += 5
        },
        None => {
            print(-1)
        },
    }
    print(b)
}
"#,
        "15\n-1\n20\n",
    );
}

#[test]
fn test_result_references_and_try() {
    check_native_program(
        "result_refs",
        r#"
fn parse_positive(n: &Int) -> Result<&Int, Text> {
    if n > 0 {
        return Result.Ok(&n)
    }
    return Result.Err("no es positivo")
}

fn increment_positive(n: &mut Int) -> Result<&mut Int, Text> {
    if n > 0 {
        n += 1
        return Result.Ok(&mut n)
    }
    return Result.Err("no es positivo")
}

fn try_flow(n: &Int) -> Result<&Int, Text> {
    let r = parse_positive(&n)?
    return Result.Ok(r)
}

fn main() {
    let a = 10
    let b = -5
    match try_flow(&a) {
        Ok(v) => print(v),
        Err(msg) => print(msg),
    }
    match try_flow(&b) {
        Ok(v) => print(v),
        Err(msg) => print(msg),
    }
    var c = 20
    match increment_positive(&mut c) {
        Ok(v) => {
            v += 2
            print(v)
        },
        Err(msg) => print(msg),
    }
    print(c)
}
"#,
        "10\nno es positivo\n23\n23\n",
    );
}

#[test]
fn test_custom_enum_references() {
    check_native_program(
        "custom_enum_refs",
        r#"
enum Respuesta {
    Encontrado(&Int),
    Par(&Int, &mut Int),
    Vacio,
}

fn elegir(modo: Int, x: &Int, y: &mut Int) -> Respuesta {
    if modo == 1 {
        return Respuesta.Encontrado(&x)
    }
    if modo == 2 {
        return Respuesta.Par(&x, &mut y)
    }
    return Respuesta.Vacio
}

fn main() {
    let x = 100
    var y = 25
    let r1 = elegir(1, &x, &mut y)
    match r1 {
        Respuesta.Encontrado(v) => print(v),
        Respuesta.Par(a, b) => print(0),
        Respuesta.Vacio => print(-1),
    }
    let r2 = elegir(2, &x, &mut y)
    match r2 {
        Respuesta.Encontrado(v) => print(0),
        Respuesta.Par(a, b) => {
            b += a
            print(b)
        },
        Respuesta.Vacio => print(-1),
    }
    let r3 = elegir(3, &x, &mut y)
    match r3 {
        Respuesta.Encontrado(v) => print(0),
        Respuesta.Par(a, b) => print(0),
        Respuesta.Vacio => print(-1),
    }
    print(y)
}
"#,
        "100\n125\n-1\n125\n",
    );
}

#[test]
fn test_array_references() {
    check_native_program(
        "array_refs",
        r#"
fn get_first(a: &Int, b: &Int) -> Int {
    let arr = [&a, &b]
    return arr[0]
}

fn make_array(a: &Int, b: &Int) -> [&Int; 2] {
    return [&a, &b]
}

fn main() {
    let x = 10
    let y = 20
    let arr = [&x, &y]
    print(arr.length)
    print(arr[0])
    print(arr[1])
    for item in arr {
        print(item)
    }
    let first = get_first(&x, &y)
    print(first)
    let returned_arr = make_array(&x, &y)
    print(returned_arr[0])
    print(returned_arr[1])
}
"#,
        "2\n10\n20\n10\n20\n10\n10\n20\n",
    );
}

#[test]
fn test_list_references() {
    check_native_program(
        "list_refs",
        r#"
fn make_list(a: &Int, b: &Int) -> List<&Int> {
    var xs = List[&a]
    xs.push(&b)
    return xs
}

fn main() {
    let x = 10
    let y = 20
    let z = 30
    var xs = List[&x, &y]
    xs.push(&z)
    print(xs.length)
    print(xs[0])
    print(xs[1])
    print(xs[2])
    for item in xs {
        print(item)
    }
    let returned = make_list(&x, &y)
    print(returned.length)
    print(returned[0])
    print(returned[1])
}
"#,
        "3\n10\n20\n30\n10\n20\n30\n2\n10\n20\n",
    );
}

#[test]
fn test_regional_collections_references() {
    check_native_program(
        "region_list_refs",
        r#"
fn main() {
    let a = 100
    let b = 200
    region r {
        var xs = r.list<&Int>()
        xs.push(&a)
        xs.push(&b)
        print(xs.length)
        print(xs[0])
        print(xs[1])
        for item in xs {
            print(item)
        }
    }
}
"#,
        "2\n100\n200\n100\n200\n",
    );
}

#[test]
fn test_negative_diagnostics_composite_references() {
    // 1. Local escapes rejected before codegen
    for source in [
        "fn f() -> Option<&Int> { let x = 10\n return Option.Some(&x) }\nfn main() {}",
        "fn f() -> Result<&Int, Text> { let x = 10\n return Result.Ok(&x) }\nfn main() {}",
        "enum Resp { Val(&Int) }\nfn f() -> Resp { let x = 10\n return Resp.Val(&x) }\nfn main() {}",
        "fn f() -> [&Int; 1] { let x = 10\n return [&x] }\nfn main() {}",
        "fn f() -> List<&Int> { let x = 10\n return List[&x] }\nfn main() {}",
        "fn f(a: &Int) -> Option<&Int> { let local = 10\n return Option.Some(&local) }\nfn main() {}",
    ] {
        let err = check(source).expect_err(source);
        assert!(
            err.code == "L0013" || err.code == "L0014",
            "{source}: {err:?}"
        );
    }

    // 2. Conflicting mutable loans and mutation of borrowed owner
    for (source, expected_code) in [
        (
            "fn main() { var x = 10\n let o1 = Option.Some(&mut x)\n let o2 = Option.Some(&mut x)\n match o1 { Some(v) => print(v), None => {} }\n match o2 { Some(v) => print(v), None => {} } }",
            "L0012",
        ),
        (
            "fn main() { var x = 10\n let o = Option.Some(&x)\n x = 20\n match o { Some(v) => print(v), None => {} } }",
            "L0012",
        ),
        (
            "enum Resp { Par(&Int, &mut Int), Vacio }\nfn main() { var x = 10\n let r = Resp.Par(&x, &mut x)\n match r { Resp.Par(a, b) => print(a), Resp.Vacio => {} } }",
            "L0012",
        ),
        (
            "fn main() { var x = 10\n let arr = [&mut x, &mut x]\n print(arr[0]) }",
            "L0012",
        ),
        (
            "fn main() { var x = 10\n var xs = List[&mut x]\n xs.push(&mut x)\n print(xs[0]) }",
            "L0012",
        ),
        (
            "fn main() { var x = 10\n let xs = [&x]\n x = 20\n print(xs[0]) }",
            "L0012",
        ),
        (
            "fn main() { var x = 10\n var xs = List[&x]\n x = 20\n print(xs[0]) }",
            "L0012",
        ),
    ] {
        let err = check(source).expect_err(source);
        assert_eq!(err.code, expected_code, "{source}: {err:?}");
    }
}
