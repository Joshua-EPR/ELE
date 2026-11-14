//! Fuzzer diferencial determinista para NEXO físico.
//!
//! ```text
//! nexo-physical-fuzz [pasos]                 modo clásico (4 semillas fijas)
//! nexo-physical-fuzz --fallos [pasos] [n]    n campañas con fallos del SO
//! ```
//!
//! El modo clásico es el de la versión anterior (mismas semillas y mezcla de
//! operaciones). El modo de fallos añade inyección en cada punto del SO y de
//! la cabecera, reparación, reclaim forzado, política diferida, generaciones
//! cerca del límite, pools pequeños (agotamiento), huecos perdidos,
//! revalidaciones y cierre final. Ante un fallo imprime la semilla, el paso,
//! la secuencia reducida (borrando tramos mientras el fallo persista) y
//! termina con código 1.

use nexo::physical::{
    Command, CommandResult, DifferentialHarness, FaultOp, PoolConfig, ReclaimPolicy,
};
use nexo::rt::pool::GEN_RETIRADO;

const SEEDS: [u64; 4] = [0x4E45_584F, 0xC0FF_EE03, 0x0BAD_5EED, 0xF01D_2026];

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--fallos") {
        let steps = args
            .get(1)
            .map(|v| v.parse().expect("pasos"))
            .unwrap_or(5_000);
        let campaigns: u64 = args
            .get(2)
            .map(|v| v.parse().expect("campañas"))
            .unwrap_or(64);
        let mut total = Totals::default();
        for i in 0..campaigns {
            let seed = 0x5EED_0000_0000u64 ^ i.wrapping_mul(0x9E37_79B9_7F4A_7C15);
            match faults_campaign(seed, steps) {
                Ok(t) => total.add(&t),
                Err((commands, error)) => {
                    let reduced = shrink(seed, &commands, &error);
                    eprintln!(
                        "FALLO semilla {seed:#x}: {error}\nsecuencia reducida ({} de {} comandos):\n{reduced:#?}",
                        reduced.len(),
                        commands.len()
                    );
                    std::process::exit(1);
                }
            }
        }
        println!(
            "nexo-physical-fuzz --fallos: {campaigns} campañas × {steps} pasos sin divergencias; {total:?}"
        );
        return;
    }
    let steps = args
        .first()
        .map(|v| v.parse::<usize>().expect("steps must be an integer"))
        .unwrap_or(10_000);
    for seed in SEEDS {
        classic(seed, steps).unwrap_or_else(|error| panic!("seed {seed:#x}: {error}"));
    }
    println!(
        "nexo-physical-fuzz: {} seeds x {steps} operations passed",
        SEEDS.len()
    );
}

struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0 >> 11
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

/// Modo clásico: misma mezcla que la versión anterior.
fn classic(seed: u64, steps: usize) -> Result<(), String> {
    let mut harness =
        DifferentialHarness::new(PoolConfig::default()).map_err(|e| format!("{e:?}"))?;
    // 0 = vivo, 1 = hueco, 2 = muerto, 3 = liberado.
    let mut states = Vec::<u8>::new();
    let mut random = seed;
    for step in 0..steps {
        random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
        let pick = |s: u8, states: &[u8]| -> Vec<usize> {
            states
                .iter()
                .enumerate()
                .filter_map(|(i, x)| (*x == s).then_some(i))
                .collect()
        };
        let (alive, holes, dead) = (pick(0, &states), pick(1, &states), pick(2, &states));
        match random % 10 {
            0..=2 if states.len() < 4_000 => {
                let result = harness.apply(Command::Allocate { value: step as i64 })?;
                let CommandResult::Allocated { id, .. } = result else {
                    return Err(format!("step {step}: allocation returned {result:?}"));
                };
                if id != states.len() {
                    return Err(format!("step {step}: non-contiguous id {id}"));
                }
                states.push(0);
            }
            3 if !alive.is_empty() => {
                let id = alive[random as usize % alive.len()];
                harness.apply(Command::Write {
                    id,
                    value: (random >> 17) as i64,
                })?;
            }
            4 if !alive.is_empty() => {
                harness.apply(Command::Read {
                    id: alive[random as usize % alive.len()],
                })?;
            }
            5..=6 if !alive.is_empty() => {
                let id = alive[random as usize % alive.len()];
                let hole = random & 0x100 != 0;
                harness.apply(Command::Destroy { id, hole })?;
                states[id] = if hole { 1 } else { 2 };
            }
            7 if !holes.is_empty() => {
                let id = holes[random as usize % holes.len()];
                harness.apply(Command::ReuseHole { id })?;
                states[id] = 0;
            }
            8 if !holes.is_empty() => {
                let id = holes[random as usize % holes.len()];
                harness.apply(Command::ReleaseHole { id })?;
                states[id] = 3;
            }
            9 if !dead.is_empty() => {
                let id = dead[random as usize % dead.len()];
                if harness.apply(Command::ProbeStale { id })? != CommandResult::Rejected {
                    return Err(format!("step {step}: stale probe was accepted"));
                }
            }
            _ if !states.is_empty() => {
                harness.apply(Command::Read {
                    id: random as usize % states.len(),
                })?;
            }
            _ => {
                harness.apply(Command::Allocate { value: 0 })?;
                states.push(0);
            }
        }
    }
    let snapshot = harness.snapshot()?;
    if snapshot.live != states.iter().filter(|s| **s == 0).count() as u64
        || snapshot.holes != states.iter().filter(|s| **s == 1).count() as u64
    {
        return Err(format!("final snapshot mismatch: {snapshot:?}"));
    }
    harness.finish()
}

