//! Microbenchmarks reproducibles sin dependencias externas.
//!
//! ```text
//! nexo-physical-bench            escenarios originales (formato de v0.3)
//! nexo-physical-bench --completo escenarios originales + ampliados con
//!                                estadísticas, llamadas al SO y memoria
//! ```
//!
//! Los cinco escenarios originales se conservan sin cambios de carga (solo
//! adaptados a la API lineal) para comparar con las cifras anteriores.

use std::alloc::{GlobalAlloc, Layout, System};
use std::hint::black_box;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use nexo::physical::{DestroyOutcome, Handle, PhysicalPool, PoolConfig, ReclaimPolicy};
use nexo::rt::pool::{Eventos, Pool};

const WARMUP: usize = 2_000;
const ITERATIONS: usize = 20_000;

/// Allocator global que cuenta llamadas (asignaciones auxiliares por op).
struct Contador;

static ALLOCS: AtomicU64 = AtomicU64::new(0);

// SAFETY: delega en `System` sin cambiar layouts ni punteros; solo cuenta.
unsafe impl GlobalAlloc for Contador {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCS.fetch_add(1, Ordering::Relaxed);
        // SAFETY: mismo contrato que `GlobalAlloc::alloc`.
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: `ptr` procede de `System.alloc` con este `layout`.
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        ALLOCS.fetch_add(1, Ordering::Relaxed);
        // SAFETY: mismo contrato que `GlobalAlloc::realloc`.
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Contador = Contador;

fn main() {
    let completo = std::env::args().any(|a| a == "--completo");
    println!(
        "nexo-physical-bench os={} arch={} warmup={} iterations={}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        WARMUP,
        ITERATIONS
    );
    // Escenarios originales (mismo formato de salida que v0.3).
    bench("physical hot allocate+free", physical_hot);
    bench("physical hole destroy+reuse", physical_hole);
    bench("physical commit+reclaim", physical_reclaim);
    bench("abstract allocate+free", abstract_hot);
    bench("Rust global Box<[u8;64]>", global_box);

    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let handle = pool.allocate().unwrap();
    println!(
        "memory reserved={} committed={} useful={} external_metadata_lower_bound={} header_used=4095",
        pool.address_metrics().unwrap().reserved_bytes,
        pool.address_metrics().unwrap().committed_bytes,
        64,
        std::mem::size_of_val(&pool),
    );
    pool.destroy(handle, false).unwrap();
    if completo {
        ampliado();
    }
}

fn bench(name: &str, run: fn(usize) -> Duration) {
    black_box(run(WARMUP));
    let elapsed = run(ITERATIONS);
    println!(
        "{name}: total_ns={} ns_per_op={:.2}",
        elapsed.as_nanos(),
        elapsed.as_nanos() as f64 / ITERATIONS as f64
    );
}

fn physical_hot(iterations: usize) -> Duration {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let anchor = pool.allocate().unwrap();
    let start = Instant::now();
    for _ in 0..iterations {
        let handle = black_box(pool.allocate().unwrap());
        black_box(pool.destroy(handle, false).unwrap());
    }
    let elapsed = start.elapsed();
    pool.destroy(anchor, false).unwrap();
    elapsed
}

fn physical_hole(iterations: usize) -> Duration {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let mut handle = pool.allocate().unwrap();
    let start = Instant::now();
    for _ in 0..iterations {
        let DestroyOutcome::Hole(hole) = pool.destroy(handle, true).unwrap().outcome else {
            unreachable!()
        };
        handle = black_box(pool.reuse_hole(hole).unwrap());
    }
    let elapsed = start.elapsed();
    pool.destroy(handle, false).unwrap();
    elapsed
}

fn physical_reclaim(iterations: usize) -> Duration {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let start = Instant::now();
    for _ in 0..iterations {
        let handle = black_box(pool.allocate().unwrap());
        black_box(pool.destroy(handle, false).unwrap());
    }
    start.elapsed()
}

fn abstract_hot(iterations: usize) -> Duration {
    let mut pool = Pool::nuevo(0, 1, 64, 8, 0).unwrap();
    let mut events = Eventos::default();
    let anchor = pool.asignar(0, &mut events).unwrap();
    let start = Instant::now();
    for _ in 0..iterations {
        let handle = black_box(pool.asignar(0, &mut events).unwrap());
        black_box(
            pool.destruir(handle.0, handle.1, false, &mut events)
                .unwrap(),
        );
    }
    let elapsed = start.elapsed();
    pool.destruir(anchor.0, anchor.1, false, &mut events)
        .unwrap();
    elapsed
}

fn global_box(iterations: usize) -> Duration {
    let start = Instant::now();
    for _ in 0..iterations {
        let allocation = black_box(Box::new([0u8; 64]));
        black_box(allocation);
    }
    start.elapsed()
}

// ------------------------------------------------------------- ampliado

const RUNS: usize = 7;
const BATCH: usize = 200;

struct Escenario {
    nombre: &'static str,
    ops: usize,
    run: fn(usize, &mut Muestras) -> Contadores,
}

#[derive(Default, Clone, Copy)]
struct Contadores {
    os_calls: u64,
    header_bytes: u64,
    commits: u64,
    returns: u64,
    hole_reuses: u64,
}

#[derive(Default)]
struct Muestras {
    /// ns/op por lote.
    lotes: Vec<f64>,
}

impl Muestras {
    fn medir(&mut self, ops: usize, mut f: impl FnMut()) {
        let mut hechas = 0;
        while hechas < ops {
            let n = BATCH.min(ops - hechas);
            let t = Instant::now();
            for _ in 0..n {
                f();
            }
            self.lotes.push(t.elapsed().as_nanos() as f64 / n as f64);
            hechas += n;
        }
    }
}

fn percentil(v: &mut [f64], p: f64) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let i = ((v.len() as f64 - 1.0) * p).round() as usize;
    v[i]
}

