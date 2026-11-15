//! NEXO v0.4: Subsistema experimental de optimización de memoria.
//!
//! Este módulo contiene los prototipos de la siguiente evolución arquitectónica:
//! - [`arena`]: Asignador de ámbito / pila de datos (`ScopedArena`) por avance de puntero.
//! - [`compact`]: Generaciones compactas de 16 bits y enlaces compactos de 4 bytes.
//! - [`optimize`]: Optimizaciones de revalidación en lote y hoisting de invariantes.

pub mod arena;
pub mod compact;
pub mod optimize;

pub use arena::{ArenaError, ScopeMarker, ScopedArena};
pub use compact::{
    CompactGen, CompactGenError, CompactLink, CompactLinkError, GEN_RETIRADO_16, MAX_SLOT_COMPACT,
};
pub use optimize::{BatchRevalidator, HoistSafety};
