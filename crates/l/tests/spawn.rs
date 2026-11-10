//! `spawn`, `TaskHandle<T>` and the cooperative scheduler: several tasks on one
//! thread, real interleaving, structured ownership and safe cancellation.
//!
//! Every positive program runs on both backends — the rustc reference (which
//! lowers tasks onto Rust's own futures and an equivalent FIFO scheduler) and
//! the native Cranelift backend (the hand-written state machine and runtime) —
//! and stdout, stderr and exit status must match. The native run is
//! instrumented with `--trace-alloc`: every heap block must be freed exactly
//! once and the heap must validate at exit. `suspends` counts the polls that
//! returned Pending, which is how a test tells a real suspension from a body
//! that simply ran to completion.
use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/spawn")
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

// ------------------------------------------------------------------ spawn --

#[test]
fn spawn_and_await_a_task() {
    let s = check_program(
        "simple",
        r#"async fn calcular(numero: Int) -> Int {
    await yieldNow()
    return numero * 2
}

async fn main() {
    let tarea = spawn calcular(21)

    let resultado = await tarea

    print(resultado)
}
"#,
        "42\n",
    );
    // main suspends once awaiting the task, which suspends once on yieldNow.
    assert_eq!(s.suspends, 2, "{s:?}");
    // Two tasks: a state and a scheduler record each, plus the yieldNow future.
    assert_eq!(s.allocs, 5, "{s:?}");
}

#[test]
fn two_independent_tasks() {
    let s = check_program(
        "dos",
        r#"async fn calcular(numero: Int) -> Int {
    await yieldNow()
    return numero * 2
}

async fn main() {
    let primera = spawn calcular(10)
    let segunda = spawn calcular(20)

    let a = await primera
    let b = await segunda

    print(a + b)
}
"#,
        "60\n",
    );
    // Both tasks suspend, and main suspends once waiting for the first: the
    // second one had already finished by then.
    assert_eq!(s.suspends, 3, "{s:?}");
}

#[test]
fn three_tasks_interleave_in_a_deterministic_order() {
    // The trace is what proves the scheduler really interleaves the tasks
    // instead of running each one to completion in turn: all three advance one
    // step before any of them takes its second step.
    let s = check_program(
        "intercalado",
        r#"async fn trabajo(id: Int, pasos: Int) -> Int {
    var i = 0
    while i < pasos {
        print("tarea {id} paso {i}")
        await yieldNow()
        i = i + 1
    }
    return id * 100
}

async fn main() {
    let a = spawn trabajo(1, 3)
    let b = spawn trabajo(2, 3)
    let c = spawn trabajo(3, 3)

    let x = await a
    let y = await b
    let z = await c

    print(x + y + z)
}
"#,
        "tarea 1 paso 0\ntarea 2 paso 0\ntarea 3 paso 0\n\
         tarea 1 paso 1\ntarea 2 paso 1\ntarea 3 paso 1\n\
         tarea 1 paso 2\ntarea 2 paso 2\ntarea 3 paso 2\n600\n",
    );
    // Nine yields plus the suspension of main waiting for the first task.
    assert_eq!(s.suspends, 10, "{s:?}");
}

#[test]
fn a_task_that_never_runs_is_cancelled_cleanly() {
    // main never suspends, so the task is still queued and unpolled when the
    // handle dies at the end of the scope: cancelling it releases its state
    // without ever starting its body.
    let s = check_program(
        "nunca_corre",
        r#"async fn trabajo() -> Int {
    print("no debería ejecutarse")
    return 1
}

async fn main() {
    let t = spawn trabajo()

    print("creada y destruida sin esperarla")
}
"#,
        "creada y destruida sin esperarla\n",
    );
    assert_eq!(s.suspends, 0, "{s:?}");
}

#[test]
fn a_suspended_task_is_cancelled_when_its_scope_ends() {
    // The task suspends three times but main only yields twice: when main
    // finishes, the handle dies and the task is cancelled while suspended, so
    // its body never reaches the end.
    let s = check_program(
        "cancelar_suspendida",
        r#"async fn lenta(id: Int) -> Text {
    await yieldNow()
    await yieldNow()
    await yieldNow()
    print("lenta {id} llegó al final")
    return "recurso {id}"
}

async fn main() {
    let a = spawn lenta(1)

    await yieldNow()
    print("main sigue")
    await yieldNow()
    print("main termina y cancela la tarea suspendida")
}
"#,
        "main sigue\nmain termina y cancela la tarea suspendida\n",
    );
    assert_eq!(s.suspends, 4, "{s:?}");
}

#[test]
fn an_early_return_cancels_every_live_handle() {
    let s = check_program(
        "retorno_anticipado",
        r#"async fn uno(id: Int) -> Int {
    await yieldNow()
    print("uno {id} terminó")
    return 1
}

async fn main() {
    let a = spawn uno(1)
    let b = spawn uno(2)

    if true {
        print("salida anticipada")
        return
    }

    let x = await a
    let y = await b
    print(x + y)
}
"#,
        "salida anticipada\n",
    );
    assert_eq!(s.suspends, 0, "{s:?}");
}

#[test]
fn results_of_every_supported_shape_come_back_from_a_task() {
    check_program(
        "resultados",
        r#"struct Punto {
    x: Int,
    y: Int
}

async fn texto(n: Int) -> Text {
    await yieldNow()
    return "valor {n}"
}

async fn punto(n: Int) -> Punto {
    await yieldNow()
    return Punto(x: n, y: n * 2)
}

async fn real() -> Float {
    await yieldNow()
    return 2.5
}

async fn main() {
    let t = spawn texto(7)
    let s = await t
    print(s)

    let p = spawn punto(3)
    let q = await p
    print(q.x + q.y)

    let f = spawn real()
    let v = await f
    print(v)
}
"#,
        "valor 7\n9\n2.5\n",
    );
}

