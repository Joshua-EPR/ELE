//! Native async/await: `async fn`, futures, `await`, real suspension and the
//! cooperative executor.
//!
//! Every positive program is built with the rustc backend (reference, which
//! lowers async onto Rust's own lazy futures) and with the Cranelift backend
//! (the hand-written state machine) instrumented with `--trace-alloc`. stdout,
//! stderr and exit status must match, every heap block must be freed exactly
//! once and the heap must validate at exit. `suspends` counts the polls that
//! returned Pending and were resumed after a notification, so a test can tell
//! a real suspension from a body that just ran to completion.
use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/async")
        .join(name);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn build(dir: &Path, file: &str, extra: &[&str]) -> PathBuf {
    let mut args = vec!["build", file];
    args.extend_from_slice(extra);
    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(dir)
        .args(&args)
        .output()
        .unwrap();
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
    frees: u64,
    /// Polls that returned Pending and were resumed (real suspensions).
    suspends: u64,
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
        frees: field("frees"),
        suspends: field("suspends"),
    }
}

/// Differential + instrumented run of a program expected to exit normally.
fn check_program(name: &str, source: &str, expected: &str) -> Stats {
    let dir = work(name);
    let file = format!("{name}.l");
    fs::write(dir.join(&file), source).unwrap();
    let reference = run(&build(&dir, &file, &[]));
    let native = run(&build(
        &dir,
        &file,
        &["--backend", "cranelift", "--trace-alloc"],
    ));
    assert_eq!(reference.2, Some(0), "{name} rustc: {}", reference.1);
    assert_eq!(native.2, Some(0), "{name} cranelift: {}", native.1);
    assert_eq!(reference.0, expected, "{name}: salida rustc");
    assert_eq!(native.0, expected, "{name}: salida cranelift");
    assert!(
        reference.1.is_empty(),
        "{name}: stderr rustc: {}",
        reference.1
    );
    assert_eq!(
        native.1.lines().count(),
        1,
        "{name}: stderr cranelift: {}",
        native.1
    );
    let s = stats(&native.1);
    assert_eq!(s.allocs, s.frees, "{name}: bloques sin liberar: {s:?}");
    s
}

/// A program rejected at compile time with `code` and a message containing `cause`.
fn rejects(source: &str, code: &str, cause: &str) {
    let e = check(source).expect_err(source);
    assert_eq!(e.code, code, "{source}: {e:?}");
    assert!(e.message.contains(cause), "{source}: {e:?}");
    assert!(e.span.line > 0 && e.span.column > 0, "{source}: {e:?}");
}

// ---------------------------------------------------------------- futures --

#[test]
fn canonical_example() {
    let s = check_program(
        "canonico",
        r#"async fn obtenerNumero() -> Int {
    return 42
}

async fn main() {
    let resultado = await obtenerNumero()

    print(resultado)
}
"#,
        "42\n",
    );
    // The task record of main, its state and the state of the awaited call;
    // nothing suspends.
    assert_eq!(s.allocs, 3, "{s:?}");
    assert_eq!(s.suspends, 0, "{s:?}");
}

#[test]
fn async_without_await_and_unpolled_futures() {
    // Calling an async function runs nothing: the body only runs when polled.
    let s = check_program(
        "sin_await",
        r#"async fn listo() -> Int {
    print(2)
    return 7
}

async fn main() {
    print(1)
    let pendiente = listo()
    print(3)
    let valor = await listo()
    print(valor)
}
"#,
        "1\n3\n2\n7\n",
    );
    // The task record of main, its state, the future that is never polled
    // and the awaited one.
    assert_eq!(s.allocs, 4, "{s:?}");
    assert_eq!(s.suspends, 0, "{s:?}");
}

