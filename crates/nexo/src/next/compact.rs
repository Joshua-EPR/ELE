//! Generaciones compactas (16 bits y 8 bits) y Enlaces compactos (4 bytes y 8 bytes).
//!
//! Permite reducir la sobrecarga de memoria de 8/12 bytes por enlace a 4 u 8 bytes,
//! e implementar ciclos de vida compactos en pools de tamaño limitado preservando
//! estrictamente la inmunidad ante problemas ABA y colisiones de identidad.

use std::fmt;
use std::sync::atomic::{AtomicU8, AtomicU16, Ordering};

use crate::physical::PhysicalPool;

pub const INVALID_COMPACT_POOL_ID: u8 = 0;
pub const MAX_COMPACT_POOLS: u8 = 255;
pub const INVALID_COMPACT_POOL_ID_16: u16 = 0;
pub const MAX_COMPACT_POOLS_16: u16 = 65535;
pub const GEN_RETIRADO_16: u16 = 0xfffe;
pub const GEN_RETIRADO_8: u8 = 0xfe;
pub const MAX_SLOT_COMPACT_32: u32 = 0xffff; // 16 bits = 65.535 slots por pool compacto de 4 bytes

/// Errores de asignación y registro de pools compactos.
#[derive(Debug, Eq, PartialEq)]
pub enum CompactPoolError {
    /// Se ha agotado el espacio de identificadores únicos de pool compacto.
    /// Queda terminantemente prohibido el reciclaje o wraparound silencioso.
    PoolIdExhausted,
    InvalidPoolId,
    /// El token de autoridad no corresponde al pool físico proporcionado.
    PoolMismatch,
    /// El pool físico ya fue registrado previamente en este registro.
    AlreadyRegistered {
        physical_pool_id: u64,
    },
    /// El pool físico se encuentra cerrado y no puede registrarse ni adaptarse.
    PoolClosed,
    /// El pool físico se encuentra en estado ambiguo de liberación y no puede registrarse ni adaptarse.
    ReleaseUncertain,
    /// El registro global de pools se encuentra en un estado inconsistente o irrecuperable.
    RegistryCorrupted,
    /// Fallo de asignación de memoria al intentar expandir la capacidad del registro.
    OutOfMemory,
}

impl fmt::Display for CompactPoolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::PoolIdExhausted => write!(f, "compact pool identifier space exhausted"),
            Self::InvalidPoolId => write!(f, "invalid compact pool identifier"),
            Self::PoolMismatch => {
                write!(f, "compact pool token does not belong to the target pool")
            }
            Self::AlreadyRegistered { physical_pool_id } => {
                write!(f, "physical pool {physical_pool_id} is already registered")
            }
            Self::PoolClosed => {
                write!(
                    f,
                    "physical pool is closed and cannot be registered or adapted"
                )
            }
            Self::ReleaseUncertain => {
                write!(
                    f,
                    "physical pool has uncertain release status and cannot be registered or adapted"
                )
            }
            Self::RegistryCorrupted => {
                write!(
                    f,
                    "compact pool registry state is corrupted and refuses to issue authority"
                )
            }
            Self::OutOfMemory => {
                write!(f, "failed to allocate memory for compact pool registry")
            }
        }
    }
}

impl std::error::Error for CompactPoolError {}

/// Asignador monotónico acotado de identificadores numéricos de 8 bits (1..=255).
///
/// Componente puramente algorítmico sin autoridad de memoria.
/// Emite números únicos en el rango `1..=255`. Al alcanzar el límite,
/// retorna permanentemente [`CompactPoolError::PoolIdExhausted`] sin wraparound ni reciclaje.
#[derive(Debug)]
pub struct CompactIdAllocator8 {
    allocated: AtomicU8,
}

impl Default for CompactIdAllocator8 {
    fn default() -> Self {
        Self::new()
    }
}

impl CompactIdAllocator8 {
    pub const fn new() -> Self {
        Self {
            allocated: AtomicU8::new(0),
        }
    }

    /// Asigna el siguiente identificador numérico único (1..=255).
    pub fn allocate_id(&self) -> Result<u8, CompactPoolError> {
        let mut current = self.allocated.load(Ordering::Relaxed);
        loop {
            if current == MAX_COMPACT_POOLS {
                return Err(CompactPoolError::PoolIdExhausted);
            }
            let next = current + 1;
            match self.allocated.compare_exchange_weak(
                current,
                next,
                Ordering::SeqCst,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Ok(next),
                Err(actual) => current = actual,
            }
        }
    }

    /// Comprueba si un identificador se encuentra en el rango asignado legítimamente.
    pub fn is_valid_id(&self, id: u8) -> bool {
        id != INVALID_COMPACT_POOL_ID && id <= self.allocated.load(Ordering::SeqCst)
    }

