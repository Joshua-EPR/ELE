//! Allocator Bi-Slab respaldado por memoria virtual real.
//!
//! Los metadatos de búsqueda viven también en estructuras Rust para no crear
//! referencias a la cabecera revocable. La representación normativa de
//! generaciones, bitmaps y ocupación se refleja byte por byte en la página de
//! cabecera comprometida de cada superpágina.

use std::sync::atomic::{AtomicU64, Ordering};

use super::generation;
use super::{AddressSpace, AddressSpaceMetrics, PhysicalError};
use crate::rt::pool::{
    CABECERA, GEN_RETIRADO, MAX_SUPERPAGINAS, SUBPAGINA, SUBPAGINAS_DATOS, SUPERPAGINA,
};

const FREE_OFFSET: usize = 960 * 4;
const HOLES_OFFSET: usize = FREE_OFFSET + SUBPAGINAS_DATOS * 8;
const OCCUPIED_OFFSET: usize = HOLES_OFFSET + SUBPAGINAS_DATOS * 8;
const HEADER_USED: usize = OCCUPIED_OFFSET + SUBPAGINAS_DATOS;
const _: () = assert!(HEADER_USED == 4095);

static NEXT_POOL_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PoolConfig {
    pub fields: usize,
    pub slot_size: u32,
    pub max_superpages: u32,
    pub initial_generation: u32,
    /// Inyecta un fallo antes de la reserva, para probar limpieza del constructor.
    pub fail_reserve: bool,
    /// Inyecta un fallo en la N-ésima confirmación (base uno).
    pub fail_commit_at: Option<u64>,
}

impl Default for PoolConfig {
    fn default() -> Self {
        Self {
            fields: 1,
            slot_size: 64,
            max_superpages: 8,
            initial_generation: 0,
            fail_reserve: false,
            fail_commit_at: None,
        }
    }
}