#[test]
fn real_suspension_and_resume() {
    let s = check_program(
        "suspension",
        r#"async fn tarea() -> Int {
    print(1)
    await yieldNow()
    print(2)
    await yieldNow()
    print(3)
    return 4
}

async fn main() {
    print(0)
    let r = await tarea()
    print(r)
}
"#,
        "0\n1\n2\n3\n4\n",
    );
    // The body stopped twice and the executor resumed it twice.
    assert_eq!(s.suspends, 2, "{s:?}");
}

#[test]
fn nested_async_loops_and_saved_locals() {
    let s = check_program(
        "anidado",
        r#"async fn obtenerNumero() -> Int {
    await yieldNow()
    return 32
}

async fn calcular() -> Int {
    let a = 10
    let b = await obtenerNumero()
    return a + b
}

async fn main() {
    let total = await calcular()
    print(total)
    var suma = 0
    var i = 0
    while i < 3 {
        let parte = await obtenerNumero()
        suma += parte
        i += 1
    }
    print(suma)
    for k in 0..2 {
        let v = await obtenerNumero()
        print(v + k)
    }
}
"#,
        "42\n96\n32\n33\n",
    );
    // One suspension per call to obtenerNumero: 1 + 3 + 2.
    assert_eq!(s.suspends, 6, "{s:?}");
}

#[test]
fn text_and_struct_results_across_suspensions() {
    check_program(
        "resultados",
        r#"struct Persona {
    nombre: Text
    edad: Int
}

async fn saludo(n: Int) -> Text {
    await yieldNow()
    return "hola {n}"
}

async fn persona(edad: Int) -> Persona {
    let t = await saludo(edad)
    return Persona(nombre: t, edad: edad)
}

async fn promedio(a: Float, b: Float) -> Float {
    await yieldNow()
    return (a + b) / 2.0
}

async fn main() {
    let p = await persona(7)
    print(p.nombre)
    print(p.edad)
    let s = await saludo(1)
    print(s)
    let m = await promedio(1.5, 2.5)
    print(m)
    let vacio = await saludo(0)
    print(vacio)
}
"#,
        "hola 7\n7\nhola 1\n2\nhola 0\n",
    );
}

#[test]
fn option_result_and_try_propagation() {
    check_program(
        "option_result",
        r#"fn mitad(n: Int) -> Int? {
    if n % 2 == 0 {
        return Some(n / 2)
    }
    return None
}

async fn calcular(n: Int) -> Int? {
    await yieldNow()
    let m = mitad(n)?
    return Some(m + 1)
}

async fn clasificar(n: Int) -> Result<Int, Text> {
    let r = await calcular(n)
    match r {
        Some(v) => return Ok(v),
        None => return Err("impar {n}")
    }
}

async fn main() {
    let par = await clasificar(10)
    match par {
        Ok(v) => print(v),
        Err(e) => print(e)
    }
    let impar = await clasificar(7)
    match impar {
        Ok(v) => print(v),
        Err(e) => print(e)
    }
}
"#,
        "6\nimpar 7\n",
    );
}

#[test]
fn early_returns_breaks_and_dead_resources() {
    let s = check_program(
        "salidas",
        r#"async fn paso(n: Int) -> Int {
    if n > 1 {
        await yieldNow()
        return n * 2
    }
    await yieldNow()
    return n
}

async fn buscar(objetivo: Int) -> Int {
    var i = 0
    loop {
        let v = await paso(i)
        if v >= objetivo {
            return v
        }
        i += 1
        if i > 10 {
            break
        }
    }
    return -1
}

async fn main() {
    let a = await buscar(8)
    print(a)
    let b = await buscar(1000)
    print(b)
    // Text remains owned by this scope even if its last read precedes await.
    let t = "temporal {1}"
    print(t)
    let n = await paso(3)
    print(n)
}
"#,
        "8\n-1\ntemporal 1\n6\n",
    );
    assert!(s.suspends > 10, "{s:?}");
}