    /// Retorna la cantidad de identificadores efectivamente emitidos.
    pub fn allocated_count(&self) -> u8 {
        self.allocated.load(Ordering::SeqCst)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RegisteredPool8 {
    physical_pool_id: u64,
    compact_id: u8,
}

/// Instancia de registro acotado de identificadores de pools compactos de 8 bits (1..=255).
pub(crate) struct CompactPoolRegistryInstance {
    allocator: CompactIdAllocator8,
    registered_pools: std::sync::Mutex<Vec<RegisteredPool8>>,
    corrupted: std::sync::atomic::AtomicBool,
}

impl Default for CompactPoolRegistryInstance {
    fn default() -> Self {
        Self::new()
    }
}

impl CompactPoolRegistryInstance {
    pub const fn new() -> Self {
        Self {
            allocator: CompactIdAllocator8::new(),
            registered_pools: std::sync::Mutex::new(Vec::new()),
            corrupted: std::sync::atomic::AtomicBool::new(false),
        }
    }

    fn audit_and_recover_8(&self, guard: &mut Vec<RegisteredPool8>) -> bool {
        guard.sort_unstable_by_key(|e| e.physical_pool_id);

        let allocated = self.allocator.allocated_count();
        let mut seen_compact = [false; 256];

        let mut i = 0;
        while i < guard.len() {
            let entry = guard[i];
            if entry.compact_id == 0 || entry.compact_id > allocated {
                return false;
            }
            if i + 1 < guard.len() && guard[i + 1].physical_pool_id == entry.physical_pool_id {
                if guard[i + 1].compact_id != entry.compact_id {
                    return false;
                }
                guard.remove(i + 1);
                continue;
            }
            if seen_compact[entry.compact_id as usize] {
                return false;
            }
            seen_compact[entry.compact_id as usize] = true;
            i += 1;
        }
        true
    }

    /// Registra un pool físico de manera atómica, transaccional e infalsificable.
    ///
    /// # Errores
    /// - Retorna [`CompactPoolError::AlreadyRegistered`] si el pool ya fue registrado previamente.
    /// - Retorna [`CompactPoolError::PoolIdExhausted`] si se han agotado los 255 identificadores.
    /// - Retorna [`CompactPoolError::RegistryCorrupted`] si el estado interno fue corrompido de forma irrecuperable.
    pub fn register(&self, physical_pool_id: u64) -> Result<CompactPoolToken, CompactPoolError> {
        if self.corrupted.load(Ordering::SeqCst) {
            return Err(CompactPoolError::RegistryCorrupted);
        }

        let mut pools = match self.registered_pools.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                let mut guard = poisoned.into_inner();
                if !self.audit_and_recover_8(&mut guard) {
                    self.corrupted.store(true, Ordering::SeqCst);
                    return Err(CompactPoolError::RegistryCorrupted);
                }
                guard
            }
        };

        match pools.binary_search_by_key(&physical_pool_id, |e| e.physical_pool_id) {
            Ok(_) => Err(CompactPoolError::AlreadyRegistered { physical_pool_id }),
            Err(insert_idx) => {
                pools
                    .try_reserve(1)
                    .map_err(|_| CompactPoolError::OutOfMemory)?;
                let compact_id = self.allocator.allocate_id()?;
                pools.insert(
                    insert_idx,
                    RegisteredPool8 {
                        physical_pool_id,
                        compact_id,
                    },
                );
                Ok(CompactPoolToken {
                    compact_id,
                    physical_pool_id,
                })
            }
        }
    }

    pub fn is_valid_id(&self, id: u8) -> bool {
        self.allocator.is_valid_id(id)
    }

    pub fn allocated_count(&self) -> u8 {
        self.allocator.allocated_count()
    }

    pub fn is_pool_registered(&self, physical_pool_id: u64) -> bool {
        if self.corrupted.load(Ordering::SeqCst) {
            return false;
        }
        let pools = match self.registered_pools.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                let mut guard = poisoned.into_inner();
                if !self.audit_and_recover_8(&mut guard) {
                    self.corrupted.store(true, Ordering::SeqCst);
                    return false;
                }
                guard
            }
        };
        pools
            .binary_search_by_key(&physical_pool_id, |e| e.physical_pool_id)
            .is_ok()
    }
}

static GLOBAL_COMPACT_REGISTRY: CompactPoolRegistryInstance = CompactPoolRegistryInstance::new();

/// Token lineal de autoridad única emitido para un pool compacto de 8 bits (1..=255).
///
/// Invariantes de seguridad (R1-R9):
/// 1. Campos estrictamente privados: ningún consumidor externo puede falsificarlo.
/// 2. No implementa `Clone` ni `Copy`: no puede duplicarse ni compartirse espuriamente.
/// 3. Vinculado de manera infalsificable a la identidad única de un `PhysicalPool` (`physical_pool_id`).
/// 4. Emitible exclusivamente a través de [`CompactPoolRegistry::register_pool`].
#[derive(Debug)]
pub struct CompactPoolToken {
    compact_id: u8,
    physical_pool_id: u64,
}

impl CompactPoolToken {
    pub fn compact_id(&self) -> u8 {
        self.compact_id
    }

    /// Identificador de pool compacto (1..=255).
    pub fn id(&self) -> u8 {
        self.compact_id
    }

    /// Identificador único del pool físico propietario vinculado a este token.
    pub fn physical_pool_id(&self) -> u64 {
        self.physical_pool_id
    }
}

/// Registro global seguro de identificadores de pools compactos de 8 bits.
pub struct CompactPoolRegistry;

impl CompactPoolRegistry {
    /// Registra un `PhysicalPool` real y emite un token de autoridad infalsificable
    /// vinculado unívocamente a su identificador de memoria física.
    ///
    /// # Errores
    /// - [`CompactPoolError::AlreadyRegistered`]: Si el pool ya fue registrado previamente.
    /// - [`CompactPoolError::PoolIdExhausted`]: Si se agotaron los 255 IDs de pool compacto.
    pub fn register_pool(pool: &PhysicalPool) -> Result<CompactPoolToken, CompactPoolError> {
        if pool.is_closed() {
            return Err(CompactPoolError::PoolClosed);
        }
        if pool.is_release_uncertain() {
            return Err(CompactPoolError::ReleaseUncertain);
        }
        pool.ensure_operational()
            .map_err(|_| CompactPoolError::ReleaseUncertain)?;
        GLOBAL_COMPACT_REGISTRY.register(pool.id())
    }

    /// Comprueba si un identificador se encuentra dentro del rango asignado legítimamente.
    pub fn is_valid_id(id: u8) -> bool {
        GLOBAL_COMPACT_REGISTRY.is_valid_id(id)
    }

    /// Retorna la cantidad de identificadores de pool efectivamente emitidos hasta el momento.
    pub fn allocated_count() -> u8 {
        GLOBAL_COMPACT_REGISTRY.allocated_count()
    }

    /// Comprueba si un pool físico específico ya se encuentra registrado.
    pub fn is_pool_registered(pool: &PhysicalPool) -> bool {
        GLOBAL_COMPACT_REGISTRY.is_pool_registered(pool.id())
    }
}

/// Asignador monotónico acotado de identificadores numéricos de 16 bits (1..=65.535).
///
/// Componente puramente algorítmico sin autoridad de memoria.
/// Emite números únicos en el rango `1..=65.535`. Al alcanzar el límite,
/// retorna permanentemente [`CompactPoolError::PoolIdExhausted`] sin wraparound ni reciclaje.
#[derive(Debug)]
pub struct CompactIdAllocator16 {
    allocated: AtomicU16,
}

impl Default for CompactIdAllocator16 {
    fn default() -> Self {
        Self::new()
    }
}

