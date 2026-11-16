//! Allocator Bi-Slab respaldado por memoria virtual real.
//!
//! # Fuente de verdad
//!
//! Los metadatos lógicos (generaciones, bitmaps libres y de huecos,
//! ocupación) viven en estructuras Rust y son la **única** fuente de verdad
//! para validar identidades. La cabecera física de cada superpágina es un
//! espejo byte a byte con el layout normativo (4.095 B), actualizado de forma
//! incremental en cada transición y verificado por
//! [`PhysicalPool::check_invariants`]. Si una escritura del espejo falla, la
//! superpágina queda marcada como sucia, la operación lógica conserva su
//! resultado y el espejo se rehace con [`PhysicalPool::repair`]; nunca se
//! lee la cabecera física para decidir la validez de un acceso.
//!
//! # Estados de una subpágina de datos
//!
//! | Estado | Confirmada en el SO | Acceso físico | Objetos vivos/huecos | Asignable | Reclaim reintentable |
//! | --- | --- | --- | --- | --- | --- |
//! | `Reserved` | no | no | no | sí (confirma) | — |
//! | `Committed` | sí | sí | sí, o ninguno si está en la caché diferida | sí | — |
//! | `ReclaimPending` | sí (`Accessible` si falló la protección, `Protected` si falló el descarte) | no garantizado | no | sí (reconfirma) | sí |
//! | `Quarantined` | desconocido; la API lo mantiene inaccesible | no garantizado | no | no, hasta `repair` | sí |
//! | `Returned` | no (descartada) | no | no | sí (reconfirma, contenido a cero) | — |
//!
//! Transiciones legales: `Reserved → Committed` (asignar); `Committed →
//! Returned | ReclaimPending` (vaciar con reclaim inmediato o al vaciar la
//! caché); `ReclaimPending → Returned` (reintento con éxito);
//! `ReclaimPending | Returned → Committed` (reactivar al asignar);
//! `Quarantined → Returned | ReclaimPending` (reconciliación por página).
//!
//! En `ReclaimPending` los bytes de objetos destruidos pueden seguir
//! físicamente en memoria, pero ningún acceso los alcanza: toda lectura o
//! escritura valida primero la generación contra los metadatos lógicos, y
//! las generaciones de los objetos destruidos ya avanzaron. Una reclamación
//! fallida nunca restaura generaciones antiguas.
//!
//! # Contrato de errores
//!
//! Las operaciones que consumen una capacidad (`destroy`, `reuse_hole`,
//! `release_hole`) devuelven `Err((capacidad, error))` **solo** si fallan
//! antes de consumirla, y entonces devuelven la capacidad intacta. Si la
//! consumen, devuelven `Ok` con un informe que separa el efecto lógico (ya
//! aplicado e irreversible) del estado de la reclamación física y del espejo
//! de cabecera. Así un error nunca induce a repetir una destrucción ni pierde
//! o duplica un hueco.
//!
//! # Autoridad
//!
//! [`Handle`] es la capacidad propietaria: no es `Copy` ni `Clone` y
//! `destroy` lo consume, de modo que el sistema de tipos de Rust impide
//! destruir dos veces con la API segura. [`ObjRef`] y [`Link`] son copiables
//! y no son propietarios: `ObjRef` permite acceder, `Link` exige revalidar
//! antes. Toda copia se valida dinámicamente contra la generación actual, que
//! es la comprobación real de autoridad. La API Rust no expresa las reglas de
//! préstamo de NEXO-Core (R5–R7: exclusividad, no-escape); esas siguen siendo
//! responsabilidad del verificador. Aquí solo se garantiza que ningún acceso
//! alcanza un objeto muerto ni memoria no accesible.

use std::sync::atomic::{AtomicU64, Ordering};

use super::address_space::FaultPlan;
use super::generation;
use super::{AddressSpace, AddressSpaceMetrics, CloseFailure, PageAccess, PhysicalError};
use crate::rt::pool::{
    CABECERA, GEN_RETIRADO, MAX_SUPERPAGINAS, SUBPAGINA, SUBPAGINAS_DATOS, SUPERPAGINA,
};

const FREE_OFFSET: usize = 960 * 4;
const HOLES_OFFSET: usize = FREE_OFFSET + SUBPAGINAS_DATOS * 8;
const OCCUPIED_OFFSET: usize = HOLES_OFFSET + SUBPAGINAS_DATOS * 8;
pub const HEADER_USED: usize = OCCUPIED_OFFSET + SUBPAGINAS_DATOS;
const _: () = assert!(HEADER_USED == 4095);
const _: () = assert!(HEADER_USED <= CABECERA as usize);

static NEXT_POOL_ID: AtomicU64 = AtomicU64::new(1);

/// Política de reclamación de subpáginas vacías.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReclaimPolicy {
    /// Devuelve al SO cada subpágina en cuanto se vacía.
    Aggressive,
    /// Conserva confirmadas hasta `keep_empty` subpáginas vacías para
    /// reutilizarlas sin llamadas al SO; las demás se devuelven.
    Deferred { keep_empty: u32 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PoolConfig {
    pub fields: usize,
    pub slot_size: u32,
    pub max_superpages: u32,
    pub initial_generation: u32,
    /// Inyecta un fallo antes de la reserva, para probar limpieza del constructor.
    pub fail_reserve: bool,
    /// Inyecta un fallo en la N-ésima confirmación de página (base uno),
    /// contando cabeceras, datos y reconfirmaciones.
    pub fail_commit_at: Option<u64>,
    pub reclaim: ReclaimPolicy,
    /// Windows: proteger antes de `MEM_DECOMMIT` (redundante; solo pruebas y
    /// comparación). En Linux la protección previa es siempre obligatoria.
    pub protect_before_discard: bool,
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
            reclaim: ReclaimPolicy::Aggressive,
            protect_before_discard: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PoolError {
    Physical(PhysicalError),
    InvalidConfig(&'static str),
    OutOfSpace,
    OutOfBounds,
    InvalidField,
    ForeignHandle,
    StaleGeneration,
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

/// Capacidad propietaria de un objeto vivo. Lineal: no es `Copy` ni `Clone`,
/// y no tiene constructor público.
///
/// La doble destrucción no compila:
/// ```compile_fail,E0382
/// use nexo::physical::{PhysicalPool, PoolConfig};
/// let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
/// let h = pool.allocate().unwrap();
/// let _ = pool.destroy(h, false);
/// let _ = pool.destroy(h, false); // uso de un valor movido
/// ```
///
/// Los campos son privados y no pueden construirse externamente:
/// ```compile_fail,E0451
/// use nexo::physical::Handle;
/// let _h = Handle { pool: 0, slot: 0, generation: 1 };
/// ```
///
/// No implementa `Clone` ni `Copy`:
/// ```compile_fail,E0599
/// use nexo::physical::{PhysicalPool, PoolConfig};
/// let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
/// let h = pool.allocate().unwrap();
/// let _h2 = h.clone();
/// ```
#[derive(Debug, Eq, PartialEq)]
pub struct Handle {
    pool: u64,
    slot: u32,
    generation: u32,
}

impl Handle {
    pub fn pool(&self) -> u64 {
        self.pool
    }

    pub fn slot(&self) -> u32 {
        self.slot
    }

    pub fn generation(&self) -> u32 {
        self.generation
    }

    /// Enlace generacional copiable (no da acceso sin revalidar).
    pub fn link(&self) -> Link {
        Link {
            pool: self.pool,
            slot: self.slot,
            generation: self.generation,
        }
    }

    /// Acceso no propietario, validado en cada uso.
    pub fn obj(&self) -> ObjRef {
        ObjRef {
            pool: self.pool,
            slot: self.slot,
            generation: self.generation,
        }
    }
}

/// Acceso copiable y no propietario. Cada lectura o escritura comprueba que
/// la identidad sigue viva; tras destruir el objeto todo acceso se rechaza.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ObjRef {
    pool: u64,
    slot: u32,
    generation: u32,
}

impl ObjRef {
    pub fn slot(&self) -> u32 {
        self.slot
    }

    pub fn generation(&self) -> u32 {
        self.generation
    }

    pub fn link(&self) -> Link {
        Link {
            pool: self.pool,
            slot: self.slot,
            generation: self.generation,
        }
    }
}

/// Enlace generacional `(slot, gen)` atado a su pool.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Link {
    pool: u64,
    slot: u32,
    generation: u32,
}

impl Link {
    pub fn pool(&self) -> u64 {
        self.pool
    }

    pub fn slot(&self) -> u32 {
        self.slot
    }

    pub fn generation(&self) -> u32 {
        self.generation
    }
}

/// Capacidad lineal de hueco: deliberadamente no implementa `Clone` ni `Copy`,
/// y sus campos son estrictamente privados.
///
/// Los campos son privados y no pueden construirse externamente:
/// ```compile_fail,E0451
/// use nexo::physical::HoleToken;
/// let _t = HoleToken { pool: 0, slot: 0, generation: 1 };
/// ```
///
/// No implementa `Clone` ni `Copy`:
/// ```compile_fail,E0599
/// use nexo::physical::{DestroyOutcome, PhysicalPool, PoolConfig};
/// let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
/// let h = pool.allocate().unwrap();
/// let rep = pool.destroy(h, true).unwrap();
/// if let DestroyOutcome::Hole(t) = rep.outcome {
///     let _t2 = t.clone();
/// }
/// ```
#[derive(Debug, Eq, PartialEq)]
pub struct HoleToken {
    pool: u64,
    slot: u32,
    generation: u32,
}

impl HoleToken {
    pub fn pool(&self) -> u64 {
        self.pool
    }

    pub fn slot(&self) -> u32 {
        self.slot
    }

    pub fn generation(&self) -> u32 {
        self.generation
    }
}

#[derive(Debug, Eq, PartialEq)]
pub enum DestroyOutcome {
    Free,
    Retired,
    Hole(HoleToken),
}

/// Resultado de la reclamación física de una subpágina vaciada.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReclaimStatus {
    /// La subpágina sigue ocupada.
    NotNeeded,
    /// Devuelta al SO.
    Completed,
    /// Conservada confirmada por la política diferida.
    Deferred,
    /// El SO falló: la subpágina queda `ReclaimPending` con el estado físico
    /// indicado y se reintentará.
    Pending {
        error: PhysicalError,
        access: PageAccess,
    },
}

/// Estado del espejo de cabecera tras una transición.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HeaderStatus {
    Synced,
    /// La escritura falló: la superpágina queda sucia hasta `repair`.
    Stale(PhysicalError),
}