fn ampliado() {
    let escenarios = [
        Escenario {
            nombre: "hot allocate+free (pool con ancla)",
            ops: ITERATIONS,
            run: e_hot,
        },
        Escenario {
            nombre: "hole destroy+reuse",
            ops: ITERATIONS,
            run: e_hole,
        },
        Escenario {
            nombre: "commit+reclaim agresivo",
            ops: ITERATIONS,
            run: e_reclaim_agresivo,
        },
        Escenario {
            nombre: "commit+reclaim agresivo, protección previa",
            ops: ITERATIONS,
            run: e_reclaim_dos_pasos,
        },
        Escenario {
            nombre: "commit+reclaim diferido keep=1",
            ops: ITERATIONS,
            run: e_reclaim_diferido,
        },
        Escenario {
            nombre: "ráfaga 960 asignar + 960 liberar (por op)",
            ops: 960 * 10,
            run: e_rafaga,
        },
        Escenario {
            nombre: "larga duración: 900 vivos + churn",
            ops: ITERATIONS,
            run: e_larga,
        },
        Escenario {
            nombre: "fragmentado: 450 subpáginas a medias",
            ops: ITERATIONS,
            run: e_fragmentado,
        },
        Escenario {
            nombre: "pool pequeño (1 superpágina)",
            ops: ITERATIONS,
            run: e_pequeno,
        },
        Escenario {
            nombre: "pool grande (64 superpáginas, 50.000 vivos)",
            ops: ITERATIONS,
            run: e_grande,
        },
        Escenario {
            nombre: "revalidar enlace + leer",
            ops: ITERATIONS,
            run: e_revalidar,
        },
        Escenario {
            nombre: "Box<[u8;64]> asignar+liberar",
            ops: ITERATIONS,
            run: e_box,
        },
        Escenario {
            nombre: "Box ráfaga 960+960 (por op)",
            ops: 960 * 10,
            run: e_box_rafaga,
        },
    ];
    println!("\n== ampliado: {RUNS} corridas × lotes de {BATCH} ops; ns/op");
    println!(
        "{:<46} {:>9} {:>9} {:>9} {:>9} {:>7} {:>8} {:>8} {:>8} {:>8} {:>8} {:>9}",
        "escenario",
        "media",
        "mediana",
        "p95",
        "p99",
        "cv%",
        "alloc/op",
        "so/op",
        "cab B/op",
        "commit/op",
        "devol/op",
        "huecos/op"
    );
    for e in &escenarios {
        let mut medias = Vec::new();
        let mut todas = Muestras::default();
        let mut c = Contadores::default();
        let mut allocs = 0u64;
        black_box((e.run)(e.ops / 10, &mut Muestras::default()));
        for _ in 0..RUNS {
            let mut m = Muestras::default();
            let a0 = ALLOCS.load(Ordering::Relaxed);
            c = (e.run)(e.ops, &mut m);
            allocs += ALLOCS.load(Ordering::Relaxed) - a0;
            medias.push(m.lotes.iter().sum::<f64>() / m.lotes.len() as f64);
            todas.lotes.extend(m.lotes);
        }
        let media = medias.iter().sum::<f64>() / RUNS as f64;
        let sd = (medias.iter().map(|x| (x - media).powi(2)).sum::<f64>() / RUNS as f64).sqrt();
        let ops = e.ops as f64;
        println!(
            "{:<46} {:>9.1} {:>9.1} {:>9.1} {:>9.1} {:>7.1} {:>8.3} {:>8.3} {:>8.1} {:>8.3} {:>8.3} {:>9.3}",
            e.nombre,
            media,
            percentil(&mut todas.lotes, 0.5),
            percentil(&mut todas.lotes, 0.95),
            percentil(&mut todas.lotes, 0.99),
            100.0 * sd / media,
            allocs as f64 / (RUNS as f64 * ops),
            c.os_calls as f64 / ops,
            c.header_bytes as f64 / ops,
            c.commits as f64 / ops,
            c.returns as f64 / ops,
            c.hole_reuses as f64 / ops,
        );
    }
    println!(
        "(alloc/op incluye la preparación de cada escenario —vectores de handles, pools— repartida entre sus ops)"
    );
    memoria();
}

