//! Microbenchmark reproducible sin dependencias externas.

use std::hint::black_box;
use std::time::{Duration, Instant};

use nexo::physical::{DestroyOutcome, PhysicalPool, PoolConfig};
use nexo::rt::pool::{Eventos, Pool};

const WARMUP: usize = 2_000;
const ITERATIONS: usize = 20_000;

fn main() {
    println!(
        "nexo-physical-bench os={} arch={} warmup={} iterations={}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        WARMUP,
        ITERATIONS
    );
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
        let DestroyOutcome::Hole(hole) = pool.destroy(handle, true).unwrap() else {
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
