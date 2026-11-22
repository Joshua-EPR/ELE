//! Ejecución diferencial acotada entre el modelo v0.2 y el pool físico.
//!
//! # Relación de refinamiento
//!
//! Las **observaciones semánticas** deben coincidir exactamente: identidad
//! `(slot, gen)` de cada asignación y reuso, valores leídos, resultado
//! (`Free`/`Hole`/`Retired`), rechazo de accesos obsoletos, contadores de vivos
//! y huecos, y agotamiento del espacio. El estado **físico** puede diferir del
//! abstracto solo de esta forma, por la reclamación diferida o fallida:
//!
//! * abstracto `Confirmada` (subpágina con objetos) ⇒ físico `Committed`;
//! * abstracto `Devuelta`/`Reservada` (vacía) ⇒ físico `Reserved`, `Returned`,
//!   `ReclaimPending` o `Committed` vacía (caché diferida);
//! * físico `Reserved` ⇒ abstracto no `Confirmada`.
//!
//! Los fallos inyectados afectan solo al pool físico. Una operación física
//! que falla **antes** de consumir no se aplica al modelo abstracto; una que
//! consume se aplica a ambos aunque su reclamación física quede pendiente.

use super::{
    DestroyOutcome, FaultOp, FaultPlan, Handle, HoleToken, ObjRef, PageState, PhysicalPool,
    PoolConfig, PoolError, ReclaimStatus,
};
use crate::rt::Violacion;
use crate::rt::pool::{EstadoSub, Eventos, Palabra, Pool};

