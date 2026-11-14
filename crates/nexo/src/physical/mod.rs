//! Memoria virtual física experimental de NEXO v0.3.
//!
//! Esta capa solo encapsula primitivas del sistema operativo. No modifica el
//! modelo abstracto, ELE-LIR, el ABI ni las reglas de ownership de ELE.

mod address_space;
mod generation;
mod oracle_adapter;
mod platform;
mod pool;

use std::fmt;

pub use address_space::{
    AddressSpace, AddressSpaceMetrics, DropReleaseDiagnostics, FaultOp, FaultOutcome, FaultPlan,
    OsCalls, PageAccess, drop_release_diagnostics,
};
pub use oracle_adapter::{Command, CommandResult, DifferentialHarness, DifferentialSnapshot};
pub use pool::{
    DestroyOutcome, DestroyReport, HEADER_USED, Handle, HeaderStatus, HoleToken, Link, ObjRef,
    PageState, PhysicalPool, PoolConfig, PoolError, PoolMetrics, ReclaimPolicy, ReclaimStatus,
    ReleaseReport, RepairReport,
};

/// Error de un cierre propietario. Devuelve el único dueño para que el
/// llamador pueda corregir la causa y reintentar sin reconstruir capacidad.
pub struct CloseFailure<T, E> {
    owner: T,
    error: E,
}

impl<T, E> CloseFailure<T, E> {
    pub(crate) fn new(owner: T, error: E) -> Self {
        Self { owner, error }
    }

    pub fn error(&self) -> &E {
        &self.error
    }

    pub fn owner(&self) -> &T {
        &self.owner
    }

    pub fn into_parts(self) -> (T, E) {
        (self.owner, self.error)
    }
}

impl<T, E: fmt::Debug> fmt::Debug for CloseFailure<T, E> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CloseFailure")
            .field("owner", &std::any::type_name::<T>())
            .field("error", &self.error)
            .finish()
    }
}

/// Error controlado de la capa de memoria virtual.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PhysicalError {
    UnsupportedPlatform(&'static str),
    UnsupportedPageSize {
        found: usize,
        required: usize,
    },
    InvalidAlignment {
        alignment: usize,
        granularity: usize,
    },
    InvalidRange,
    Overflow,
    Released,
    /// Un `release` real falló y la integridad de la reserva no puede
    /// suponerse. Solo es seguro reintentar el cierre.
    ReleaseUncertain,
    Uncommitted,
    Inaccessible,
    /// Fallo inyectado antes de llamar al SO: el estado externo no cambió.
    Injected(FaultOp),
    /// El plan parcial se usó en una ruta que solo admite fallos previos.
    InvalidFaultPlan(FaultOp),
    /// El rango completo cambió, pero la operación informó error.
    CompletedWithError(FaultOp),
    /// Solo un prefijo conocido del rango cambió.
    PartiallyApplied {
        op: FaultOp,
        applied: usize,
        total: usize,
    },
    /// No hay observación confiable del resultado físico.
    UnknownState(FaultOp),
    /// La página no puede exponerse hasta reconciliar su estado físico.
    Quarantined,
    Os {
        operation: &'static str,
        code: i32,
    },
}

impl fmt::Display for PhysicalError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedPlatform(platform) => {
                write!(
                    formatter,
                    "unsupported physical-memory platform: {platform}"
                )
            }
            Self::UnsupportedPageSize { found, required } => write!(
                formatter,
                "unsupported OS page size {found}; NEXO requires {required}"
            ),
            Self::InvalidAlignment {
                alignment,
                granularity,
            } => write!(
                formatter,
                "invalid alignment {alignment} for allocation granularity {granularity}"
            ),
            Self::InvalidRange => formatter.write_str("range is outside the reservation"),
            Self::Overflow => formatter.write_str("address-space arithmetic overflow"),
            Self::Released => formatter.write_str("address space has already been released"),
            Self::ReleaseUncertain => formatter.write_str(
                "address-space release had an uncertain result; only release retry is allowed",
            ),
            Self::Uncommitted => formatter.write_str("range contains an uncommitted page"),
            Self::Inaccessible => formatter.write_str("range contains an inaccessible page"),
            Self::Injected(op) => write!(formatter, "injected failure before {op:?}"),
            Self::InvalidFaultPlan(op) => {
                write!(formatter, "partial outcome is invalid for {op:?}")
            }
            Self::CompletedWithError(op) => {
                write!(formatter, "{op:?} completed but reported an error")
            }
            Self::PartiallyApplied { op, applied, total } => write!(
                formatter,
                "{op:?} changed {applied} of {total} pages before failing"
            ),
            Self::UnknownState(op) => {
                write!(formatter, "{op:?} left an ambiguous physical result")
            }
            Self::Quarantined => formatter.write_str("range contains a quarantined page"),
            Self::Os { operation, code } => {
                write!(formatter, "{operation} failed with OS error {code}")
            }
        }
    }
}

impl std::error::Error for PhysicalError {}