type Base = (u64, u64, u64, u64, u64);

fn base(pool: &PhysicalPool) -> Base {
    let m = pool.metrics();
    (
        pool.address_metrics().unwrap().os_calls.total(),
        m.header_bytes_written,
        m.data_committed + m.data_recommitted,
        m.data_returned,
        m.hole_reuses,
    )
}

fn contadores(pool: &PhysicalPool, antes: Base) -> Contadores {
    let ahora = base(pool);
    Contadores {
        os_calls: ahora.0 - antes.0,
        header_bytes: ahora.1 - antes.1,
        commits: ahora.2 - antes.2,
        returns: ahora.3 - antes.3,
        hole_reuses: ahora.4 - antes.4,
    }
}

/// Asignar+liberar con un pool ya preparado (sus objetos se liberan al final).
fn churn(mut pool: PhysicalPool, fijos: Vec<Handle>, ops: usize, m: &mut Muestras) -> Contadores {
    let b = base(&pool);
    m.medir(ops, || {
        let h = black_box(pool.allocate().unwrap());
        black_box(pool.destroy(h, false).unwrap());
    });
    let c = contadores(&pool, b);
    for h in fijos {
        pool.destroy(h, false).unwrap();
    }
    c
}

fn con_ancla(config: PoolConfig, ops: usize, m: &mut Muestras) -> Contadores {
    let mut pool = PhysicalPool::new(config).unwrap();
    let a = pool.allocate().unwrap();
    churn(pool, vec![a], ops, m)
}

fn sin_ancla(config: PoolConfig, ops: usize, m: &mut Muestras) -> Contadores {
    churn(PhysicalPool::new(config).unwrap(), Vec::new(), ops, m)
}

fn e_hot(ops: usize, m: &mut Muestras) -> Contadores {
    con_ancla(PoolConfig::default(), ops, m)
}

fn e_reclaim_agresivo(ops: usize, m: &mut Muestras) -> Contadores {
    sin_ancla(PoolConfig::default(), ops, m)
}

fn e_reclaim_dos_pasos(ops: usize, m: &mut Muestras) -> Contadores {
    sin_ancla(
        PoolConfig {
            protect_before_discard: true,
            ..PoolConfig::default()
        },
        ops,
        m,
    )
}

fn e_reclaim_diferido(ops: usize, m: &mut Muestras) -> Contadores {
    sin_ancla(
        PoolConfig {
            reclaim: ReclaimPolicy::Deferred { keep_empty: 1 },
            ..PoolConfig::default()
        },
        ops,
        m,
    )
}

fn e_hole(ops: usize, m: &mut Muestras) -> Contadores {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let mut slot = Some(pool.allocate().unwrap());
    let b = base(&pool);
    m.medir(ops, || {
        let h = slot.take().unwrap();
        let DestroyOutcome::Hole(t) = pool.destroy(h, true).unwrap().outcome else {
            unreachable!()
        };
        slot = Some(black_box(pool.reuse_hole(t).unwrap()));
    });
    let c = contadores(&pool, b);
    pool.destroy(slot.take().unwrap(), false).unwrap();
    c
}

