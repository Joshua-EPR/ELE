//! Optimizaciones de revalidación en lote y elevación de invariantes (*hoisting*).
//!
//! Permite amortizar los accesos a metadatos al validar múltiples enlaces en un solo
//! barrido y modelar la elevación estática de comprobaciones de enlaces fuera de bucles
//! cuando el análisis de efectos certifica ausencia de mutaciones invalidantes.

use crate::physical::Link;

/// Resultado de la revalidación en lote.
#[derive(Debug, Eq, PartialEq)]
pub struct BatchResult {
    pub total: usize,
    pub valid_count: usize,
    pub stale_count: usize,
}

/// Validador de enlaces en lote.
pub struct BatchRevalidator;

impl BatchRevalidator {
    /// Revalida un lote de enlaces contra una función de consulta de generación.
    ///
    /// Retorna una máscara booleana (`true` si el enlace sigue siendo válido) y un
    /// resumen estadístico de la operación.
    pub fn validate_batch<F>(links: &[Link], mut get_current_gen: F) -> (Vec<bool>, BatchResult)
    where
        F: FnMut(u64, u32) -> Option<u32>,
    {
        let mut mask = Vec::with_capacity(links.len());
        let mut valid_count = 0;
        let mut stale_count = 0;

        for link in links {
            let pool_id = link.pool();
            let slot = link.slot();
            let expected_gen = link.generation();

            let is_valid = match get_current_gen(pool_id, slot) {
                Some(current_gen) => current_gen == expected_gen && current_gen % 2 != 0,
                None => false,
            };

            if is_valid {
                valid_count += 1;
            } else {
                stale_count += 1;
            }
            mask.push(is_valid);
        }

        (
            mask,
            BatchResult {
                total: links.len(),
                valid_count,
                stale_count,
            },
        )
    }
}

/// Clasificación de seguridad para la elevación de revalidaciones fuera de un bucle.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum HoistSafety {
    /// Seguro para elevar fuera del bucle: el cuerpo no muta ni invalida el pool.
    SafeToHoist,
    /// Inseguro: el cuerpo contiene operaciones de destrucción, sellado o llamadas opacas.
    MustRemainInLoop,
}

/// Analizador de seguridad para la elevación de comprobaciones de revalidación.
pub struct LoopHoistAnalyzer;

impl LoopHoistAnalyzer {
    /// Determina si una revalidación sobre el pool `target_pool` puede ser elevada
    /// fuera del bucle con los efectos indicados en el cuerpo.
    ///
    /// Si el bucle realiza destrucción (`has_destroy`), reestructuración (`has_reorder`)
    /// o llamadas opacas sin contrato (`has_opaque_calls`) sobre `target_pool`,
    /// la comprobación NO puede ser extraída del bucle.
    pub fn can_hoist(
        target_pool: u64,
        mutated_pools: &[u64],
        has_opaque_calls: bool,
    ) -> HoistSafety {
        if has_opaque_calls {
            return HoistSafety::MustRemainInLoop;
        }
        if mutated_pools.contains(&target_pool) {
            return HoistSafety::MustRemainInLoop;
        }
        HoistSafety::SafeToHoist
    }
}