#[test]
fn result_and_try_propagation_across_tasks() {
    check_program(
        "resultado",
        r#"async fn puede(n: Int) -> Result<Int, Text> {
    await yieldNow()
    if n < 0 {
        return Err("negativo")
    }
    return Ok(n * 3)
}

async fn usar(n: Int) -> Result<Int, Text> {
    let t = spawn puede(n)
    let r = await t
    let v = r?
    return Ok(v + 1)
}

async fn main() {
    let a = spawn usar(5)
    let r = await a
    match r {
        Ok(v) => print(v)
        Err(e) => print("error: {e}")
    }

    let b = spawn usar(0 - 2)
    let r2 = await b
    match r2 {
        Ok(v) => print(v)
        Err(e) => print("error: {e}")
    }
}
"#,
        "16\nerror: negativo\n",
    );
}

#[test]
fn a_handle_moves_between_locals_and_survives_suspensions() {
    let s = check_program(
        "mover_handle",
        r#"async fn trabajo(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn main() {
    let primero = spawn trabajo(4)
    let segundo = spawn trabajo(5)

    // `segundo` stays alive across the suspension of this await, and the
    // handle of the first one is moved to another local before being consumed.
    let movido = primero
    let a = await movido

    let b = await segundo
    print(a + b)
}
"#,
        "9\n",
    );
    assert_eq!(s.suspends, 3, "{s:?}");
}

#[test]
fn a_task_spawns_its_own_tasks() {
    // A tree of tasks: every level keeps two handles alive across its own
    // suspension, and the whole tree is awaited back in order.
    let s = check_program(
        "arbol",
        r#"async fn hoja(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn rama(n: Int) -> Int {
    if n <= 0 {
        return 0
    }
    let hijo = spawn rama(n - 1)
    let mio = spawn hoja(n)
    await yieldNow()
    let a = await hijo
    let b = await mio
    return a + b
}

async fn main() {
    let r = spawn rama(100)
    let total = await r
    print(total)
}
"#,
        "5050\n",
    );
    // 201 live tasks at the deepest point, so every level really suspended.
    assert!(s.suspends > 200, "{s:?}");
}

#[test]
fn a_thousand_tasks_finish_and_free_everything() {
    let s = check_program(
        "mil",
        r#"async fn hoja(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn rama(n: Int) -> Int {
    if n <= 0 {
        return 0
    }
    let hijo = spawn rama(n - 1)
    let mio = spawn hoja(n)
    await yieldNow()
    let a = await hijo
    let b = await mio
    return a + b
}

async fn main() {
    let r = spawn rama(1000)
    let total = await r
    print(total)
}
"#,
        "500500\n",
    );
    // 2002 tasks, each with a state and a scheduler record.
    assert!(s.allocs > 4000, "{s:?}");
    assert_eq!(s.allocs, s.frees, "{s:?}");
}

#[test]
fn a_deep_chain_of_suspended_tasks_is_cancelled_without_recursing() {
    // 20 000 tasks, each one suspended holding the handle of the next. When
    // main ends, destroying the first handle must release the whole chain:
    // doing it recursively would overflow the stack, so the runtime drains a
    // list of records awaiting destruction instead.
    let s = check_program(
        "cadena_profunda",
        r#"async fn cadena(n: Int) -> Int {
    if n <= 0 {
        return 0
    }
    let h = spawn cadena(n - 1)
    await yieldNow()
    let r = await h
    return r + 1
}

async fn main() {
    let c = spawn cadena(20000)
    var i = 0
    while i < 12000 {
        await yieldNow()
        i += 1
    }
    print("main termina con la cadena viva")
}
"#,
        "main termina con la cadena viva\n",
    );
    assert_eq!(s.allocs, s.frees, "{s:?}");
    assert!(s.allocs > 40000, "{s:?}");
}

#[test]
fn tasks_created_in_a_loop_are_released_each_iteration() {
    let s = check_program(
        "bucle",
        r#"async fn doble(n: Int) -> Int {
    await yieldNow()
    return n * 2
}

async fn main() {
    var total = 0
    var i = 1
    while i <= 50 {
        let t = spawn doble(i)
        let v = await t
        total = total + v
        i = i + 1
    }
    print(total)
}
"#,
        "2550\n",
    );
    assert_eq!(s.suspends, 100, "{s:?}");
}

#[test]
fn many_tasks_cancelled_before_running_are_released_at_once() {
    // main never suspends, so every task is still queued and unpolled when its
    // handle dies. Cancelling it has to take the record out of the ready queue
    // and release it there and then: otherwise 50 000 records would pile up
    // until the scheduler got its turn.
    let s = check_program(
        "cancelar_en_cola",
        r#"async fn trabajo(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn main() {
    var i = 0
    while i < 50000 {
        let t = spawn trabajo(i)
        i += 1
    }
    print(i)
}
"#,
        "50000\n",
    );
    assert_eq!(s.suspends, 0, "{s:?}");
    assert_eq!(s.allocs, s.frees, "{s:?}");
}

#[test]
fn an_async_main_without_tasks_still_runs_on_the_scheduler() {
    let s = check_program(
        "sin_tareas",
        r#"async fn main() {
    print(1)
    await yieldNow()
    print(2)
}
"#,
        "1\n2\n",
    );
    assert_eq!(s.suspends, 1, "{s:?}");
}

// --------------------------------------------------------------- rejected --

#[test]
fn a_handle_is_consumed_once() {
    // Awaiting twice, and using a handle after moving it, are uses after move.
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let t = spawn f()\n    let a = await t\n    let b = await t\n}",
        "L0005",
        "después de moverlo",
    );
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let t = spawn f()\n    let u = t\n    let a = await t\n}",
        "L0005",
        "después de moverlo",
    );
}