#[test]
fn futures_move_between_locals_and_are_released_unpolled() {
    let s = check_program(
        "movimiento",
        r#"async fn valor(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn descartar(n: Int) -> Int {
    // Built, then abandoned on the early return: its task state is released
    // without ever being polled.
    let sobrante = valor(99)
    if n > 0 {
        let v = await valor(n)
        return v
    }
    return 0
}

async fn main() {
    let f = valor(5)
    let g = f
    let r = await g
    print(r)
    let d = await descartar(3)
    print(d)
    let z = await descartar(0)
    print(z)
}
"#,
        "5\n3\n0\n",
    );
    // main + (valor, descartar x2, their abandoned and awaited futures).
    assert!(s.allocs >= 6, "{s:?}");
    assert_eq!(s.suspends, 2, "{s:?}");
}

#[test]
fn out_of_memory_building_a_task_is_a_clean_panic() {
    // The state of main is the first allocation and its task record the
    // second; the state of the awaited call is the third.
    let dir = work("sin_memoria");
    let source = "async fn f() -> Int {\n    return 1\n}\nasync fn main() {\n    print(0)\n    let v = await f()\n    print(v)\n}\n";
    fs::write(dir.join("sin_memoria.l"), source).unwrap();
    let exe = build(
        &dir,
        "sin_memoria.l",
        &["--backend", "cranelift", "--alloc-fail-after", "2"],
    );
    let (stdout, stderr, code) = run(&exe);
    assert_eq!(stdout, "0\n");
    assert_eq!(stderr, "ELE: memoria insuficiente\n");
    assert_eq!(code, Some(project_l::native::PANIC_EXIT_CODE as i32));
    // With room for every task state the program completes.
    let exe = build(
        &dir,
        "sin_memoria.l",
        &["--backend", "cranelift", "--alloc-fail-after", "3"],
    );
    assert_eq!(run(&exe).0, "0\n1\n");
}

// --------------------------------------------------------------- rejected --

#[test]
fn await_outside_async_is_rejected() {
    rejects(
        "async fn f() -> Int = 1\nfn main() {\n    let v = await f()\n    print(v)\n}",
        "L0015",
        "dentro de una función async",
    );
    rejects(
        "fn main() {\n    let v = await 1\n}",
        "L0015",
        "dentro de una función async",
    );
}

#[test]
fn await_only_at_statement_positions() {
    check_program(
        "await_in_arithmetic_and_calls",
        r#"
async fn f() -> Int {
    return 1
}

async fn main() {
    let v = (await f()) + 1
    print(v)
    print(await f())
    var s = 0
    s += await f()
    print(s)
    let w = await f()
    match w {
        _ => {
            let z = await f()
            print(z)
        }
    }
}
"#,
        "2\n1\n1\n1\n",
    );
}

#[test]
fn await_needs_a_future() {
    rejects(
        "async fn main() {\n    let v = await 1\n    print(v)\n}",
        "L0015",
        "await espera el future",
    );
}

#[test]
fn values_with_resources_cannot_cross_a_suspension() {
    // Borrowed parameters cannot live in the task state.
    rejects(
        "async fn f(d: &Int) -> Int = 1\nfn main() {}",
        "L0015",
        "parámetro d",
    );
    // A plain Future local is still released before a suspension.
    rejects(
        "async fn g() -> Int = 1\nasync fn main() {\n    let f = g()\n    await yieldNow()\n    let n = await f\n}",
        "L0015",
        "no sobrevive a una suspensión",
    );
    // An open region would be released under the task's feet.
    rejects(
        "async fn g() -> Int = 1\nasync fn main() {\n    region r {\n        var b = r.bytes(8)\n        let n = await g()\n    }\n}",
        "L0015",
        "región",
    );
    // Iterating a collection borrows it for the whole loop.
    rejects(
        "async fn g() -> Int = 1\nasync fn main() {\n    let datos = List[1, 2]\n    for x in datos {\n        let n = await g()\n    }\n}",
        "L0015",
        "for sobre una colección",
    );
}

