//! End-to-end timer tests against both schedulers and the native heap trace.
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
};

fn work(name: &str, source: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/timers")
        .join(name);
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("main.l"), source).unwrap();
    dir
}

fn build(dir: &Path, backend: &str, extra: &[&str]) -> PathBuf {
    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(dir)
        .args(["build", "main.l", "--backend", backend])
        .args(extra)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{backend}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let stdout = String::from_utf8(out.stdout).unwrap();
    dir.join(
        stdout
            .lines()
            .find_map(|s| s.strip_prefix("Build: "))
            .unwrap(),
    )
}

fn run(exe: &Path) -> Output {
    Command::new(exe).output().unwrap()
}

struct Stats(String);
impl Stats {
    fn get(&self, name: &str) -> u64 {
        self.0
            .split_whitespace()
            .find_map(|word| word.strip_prefix(&format!("{name}=")))
            .unwrap_or_else(|| panic!("{name}: {}", self.0))
            .parse()
            .unwrap()
    }
}

fn check(name: &str, source: &str, expected: &str) -> Stats {
    let dir = work(name, source);
    let reference = run(&build(&dir, "rustc", &[]));
    let native = run(&build(&dir, "cranelift", &["--trace-alloc"]));
    for out in [&reference, &native] {
        assert_eq!(
            out.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        assert_eq!(out.stdout, expected.as_bytes());
    }
    assert!(reference.stderr.is_empty());
    let stats = Stats(String::from_utf8(native.stderr).unwrap());
    assert_eq!(stats.0.lines().count(), 1, "{}", stats.0);
    assert_eq!(stats.get("heap_ok"), 1, "{}", stats.0);
    assert_eq!(stats.get("allocs"), stats.get("frees"), "{}", stats.0);
    assert_eq!(
        stats.get("timer_registers"),
        stats.get("timer_wakes") + stats.get("timer_cancels"),
        "{}",
        stats.0
    );
    stats
}

#[test]
fn zero_and_unpolled_futures_do_not_register_timers() {
    let s = check(
        "cero",
        r#"fn preparar() -> Future<()> = sleepMs(30000)
async fn main() {
    let inicial = preparar()
    let movido = inicial
    await sleepMs(0)
    print("inmediato")
}"#,
        "inmediato\n",
    );
    for field in ["timer_registers", "timer_wakes", "timer_parks", "suspends"] {
        assert_eq!(s.get(field), 0, "{}", s.0);
    }
}

#[test]
fn deadlines_allow_ready_tasks_to_run_and_finish_out_of_registration_order() {
    let s = check(
        "orden",
        r#"async fn lenta() -> Text {
    print("lenta inicia")
    await sleepMs(120)
    print("lenta termina")
    return "lenta"
}
async fn rapida() -> Int {
    print("rápida inicia")
    await sleepMs(4)
    print("rápida termina")
    return 7
}
async fn lista() {
    print("lista")
}
async fn main() {
    let a = spawn lenta()
    let b = spawn rapida()
    let c = spawn lista()
    let r = await join(a, b)
    await c
    print(r.first)
    print(r.second)
}"#,
        "lenta inicia\nrápida inicia\nlista\nrápida termina\nlenta termina\nlenta\n7\n",
    );
    assert_eq!(s.get("timer_registers"), 2, "{}", s.0);
    assert_eq!(s.get("timer_wakes"), 2, "{}", s.0);
    assert!(s.get("timer_parks") > 0, "{}", s.0);
}

#[test]
fn timers_integrate_with_first_class_futures_expressions_and_groups() {
    let s = check(
        "grupos",
        r#"fn preparar(ms: Int) -> Future<()> = sleepMs(ms)
async fn producir(n: Int) -> List<Text> {
    let texto = "dato {n}"
    let futuro = preparar(3)
    await futuro
    return List[texto]
}
async fn main() {
    var g = taskGroup<List<Text>>()
    for i in 0..10 {
        g.spawn(producir(i))
    }
    let total = (await g.joinAll()).length
    print(total)
    let t = spawn sleepMs(2)
    await t
    await sleepMs(1)
    print("fin")
}"#,
        "10\nfin\n",
    );
    assert_eq!(s.get("timer_registers"), 12, "{}", s.0);
    assert_eq!(s.get("timer_wakes"), 12, "{}", s.0);
}