impl CompactIdAllocator16 {
    pub const fn new() -> Self {
        Self {
            allocated: AtomicU16::new(0),
        }
    }

    /// Asigna el siguiente identificador numérico único (1..=65.535).
    pub fn allocate_id(&self) -> Result<u16, CompactPoolError> {
        let mut current = self.allocated.load(Ordering::Relaxed);
        loop {
            if current == MAX_COMPACT_POOLS_16 {
                return Err(CompactPoolError::PoolIdExhausted);
            }
            let next = current + 1;
            match self.allocated.compare_exchange_weak(
                current,
                next,
                Ordering::SeqCst,
                Ordering::Relaxed,
            ) {
                Ok(_) => return Ok(next),
                Err(actual) => current = actual,
            }
        }
    }

    /// Comprueba si un identificador se encuentra en el rango asignado legítimamente.
    pub fn is_valid_id(&self, id: u16) -> bool {
        id != INVALID_COMPACT_POOL_ID_16 && id <= self.allocated.load(Ordering::SeqCst)
    }

    /// Retorna la cantidad de identificadores efectivamente emitidos.
    pub fn allocated_count(&self) -> u16 {
        self.allocated.load(Ordering::SeqCst)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RegisteredPool16 {
    physical_pool_id: u64,
    compact_id: u16,
}

/// Instancia de registro acotado de identificadores de pools compactos de 16 bits (1..=65.535).
pub(crate) struct CompactPoolRegistryInstance16 {
    allocator: CompactIdAllocator16,
    registered_pools: std::sync::Mutex<Vec<RegisteredPool16>>,
    corrupted: std::sync::atomic::AtomicBool,
}

impl Default for CompactPoolRegistryInstance16 {
    fn default() -> Self {
        Self::new()
    }
}

impl CompactPoolRegistryInstance16 {
    pub const fn new() -> Self {
        Self {
            allocator: CompactIdAllocator16::new(),
            registered_pools: std::sync::Mutex::new(Vec::new()),
            corrupted: std::sync::atomic::AtomicBool::new(false),
        }
    }

    fn audit_and_recover_16(&self, guard: &mut Vec<RegisteredPool16>) -> bool {
        guard.sort_unstable_by_key(|e| e.physical_pool_id);

        let allocated = self.allocator.allocated_count();

        let mut i = 0;
        while i < guard.len() {
            let entry = guard[i];
            if entry.compact_id == 0 || entry.compact_id > allocated {
                return false;
            }
            if i + 1 < guard.len() && guard[i + 1].physical_pool_id == entry.physical_pool_id {
                if guard[i + 1].compact_id != entry.compact_id {
                    return false;
                }
                guard.remove(i + 1);
                continue;
            }
            i += 1;
        }

        let mut compact_ids: Vec<u16> = guard.iter().map(|e| e.compact_id).collect();
        compact_ids.sort_unstable();
        for w in compact_ids.windows(2) {
            if w[0] == w[1] {
                return false;
            }
        }

        true
    }

    /// Registra un pool físico de manera atómica, transaccional e infalsificable en 16 bits.
    pub fn register(&self, physical_pool_id: u64) -> Result<CompactPoolToken16, CompactPoolError> {
        if self.corrupted.load(Ordering::SeqCst) {
            return Err(CompactPoolError::RegistryCorrupted);
        }

        let mut pools = match self.registered_pools.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                let mut guard = poisoned.into_inner();
                if !self.audit_and_recover_16(&mut guard) {
                    self.corrupted.store(true, Ordering::SeqCst);
                    return Err(CompactPoolError::RegistryCorrupted);
                }
                guard
            }
        };

        match pools.binary_search_by_key(&physical_pool_id, |e| e.physical_pool_id) {
            Ok(_) => Err(CompactPoolError::AlreadyRegistered { physical_pool_id }),
            Err(insert_idx) => {
                pools
                    .try_reserve(1)
                    .map_err(|_| CompactPoolError::OutOfMemory)?;
                let compact_id = self.allocator.allocate_id()?;
                pools.insert(
                    insert_idx,
                    RegisteredPool16 {
                        physical_pool_id,
                        compact_id,
                    },
                );
                Ok(CompactPoolToken16 {
                    compact_id,
                    physical_pool_id,
                })
            }
        }
    }

    pub fn is_valid_id(&self, id: u16) -> bool {
        self.allocator.is_valid_id(id)
    }

    pub fn allocated_count(&self) -> u16 {
        self.allocator.allocated_count()
    }

    pub fn is_pool_registered(&self, physical_pool_id: u64) -> bool {
        if self.corrupted.load(Ordering::SeqCst) {
            return false;
        }
        let pools = match self.registered_pools.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                let mut guard = poisoned.into_inner();
                if !self.audit_and_recover_16(&mut guard) {
                    self.corrupted.store(true, Ordering::SeqCst);
                    return false;
                }
                guard
            }
        };
        pools
            .binary_search_by_key(&physical_pool_id, |e| e.physical_pool_id)
            .is_ok()
    }
}

static GLOBAL_COMPACT_REGISTRY_16: CompactPoolRegistryInstance16 =
    CompactPoolRegistryInstance16::new();

/// Token lineal de autoridad única emitido para un pool compacto de 16 bits (1..=65.535).
#[derive(Debug)]
pub struct CompactPoolToken16 {
    compact_id: u16,
    physical_pool_id: u64,
}

impl CompactPoolToken16 {
    pub fn compact_id(&self) -> u16 {
        self.compact_id
    }

    pub fn id(&self) -> u16 {
        self.compact_id
    }

    pub fn physical_pool_id(&self) -> u64 {
        self.physical_pool_id
    }
}

/// Registro global seguro de identificadores de pools compactos de 16 bits.
pub struct CompactPoolRegistry16;