#[test]
fn futures_are_consumed_once_and_stay_local() {
    // Awaiting consumes the future: a second await is a use after move.
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let fut = f()\n    let a = await fut\n    let b = await fut\n    print(a + b)\n}",
        "L0005",
        "después de moverlo",
    );
    // A future cannot leave the function that created it.
    rejects(
        "async fn f() -> Int = 1\nfn crear() = f()\nfn main() {}",
        "L0015",
        "no se puede devolver",
    );
    // Nor be stored in an aggregate (no future type can be named).
    rejects(
        "struct Caja {\n    f: Int\n}\nasync fn f() -> Int = 1\nasync fn main() {\n    let c = Caja(f: f())\n}",
        "L0001",
        "",
    );
}

#[test]
fn unsupported_async_forms_are_rejected() {
    rejects(
        "async fn f<T>(x: T) -> Int = 1\nfn main() {}",
        "L0015",
        "genéricas",
    );
    rejects(
        "struct S {\n    n: Int\n}\nimpl S {\n    async fn f(self) -> Int = 1\n}\nfn main() {}",
        "L0003",
        "métodos async",
    );
}

#[test]
fn allocation_effects_cover_tasks() {
    // Building a future reserves its task state: that is an allocation.
    rejects(
        "async fn f() -> Int = 1\n@noalloc async fn g() -> Int {\n    let v = await f()\n    return v\n}\nfn main() {}",
        "L0010",
        "",
    );
    rejects(
        "async fn f() -> Int = 1\n@noalloc fn g() -> Int {\n    let x = f()\n    return 1\n}\nfn main() {}",
        "L0010",
        "",
    );
    check("async fn contar(datos: List<Int>) -> Int !{} = datos.length\nfn main() {}").unwrap();
    rejects(
        "async fn contar(datos: List<Int>) -> Int !{} = datos.length\n@noalloc fn crear(datos: List<Int>) { let f = contar(datos) }\nfn main() {}",
        "L0010",
        "",
    );
    // Awaiting inherits the effects of the body it polls.
    rejects(
        "async fn imprime() -> Int {\n    print(1)\n    return 1\n}\nasync fn puro() -> Int !{} {\n    let v = await imprime()\n    return v\n}\nfn main() {}",
        "L0010",
        "",
    );
    // An async function that allocates nothing and awaits nothing is pure.
    check("async fn puro(n: Int) -> Int !{} {\n    return n\n}\nfn main() {}").unwrap();
}

#[test]
fn owning_text_moves_and_reinitializes_across_real_suspensions() {
    let s = check_program(
        "texto_async_movimientos",
        r#"async fn etiqueta(n: Int) -> Text {
    let t = "valor {n}"
    await yieldNow()
    return t
}

async fn elegir(n: Int) -> Text {
    let inicial = "inicio {n}"
    var texto = inicial
    var i = 0
    while i < n {
        texto = await etiqueta(i)
        i += 1
        if i == 1 {
            continue
        }
        let auxiliar = "paso {i}"
        let tomado = auxiliar
        await yieldNow()
        print(tomado)
        texto = "restaurado {i}"
    }
    await yieldNow()
    return texto
}

async fn main() {
    let a = await elegir(0)
    let b = await elegir(3)
    await yieldNow()
    print(a)
    print(b)
}
"#,
        "paso 2\npaso 3\ninicio 0\nrestaurado 3\n",
    );
    assert_eq!(s.suspends, 8, "{s:?}");
}

#[test]
fn text_slots_are_cleaned_on_both_paths_of_try() {
    let s = check_program(
        "texto_async_try",
        r#"async fn revisar(n: Int) -> Result<Int, Text> {
    await yieldNow()
    if n == 0 {
        return Result.Err("falló {n}")
    }
    return Result.Ok(n)
}

async fn elegir(n: Int) -> Result<Text, Text> {
    let t = "dato {n}"
    let r = await revisar(n)
    let v = r?
    print(v)
    return Result.Ok(t)
}

async fn main() {
    let a = await elegir(0)
    match a {
        Result.Ok(t) => print(t)
        Result.Err(e) => print(e)
    }
    let b = await elegir(2)
    match b {
        Result.Ok(t) => print(t)
        Result.Err(e) => print(e)
    }
}
"#,
        "falló 0\n2\ndato 2\n",
    );
    assert_eq!(s.suspends, 2, "{s:?}");
}