#[test]
fn a_handle_cannot_escape_its_async_scope() {
    // Returning it: the result type of a function can never be a handle.
    rejects(
        "async fn f() -> Int = 1\nasync fn g() -> Int {\n    let t = spawn f()\n    return t\n}\nfn main() {}",
        "L0001",
        "TaskHandle",
    );
    // Storing it in an aggregate, or passing it on, would untie it from the
    // scope that owns the task.
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let t = spawn f()\n    let l = List[List[t]]\n}",
        "L0015",
        "no se puede almacenar en un agregado",
    );
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let t = spawn f()\n    let a = [t]\n}",
        "L0015",
        "no se puede almacenar en un agregado",
    );
    rejects(
        "struct S {\n    t: Int\n}\nasync fn f() -> Int = 1\nasync fn main() {\n    let t = spawn f()\n    let s = S(t: t)\n}",
        "L0001",
        "TaskHandle",
    );
    rejects(
        "async fn f() -> Int = 1\nasync fn g(x: Int) -> Int = x\nasync fn main() {\n    let t = spawn f()\n    let v = await g(t)\n}",
        "L0001",
        "TaskHandle",
    );
    // The same rule closes the hole for the futures of the first increment.
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let l = List[f()]\n}",
        "L0015",
        "no se puede almacenar en un agregado",
    );
}

#[test]
fn spawn_is_only_valid_on_an_async_call_inside_an_async_function() {
    rejects(
        "async fn f() -> Int = 1\nfn main() {\n    let t = spawn f()\n}",
        "L0015",
        "spawn solo se puede usar dentro de una función async",
    );
    rejects(
        "fn f() -> Int = 1\nasync fn main() {\n    let t = spawn f()\n}",
        "L0015",
        "spawn espera la llamada a una función async",
    );
    rejects(
        "async fn main() {\n    let t = spawn 3\n}",
        "L0015",
        "spawn espera la llamada a una función async",
    );
    // `await` still needs a future or a handle, and still only inside async.
    rejects(
        "async fn main() {\n    let v = await 3\n}",
        "L0015",
        "await espera el future de una llamada async o un TaskHandle",
    );
    rejects(
        "async fn f() -> Int = 1\nfn main() {\n    let v = await f()\n}",
        "L0015",
        "await solo se puede usar dentro de una función async",
    );
}

#[test]
fn unsupported_values_cannot_cross_into_or_out_of_a_task() {
    // A task cannot capture a borrowed argument.
    rejects(
        "async fn f(x: &Int) -> Int = 1\nfn main() {}",
        "L0015",
        "tipo o modo no admitido",
    );
    // A local holding resources is released before suspending, so it cannot be
    // read after the await, whether the suspension comes from a task or not.
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let otro = f()\n    let t = spawn f()\n    let v = await t\n    let n = await otro\n}",
        "L0015",
        "no sobrevive a una suspensión",
    );
    // A region lives in the frame of the poll call, which ends at a suspension.
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    region r {\n        let t = spawn f()\n        let v = await t\n    }\n}",
        "L0015",
        "una región está abierta",
    );
    // Iterating a collection borrows it for the whole loop.
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let l = List[1, 2]\n    for x in l {\n        let t = spawn f()\n        let v = await t\n    }\n}",
        "L0015",
        "for sobre una colección",
    );
}

#[test]
fn await_of_a_handle_stays_at_a_statement_boundary() {
    check_program(
        "handle_in_expr",
        r#"
async fn f() -> Int {
    return 10
}

async fn main() {
    let t = spawn f()
    print(await t)

    let t2 = spawn f()
    let v = 1 + (await t2)
    print(v)

    let t3 = spawn f()
    var s = 5
    s += await t3
    print(s)
}
"#,
        "10\n11\n15\n",
    );
}

#[test]
fn spawn_reports_the_allocations_it_makes() {
    // Registering a task reserves its state and its scheduler record, so a
    // @noalloc function cannot spawn: the allocation is accounted for instead
    // of being hidden inside the runtime.
    rejects(
        "async fn f() -> Int = 1\n@noalloc async fn g() -> Int {\n    let t = spawn f()\n    let v = await t\n    return v\n}\nfn main() {}",
        "L0010",
        "@noalloc",
    );
    // A spawned task commits to running its body, so its effects belong to the
    // function that spawned it.
    rejects(
        "async fn f() -> Int {\n    print(1)\n    return 1\n}\nasync fn g() -> Int !{} {\n    let t = spawn f()\n    let v = await t\n    return v\n}\nfn main() {}",
        "L0010",
        "efecto",
    );
}

#[test]
fn cancelling_tasks_drops_only_initialized_text_slots() {
    let s = check_program(
        "cancelar_texto",
        r#"async fn trabajo(n: Int) -> Text {
    let moved_from = "trabajo {n}"
    let visible = moved_from
    if n == 0 {
        print(visible)
    }
    await yieldNow()
    let late = "tarde {n}"
    await yieldNow()
    print(late)
    return visible
}

async fn main() {
    let pending = spawn trabajo(0)
    await yieldNow()
    let unpolled = spawn trabajo(1)
    print("cancelar")
}
"#,
        "trabajo 0\ncancelar\n",
    );
    assert!(s.suspends == 2 && s.allocs > 2, "{s:?}");
}

#[test]
fn owned_text_tasks_complete_and_cancel_at_three_scales() {
    let s = check_program(
        "carga_texto",
        include_str!("../../../bench/programs/async_owned_text.l"),
        "10\n100\n1000\n",
    );
    assert!(s.allocs >= 2220 && s.suspends >= 2220, "{s:?}");
}

#[test]
fn cancellation_releases_ready_results_and_cascades_to_owned_text() {
    let s = check_program(
        "cancelar_cascada_texto",
        r#"async fn lista(n: Int) -> Text {
    let t = "listo {n}"
    print(t)
    return t
}

async fn hija(n: Int) {
    let t = "hija {n}"
    print(t)
    loop {
        await yieldNow()
    }
}

async fn padre(n: Int) {
    let t = "padre {n}"
    print(t)
    let h = spawn hija(n)
    loop {
        await yieldNow()
    }
}

async fn main() {
    let listo = spawn lista(1)
    let pendiente = spawn padre(2)
    await yieldNow()
    await yieldNow()
    print("fin")
}
"#,
        "listo 1\npadre 2\nhija 2\nfin\n",
    );
    assert!(s.suspends >= 3 && s.allocs > 8, "{s:?}");
}

