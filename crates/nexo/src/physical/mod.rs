//! Memoria virtual física experimental de NEXO v0.3.
//!
//! Esta capa solo encapsula primitivas del sistema operativo. No modifica el
//! modelo abstracto, ELE-LIR, el ABI ni las reglas de ownership de ELE.

mod address_space;
mod platform;

use std::fmt;

pub use address_space::{AddressSpace, AddressSpaceMetrics};

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
    Uncommitted,
    Inaccessible,
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
            Self::Uncommitted => formatter.write_str("range contains an uncommitted page"),
            Self::Inaccessible => formatter.write_str("range contains an inaccessible page"),
            Self::Os { operation, code } => {
                write!(formatter, "{operation} failed with OS error {code}")
            }
        }
    }
}

impl std::error::Error for PhysicalError {}
