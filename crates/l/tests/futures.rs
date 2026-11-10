//! First-Class Futures in ELE: variables, moves, single ownership,
//! function arguments and returns, dynamic dispatch, task groups, and clean
//! destructor drops with zero memory leaks.

use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/futures")
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

fn rejects(source: &str, code: &str, cause: &str) {
    let e = check(source).expect_err(source);
    assert_eq!(e.code, code, "{source}: {e:?}");
    assert!(e.message.contains(cause), "{source}: {e:?}");
    assert!(e.span.line > 0 && e.span.column > 0, "{source}: {e:?}");
}

// ------------------------------------------------------------------ tests --

#[test]
fn future_in_variable_lazy_and_awaited() {
    let s = check_program(
        "future_var_lazy",
        r#"async fn calcular(n: Int) -> Int {
    await yieldNow()
    return n * 3
}

async fn main() {
    let fut: Future<Int> = calcular(14)
    print("antes de await")
    let r = await fut
    print(r)
}
"#,
        "antes de await\n42\n",
    );
    assert!(s.suspends >= 1);
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn future_moved_between_locals() {
    let s = check_program(
        "future_moved",
        r#"async fn sumar(a: Int, b: Int) -> Int {
    return a + b
}

async fn main() {
    let f1 = sumar(15, 25)
    let f2 = f1
    let r = await f2
    print(r)
}
"#,
        "40\n",
    );
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn future_as_function_parameter() {
    let s = check_program(
        "future_param",
        r#"async fn obtener(x: Int) -> Int {
    return x * 10
}

fn reenviar(f: Future<Int>) -> Future<Int> {
    return f
}

async fn procesar_async(f: Future<Int>) -> Int {
    return await f
}

async fn main() {
    let f1: Future<Int> = obtener(5)
    let f1_reenviado = reenviar(f1)
    let r1 = await f1_reenviado
    let f2: Future<Int> = obtener(7)
    let r2 = await procesar_async(f2)
    print(r1 + r2)
}
"#,
        "120\n",
    );
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn future_returned_from_function() {
    let s = check_program(
        "future_return",
        r#"async fn operacion(n: Int) -> Int {
    return n + 100
}

fn fabricar(n: Int) -> Future<Int> {
    return operacion(n)
}

async fn main() {
    let f = fabricar(23)
    let r = await f
    print(r)
}
"#,
        "123\n",
    );
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn future_dynamic_composition_and_selection() {
    let s = check_program(
        "future_composition",
        r#"async fn camino_a() -> Int {
    return 100
}

async fn camino_b() -> Int {
    return 200
}

fn seleccionar(cond: Bool) -> Future<Int> {
    if cond {
        return camino_a()
    } else {
        return camino_b()
    }
}

async fn resolver(f: Future<Int>) -> Int {
    return await f
}

async fn main() {
    let fa = seleccionar(true)
    let ra = await resolver(fa)
    let fb = seleccionar(false)
    let rb = await resolver(fb)
    print(ra + rb)
}
"#,
        "300\n",
    );
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn future_spawn_and_scheduler_transfer() {
    let s = check_program(
        "future_spawn_transfer",
        r#"async fn tarea(val: Int) -> Int {
    await yieldNow()
    return val * 4
}

async fn main() {
    let fut: Future<Int> = tarea(10)
    let handle = spawn fut
    let r = await handle
    print(r)
}
"#,
        "40\n",
    );
    assert!(s.suspends >= 1);
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn future_taskgroup_integration() {
    let s = check_program(
        "future_taskgroup",
        r#"async fn elemento(v: Int) -> Int {
    return v * 2
}

async fn main() {
    var tg = taskGroup<Int>()
    let f1 = elemento(5)
    let f2 = elemento(10)
    tg.spawn(f1)
    tg.push(spawn f2)
    let results = await joinAll(tg)
    print(results[0])
    print(results[1])
}
"#,
        "10\n20\n",
    );
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn abandoned_unpolled_future_drops_cleanly_with_zero_leaks() {
    let s = check_program(
        "future_abandoned",
        r#"struct Dato {
    etiqueta: Text
    valor: Int
}

async fn con_recursos(d: Dato) -> Text {
    return d.etiqueta
}

async fn main() {
    let f = con_recursos(Dato(etiqueta: "hola mundo con memoria propietaria", valor: 42))
    print("futuro creado y descartado")
}
"#,
        "futuro creado y descartado\n",
    );
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn negative_future_diagnostics() {
    // Double await of an owned future rejected with L0005
    rejects(
        r#"async fn f() -> Int = 1
async fn main() {
    let fut: Future<Int> = f()
    let a = await fut
    let b = await fut
}
"#,
        "L0005",
        "después de moverlo",
    );

    // Double spawn of an owned future rejected with L0005
    rejects(
        r#"async fn f() -> Int = 1
async fn main() {
    let fut = f()
    let h1 = spawn fut
    let h2 = spawn fut
}
"#,
        "L0005",
        "después de moverlo",
    );

    // Use after move to variable rejected with L0005
    rejects(
        r#"async fn f() -> Int = 1
async fn main() {
    let f1 = f()
    let f2 = f1
    let r = await f1
}
"#,
        "L0005",
        "después de moverlo",
    );

    // Borrowing a future with & rejected with L0012
    rejects(
        r#"async fn f() -> Int = 1
async fn main() {
    let fut = f()
    let r = &fut
}
"#,
        "L0012",
        "Future no admite préstamos",
    );

    // Borrowing a future with &mut rejected with L0012
    rejects(
        r#"async fn f() -> Int = 1
async fn main() {
    var fut = f()
    let r = &mut fut
}
"#,
        "L0012",
        "Future no admite préstamos",
    );

    // Borrowed parameter of type &Future<T> rejected with L0012
    rejects(
        r#"fn probar(f: &Future<Int>) {}
fn main() {}
"#,
        "L0012",
        "Future no admite préstamos",
    );

    // Storing Future in struct rejected with L0015
    rejects(
        r#"struct Caja {
    f: Future<Int>
}
fn main() {}
"#,
        "L0015",
        "Future no se puede almacenar en un agregado ni colecciones",
    );

    // Storing Future in enum rejected with L0015
    rejects(
        r#"enum Opcion {
    Presente(Future<Int>)
}
fn main() {}
"#,
        "L0015",
        "Future no se puede almacenar en un agregado ni colecciones",
    );

    // Storing Future in List rejected with L0015
    rejects(
        r#"async fn f() -> Int = 1
async fn main() {
    let fut = f()
    let l = List[fut]
}
"#,
        "L0015",
        "Future no se puede almacenar en un agregado ni colecciones",
    );

    // Storing Future in Array rejected with L0015
    rejects(
        r#"async fn f() -> Int = 1
async fn main() {
    let fut = f()
    let arr = [fut]
}
"#,
        "L0015",
        "Future no se puede almacenar en un agregado ni colecciones",
    );
}
