//! Ejecución diferencial acotada entre el modelo v0.2 y el pool físico.

use super::{DestroyOutcome, Handle, HoleToken, PhysicalPool, PoolConfig, PoolError};
use crate::rt::pool::{Eventos, Palabra, Pool};

#[derive(Clone, Copy, Debug)]
pub enum Command {
    Allocate { value: i64 },
    Read { id: usize },
    Write { id: usize, value: i64 },
    Destroy { id: usize, hole: bool },
    ReuseHole { id: usize },
    ReleaseHole { id: usize },
    ProbeStale { id: usize },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandResult {
    Allocated {
        id: usize,
        slot: u32,
        generation: u32,
    },
    Value(i64),
    Destroyed,
    Reused {
        slot: u32,
        generation: u32,
    },
    Released,
    Rejected,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DifferentialSnapshot {
    pub live: u64,
    pub holes: u64,
    pub abstract_confirmed: usize,
    pub physical_committed_bytes: usize,
}

enum Entry {
    Vacant,
    Alive {
        abstract_handle: (u32, u32),
        physical_handle: Handle,
    },
    Hole {
        slot: u32,
        generation: u32,
        physical: HoleToken,
    },
    Dead {
        abstract_handle: (u32, u32),
        physical_handle: Handle,
    },
}

pub struct DifferentialHarness {
    abstract_pool: Pool,
    physical_pool: PhysicalPool,
    events: Eventos,
    entries: Vec<Entry>,
}

impl DifferentialHarness {
    pub fn new(config: PoolConfig) -> Result<Self, PoolError> {
        let abstract_pool = Pool::nuevo(
            0,
            config.fields,
            config.slot_size,
            config.max_superpages,
            config.initial_generation,
        )
        .map_err(|_| PoolError::InvalidConfig("abstract pool rejected configuration"))?;
        Ok(Self {
            abstract_pool,
            physical_pool: PhysicalPool::new(config)?,
            events: Eventos::default(),
            entries: Vec::new(),
        })
    }

    pub fn apply(&mut self, command: Command) -> Result<CommandResult, String> {
        let result = match command {
            Command::Allocate { value } => {
                let abstract_handle = self
                    .abstract_pool
                    .asignar(0, &mut self.events)
                    .map_err(text)?;
                let physical_handle = self.physical_pool.allocate().map_err(debug)?;
                same_identity(abstract_handle, physical_handle)?;
                self.abstract_pool
                    .escribir(abstract_handle.0, abstract_handle.1, 0, Palabra::Int(value))
                    .map_err(text)?;
                self.physical_pool
                    .write_int(physical_handle, 0, value)
                    .map_err(debug)?;
                let id = self.entries.len();
                self.entries.push(Entry::Alive {
                    abstract_handle,
                    physical_handle,
                });
                CommandResult::Allocated {
                    id,
                    slot: abstract_handle.0,
                    generation: abstract_handle.1,
                }
            }
            Command::Read { id } => {
                let Entry::Alive {
                    abstract_handle,
                    physical_handle,
                } = *self
                    .entries
                    .get(id)
                    .ok_or_else(|| "read id out of range".to_string())?
                else {
                    return Ok(CommandResult::Rejected);
                };
                let abstract_value = self
                    .abstract_pool
                    .leer(abstract_handle.0, abstract_handle.1, 0)
                    .map_err(text)?;
                let physical_value = self
                    .physical_pool
                    .read_int(physical_handle, 0)
                    .map_err(debug)?;
                if abstract_value != Palabra::Int(physical_value) {
                    return Err(format!(
                        "data mismatch: {abstract_value:?} != {physical_value}"
                    ));
                }
                CommandResult::Value(physical_value)
            }
            Command::Write { id, value } => {
                let Entry::Alive {
                    abstract_handle,
                    physical_handle,
                } = *self
                    .entries
                    .get(id)
                    .ok_or_else(|| "write id out of range".to_string())?
                else {
                    return Ok(CommandResult::Rejected);
                };
                self.abstract_pool
                    .escribir(abstract_handle.0, abstract_handle.1, 0, Palabra::Int(value))
                    .map_err(text)?;
                self.physical_pool
                    .write_int(physical_handle, 0, value)
                    .map_err(debug)?;
                CommandResult::Value(value)
            }
            Command::Destroy { id, hole } => {
                let entry = self
                    .entries
                    .get_mut(id)
                    .ok_or_else(|| "destroy id out of range".to_string())?;
                let Entry::Alive {
                    abstract_handle,
                    physical_handle,
                } = *entry
                else {
                    return Ok(CommandResult::Rejected);
                };
                let abstract_outcome = self
                    .abstract_pool
                    .destruir(abstract_handle.0, abstract_handle.1, hole, &mut self.events)
                    .map_err(text)?;
                let physical_outcome = self
                    .physical_pool
                    .destroy(physical_handle, hole)
                    .map_err(debug)?;
                match (hole, abstract_outcome, physical_outcome) {
                    (true, crate::rt::pool::Destruido::Libre, DestroyOutcome::Hole(token)) => {
                        *entry = Entry::Hole {
                            slot: abstract_handle.0,
                            generation: abstract_handle.1 + 1,
                            physical: token,
                        };
                    }
                    (false, crate::rt::pool::Destruido::Libre, DestroyOutcome::Free)
                    | (_, crate::rt::pool::Destruido::Retirado, DestroyOutcome::Retired) => {
                        *entry = Entry::Dead {
                            abstract_handle,
                            physical_handle,
                        };
                    }
                    pair => return Err(format!("destroy outcome mismatch: {pair:?}")),
                }
                CommandResult::Destroyed
            }
            Command::ReuseHole { id } => {
                let entry = self
                    .entries
                    .get_mut(id)
                    .ok_or_else(|| "hole id out of range".to_string())?;
                let old = std::mem::replace(entry, Entry::Vacant);
                let Entry::Hole {
                    slot,
                    generation,
                    physical,
                } = old
                else {
                    *entry = old;
                    return Ok(CommandResult::Rejected);
                };
                let abstract_generation = self.abstract_pool.reusar_hueco(slot).map_err(text)?;
                let physical_handle = self.physical_pool.reuse_hole(physical).map_err(debug)?;
                if abstract_generation != physical_handle.generation || slot != physical_handle.slot
                {
                    return Err("hole reuse identity mismatch".into());
                }
                debug_assert_eq!(abstract_generation, generation + 1);
                *entry = Entry::Alive {
                    abstract_handle: (slot, abstract_generation),
                    physical_handle,
                };
                CommandResult::Reused {
                    slot,
                    generation: abstract_generation,
                }
            }
            Command::ReleaseHole { id } => {
                let entry = self
                    .entries
                    .get_mut(id)
                    .ok_or_else(|| "hole id out of range".to_string())?;
                let old = std::mem::replace(entry, Entry::Vacant);
                let Entry::Hole {
                    slot,
                    generation,
                    physical,
                } = old
                else {
                    *entry = old;
                    return Ok(CommandResult::Rejected);
                };
                self.abstract_pool
                    .liberar_hueco(slot, &mut self.events)
                    .map_err(text)?;
                self.physical_pool.release_hole(physical).map_err(debug)?;
                let _ = generation;
                *entry = Entry::Vacant;
                CommandResult::Released
            }
            Command::ProbeStale { id } => {
                let Entry::Dead {
                    abstract_handle,
                    physical_handle,
                } = *self
                    .entries
                    .get(id)
                    .ok_or_else(|| "probe id out of range".to_string())?
                else {
                    return Ok(CommandResult::Rejected);
                };
                let abstract_rejected = self
                    .abstract_pool
                    .leer(abstract_handle.0, abstract_handle.1, 0)
                    .is_err();
                let physical_rejected = self.physical_pool.read_int(physical_handle, 0).is_err();
                if !abstract_rejected || !physical_rejected {
                    return Err("a stale access was accepted".into());
                }
                CommandResult::Rejected
            }
        };
        self.compare_state()?;
        Ok(result)
    }

    pub fn snapshot(&self) -> Result<DifferentialSnapshot, String> {
        Ok(DifferentialSnapshot {
            live: self.abstract_pool.vivos,
            holes: self.abstract_pool.huecos,
            abstract_confirmed: self.abstract_pool.subpaginas_confirmadas(),
            physical_committed_bytes: self
                .physical_pool
                .address_metrics()
                .map_err(debug)?
                .committed_bytes,
        })
    }

    fn compare_state(&self) -> Result<(), String> {
        self.abstract_pool.comprobar_invariantes()?;
        self.physical_pool.check_invariants().map_err(debug)?;
        if self.abstract_pool.vivos != self.physical_pool.live_count()
            || self.abstract_pool.huecos != self.physical_pool.hole_count()
        {
            return Err("live/hole counter mismatch".into());
        }
        Ok(())
    }
}

fn same_identity(abstract_handle: (u32, u32), physical_handle: Handle) -> Result<(), String> {
    if abstract_handle == (physical_handle.slot, physical_handle.generation) {
        Ok(())
    } else {
        Err(format!(
            "identity mismatch: {abstract_handle:?} != ({}, {})",
            physical_handle.slot, physical_handle.generation
        ))
    }
}

fn text(error: impl std::fmt::Display) -> String {
    error.to_string()
}

fn debug(error: impl std::fmt::Debug) -> String {
    format!("{error:?}")
}