#[test]
fn cancelling_unpolled_parameters_and_partially_moved_structs() {
    let stats = check_program(
        "async_cancelar_campos",
        r#"struct Datos {
    nombre: Text
    ciudad: Text
}

async fn trabajar(d: Datos, extra: Text) {
    await yieldNow()
    let nombre = d.nombre
    print(nombre)
    await yieldNow()
    print(extra)
    print(d.ciudad)
}

async fn main() {
    let n = 7
    let pendiente = spawn trabajar(Datos(nombre: "Ana {n}", ciudad: "Ciudad {n}"), "Extra {n}")
    await yieldNow()
    await yieldNow()
    let nunca = spawn trabajar(Datos(nombre: "Nadie {n}", ciudad: "Lugar {n}"), "Otro {n}")
    print("fin")
}
"#,
        "Ana 7\nfin\n",
    );
    assert_eq!(stats.suspends, 4, "{stats:?}");
    assert!(stats.allocs > 8, "{stats:?}");
}

#[test]
fn struct_tasks_complete_and_cancel_at_three_scales() {
    let stats = check_program(
        "async_carga_structs",
        include_str!("../../../bench/programs/async_owned_structs.l"),
        "10\n100\n1000\n",
    );
    assert_eq!(stats.suspends, 5550, "{stats:?}");
    assert!(stats.allocs > 2220, "{stats:?}");
}

#[test]
fn cancellation_drops_only_the_active_enum_payload() {
    let stats = check_program(
        "async_cancelar_enum",
        r#"enum Mensaje {
    Nada(Int)
    Texto(Text, Text)
}

async fn trabajar(m: Mensaje) {
    await yieldNow()
    match m {
        Mensaje.Nada(n) => print(n)
        Mensaje.Texto(a, b) => print("{a} {b}")
    }
}

async fn main() {
    let n = 3
    let primero = spawn trabajar(Mensaje.Texto("uno {n}", "dos {n}"))
    let segundo = spawn trabajar(Mensaje.Nada(n))
    await yieldNow()
    let nunca = spawn trabajar(Mensaje.Texto("tres {n}", "cuatro {n}"))
    print("fin")
}
"#,
        "fin\n",
    );
    assert_eq!(stats.suspends, 3, "{stats:?}");
    assert!(stats.allocs > 8, "{stats:?}");
}

#[test]
fn list_tasks_complete_and_cancel_at_three_scales() {
    let stats = check_program(
        "async_carga_listas",
        include_str!("../../../bench/programs/async_owned_lists.l"),
        "10\n100\n1000\n",
    );
    assert_eq!(stats.suspends, 5550, "{stats:?}");
    assert!(stats.allocs > 2220, "{stats:?}");
}

#[test]
fn cascade_drops_lists_after_replacement_and_struct_field_moves() {
    let stats = check_program(
        "async_cascada_listas",
        r#"struct Dato {
    nombre: Text
    ciudad: Text
}

async fn cadena(n: Int, original: List<Dato>) {
    var lista = original
    lista[0] = Dato(nombre: "nuevo {n}", ciudad: "cambio {n}")
    let parcial = Dato(nombre: "parcial {n}", ciudad: "queda {n}")
    let movido = parcial.nombre
    if n > 0 {
        let siguiente = spawn cadena(n - 1, List[Dato(nombre: "hija {n}", ciudad: "lugar {n}")])
        await siguiente
        return
    }
    print(lista[0].nombre)
    loop { await yieldNow() }
}

async fn main() {
    let n = 1000
    let raiz = spawn cadena(n, List[Dato(nombre: "raíz {n}", ciudad: "lugar {n}")])
    for i in 0..n + 2 {
        await yieldNow()
    }
    print("fin")
}
"#,
        "nuevo 0\nfin\n",
    );
    assert!(stats.suspends > 1000 && stats.allocs > 1000, "{stats:?}");
}

#[test]
fn join_delivers_already_completed_results_of_the_same_task_type() {
    let s = check_program(
        "join_listas",
        r#"async fn calcular(n: Int) -> Int = n * 2
async fn main() {
    let a = spawn calcular(10)
    let b = spawn calcular(20)
    await yieldNow()
    let par = await join(a, b)
    print(par.first)
    print(par.second)
}
"#,
        "20\n40\n",
    );
    assert_eq!(s.suspends, 1, "{s:?}");
}

#[test]
fn join_registers_both_children_and_keeps_argument_order() {
    let s = check_program(
        "join_intercalado",
        r#"async fn lenta(n: Int) -> Text {
    print("lenta inicia")
    await yieldNow()
    print("lenta paso 1")
    await yieldNow()
    print("lenta paso 2")
    await yieldNow()
    print("lenta termina")
    return "mensaje {n}"
}
async fn rapida() -> Float {
    print("rápida inicia")
    await yieldNow()
    print("rápida termina")
    return 2.5
}
async fn main() {
    let a = spawn lenta(7)
    let b = spawn rapida()
    let par = await join(a, b)
    print(par.first)
    print(par.second)
}
"#,
        "lenta inicia\nrápida inicia\nlenta paso 1\nrápida termina\nlenta paso 2\nlenta termina\nmensaje 7\n2.5\n",
    );
    // Three yields in lenta, one in rapida, and two parent Pending polls.
    assert_eq!(s.suspends, 6, "{s:?}");
}

#[test]
fn nested_join_transfers_struct_list_result_and_unit() {
    let s = check_program(
        "join_anidado_propietarios",
        r#"struct Dato {
    nombre: Text
    numero: Int
}
async fn detalle(n: Int) -> Result<Dato, Text> {
    await yieldNow()
    if n < 0 {
        return Result.Err("error {n}")
    }
    return Result.Ok(Dato(nombre: "nombre {n}", numero: n))
}
async fn lista(n: Int) -> List<Text> {
    await yieldNow()
    return List["lista {n}"]
}
async fn grupo(n: Int) -> Result<List<Text>, Text> {
    let par = await join(spawn detalle(n), spawn lista(n))
    await yieldNow()
    let estado = par.first
    let dato = estado?
    var salida = par.second
    salida.push(dato.nombre)
    return Result.Ok(salida)
}
async fn vacia() {}
async fn encendido() -> Bool = true
async fn main() {
    let par = await join(spawn grupo(2), spawn grupo(-1))
    let a = par.first
    let b = par.second
    match a {
        Result.Ok(xs) => print(xs[1]),
        Result.Err(e) => print(e),
    }
    match b {
        Result.Ok(xs) => print(xs[0]),
        Result.Err(e) => print(e),
    }
    let otro = await join(spawn vacia(), spawn encendido())
    print(otro.second)
}
"#,
        "nombre 2\nerror -1\ntrue\n",
    );
    assert!(s.suspends >= 8, "{s:?}");
}

