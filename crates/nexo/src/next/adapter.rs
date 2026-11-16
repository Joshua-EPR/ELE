//! Adaptador experimental de enlace compacto sobre `PhysicalPool`.
//!
//! Conecta la representación de enlace compacto ([`CompactLink`], [`CompactLink64`])
//! con el subsistema de memoria física respaldado por páginas virtuales ([`PhysicalPool`]),
//! verificando estrictamente metadatos lógicos, estado de páginas (comprometidas, en cuarentena),
//! límites de slots y generaciones vivas, y vinculando el acceso al préstamo del pool.
//!
//! # Frontera de autoridad
//!
//! Conforme a la regla de no fabricación de capacidades de v0.3, este adaptador
//! no fabrica tipos propietarios (`Handle`) ni capacidades opacas (`ObjRef`) de v0.3.
//! La revalidación valida los metadatos físicos reales del pool y emite un
//! [`CompactObjRef`] acotado por la vida útil del préstamo (`'a`).

use super::compact::{
    CompactPoolAuthority, CompactPoolAuthority64, CompactPoolError, CompactPoolToken,
    CompactPoolToken16, CompactRevalidateError, GEN_RETIRADO_8, GEN_RETIRADO_16,
    MAX_SLOT_COMPACT_32, private,
};
use crate::physical::{PageState, PhysicalPool};

/// Adaptador de revalidación para enlaces compactos de 4 bytes sobre `PhysicalPool`.
pub struct CompactPhysicalPool<'a> {
    pool: &'a PhysicalPool,
    token: &'a CompactPoolToken,
}

impl<'a> std::fmt::Debug for CompactPhysicalPool<'a> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CompactPhysicalPool")
            .field("pool_id", &self.pool.id())
            .field("token", &self.token)
            .finish()
    }
}

impl<'a> CompactPhysicalPool<'a> {
    /// Construye un nuevo adaptador vinculando el pool físico con su token de autoridad legítimo.
    ///
    /// # Errores
    /// Retorna [`CompactPoolError::PoolMismatch`] si el token proporcionado no fue emitido
    /// específicamente para este `pool` (i.e. `token.physical_pool_id() != pool.id()`).
    pub fn new(
        pool: &'a PhysicalPool,
        token: &'a CompactPoolToken,
    ) -> Result<Self, CompactPoolError> {
        if token.physical_pool_id() != pool.id() {
            return Err(CompactPoolError::PoolMismatch);
        }
        Ok(Self { pool, token })
    }

    pub fn pool(&self) -> &'a PhysicalPool {
        self.pool
    }

    pub fn token(&self) -> &'a CompactPoolToken {
        self.token
    }
}

impl<'a> private::Sealed for CompactPhysicalPool<'a> {}

impl<'a> CompactPoolAuthority for CompactPhysicalPool<'a> {
    fn __seal_authority(&self, _: private::InternalSeal) {}

    fn compact_id(&self) -> u8 {
        self.token.id()
    }

    fn slot_capacity(&self) -> u32 {
        let pool_cap = self.pool.capacity();
        let max_compact = (MAX_SLOT_COMPACT_32 as u64) + 1;
        pool_cap.min(max_compact) as u32
    }

    fn current_compact_generation(&self, slot: u32) -> Result<u8, CompactRevalidateError> {
        let capacity = self.slot_capacity();
        if slot >= capacity {
            return Err(CompactRevalidateError::OutOfBounds);
        }

        // Verificar el estado de la subpágina en memoria física
        let page_state = self
            .pool
            .page_state(slot)
            .map_err(|_| CompactRevalidateError::OutOfBounds)?;

        // Rechazar páginas en cuarentena, no confirmadas o devueltas al SO
        match page_state {
            PageState::Committed => {}
            PageState::Quarantined => {
                return Err(CompactRevalidateError::SubpageQuarantined);
            }
            PageState::Reserved | PageState::ReclaimPending | PageState::Returned => {
                return Err(CompactRevalidateError::SlotNotAllocated);
            }
        }

        // Consultar la generación lógica de la tabla
        let generation_val = self
            .pool
            .generation(slot)
            .map_err(|_| CompactRevalidateError::OutOfBounds)?;

        if generation_val >= GEN_RETIRADO_8 as u32 {
            return Err(CompactRevalidateError::GenerationRetired);
        }

        if generation_val.is_multiple_of(2) {
            return Err(CompactRevalidateError::SlotNotAllocated);
        }

        Ok(generation_val as u8)
    }
}

/// Adaptador de revalidación para enlaces compactos de 8 bytes (64 bits) sobre `PhysicalPool`.
pub struct CompactPhysicalPool64<'a> {
    pool: &'a PhysicalPool,
    token: &'a CompactPoolToken16,
}

impl<'a> std::fmt::Debug for CompactPhysicalPool64<'a> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CompactPhysicalPool64")
            .field("pool_id", &self.pool.id())
            .field("token", &self.token)
            .finish()
    }
}

impl<'a> CompactPhysicalPool64<'a> {
    /// Construye un nuevo adaptador vinculando el pool físico con su token de autoridad de 16 bits.
    ///
    /// # Errores
    /// Retorna [`CompactPoolError::PoolMismatch`] si el token proporcionado no fue emitido
    /// específicamente para este `pool` (i.e. `token.physical_pool_id() != pool.id()`).
    pub fn new(
        pool: &'a PhysicalPool,
        token: &'a CompactPoolToken16,
    ) -> Result<Self, CompactPoolError> {
        if token.physical_pool_id() != pool.id() {
            return Err(CompactPoolError::PoolMismatch);
        }
        Ok(Self { pool, token })
    }

    pub fn pool(&self) -> &'a PhysicalPool {
        self.pool
    }

    pub fn token(&self) -> &'a CompactPoolToken16 {
        self.token
    }
}

impl<'a> private::Sealed for CompactPhysicalPool64<'a> {}

impl<'a> CompactPoolAuthority64 for CompactPhysicalPool64<'a> {
    fn __seal_authority(&self, _: private::InternalSeal) {}

    fn compact_id(&self) -> u16 {
        self.token.id()
    }

    fn slot_capacity(&self) -> u32 {
        u32::try_from(self.pool.capacity()).unwrap_or(u32::MAX)
    }

    fn current_compact_generation(&self, slot: u32) -> Result<u16, CompactRevalidateError> {
        let capacity = self.slot_capacity();
        if slot >= capacity {
            return Err(CompactRevalidateError::OutOfBounds);
        }

        let page_state = self
            .pool
            .page_state(slot)
            .map_err(|_| CompactRevalidateError::OutOfBounds)?;

        match page_state {
            PageState::Committed => {}
            PageState::Quarantined => {
                return Err(CompactRevalidateError::SubpageQuarantined);
            }
            PageState::Reserved | PageState::ReclaimPending | PageState::Returned => {
                return Err(CompactRevalidateError::SlotNotAllocated);
            }
        }

        let generation_val = self
            .pool
            .generation(slot)
            .map_err(|_| CompactRevalidateError::OutOfBounds)?;

        if generation_val >= GEN_RETIRADO_16 as u32 {
            return Err(CompactRevalidateError::GenerationRetired);
        }

        if generation_val.is_multiple_of(2) {
            return Err(CompactRevalidateError::SlotNotAllocated);
        }

        Ok(generation_val as u16)
    }
}