#[derive(Debug)]
pub enum PoolError {
    Physical(PhysicalError),
    InvalidConfig(&'static str),
    OutOfSpace,
    OutOfBounds,
    InvalidField,
    ForeignHandle,
    StaleGeneration,
    DoubleFree,
    InventedHole,
    Retired,
    Leak { live: u64, holes: u64 },
    Closed,
    InjectedFailure(&'static str),
    Invariant(String),
}

impl From<PhysicalError> for PoolError {
    fn from(value: PhysicalError) -> Self {
        Self::Physical(value)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Handle {
    pool: u64,
    pub slot: u32,
    pub generation: u32,
}

impl Handle {
    pub fn link(self) -> Link {
        Link {
            pool: self.pool,
            slot: self.slot,
            generation: self.generation,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Link {
    pool: u64,
    pub slot: u32,
    pub generation: u32,
}

/// Capacidad lineal: deliberadamente no implementa `Clone` ni `Copy`.
#[derive(Debug)]
pub struct HoleToken {
    pool: u64,
    slot: u32,
    generation: u32,
}

#[derive(Debug)]
pub enum DestroyOutcome {
    Free,
    Retired,
    Hole(HoleToken),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PageState {
    Reserved,
    Committed,
    Returned,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct PoolMetrics {
    pub allocations: u64,
    pub destructions: u64,
    pub hole_reuses: u64,
    pub headers_committed: u64,
    pub data_committed: u64,
    pub data_recommitted: u64,
    pub data_returned: u64,
    pub retired_slots: u64,
    pub commit_attempts: u64,
}

struct SuperpageMeta {
    generations: Vec<u32>,
    free: [u64; SUBPAGINAS_DATOS],
    holes: [u64; SUBPAGINAS_DATOS],
    occupied: [u8; SUBPAGINAS_DATOS],
    state: [PageState; SUBPAGINAS_DATOS],
}

/// Pool físico. Ninguna referencia ni slice a su reserva sale de esta API.
pub struct PhysicalPool {
    id: u64,
    config: PoolConfig,
    slots_per_subpage: u32,
    space: Option<AddressSpace>,
    superpages: Vec<Option<SuperpageMeta>>,
    live: u64,
    holes: u64,
    metrics: PoolMetrics,
}

impl PhysicalPool {
    pub fn new(mut config: PoolConfig) -> Result<Self, PoolError> {
        if config.fail_reserve {
            return Err(PoolError::InjectedFailure("reserve"));
        }
        if !(64..=SUBPAGINA as u32).contains(&config.slot_size) {
            return Err(PoolError::InvalidConfig("slot_size must be in 64..=4096"));
        }
        if config
            .fields
            .checked_mul(8)
            .is_none_or(|size| size > config.slot_size as usize)
        {
            return Err(PoolError::InvalidConfig("fields do not fit in slot"));
        }
        generation::validate_initial(config.initial_generation)
            .map_err(|_| PoolError::InvalidConfig("invalid initial generation"))?;
        config.max_superpages = config.max_superpages.clamp(1, MAX_SUPERPAGINAS);
        let len = (config.max_superpages as usize)
            .checked_mul(SUPERPAGINA as usize)
            .ok_or(PoolError::InvalidConfig("reservation size overflow"))?;
        let space = AddressSpace::reserve(len, SUPERPAGINA as usize)?;
        Ok(Self {
            id: NEXT_POOL_ID.fetch_add(1, Ordering::Relaxed),
            config,
            slots_per_subpage: SUBPAGINA as u32 / config.slot_size,
            space: Some(space),
            superpages: (0..config.max_superpages).map(|_| None).collect(),
            live: 0,
            holes: 0,
            metrics: PoolMetrics::default(),
        })
    }

    pub fn base_addr(&self) -> Result<usize, PoolError> {
        Ok(self.space()?.base_addr())
    }

    pub fn capacity(&self) -> u64 {
        self.config.max_superpages as u64 * self.slots_per_superpage() as u64
    }

    pub fn slots_per_subpage(&self) -> u32 {
        self.slots_per_subpage
    }

    pub fn slots_per_superpage(&self) -> u32 {
        self.slots_per_subpage * SUBPAGINAS_DATOS as u32
    }

    pub fn address_metrics(&self) -> Result<AddressSpaceMetrics, PoolError> {
        Ok(self.space()?.metrics())
    }

    pub fn metrics(&self) -> PoolMetrics {
        self.metrics
    }

    pub fn live_count(&self) -> u64 {
        self.live
    }

    pub fn hole_count(&self) -> u64 {
        self.holes
    }

    pub fn allocate(&mut self) -> Result<Handle, PoolError> {
        let (sp, sub) = match self.densest_available() {
            Some(location) => location,
            None => {
                let sp = self
                    .superpages
                    .iter()
                    .position(Option::is_none)
                    .ok_or(PoolError::OutOfSpace)?;
                self.initialize_superpage(sp)?;
                (sp, 0)
            }
        };

        let previous_state = self.superpages[sp].as_ref().unwrap().state[sub];
        if previous_state != PageState::Committed {
            self.commit_page(self.data_offset(sp, sub))?;
        }
        let bit = self.superpages[sp].as_ref().unwrap().free[sub].trailing_zeros() as usize;
        let index = sub * self.slots_per_subpage as usize + bit;
        let free_generation = self.superpages[sp].as_ref().unwrap().generations[index];
        let live_generation =
            generation::allocate(free_generation).map_err(|error| match error {
                generation::GenerationError::Retired => PoolError::Retired,
                _ => PoolError::Invariant("free bitmap points to a non-free generation".into()),
            })?;
        self.zero_slot(sp, sub, bit)?;

        let meta = self.superpages[sp].as_mut().unwrap();
        meta.state[sub] = PageState::Committed;
        meta.free[sub] &= !(1u64 << bit);
        meta.occupied[sub] += 1;
        meta.generations[index] = live_generation;
        if previous_state == PageState::Returned {
            self.metrics.data_recommitted += 1;
        } else if previous_state == PageState::Reserved {
            self.metrics.data_committed += 1;
        }
        self.live += 1;
        self.metrics.allocations += 1;
        self.sync_header(sp)?;
        Ok(Handle {
            pool: self.id,
            slot: sp as u32 * self.slots_per_superpage() + index as u32,
            generation: live_generation,
        })
    }

    pub fn destroy(
        &mut self,
        handle: Handle,
        reserve_hole: bool,
    ) -> Result<DestroyOutcome, PoolError> {
        let (sp, sub, bit) = self.validate_handle(handle, true)?;
        let index = sub * self.slots_per_subpage as usize + bit;
        let next =
            generation::destroy(handle.generation).map_err(|_| PoolError::StaleGeneration)?;
        let meta = self.superpages[sp].as_mut().unwrap();
        meta.generations[index] = next;
        self.live -= 1;
        self.metrics.destructions += 1;

        let outcome = if next == GEN_RETIRADO {
            meta.occupied[sub] -= 1;
            self.metrics.retired_slots += 1;
            DestroyOutcome::Retired
        } else if reserve_hole {
            meta.holes[sub] |= 1u64 << bit;
            self.holes += 1;
            DestroyOutcome::Hole(HoleToken {
                pool: self.id,
                slot: handle.slot,
                generation: next,
            })
        } else {
            meta.free[sub] |= 1u64 << bit;
            meta.occupied[sub] -= 1;
            DestroyOutcome::Free
        };
        self.sync_header(sp)?;
        if self.superpages[sp].as_ref().unwrap().occupied[sub] == 0 {
            self.return_page(sp, sub)?;
        }
        Ok(outcome)
    }

    pub fn reuse_hole(&mut self, token: HoleToken) -> Result<Handle, PoolError> {
        let (sp, sub, bit) = self.validate_hole(&token)?;
        let index = sub * self.slots_per_subpage as usize + bit;
        let generation = generation::allocate(token.generation).map_err(|_| PoolError::Retired)?;
        self.zero_slot(sp, sub, bit)?;
        let meta = self.superpages[sp].as_mut().unwrap();
        meta.holes[sub] &= !(1u64 << bit);
        meta.generations[index] = generation;
        self.holes -= 1;
        self.live += 1;
        self.metrics.allocations += 1;
        self.metrics.hole_reuses += 1;
        self.sync_header(sp)?;
        Ok(Handle {
            pool: self.id,
            slot: token.slot,
            generation,
        })
    }

    pub fn release_hole(&mut self, token: HoleToken) -> Result<(), PoolError> {
        let (sp, sub, bit) = self.validate_hole(&token)?;
        let meta = self.superpages[sp].as_mut().unwrap();
        meta.holes[sub] &= !(1u64 << bit);
        meta.free[sub] |= 1u64 << bit;
        meta.occupied[sub] -= 1;
        self.holes -= 1;
        self.sync_header(sp)?;
        if self.superpages[sp].as_ref().unwrap().occupied[sub] == 0 {
            self.return_page(sp, sub)?;
        }
        Ok(())
    }

    pub fn revalidate(&self, link: Link) -> Result<Handle, PoolError> {
        let handle = Handle {
            pool: link.pool,
            slot: link.slot,
            generation: link.generation,
        };
        self.validate_handle_readonly(handle)?;
        Ok(handle)
    }

    pub fn read_int(&mut self, handle: Handle, field: usize) -> Result<i64, PoolError> {
        let offset = self.field_offset(handle, field)?;
        let mut bytes = [0; 8];
        self.space_mut()?.read(offset, &mut bytes)?;
        Ok(i64::from_le_bytes(bytes))
    }

    pub fn write_int(&mut self, handle: Handle, field: usize, value: i64) -> Result<(), PoolError> {
        let offset = self.field_offset(handle, field)?;
        self.space_mut()?.write(offset, &value.to_le_bytes())?;
        Ok(())
    }

    pub fn read_link(&mut self, handle: Handle, field: usize) -> Result<Link, PoolError> {
        let offset = self.field_offset(handle, field)?;
        let mut bytes = [0; 8];
        self.space_mut()?.read(offset, &mut bytes)?;
        let packed = u64::from_le_bytes(bytes);
        Ok(Link {
            pool: self.id,
            slot: packed as u32,
            generation: (packed >> 32) as u32,
        })
    }

    pub fn write_link(
        &mut self,
        handle: Handle,
        field: usize,
        link: Link,
    ) -> Result<(), PoolError> {
        if link.pool != self.id {
            return Err(PoolError::ForeignHandle);
        }
        let offset = self.field_offset(handle, field)?;
        let packed = link.slot as u64 | ((link.generation as u64) << 32);
        self.space_mut()?.write(offset, &packed.to_le_bytes())?;
        Ok(())
    }

    pub fn generation(&self, slot: u32) -> Result<u32, PoolError> {
        let (sp, sub, bit) = self.locate(slot)?;
        let meta = self.superpages[sp].as_ref().ok_or(PoolError::OutOfBounds)?;
        Ok(meta.generations[sub * self.slots_per_subpage as usize + bit])
    }

    pub fn page_state(&self, slot: u32) -> Result<PageState, PoolError> {
        let (sp, sub, _) = self.locate(slot)?;
        Ok(self.superpages[sp]
            .as_ref()
            .ok_or(PoolError::OutOfBounds)?
            .state[sub])
    }

    pub fn check_invariants(&self) -> Result<(), PoolError> {
        let mask = if self.slots_per_subpage == 64 {
            u64::MAX
        } else {
            (1u64 << self.slots_per_subpage) - 1
        };
        let mut live = 0;
        let mut holes = 0;
        for meta in self.superpages.iter().flatten() {
            for sub in 0..SUBPAGINAS_DATOS {
                if (meta.free[sub] | meta.holes[sub]) & !mask != 0
                    || meta.free[sub] & meta.holes[sub] != 0
                {
                    return Err(PoolError::Invariant("invalid bitmap".into()));
                }
                let mut occupied = 0u8;
                for bit in 0..self.slots_per_subpage as usize {
                    let generation = meta.generations[sub * self.slots_per_subpage as usize + bit];
                    let free = meta.free[sub] & (1u64 << bit) != 0;
                    let hole = meta.holes[sub] & (1u64 << bit) != 0;
                    if generation & 1 == 1 {
                        if free || hole {
                            return Err(PoolError::Invariant("live slot in bitmap".into()));
                        }
                        live += 1;
                        occupied += 1;
                    } else if hole {
                        holes += 1;
                        occupied += 1;
                    } else if generation != GEN_RETIRADO && !free {
                        return Err(PoolError::Invariant("free slot missing from bitmap".into()));
                    }
                }
                if occupied != meta.occupied[sub]
                    || (occupied > 0) != (meta.state[sub] == PageState::Committed)
                {
                    return Err(PoolError::Invariant("page occupancy/state mismatch".into()));
                }
            }
        }
        if live != self.live || holes != self.holes {
            return Err(PoolError::Invariant("global counters mismatch".into()));
        }
        Ok(())
    }

    /// Rechaza fugas sin liberar la reserva. Tras éxito, el pool queda cerrado.
    pub fn close(&mut self) -> Result<(), PoolError> {
        if self.live != 0 || self.holes != 0 {
            return Err(PoolError::Leak {
                live: self.live,
                holes: self.holes,
            });
        }
        self.space.take();
        Ok(())
    }

    fn space(&self) -> Result<&AddressSpace, PoolError> {
        self.space.as_ref().ok_or(PoolError::Closed)
    }

    fn space_mut(&mut self) -> Result<&mut AddressSpace, PoolError> {
        self.space.as_mut().ok_or(PoolError::Closed)
    }

    fn densest_available(&self) -> Option<(usize, usize)> {
        self.superpages
            .iter()
            .enumerate()
            .filter_map(|(sp, meta)| meta.as_ref().map(|meta| (sp, meta)))
            .flat_map(|(sp, meta)| {
                meta.free
                    .iter()
                    .enumerate()
                    .filter(|(_, bitmap)| **bitmap != 0)
                    .map(move |(sub, bitmap)| (bitmap.count_ones(), sp, sub))
            })
            .min()
            .map(|(_, sp, sub)| (sp, sub))
    }

    fn initialize_superpage(&mut self, sp: usize) -> Result<(), PoolError> {
        let offset = sp
            .checked_mul(SUPERPAGINA as usize)
            .ok_or(PoolError::OutOfBounds)?;
        self.commit_page(offset)?;
        let mask = if self.slots_per_subpage == 64 {
            u64::MAX
        } else {
            (1u64 << self.slots_per_subpage) - 1
        };
        self.superpages[sp] = Some(SuperpageMeta {
            generations: vec![self.config.initial_generation; self.slots_per_superpage() as usize],
            free: [mask; SUBPAGINAS_DATOS],
            holes: [0; SUBPAGINAS_DATOS],
            occupied: [0; SUBPAGINAS_DATOS],
            state: [PageState::Reserved; SUBPAGINAS_DATOS],
        });
        self.metrics.headers_committed += 1;
        self.sync_header(sp)
    }

    fn commit_page(&mut self, offset: usize) -> Result<(), PoolError> {
        self.metrics.commit_attempts += 1;
        if self.config.fail_commit_at == Some(self.metrics.commit_attempts) {
            return Err(PoolError::InjectedFailure("commit"));
        }
        self.space_mut()?.commit(offset, SUBPAGINA as usize)?;
        Ok(())
    }

    fn return_page(&mut self, sp: usize, sub: usize) -> Result<(), PoolError> {
        let offset = self.data_offset(sp, sub);
        self.space_mut()?.protect_none(offset, SUBPAGINA as usize)?;
        self.space_mut()?.decommit(offset, SUBPAGINA as usize)?;
        self.superpages[sp].as_mut().unwrap().state[sub] = PageState::Returned;
        self.metrics.data_returned += 1;
        Ok(())
    }

    fn sync_header(&mut self, sp: usize) -> Result<(), PoolError> {
        let meta = self.superpages[sp].as_ref().unwrap();
        let mut header = [0u8; HEADER_USED];
        for (index, generation) in meta.generations.iter().enumerate() {
            let start = index * 4;
            header[start..start + 4].copy_from_slice(&generation.to_le_bytes());
        }
        for sub in 0..SUBPAGINAS_DATOS {
            let free = FREE_OFFSET + sub * 8;
            header[free..free + 8].copy_from_slice(&meta.free[sub].to_le_bytes());
            let holes = HOLES_OFFSET + sub * 8;
            header[holes..holes + 8].copy_from_slice(&meta.holes[sub].to_le_bytes());
            header[OCCUPIED_OFFSET + sub] = meta.occupied[sub];
        }
        let offset = sp * SUPERPAGINA as usize;
        self.space_mut()?.write(offset, &header)?;
        Ok(())
    }

    fn validate_handle(
        &self,
        handle: Handle,
        freeing: bool,
    ) -> Result<(usize, usize, usize), PoolError> {
        if handle.pool != self.id {
            return Err(PoolError::ForeignHandle);
        }
        let (sp, sub, bit) = self.locate(handle.slot)?;
        let meta = self.superpages[sp]
            .as_ref()
            .ok_or(PoolError::StaleGeneration)?;
        let actual = meta.generations[sub * self.slots_per_subpage as usize + bit];
        if actual == handle.generation && actual & 1 == 1 {
            return Ok((sp, sub, bit));
        }
        if freeing && actual & 1 == 0 && actual.checked_sub(1) == Some(handle.generation) {
            return Err(PoolError::DoubleFree);
        }
        Err(PoolError::StaleGeneration)
    }

    fn validate_handle_readonly(&self, handle: Handle) -> Result<(), PoolError> {
        self.validate_handle(handle, false).map(|_| ())
    }

    fn validate_hole(&self, token: &HoleToken) -> Result<(usize, usize, usize), PoolError> {
        if token.pool != self.id {
            return Err(PoolError::ForeignHandle);
        }
        let (sp, sub, bit) = self.locate(token.slot)?;
        let meta = self.superpages[sp]
            .as_ref()
            .ok_or(PoolError::InventedHole)?;
        let index = sub * self.slots_per_subpage as usize + bit;
        if meta.holes[sub] & (1u64 << bit) == 0 || meta.generations[index] != token.generation {
            return Err(PoolError::InventedHole);
        }
        Ok((sp, sub, bit))
    }

    fn locate(&self, slot: u32) -> Result<(usize, usize, usize), PoolError> {
        if slot as u64 >= self.capacity() {
            return Err(PoolError::OutOfBounds);
        }
        let sp = slot / self.slots_per_superpage();
        let within = slot % self.slots_per_superpage();
        Ok((
            sp as usize,
            (within / self.slots_per_subpage) as usize,
            (within % self.slots_per_subpage) as usize,
        ))
    }

    fn field_offset(&self, handle: Handle, field: usize) -> Result<usize, PoolError> {
        if field >= self.config.fields {
            return Err(PoolError::InvalidField);
        }
        let (sp, sub, bit) = self.validate_handle(handle, false)?;
        self.data_offset(sp, sub)
            .checked_add(bit * self.config.slot_size as usize)
            .and_then(|offset| offset.checked_add(field * 8))
            .ok_or(PoolError::OutOfBounds)
    }

    fn data_offset(&self, sp: usize, sub: usize) -> usize {
        sp * SUPERPAGINA as usize + CABECERA as usize + sub * SUBPAGINA as usize
    }

    fn zero_slot(&mut self, sp: usize, sub: usize, bit: usize) -> Result<(), PoolError> {
        let offset = self.data_offset(sp, sub) + bit * self.config.slot_size as usize;
        let zeroes = vec![0; self.config.slot_size as usize];
        self.space_mut()?.write(offset, &zeroes)?;
        Ok(())
    }
}
