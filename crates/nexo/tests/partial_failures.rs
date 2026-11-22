//! PFS01–PFS12: resultados parciales o ambiguos por página.
//!
//! `Partial` y `CompletedWithError` ejecutan llamadas reales al kernel, una
//! página por vez, y simulan únicamente el resultado adversarial informado al
//! llamador. `Unknown` es una simulación conservadora: deliberadamente olvida
//! el estado observado y obliga a reconciliar antes de volver a exponer bytes.

use nexo::physical::{
    AddressSpace, DestroyOutcome, FaultOp, FaultPlan, PageAccess, PageState, PhysicalError,
    PhysicalPool, PoolConfig, PoolError, ReclaimStatus,
};

const PAGE: usize = 4 * 1024;
const SUPERPAGE: usize = 64 * 1024;
const PAGES: usize = 8;

fn space() -> AddressSpace {
    AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap()
}

fn pool() -> PhysicalPool {
    PhysicalPool::new(PoolConfig {
        max_superpages: 1,
        protect_before_discard: true,
        ..PoolConfig::default()
    })
    .unwrap()
}

fn assert_quarantined(space: &AddressSpace, first: usize, count: usize) {
    for page in first..first + count {
        assert_eq!(space.is_quarantined(page * PAGE), Ok(true), "page {page}");
        assert_eq!(
            space.page_access(page * PAGE),
            Ok(PageAccess::Protected),
            "la vista pública nunca debe ser más permisiva"
        );
    }
}

#[test]
fn pfs01_fallo_previo_no_cambia_ninguna_pagina() {
    let mut space = space();
    space.set_faults(FaultPlan::new().fail_nth(FaultOp::Commit, 1));
    assert_eq!(
        space.commit(0, PAGES * PAGE),
        Err(PhysicalError::Injected(FaultOp::Commit))
    );
    assert_eq!(space.quarantined_pages(), 0);
    assert_eq!(space.metrics().committed_bytes, 0);
    for page in 0..PAGES {
        assert_eq!(space.page_access(page * PAGE), Ok(PageAccess::Reserved));
    }
}

#[test]
fn pfs02_commit_parcial_cuarentena_el_rango_completo() {
    let mut space = space();
    space.set_faults(FaultPlan::new().partial_nth(FaultOp::Commit, 1, 3));
    assert_eq!(
        space.commit(0, PAGES * PAGE),
        Err(PhysicalError::PartiallyApplied {
            op: FaultOp::Commit,
            applied: 3,
            total: PAGES,
        })
    );
    assert_eq!(space.metrics().committed_bytes, 3 * PAGE);
    assert_eq!(space.metrics().accessible_bytes, 0);
    assert_eq!(space.metrics().quarantined_bytes, PAGES * PAGE);
    assert_quarantined(&space, 0, PAGES);
    assert_eq!(space.peek(0, &mut [0]), Err(PhysicalError::Quarantined));
}

#[test]
fn pfs03_proteccion_parcial_no_expone_el_sufijo() {
    let mut space = space();
    space.commit(0, PAGES * PAGE).unwrap();
    space.fill(0, PAGES * PAGE, 0xA5).unwrap();
    space.set_faults(FaultPlan::new().partial_nth(FaultOp::Protect, 1, 2));
    assert!(matches!(
        space.protect_none(0, PAGES * PAGE),
        Err(PhysicalError::PartiallyApplied {
            op: FaultOp::Protect,
            applied: 2,
            total: PAGES
        })
    ));
    assert_quarantined(&space, 0, PAGES);
    assert_eq!(space.write(7 * PAGE, &[1]), Err(PhysicalError::Quarantined));
    assert_eq!(space.reconcile(0, PAGES * PAGE), Ok(PAGES));
    assert_eq!(space.quarantined_pages(), 0);
    for page in 0..PAGES {
        assert_eq!(space.page_access(page * PAGE), Ok(PageAccess::Protected));
    }
}

#[test]
fn pfs04_descarte_parcial_se_reconcilia_pagina_a_pagina() {
    let mut space = space();
    space.commit(0, PAGES * PAGE).unwrap();
    space.set_protect_before_discard(true);
    space.set_faults(FaultPlan::new().partial_nth(FaultOp::Decommit, 1, 5));
    assert_eq!(
        space.decommit(0, PAGES * PAGE),
        Err(PhysicalError::PartiallyApplied {
            op: FaultOp::Decommit,
            applied: 5,
            total: PAGES,
        })
    );
    assert_eq!(space.metrics().committed_bytes, 3 * PAGE);
    assert_quarantined(&space, 0, PAGES);
    assert_eq!(space.reconcile(0, PAGES * PAGE), Ok(PAGES));
    assert_eq!(space.metrics().committed_bytes, PAGES * PAGE);
    assert_eq!(space.metrics().accessible_bytes, 0);
}