#[test]
fn pending_timers_are_removed_before_reusing_task_records() {
    let s = check(
        "cancelacion",
        r#"async fn dormida(n: Int) -> Text {
    let texto = "dormida {n}"
    await sleepMs(30000)
    print("no debe reanudarse")
    return texto
}
async fn main() {
    {
        let nunca = spawn dormida(0)
    }
    {
        var g = taskGroup<Text>()
        g.reserve(10000)
        for i in 0..10000 {
            g.spawn(dormida(i))
        }
        await yieldNow()
        print("cancelar")
    }
    let nueva = spawn sleepMs(3)
    await nueva
    print("fin")
}"#,
        "cancelar\nfin\n",
    );
    assert_eq!(s.get("timer_registers"), 10001, "{}", s.0);
    assert_eq!(s.get("timer_cancels"), 10000, "{}", s.0);
    assert_eq!(s.get("timer_wakes"), 1, "{}", s.0);
    assert_eq!(s.get("timer_peak"), 10000, "{}", s.0);
}

#[test]
fn invalid_durations_and_repeated_consumption_are_rejected() {
    for (statement, code, message) in [
        ("await sleepMs(-1)", "L0015", "fuera de rango"),
        ("await sleepMs(922337203685478)", "L0015", "fuera de rango"),
        ("await sleepMs(true)", "L0001", "Int"),
        ("await sleepMs()", "L0015", "duración"),
        ("let f = sleepMs(3)\n await f\n await f", "L0005", "mover"),
    ] {
        let source = format!("async fn main() {{\n {statement}\n}}");
        let err = project_l::check(&source).unwrap_err();
        assert_eq!(err.code, code, "{err:?}");
        assert!(err.message.contains(message), "{err:?}");
        assert!(err.span.line > 0 && err.span.column > 0, "{err:?}");
    }
    project_l::check("async fn main() !{alloc, panic} { await sleepMs(10) }").unwrap();
    let err = project_l::check("@noalloc async fn main() { await sleepMs(10) }").unwrap_err();
    assert_eq!(err.code, "L0010", "{err:?}");
}

#[test]
fn dynamic_invalid_duration_panics_at_the_call_site() {
    let dir = work(
        "duracion_dinamica",
        r#"fn invalida() -> Int = -1
async fn main() {
    let f = sleepMs(invalida())
    await f
}"#,
    );
    for backend in ["rustc", "cranelift"] {
        let out = run(&build(&dir, backend, &[]));
        assert!(!out.status.success(), "{backend}");
        assert!(out.stdout.is_empty(), "{backend}");
        let stderr = String::from_utf8(out.stderr).unwrap();
        assert!(
            stderr.contains("3:13: duración de sleepMs fuera de rango"),
            "{backend}: {stderr}"
        );
    }
}

#[test]
fn stress_ten_thousand_timers() {
    let s = check(
        "estres",
        include_str!("../../../bench/programs/async_timers.l"),
        "10\n100\n1000\n10000\n",
    );
    assert_eq!(s.get("timer_registers"), 11110, "{}", s.0);
    assert_eq!(s.get("timer_wakes"), 11110, "{}", s.0);
}

#[test]
fn expired_timers_are_processed_while_the_ready_queue_stays_nonempty() {
    let s = check(
        "cola_activa",
        r#"async fn girar() {
    for i in 0..30000 {
        await yieldNow()
    }
    print("fin de la cola")
}
async fn main() {
    let t = spawn girar()
    await sleepMs(1)
    print("vence")
    await t
}"#,
        "vence\nfin de la cola\n",
    );
    assert_eq!(s.get("timer_wakes"), 1, "{}", s.0);
    assert_eq!(s.get("timer_parks"), 0, "{}", s.0);
}

#[test]
fn completed_timer_result_can_be_dropped_without_consuming_it() {
    let s = check(
        "lista_sin_consumir",
        r#"async fn hija(n: Int) -> List<Text> {
    await sleepMs(3)
    print("lista")
    return List["texto {n}"]
}
async fn main() {
    {
        let t = spawn hija(7)
        await sleepMs(120)
    }
    print("fin")
}"#,
        "lista\nfin\n",
    );
    assert_eq!(s.get("timer_registers"), 2, "{}", s.0);
    assert_eq!(s.get("timer_wakes"), 2, "{}", s.0);
    assert_eq!(s.get("timer_cancels"), 0, "{}", s.0);
}