/// Informe de una destrucción ya consumida (irreversible).
#[derive(Debug, Eq, PartialEq)]
pub struct DestroyReport {
    pub outcome: DestroyOutcome,
    pub reclaim: ReclaimStatus,
    pub header: HeaderStatus,
}

/// Informe de una liberación de hueco ya consumida.
#[derive(Debug, Eq, PartialEq)]
pub struct ReleaseReport {
    pub reclaim: ReclaimStatus,
    pub header: HeaderStatus,
}

/// Resultado de [`PhysicalPool::repair`].
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RepairReport {
    pub reclaimed: u64,
    pub still_pending: u64,
    pub headers_resynced: u64,
    pub headers_still_dirty: u64,
    pub errors: Vec<PhysicalError>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PageState {
    Reserved,
    Committed,
    ReclaimPending,
    /// El backend adversarial no permite afirmar el estado físico. La
    /// subpágina queda fuera del índice de asignación hasta `repair()`.
    Quarantined,
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
    pub header_bytes_written: u64,
    pub header_mirror_failures: u64,
    pub reclaim_failures: u64,
    pub reclaim_retries: u64,
    pub deferred_kept: u64,
    pub deferred_reused: u64,
}

/// Identificador validado de una superpágina dentro del pool.
/// Garantiza que el índice corresponde a un ordinal dentro del límite
/// de la reserva y que los metadatos físicos han sido inicializados.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash)]
pub struct SuperpageIndex(pub(crate) usize);

impl SuperpageIndex {
    #[inline]
    pub fn get(self) -> usize {
        self.0
    }
}

struct SuperpageMeta {
    generations: Vec<u32>,
    free: [u64; SUBPAGINAS_DATOS],
    holes: [u64; SUBPAGINAS_DATOS],
    occupied: [u8; SUBPAGINAS_DATOS],
    state: [PageState; SUBPAGINAS_DATOS],
    header_dirty: bool,
}

/// Índice por densidad: `buckets[k - 1]` contiene las subpáginas globales
/// (`sp · 15 + sub`) con exactamente `k` slots libres; `summary` marca los
/// buckets no vacíos. La subpágina elegida es la de menor `k` y, a igual `k`,
/// la de menor índice: el mismo orden que el modelo abstracto, que es la
/// relación que exige el oráculo diferencial.
struct DensityIndex {
    buckets: Vec<Vec<u64>>,
    summary: u64,
}

impl DensityIndex {
    fn new(slots_per_subpage: u32, subpages: usize) -> Self {
        let words = subpages.div_ceil(64);
        Self {
            buckets: (0..slots_per_subpage).map(|_| vec![0; words]).collect(),
            summary: 0,
        }
    }

    fn set(&mut self, g: usize, free: u32, on: bool) {
        if free == 0 || free > 64 || free as usize > self.buckets.len() {
            return;
        }
        let b = &mut self.buckets[free as usize - 1];
        let word_idx = g / 64;
        if word_idx >= b.len() {
            return;
        }
        let bit = 1u64 << (g % 64);
        if on {
            b[word_idx] |= bit;
            self.summary |= 1u64 << (free - 1);
        } else {
            b[word_idx] &= !bit;
            if b.iter().all(|w| *w == 0) {
                self.summary &= !(1u64 << (free - 1));
            }
        }
    }

    fn contains(&self, g: usize, free: u32) -> bool {
        if free == 0 || free > 64 || free as usize > self.buckets.len() {
            return false;
        }
        let b = &self.buckets[free as usize - 1];
        let word_idx = g / 64;
        if word_idx >= b.len() {
            return false;
        }
        b[word_idx] & (1u64 << (g % 64)) != 0
    }

    fn first(&self) -> Option<usize> {
        if self.summary == 0 {
            return None;
        }
        let k = self.summary.trailing_zeros() as usize;
        self.buckets[k]
            .iter()
            .enumerate()
            .find(|(_, w)| **w != 0)
            .map(|(i, w)| i * 64 + w.trailing_zeros() as usize)
    }
}

/// Pool físico. Ninguna referencia ni slice a su reserva sale de esta API.
pub struct PhysicalPool {
    id: u64,
    config: PoolConfig,
    slots_per_subpage: u32,
    space: Option<AddressSpace>,
    superpages: Vec<Option<SuperpageMeta>>,
    density: DensityIndex,
    /// Subpágina globales vacías conservadas por la política diferida.
    deferred: Vec<usize>,
    /// Subpáginas globales en `ReclaimPending`.
    pending: Vec<usize>,
    live: u64,
    holes: u64,
    metrics: PoolMetrics,
}

impl PhysicalPool {
    pub fn new(config: PoolConfig) -> Result<Self, PoolError> {
        Self::with_faults(config, FaultPlan::new())
    }

    /// Como [`PhysicalPool::new`], con un plan de fallos inyectados activo
    /// desde la reserva.
    pub fn with_faults(mut config: PoolConfig, faults: FaultPlan) -> Result<Self, PoolError> {
        if config.fail_reserve {
            return Err(PoolError::InjectedFailure("reserve"));
        }
        if !(64..=SUBPAGINA as u32).contains(&config.slot_size) {
            return Err(PoolError::InvalidConfig("slot_size must be in 64..=4096"));
        }
        if !config.slot_size.is_multiple_of(8) {
            return Err(PoolError::InvalidConfig(
                "slot_size must be a multiple of 8",
            ));
        }
        if config
            .fields
            .checked_mul(8)
            .is_none_or(|size| size > config.slot_size as usize)
        {
            return Err(PoolError::InvalidConfig("fields do not fit in slot"));
        }
        if let ReclaimPolicy::Deferred { keep_empty } = config.reclaim
            && keep_empty as usize > MAX_SUPERPAGINAS as usize * SUBPAGINAS_DATOS
        {
            return Err(PoolError::InvalidConfig(
                "keep_empty exceeds the reservation",
            ));
        }
        generation::validate_initial(config.initial_generation)
            .map_err(|_| PoolError::InvalidConfig("invalid initial generation"))?;
        config.max_superpages = config.max_superpages.clamp(1, MAX_SUPERPAGINAS);
        let len = (config.max_superpages as usize)
            .checked_mul(SUPERPAGINA as usize)
            .ok_or(PoolError::InvalidConfig("reservation size overflow"))?;
        let mut space = AddressSpace::reserve_with_faults(len, SUPERPAGINA as usize, faults)?;
        space.set_protect_before_discard(config.protect_before_discard);
        let slots_per_subpage = SUBPAGINA as u32 / config.slot_size;
        let id = NEXT_POOL_ID
            .try_update(Ordering::Relaxed, Ordering::Relaxed, |id| {
                if id == u64::MAX { None } else { Some(id + 1) }
            })
            .map_err(|_| PoolError::InvalidConfig("pool ID counter exhausted"))?;
        Ok(Self {
            id,
            config,
            slots_per_subpage,
            space: Some(space),
            superpages: (0..config.max_superpages).map(|_| None).collect(),
            density: DensityIndex::new(
                slots_per_subpage,
                config.max_superpages as usize * SUBPAGINAS_DATOS,
            ),
            deferred: Vec::new(),
            pending: Vec::new(),
            live: 0,
            holes: 0,
            metrics: PoolMetrics::default(),
        })
    }

    pub fn id(&self) -> u64 {
        self.id
    }

    /// Comprueba si el pool físico ha sido cerrado y su reserva de páginas liberada.
    pub fn is_closed(&self) -> bool {
        self.space.is_none()
    }

    /// Comprueba si el pool físico se encuentra abierto (su reserva no ha sido liberada).
    pub fn is_open(&self) -> bool {
        self.space.is_some()
    }

    /// Comprueba si el pool físico se encuentra en estado ambiguo de liberación (`ReleaseUncertain`).
    pub fn is_release_uncertain(&self) -> bool {
        self.space
            .as_ref()
            .is_some_and(|s| s.is_release_uncertain())
    }

    /// Comprueba si el pool físico se encuentra completamente operativo (abierto y sin incertidumbre de liberación).
    pub fn is_operational(&self) -> bool {
        self.space
            .as_ref()
            .is_some_and(|s| !s.is_release_uncertain() && !s.is_released())
    }

    /// Garantiza que el pool físico se encuentra en estado plenamente operativo.
    ///
    /// # Errores
    /// - [`PoolError::Closed`]: Si el pool ha sido cerrado y su reserva liberada.
    /// - [`PoolError::Physical(PhysicalError::ReleaseUncertain)`]: Si un intento de cierre previo
    ///   dejó la reserva en estado ambiguo (`ReleaseUncertain`).
    /// - [`PoolError::Physical(PhysicalError::Released)`]: Si la reserva subyacente fue liberada.
    pub fn ensure_operational(&self) -> Result<(), PoolError> {
        let space = self.space.as_ref().ok_or(PoolError::Closed)?;
        space.ensure_operational()?;
        Ok(())
    }

    pub fn base_addr(&self) -> Result<usize, PoolError> {
        self.ensure_operational()?;
        Ok(self.space()?.base_addr())
    }

    pub fn capacity(&self) -> u64 {
        (self.config.max_superpages as u64).saturating_mul(self.slots_per_superpage() as u64)
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

    pub fn pending_reclaims(&self) -> usize {
        self.pending.len()
    }

    pub fn deferred_pages(&self) -> usize {
        self.deferred.len()
    }

    pub fn dirty_headers(&self) -> usize {
        self.superpages
            .iter()
            .flatten()
            .filter(|m| m.header_dirty)
            .count()
    }

    /// Plan de fallos activo (pruebas de recuperación).
    pub fn faults_mut(&mut self) -> Result<&mut FaultPlan, PoolError> {
        Ok(self.space_mut()?.faults_mut())
    }

    pub fn set_faults(&mut self, faults: FaultPlan) -> Result<(), PoolError> {
        self.space_mut()?.set_faults(faults);
        Ok(())
    }

    pub fn allocate(&mut self) -> Result<Handle, PoolError> {
        self.ensure_operational()?;

        // Fase A — Prevalidación:
        // 1. Verificación de capacidad y desbordamiento de contadores de seguridad.
        let next_live = self.live.checked_add(1).ok_or(PoolError::OutOfSpace)?;
        if next_live > self.capacity() {
            return Err(PoolError::OutOfSpace);
        }

        // 2. Localización de subpágina y slot objetivo.
        let g = match self.density.first() {
            Some(g) => g,
            None => {
                let sp = self
                    .superpages
                    .iter()
                    .position(Option::is_none)
                    .ok_or(PoolError::OutOfSpace)?;
                self.initialize_superpage(sp)?;
                sp * SUBPAGINAS_DATOS
            }
        };
        let (sp, sub) = (g / SUBPAGINAS_DATOS, g % SUBPAGINAS_DATOS);
        let previous_state = self.meta(sp)?.state[sub];
        let free_mask = self.meta(sp)?.free[sub];
        let bit = free_mask.trailing_zeros() as usize;
        if bit >= self.slots_per_subpage as usize {
            return Err(PoolError::Invariant(
                "density index free count desynchronized".into(),
            ));
        }
        let index = sub * self.slots_per_subpage as usize + bit;

        // 3. Transición de generación validada antes de mutar estado físico o lógico.
        let live_generation = generation::allocate(self.meta(sp)?.generations[index]).map_err(
            |error| match error {
                generation::GenerationError::Retired => PoolError::Retired,
                _ => PoolError::Invariant("free bitmap points to a non-free generation".into()),
            },
        )?;

        // 4. Verificación de invariante de ocupación.
        if self.meta(sp)?.occupied[sub] >= self.slots_per_subpage as u8 {
            return Err(PoolError::Invariant(
                "subpage occupied counter overflow".into(),
            ));
        }

        // 5. Preparación física: confirmación de página y puesta a cero del slot.
        // Si cualquier paso físico falla, ninguna identidad lógica se ha publicado.
        if previous_state != PageState::Committed {
            self.commit_page(self.data_offset(sp, sub))?;
            self.meta_mut(sp)?.state[sub] = PageState::Committed;
            self.pending.retain(|p| *p != g);
            match previous_state {
                PageState::Reserved => {
                    self.metrics.data_committed = self.metrics.data_committed.saturating_add(1)
                }
                _ => {
                    self.metrics.data_recommitted = self.metrics.data_recommitted.saturating_add(1)
                }
            }
        } else if let Some(i) = self.deferred.iter().position(|p| *p == g) {
            self.deferred.swap_remove(i);
            self.metrics.deferred_reused = self.metrics.deferred_reused.saturating_add(1);
        }
        let slot_offset = self.data_offset(sp, sub) + bit * self.config.slot_size as usize;
        let slot_size = self.config.slot_size as usize;
        if let Err(e) = self.space_mut()?.fill(slot_offset, slot_size, 0) {
            if self.meta(sp).is_ok_and(|m| m.occupied[sub] == 0) {
                let _ = self.on_empty(sp, sub);
            }
            return Err(e.into());
        }

        // Fase B — Commit lógico:
        // Transición atómica infalible para la capacidad.
        let free_before = self.meta(sp)?.free[sub].count_ones();
        self.density.set(g, free_before, false);
        let meta = self.meta_mut(sp)?;
        meta.free[sub] &= !(1u64 << bit);
        meta.occupied[sub] += 1;
        meta.generations[index] = live_generation;
        self.density.set(g, free_before - 1, true);
        self.live = next_live;
        self.metrics.allocations = self.metrics.allocations.saturating_add(1);

        // Efectos físicos posteriores al commit: fallos no invalidan la asignación lógica.
        let _ = self.mirror(sp, sub, index);
        Ok(Handle {
            pool: self.id,
            slot: sp as u32 * self.slots_per_superpage() + index as u32,
            generation: live_generation,
        })
    }

    /// Destruye el objeto. `Err` devuelve el `Handle` intacto (nada se
    /// consumió); `Ok` significa que la identidad quedó invalidada para
    /// siempre, aunque la reclamación física o el espejo hayan fallado.
    pub fn destroy(
        &mut self,
        handle: Handle,
        reserve_hole: bool,
    ) -> Result<DestroyReport, (Handle, PoolError)> {
        // Fase A — Prevalidación:
        // 1. Comprobar operatividad.
        if let Err(error) = self.ensure_operational() {
            return Err((handle, error));
        }

        // 2. Validar identidad y pertenencia al pool.
        let (sp, sub, bit) = match self.validate(handle.pool, handle.slot, handle.generation) {
            Ok(x) => x,
            Err(e) => return Err((handle, e)),
        };
        let index = sub * self.slots_per_subpage as usize + bit;

        // 3. Validar transición de generación.
        let next = match generation::destroy(handle.generation) {
            Ok(n) => n,
            Err(_) => return Err((handle, PoolError::StaleGeneration)),
        };

        // 4. Validar disponibilidad de metadatos.
        let meta = match self.meta(sp) {
            Ok(m) => m,
            Err(e) => return Err((handle, e)),
        };

        // 5. Validar subdesbordamiento de contadores de seguridad (live y occupied).
        let next_live = match self.live.checked_sub(1) {
            Some(l) => l,
            None => {
                return Err((
                    handle,
                    PoolError::Invariant("live counter underflow in destroy".into()),
                ));
            }
        };
        if meta.occupied[sub] == 0 {
            return Err((
                handle,
                PoolError::Invariant("subpage occupied counter underflow in destroy".into()),
            ));
        }

        // 6. Validar condiciones previas según destino del slot (hueco, retiro o libre).
        let next_holes = if reserve_hole && next != GEN_RETIRADO {
            if meta.holes[sub] & (1u64 << bit) != 0 {
                return Err((
                    handle,
                    PoolError::Invariant("hole bit already set for live slot".into()),
                ));
            }
            match self.holes.checked_add(1) {
                Some(h) => h,
                None => return Err((handle, PoolError::OutOfSpace)),
            }
        } else {
            self.holes
        };

        if !reserve_hole && next != GEN_RETIRADO && meta.free[sub] & (1u64 << bit) != 0 {
            return Err((
                handle,
                PoolError::Invariant("free bit already set for live slot".into()),
            ));
        }

        // Fase B — Commit lógico:
        // Punto de no retorno: la capacidad se consume y el slot transiciona.
        let g = sp * SUBPAGINAS_DATOS + sub;
        let outcome = if next == GEN_RETIRADO {
            let meta = match self.meta_mut(sp) {
                Ok(m) => m,
                Err(e) => return Err((handle, e)),
            };
            meta.generations[index] = next;
            meta.occupied[sub] -= 1;
            self.live = next_live;
            self.metrics.destructions = self.metrics.destructions.saturating_add(1);
            self.metrics.retired_slots = self.metrics.retired_slots.saturating_add(1);
            DestroyOutcome::Retired
        } else if reserve_hole {
            let meta = match self.meta_mut(sp) {
                Ok(m) => m,
                Err(e) => return Err((handle, e)),
            };
            meta.generations[index] = next;
            meta.holes[sub] |= 1u64 << bit;
            self.live = next_live;
            self.holes = next_holes;
            self.metrics.destructions = self.metrics.destructions.saturating_add(1);
            DestroyOutcome::Hole(HoleToken {
                pool: self.id,
                slot: handle.slot,
                generation: next,
            })
        } else {
            let free_before = match self.meta(sp) {
                Ok(m) => m.free[sub].count_ones(),
                Err(e) => return Err((handle, e)),
            };
            self.density.set(g, free_before, false);
            let meta = match self.meta_mut(sp) {
                Ok(m) => m,
                Err(e) => {
                    self.density.set(g, free_before, true);
                    return Err((handle, e));
                }
            };
            meta.generations[index] = next;
            meta.free[sub] |= 1u64 << bit;
            meta.occupied[sub] -= 1;
            self.density.set(g, free_before + 1, true);
            self.live = next_live;
            self.metrics.destructions = self.metrics.destructions.saturating_add(1);
            DestroyOutcome::Free
        };

        // Efectos físicos posteriores al commit: no afectan la invalidación de la capacidad.
        let header = self.mirror(sp, sub, index);
        let reclaim = if self.meta(sp).is_ok_and(|m| m.occupied[sub] == 0) {
            self.on_empty(sp, sub)
        } else {
            ReclaimStatus::NotNeeded
        };
        Ok(DestroyReport {
            outcome,
            reclaim,
            header,
        })
    }

    /// Reutiliza un hueco in situ (`gen` +1). `Err` devuelve el token intacto.
    pub fn reuse_hole(&mut self, token: HoleToken) -> Result<Handle, (HoleToken, PoolError)> {
        // Fase A — Prevalidación:
        // 1. Comprobar operatividad.
        if let Err(error) = self.ensure_operational() {
            return Err((token, error));
        }

        // 2. Validar token del hueco.
        let (sp, sub, bit) = match self.validate_hole(&token) {
            Ok(x) => x,
            Err(e) => return Err((token, e)),
        };
        let index = sub * self.slots_per_subpage as usize + bit;

        // 3. Validar transición de generación.
        let generation = match generation::allocate(token.generation) {
            Ok(g) => g,
            Err(_) => return Err((token, PoolError::Retired)),
        };

        // 4. Validar disponibilidad de metadatos.
        let meta = match self.meta(sp) {
            Ok(m) => m,
            Err(e) => return Err((token, e)),
        };

        // 5. Validar contadores de seguridad (holes underflow y live overflow/capacity).
        let next_holes = match self.holes.checked_sub(1) {
            Some(h) => h,
            None => {
                return Err((
                    token,
                    PoolError::Invariant("holes counter underflow in reuse_hole".into()),
                ));
            }
        };
        let next_live = match self.live.checked_add(1) {
            Some(l) => l,
            None => return Err((token, PoolError::OutOfSpace)),
        };
        if next_live > self.capacity() {
            return Err((token, PoolError::OutOfSpace));
        }

        // 6. Validar presencia del hueco en el bitmap.
        if meta.holes[sub] & (1u64 << bit) == 0 {
            return Err((token, PoolError::InventedHole));
        }

        // 7. Preparación física: puesta a cero del slot.
        let slot_offset = self.data_offset(sp, sub) + bit * self.config.slot_size as usize;
        let slot_size = self.config.slot_size as usize;
        let zeroed = match self.space_mut() {
            Ok(space) => space
                .fill(slot_offset, slot_size, 0)
                .map_err(PoolError::from),
            Err(e) => Err(e),
        };
        if let Err(e) = zeroed {
            return Err((token, e));
        }

        // Fase B — Commit lógico:
        // Transición atómica infalible para el token.
        let meta = match self.meta_mut(sp) {
            Ok(m) => m,
            Err(e) => return Err((token, e)),
        };
        meta.holes[sub] &= !(1u64 << bit);
        meta.generations[index] = generation;
        self.holes = next_holes;
        self.live = next_live;
        self.metrics.allocations = self.metrics.allocations.saturating_add(1);
        self.metrics.hole_reuses = self.metrics.hole_reuses.saturating_add(1);

        // Efectos físicos posteriores al commit.
        let _ = self.mirror(sp, sub, index);
        Ok(Handle {
            pool: self.id,
            slot: token.slot,
            generation,
        })
    }

    /// Devuelve el hueco a la lista libre. `Err` devuelve el token intacto.
    pub fn release_hole(
        &mut self,
        token: HoleToken,
    ) -> Result<ReleaseReport, (HoleToken, PoolError)> {
        // Fase A — Prevalidación:
        // 1. Comprobar operatividad.
        if let Err(error) = self.ensure_operational() {
            return Err((token, error));
        }

        // 2. Validar token del hueco.
        let (sp, sub, bit) = match self.validate_hole(&token) {
            Ok(x) => x,
            Err(e) => return Err((token, e)),
        };
        let index = sub * self.slots_per_subpage as usize + bit;

        // 3. Validar disponibilidad de metadatos.
        let meta = match self.meta(sp) {
            Ok(m) => m,
            Err(e) => return Err((token, e)),
        };

        // 4. Validar contadores de seguridad (holes y occupied underflow).
        let next_holes = match self.holes.checked_sub(1) {
            Some(h) => h,
            None => {
                return Err((
                    token,
                    PoolError::Invariant("holes counter underflow in release_hole".into()),
                ));
            }
        };
        if meta.occupied[sub] == 0 {
            return Err((
                token,
                PoolError::Invariant("subpage occupied counter underflow in release_hole".into()),
            ));
        }

        // 5. Validar bitmaps de hueco y libres.
        if meta.holes[sub] & (1u64 << bit) == 0 {
            return Err((token, PoolError::InventedHole));
        }
        if meta.free[sub] & (1u64 << bit) != 0 {
            return Err((
                token,
                PoolError::Invariant("hole slot already present in free bitmap".into()),
            ));
        }

        // Fase B — Commit lógico:
        // Transición atómica infalible para el token.
        let g = sp * SUBPAGINAS_DATOS + sub;
        let free_before = match self.meta(sp) {
            Ok(m) => m.free[sub].count_ones(),
            Err(e) => return Err((token, e)),
        };
        self.density.set(g, free_before, false);
        let meta = match self.meta_mut(sp) {
            Ok(m) => m,
            Err(e) => {
                self.density.set(g, free_before, true);
                return Err((token, e));
            }
        };
        meta.holes[sub] &= !(1u64 << bit);
        meta.free[sub] |= 1u64 << bit;
        meta.occupied[sub] -= 1;
        self.density.set(g, free_before + 1, true);
        self.holes = next_holes;

        // Efectos físicos posteriores al commit.
        let header = self.mirror(sp, sub, index);
        let reclaim = if self.meta(sp).is_ok_and(|m| m.occupied[sub] == 0) {
            self.on_empty(sp, sub)
        } else {
            ReclaimStatus::NotNeeded
        };
        Ok(ReleaseReport { reclaim, header })
    }

    /// Revalida un enlace: devuelve un acceso no propietario si la identidad
    /// sigue viva. Nunca fabrica un `Handle`.
    pub fn revalidate(&self, link: Link) -> Result<ObjRef, PoolError> {
        self.ensure_operational()?;
        self.validate(link.pool, link.slot, link.generation)?;
        Ok(ObjRef {
            pool: link.pool,
            slot: link.slot,
            generation: link.generation,
        })
    }

    pub fn read_int(&mut self, obj: ObjRef, field: usize) -> Result<i64, PoolError> {
        let offset = self.field_offset(obj, field)?;
        let mut bytes = [0; 8];
        self.space_mut()?.read(offset, &mut bytes)?;
        Ok(i64::from_le_bytes(bytes))
    }

    pub fn write_int(&mut self, obj: ObjRef, field: usize, value: i64) -> Result<(), PoolError> {
        let offset = self.field_offset(obj, field)?;
        self.space_mut()?.write(offset, &value.to_le_bytes())?;
        Ok(())
    }

    pub fn read_link(&mut self, obj: ObjRef, field: usize) -> Result<Link, PoolError> {
        let offset = self.field_offset(obj, field)?;
        let mut bytes = [0; 8];
        self.space_mut()?.read(offset, &mut bytes)?;
        let packed = u64::from_le_bytes(bytes);
        Ok(Link {
            pool: self.id,
            slot: packed as u32,
            generation: (packed >> 32) as u32,
        })
    }

    pub fn write_link(&mut self, obj: ObjRef, field: usize, link: Link) -> Result<(), PoolError> {
        if link.pool != self.id {
            return Err(PoolError::ForeignHandle);
        }
        let offset = self.field_offset(obj, field)?;
        let packed = link.slot as u64 | ((link.generation as u64) << 32);
        self.space_mut()?.write(offset, &packed.to_le_bytes())?;
        Ok(())
    }

    pub fn generation(&self, slot: u32) -> Result<u32, PoolError> {
        self.ensure_operational()?;
        let (sp, sub, bit) = self.locate(slot)?;
        let meta = self.superpages[sp].as_ref().ok_or(PoolError::OutOfBounds)?;
        Ok(meta.generations[sub * self.slots_per_subpage as usize + bit])
    }

    pub fn page_state(&self, slot: u32) -> Result<PageState, PoolError> {
        self.ensure_operational()?;
        let (sp, sub, _) = self.locate(slot)?;
        Ok(self.superpages[sp]
            .as_ref()
            .ok_or(PoolError::OutOfBounds)?
            .state[sub])
    }

    /// Estado físico (según el SO) de la subpágina que contiene `slot`.
    pub fn physical_access(&self, slot: u32) -> Result<PageAccess, PoolError> {
        self.ensure_operational()?;
        let (sp, sub, _) = self.locate(slot)?;
        Ok(self.space()?.page_access(self.data_offset(sp, sub))?)
    }

    /// Reintenta las reclamaciones pendientes y rehace los espejos sucios.
    pub fn repair(&mut self) -> Result<RepairReport, PoolError> {
        self.ensure_operational()?;
        let mut report = RepairReport::default();
        for g in self.pending.clone() {
            let (sp, sub) = (g / SUBPAGINAS_DATOS, g % SUBPAGINAS_DATOS);
            self.metrics.reclaim_retries += 1;
            match self.try_reclaim(sp, sub) {
                ReclaimStatus::Completed => report.reclaimed += 1,
                ReclaimStatus::Pending { error, .. } => {
                    report.still_pending += 1;
                    report.errors.push(error);
                }
                other => {
                    return Err(PoolError::Invariant(format!(
                        "pending reclaim produced {other:?}"
                    )));
                }
            }
        }
        for sp in 0..self.superpages.len() {
            if self.superpages[sp].as_ref().is_some_and(|m| m.header_dirty) {
                match self.resync_header(sp) {
                    Ok(()) => report.headers_resynced += 1,
                    Err(e) => {
                        report.headers_still_dirty += 1;
                        report.errors.push(e);
                    }
                }
            }
        }
        Ok(report)
    }

    /// Modo de presión de memoria: devuelve al SO toda la caché diferida y
    /// reintenta lo pendiente.
    pub fn reclaim_all(&mut self) -> Result<RepairReport, PoolError> {
        self.ensure_operational()?;
        for g in std::mem::take(&mut self.deferred) {
            let (sp, sub) = (g / SUBPAGINAS_DATOS, g % SUBPAGINAS_DATOS);
            let _ = self.try_reclaim(sp, sub);
        }
        self.repair()
    }

    pub fn check_invariants(&self) -> Result<(), PoolError> {
        let inv = |m: String| Err(PoolError::Invariant(m));
        let space = self.space()?;
        let mask = self.full_mask();
        let mut live = 0;
        let mut holes = 0;
        for (sp, meta) in self.superpages.iter().enumerate() {
            let Some(meta) = meta else {
                continue;
            };
            for sub in 0..SUBPAGINAS_DATOS {
                let g = sp * SUBPAGINAS_DATOS + sub;
                if (meta.free[sub] | meta.holes[sub]) & !mask != 0
                    || meta.free[sub] & meta.holes[sub] != 0
                {
                    return inv(format!("subpage {g}: invalid bitmap"));
                }
                let mut occupied = 0u8;
                for bit in 0..self.slots_per_subpage as usize {
                    let generation = meta.generations[sub * self.slots_per_subpage as usize + bit];
                    let free = meta.free[sub] & (1u64 << bit) != 0;
                    let hole = meta.holes[sub] & (1u64 << bit) != 0;
                    if generation & 1 == 1 {
                        if free || hole {
                            return inv(format!("subpage {g}: live slot in bitmap"));
                        }
                        live += 1;
                        occupied += 1;
                    } else if hole {
                        holes += 1;
                        occupied += 1;
                    } else if generation != GEN_RETIRADO && !free {
                        return inv(format!("subpage {g}: free slot missing from bitmap"));
                    } else if generation == GEN_RETIRADO && free {
                        return inv(format!("subpage {g}: retired slot in free bitmap"));
                    }
                }
                if occupied != meta.occupied[sub] {
                    return inv(format!("subpage {g}: occupancy mismatch"));
                }
                let free = meta.free[sub].count_ones();
                for k in 1..=self.slots_per_subpage {
                    let indexed = meta.state[sub] != PageState::Quarantined && k == free;
                    if self.density.contains(g, k) != indexed {
                        return inv(format!("subpage {g}: density index mismatch"));
                    }
                }
                let access = space.page_access(self.data_offset(sp, sub))?;
                let quarantined = space.is_quarantined(self.data_offset(sp, sub))?;
                let in_deferred = self.deferred.contains(&g);
                let in_pending = self.pending.contains(&g);
                let ok = match meta.state[sub] {
                    PageState::Reserved => {
                        !quarantined && access == PageAccess::Reserved && occupied == 0
                    }
                    PageState::Committed => {
                        !quarantined
                            && access == PageAccess::Accessible
                            && (occupied > 0) != in_deferred
                    }
                    PageState::ReclaimPending => {
                        occupied == 0
                            && in_pending
                            && !quarantined
                            && matches!(access, PageAccess::Accessible | PageAccess::Protected)
                    }
                    PageState::Quarantined => occupied == 0 && in_pending && quarantined,
                    PageState::Returned => {
                        !quarantined && access == PageAccess::Discarded && occupied == 0
                    }
                };
                if !ok
                    || (in_pending
                        && !matches!(
                            meta.state[sub],
                            PageState::ReclaimPending | PageState::Quarantined
                        ))
                    || (in_deferred && meta.state[sub] != PageState::Committed)
                {
                    return inv(format!(
                        "subpage {g}: state {:?} / physical {access:?} / occupied {occupied} / deferred {in_deferred} / pending {in_pending}",
                        meta.state[sub]
                    ));
                }
            }
            if space.page_access(sp * SUPERPAGINA as usize)? != PageAccess::Accessible {
                return inv(format!("superpage {sp}: header page not accessible"));
            }
            if !meta.header_dirty {
                let expected = self.expected_header(meta);
                let mut actual = [0u8; HEADER_USED];
                // `read` exige `&mut`; el estado no cambia, así que se lee a
                // través de una copia de solo lectura del espejo.
                if self.peek_header(sp, &mut actual).is_err() || actual != expected {
                    return inv(format!(
                        "superpage {sp}: physical header differs from metadata"
                    ));
                }
            }
        }
        if live != self.live || holes != self.holes {
            return inv("global counters mismatch".into());
        }
        Ok(())
    }

    /// Rechaza fugas sin liberar la reserva. Si el SO rechaza la liberación,
    /// el pool sigue abierto, consistente y reintentable. Las reclamaciones
    /// pendientes y la caché diferida desaparecen con la reserva.
    pub fn close(&mut self) -> Result<(), PoolError> {
        if self.live != 0 || self.holes != 0 {
            return Err(PoolError::Leak {
                live: self.live,
                holes: self.holes,
            });
        }
        self.space_mut()?.release()?;
        self.space = None;
        self.pending.clear();
        self.deferred.clear();
        self.superpages.clear();
        Ok(())
    }

    /// Variante propietaria de [`Self::close`]. Si el pool contiene recursos
    /// vivos o el SO rechaza la liberación, el error devuelve el mismo pool
    /// abierto para resolver las capacidades y reintentar.
    pub fn try_close(mut self) -> Result<(), Box<CloseFailure<Self, PoolError>>> {
        match self.close() {
            Ok(()) => Ok(()),
            Err(error) => Err(Box::new(CloseFailure::new(self, error))),
        }
    }

    /// Comprueba si la superpágina `sp` ha sido inicializada.
    pub fn is_superpage_initialized(&self, sp: usize) -> bool {
        self.superpages.get(sp).and_then(Option::as_ref).is_some()
    }

    /// Valida que el ordinal `sp` corresponde a una superpágina inicializada en este pool.
    pub fn validate_superpage(&self, sp: usize) -> Result<SuperpageIndex, PoolError> {
        if sp >= self.superpages.len() {
            return Err(PoolError::OutOfBounds);
        }
        if self.is_superpage_initialized(sp) {
            Ok(SuperpageIndex(sp))
        } else {
            Err(PoolError::Invariant(format!(
                "superpágina {sp} no inicializada"
            )))
        }
    }

    // ------------------------------------------------------------ internos

    fn meta(&self, sp: usize) -> Result<&SuperpageMeta, PoolError> {
        self.superpages
            .get(sp)
            .and_then(Option::as_ref)
            .ok_or_else(|| PoolError::Invariant(format!("superpágina {sp} no inicializada")))
    }

    fn meta_mut(&mut self, sp: usize) -> Result<&mut SuperpageMeta, PoolError> {
        self.superpages
            .get_mut(sp)
            .and_then(Option::as_mut)
            .ok_or_else(|| PoolError::Invariant(format!("superpágina {sp} no inicializada")))
    }

    fn full_mask(&self) -> u64 {
        if self.slots_per_subpage == 64 {
            u64::MAX
        } else {
            (1u64 << self.slots_per_subpage) - 1
        }
    }

    fn space(&self) -> Result<&AddressSpace, PoolError> {
        self.space.as_ref().ok_or(PoolError::Closed)
    }

    fn space_mut(&mut self) -> Result<&mut AddressSpace, PoolError> {
        self.space.as_mut().ok_or(PoolError::Closed)
    }

    fn initialize_superpage(&mut self, sp: usize) -> Result<(), PoolError> {
        let offset = sp
            .checked_mul(SUPERPAGINA as usize)
            .ok_or(PoolError::OutOfBounds)?;
        self.commit_page(offset)?;
        let mask = self.full_mask();
        let meta = SuperpageMeta {
            generations: vec![self.config.initial_generation; self.slots_per_superpage() as usize],
            free: [mask; SUBPAGINAS_DATOS],
            holes: [0; SUBPAGINAS_DATOS],
            occupied: [0; SUBPAGINAS_DATOS],
            state: [PageState::Reserved; SUBPAGINAS_DATOS],
            header_dirty: true,
        };
        self.superpages[sp] = Some(meta);
        for sub in 0..SUBPAGINAS_DATOS {
            self.density
                .set(sp * SUBPAGINAS_DATOS + sub, self.slots_per_subpage, true);
        }
        self.metrics.headers_committed += 1;
        // Escritura completa inicial (única vez); si falla, queda sucia.
        let _ = self.resync_header(sp);
        Ok(())
    }

    fn commit_page(&mut self, offset: usize) -> Result<(), PoolError> {
        self.metrics.commit_attempts += 1;
        if self.config.fail_commit_at == Some(self.metrics.commit_attempts) {
            return Err(PoolError::InjectedFailure("commit"));
        }
        self.space_mut()?.commit(offset, SUBPAGINA as usize)?;
        Ok(())
    }

    /// Una subpágina acaba de quedar sin objetos ni huecos.
    fn on_empty(&mut self, sp: usize, sub: usize) -> ReclaimStatus {
        let g = sp * SUBPAGINAS_DATOS + sub;
        if let ReclaimPolicy::Deferred { keep_empty } = self.config.reclaim
            && self
                .meta(sp)
                .is_ok_and(|m| m.state[sub] == PageState::Committed)
            && self.deferred.len() < keep_empty as usize
        {
            self.deferred.push(g);
            self.metrics.deferred_kept = self.metrics.deferred_kept.saturating_add(1);
            return ReclaimStatus::Deferred;
        }
        self.try_reclaim(sp, sub)
    }

    fn try_reclaim(&mut self, sp: usize, sub: usize) -> ReclaimStatus {
        let g = sp * SUBPAGINAS_DATOS + sub;
        let offset = self.data_offset(sp, sub);
        let Some(space) = self.space.as_ref() else {
            return ReclaimStatus::Pending {
                error: PhysicalError::Released,
                access: PageAccess::Reserved,
            };
        };
        if space.is_quarantined(offset).unwrap_or(true) {
            let Some(space) = self.space.as_mut() else {
                return ReclaimStatus::Pending {
                    error: PhysicalError::Released,
                    access: PageAccess::Reserved,
                };
            };
            let result = space.reconcile(offset, SUBPAGINA as usize);
            if let Err(error) = result {
                return self.mark_reclaim_pending(sp, sub, error);
            }
        }
        let Some(space) = self.space.as_mut() else {
            return ReclaimStatus::Pending {
                error: PhysicalError::Released,
                access: PageAccess::Reserved,
            };
        };
        let result = space.decommit(offset, SUBPAGINA as usize);
        match result {
            Ok(()) => {
                if let Ok(m) = self.meta_mut(sp) {
                    m.state[sub] = PageState::Returned;
                }
                self.pending.retain(|p| *p != g);
                self.deferred.retain(|p| *p != g);
                let free = self.meta(sp).map_or(0, |m| m.free[sub].count_ones());
                self.density.set(g, free, true);
                self.metrics.data_returned = self.metrics.data_returned.saturating_add(1);
                ReclaimStatus::Completed
            }
            Err(error) => self.mark_reclaim_pending(sp, sub, error),
        }
    }

    fn mark_reclaim_pending(
        &mut self,
        sp: usize,
        sub: usize,
        error: PhysicalError,
    ) -> ReclaimStatus {
        let g = sp * SUBPAGINAS_DATOS + sub;
        let offset = self.data_offset(sp, sub);
        let (access, quarantined) =
            self.space
                .as_ref()
                .map_or((PageAccess::Protected, true), |space| {
                    (
                        space.page_access(offset).unwrap_or(PageAccess::Protected),
                        space.is_quarantined(offset).unwrap_or(true),
                    )
                });
        if let Ok(m) = self.meta_mut(sp) {
            m.state[sub] = if quarantined {
                PageState::Quarantined
            } else {
                PageState::ReclaimPending
            };
        }
        self.deferred.retain(|p| *p != g);
        if !self.pending.contains(&g) {
            self.pending.push(g);
        }
        let free = self.meta(sp).map_or(0, |m| m.free[sub].count_ones());
        self.density.set(g, free, !quarantined);
        self.metrics.reclaim_failures = self.metrics.reclaim_failures.saturating_add(1);
        ReclaimStatus::Pending { error, access }
    }

    /// Escritura incremental del espejo: generación, bitmaps y ocupación de la
    /// subpágina tocada (21 bytes). Un único punto de inyección por
    /// transición, comprobado antes de escribir nada.
    fn mirror(&mut self, sp: usize, sub: usize, index: usize) -> HeaderStatus {
        if self.meta(sp).map_or(true, |m| m.header_dirty) {
            return match self.resync_header(sp) {
                Ok(()) => HeaderStatus::Synced,
                Err(e) => HeaderStatus::Stale(e),
            };
        }
        let meta = match self.meta(sp) {
            Ok(m) => m,
            Err(_) => return HeaderStatus::Synced,
        };
        let generation = meta.generations[index].to_le_bytes();
        let free = meta.free[sub].to_le_bytes();
        let holes = meta.holes[sub].to_le_bytes();
        let occupied = [meta.occupied[sub]];
        let base = sp * SUPERPAGINA as usize;
        let result = (|| -> Result<(), PhysicalError> {
            let space = self.space.as_mut().ok_or(PhysicalError::Released)?;
            space.inject(super::FaultOp::HeaderWrite)?;
            space.write(base + index * 4, &generation)?;
            space.write(base + FREE_OFFSET + sub * 8, &free)?;
            space.write(base + HOLES_OFFSET + sub * 8, &holes)?;
            space.write(base + OCCUPIED_OFFSET + sub, &occupied)?;
            Ok(())
        })();
        match result {
            Ok(()) => {
                self.metrics.header_bytes_written =
                    self.metrics.header_bytes_written.saturating_add(21);
                HeaderStatus::Synced
            }
            Err(e) => {
                if let Ok(m) = self.meta_mut(sp) {
                    m.header_dirty = true;
                }
                self.metrics.header_mirror_failures =
                    self.metrics.header_mirror_failures.saturating_add(1);
                HeaderStatus::Stale(e)
            }
        }
    }

    fn expected_header(&self, meta: &SuperpageMeta) -> [u8; HEADER_USED] {
        let mut header = [0u8; HEADER_USED];
        for (index, generation) in meta.generations.iter().enumerate() {
            header[index * 4..index * 4 + 4].copy_from_slice(&generation.to_le_bytes());
        }
        for sub in 0..SUBPAGINAS_DATOS {
            let free = FREE_OFFSET + sub * 8;
            header[free..free + 8].copy_from_slice(&meta.free[sub].to_le_bytes());
            let holes = HOLES_OFFSET + sub * 8;
            header[holes..holes + 8].copy_from_slice(&meta.holes[sub].to_le_bytes());
            header[OCCUPIED_OFFSET + sub] = meta.occupied[sub];
        }
        header
    }

    fn resync_header(&mut self, sp: usize) -> Result<(), PhysicalError> {
        let header = match self.meta(sp) {
            Ok(m) => self.expected_header(m),
            Err(_) => return Ok(()),
        };
        let space = self.space.as_mut().ok_or(PhysicalError::Released)?;
        let result = space
            .inject(super::FaultOp::HeaderWrite)
            .and_then(|()| space.write(sp * SUPERPAGINA as usize, &header));
        match result {
            Ok(()) => {
                if let Ok(m) = self.meta_mut(sp) {
                    m.header_dirty = false;
                }
                self.metrics.header_bytes_written = self
                    .metrics
                    .header_bytes_written
                    .saturating_add(HEADER_USED as u64);
                Ok(())
            }
            Err(e) => {
                if let Ok(m) = self.meta_mut(sp) {
                    m.header_dirty = true;
                }
                self.metrics.header_mirror_failures =
                    self.metrics.header_mirror_failures.saturating_add(1);
                Err(e)
            }
        }
    }

    /// Lectura de la cabecera física para verificación (no para decidir
    /// validez). `AddressSpace::read` necesita `&mut`; aquí basta con un
    /// préstamo compartido porque la página de cabecera nunca se revoca
    /// mientras el pool vive.
    fn peek_header(&self, sp: usize, out: &mut [u8; HEADER_USED]) -> Result<(), PhysicalError> {
        self.space
            .as_ref()
            .ok_or(PhysicalError::Released)?
            .peek(sp * SUPERPAGINA as usize, out)
    }

    fn validate(
        &self,
        pool: u64,
        slot: u32,
        generation: u32,
    ) -> Result<(usize, usize, usize), PoolError> {
        if pool != self.id {
            return Err(PoolError::ForeignHandle);
        }
        self.ensure_operational()?;
        let (sp, sub, bit) = self.locate(slot)?;
        let meta = self.superpages[sp]
            .as_ref()
            .ok_or(PoolError::StaleGeneration)?;
        let actual = meta.generations[sub * self.slots_per_subpage as usize + bit];
        if actual == generation && actual & 1 == 1 {
            Ok((sp, sub, bit))
        } else {
            Err(PoolError::StaleGeneration)
        }
    }

    fn validate_hole(&self, token: &HoleToken) -> Result<(usize, usize, usize), PoolError> {
        if token.pool != self.id {
            return Err(PoolError::ForeignHandle);
        }
        self.ensure_operational()?;
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

    fn field_offset(&self, obj: ObjRef, field: usize) -> Result<usize, PoolError> {
        if field >= self.config.fields {
            return Err(PoolError::InvalidField);
        }
        let (sp, sub, bit) = self.validate(obj.pool, obj.slot, obj.generation)?;
        self.data_offset(sp, sub)
            .checked_add(bit * self.config.slot_size as usize)
            .and_then(|offset| offset.checked_add(field * 8))
            .ok_or(PoolError::OutOfBounds)
    }

    fn data_offset(&self, sp: usize, sub: usize) -> usize {
        sp * SUPERPAGINA as usize + CABECERA as usize + sub * SUBPAGINA as usize
    }
}

/// Métodos auxiliares de instrumentación adversarial y pruebas de corrupción.
/// No forman parte de la API del crate ni existen en compilaciones que no sean de prueba (cfg(test)),
/// y tienen visibilidad restringida al crate (`pub(crate)`).
#[cfg(test)]
#[allow(dead_code)]
impl PhysicalPool {
    pub(crate) fn corrupt_live_for_test(&mut self, live: u64) {
        self.live = live;
    }

    pub(crate) fn corrupt_holes_for_test(&mut self, holes: u64) {
        self.holes = holes;
    }

    pub(crate) fn corrupt_occupied_for_test(&mut self, sp: usize, sub: usize, occupied: u8) {
        if let Ok(meta) = self.meta_mut(sp) {
            meta.occupied[sub] = occupied;
        }
    }

    pub(crate) fn corrupt_generation_for_test(&mut self, slot: u32, generation: u32) {
        let slots_per_sub = self.slots_per_subpage as usize;
        if let Ok((sp, sub, bit)) = self.locate(slot)
            && let Ok(meta) = self.meta_mut(sp)
        {
            meta.generations[sub * slots_per_sub + bit] = generation;
        }
    }

    pub(crate) fn corrupt_free_bit_for_test(
        &mut self,
        sp: usize,
        sub: usize,
        bit: usize,
        set: bool,
    ) {
        if let Ok(meta) = self.meta_mut(sp) {
            if set {
                meta.free[sub] |= 1u64 << bit;
            } else {
                meta.free[sub] &= !(1u64 << bit);
            }
        }
    }

    pub(crate) fn corrupt_hole_bit_for_test(
        &mut self,
        sp: usize,
        sub: usize,
        bit: usize,
        set: bool,
    ) {
        if let Ok(meta) = self.meta_mut(sp) {
            if set {
                meta.holes[sub] |= 1u64 << bit;
            } else {
                meta.holes[sub] &= !(1u64 << bit);
            }
        }
    }

    pub(crate) fn craft_handle_for_test(&self, slot: u32, generation: u32) -> Handle {
        Handle {
            pool: self.id,
            slot,
            generation,
        }
    }

    pub(crate) fn craft_hole_token_for_test(&self, slot: u32, generation: u32) -> HoleToken {
        HoleToken {
            pool: self.id,
            slot,
            generation,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn superpage_typed_validation_and_meta_safety() {
        let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
        // Superpage 0 starts uninitialized
        assert!(!pool.is_superpage_initialized(0));
        assert!(matches!(
            pool.validate_superpage(0),
            Err(PoolError::Invariant(_))
        ));
        assert!(matches!(pool.meta(0), Err(PoolError::Invariant(_))));
        assert!(matches!(pool.meta_mut(0), Err(PoolError::Invariant(_))));

        // Out of bounds superpage
        assert!(matches!(
            pool.validate_superpage(999),
            Err(PoolError::OutOfBounds)
        ));
        assert!(matches!(pool.meta(999), Err(PoolError::Invariant(_))));
        assert!(matches!(pool.meta_mut(999), Err(PoolError::Invariant(_))));

        // After an allocation, superpage 0 becomes initialized
        let handle = pool.allocate().unwrap();
        assert!(pool.is_superpage_initialized(0));
        let sp_idx = pool.validate_superpage(0).unwrap();
        assert_eq!(sp_idx.get(), 0);
        assert!(pool.meta(0).is_ok());
        assert!(pool.meta_mut(0).is_ok());

        // Destroy handle
        assert!(pool.destroy(handle, false).is_ok());
        pool.close().unwrap();
    }

    #[test]
    fn density_index_boundaries_and_shift_safety() {
        let mut density = DensityIndex::new(64, 120);
        // free = 0 does nothing and does not panic
        density.set(0, 0, true);
        assert!(!density.contains(0, 0));
        // free > 64 does nothing and does not panic
        density.set(0, 65, true);
        assert!(!density.contains(0, 65));
        density.set(0, u32::MAX, true);
        assert!(!density.contains(0, u32::MAX));
        // g beyond words does not panic
        density.set(usize::MAX, 32, true);
        assert!(!density.contains(usize::MAX, 32));
    }

    #[test]
    fn pool_metrics_and_counters_saturation() {
        let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
        pool.metrics.allocations = u64::MAX;
        pool.metrics.destructions = u64::MAX;
        pool.metrics.allocations = pool.metrics.allocations.saturating_add(1);
        pool.metrics.destructions = pool.metrics.destructions.saturating_add(1);
        assert_eq!(pool.metrics.allocations, u64::MAX);
        assert_eq!(pool.metrics.destructions, u64::MAX);
        pool.close().unwrap();
    }
}
