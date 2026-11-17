//! Pruebas de optimizaciones de revalidación en lote y análisis de hoisting.

use nexo::next::optimize::{BatchRevalidator, HoistSafety, LoopHoistAnalyzer};
use nexo::physical::{PhysicalPool, PoolConfig};

#[test]
fn test_batch_revalidation_with_real_pool() {
    let mut pool = PhysicalPool::new(PoolConfig {
        slot_size: 64,
        fields: 2,
        max_superpages: 1,
        ..PoolConfig::default()
    })
    .unwrap();

    let h1 = pool.allocate().unwrap();
    let h2 = pool.allocate().unwrap();
    let h3 = pool.allocate().unwrap();

    let l1 = h1.link();
    let l2 = h2.link();
    let l3 = h3.link();

    // Destruir h2 (debe quedar obsoleto)
    pool.destroy(h2, false).unwrap();

    let links = vec![l1, l2, l3];
    let (mask, result) = BatchRevalidator::validate_batch(&links, |p_id, slot| {
        if p_id == pool.id() {
            pool.generation(slot).ok()
        } else {
            None
        }
    });

    assert_eq!(result.total, 3);
    assert_eq!(result.valid_count, 2);
    assert_eq!(result.stale_count, 1);
    assert_eq!(mask, vec![true, false, true]);

    pool.destroy(h1, false).unwrap();
    pool.destroy(h3, false).unwrap();
    pool.close().unwrap();
}

#[test]
fn test_loop_hoist_safety_analysis() {
    let pool_a = 100u64;
    let pool_b = 200u64;

    // Caso 1: Bucle muta pool_b, pero no pool_a -> Seguro elevar revalidación de pool_a
    let safety1 = LoopHoistAnalyzer::can_hoist(pool_a, &[pool_b], false);
    assert_eq!(safety1, HoistSafety::SafeToHoist);

    // Caso 2: Bucle muta pool_a -> Inseguro elevar revalidación de pool_a
    let safety2 = LoopHoistAnalyzer::can_hoist(pool_a, &[pool_a, pool_b], false);
    assert_eq!(safety2, HoistSafety::MustRemainInLoop);

    // Caso 3: Bucle contiene llamadas opacas -> Inseguro por tratamiento conservador
    let safety3 = LoopHoistAnalyzer::can_hoist(pool_a, &[], true);
    assert_eq!(safety3, HoistSafety::MustRemainInLoop);
}