#[test]
fn pfs05_recommit_parcial_conserva_cuarentena_hasta_reconciliar() {
    let mut space = space();
    space.commit(0, PAGES * PAGE).unwrap();
    space.decommit(0, PAGES * PAGE).unwrap();
    space.set_faults(FaultPlan::new().partial_nth(FaultOp::Recommit, 1, 4));
    assert_eq!(
        space.commit(0, PAGES * PAGE),
        Err(PhysicalError::PartiallyApplied {
            op: FaultOp::Recommit,
            applied: 4,
            total: PAGES,
        })
    );
    assert_quarantined(&space, 0, PAGES);
    assert_eq!(space.reconcile(0, PAGES * PAGE), Ok(PAGES));
    assert_eq!(space.quarantined_pages(), 0);
}

#[test]
fn pfs06_exito_fisico_con_error_se_distingue_del_fallo_previo() {
    let mut space = space();
    space.set_faults(FaultPlan::new().complete_then_error_nth(FaultOp::Commit, 1));
    assert_eq!(
        space.commit(0, PAGES * PAGE),
        Err(PhysicalError::CompletedWithError(FaultOp::Commit))
    );
    assert_eq!(space.metrics().committed_bytes, PAGES * PAGE);
    assert_eq!(space.metrics().accessible_bytes, 0);
    assert_quarantined(&space, 0, PAGES);
    assert_eq!(space.reconcile(0, PAGES * PAGE), Ok(PAGES));
}

#[test]
fn pfs07_resultado_ambiguo_no_presume_estado_fisico() {
    let mut space = space();
    space.set_faults(FaultPlan::new().unknown_nth(FaultOp::Commit, 1));
    assert_eq!(
        space.commit(0, PAGES * PAGE),
        Err(PhysicalError::UnknownState(FaultOp::Commit))
    );
    assert_eq!(space.metrics().committed_bytes, 0);
    assert_quarantined(&space, 0, PAGES);
    assert_eq!(space.reconcile(0, PAGES * PAGE), Ok(PAGES));
    assert_eq!(space.metrics().committed_bytes, PAGES * PAGE);
}

#[test]
fn pfs08_reconciliacion_fallida_es_reintentable() {
    let mut space = space();
    space.set_faults(FaultPlan::new().unknown_nth(FaultOp::Commit, 1));
    assert!(space.commit(0, PAGES * PAGE).is_err());
    space.set_faults(FaultPlan::new().fail_always(FaultOp::Recommit));
    assert_eq!(
        space.reconcile(0, PAGES * PAGE),
        Err(PhysicalError::Injected(FaultOp::Recommit))
    );
    assert_eq!(space.quarantined_pages(), PAGES);
    space.faults_mut().stop_failing(FaultOp::Recommit);
    assert_eq!(space.reconcile(0, PAGES * PAGE), Ok(PAGES));
}

#[test]
fn pfs09_solo_el_subrango_afectado_queda_en_cuarentena() {
    let mut space = space();
    space.commit(0, PAGES * PAGE).unwrap();
    space.set_faults(FaultPlan::new().partial_nth(FaultOp::Protect, 1, 1));
    assert!(space.protect_none(2 * PAGE, 4 * PAGE).is_err());
    assert_eq!(space.quarantined_pages(), 4);
    assert_eq!(space.write(0, &[9]), Ok(()));
    assert_eq!(space.write(7 * PAGE, &[7]), Ok(()));
    assert_eq!(space.write(3 * PAGE, &[3]), Err(PhysicalError::Quarantined));
    assert_quarantined(&space, 2, 4);
}

#[test]
fn pfs10_reconciliar_y_reconfirmar_habilita_reutilizacion_segura() {
    let mut space = space();
    space.set_faults(FaultPlan::new().partial_nth(FaultOp::Commit, 1, 2));
    assert!(space.commit(0, PAGES * PAGE).is_err());
    space.reconcile(0, PAGES * PAGE).unwrap();
    space.commit(0, PAGES * PAGE).unwrap();
    space.fill(0, PAGES * PAGE, 0x5A).unwrap();
    let mut byte = [0];
    space.peek(7 * PAGE, &mut byte).unwrap();
    assert_eq!(byte, [0x5A]);
}

#[test]
fn pfs11_release_fallido_preserva_cuarentena_y_es_reintentable() {
    let mut space = space();
    space.set_faults(FaultPlan::new().unknown_nth(FaultOp::Commit, 1));
    assert!(space.commit(0, PAGES * PAGE).is_err());
    space.set_faults(FaultPlan::new().fail_nth(FaultOp::Release, 1));
    assert_eq!(
        space.release(),
        Err(PhysicalError::Injected(FaultOp::Release))
    );
    assert_eq!(space.quarantined_pages(), PAGES);
    assert_ne!(space.base_addr(), 0);
    assert_eq!(space.release(), Ok(()));
    assert_eq!(space.base_addr(), 0);
    assert_eq!(space.quarantined_pages(), 0);
}

