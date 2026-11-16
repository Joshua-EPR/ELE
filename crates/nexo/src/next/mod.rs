//! NEXO v0.4: Subsistema experimental de optimización de memoria.
//!
//! Este módulo contiene los prototipos de la siguiente evolución arquitectónica:
//! - [`arena`]: Asignador de ámbito / pila de datos (`ScopedArena`) por avance de puntero.
//! - [`compact`]: Generaciones compactas de 16 bits y enlaces compactos de 4 bytes.
//! - [`optimize`]: Optimizaciones de revalidación en lote y hoisting de invariantes.

pub mod adapter;
pub mod arena;
pub mod compact;
pub mod optimize;

pub use adapter::{CompactPhysicalPool, CompactPhysicalPool64};
pub use arena::{
    ARENA_BASE_ALIGN, ArenaError, ArenaState, CloseScopeError, ScopeMarker, ScopedArena,
};
pub use compact::{
    CompactGen, CompactGenError, CompactLink, CompactLink64, CompactLinkError, CompactObjRef,
    CompactObjRef64, CompactPoolAuthority, CompactPoolAuthority64, CompactPoolError,
    CompactPoolRegistry, CompactPoolRegistry16, CompactPoolRegistryInstance,
    CompactPoolRegistryInstance16, CompactPoolToken, CompactPoolToken16, CompactRevalidateError,
    GEN_RETIRADO_8, GEN_RETIRADO_16, INVALID_COMPACT_POOL_ID, INVALID_COMPACT_POOL_ID_16,
    MAX_COMPACT_POOLS, MAX_COMPACT_POOLS_16, MAX_SLOT_COMPACT_32,
};
pub use optimize::{BatchRevalidator, HoistSafety};
