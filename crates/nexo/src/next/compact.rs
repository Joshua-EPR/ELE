//! Generaciones compactas (16 bits y 8 bits) y Enlaces compactos (4 bytes).
//!
//! Permite reducir la sobrecarga de memoria de 8 bytes por enlace a 4 bytes,
//! e implementar ciclos de vida compactos en pools de tamaño limitado preservando
//! estrictamente la inmunidad ante problemas ABA y colisiones de identidad.

pub const GEN_RETIRADO_16: u16 = 0xfffe;
pub const GEN_RETIRADO_8: u8 = 0xfe;
pub const MAX_SLOT_COMPACT_32: u32 = 0xffff; // 16 bits = 65.535 slots por pool compacto de 4 bytes

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
        if current == GEN_RETIRADO_8 {
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
        if current == GEN_RETIRADO_8 {
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
        g != GEN_RETIRADO_8 && !g.is_multiple_of(2)
    }

    /// Comprueba si la generación de 8 bits está retirada permanentemente.
    pub fn is_retired_8(g: u8) -> bool {
        g == GEN_RETIRADO_8
    }
}

/// Errores en la creación de enlaces compactos.
#[derive(Debug, Eq, PartialEq)]
pub enum CompactLinkError {
    SlotOverflow,
    GenerationRetired,
    InvalidState,
}

/// Enlace generacional compacto de 4 bytes (32 bits).
///
/// Codificación interna (32 bits exactos):
/// - Bits 0..15 (16 bits): Índice de slot dentro del pool (0..65.535).
/// - Bits 16..23 (8 bits): Generación compacta de vida (1..253).
/// - Bits 24..31 (8 bits): Identificador de pool de origen (0..255).
///
/// Garantía contra colisiones ABA:
/// Al restringir la generación a 8 bits con retiro definitivo en 254 (`GEN_RETIRADO_8`),
/// los valores impares vivos jamás sufren wraparound ni colisionan (por ejemplo, gen 1 y gen 257),
/// garantizando que un enlace antiguo jamás puede revalidar con un objeto posterior.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct CompactLink(u32);

impl CompactLink {
    /// Empaqueta `pool_id`, `slot` y `generation` en 4 bytes.
    pub fn new(pool_id: u8, slot: u32, generation: u16) -> Result<Self, CompactLinkError> {
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

    /// Identificador de pool de origen (0..255).
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

    /// Comprueba si este enlace compacto coincide estrictamente con el pool y la generación del slot.
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