impl CompactPoolRegistry16 {
    /// Registra un `PhysicalPool` real y emite un token de autoridad infalsificable
    /// vinculado unívocamente a su identificador de memoria física.
    ///
    /// # Errores
    /// - [`CompactPoolError::AlreadyRegistered`]: Si el pool ya fue registrado previamente.
    /// - [`CompactPoolError::PoolIdExhausted`]: Si se agotaron los 65.535 IDs de pool compacto.
    pub fn register_pool(pool: &PhysicalPool) -> Result<CompactPoolToken16, CompactPoolError> {
        if pool.is_closed() {
            return Err(CompactPoolError::PoolClosed);
        }
        if pool.is_release_uncertain() {
            return Err(CompactPoolError::ReleaseUncertain);
        }
        pool.ensure_operational()
            .map_err(|_| CompactPoolError::ReleaseUncertain)?;
        GLOBAL_COMPACT_REGISTRY_16.register(pool.id())
    }

    pub fn is_valid_id(id: u16) -> bool {
        GLOBAL_COMPACT_REGISTRY_16.is_valid_id(id)
    }

    pub fn allocated_count() -> u16 {
        GLOBAL_COMPACT_REGISTRY_16.allocated_count()
    }

    pub fn is_pool_registered(pool: &PhysicalPool) -> bool {
        GLOBAL_COMPACT_REGISTRY_16.is_pool_registered(pool.id())
    }
}

/// Errores de manipulación de generaciones compactas.
#[derive(Debug, Eq, PartialEq)]
pub enum CompactGenError {
    Retired,
    InvalidInitialState,
    Overflow,
}

/// Manipulador de generaciones compactas (16 bits y 8 bits).
pub struct CompactGen;

impl CompactGen {
    /// Transiciona un slot a la siguiente generación viva (impar) en 16 bits.
    pub fn allocate(current: u16) -> Result<u16, CompactGenError> {
        if current >= GEN_RETIRADO_16 {
            return Err(CompactGenError::Retired);
        }
        // El slot debe estar en estado par (libre o recién destruido)
        if !current.is_multiple_of(2) {
            return Err(CompactGenError::InvalidInitialState);
        }
        // Si al sumar 1 alcanzaríamos o superaríamos el límite de retiro, retirar
        if current >= GEN_RETIRADO_16.saturating_sub(1) {
            return Err(CompactGenError::Retired);
        }
        current.checked_add(1).ok_or(CompactGenError::Overflow)
    }

    /// Transiciona un slot a la siguiente generación destruida (par) o retirado en 16 bits.
    pub fn destroy(current: u16) -> Result<u16, CompactGenError> {
        if current >= GEN_RETIRADO_16 {
            return Err(CompactGenError::Retired);
        }
        // El slot debe estar vivo (impar)
        if current.is_multiple_of(2) {
            return Err(CompactGenError::InvalidInitialState);
        }
        // Si alcanzamos 65533 (último impar antes de 0xfffe), se retira definitivamente
        if current >= 0xfffd {
            return Ok(GEN_RETIRADO_16);
        }
        current.checked_add(1).ok_or(CompactGenError::Overflow)
    }

    /// Comprueba si la generación de 16 bits corresponde a un slot vivo.
    pub fn is_live(g: u16) -> bool {
        g < GEN_RETIRADO_16 && !g.is_multiple_of(2)
    }

    /// Comprueba si la generación de 16 bits está retirada permanentemente.
    pub fn is_retired(g: u16) -> bool {
        g >= GEN_RETIRADO_16
    }

    /// Transiciona un slot a la siguiente generación viva (impar) en 8 bits.
    pub fn allocate_8(current: u8) -> Result<u8, CompactGenError> {
        if current >= GEN_RETIRADO_8 {
            return Err(CompactGenError::Retired);
        }
        if !current.is_multiple_of(2) {
            return Err(CompactGenError::InvalidInitialState);
        }
        if current >= GEN_RETIRADO_8.saturating_sub(1) {
            return Err(CompactGenError::Retired);
        }
        current.checked_add(1).ok_or(CompactGenError::Overflow)
    }

    /// Transiciona un slot a la siguiente generación destruida (par) o retirado en 8 bits.
    pub fn destroy_8(current: u8) -> Result<u8, CompactGenError> {
        if current >= GEN_RETIRADO_8 {
            return Err(CompactGenError::Retired);
        }
        if current.is_multiple_of(2) {
            return Err(CompactGenError::InvalidInitialState);
        }
        if current >= 253 {
            return Ok(GEN_RETIRADO_8);
        }
        current.checked_add(1).ok_or(CompactGenError::Overflow)
    }

    /// Comprueba si la generación de 8 bits corresponde a un slot vivo.
    pub fn is_live_8(g: u8) -> bool {
        g < GEN_RETIRADO_8 && !g.is_multiple_of(2)
    }

    /// Comprueba si la generación de 8 bits está retirada permanentemente.
    pub fn is_retired_8(g: u8) -> bool {
        g >= GEN_RETIRADO_8
    }
}

/// Errores en la creación de enlaces compactos.
#[derive(Debug, Eq, PartialEq)]
pub enum CompactLinkError {
    SlotOverflow,
    GenerationRetired,
    InvalidState,
    InvalidPoolId,
}

/// Enlace generacional compacto de 4 bytes (32 bits).
///
/// Codificación interna (32 bits exactos):
/// - Bits 0..15 (16 bits): Índice de slot dentro del pool (0..65.535).
/// - Bits 16..23 (8 bits): Generación compacta de vida (1..253).
/// - Bits 24..31 (8 bits): Identificador de pool de origen (1..255).
///
/// Garantía formal contra colisiones ABA:
/// Al restringir la generación a 8 bits con retiro definitivo en 254 (`GEN_RETIRADO_8`),
/// los valores impares vivos jamás sufren wraparound ni colisionan (por ejemplo, gen 1 y gen 257),
/// garantizando que un enlace antiguo jamás puede revalidar con un objeto posterior.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct CompactLink(u32);

impl CompactLink {
    /// Empaqueta `pool_id`, `slot` y `generation` en 4 bytes.
    ///
    /// Valida que:
    /// - `pool_id` no sea nulo (`INVALID_COMPACT_POOL_ID`).
    /// - `slot` no exceda 16 bits (`MAX_SLOT_COMPACT_32`).
    /// - `generation` no sea par (debe ser un objeto vivo).
    /// - `generation` no haya alcanzado ni superado el retiro en 254 (`GEN_RETIRADO_8`).
    pub fn new(pool_id: u8, slot: u32, generation: u16) -> Result<Self, CompactLinkError> {
        if pool_id == INVALID_COMPACT_POOL_ID {
            return Err(CompactLinkError::InvalidPoolId);
        }
        if slot > MAX_SLOT_COMPACT_32 {
            return Err(CompactLinkError::SlotOverflow);
        }
        if generation >= (GEN_RETIRADO_8 as u16) {
            return Err(CompactLinkError::GenerationRetired);
        }
        if !CompactGen::is_live(generation) {
            return Err(CompactLinkError::InvalidState);
        }
        let gen_8 = generation as u8;
        let packed = (slot & 0xffff) | ((gen_8 as u32) << 16) | ((pool_id as u32) << 24);
        Ok(Self(packed))
    }

