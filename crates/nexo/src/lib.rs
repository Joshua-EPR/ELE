//! # NEXO v0.2 — modelo de memoria de ELE
//!
//! Núcleo aislado (Etapa 2) del modelo de memoria basado en permisos
//! estáticos, referencias generacionales con metadatos Bi-Slab y efectos de
//! invalidación monotónicos. No depende del compilador ni del backend: la
//! integración en ELE-LIR (`--memory-model=nexo`) es la Etapa 4.
//!
//! * [`ir`]: NEXO-Core, IR tipada mínima.
//! * [`verif`]: verificador estático (R1–R9, C1–C6), inferencia de efectos y
//!   elaboración (drop flags, huecos, niveles de acceso).
//! * [`rt`]: máquina abstracta con pools Bi-Slab y oráculo de seguridad.

pub mod diag;
pub mod fuzz;
pub mod ir;
pub mod physical;
pub mod pretty;
pub mod rt;
pub mod verif;

pub use diag::{Diagnostico, Regla};
pub use verif::{ProgramaVerificado, verificar};