#[test]
fn pfs12_conteo_y_limites_del_prefijo_son_deterministas() {
    let mut space = space();
    space.set_faults(
        FaultPlan::new()
            .partial_nth(FaultOp::Commit, 1, PAGES + 10)
            .unknown_nth(FaultOp::Recommit, 1),
    );
    assert_eq!(
        space.commit(0, PAGES * PAGE),
        Err(PhysicalError::CompletedWithError(FaultOp::Commit)),
        "un prefijo que cubre todo el rango no se publica como parcial"
    );
    assert_eq!(space.faults().count(FaultOp::Commit), 1);
    space.reconcile(0, PAGES * PAGE).unwrap();
    assert_eq!(
        space.commit(0, PAGES * PAGE),
        Err(PhysicalError::UnknownState(FaultOp::Recommit)),
        "tras reconciliar, la segunda operación es Recommit, no Commit"
    );
}

#[test]
fn pfs09b_enlaces_obsoletos_siguen_muertos_durante_cuarentena() {
    let mut pool = pool();
    let handle = pool.allocate().unwrap();
    let (slot, link, object) = (handle.slot(), handle.link(), handle.obj());
    pool.write_int(object, 0, 0x1234).unwrap();
    pool.set_faults(FaultPlan::new().complete_then_error_nth(FaultOp::Decommit, 1))
        .unwrap();
    let report = pool.destroy(handle, false).unwrap();
    assert!(matches!(
        report.reclaim,
        ReclaimStatus::Pending {
            error: PhysicalError::CompletedWithError(FaultOp::Decommit),
            access: PageAccess::Protected,
        }
    ));
    assert_eq!(pool.page_state(slot), Ok(PageState::Quarantined));
    assert_eq!(pool.revalidate(link), Err(PoolError::StaleGeneration));
    assert_eq!(pool.read_int(object, 0), Err(PoolError::StaleGeneration));
    pool.check_invariants().unwrap();

    assert_eq!(pool.repair().unwrap().reclaimed, 1);
    assert_eq!(pool.page_state(slot), Ok(PageState::Returned));
    assert_eq!(pool.revalidate(link), Err(PoolError::StaleGeneration));
    pool.check_invariants().unwrap();
}

#[test]
fn pfs10b_hueco_lineal_se_consume_una_vez_ante_error_despues_de_exito() {
    let mut pool = pool();
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let DestroyOutcome::Hole(token) = pool.destroy(handle, true).unwrap().outcome else {
        panic!("se esperaba un hueco lineal")
    };
    pool.set_faults(FaultPlan::new().complete_then_error_nth(FaultOp::Decommit, 1))
        .unwrap();
    let report = pool.release_hole(token).unwrap();
    assert!(matches!(
        report.reclaim,
        ReclaimStatus::Pending {
            error: PhysicalError::CompletedWithError(FaultOp::Decommit),
            ..
        }
    ));
    assert_eq!(pool.hole_count(), 0, "release_hole consumió el token");
    assert_eq!(pool.page_state(slot), Ok(PageState::Quarantined));
    pool.check_invariants().unwrap();
    assert_eq!(pool.repair().unwrap().reclaimed, 1);
    assert_eq!(pool.page_state(slot), Ok(PageState::Returned));
    pool.check_invariants().unwrap();
}

#[test]
fn pfs11b_close_libera_un_pool_con_estado_fisico_ambiguo() {
    let mut pool = pool();
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    pool.set_faults(FaultPlan::new().unknown_nth(FaultOp::Decommit, 1))
        .unwrap();
    let report = pool.destroy(handle, false).unwrap();
    assert!(matches!(
        report.reclaim,
        ReclaimStatus::Pending {
            error: PhysicalError::UnknownState(FaultOp::Decommit),
            ..
        }
    ));
    assert_eq!(pool.page_state(slot), Ok(PageState::Quarantined));
    pool.check_invariants().unwrap();
    pool.close().unwrap();
    assert_eq!(pool.base_addr(), Err(PoolError::Closed));
    assert_eq!(pool.pending_reclaims(), 0);
}

#[test]
fn pfs12b_invariantes_sobreviven_error_despues_de_exito_y_repair() {
    let mut pool = pool();
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    pool.set_faults(FaultPlan::new().complete_then_error_nth(FaultOp::Decommit, 1))
        .unwrap();
    let report = pool.destroy(handle, false).unwrap();
    assert!(matches!(
        report.reclaim,
        ReclaimStatus::Pending {
            error: PhysicalError::CompletedWithError(FaultOp::Decommit),
            ..
        }
    ));
    assert_eq!(pool.page_state(slot), Ok(PageState::Quarantined));
    pool.check_invariants().unwrap();
    let repaired = pool.repair().unwrap();
    assert_eq!((repaired.reclaimed, repaired.still_pending), (1, 0));
    assert_eq!(pool.page_state(slot), Ok(PageState::Returned));
    pool.check_invariants().unwrap();
}