#[derive(Debug, Default)]
struct Totals {
    commands: u64,
    allocations: u64,
    failed_allocations: u64,
    out_of_space: u64,
    pending_reclaims_seen: u64,
    injections: u64,
    repairs: u64,
}

impl Totals {
    fn add(&mut self, o: &Totals) {
        self.commands += o.commands;
        self.allocations += o.allocations;
        self.failed_allocations += o.failed_allocations;
        self.out_of_space += o.out_of_space;
        self.pending_reclaims_seen += o.pending_reclaims_seen;
        self.injections += o.injections;
        self.repairs += o.repairs;
    }
}

fn config_for(seed: u64) -> PoolConfig {
    let mut r = Lcg(seed ^ 0xC0F1_6000);
    let sizes = [64u32, 128, 1000, 4096];
    PoolConfig {
        fields: 1,
        slot_size: sizes[r.below(4) as usize],
        max_superpages: 1 + r.below(3) as u32,
        initial_generation: if r.below(3) == 0 {
            GEN_RETIRADO - 2 * (1 + r.below(4) as u32)
        } else {
            0
        },
        reclaim: if r.below(2) == 0 {
            ReclaimPolicy::Aggressive
        } else {
            ReclaimPolicy::Deferred {
                keep_empty: r.below(4) as u32,
            }
        },
        protect_before_discard: r.below(2) == 0,
        ..PoolConfig::default()
    }
}

/// Ejecuta una secuencia de comandos. Devuelve totales o el error.
fn execute(seed: u64, commands: &[Command]) -> Result<Totals, String> {
    let mut h = DifferentialHarness::new(config_for(seed)).map_err(|e| format!("{e:?}"))?;
    let mut t = Totals::default();
    for (step, c) in commands.iter().enumerate() {
        let r = h
            .apply(*c)
            .map_err(|e| format!("paso {step} ({c:?}): {e}"))?;
        t.commands += 1;
        match r {
            CommandResult::Allocated { .. } => t.allocations += 1,
            CommandResult::AllocationFailed => t.failed_allocations += 1,
            CommandResult::OutOfSpace => t.out_of_space += 1,
            CommandResult::Destroyed {
                reclaim_pending: true,
            } => t.pending_reclaims_seen += 1,
            CommandResult::Injected => t.injections += 1,
            CommandResult::Repaired { .. } => t.repairs += 1,
            _ => {}
        }
    }
    // Recuperación final: sin fallos pendientes, reparar y cerrar.
    h.clear_faults()?;
    h.apply(Command::Repair)?;
    let snap = h.snapshot()?;
    if snap.pending_reclaims != 0 || snap.dirty_headers != 0 {
        return Err(format!("estado no recuperado tras reparar: {snap:?}"));
    }
    h.finish()?;
    Ok(t)
}

fn generate(seed: u64, steps: usize) -> Vec<Command> {
    let mut r = Lcg(seed);
    let ops = [
        FaultOp::Commit,
        FaultOp::Recommit,
        FaultOp::Protect,
        FaultOp::Decommit,
        FaultOp::HeaderWrite,
        FaultOp::Release,
    ];
    let mut allocated = 0usize;
    let mut out = Vec::with_capacity(steps);
    for _ in 0..steps {
        let id = r.below(allocated.max(1) as u64) as usize;
        let c = match r.below(20) {
            0..=4 => {
                allocated += 1;
                Command::Allocate {
                    value: r.next() as i64,
                }
            }
            5 => Command::Read { id },
            6 => Command::Write {
                id,
                value: r.next() as i64,
            },
            7..=9 => Command::Destroy {
                id,
                hole: r.below(3) == 0,
            },
            10 => Command::ReuseHole { id },
            11 => Command::ReleaseHole { id },
            12 => Command::ProbeStale { id },
            13 => Command::Revalidate { id },
            14 if r.below(8) == 0 => Command::LoseHole { id },
            15 | 16 => Command::Inject {
                op: ops[r.below(ops.len() as u64) as usize],
            },
            17 => Command::Repair,
            18 if r.below(4) == 0 => Command::ReclaimAll,
            _ => Command::Read { id },
        };
        out.push(c);
    }
    out
}

fn faults_campaign(seed: u64, steps: usize) -> Result<Totals, (Vec<Command>, String)> {
    let commands = generate(seed, steps);
    execute(seed, &commands).map_err(|e| (commands, e))
}

/// Reducción: borra tramos de comandos mientras el fallo persista.
fn shrink(seed: u64, commands: &[Command], _error: &str) -> Vec<Command> {
    let mut current = commands.to_vec();
    let mut chunk = current.len() / 2;
    while chunk >= 1 {
        let mut i = 0;
        while i + chunk <= current.len() {
            let mut candidate = current.clone();
            candidate.drain(i..i + chunk);
            if execute(seed, &candidate).is_err() {
                current = candidate;
            } else {
                i += chunk;
            }
        }
        chunk /= 2;
    }
    current
}
