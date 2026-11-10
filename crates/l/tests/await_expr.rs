//! Tests for general `await` expressions in ELE:
//! - Arithmetic and binary expressions with single and multiple awaits.
//! - Comparisons and conditions.
//! - Short-circuiting `&&` and `||` with asynchronous operands.
//! - Function and method arguments evaluated in strict left-to-right order.
//! - Return await expressions.
//! - Owned temporaries (`Text`, structs, lists) surviving suspensions.
//! - `Result` with `?` and `Option` with `??`.
//! - Nested awaits and integration with `spawn`, `TaskHandle`, `join`, and `TaskGroup`.
//! - Negative diagnostics and borrow check rejections.

use project_l::check;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

fn work(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/await_expr")
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
fn await_in_arithmetic_and_precedence() {
    let s = check_program(
        "await_arithmetic",
        r#"
async fn doble(n: Int) -> Int {
    await yieldNow()
    return n * 2
}

async fn main() {
    let a = (await doble(10)) + 5
    let b = 100 - (await doble(20))
    let c = (await doble(3)) * (await doble(4)) + 1
    print(a)
    print(b)
    print(c)
}
"#,
        "25\n60\n49\n",
    );
    assert!(s.suspends >= 4);
}

#[test]
fn await_in_comparisons_and_conditions() {
    let s = check_program(
        "await_conditions",
        r#"
async fn obtener(n: Int) -> Int {
    await yieldNow()
    return n
}

async fn esPositivo(n: Int) -> Bool {
    await yieldNow()
    return (await obtener(n)) > 0
}

async fn main() {
    if await esPositivo(10) {
        print("diez es positivo")
    }
    if (await obtener(5)) == 5 {
        print("cinco es cinco")
    }
    if (await obtener(-2)) > 0 {
        print("no debe imprimir")
    } else {
        print("menor o igual a cero")
    }
}
"#,
        "diez es positivo\ncinco es cinco\nmenor o igual a cero\n",
    );
    assert!(s.suspends >= 4);
}

#[test]
fn await_short_circuit_and() {
    // If left is false, right operand must never execute!
    let s = check_program(
        "await_short_circuit_and",
        r#"
async fn falso() -> Bool {
    await yieldNow()
    return false
}

async fn verdadero() -> Bool {
    await yieldNow()
    return true
}

async fn noDebeEjecutarse() -> Bool {
    print("ERROR: se ejecuto el lado derecho en cortocircuito")
    return true
}

async fn ladoDerecho() -> Bool {
    print("derecho evaluado")
    return true
}

async fn main() {
    if (await falso()) && (await noDebeEjecutarse()) {
        print("no debe entrar")
    } else {
        print("primer and correcto")
    }

    if (await verdadero()) && (await ladoDerecho()) {
        print("segundo and correcto")
    }
}
"#,
        "primer and correcto\nderecho evaluado\nsegundo and correcto\n",
    );
    assert!(s.suspends >= 2);
}

#[test]
fn await_short_circuit_or() {
    // If left is true, right operand must never execute!
    let s = check_program(
        "await_short_circuit_or",
        r#"
async fn verdadero() -> Bool {
    await yieldNow()
    return true
}

async fn falso() -> Bool {
    await yieldNow()
    return false
}

async fn noDebeEjecutarse() -> Bool {
    print("ERROR: se ejecuto el lado derecho en cortocircuito")
    return false
}

async fn ladoDerecho() -> Bool {
    print("derecho evaluado")
    return true
}

async fn main() {
    if (await verdadero()) || (await noDebeEjecutarse()) {
        print("primer or correcto")
    }

    if (await falso()) || (await ladoDerecho()) {
        print("segundo or correcto")
    }
}
"#,
        "primer or correcto\nderecho evaluado\nsegundo or correcto\n",
    );
    assert!(s.suspends >= 2);
}

#[test]
fn await_as_function_arguments_and_ordering() {
    let s = check_program(
        "await_fn_args",
        r#"
fn sumar3(a: Int, b: Int, c: Int) -> Int {
    return a + b + c
}

async fn paso1() -> Int {
    print("paso 1")
    await yieldNow()
    return 10
}

async fn paso2() -> Int {
    print("paso 2")
    await yieldNow()
    return 20
}

async fn paso3() -> Int {
    print("paso 3")
    await yieldNow()
    return 30
}

async fn main() {
    let total = sumar3(
        await paso1(),
        await paso2(),
        await paso3()
    )
    print(total)
}
"#,
        "paso 1\npaso 2\npaso 3\n60\n",
    );
    assert!(s.suspends >= 3);
}

#[test]
fn await_with_owned_text_surviving_suspension() {
    // Left operand creates an owned Text before right operand awaits and suspends!
    let s = check_program(
        "await_owned_text",
        r#"
fn concatenar(a: Text, b: Text) -> Text {
    return "{a}{b}"
}

fn crearPrefijo() -> Text {
    return "Hola, "
}

async fn obtenerMensaje() -> Text {
    await yieldNow()
    return "mundo asincrono!"
}

async fn main() {
    let completo = concatenar(crearPrefijo(), await obtenerMensaje())
    print(completo)
}
"#,
        "Hola, mundo asincrono!\n",
    );
    assert!(s.suspends >= 1);
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn await_with_structs_and_lists() {
    let s = check_program(
        "await_structs_and_lists",
        r#"
struct Par {
    x: Int,
    y: Int,
}

async fn calcular(n: Int) -> Int {
    await yieldNow()
    return n * 10
}

async fn main() {
    let p = Par(x: await calcular(1), y: await calcular(2))
    print(p.x)
    print(p.y)

    let lista = List[await calcular(3), await calcular(4)]
    for item in lista {
        print(item)
    }
}
"#,
        "10\n20\n30\n40\n",
    );
    assert!(s.suspends >= 4);
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn await_with_result_try_and_option_coalesce() {
    let s = check_program(
        "await_result_option",
        r#"
async fn dividir(a: Int, b: Int) -> Result<Int, Text> {
    await yieldNow()
    if b == 0 {
        return Err("division por cero")
    }
    return Ok(a / b)
}

async fn calcularSeguro(a: Int, b: Int) -> Result<Int, Text> {
    let res = (await dividir(a, b))?
    return Ok(res + 100)
}

async fn buscarValor(encontrado: Bool) -> Option<Int> {
    await yieldNow()
    if encontrado {
        return Some(42)
    }
    return None
}

async fn main() {
    let ok = await calcularSeguro(10, 2)
    match ok {
        Ok(v) => print(v),
        Err(e) => print(e),
    }

    let err = await calcularSeguro(10, 0)
    match err {
        Ok(v) => print(v),
        Err(e) => print(e),
    }

    let opt1 = (await buscarValor(true)) ?? 0
    let opt2 = (await buscarValor(false)) ?? 999
    print(opt1)
    print(opt2)
}
"#,
        "105\ndivision por cero\n42\n999\n",
    );
    assert!(s.suspends >= 4);
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn await_nested_and_taskgroup_integration() {
    let s = check_program(
        "await_taskgroup_integration",
        r#"
async fn calcular(n: Int) -> Int {
    await yieldNow()
    return n * 3
}

async fn main() {
    // 1. TaskHandle in arithmetic expression
    let h1 = spawn calcular(10)
    let h2 = spawn calcular(20)
    let sum = (await h1) + (await h2)
    print(sum)

    // 2. Join in arithmetic expression
    let a = spawn calcular(5)
    let b = spawn calcular(6)
    let par = await join(a, b)
    let total_par = par.first + par.second
    print(total_par)

    // 3. TaskGroup joinAll in expression
    var tg = taskGroup<Int>()
    tg.push(spawn calcular(1))
    tg.push(spawn calcular(2))
    let lista = await tg.joinAll()
    print(lista.length)
}
"#,
        "90\n33\n2\n",
    );
    assert!(s.suspends >= 4);
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn await_while_loop_with_async_condition() {
    let s = check_program(
        "await_while_loop",
        r#"
async fn limite(contador: Int) -> Bool {
    await yieldNow()
    return contador < 3
}

async fn main() {
    var i = 0
    while await limite(i) {
        print(i)
        i += 1
    }
    print("fin loop")
}
"#,
        "0\n1\n2\nfin loop\n",
    );
    assert!(s.suspends >= 3);
    assert_eq!(s.allocs, s.frees);
}

#[test]
fn negative_await_expression_diagnostics() {
    // 1. Await outside async function
    rejects(
        "fn sincrona() -> Int {\n    return (await 10) + 1\n}\nfn main() {}",
        "L0015",
        "await solo se puede usar dentro de una función async",
    );

    // 2. Await in top-level constant
    rejects(
        "async fn f() -> Int = 1\nconst X = (await f()) + 1\nasync fn main() {}",
        "L0015",
        "await solo se puede usar dentro de una función async",
    );

    // 3. Await on non-future type
    rejects(
        "async fn main() {\n    let v = (await 42) + 1\n    print(v)\n}",
        "L0015",
        "await espera el future",
    );

    // 4. Double await of the same future
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let fut = f()\n    let v = (await fut) + (await fut)\n    print(v)\n}",
        "L0005",
        "después de moverlo",
    );

    // 5. Use after move
    rejects(
        "async fn f() -> Int = 1\nasync fn main() {\n    let fut = f()\n    let a = await fut\n    let b = (await fut) + 1\n    print(a + b)\n}",
        "L0005",
        "después de moverlo",
    );
}