#[test]
fn cancelling_join_releases_pending_children_and_ready_owned_results() {
    let s = check_program(
        "join_cancelacion",
        r#"async fn primera(n: Int) -> Text {
    print("primera lista {n}")
    return "texto {n}"
}
async fn segunda(n: Int) -> List<Text> {
    if n == 0 {
        print("segunda pendiente {n}")
        await yieldNow()
        await yieldNow()
    }
    print("segunda lista {n}")
    return List["lista {n}"]
}
async fn padre(n: Int) {
    let par = await join(spawn primera(n), spawn segunda(n))
    print(par.first)
}
async fn main() {
    {
        let nunca = spawn padre(7)
    }
    for n in 0..2 {
        let t = spawn padre(n)
        await yieldNow()
        await yieldNow()
        print("cancelar {n}")
    }
}
"#,
        "primera lista 0\nsegunda pendiente 0\ncancelar 0\nprimera lista 1\nsegunda lista 1\ncancelar 1\n",
    );
    assert_eq!(s.suspends, 7, "{s:?}");
}

#[test]
fn join_rejects_wrong_arity_non_handles_and_reused_owners() {
    let prefix = r#"async fn texto(n: Int) -> Text = "texto {n}"
async fn main() {
    let a = spawn texto(1)
    let b = spawn texto(2)
"#;
    for (body, code, cause) in [
        ("let r = await join(a)", "L0015", "exactamente dos"),
        ("let r = await join(a, b, a)", "L0015", "exactamente dos"),
        ("let r = await join(a, texto(2))", "L0015", "TaskHandle"),
        ("let r = join(a, b)", "L0015", "await join"),
        ("let r = await join(a, a)", "L0005", "moverlo"),
        (
            "let r = await join(a, b)\n    let otro = await a",
            "L0005",
            "moverlo",
        ),
        (
            "let r = await join(a, b)\n    let x = r.first\n    print(r.first)",
            "L0005",
            "movido",
        ),
    ] {
        rejects(&format!("{prefix}    {body}\n}}"), code, cause);
    }
}

#[test]
fn cancelling_nested_joins_drains_the_owned_task_tree() {
    let s = check_program(
        "join_cancelacion_anidada",
        r#"async fn hoja(n: Int) -> List<Text> {
    let xs = List["hoja {n}"]
    print(xs[0])
    await yieldNow()
    await yieldNow()
    print("no debe terminar")
    return xs
}
async fn interior() -> Text {
    print("interior")
    let par = await join(spawn hoja(1), spawn hoja(2))
    return "interior listo"
}
async fn exterior() {
    let par = await join(spawn interior(), spawn hoja(3))
    print(par.first)
}
async fn main() {
    let t = spawn exterior()
    await yieldNow()
    await yieldNow()
    await yieldNow()
    print("fin")
}
"#,
        "interior\nhoja 3\nhoja 1\nhoja 2\nfin\n",
    );
    assert_eq!(s.suspends, 9, "{s:?}");
}

#[test]
fn join_stress_with_text_and_lists_at_three_scales() {
    let s = check_program(
        "join_carga",
        include_str!("../../../bench/programs/async_join.l"),
        "10\n100\n1000\n",
    );
    assert!(s.suspends >= 2220 && s.allocs > 1110, "{s:?}");
}

#[test]
fn deep_join_cascade_cancels_pending_branches_and_drops_completed_lists() {
    let s = check_program(
        "join_cascada_1000",
        r#"async fn lista(n: Int) -> List<Text> {
    await yieldNow()
    return List["lista {n}"]
}
async fn cadena(n: Int) -> Text {
    if n == 0 {
        print("fondo")
        loop {
            await yieldNow()
        }
    }
    let par = await join(spawn cadena(n - 1), spawn lista(n))
    return par.first
}
async fn main() {
    let raiz = spawn cadena(500)
    for i in 0..506 {
        await yieldNow()
    }
    print("fin")
}
"#,
        "fondo\nfin\n",
    );
    assert!(s.suspends > 1500 && s.allocs > 2000, "{s:?}");
}

#[test]
fn join_keeps_borrow_checks_for_the_suspension_and_its_result() {
    let prefix = r#"async fn f(n: Int) -> Text = "texto {n}"
async fn main() {
    let a = spawn f(1)
    let b = spawn f(2)
"#;
    rejects(
        &format!(
            "{prefix}    let n = 7\n    let r = &n\n    let par = await join(a, b)\n    print(r)\n}}"
        ),
        "L0015",
        "el préstamo no sobrevive",
    );
    rejects(
        &format!(
            "{prefix}    let par = await join(a, b)\n    let r = &par.first\n    let texto = par.first\n    print(r)\n}}"
        ),
        "L0012",
        "préstamo incompatible",
    );
}

#[test]
fn join_all_handles_empty_singleton_and_ordered_groups() {
    let s = check_program(
        "join_all_basico",
        r#"async fn calcular(n: Int) -> Int {
    if n == 10 {
        await yieldNow()
        await yieldNow()
    }
    if n == 20 {
        await yieldNow()
    }
    print("lista {n}")
    return n * 2
}
async fn main() {
    let vacia = await joinAll(taskGroup(calcular))
    print(vacia.length)
    let sola = await joinAll(List[spawn calcular(1)])
    print(sola[0])
    let tareas = List[spawn calcular(10), spawn calcular(20), spawn calcular(30)]
    let valores = await joinAll(tareas)
    for valor in valores {
        print(valor)
    }
}
"#,
        "0\nlista 1\n2\nlista 30\nlista 20\nlista 10\n20\n40\n60\n",
    );
    // Three child yields and one parent suspension per non-ready group.
    assert_eq!(s.suspends, 5, "{s:?}");
}