#[test]
fn async_rejects_loans_used_after_suspension() {
    for (binding, after) in [
        ("let r = &n", "print(r)"),
        ("let r = &n", "let otro = &r\n print(otro)"),
        ("let r = &mut n", "r = 2"),
    ] {
        rejects(
            &format!("async fn main() {{\n var n = 1\n {binding}\n await yieldNow()\n {after}\n}}"),
            "L0015",
            "no sobrevive a una suspensión",
        );
    }
}

#[test]
fn moving_text_before_await_does_not_allow_reading_it_later() {
    rejects(
        "async fn main() {\n let t = \"texto\"\n let moved = t\n await yieldNow()\n print(t)\n}",
        "L0005",
        "movido",
    );
}

#[test]
fn async_text_can_be_borrowed_separately_in_each_poll() {
    let s = check_program(
        "prestamos_texto_async",
        r#"fn mostrar(s: &Text) {
    print(s)
}

async fn main() {
    let numero = 7
    let texto = "préstamo {numero}"
    mostrar(&texto)
    await yieldNow()
    let nuevo = &texto
    print(nuevo)
}
"#,
        "préstamo 7\npréstamo 7\n",
    );
    assert_eq!(s.suspends, 1, "{s:?}");
}

#[test]
fn match_can_move_a_persistent_text_after_resume() {
    let s = check_program(
        "texto_async_match",
        r#"fn consumir(t: Text) {
    print(t)
}

async fn mostrar(n: Int) {
    let t = "texto {n}"
    await yieldNow()
    match t {
        "texto 0" => print("cero"),
        otro => consumir(otro),
    }
    await yieldNow()
}

async fn main() {
    await mostrar(0)
    await mostrar(1)
}
"#,
        "cero\ntexto 1\n",
    );
    assert_eq!(s.suspends, 4, "{s:?}");
}

#[test]
fn async_owned_parameters_transfer_before_the_first_poll() {
    let stats = check_program(
        "async_parametros_propietarios",
        r#"struct Usuario {
    nombre: Text
    edad: Int
}

async fn mostrar(prefijo: Text, usuario: Usuario, sufijo: Text) -> Text {
    await yieldNow()
    print("{prefijo} {usuario.nombre} {usuario.edad} {sufijo}")
    return usuario.nombre
}

async fn main() {
    let n = 25
    let usuario = Usuario(nombre: "Ana {n}", edad: n)
    let a = "Inicio {n}"
    let b = "Fin {n}"
    let nombre = await mostrar(a, usuario, b)
    print(nombre)
}
"#,
        "Inicio 25 Ana 25 25 Fin 25\nAna 25\n",
    );
    assert_eq!(stats.suspends, 1, "{stats:?}");
}

#[test]
fn partial_moves_and_field_reinitialization_follow_resume_edges() {
    let stats = check_program(
        "async_campos_parciales",
        r#"struct Datos {
    nombre: Text
    codigo: Int
}
struct Usuario {
    datos: Datos
    ciudad: Text
}
fn recibir(u: Usuario) {
    print("{u.datos.nombre} {u.ciudad}")
}
async fn procesar(n: Int) {
    var u = Usuario(datos: Datos(nombre: "Ana {n}", codigo: n), ciudad: "Ciudad {n}")
    if n > 0 {
        let nombre = u.datos.nombre
        await yieldNow()
        print(nombre)
    }
    await yieldNow()
    print(u.datos.codigo)
    let ciudad = u.ciudad
    await yieldNow()
    print(ciudad)
    u.datos.nombre = "Nuevo {n}"
    u.ciudad = "Otro {n}"
    recibir(u)
}
async fn main() {
    await procesar(1)
    await procesar(0)
}
"#,
        "Ana 1\n1\nCiudad 1\nNuevo 1 Otro 1\n0\nCiudad 0\nNuevo 0 Otro 0\n",
    );
    assert_eq!(stats.suspends, 5, "{stats:?}");
}

