//! Operaciones de generación que no permiten wraparound ni resurrección.

use crate::rt::pool::GEN_RETIRADO;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GenerationError {
    InvalidInitial,
    NotLive,
    Retired,
}

pub fn validate_initial(generation: u32) -> Result<(), GenerationError> {
    if generation & 1 != 0 || generation >= GEN_RETIRADO {
        Err(GenerationError::InvalidInitial)
    } else {
        Ok(())
    }
}

/// Convierte una generación libre par en una generación viva impar.
pub fn allocate(free: u32) -> Result<u32, GenerationError> {
    if free == GEN_RETIRADO {
        return Err(GenerationError::Retired);
    }
    if free & 1 != 0 || free >= GEN_RETIRADO {
        return Err(GenerationError::NotLive);
    }
    free.checked_add(1).ok_or(GenerationError::Retired)
}

/// Invalida una generación viva. `GEN_RETIRADO` permanece fuera de toda
/// lista libre y nunca vuelve a incrementarse.
pub fn destroy(live: u32) -> Result<u32, GenerationError> {
    if live & 1 == 0 || live >= GEN_RETIRADO {
        return Err(GenerationError::NotLive);
    }
    live.checked_add(1).ok_or(GenerationError::Retired)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn par_impar_y_retiro_sin_wraparound() {
        assert_eq!(allocate(0), Ok(1));
        assert_eq!(destroy(1), Ok(2));
        assert_eq!(allocate(GEN_RETIRADO - 2), Ok(GEN_RETIRADO - 1));
        assert_eq!(destroy(GEN_RETIRADO - 1), Ok(GEN_RETIRADO));
        assert_eq!(allocate(GEN_RETIRADO), Err(GenerationError::Retired));
        assert_eq!(destroy(u32::MAX), Err(GenerationError::NotLive));
    }
}
