//! Generaciones compactas (16 bits y 8 bits) y Enlaces compactos (4 bytes y 8 bytes).
//!
//! Permite reducir la sobrecarga de memoria de 8/12 bytes por enlace a 4 u 8 bytes,
//! e implementar ciclos de vida compactos en pools de tamaño limitado preservando
//! estrictamente la inmunidad ante problemas ABA y colisiones de identidad.

use std::sync::atomic::{AtomicU8, Ordering};

pub const INVALID_COMPACT_POOL_ID: u8 = 0;
pub const MAX_COMPACT_POOLS: u8 = 255;
pub const GEN_RETIRADO_16: u16 = 0xfffe;
pub const GEN_RETIRADO_8: u8 = 0xfe;
pub const MAX_SLOT_COMPACT_32: u32 = 0xffff; // 16 bits = 65.535 slots por pool compacto de 4 bytes

/// Contador monotónico atómico de pools compactos asignados (0..=255).
/// 0 indica que ningún pool ha sido registrado aún.
static ALLOCATED_COMPACT_POOLS: AtomicU8 = AtomicU8::new(0);

/// Errores de asignación y registro de pools compactos.
#[derive(Debug, Eq, PartialEq)]
pub enum CompactPoolError {
    /// Se ha agotado el espacio de 255 identificadores únicos de pool compacto.
    /// Queda terminantemente prohibido el reciclaje o wraparound silencioso.
    PoolIdExhausted,
    InvalidPoolId,
}

/// Registro global seguro de identificadores de pools compactos de 8 bits.
pub struct CompactPoolRegistry;

impl CompactPoolRegistry {
    /// Reserva un nuevo identificador único de pool compacto (1..=255).
    ///
    /// Garantiza ausencia de reciclaje: una vez asignados los 255 identificadores,
    /// cualquier intento posterior retorna [`CompactPoolError::PoolIdExhausted`],
    /// impidiendo que un pool nuevo reutilice una identidad capaz de validar un enlace antiguo.
    pub fn acquire_id() -> Result<u8, CompactPoolError> {
        let mut current = ALLOCATED_COMPACT_POOLS.load(Ordering::Relaxed);
        loop {
            if current == MAX_COMPACT_POOLS {
                return Err(CompactPoolError::PoolIdExhausted);
            }
            let next = current + 1;
            match ALLOCATED_COMPACT_POOLS.compare_exchange_weak(
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

    /// Comprueba si un identificador se encuentra dentro del rango asignado legítimamente.
    ///
    /// Un identificador es válido si y solo si:
    /// 1. No es `INVALID_COMPACT_POOL_ID` (0).
    /// 2. Es menor o igual al número total de identificadores efectivamente emitidos.
    pub fn is_valid_id(id: u8) -> bool {
        id != INVALID_COMPACT_POOL_ID && id <= ALLOCATED_COMPACT_POOLS.load(Ordering::SeqCst)
    }

    /// Retorna la cantidad de identificadores de pool efectivamente emitidos hasta el momento.
    pub fn allocated_count() -> u8 {
        ALLOCATED_COMPACT_POOLS.load(Ordering::SeqCst)
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
        if current == GEN_RETIRADO_16 {
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
        if current == GEN_RETIRADO_16 {
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
        g != GEN_RETIRADO_16 && !g.is_multiple_of(2)
    }

    /// Comprueba si la generación de 16 bits está retirada permanentemente.
    pub fn is_retired(g: u16) -> bool {
        g == GEN_RETIRADO_16
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compact_pool_registry_invariants() {
        assert!(!CompactPoolRegistry::is_valid_id(INVALID_COMPACT_POOL_ID));
        let count = CompactPoolRegistry::allocated_count();
        if count == 0 {
            assert!(!CompactPoolRegistry::is_valid_id(1));
        } else {
            assert!(CompactPoolRegistry::is_valid_id(count));
        }
    }

    #[test]
    fn test_matches_representation_predicate() {
        let link = CompactLink::new(5, 100, 3).unwrap();
        assert!(link.matches(5, 3));
        assert!(!link.matches(6, 3));
        assert!(!link.matches(5, 4));
        assert!(!link.matches(5, 254));
    }
}