    /// Identificador de pool de origen (1..255).
    pub fn pool_id(&self) -> u8 {
        ((self.0 >> 24) & 0xff) as u8
    }

    /// Índice de slot dentro del pool (0..65.535).
    pub fn slot(&self) -> u32 {
        self.0 & 0xffff
    }

    /// Generación de vida del enlace (1..253).
    pub fn generation(&self) -> u8 {
        ((self.0 >> 16) & 0xff) as u8
    }

    /// Comprueba si este enlace compacto coincide a nivel de representación con el pool y la generación del slot.
    ///
    /// PRECAUCIÓN: Este método es un predicado puramente representacional. No constituye por sí solo
    /// una revalidación completa de autoridad sobre memoria física, la cual requiere verificar el estado vivo
    /// y asignado del slot en la tabla de asignación del pool correspondiente (`PhysicalPool`).
    ///
    /// Retorna `true` únicamente si:
    /// 1. El pool coincide exactamente (`self.pool_id() == pool_id`).
    /// 2. La generación consultada corresponde a un slot vivo (`CompactGen::is_live`).
    /// 3. La generación consultada no ha alcanzado ni superado el límite de retiro.
    /// 4. La generación almacenada coincide exactamente con la generación actual.
    pub fn matches(&self, pool_id: u32, current_generation: u16) -> bool {
        if self.pool_id() as u32 != pool_id {
            return false;
        }
        if !CompactGen::is_live(current_generation) {
            return false;
        }
        if current_generation >= (GEN_RETIRADO_8 as u16) {
            return false;
        }
        (self.generation() as u16) == current_generation
    }

    /// Retorna la representación entera cruda de 32 bits.
    pub fn raw(&self) -> u32 {
        self.0
    }
}

/// Enlace generacional compacto de 8 bytes (64 bits).
///
/// Codificación interna (64 bits exactos):
/// - Bits 0..31 (32 bits): Índice de slot dentro del pool (hasta 4.294.967.295 slots).
/// - Bits 32..47 (16 bits): Generación de vida completa (1..65533, retira en 65534).
/// - Bits 48..63 (16 bits): Identificador de pool extendido (1..65535).
///
/// Utilizado cuando un subsistema requiere más de 255 pools o más de 65.535 slots por pool,
/// conservando la garantía absoluta No-ABA y cero colisiones generacionales.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct CompactLink64(u64);

impl CompactLink64 {
    pub fn new(pool_id: u16, slot: u32, generation: u16) -> Result<Self, CompactLinkError> {
        if pool_id == 0 {
            return Err(CompactLinkError::InvalidPoolId);
        }
        if generation >= GEN_RETIRADO_16 {
            return Err(CompactLinkError::GenerationRetired);
        }
        if !CompactGen::is_live(generation) {
            return Err(CompactLinkError::InvalidState);
        }
        let packed = (slot as u64) | ((generation as u64) << 32) | ((pool_id as u64) << 48);
        Ok(Self(packed))
    }

    pub fn pool_id(&self) -> u16 {
        ((self.0 >> 48) & 0xffff) as u16
    }

    pub fn slot(&self) -> u32 {
        (self.0 & 0xffff_ffff) as u32
    }

    pub fn generation(&self) -> u16 {
        ((self.0 >> 32) & 0xffff) as u16
    }

    /// Comprueba si este enlace compacto de 64 bits coincide a nivel de representación con el pool y la generación del slot.
    ///
    /// PRECAUCIÓN: Predicado representacional. La revalidación de autoridad sobre memoria física requiere
    /// consultar el estado efectivo del slot en el pool propietario.
    pub fn matches(&self, pool_id: u32, current_generation: u32) -> bool {
        if self.pool_id() as u32 != pool_id {
            return false;
        }
        if current_generation >= (GEN_RETIRADO_16 as u32) {
            return false;
        }
        if current_generation.is_multiple_of(2) {
            return false;
        }
        (self.generation() as u32) == current_generation
    }

    pub fn raw(&self) -> u64 {
        self.0
    }
}

/// Error al revalidar un enlace compacto contra una autoridad física de pool.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CompactRevalidateError {
    /// El enlace no pertenece al pool indicado (`pool_id` no coincide).
    ForeignPool,
    /// El índice de slot supera la capacidad máxima del pool.
    OutOfBounds,
    /// El slot consultado no se encuentra asignado (está libre o en estado hueco).
    SlotNotAllocated,
    /// La generación del enlace es obsoleta respecto a la generación viva actual del slot.
    StaleGeneration,
    /// La generación del slot ha sido retirada permanentemente por agotamiento de ciclos.
    GenerationRetired,
    /// La subpágina que contiene el slot se encuentra en cuarentena por fallo o aislamiento de seguridad.
    SubpageQuarantined,
    /// El pool físico de respaldo ha sido cerrado.
    PoolClosed,
    /// El pool físico se encuentra en estado ambiguo de liberación (`ReleaseUncertain`).
    ReleaseUncertain,
    /// Fallo físico u operativo de bajo nivel en el subsistema de memoria virtual.
    Physical(crate::physical::PhysicalError),
    /// Violación de invariante interna del pool físico.
    Invariant(String),
}