fn e_rafaga(ops: usize, m: &mut Muestras) -> Contadores {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let b = base(&pool);
    let mut vivos: Vec<Handle> = Vec::with_capacity(960);
    // Una op = una asignación o una liberación; la ráfaga alterna 960 + 960.
    let mut fase_alloc = true;
    m.medir(ops, || {
        if fase_alloc {
            vivos.push(pool.allocate().unwrap());
            fase_alloc = vivos.len() < 960;
        } else {
            pool.destroy(vivos.pop().unwrap(), false).unwrap();
            fase_alloc = vivos.is_empty();
        }
    });
    let c = contadores(&pool, b);
    for h in vivos {
        pool.destroy(h, false).unwrap();
    }
    c
}

fn e_larga(ops: usize, m: &mut Muestras) -> Contadores {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let largos: Vec<Handle> = (0..900).map(|_| pool.allocate().unwrap()).collect();
    churn(pool, largos, ops, m)
}

fn e_fragmentado(ops: usize, m: &mut Muestras) -> Contadores {
    // 32 superpáginas; se llenan 30 (450 subpáginas) y se destruye un objeto
    // de cada dos: 450 subpáginas a medias en el índice de densidad.
    let mut pool = PhysicalPool::new(PoolConfig {
        max_superpages: 32,
        ..PoolConfig::default()
    })
    .unwrap();
    let todos: Vec<Handle> = (0..30 * 960).map(|_| pool.allocate().unwrap()).collect();
    let mut quedan = Vec::with_capacity(todos.len() / 2);
    for (i, h) in todos.into_iter().enumerate() {
        if i % 2 == 0 {
            pool.destroy(h, false).unwrap();
        } else {
            quedan.push(h);
        }
    }
    churn(pool, quedan, ops, m)
}

fn e_pequeno(ops: usize, m: &mut Muestras) -> Contadores {
    con_ancla(
        PoolConfig {
            max_superpages: 1,
            ..PoolConfig::default()
        },
        ops,
        m,
    )
}

fn e_grande(ops: usize, m: &mut Muestras) -> Contadores {
    let mut pool = PhysicalPool::new(PoolConfig {
        max_superpages: 64,
        ..PoolConfig::default()
    })
    .unwrap();
    let vivos: Vec<Handle> = (0..50_000).map(|_| pool.allocate().unwrap()).collect();
    churn(pool, vivos, ops, m)
}

fn e_revalidar(ops: usize, m: &mut Muestras) -> Contadores {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let h = pool.allocate().unwrap();
    let link = h.link();
    let b = base(&pool);
    m.medir(ops, || {
        let obj = black_box(pool.revalidate(black_box(link)).unwrap());
        black_box(pool.read_int(obj, 0).unwrap());
    });
    let c = contadores(&pool, b);
    pool.destroy(h, false).unwrap();
    c
}

fn e_box(ops: usize, m: &mut Muestras) -> Contadores {
    m.medir(ops, || {
        black_box(Box::new([0u8; 64]));
    });
    Contadores::default()
}

fn e_box_rafaga(ops: usize, m: &mut Muestras) -> Contadores {
    let mut vivos: Vec<Box<[u8; 64]>> = Vec::with_capacity(960);
    let mut fase_alloc = true;
    m.medir(ops, || {
        if fase_alloc {
            vivos.push(Box::new([0u8; 64]));
            fase_alloc = vivos.len() < 960;
        } else {
            black_box(vivos.pop());
            fase_alloc = vivos.is_empty();
        }
    });
    Contadores::default()
}

// ------------------------------------------------------------- memoria

