//! Fuzzer diferencial determinista y acotado para NEXO físico.

use nexo::physical::{Command, CommandResult, DifferentialHarness, PoolConfig};

fn main() {
    let steps = std::env::args()
        .nth(1)
        .map(|value| value.parse::<usize>().expect("steps must be an integer"))
        .unwrap_or(10_000);
    let seeds = [0x4E45_584Fu64, 0xC0FF_EE03, 0x0BAD_5EED, 0xF01D_2026];
    for seed in seeds {
        run(seed, steps).unwrap_or_else(|error| panic!("seed {seed:#x}: {error}"));
    }
    println!(
        "nexo-physical-fuzz: {} seeds x {steps} operations passed",
        seeds.len()
    );
}

fn run(seed: u64, steps: usize) -> Result<(), String> {
    let mut harness = DifferentialHarness::new(PoolConfig {
        fields: 1,
        slot_size: 64,
        max_superpages: 8,
        ..PoolConfig::default()
    })
    .map_err(|error| format!("constructor: {error:?}"))?;
    // 0 = vivo, 1 = hueco, 2 = muerto, 3 = liberado.
    let mut states = Vec::<u8>::new();
    let mut random = seed;
    for step in 0..steps {
        random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
        let alive: Vec<_> = states
            .iter()
            .enumerate()
            .filter_map(|(id, state)| (*state == 0).then_some(id))
            .collect();
        let holes: Vec<_> = states
            .iter()
            .enumerate()
            .filter_map(|(id, state)| (*state == 1).then_some(id))
            .collect();
        let dead: Vec<_> = states
            .iter()
            .enumerate()
            .filter_map(|(id, state)| (*state == 2).then_some(id))
            .collect();
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
                let id = alive[random as usize % alive.len()];
                harness.apply(Command::Read { id })?;
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
                let id = random as usize % states.len();
                let _ = harness.apply(Command::Read { id })?;
            }
            _ => {
                let result = harness.apply(Command::Allocate { value: 0 })?;
                let CommandResult::Allocated { .. } = result else {
                    return Err("initial allocation failed".into());
                };
                states.push(0);
            }
        }
    }
    let snapshot = harness.snapshot()?;
    if snapshot.live != states.iter().filter(|state| **state == 0).count() as u64
        || snapshot.holes != states.iter().filter(|state| **state == 1).count() as u64
    {
        return Err(format!("final snapshot mismatch: {snapshot:?}"));
    }
    Ok(())
}