impl fmt::Display for CompactRevalidateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ForeignPool => write!(f, "compact link does not belong to this pool"),
            Self::OutOfBounds => write!(f, "compact link slot index out of bounds"),
            Self::SlotNotAllocated => write!(f, "compact link slot is not currently allocated"),
            Self::StaleGeneration => write!(f, "compact link generation is stale"),
            Self::GenerationRetired => {
                write!(f, "compact link slot generation is permanently retired")
            }
            Self::SubpageQuarantined => {
                write!(
                    f,
                    "compact link subpage is quarantined due to safety fault or isolation"
                )
            }
            Self::PoolClosed => write!(f, "compact link target pool is closed"),
            Self::ReleaseUncertain => {
                write!(f, "compact link target pool has uncertain release status")
            }
            Self::Physical(err) => write!(f, "physical memory error during revalidation: {err}"),
            Self::Invariant(msg) => write!(f, "pool invariant error during revalidation: {msg}"),
        }
    }
}

impl std::error::Error for CompactRevalidateError {}

/// Módulo privado para sellar traits de autoridad de memoria compacta.
///
/// Impide terminantemente que crates o consumidores externos implementen
/// [`CompactPoolAuthority`] o [`CompactPoolAuthority64`], evitando que entidades
/// no verificadas puedan fabricar tokens de acceso o eludir las comprobaciones
/// de seguridad física.
pub(crate) mod private {
    pub trait Sealed {}
    #[derive(Debug)]
    pub struct InternalSeal;
}

/// Token de acceso no propietario obtenido exclusivamente tras una revalidación autorizada
/// de un enlace compacto de 4 bytes ([`CompactLink`]).
///
/// Invariantes de seguridad (R1-R9):
/// 1. Campos estrictamente privados: ningún consumidor externo puede fabricar un `CompactObjRef`.
/// 2. Sin constructor público: emitible únicamente por una implementación autorizada de pool.
/// 3. No implementa `Clone` ni `Copy`: preserva la disciplina de préstamos sin duplicación espuria.
/// 4. Vinculado a la vida útil del préstamo del pool (`'a`): expira al finalizar el ámbito del préstamo,
///    impidiendo el acceso tras la destrucción, reutilización o cierre del pool.
/// 5. No puede convertirse a `Handle`: un enlace jamás confiere capacidad de posesión o destrucción.
///
/// No puede construirse externamente:
/// ```compile_fail,E0423
/// use nexo::next::CompactObjRef;
/// let _r = CompactObjRef { pool_id: 1, slot: 0, generation: 1, _marker: std::marker::PhantomData };
/// ```
#[derive(Debug)]
pub struct CompactObjRef<'a> {
    pool_id: u8,
    slot: u32,
    generation: u8,
    _marker: std::marker::PhantomData<&'a ()>,
}

impl<'a> CompactObjRef<'a> {
    pub fn pool_id(&self) -> u8 {
        self.pool_id
    }

    pub fn slot(&self) -> u32 {
        self.slot
    }

    pub fn generation(&self) -> u8 {
        self.generation
    }
}

/// Token de acceso no propietario obtenido tras revalidación de un enlace compacto de 8 bytes ([`CompactLink64`]).
///
/// No puede construirse externamente:
/// ```compile_fail,E0423
/// use nexo::next::CompactObjRef64;
/// let _r = CompactObjRef64 { pool_id: 1, slot: 0, generation: 1, _marker: std::marker::PhantomData };
/// ```
#[derive(Debug)]
pub struct CompactObjRef64<'a> {
    pool_id: u16,
    slot: u32,
    generation: u16,
    _marker: std::marker::PhantomData<&'a ()>,
}

impl<'a> CompactObjRef64<'a> {
    pub fn pool_id(&self) -> u16 {
        self.pool_id
    }

    pub fn slot(&self) -> u32 {
        self.slot
    }

    pub fn generation(&self) -> u16 {
        self.generation
    }
}

/// Autoridad de revalidación para pools con soporte de enlaces compactos de 4 bytes.
///
/// Este trait está sellado de manera auténtica mediante [`private::Sealed`] y un método interno
/// oculto que requiere [`private::InternalSeal`]: solo implementaciones auditadas dentro
/// del runtime de NEXO pueden actuar como autoridad de revalidación.
///
/// Tipos externos no pueden implementar este trait:
/// ```compile_fail,E0277
/// use nexo::next::CompactPoolAuthority;
/// struct RoguePool;
/// impl CompactPoolAuthority for RoguePool {
///     fn compact_id(&self) -> u8 { 1 }
///     fn slot_capacity(&self) -> u32 { 10 }
///     fn current_compact_generation(&self, _: u32) -> Result<u8, nexo::next::CompactRevalidateError> { Ok(1) }
/// }
/// ```
pub trait CompactPoolAuthority: private::Sealed {
    #[doc(hidden)]
    fn __seal_authority(&self, _: private::InternalSeal);

    fn compact_id(&self) -> u8;
    fn slot_capacity(&self) -> u32;
    fn current_compact_generation(&self, slot: u32) -> Result<u8, CompactRevalidateError>;

    /// Revalida un enlace compacto contra la autoridad real del pool.
    fn revalidate_compact<'a>(
        &'a self,
        link: CompactLink,
    ) -> Result<CompactObjRef<'a>, CompactRevalidateError> {
        if link.pool_id() != self.compact_id() {
            return Err(CompactRevalidateError::ForeignPool);
        }
        if link.slot() >= self.slot_capacity() {
            return Err(CompactRevalidateError::OutOfBounds);
        }
        let current_gen = self.current_compact_generation(link.slot())?;
        if current_gen >= GEN_RETIRADO_8 {
            return Err(CompactRevalidateError::GenerationRetired);
        }
        if current_gen.is_multiple_of(2) {
            return Err(CompactRevalidateError::SlotNotAllocated);
        }
        if link.generation() != current_gen {
            return Err(CompactRevalidateError::StaleGeneration);
        }
        Ok(CompactObjRef {
            pool_id: link.pool_id(),
            slot: link.slot(),
            generation: link.generation(),
            _marker: std::marker::PhantomData,
        })
    }
}

/// Autoridad de revalidación para pools con soporte de enlaces compactos de 8 bytes.
///
/// Tipos externos no pueden implementar este trait:
/// ```compile_fail,E0277
/// use nexo::next::CompactPoolAuthority64;
/// struct RoguePool64;
/// impl CompactPoolAuthority64 for RoguePool64 {
///     fn compact_id(&self) -> u16 { 1 }
///     fn slot_capacity(&self) -> u32 { 10 }
///     fn current_compact_generation(&self, _: u32) -> Result<u16, nexo::next::CompactRevalidateError> { Ok(1) }
/// }
/// ```
pub trait CompactPoolAuthority64: private::Sealed {
    #[doc(hidden)]
    fn __seal_authority(&self, _: private::InternalSeal);