#[derive(Clone, Copy, Debug)]
pub enum Command {
    Allocate {
        value: i64,
    },
    Read {
        id: usize,
    },
    Write {
        id: usize,
        value: i64,
    },
    Destroy {
        id: usize,
        hole: bool,
    },
    ReuseHole {
        id: usize,
    },
    ReleaseHole {
        id: usize,
    },
    ProbeStale {
        id: usize,
    },
    Revalidate {
        id: usize,
    },
    /// Pierde un token de hueco: ambos modelos conservan el hueco y el cierre
    /// debe detectarlo como fuga.
    LoseHole {
        id: usize,
    },
    /// Falla la próxima ocurrencia de `op` en el pool físico.
    Inject {
        op: FaultOp,
    },
    Repair,
    ReclaimAll,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandResult {
    Allocated {
        id: usize,
        slot: u32,
        generation: u32,
    },
    /// La asignación física falló antes de publicar identidad; el modelo
    /// abstracto no se tocó.
    AllocationFailed,
    OutOfSpace,
    Value(i64),
    Destroyed {
        reclaim_pending: bool,
    },
    Reused {
        slot: u32,
        generation: u32,
    },
    Released,
    Rejected,
    Injected,
    Repaired {
        still_pending: u64,
    },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DifferentialSnapshot {
    pub live: u64,
    pub holes: u64,
    pub abstract_confirmed: usize,
    pub physical_committed_bytes: usize,
    pub pending_reclaims: usize,
    pub dirty_headers: usize,
}

enum Entry {
    Vacant,
    Alive {
        abstract_handle: (u32, u32),
        physical: Handle,
    },
    Hole {
        slot: u32,
        physical: HoleToken,
    },
    LostHole,
    Dead {
        abstract_handle: (u32, u32),
        physical: ObjRef,
    },
}

pub struct DifferentialHarness {
    abstract_pool: Pool,
    physical_pool: PhysicalPool,
    events: Eventos,
    entries: Vec<Entry>,
    slots_per_subpage: u32,
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
        let physical_pool = PhysicalPool::new(config)?;
        Ok(Self {
            slots_per_subpage: physical_pool.slots_per_subpage(),
            abstract_pool,
            physical_pool,
            events: Eventos::default(),
            entries: Vec::new(),
        })
    }

    pub fn entries(&self) -> usize {
        self.entries.len()
    }

    pub fn apply(&mut self, command: Command) -> Result<CommandResult, String> {
        let result = match command {
            Command::Allocate { value } => self.allocate(value)?,
            Command::Read { id } => {
                let Some(Entry::Alive {
                    abstract_handle,
                    physical,
                }) = self.entries.get(id)
                else {
                    return Ok(CommandResult::Rejected);
                };
                let (a, obj) = (*abstract_handle, physical.obj());
                let abstract_value = self.abstract_pool.leer(a.0, a.1, 0).map_err(text)?;
                let physical_value = self.physical_pool.read_int(obj, 0).map_err(debug)?;
                if abstract_value != Palabra::Int(physical_value) {
                    return Err(format!(
                        "data mismatch: {abstract_value:?} != {physical_value}"
                    ));
                }
                CommandResult::Value(physical_value)
            }
            Command::Write { id, value } => {
                let Some(Entry::Alive {
                    abstract_handle,
                    physical,
                }) = self.entries.get(id)
                else {
                    return Ok(CommandResult::Rejected);
                };
                let (a, obj) = (*abstract_handle, physical.obj());
                self.abstract_pool
                    .escribir(a.0, a.1, 0, Palabra::Int(value))
                    .map_err(text)?;
                self.physical_pool.write_int(obj, 0, value).map_err(debug)?;
                CommandResult::Value(value)
            }
            Command::Destroy { id, hole } => self.destroy(id, hole)?,
            Command::ReuseHole { id } => {
                if !matches!(self.entries.get(id), Some(Entry::Hole { .. })) {
                    return Ok(CommandResult::Rejected);
                }
                let Entry::Hole { slot, physical } =
                    std::mem::replace(&mut self.entries[id], Entry::Vacant)
                else {
                    unreachable!("comprobado arriba")
                };
                match self.physical_pool.reuse_hole(physical) {
                    Ok(handle) => {
                        let abstract_generation =
                            self.abstract_pool.reusar_hueco(slot).map_err(text)?;
                        if abstract_generation != handle.generation() || slot != handle.slot() {
                            return Err("hole reuse identity mismatch".into());
                        }
                        let r = CommandResult::Reused {
                            slot,
                            generation: abstract_generation,
                        };
                        self.entries[id] = Entry::Alive {
                            abstract_handle: (slot, abstract_generation),
                            physical: handle,
                        };
                        r
                    }
                    Err((token, error)) => {
                        // Fallo antes de consumir: el token vuelve intacto.
                        self.entries[id] = Entry::Hole {
                            slot,
                            physical: token,
                        };
                        let _ = error;
                        CommandResult::Rejected
                    }
                }
            }
            Command::ReleaseHole { id } => {
                if !matches!(self.entries.get(id), Some(Entry::Hole { .. })) {
                    return Ok(CommandResult::Rejected);
                }
                let Entry::Hole { slot, physical } =
                    std::mem::replace(&mut self.entries[id], Entry::Vacant)
                else {
                    unreachable!("comprobado arriba")
                };
                match self.physical_pool.release_hole(physical) {
                    Ok(_) => {
                        self.abstract_pool
                            .liberar_hueco(slot, &mut self.events)
                            .map_err(text)?;
                        CommandResult::Released
                    }
                    Err((token, _)) => {
                        self.entries[id] = Entry::Hole {
                            slot,
                            physical: token,
                        };
                        CommandResult::Rejected
                    }
                }
            }
            Command::ProbeStale { id } => {
                let Some(Entry::Dead {
                    abstract_handle,
                    physical,
                }) = self.entries.get(id)
                else {
                    return Ok(CommandResult::Rejected);
                };
                let (a, obj) = (*abstract_handle, *physical);
                let abstract_rejected = self.abstract_pool.leer(a.0, a.1, 0).is_err();
                let physical_rejected = self.physical_pool.read_int(obj, 0).is_err()
                    && self.physical_pool.revalidate(obj.link()).is_err();
                if !abstract_rejected || !physical_rejected {
                    return Err("a stale access was accepted".into());
                }
                CommandResult::Rejected
            }
            Command::Revalidate { id } => match self.entries.get(id) {
                Some(Entry::Alive { physical, .. }) => {
                    let link = physical.link();
                    let obj = self.physical_pool.revalidate(link).map_err(debug)?;
                    if obj != physical.obj() {
                        return Err("revalidation changed identity".into());
                    }
                    CommandResult::Value(0)
                }
                Some(Entry::Dead { physical, .. }) => {
                    if self.physical_pool.revalidate(physical.link()).is_ok() {
                        return Err("a dead link revalidated".into());
                    }
                    CommandResult::Rejected
                }
                _ => CommandResult::Rejected,
            },
            Command::LoseHole { id } => match self.entries.get(id) {
                Some(Entry::Hole { .. }) => {
                    self.entries[id] = Entry::LostHole;
                    CommandResult::Released
                }
                _ => CommandResult::Rejected,
            },
            Command::Inject { op } => {
                let plan = self.physical_pool.faults_mut().map_err(debug)?;
                *plan = std::mem::take(plan).fail_nth(op, 1);
                CommandResult::Injected
            }
            Command::Repair => {
                let report = self.physical_pool.repair().map_err(debug)?;
                CommandResult::Repaired {
                    still_pending: report.still_pending,
                }
            }
            Command::ReclaimAll => {
                let report = self.physical_pool.reclaim_all().map_err(debug)?;
                CommandResult::Repaired {
                    still_pending: report.still_pending,
                }
            }
        };
        self.compare_state()?;
        Ok(result)
    }

    fn allocate(&mut self, value: i64) -> Result<CommandResult, String> {
        // Físico primero: si falla antes de publicar, el abstracto no cambia.
        let handle = match self.physical_pool.allocate() {
            Ok(h) => h,
            Err(PoolError::OutOfSpace) => {
                let abstract_result = self.abstract_pool.asignar(0, &mut self.events);
                return match abstract_result {
                    Err(e) if e.violacion == Violacion::AgotamientoVirtual => {
                        Ok(CommandResult::OutOfSpace)
                    }
                    other => Err(format!("physical out of space, abstract {other:?}")),
                };
            }
            Err(_) => return Ok(CommandResult::AllocationFailed),
        };
        let abstract_handle = self
            .abstract_pool
            .asignar(0, &mut self.events)
            .map_err(text)?;
        if abstract_handle != (handle.slot(), handle.generation()) {
            return Err(format!(
                "identity mismatch: {abstract_handle:?} != ({}, {})",
                handle.slot(),
                handle.generation()
            ));
        }
        self.abstract_pool
            .escribir(abstract_handle.0, abstract_handle.1, 0, Palabra::Int(value))
            .map_err(text)?;
        self.physical_pool
            .write_int(handle.obj(), 0, value)
            .map_err(debug)?;
        let id = self.entries.len();
        self.entries.push(Entry::Alive {
            abstract_handle,
            physical: handle,
        });
        Ok(CommandResult::Allocated {
            id,
            slot: abstract_handle.0,
            generation: abstract_handle.1,
        })
    }

    fn destroy(&mut self, id: usize, hole: bool) -> Result<CommandResult, String> {
        if !matches!(self.entries.get(id), Some(Entry::Alive { .. })) {
            return Ok(CommandResult::Rejected);
        }
        let Entry::Alive {
            abstract_handle,
            physical,
        } = std::mem::replace(&mut self.entries[id], Entry::Vacant)
        else {
            unreachable!("comprobado arriba")
        };
        let obj = physical.obj();
        let report = match self.physical_pool.destroy(physical, hole) {
            Ok(r) => r,
            Err((handle, error)) => {
                return Err(format!(
                    "destroy of a live handle failed: {error:?} ({handle:?})"
                ));
            }
        };
        let abstract_outcome = self
            .abstract_pool
            .destruir(abstract_handle.0, abstract_handle.1, hole, &mut self.events)
            .map_err(text)?;
        let reclaim_pending = matches!(report.reclaim, ReclaimStatus::Pending { .. });
        match (hole, abstract_outcome, report.outcome) {
            (true, crate::rt::pool::Destruido::Libre, DestroyOutcome::Hole(token)) => {
                self.entries[id] = Entry::Hole {
                    slot: abstract_handle.0,
                    physical: token,
                };
            }
            (false, crate::rt::pool::Destruido::Libre, DestroyOutcome::Free)
            | (_, crate::rt::pool::Destruido::Retirado, DestroyOutcome::Retired) => {
                self.entries[id] = Entry::Dead {
                    abstract_handle,
                    physical: obj,
                };
            }
            pair => return Err(format!("destroy outcome mismatch: {pair:?}")),
        }
        Ok(CommandResult::Destroyed { reclaim_pending })
    }

    /// Cierra el pool físico al final de una campaña: debe rechazar la fuga
    /// exactamente cuando el modelo abstracto conserva objetos o huecos.
    pub fn finish(mut self) -> Result<(), String> {
        let abstract_leak = self.abstract_pool.vivos > 0 || self.abstract_pool.huecos > 0;
        match self.physical_pool.close() {
            Err(PoolError::Leak { live, holes }) if abstract_leak => {
                if live != self.abstract_pool.vivos || holes != self.abstract_pool.huecos {
                    return Err("leak counters differ at close".into());
                }
                // Liberar lo vivo y cerrar de verdad.
                for entry in std::mem::take(&mut self.entries) {
                    match entry {
                        Entry::Alive { physical, .. } => {
                            self.physical_pool
                                .destroy(physical, false)
                                .map_err(|(_, e)| debug(e))?;
                        }
                        Entry::Hole { physical, .. } => {
                            self.physical_pool
                                .release_hole(physical)
                                .map_err(|(_, e)| debug(e))?;
                        }
                        _ => {}
                    }
                }
                // Los huecos perdidos son una fuga permanente y detectada.
                match self.physical_pool.close() {
                    Ok(()) if self.physical_pool.hole_count() == 0 => Ok(()),
                    Err(PoolError::Leak { live: 0, .. }) => Ok(()),
                    other => Err(format!("unexpected close result {other:?}")),
                }
            }
            Ok(()) if !abstract_leak => Ok(()),
            Err(PoolError::Physical(_)) if !abstract_leak => {
                // Liberación rechazada (fallo inyectado): el pool sigue vivo y
                // el reintento debe cerrarlo.
                self.physical_pool.check_invariants().map_err(debug)?;
                self.physical_pool.close().map_err(debug)
            }
            other => Err(format!(
                "close mismatch: {other:?}, abstract leak {abstract_leak}"
            )),
        }
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
            pending_reclaims: self.physical_pool.pending_reclaims(),
            dirty_headers: self.physical_pool.dirty_headers(),
        })
    }

    pub fn physical(&self) -> &PhysicalPool {
        &self.physical_pool
    }

    fn compare_state(&self) -> Result<(), String> {
        self.abstract_pool.comprobar_invariantes()?;
        self.physical_pool.check_invariants().map_err(debug)?;
        if self.abstract_pool.vivos != self.physical_pool.live_count()
            || self.abstract_pool.huecos != self.physical_pool.hole_count()
        {
            return Err("live/hole counter mismatch".into());
        }
        // Refinamiento del estado de página (ver la documentación del módulo).
        let mut slot = 0u64;
        while slot < self.physical_pool.capacity() {
            let s = slot as u32;
            let abstracto = self.abstract_pool.estado_subpagina(s);
            let fisico = self.physical_pool.page_state(s).ok();
            let confirmada = abstracto == Some(EstadoSub::Confirmada);
            if confirmada && fisico != Some(PageState::Committed) {
                return Err(format!(
                    "subpage of slot {s}: abstract confirmed, physical {fisico:?}"
                ));
            }
            if fisico == Some(PageState::Reserved) && confirmada {
                return Err(format!(
                    "subpage of slot {s}: physical reserved, abstract confirmed"
                ));
            }
            slot += self.slots_per_subpage as u64;
        }
        Ok(())
    }

    /// Plan de fallos vacío en el pool físico (para fases sin inyección).
    pub fn clear_faults(&mut self) -> Result<(), String> {
        self.physical_pool
            .set_faults(FaultPlan::new())
            .map_err(debug)
    }
}

fn text(error: impl std::fmt::Display) -> String {
    error.to_string()
}

fn debug(error: impl std::fmt::Debug) -> String {
    format!("{error:?}")
}