#[test]
fn join_all_collects_a_dynamic_group_that_was_already_ready() {
    let s = check_program(
        "join_all_listas",
        r#"async fn calcular(n: Int) -> Int = n
async fn main() {
    var tareas = taskGroup(calcular)
    for i in 0..10 {
        tareas.push(spawn calcular(i))
    }
    await yieldNow()
    let resultados = await joinAll(tareas)
    print(resultados.length)
    print(resultados[9])
}
"#,
        "10\n9\n",
    );
    assert_eq!(s.suspends, 1, "{s:?}");
}

#[test]
fn join_all_accepts_different_functions_with_one_result_type() {
    let s = check_program(
        "join_all_homogeneo",
        r#"async fn lento(n: Int) -> Text {
    await yieldNow()
    return "lento {n}"
}
async fn rapido(n: Int) -> Text = "rápido {n}"
async fn main() {
    var tareas = List[spawn lento(1), spawn rapido(2)]
    tareas.push(spawn rapido(3))
    let resultados = await joinAll(tareas)
    print(resultados[0])
    print(resultados[1])
    print(resultados[2])
}
"#,
        "lento 1\nrápido 2\nrápido 3\n",
    );
    assert_eq!(s.suspends, 2, "{s:?}");
}

#[test]
fn join_all_moves_aggregate_results_and_nested_groups() {
    let s = check_program(
        "join_all_propietarios",
        r#"struct Dato {
    nombre: Text
    lista: List<Text>
}
async fn datos(n: Int) -> Result<Dato, Text> {
    await yieldNow()
    if n < 0 {
        return Result.Err("error {n}")
    }
    return Result.Ok(Dato(nombre: "dato {n}", lista: List["lista {n}"]))
}
async fn agrupar(n: Int) -> List<Result<Dato, Text>> {
    let tareas = List[spawn datos(n), spawn datos(-n)]
    return await joinAll(tareas)
}
async fn main() {
    let tareas = List[spawn agrupar(1), spawn agrupar(2)]
    var resultados = await joinAll(tareas)
    await yieldNow()
    match resultados.pop() {
        Option.Some(xs) => {
            for r in xs {
                match r {
                    Result.Ok(d) => print("{d.nombre} {d.lista[0]}"),
                    Result.Err(e) => print(e),
                }
            }
        }
        Option.None => print("vacío"),
    }
    print(resultados.length)
}
"#,
        "dato 2 lista 2\nerror -2\n1\n",
    );
    assert!(s.suspends >= 8, "{s:?}");
}

#[test]
fn join_all_rejects_duplicate_moves_borrows_and_group_escape() {
    let prefix = r#"async fn f(n: Int) -> Int = n
async fn g() -> Text = "texto"
fn ignorar<T>(x: T) {}
async fn main() {
    let a = spawn f(1)
"#;
    for (body, code, cause) in [
        ("let r = await joinAll(List[a, a])", "L0005", "moverlo"),
        (
            "let r = await joinAll(List[a, spawn g()])",
            "L0001",
            "se esperaba",
        ),
        (
            "let r = await joinAll(List[1])",
            "L0015",
            "lista de TaskHandle",
        ),
        ("let r = joinAll(List[a])", "L0015", "await joinAll"),
        (
            "let ts = List[a]\n let r = await joinAll(ts)\n let otro = await joinAll(ts)",
            "L0005",
            "moverlo",
        ),
        ("let ts = List[a]\n let r = await a", "L0005", "moverlo"),
        (
            "let ts = List[a]\n let t = ts[0]",
            "L0015",
            "grupo de tareas",
        ),
        ("let ts = List[a]\n let t = &ts", "L0015", "grupo de tareas"),
        ("let ts = List[a]\n ignorar(ts)", "L0015", "grupo de tareas"),
        (
            "let ts = List[a]\n let listas = List[ts]",
            "L0015",
            "grupo de tareas",
        ),
        (
            "var ts = List[a]\n let otro = ts.pop()",
            "L0015",
            "solo admite",
        ),
        (
            "let ts = List[a]\n let n = 1\n let r = &n\n let xs = await joinAll(ts)\n print(r)",
            "L0015",
            "préstamo no sobrevive",
        ),
    ] {
        rejects(&format!("{prefix} {body}\n}}"), code, cause);
    }
}

#[test]
fn join_all_cancels_nested_large_groups_and_reuses_records() {
    let s = check_program(
        "join_all_cancelacion_masiva",
        r#"async fn elemento(n: Int) -> Text {
    if n == 0 {
        print("primera lista")
        return "lista {n}"
    }
    await yieldNow()
    await yieldNow()
    return "pendiente {n}"
}
async fn subgrupo(n: Int) -> List<Text> {
    var ts = taskGroup(elemento)
    ts.reserve(n)
    for i in 0..n {
        ts.push(spawn elemento(i))
    }
    return await joinAll(ts)
}
async fn padre(n: Int) {
    let ts = List[spawn subgrupo(n), spawn subgrupo(n)]
    let resultados = await joinAll(ts)
    print("no debe reanudarse")
}
async fn main() {
    {
        let nunca = spawn padre(5000)
    }
    {
        let p = spawn padre(5000)
        await yieldNow()
        await yieldNow()
        await yieldNow()
        print("cancelar")
    }
    let resultados = await joinAll(List[spawn elemento(1), spawn elemento(2)])
    print(resultados[0])
    print(resultados[1])
}
"#,
        "primera lista\nprimera lista\ncancelar\npendiente 1\npendiente 2\n",
    );
    assert!(s.suspends >= 10_000 && s.allocs >= 20_000, "{s:?}");
}

