//! A01–A12: Suite adversarial de verificación de atomicidad y contratos lineales.
//!
//! Verifica formalmente que:
//! - Las capacidades lineales (`Handle`, `HoleToken`) jamás se consumen parcialmente
//!   ni se retornan como `Err` tras una mutación destructiva.
//! - Los errores en Fase A (prevalidación) preservan el estado lógico y la validez
//!   de la capacidad intactos.
//! - Los errores posteriores al commit lógico (Fase B: espejo de cabecera o decommit)
//!   no alteran la irreversibilidad del consumo de la capacidad.
//! - Los contadores de seguridad (`live`, `holes`, `occupied`) no enmascaran
//!   subdesbordamientos ni inconsistencias mediante saturación.

use crate::physical::{
    DestroyOutcome, FaultOp, FaultPlan, Handle, HeaderStatus, HoleToken, PageState, PhysicalPool,
    PoolConfig, PoolError, ReclaimStatus,
};

fn test_pool(max_superpages: u32) -> PhysicalPool {
    PhysicalPool::new(PoolConfig {
        slot_size: 64,
        fields: 2,
        max_superpages,
        protect_before_discard: true,
        ..PoolConfig::default()
    })
    .unwrap()
}

// ----------------------------------------------------------------------------
// A01: Subdesbordamiento de live rechazado en Fase A sin tocar la generación
// ----------------------------------------------------------------------------
#[test]
fn a01_live_underflow_rejected_in_phase_a_without_mutating_generation() {
    let mut pool = test_pool(1);
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let gen_before = pool.generation(slot).unwrap();
    assert_eq!(pool.live_count(), 1);

    // Corromper el contador live a 0 simulando una inconsistencia
    pool.corrupt_live_for_test(0);

    // destroy debe fallar en Fase A por underflow de live
    let err = pool.destroy(handle, false);
    let (returned_handle, pool_err) = match err {
        Err((h, e)) => (h, e),
        Ok(_) => panic!("A01: destroy debió fallar por underflow de live"),
    };

    assert!(
        matches!(pool_err, PoolError::Invariant(_)),
        "A01: error esperado PoolError::Invariant, recibido: {pool_err:?}"
    );

    // La capacidad devuelta sigue intacta y la generación del slot NO fue alterada
    assert_eq!(pool.generation(slot).unwrap(), gen_before);
    assert_eq!(returned_handle.generation(), gen_before);
    assert_eq!(returned_handle.slot(), slot);

    // Restaurar live para completar la destrucción legítima
    pool.corrupt_live_for_test(1);
    let report = pool.destroy(returned_handle, false).unwrap();
    assert_eq!(report.outcome, DestroyOutcome::Free);
    assert_eq!(pool.live_count(), 0);
    assert_ne!(pool.generation(slot).unwrap(), gen_before);

    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A02: Subdesbordamiento de holes rechazado en Fase A sin consumir el hueco
// ----------------------------------------------------------------------------
#[test]
fn a02_holes_underflow_rejected_in_phase_a_without_consuming_token() {
    let mut pool = test_pool(1);
    let handle = pool.allocate().unwrap();
    let report = pool.destroy(handle, true).unwrap();
    let token = match report.outcome {
        DestroyOutcome::Hole(t) => t,
        _ => panic!("A02: se esperaba un HoleToken"),
    };
    assert_eq!(pool.hole_count(), 1);

    // Corromper holes a 0
    pool.corrupt_holes_for_test(0);

    // release_hole debe fallar en Fase A
    let (token, pool_err) = match pool.release_hole(token) {
        Err((t, e)) => (t, e),
        Ok(_) => panic!("A02: release_hole debió fallar por underflow de holes"),
    };
    assert!(
        matches!(pool_err, PoolError::Invariant(_)),
        "A02: error esperado PoolError::Invariant, recibido: {pool_err:?}"
    );

    // reuse_hole también debe fallar en Fase A
    let (token, pool_err) = match pool.reuse_hole(token) {
        Err((t, e)) => (t, e),
        Ok(_) => panic!("A02: reuse_hole debió fallar por underflow de holes"),
    };
    assert!(
        matches!(pool_err, PoolError::Invariant(_)),
        "A02: error esperado PoolError::Invariant, recibido: {pool_err:?}"
    );

    // Restaurar holes y reutilizar el token exitosamente
    pool.corrupt_holes_for_test(1);
    let handle = pool.reuse_hole(token).unwrap();
    assert_eq!(pool.hole_count(), 0);
    assert_eq!(pool.live_count(), 1);

    pool.destroy(handle, false).unwrap();
    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A03: Desbordamiento de live rechazado antes de publicar asignación o mutar slot
// ----------------------------------------------------------------------------
#[test]
fn a03_live_overflow_rejected_before_publishing_allocation() {
    let mut pool = test_pool(1);

    // Simular live == u64::MAX
    pool.corrupt_live_for_test(u64::MAX);

    let res = pool.allocate();
    assert!(
        matches!(res, Err(PoolError::OutOfSpace)),
        "A03: allocate debió fallar con OutOfSpace por overflow de live"
    );

    // Restaurar y verificar que el pool asigna normalmente
    pool.corrupt_live_for_test(0);
    let handle = pool.allocate().unwrap();
    assert_eq!(pool.live_count(), 1);

    pool.destroy(handle, false).unwrap();
    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A04: Desbordamiento de holes en destroy rechazado antes de invalidar el Handle
// ----------------------------------------------------------------------------
#[test]
fn a04_holes_overflow_rejected_before_invalidating_handle() {
    let mut pool = test_pool(1);
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let gen_before = pool.generation(slot).unwrap();

    // Simular holes == u64::MAX
    pool.corrupt_holes_for_test(u64::MAX);

    let (handle, err) = match pool.destroy(handle, true) {
        Err((h, e)) => (h, e),
        Ok(_) => panic!("A04: destroy con reserve_hole debió fallar con OutOfSpace"),
    };
    assert!(
        matches!(err, PoolError::OutOfSpace),
        "A04: error esperado OutOfSpace, recibido: {err:?}"
    );

    // El handle sigue vivo y su generación intacta
    assert_eq!(pool.generation(slot).unwrap(), gen_before);
    assert_eq!(handle.generation(), gen_before);

    // Restaurar holes y destruir normalmente
    pool.corrupt_holes_for_test(0);
    let report = pool.destroy(handle, false).unwrap();
    assert_eq!(report.outcome, DestroyOutcome::Free);

    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A05: Falla de metadatos (superpágina no inicializada) devuelve capacidad intacta
// ----------------------------------------------------------------------------
#[test]
fn a05_uninitialized_superpage_metadata_returns_capability_intact() {
    let mut pool = test_pool(2);
    // Superpágina 0 inicializada tras allocate
    let h0 = pool.allocate().unwrap();

    // Fabricar handle que apunta a la superpágina 1 (no inicializada aún)
    let fake_slot = pool.slots_per_superpage(); // Primer slot de superpágina 1
    let fake_handle = pool.craft_handle_for_test(fake_slot, 1);

    let (returned_h, err) = match pool.destroy(fake_handle, false) {
        Err((h, e)) => (h, e),
        Ok(_) => panic!("A05: destroy a superpágina no inicializada debió fallar"),
    };
    assert_eq!(returned_h.slot(), fake_slot);
    assert!(
        matches!(err, PoolError::StaleGeneration),
        "A05: error esperado StaleGeneration, recibido: {err:?}"
    );

    pool.destroy(h0, false).unwrap();
    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A06: Fallo en pre-commit deja la capacidad completamente válida y reutilizable
// ----------------------------------------------------------------------------
#[test]
fn a06_pre_commit_failure_preserves_token_for_subsequent_reuse() {
    let mut pool = test_pool(1);
    let h = pool.allocate().unwrap();
    let report = pool.destroy(h, true).unwrap();
    let token = match report.outcome {
        DestroyOutcome::Hole(t) => t,
        _ => panic!("A06: se esperaba HoleToken"),
    };

    // Provocar fallo previo en Fase A corrompiendo temporalmente holes a 0
    pool.corrupt_holes_for_test(0);
    let (token, err) = match pool.reuse_hole(token) {
        Err((t, e)) => (t, e),
        Ok(_) => panic!("A06: reuse_hole debió fallar en Fase A"),
    };
    assert!(matches!(err, PoolError::Invariant(_)));

    // El token sigue siendo completamente válido; restauramos el estado y lo reutilizamos
    pool.corrupt_holes_for_test(1);
    let h2 = pool.reuse_hole(token).unwrap();
    assert_eq!(pool.live_count(), 1);
    assert_eq!(pool.hole_count(), 0);

    pool.destroy(h2, false).unwrap();
    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A07: Fallo post-commit en espejo de cabecera nunca devuelve Err((cap, ...))
// ----------------------------------------------------------------------------
#[test]
fn a07_post_commit_header_failure_never_returns_err_capability() {
    let mut pool = test_pool(1);
    let h = pool.allocate().unwrap();
    let slot = h.slot();
    let gen_before = h.generation();

    // Inyectar fallo en HeaderWrite (ocurre en Fase B post-commit)
    pool.set_faults(FaultPlan::new().fail_always(FaultOp::HeaderWrite))
        .unwrap();

    // destroy con fallo en mirror DEBE devolver Ok(DestroyReport) con HeaderStatus::Stale
    let report = pool
        .destroy(h, false)
        .expect("A07: destroy debe retornar Ok incluso si la escritura física de cabecera falla");
    assert_eq!(report.outcome, DestroyOutcome::Free);
    assert!(
        matches!(report.header, HeaderStatus::Stale(_)),
        "A07: el estado de la cabecera debe ser Stale"
    );

    // El handle fue consumido de forma irreversible
    assert_ne!(pool.generation(slot).unwrap(), gen_before);
    assert_eq!(pool.live_count(), 0);

    // Quitar fallos y reparar cabecera
    pool.set_faults(FaultPlan::new()).unwrap();
    let rep = pool.repair().unwrap();
    assert_eq!(rep.headers_resynced, 1);
    pool.check_invariants().unwrap();

    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A08: Generación destruida rechazada por validate(), sin revalidación obsoleta
// ----------------------------------------------------------------------------
#[test]
fn a08_destroyed_generation_permanently_rejected() {
    let mut pool = test_pool(1);
    let h = pool.allocate().unwrap();
    let link = h.link();

    // Objeto revalidable antes de destruir
    assert!(pool.revalidate(link).is_ok());

    pool.destroy(h, false).unwrap();

    // Tras destrucción, revalidate y destroy son permanentemente rechazados
    assert!(matches!(
        pool.revalidate(link),
        Err(PoolError::StaleGeneration)
    ));

    // Nueva asignación en el mismo slot avanza a la siguiente generación impar
    let h2 = pool.allocate().unwrap();
    assert_eq!(h2.slot(), link.slot());
    assert!(h2.generation() > link.generation());

    // El enlace antiguo sigue siendo rechazado (protección contra ABA)
    assert!(matches!(
        pool.revalidate(link),
        Err(PoolError::StaleGeneration)
    ));

    pool.destroy(h2, false).unwrap();
    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A09: Consistencia de DensityIndex vs bitmaps verificada en todos los estados
// ----------------------------------------------------------------------------
#[test]
fn a09_density_index_consistency_across_alloc_free_and_holes() {
    let mut pool = test_pool(1);
    let mut handles = Vec::new();

    // Asignar 10 slots
    for _ in 0..10 {
        handles.push(pool.allocate().unwrap());
    }
    pool.check_invariants().unwrap();

    // Convertir 3 en huecos
    let mut tokens = Vec::new();
    for _ in 0..3 {
        let h = handles.pop().unwrap();
        let report = pool.destroy(h, true).unwrap();
        if let DestroyOutcome::Hole(t) = report.outcome {
            tokens.push(t);
        }
    }
    pool.check_invariants().unwrap();

    // Liberar 2 handles como Free ordinario
    for _ in 0..2 {
        let h = handles.pop().unwrap();
        pool.destroy(h, false).unwrap();
    }
    pool.check_invariants().unwrap();

    // Reutilizar 1 hueco
    let t = tokens.pop().unwrap();
    let revalidated_h = pool.reuse_hole(t).unwrap();
    handles.push(revalidated_h);
    pool.check_invariants().unwrap();

    // Liberar los huecos restantes a la lista libre
    for t in tokens {
        pool.release_hole(t).unwrap();
    }
    pool.check_invariants().unwrap();

    // Limpiar todos los handles
    for h in handles {
        pool.destroy(h, false).unwrap();
    }
    pool.check_invariants().unwrap();
    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A10: Espejo físico sucio: fallo en mirror no revierte la generación lógica
// ----------------------------------------------------------------------------
#[test]
fn a10_stale_mirror_failure_does_not_revert_logical_generation() {
    let mut pool = test_pool(1);
    let h = pool.allocate().unwrap();
    let slot = h.slot();

    pool.set_faults(FaultPlan::new().fail_always(FaultOp::HeaderWrite))
        .unwrap();

    let rep = pool.destroy(h, false).unwrap();
    assert!(matches!(rep.header, HeaderStatus::Stale(_)));

    // La generación lógica avanzó a valor par (destruido)
    let generation_val = pool.generation(slot).unwrap();
    assert_eq!(generation_val % 2, 0);

    // Restaurar y reparar
    pool.set_faults(FaultPlan::new()).unwrap();
    assert_eq!(pool.dirty_headers(), 1);
    let repair = pool.repair().unwrap();
    assert_eq!(repair.headers_resynced, 1);
    assert_eq!(pool.dirty_headers(), 0);
    pool.check_invariants().unwrap();

    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A11: Pending reclaim: fallo en decommit preserva la destrucción del handle
// ----------------------------------------------------------------------------
#[test]
fn a11_pending_reclaim_preserves_irreversible_destruction() {
    let mut pool = test_pool(1);
    // Asignar y luego liberar el único slot de la subpágina con fallo en decommit
    let h = pool.allocate().unwrap();
    let slot = h.slot();

    pool.set_faults(FaultPlan::new().fail_always(FaultOp::Decommit))
        .unwrap();

    let rep = pool.destroy(h, false).unwrap();
    assert_eq!(rep.outcome, DestroyOutcome::Free);
    assert!(
        matches!(rep.reclaim, ReclaimStatus::Pending { .. }),
        "A11: la reclamación debe quedar en estado Pending"
    );
    assert_eq!(pool.pending_reclaims(), 1);
    assert_eq!(pool.page_state(slot).unwrap(), PageState::ReclaimPending);

    // El objeto está irremediablemente destruido
    assert_eq!(pool.live_count(), 0);

    // Reparar tras eliminar el fallo
    pool.set_faults(FaultPlan::new()).unwrap();
    let repair = pool.repair().unwrap();
    assert_eq!(repair.reclaimed, 1);
    assert_eq!(pool.pending_reclaims(), 0);
    assert_eq!(pool.page_state(slot).unwrap(), PageState::Returned);
    pool.check_invariants().unwrap();

    pool.close().unwrap();
}

// ----------------------------------------------------------------------------
// A12: Campaña adversarial pseudo-aleatoria con validación de invariantes
// ----------------------------------------------------------------------------
#[test]
fn a12_differential_adversarial_invariants_campaign() {
    let mut pool = test_pool(2);
    let mut rng = 0x123456789abcdef0u64;
    let mut lcg = || {
        rng = rng.wrapping_mul(6364136223846793005).wrapping_add(1);
        rng
    };

    let mut live_handles: Vec<Handle> = Vec::new();
    let mut holes: Vec<HoleToken> = Vec::new();

    for _step in 0..300 {
        let op = lcg() % 5;
        match op {
            0 if live_handles.len() < 30 => {
                // Allocate
                if let Ok(h) = pool.allocate() {
                    live_handles.push(h);
                }
            }
            1 if !live_handles.is_empty() => {
                // Destroy as Free
                let idx = (lcg() as usize) % live_handles.len();
                let h = live_handles.swap_remove(idx);
                let _ = pool.destroy(h, false);
            }
            2 if !live_handles.is_empty() && holes.len() < 10 => {
                // Destroy as Hole
                let idx = (lcg() as usize) % live_handles.len();
                let h = live_handles.swap_remove(idx);
                if let Ok(report) = pool.destroy(h, true)
                    && let DestroyOutcome::Hole(token) = report.outcome
                {
                    holes.push(token);
                }
            }
            3 if !holes.is_empty() => {
                // Reuse Hole
                let idx = (lcg() as usize) % holes.len();
                let token = holes.swap_remove(idx);
                if let Ok(h) = pool.reuse_hole(token) {
                    live_handles.push(h);
                }
            }
            4 if !holes.is_empty() => {
                // Release Hole
                let idx = (lcg() as usize) % holes.len();
                let token = holes.swap_remove(idx);
                let _ = pool.release_hole(token);
            }
            _ => {
                // Read/Write verification on a random live handle
                if !live_handles.is_empty() {
                    let idx = (lcg() as usize) % live_handles.len();
                    let h = &live_handles[idx];
                    let val = (lcg() as i64) % 10000;
                    if pool.write_int(h.obj(), 0, val).is_ok() {
                        let read = pool.read_int(h.obj(), 0).unwrap();
                        assert_eq!(read, val);
                    }
                }
            }
        }
    }

    // Invariantes deben cumplirse al final de la secuencia
    pool.check_invariants().unwrap();

    // Limpiar todos los huecos y handles
    for t in holes {
        let _ = pool.release_hole(t);
    }
    for h in live_handles {
        let _ = pool.destroy(h, false);
    }

    pool.check_invariants().unwrap();
    pool.close().unwrap();
}
