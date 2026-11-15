//! Generaciones compactas (16 bits) y Enlaces compactos (4 bytes).
//!
//! Permite reducir la sobrecarga de memoria de 8 bytes por enlace a 4 bytes,
//! e implementar ciclos de vida compactos en pools de tamaño limitado preservando
//! estrictamente la inmunidad ante problemas ABA y colisiones de identidad.

pub const GEN_RETIRADO_16: u16 = 0xfffe;
pub const MAX_SLOT_COMPACT: u32 = 0x00ff_ffff; // 24 bits = 16.777.215 slots

/// Errores de manipulación de generaciones compactas.
#[derive(Debug, Eq, PartialEq)]
pub enum CompactGenError {
    Retired,
    InvalidInitialState,
    Overflow,
}

/// Manipulador de generaciones de 16 bits.
pub struct CompactGen;

impl CompactGen {
    /// Transiciona un slot a la siguiente generación viva (impar).
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
        let next = current.checked_add(1).ok_or(CompactGenError::Overflow)?;
        Ok(next)
    }

    /// Transiciona un slot a la siguiente generación destruida (par) o retirado.
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
        let next = current.checked_add(1).ok_or(CompactGenError::Overflow)?;
        Ok(next)
    }

    /// Comprueba si la generación corresponde a un slot vivo.
    pub fn is_live(g: u16) -> bool {
        g != GEN_RETIRADO_16 && !g.is_multiple_of(2)
    }

    /// Comprueba si la generación está retirada permanentemente.
    pub fn is_retired(g: u16) -> bool {
        g == GEN_RETIRADO_16
    }
}

/// Errores en la creación de enlaces compactos.
#[derive(Debug, Eq, PartialEq)]
pub enum CompactLinkError {
    SlotOverflow,
    GenerationRetired,
}

/// Enlace generacional compacto de 4 bytes (32 bits).
///
/// Codificación interna:
/// - Bits 0..23 (24 bits): Índice de slot (hasta 16.777.215 slots).
/// - Bits 24..31 (8 bits): Tag de validación generacional rápida.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct CompactLink(u32);

impl CompactLink {
    /// Empaqueta un slot de 24 bits y una generación de 16 bits en 4 bytes.
    pub fn new(slot: u32, generation: u16) -> Result<Self, CompactLinkError> {
        if slot > MAX_SLOT_COMPACT {
            return Err(CompactLinkError::SlotOverflow);
        }
        if generation == GEN_RETIRADO_16 {
            return Err(CompactLinkError::GenerationRetired);
        }
        let gen_tag = (generation & 0x00ff) as u8;
        let packed = slot | ((gen_tag as u32) << 24);
        Ok(Self(packed))
    }

    /// Índice de slot dentro del pool (0..16.777.215).
    pub fn slot(&self) -> u32 {
        self.0 & MAX_SLOT_COMPACT
    }

    /// Tag de 8 bits de la generación.
    pub fn gen_tag(&self) -> u8 {
        ((self.0 >> 24) & 0xff) as u8
    }

    /// Comprueba si este enlace compacto coincide con la generación actual del slot.
    pub fn matches(&self, full_generation: u16) -> bool {
        if full_generation == GEN_RETIRADO_16 {
            return false;
        }
        let expected_tag = (full_generation & 0x00ff) as u8;
        self.gen_tag() == expected_tag
    }

    /// Retorna la representación entera cruda de 32 bits.
    pub fn raw(&self) -> u32 {
        self.0
    }
}