/// Memoria del proceso: (working set / RSS, memoria privada comprometida /
/// RSS anónima), en bytes.
fn memoria_proceso() -> Option<(u64, u64)> {
    #[cfg(target_os = "windows")]
    {
        #[repr(C)]
        #[derive(Default)]
        #[allow(non_snake_case)]
        struct Counters {
            cb: u32,
            PageFaultCount: u32,
            PeakWorkingSetSize: usize,
            WorkingSetSize: usize,
            QuotaPeakPagedPoolUsage: usize,
            QuotaPagedPoolUsage: usize,
            QuotaPeakNonPagedPoolUsage: usize,
            QuotaNonPagedPoolUsage: usize,
            PagefileUsage: usize,
            PeakPagefileUsage: usize,
        }
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn GetCurrentProcess() -> *mut core::ffi::c_void;
            fn K32GetProcessMemoryInfo(p: *mut core::ffi::c_void, c: *mut Counters, cb: u32)
            -> i32;
        }
        let mut c = Counters {
            cb: std::mem::size_of::<Counters>() as u32,
            ..Counters::default()
        };
        // SAFETY: `c` es una PROCESS_MEMORY_COUNTERS válida con `cb` correcto;
        // GetCurrentProcess devuelve un pseudo-handle siempre válido.
        let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut c, c.cb) };
        (ok != 0).then_some((c.WorkingSetSize as u64, c.PagefileUsage as u64))
    }
    #[cfg(target_os = "linux")]
    {
        let st = std::fs::read_to_string("/proc/self/status").ok()?;
        let campo = |n: &str| {
            st.lines()
                .find(|l| l.starts_with(n))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse::<u64>().ok())
                .map(|kb| kb * 1024)
        };
        Some((campo("VmRSS:")?, campo("RssAnon:")?))
    }
    #[cfg(not(any(target_os = "windows", target_os = "linux")))]
    {
        None
    }
}

fn memoria() {
    let mb = |x: u64| x as f64 / (1024.0 * 1024.0);
    let delta = |a: u64, b: u64| (b as f64 - a as f64) / (1024.0 * 1024.0);
    println!(
        "\n== memoria: pool de 64 superpáginas ({:.1} MiB reservados, NO consumo de RAM); 50.000 objetos de 64 B = {:.2} MiB útiles",
        mb(64 * 64 * 1024),
        mb(50_000 * 64)
    );
    println!(
        "{:<44} {:>11} {:>11} {:>12} {:>13}",
        "estado", "comprom.", "accesible", "Δ WS/RSS", "Δ privada/anón"
    );
    for (nombre, politica) in [
        ("agresivo", ReclaimPolicy::Aggressive),
        ("diferido keep=8", ReclaimPolicy::Deferred { keep_empty: 8 }),
    ] {
        let inicio = memoria_proceso();
        let mut pool = PhysicalPool::new(PoolConfig {
            max_superpages: 64,
            reclaim: politica,
            ..PoolConfig::default()
        })
        .unwrap();
        let fila = |etiqueta: &str, pool: &PhysicalPool| {
            let a = pool.address_metrics().unwrap();
            let (ws, privada) = match (inicio, memoria_proceso()) {
                (Some(i), Some(p)) => (
                    format!("{:+.2} MiB", delta(i.0, p.0)),
                    format!("{:+.2} MiB", delta(i.1, p.1)),
                ),
                _ => ("n/d".into(), "n/d".into()),
            };
            println!(
                "{:<44} {:>8.2} Mi {:>8.2} Mi {:>12} {:>13}",
                format!("{nombre}: {etiqueta}"),
                mb(a.committed_bytes as u64),
                mb(a.accessible_bytes as u64),
                ws,
                privada
            );
        };
        // El vector de handles (≈ 0,8 MiB) también cuenta en el proceso.
        let mut vivos: Vec<Handle> = Vec::with_capacity(50_000);
        for _ in 0..50_000 {
            let h = pool.allocate().unwrap();
            pool.write_int(h.obj(), 0, 1).unwrap();
            vivos.push(h);
        }
        fila("50.000 vivos", &pool);
        let mut mitad = Vec::with_capacity(25_000);
        for (i, h) in vivos.into_iter().enumerate() {
            if i % 2 == 0 {
                pool.destroy(h, false).unwrap();
            } else {
                mitad.push(h);
            }
        }
        fila("25.000 vivos intercalados", &pool);
        for h in mitad {
            pool.destroy(h, false).unwrap();
        }
        fila("0 vivos", &pool);
        pool.reclaim_all().unwrap();
        fila("0 vivos tras reclaim_all", &pool);
        pool.close().unwrap();
    }
    let pool = PhysicalPool::new(PoolConfig {
        max_superpages: 64,
        ..PoolConfig::default()
    })
    .unwrap();
    println!(
        "PhysicalPool: {} B inmediatos (cota inferior: los vectores de páginas, superpáginas e índice van aparte)",
        std::mem::size_of_val(&pool)
    );
}