#[test]
fn owner_parameters_and_partial_fields_cannot_be_read_after_moves() {
    for body in [
        "let a = usuario.nombre\n await yieldNow()\n print(usuario.nombre)",
        "let a = usuario.nombre\n await yieldNow()\n let b = usuario.nombre",
        "let a = usuario\n await yieldNow()\n print(usuario.edad)",
        "if usuario.edad > 1 { let a = usuario.nombre }\n await yieldNow()\n print(usuario.nombre)",
    ] {
        rejects(
            &format!(
                "struct Usuario {{\n nombre: Text\n edad: Int\n}}\nasync fn f(usuario: Usuario) {{\n {body}\n}}\nfn main() {{}}"
            ),
            "L0005",
            "movi",
        );
    }
}

#[test]
fn struct_field_loan_cannot_follow_its_owner_across_await() {
    rejects(
        r#"struct Usuario {
    nombre: Text
}
async fn f(usuario: Usuario) {
    let nombre = &usuario.nombre
    await yieldNow()
    print(nombre)
}
fn main() {}"#,
        "L0015",
        "no sobrevive a una suspensión",
    );
}

#[test]
fn enum_arms_move_payloads_and_release_unmoved_payloads_after_await() {
    let stats = check_program(
        "async_enum_payloads",
        r#"enum Respuesta {
    Exito(Text, Text)
    Error(Int)
}

fn consumir(t: Text) {
    print(t)
}

async fn procesar(r: Respuesta) {
    await yieldNow()
    match r {
        Respuesta.Exito(a, b) => {
            print(a)
            consumir(b)
        }
        Respuesta.Error(codigo) => print(codigo)
    }
    await yieldNow()
}

async fn main() {
    let n = 7
    await procesar(Respuesta.Exito("uno {n}", "dos {n}"))
    await procesar(Respuesta.Error(n))
}
"#,
        "uno 7\ndos 7\n7\n",
    );
    assert_eq!(stats.suspends, 4, "{stats:?}");
}

#[test]
fn option_and_result_owners_can_cross_multiple_awaits() {
    let stats = check_program(
        "async_option_result_persistentes",
        r#"async fn procesar(r: Result<Int, Text>, opcion: Option<Text>) -> Result<Int, Text> {
    await yieldNow()
    let n = r?
    await yieldNow()
    match opcion {
        Option.Some(t) => print(t)
        Option.None => print("sin texto")
    }
    return Result.Ok(n)
}
async fn main() {
    let n = 7
    let a = await procesar(Result.Err("error {n}"), Option.Some("se libera {n}"))
    match a {
        Result.Err(e) => print(e)
        Result.Ok(v) => print(v)
    }
    let b = await procesar(Result.Ok(n), Option.Some("valor {n}"))
    match b {
        Result.Err(e) => print(e)
        Result.Ok(v) => print(v)
    }
}
"#,
        "error 7\nvalor 7\n7\n",
    );
    assert_eq!(stats.suspends, 3, "{stats:?}");
}

#[test]
fn moving_an_enum_payload_consumes_the_enum_across_resumptions() {
    rejects(
        r#"enum Respuesta {
    Exito(Text)
    Error(Int)
}
fn consumir(t: Text) {}
async fn f(r: Respuesta) {
    match r {
        Respuesta.Exito(t) => consumir(t)
        Respuesta.Error(_) => print("error")
    }
    await yieldNow()
    match r {
        Respuesta.Exito(t) => print(t)
        Respuesta.Error(_) => print("error")
    }
}
fn main() {}"#,
        "L0005",
        "movi",
    );
}