    fn compact_id(&self) -> u16;
    fn slot_capacity(&self) -> u32;
    fn current_compact_generation(&self, slot: u32) -> Result<u16, CompactRevalidateError>;

    /// Revalida un enlace compacto de 64 bits contra la autoridad real del pool.
    fn revalidate_compact_64<'a>(
        &'a self,
        link: CompactLink64,
    ) -> Result<CompactObjRef64<'a>, CompactRevalidateError> {
        if link.pool_id() != self.compact_id() {
            return Err(CompactRevalidateError::ForeignPool);
        }
        if link.slot() >= self.slot_capacity() {
            return Err(CompactRevalidateError::OutOfBounds);
        }
        let current_gen = self.current_compact_generation(link.slot())?;
        if current_gen >= GEN_RETIRADO_16 {
            return Err(CompactRevalidateError::GenerationRetired);
        }
        if current_gen.is_multiple_of(2) {
            return Err(CompactRevalidateError::SlotNotAllocated);
        }
        if link.generation() != current_gen {
            return Err(CompactRevalidateError::StaleGeneration);
        }
        Ok(CompactObjRef64 {
            pool_id: link.pool_id(),
            slot: link.slot(),
            generation: link.generation(),
            _marker: std::marker::PhantomData,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MockCompactPool {
        pub id: u8,
        pub capacity: u32,
        pub generations: Vec<u8>,
    }

    impl private::Sealed for MockCompactPool {}

    impl CompactPoolAuthority for MockCompactPool {
        fn __seal_authority(&self, _: private::InternalSeal) {}

        fn compact_id(&self) -> u8 {
            self.id
        }

        fn slot_capacity(&self) -> u32 {
            self.capacity
        }

        fn current_compact_generation(&self, slot: u32) -> Result<u8, CompactRevalidateError> {
            if slot >= self.capacity || slot as usize >= self.generations.len() {
                return Err(CompactRevalidateError::OutOfBounds);
            }
            Ok(self.generations[slot as usize])
        }
    }

    struct MockCompactPool64 {
        pub id: u16,
        pub capacity: u32,
        pub generations: Vec<u16>,
    }

    impl private::Sealed for MockCompactPool64 {}

    impl CompactPoolAuthority64 for MockCompactPool64 {
        fn __seal_authority(&self, _: private::InternalSeal) {}

        fn compact_id(&self) -> u16 {
            self.id
        }

        fn slot_capacity(&self) -> u32 {
            self.capacity
        }

        fn current_compact_generation(&self, slot: u32) -> Result<u16, CompactRevalidateError> {
            if slot >= self.capacity || slot as usize >= self.generations.len() {
                return Err(CompactRevalidateError::OutOfBounds);
            }
            Ok(self.generations[slot as usize])
        }
    }

    #[test]
    fn test_compact_pool_authority_revalidation() {
        let pool = MockCompactPool {
            id: 10,
            capacity: 100,
            generations: vec![1, 2, 3, 254], // slot 0: gen 1 (vivo), slot 1: gen 2 (destruido), slot 2: gen 3 (vivo), slot 3: retirado
        };

        // Enlace válido
        let valid_link = CompactLink::new(10, 0, 1).unwrap();
        let obj_ref = pool.revalidate_compact(valid_link).unwrap();
        assert_eq!(obj_ref.pool_id(), 10);
        assert_eq!(obj_ref.slot(), 0);
        assert_eq!(obj_ref.generation(), 1);

        // Enlace foráneo (pool_id distinto)
        let foreign_link = CompactLink::new(11, 0, 1).unwrap();
        assert_eq!(
            pool.revalidate_compact(foreign_link).unwrap_err(),
            CompactRevalidateError::ForeignPool
        );

        // Slot no asignado (par)
        let unallocated_link = CompactLink::new(10, 1, 1).unwrap();
        assert_eq!(
            pool.revalidate_compact(unallocated_link).unwrap_err(),
            CompactRevalidateError::SlotNotAllocated
        );

        // Generación obsoleta (stale)
        let stale_link = CompactLink::new(10, 2, 1).unwrap(); // el pool tiene gen 3
        assert_eq!(
            pool.revalidate_compact(stale_link).unwrap_err(),
            CompactRevalidateError::StaleGeneration
        );

        // Slot fuera de límites
        let oob_link = CompactLink::new(10, 200, 1).unwrap();
        assert_eq!(
            pool.revalidate_compact(oob_link).unwrap_err(),
            CompactRevalidateError::OutOfBounds
        );
    }

    #[test]
    fn test_compact_pool_authority_64_revalidation() {
        let pool = MockCompactPool64 {
            id: 200,
            capacity: 50,
            generations: vec![1, 2, GEN_RETIRADO_16],
        };

        let valid = CompactLink64::new(200, 0, 1).unwrap();
        let obj = pool.revalidate_compact_64(valid).unwrap();
        assert_eq!(obj.pool_id(), 200);
        assert_eq!(obj.slot(), 0);
        assert_eq!(obj.generation(), 1);

        let retired = CompactLink64::new(200, 2, 1).unwrap();
        assert_eq!(
            pool.revalidate_compact_64(retired).unwrap_err(),
            CompactRevalidateError::GenerationRetired
        );
    }

    #[test]
    fn test_compact_gen_16bit_boundary_correctness() {
        assert!(CompactGen::is_retired(GEN_RETIRADO_16));
        assert!(CompactGen::is_retired(0xffff));
        assert!(!CompactGen::is_live(0xffff));
        assert!(!CompactGen::is_live(GEN_RETIRADO_16));
        assert!(CompactGen::is_live(65533));
        assert!(!CompactGen::is_live(65532));

        assert_eq!(
            CompactGen::allocate(0xffff).unwrap_err(),
            CompactGenError::Retired
        );
        assert_eq!(
            CompactGen::destroy(0xffff).unwrap_err(),
            CompactGenError::Retired
        );
    }

    #[test]
    fn test_isolated_compact_pool_registry_instance() {
        let registry = CompactPoolRegistryInstance::new();
        assert_eq!(registry.allocated_count(), 0);
        assert!(!registry.is_valid_id(0));
        assert!(!registry.is_valid_id(1));

        let token1 = registry.register(1001).unwrap();
        assert_eq!(token1.compact_id(), 1);
        assert_eq!(token1.physical_pool_id(), 1001);
        assert!(registry.is_valid_id(1));
        assert!(!registry.is_valid_id(2));
        assert_eq!(registry.allocated_count(), 1);
        assert!(registry.is_pool_registered(1001));
        assert!(!registry.is_pool_registered(1002));

        // Intento de registro duplicado del mismo pool físico debe ser rechazado
        assert_eq!(
            registry.register(1001).unwrap_err(),
            CompactPoolError::AlreadyRegistered {
                physical_pool_id: 1001
            }
        );
        assert_eq!(registry.allocated_count(), 1);

        // Asignar pools únicos hasta alcanzar el límite exacto de 255
        let mut allocated = vec![token1.compact_id()];
        for pool_id in 1002..=(1000 + MAX_COMPACT_POOLS as u64) {
            let tok = registry.register(pool_id).unwrap();
            assert_ne!(tok.compact_id(), INVALID_COMPACT_POOL_ID);
            allocated.push(tok.compact_id());
        }

        assert_eq!(allocated.len(), MAX_COMPACT_POOLS as usize);
        assert_eq!(allocated[0], 1);
        assert_eq!(allocated[MAX_COMPACT_POOLS as usize - 1], MAX_COMPACT_POOLS);

        // Agotado: PoolIdExhausted sin wraparound
        assert_eq!(
            registry.register(9999).unwrap_err(),
            CompactPoolError::PoolIdExhausted
        );
        assert!(registry.is_valid_id(1));
        assert!(registry.is_valid_id(MAX_COMPACT_POOLS));
        assert!(!registry.is_valid_id(INVALID_COMPACT_POOL_ID));
        assert_eq!(registry.allocated_count(), MAX_COMPACT_POOLS);
    }

    #[test]
    fn test_isolated_compact_id_allocator_concurrency() {
        use std::sync::Arc;
        let allocator = Arc::new(CompactIdAllocator8::new());
        let mut handles = Vec::new();

        for _ in 0..8 {
            let alloc = allocator.clone();
            handles.push(std::thread::spawn(move || {
                let mut issued = Vec::new();
                while let Ok(id) = alloc.allocate_id() {
                    issued.push(id);
                }
                issued
            }));
        }

        let mut all_issued = Vec::new();
        for h in handles {
            all_issued.extend(h.join().unwrap());
        }

        assert_eq!(all_issued.len(), MAX_COMPACT_POOLS as usize);
        all_issued.sort_unstable();
        all_issued.dedup();
        assert_eq!(all_issued.len(), MAX_COMPACT_POOLS as usize);
    }

    #[test]
    fn test_isolated_compact_pool_registry_16_instance() {
        let registry16 = CompactPoolRegistryInstance16::new();
        assert_eq!(registry16.allocated_count(), 0);
        assert!(!registry16.is_valid_id(0));
        assert!(!registry16.is_valid_id(1));

        let token1 = registry16.register(5001).unwrap();
        assert_eq!(token1.compact_id(), 1);
        assert_eq!(token1.physical_pool_id(), 5001);
        assert!(registry16.is_valid_id(1));
        assert!(!registry16.is_valid_id(2));
        assert_eq!(registry16.allocated_count(), 1);

        assert_eq!(
            registry16.register(5001).unwrap_err(),
            CompactPoolError::AlreadyRegistered {
                physical_pool_id: 5001
            }
        );
    }

    #[test]
    fn test_registry_mutex_poisoning_recovery() {
        use std::sync::Arc;
        let registry = Arc::new(CompactPoolRegistryInstance::new());

        // Hilo que bloquea el mutex y entra en pánico intencionalmente
        let reg_clone = registry.clone();
        let handle = std::thread::spawn(move || {
            let _guard = reg_clone.registered_pools.lock().unwrap();
            panic!("pánico forzado para envenenar el mutex del registro");
        });
        assert!(
            handle.join().is_err(),
            "El hilo secundario debió entrar en pánico"
        );

        // El mutex está envenenado; la siguiente operación register no debe entrar en pánico,
        // sino recuperar el mutex, restaurar invariantes y registrar con éxito.
        let token = registry
            .register(9999)
            .expect("El registro debe recuperarse de mutex envenenado");
        assert_eq!(token.physical_pool_id(), 9999);
        assert!(registry.is_pool_registered(9999));

        // Registro de 16 bits también se recupera
        let registry16 = Arc::new(CompactPoolRegistryInstance16::new());
        let reg16_clone = registry16.clone();
        let handle16 = std::thread::spawn(move || {
            let _guard = reg16_clone.registered_pools.lock().unwrap();
            panic!("pánico forzado en registro16");
        });
        assert!(handle16.join().is_err());
        let token16 = registry16
            .register(8888)
            .expect("El registro16 debe recuperarse de mutex envenenado");
        assert_eq!(token16.physical_pool_id(), 8888);
        assert!(registry16.is_pool_registered(8888));
    }

    #[test]
    fn test_registry_mutex_poisoning_corrupted_invariants_fails_closed() {
        use std::sync::Arc;
        let registry = Arc::new(CompactPoolRegistryInstance::new());

        // Inyectar estado corrupto: dos pools físicos distintos con el mismo compact_id
        let reg_clone = registry.clone();
        let handle = std::thread::spawn(move || {
            let mut guard = reg_clone.registered_pools.lock().unwrap();
            guard.push(RegisteredPool8 {
                physical_pool_id: 111,
                compact_id: 1,
            });
            guard.push(RegisteredPool8 {
                physical_pool_id: 222,
                compact_id: 1, // Colisión de compact_id!
            });
            panic!("pánico con estado corrupto en registro");
        });
        assert!(handle.join().is_err());

        // Al intentar registrar sobre estado corrupto irrecuperable, debe fallar cerrado
        let err = registry.register(333).unwrap_err();
        assert_eq!(err, CompactPoolError::RegistryCorrupted);
        assert!(!registry.is_pool_registered(111));
        assert!(!registry.is_pool_registered(333));
    }
}
