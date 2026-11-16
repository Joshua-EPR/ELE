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

use nexo::next::adapter::{CompactPhysicalPool, CompactPhysicalPool64};
use nexo::next::compact::{
    CompactLink, CompactLink64, CompactPoolAuthority, CompactPoolAuthority64, CompactPoolRegistry,
    CompactPoolRegistry16,
};
use nexo::physical::{DestroyOutcome, Handle, PhysicalPool, PoolConfig, ReclaimPolicy};
use nexo::rt::pool::{Eventos, Pool};
use nexo::stats::{DistributionStats, compute_stats, verify_samuelson_bounds};

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
    let json_flag = std::env::args().any(|a| a == "--json");
    let json_out_path = {
        let args: Vec<String> = std::env::args().collect();
        let mut path = None;
        let mut i = 0;
        while i < args.len() {
            if args[i] == "--json-out" && i + 1 < args.len() {
                path = Some(args[i + 1].clone());
                break;
            }
            i += 1;
        }
        path
    };

    println!(
        "nexo-physical-bench os={} arch={} warmup={} iterations={} profile={}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        WARMUP,
        ITERATIONS,
        if cfg!(debug_assertions) {
            "debug"
        } else {
            "release"
        }
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
    if completo || json_flag || json_out_path.is_some() {
        ampliado(json_flag, json_out_path.as_deref());
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

struct EscenarioResult {
    nombre: &'static str,
    batch_stats: DistributionStats,
    run_stats: DistributionStats,
    run_means: Vec<f64>,
    batch_samples: Vec<f64>,
    total_ops: f64,
    allocs_per_op: f64,
    os_calls_per_op: f64,
    header_bytes_per_op: f64,
    commits_per_op: f64,
    returns_per_op: f64,
    hole_reuses_per_op: f64,
}

fn serialize_json_results(results: &[EscenarioResult], warmup: usize, iterations: usize) -> String {
    let mut out = String::new();
    out.push_str("{\n");
    out.push_str("  \"version\": \"v0.4\",\n");
    out.push_str(&format!("  \"os\": \"{}\",\n", std::env::consts::OS));
    out.push_str(&format!("  \"arch\": \"{}\",\n", std::env::consts::ARCH));
    out.push_str(&format!(
        "  \"profile\": \"{}\",\n",
        if cfg!(debug_assertions) {
            "debug"
        } else {
            "release"
        }
    ));
    out.push_str(&format!("  \"warmup\": {warmup},\n"));
    out.push_str(&format!("  \"iterations\": {iterations},\n"));
    out.push_str(&format!("  \"runs\": {RUNS},\n"));
    out.push_str(&format!("  \"batch_size\": {BATCH},\n"));
    out.push_str("  \"scenarios\": [\n");
    for (i, r) in results.iter().enumerate() {
        out.push_str("    {\n");
        out.push_str(&format!(
            "      \"name\": \"{}\",\n",
            r.nombre.replace('\"', "\\\"")
        ));

        // batch_stats
        out.push_str("      \"batch_stats\": {\n");
        out.push_str(&format!("        \"count\": {},\n", r.batch_stats.count));
        out.push_str(&format!("        \"mean\": {:.4},\n", r.batch_stats.mean));
        out.push_str(&format!(
            "        \"variance_sample\": {:.4},\n",
            r.batch_stats.variance_sample
        ));
        out.push_str(&format!(
            "        \"variance_pop\": {:.4},\n",
            r.batch_stats.variance_pop
        ));
        out.push_str(&format!(
            "        \"stddev_sample\": {:.4},\n",
            r.batch_stats.std_dev_sample
        ));
        out.push_str(&format!(
            "        \"stddev_pop\": {:.4},\n",
            r.batch_stats.std_dev_pop
        ));
        out.push_str(&format!(
            "        \"cv_sample\": {:.4},\n",
            r.batch_stats.cv_sample
        ));
        out.push_str(&format!(
            "        \"cv_pop\": {:.4},\n",
            r.batch_stats.cv_pop
        ));
        out.push_str(&format!("        \"min\": {:.4},\n", r.batch_stats.min));
        out.push_str(&format!("        \"max\": {:.4},\n", r.batch_stats.max));
        out.push_str(&format!(
            "        \"median\": {:.4},\n",
            r.batch_stats.median
        ));
        out.push_str(&format!("        \"p95\": {:.4},\n", r.batch_stats.p95));
        out.push_str(&format!("        \"p99\": {:.4}\n", r.batch_stats.p99));
        out.push_str("      },\n");

        // run_stats
        out.push_str("      \"run_stats\": {\n");
        out.push_str(&format!("        \"count\": {},\n", r.run_stats.count));
        out.push_str(&format!("        \"mean\": {:.4},\n", r.run_stats.mean));
        out.push_str(&format!(
            "        \"variance_sample\": {:.4},\n",
            r.run_stats.variance_sample
        ));
        out.push_str(&format!(
            "        \"variance_pop\": {:.4},\n",
            r.run_stats.variance_pop
        ));
        out.push_str(&format!(
            "        \"stddev_sample\": {:.4},\n",
            r.run_stats.std_dev_sample
        ));
        out.push_str(&format!(
            "        \"stddev_pop\": {:.4},\n",
            r.run_stats.std_dev_pop
        ));
        out.push_str(&format!(
            "        \"cv_sample\": {:.4},\n",
            r.run_stats.cv_sample
        ));
        out.push_str(&format!("        \"cv_pop\": {:.4},\n", r.run_stats.cv_pop));
        out.push_str(&format!("        \"min\": {:.4},\n", r.run_stats.min));
        out.push_str(&format!("        \"max\": {:.4},\n", r.run_stats.max));
        out.push_str(&format!("        \"median\": {:.4},\n", r.run_stats.median));
        out.push_str(&format!("        \"p95\": {:.4},\n", r.run_stats.p95));
        out.push_str(&format!("        \"p99\": {:.4}\n", r.run_stats.p99));
        out.push_str("      },\n");

        // counters
        out.push_str("      \"counters\": {\n");
        out.push_str(&format!("        \"total_ops\": {:.0},\n", r.total_ops));
        out.push_str(&format!(
            "        \"alloc_per_op\": {:.4},\n",
            r.allocs_per_op
        ));
        out.push_str(&format!(
            "        \"os_calls_per_op\": {:.4},\n",
            r.os_calls_per_op
        ));
        out.push_str(&format!(
            "        \"header_bytes_per_op\": {:.4},\n",
            r.header_bytes_per_op
        ));
        out.push_str(&format!(
            "        \"commits_per_op\": {:.4},\n",
            r.commits_per_op
        ));
        out.push_str(&format!(
            "        \"returns_per_op\": {:.4},\n",
            r.returns_per_op
        ));
        out.push_str(&format!(
            "        \"hole_reuses_per_op\": {:.4}\n",
            r.hole_reuses_per_op
        ));
        out.push_str("      },\n");

        // run_means
        out.push_str("      \"run_means\": [");
        for (j, m) in r.run_means.iter().enumerate() {
            if j > 0 {
                out.push_str(", ");
            }
            out.push_str(&format!("{:.4}", m));
        }
        out.push_str("],\n");

        // batch_samples
        out.push_str("      \"batch_samples\": [");
        for (j, s) in r.batch_samples.iter().enumerate() {
            if j > 0 {
                out.push_str(", ");
            }
            out.push_str(&format!("{:.4}", s));
        }
        out.push_str("]\n");

        if i + 1 < results.len() {
            out.push_str("    },\n");
        } else {
            out.push_str("    }\n");
        }
    }
    out.push_str("  ]\n");
    out.push_str("}\n");
    out
}

fn ampliado(json_flag: bool, json_out_path: Option<&str>) {
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
            nombre: "revalidar estándar + leer (PhysicalPool)",
            ops: ITERATIONS,
            run: e_revalidar_estandar,
        },
        Escenario {
            nombre: "revalidar estándar puro (PhysicalPool)",
            ops: ITERATIONS,
            run: e_revalidar_estandar_puro,
        },
        Escenario {
            nombre: "revalidar compacto 32b (CompactPhysicalPool)",
            ops: ITERATIONS,
            run: e_revalidar_compacto_32,
        },
        Escenario {
            nombre: "revalidar compacto 64b (CompactPhysicalPool64)",
            ops: ITERATIONS,
            run: e_revalidar_compacto_64,
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

    println!(
        "\n== ampliado: {RUNS} corridas × lotes de {BATCH} ops; ns/op (estadísticas desagregadas: lote vs corrida)"
    );
    println!(
        "{:<44} {:>10} {:>12} {:>9} {:>9} {:>9} {:>9} {:>12} {:>10} {:>11} {:>8} {:>8} {:>8} {:>9} {:>8} {:>9}",
        "escenario",
        "batch_mean",
        "batch_median",
        "batch_min",
        "batch_max",
        "batch_p95",
        "batch_p99",
        "batch_stddev",
        "run_stddev",
        "batch_count",
        "alloc/op",
        "so/op",
        "cab B/op",
        "commit/op",
        "devol/op",
        "huecos/op"
    );

    let mut results = Vec::new();

    for e in &escenarios {
        let mut medias = Vec::new();
        let mut todas = Muestras::default();
        let mut total_c = Contadores::default();
        let mut allocs = 0u64;
        black_box((e.run)(e.ops / 10, &mut Muestras::default()));
        for _ in 0..RUNS {
            let mut m = Muestras::default();
            let a0 = ALLOCS.load(Ordering::Relaxed);
            let c = (e.run)(e.ops, &mut m);
            allocs += ALLOCS.load(Ordering::Relaxed) - a0;
            total_c.os_calls += c.os_calls;
            total_c.header_bytes += c.header_bytes;
            total_c.commits += c.commits;
            total_c.returns += c.returns;
            total_c.hole_reuses += c.hole_reuses;
            medias.push(m.lotes.iter().sum::<f64>() / m.lotes.len() as f64);
            todas.lotes.extend(m.lotes);
        }

        let batch_stats = compute_stats(&todas.lotes).expect("Valores de lote válidos");
        let run_stats = compute_stats(&medias).expect("Valores de corrida válidos");
        verify_samuelson_bounds(&batch_stats).expect("Cota de Samuelson en lotes");
        verify_samuelson_bounds(&run_stats).expect("Cota de Samuelson en corridas");

        let total_ops = RUNS as f64 * e.ops as f64;
        let allocs_per_op = allocs as f64 / total_ops;
        let os_calls_per_op = total_c.os_calls as f64 / total_ops;
        let header_bytes_per_op = total_c.header_bytes as f64 / total_ops;
        let commits_per_op = total_c.commits as f64 / total_ops;
        let returns_per_op = total_c.returns as f64 / total_ops;
        let hole_reuses_per_op = total_c.hole_reuses as f64 / total_ops;

        println!(
            "{:<44} {:>10.1} {:>12.1} {:>9.1} {:>9.1} {:>9.1} {:>9.1} {:>12.2} {:>10.2} {:>11} {:>8.3} {:>8.3} {:>8.1} {:>9.3} {:>8.3} {:>9.3}",
            e.nombre,
            batch_stats.mean,
            batch_stats.median,
            batch_stats.min,
            batch_stats.max,
            batch_stats.p95,
            batch_stats.p99,
            batch_stats.std_dev_sample,
            run_stats.std_dev_sample,
            batch_stats.count,
            allocs_per_op,
            os_calls_per_op,
            header_bytes_per_op,
            commits_per_op,
            returns_per_op,
            hole_reuses_per_op,
        );

        results.push(EscenarioResult {
            nombre: e.nombre,
            batch_stats,
            run_stats,
            run_means: medias,
            batch_samples: todas.lotes,
            total_ops,
            allocs_per_op,
            os_calls_per_op,
            header_bytes_per_op,
            commits_per_op,
            returns_per_op,
            hole_reuses_per_op,
        });
    }

    println!(
        "(alloc/op incluye la preparación de cada escenario —vectores de handles, pools— repartida entre sus ops)"
    );
    memoria();

    if json_flag || json_out_path.is_some() {
        let json_content = serialize_json_results(&results, WARMUP, ITERATIONS);
        if json_flag {
            println!("\n== json output ==");
            println!("{json_content}");
        }
        if let Some(path) = json_out_path {
            if let Some(parent) = std::path::Path::new(path).parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            match std::fs::write(path, &json_content) {
                Ok(_) => println!("JSON escrito exitosamente en: {path}"),
                Err(e) => eprintln!("Error al escribir JSON en {path}: {e}"),
            }
        }
    }
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

fn e_revalidar_estandar(ops: usize, m: &mut Muestras) -> Contadores {
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

fn e_revalidar_estandar_puro(ops: usize, m: &mut Muestras) -> Contadores {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let h = pool.allocate().unwrap();
    let link = h.link();
    let b = base(&pool);
    m.medir(ops, || {
        black_box(pool.revalidate(black_box(link)).unwrap());
    });
    let c = contadores(&pool, b);
    pool.destroy(h, false).unwrap();
    c
}

fn e_revalidar_compacto_32(ops: usize, m: &mut Muestras) -> Contadores {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    let h = pool.allocate().unwrap();
    let link = CompactLink::new(token.id(), h.slot(), h.generation() as u16).unwrap();
    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let b = base(&pool);
    m.medir(ops, || {
        black_box(adapter.revalidate_compact(black_box(link)).unwrap());
    });
    let c = contadores(&pool, b);
    pool.destroy(h, false).unwrap();
    c
}

fn e_revalidar_compacto_64(ops: usize, m: &mut Muestras) -> Contadores {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let token = CompactPoolRegistry16::register_pool(&pool).unwrap();
    let h = pool.allocate().unwrap();
    let link = CompactLink64::new(token.id(), h.slot(), h.generation() as u16).unwrap();
    let adapter = CompactPhysicalPool64::new(&pool, &token).unwrap();
    let b = base(&pool);
    m.medir(ops, || {
        black_box(adapter.revalidate_compact_64(black_box(link)).unwrap());
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