#[test]
fn owning_arrays_and_lists_keep_elements_and_grow_after_await() {
    let stats = check_program(
        "async_colecciones",
        r#"struct Persona {
    nombre: Text
}

enum Estado {
    Listo(Text)
    Codigo(Int)
}

async fn procesar(n: Int, fijo: [Text; 2]) {
    var enteros = List[10, 20, 30]
    var reales = List[1.25, 2.5]
    var textos = List["texto {n}"]
    var personas = List[Persona(nombre: "Ana {n}")]
    var estados = List[Estado.Listo("listo {n}")]
    await yieldNow()
    enteros.push(40)
    reales.push(3.5)
    textos[0] = "nuevo {n}"
    textos.push("último {n}")
    personas.push(Persona(nombre: "Inés {n}"))
    estados.push(Estado.Codigo(n))
    let sacado = textos.pop()
    let movidos = enteros
    let array = fijo
    await yieldNow()
    print(movidos.length)
    print(reales[2])
    print(textos[0])
    print(personas[1].nombre)
    print(estados.length)
    print(array[1])
    match sacado {
        Option.Some(t) => print(t)
        Option.None => print("vacío")
    }
}
async fn main() {
    let n = 5
    await procesar(n, ["a {n}", "b {n}"])
}
"#,
        "4\n3.5\nnuevo 5\nInés 5\n2\nb 5\núltimo 5\n",
    );
    assert_eq!(stats.suspends, 2, "{stats:?}");
}

#[test]
fn element_loans_and_moved_collections_are_rejected_after_await() {
    for (body, code, cause) in [
        (
            "let r = &lista[0]\n await yieldNow()\n print(r)",
            "L0015",
            "no sobrevive a una suspensión",
        ),
        (
            "let r = &mut lista[0]\n await yieldNow()\n r = 2",
            "L0015",
            "no sobrevive a una suspensión",
        ),
        (
            "let otra = lista\n await yieldNow()\n print(lista[0])",
            "L0005",
            "movi",
        ),
        (
            "let r = &lista[0]\n lista.push(2)\n print(r)\n await yieldNow()",
            "L0012",
            "préstamo",
        ),
    ] {
        rejects(
            &format!("async fn main() {{\n var lista = List[1]\n {body}\n}}"),
            code,
            cause,
        );
    }
}

#[test]
fn cli_reports_moved_async_fields_with_a_source_location() {
    let dir = work("async_diagnostico_movido");
    let name = "movido.l";
    fs::write(
        dir.join(name),
        "struct Datos {\n    nombre: Text\n}\nasync fn main() {\n    let d = Datos(nombre: \"Ana\")\n    let n = d.nombre\n    await yieldNow()\n    print(d.nombre)\n}\n",
    )
    .unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(dir)
        .args(["build", name, "--backend", "cranelift"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(out.stdout.is_empty());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(
        err.contains("movido.l:8:") && err.contains("L0005"),
        "{err}"
    );
}

#[test]
fn moving_persistent_fields_respects_active_disjoint_loans() {
    let source = r#"struct Datos {
    nombre: Text
    ciudad: Text
}
async fn main() {
    let n = 3
    let d = Datos(nombre: "Ana {n}", ciudad: "Madrid {n}")
    await yieldNow()
    let r = &d.ciudad
    let tomado = d.nombre
    print(r)
    await yieldNow()
    print(tomado)
}"#;
    let stats = check_program("async_prestamos_disjuntos", source, "Madrid 3\nAna 3\n");
    assert_eq!(stats.suspends, 2, "{stats:?}");
    let conflicting = source.replace("&d.ciudad", "&d.nombre");
    rejects(&conflicting, "L0012", "préstamo incompatible");
    let whole = source
        .replace("= d.nombre", "= d")
        .replace("print(tomado)", "print(tomado.nombre)");
    rejects(&whole, "L0012", "préstamo incompatible");
}