#[test]
fn join_all_cancels_groups_when_none_or_all_children_are_ready() {
    let s = check_program(
        "join_all_cancelacion_extremos",
        r#"async fn hijo(n: Int) -> List<Text> {
    if n == 0 {
        await yieldNow()
        await yieldNow()
    }
    print("lista {n}")
    return List["resultado {n}"]
}
async fn padre(n: Int) {
    let r = await joinAll(List[spawn hijo(n), spawn hijo(n)])
    print("no debe reanudarse")
}
async fn main() {
    for i in 0..2 {
        let p = spawn padre(i)
        await yieldNow()
        await yieldNow()
        print("cancelar {i}")
    }
}
"#,
        "cancelar 0\nlista 1\nlista 1\ncancelar 1\n",
    );
    assert_eq!(s.suspends, 8, "{s:?}");
}

#[test]
fn join_all_stress_scales_to_ten_thousand_owned_results() {
    let s = check_program(
        "join_all_carga",
        include_str!("../../../bench/programs/async_join_all.l"),
        "10\n100\n1000\n10000\n",
    );
    assert_eq!(s.suspends, 16669, "{s:?}");
}

#[test]
fn join_all_supports_float_bool_and_option_results() {
    let s = check_program(
        "join_all_otros_tipos",
        r#"async fn real(n: Int) -> Float {
    await yieldNow()
    if n == 1 {
        return 1.25
    }
    return 2.5
}
async fn logico(n: Int) -> Bool = n == 1
async fn opcion(n: Int) -> Option<Int> {
    if n == 1 {
        return Option.Some(n)
    }
    return Option.None()
}
async fn main() {
    let xs = await joinAll(List[spawn real(1), spawn real(2)])
    print(xs[0])
    print(xs[1])
    let bs = await joinAll(List[spawn logico(1), spawn logico(2)])
    print(bs[0])
    print(bs[1])
    var os = await joinAll(List[spawn opcion(1), spawn opcion(2)])
    match os.pop() {
        Option.Some(Option.None) => print("ninguno"),
        _ => print("incorrecto"),
    }
}
"#,
        "1.25\n2.5\ntrue\nfalse\nninguno\n",
    );
    assert_eq!(s.suspends, 5, "{s:?}");
}

#[test]
fn dropping_a_moved_group_cancels_owned_children_without_join() {
    let s = check_program(
        "join_all_drop_sin_esperar",
        r#"async fn hija(n: Int) -> Text {
    print(n)
    await yieldNow()
    print("no debe reanudarse")
    return "fin {n}"
}
async fn main() {
    {
        let original = List[spawn hija(1), spawn hija(2)]
        let movido = original
        await yieldNow()
        print(movido.length)
    }
    await yieldNow()
    print("fin")
}
"#,
        "1\n2\n2\nfin\n",
    );
    assert_eq!(s.suspends, 4, "{s:?}");
}

// -------------------------------------------------------------- taskGroup --

#[test]
fn task_group_canonical_and_spawn_push_syntax() {
    let s = check_program(
        "task_group_sintaxis_canonica",
        r#"async fn doble(n: Int) -> Int {
    await yieldNow()
    return n * 2
}

async fn main() {
    var grupo = taskGroup<Int>()
    grupo.reserve(4)
    grupo.spawn(doble(10))
    grupo.push(spawn doble(20))
    grupo.spawn(doble(30))

    let resultados = await grupo.joinAll()
    print(resultados.length)
    for r in resultados {
        print(r)
    }
}
"#,
        "3\n20\n40\n60\n",
    );
    assert_eq!(s.suspends, 4, "{s:?}");
}

#[test]
fn task_group_type_annotation_and_different_types() {
    let s = check_program(
        "task_group_anotacion_y_tipos",
        r#"struct Punto {
    x: Int
    y: Int
}

async fn punto_async(n: Int) -> Punto {
    await yieldNow()
    return Punto(x: n, y: n * 10)
}

async fn texto_async(n: Int) -> Text {
    await yieldNow()
    return "val {n}"
}

async fn real_async(n: Int) -> Float {
    await yieldNow()
    return 1.25
}

async fn main() {
    var gp: TaskGroup<Punto> = taskGroup<Punto>()
    gp.spawn(punto_async(5))
    let puntos = await gp.joinAll()
    print(puntos[0].x)
    print(puntos[0].y)

    var gt: TaskGroup<Text> = taskGroup<Text>()
    gt.spawn(texto_async(7))
    let textos = await gt.joinAll()
    print(textos[0])

    var gf: TaskGroup<Float> = taskGroup<Float>()
    gf.spawn(real_async(1))
    let reales = await gf.joinAll()
    print(reales[0])
}
"#,
        "5\n50\nval 7\n1.25\n",
    );
    assert_eq!(s.suspends, 6, "{s:?}");
}

#[test]
fn task_group_survives_suspension_before_join_all() {
    let s = check_program(
        "task_group_suspension_intermedia",
        r#"async fn trabajo(t: Text) -> Text {
    await yieldNow()
    return "eco {t}"
}

async fn main() {
    var grupo = taskGroup<Text>()
    grupo.spawn(trabajo("primero"))
    await yieldNow()
    grupo.spawn(trabajo("segundo"))
    await yieldNow()
    let res = await grupo.joinAll()
    print(res.length)
    print(res[0])
    print(res[1])
}
"#,
        "2\neco primero\neco segundo\n",
    );
    assert!(s.suspends >= 4, "{s:?}");
}

#[test]
fn task_group_nested_and_composition() {
    let s = check_program(
        "task_group_anidado",
        r#"async fn sub_hijo(n: Int) -> Int {
    await yieldNow()
    return n * 3
}

async fn tarea_con_subgrupo(base: Int) -> Int {
    var sub = taskGroup<Int>()
    sub.spawn(sub_hijo(base))
    sub.spawn(sub_hijo(base + 1))
    let res = await sub.joinAll()
    return res[0] + res[1]
}

async fn main() {
    var principal = taskGroup<Int>()
    principal.spawn(tarea_con_subgrupo(10))
    principal.spawn(tarea_con_subgrupo(20))
    let final_res = await principal.joinAll()
    print(final_res[0])
    print(final_res[1])
}
"#,
        "63\n123\n",
    );
    assert!(s.suspends >= 5, "{s:?}");
}

#[test]
fn task_group_drop_cancels_unawaited_tasks() {
    let s = check_program(
        "task_group_drop_cancela",
        r#"async fn hija(n: Int) -> Text {
    print("inicio {n}")
    await yieldNow()
    print("no debe aparecer {n}")
    return "fin {n}"
}

async fn main() {
    {
        var grupo = taskGroup<Text>()
        grupo.spawn(hija(1))
        grupo.spawn(hija(2))
        await yieldNow()
        print("saliendo del ambito")
    }
    await yieldNow()
    print("terminado")
}
"#,
        "inicio 1\ninicio 2\nsaliendo del ambito\nterminado\n",
    );
    assert_eq!(s.suspends, 4, "{s:?}");
}

#[test]
fn task_group_drop_on_early_return_cancels_pending_tasks() {
    let s = check_program(
        "task_group_retorno_temprano",
        r#"async fn hija(n: Int) -> Int {
    print("hija {n}")
    await yieldNow()
    print("no debe verse")
    return n
}

async fn probar(temprano: Bool) -> Int {
    var grupo = taskGroup<Int>()
    grupo.spawn(hija(1))
    grupo.spawn(hija(2))
    await yieldNow()
    if temprano {
        return 42
    }
    let res = await grupo.joinAll()
    return res[0]
}

async fn main() {
    let v = await probar(true)
    print(v)
    await yieldNow()
    print("fin")
}
"#,
        "hija 1\nhija 2\n42\nfin\n",
    );
    assert_eq!(s.suspends, 4, "{s:?}");
}

#[test]
fn task_group_stress_scales_to_ten_thousand_tasks() {
    let s = check_program(
        "task_group_estres",
        include_str!("../../../bench/programs/async_taskgroup.l"),
        "90\n9900\n999000\n99990000\n",
    );
    assert_eq!(s.suspends, 16669, "{s:?}");
}

#[test]
fn task_group_scope_escape_and_ownership_rejections() {
    // 1. TaskGroup no se puede pasar como parámetro
    rejects(
        "async fn f(g: TaskGroup<Int>) {}\nfn main() {}",
        "L0015",
        "pertenece al ámbito que lo crea",
    );

    // 2. TaskGroup no se puede retornar en firma
    rejects(
        "async fn f() -> TaskGroup<Int> {\n    return taskGroup<Int>()\n}\nfn main() {}",
        "L0015",
        "pertenece al ámbito que lo crea",
    );

    // 3. TaskGroup no se puede retornar en sentencia return
    rejects(
        "async fn f() {\n    var g = taskGroup<Int>()\n    return g\n}\nfn main() {}",
        "L0015",
        "un grupo de tareas no se puede retornar",
    );

    // 4. TaskGroup no se puede almacenar en structs
    rejects(
        "struct Contenedor {\n    g: TaskGroup<Int>\n}\nfn main() {}",
        "L0015",
        "pertenece al ámbito que lo crea",
    );

    // 5. TaskGroup no se puede almacenar en enums
    rejects(
        "enum OpcionG {\n    G(TaskGroup<Int>)\n}\nfn main() {}",
        "L0015",
        "pertenece al ámbito que lo crea",
    );

    // 6. TaskGroup no se puede almacenar en colecciones
    rejects(
        "async fn f() {\n    let xs = List[taskGroup<Int>()]\n}\nfn main() {}",
        "L0015",
        "no se puede almacenar en un agregado",
    );

    // 7. Escape a un ámbito más amplio
    rejects(
        "async fn f() {\n    var outer = taskGroup<Int>()\n    if true {\n        let inner = taskGroup<Int>()\n        outer = inner\n    }\n}\nfn main() {}",
        "L0015",
        "el grupo de tareas no puede escapar a un ámbito más amplio",
    );

    // 8. No admite préstamos
    rejects(
        "async fn f() {\n    let g = taskGroup<Int>()\n    let r = &g\n}\nfn main() {}",
        "L0012",
        "TaskGroup no admite préstamos",
    );

    // 9. No se puede crear en contexto no async
    rejects(
        "fn main() {\n    var g = taskGroup<Int>()\n}",
        "L0015",
        "taskGroup requiere un ámbito async",
    );

    // 10. No soporta indexación
    rejects(
        "async fn f() {\n    let g = taskGroup<Int>()\n    let x = g[0]\n}\nfn main() {}",
        "L0001",
        "no se puede indexar",
    );

    // 11. No soporta iteración for-in directa
    rejects(
        "async fn f() {\n    let g = taskGroup<Int>()\n    for x in g {}\n}\nfn main() {}",
        "L0001",
        "requiere un array, slice o List",
    );

    // 12. Método joinAll sin await
    rejects(
        "async fn f() {\n    var g = taskGroup<Int>()\n    g.joinAll()\n}\nfn main() {}",
        "L0015",
        "joinAll solo se admite como await",
    );

    // 13. Método desconocido en TaskGroup
    rejects(
        "async fn f() {\n    var g = taskGroup<Int>()\n    g.pop()\n}\nfn main() {}",
        "L0015",
        "un grupo de tareas solo admite",
    );

    // 14. Use after move
    rejects(
        "async fn f() {\n    var g = taskGroup<Int>()\n    let g2 = g\n    let r = await g.joinAll()\n}\nfn main() {}",
        "L0005",
        "uso de valor después de moverlo",
    );

    // 15. Double await
    rejects(
        "async fn f() {\n    var g = taskGroup<Int>()\n    let r1 = await g.joinAll()\n    let r2 = await g.joinAll()\n}\nfn main() {}",
        "L0005",
        "uso de valor después de moverlo",
    );

    // 16. Spawn after joinAll
    rejects(
        "async fn h() -> Int = 1\nasync fn f() {\n    var g = taskGroup<Int>()\n    let r = await g.joinAll()\n    g.spawn(h())\n}\nfn main() {}",
        "L0005",
        "uso de valor después de moverlo",
    );
}
