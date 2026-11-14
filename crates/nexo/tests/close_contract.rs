//! Contrato propietario de cierre: un fallo nunca consume silenciosamente al
//! único dueño de la reserva o del pool.

use nexo::physical::{
    AddressSpace, FaultOp, FaultPlan, PhysicalError, PhysicalPool, PoolConfig, PoolError,
    drop_release_diagnostics,
};

const SUPERPAGE: usize = 64 * 1024;

#[test]
fn address_space_try_close_consumes_only_after_success() {
    let space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
    assert!(space.try_close().is_ok());
}

#[test]
fn address_space_try_close_returns_owner_for_retry() {
    let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
    space.set_faults(FaultPlan::new().fail_nth(FaultOp::Release, 1));
    let failure = match space.try_close() {
        Ok(()) => panic!("el primer release debía fallar"),
        Err(failure) => failure,
    };
    assert_eq!(failure.error(), &PhysicalError::Injected(FaultOp::Release));
    let (space, _) = (*failure).into_parts();
    assert!(space.try_close().is_ok());
}

#[test]
fn resultado_ambiguo_de_release_bloquea_todo_salvo_reintento() {
    let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
    space.set_faults(FaultPlan::new().unknown_nth(FaultOp::Release, 1));
    let failure = match space.try_close() {
        Ok(()) => panic!("release debía quedar ambiguo"),
        Err(failure) => failure,
    };
    assert_eq!(
        failure.error(),
        &PhysicalError::UnknownState(FaultOp::Release)
    );
    let (mut space, _) = (*failure).into_parts();
    assert_eq!(space.page_access(0), Err(PhysicalError::ReleaseUncertain));
    assert_eq!(
        space.commit(0, 4 * 1024),
        Err(PhysicalError::ReleaseUncertain)
    );
    space.set_faults(FaultPlan::new());
    assert!(space.try_close().is_ok());
}

#[test]
fn pool_try_close_returns_live_owner_instead_of_hiding_leak() {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let handle = pool.allocate().unwrap();
    let failure = match pool.try_close() {
        Ok(()) => panic!("un pool con un Handle vivo no puede cerrarse"),
        Err(failure) => failure,
    };
    assert!(matches!(
        failure.error(),
        PoolError::Leak { live: 1, holes: 0 }
    ));
    let (mut pool, _) = (*failure).into_parts();
    pool.destroy(handle, false).unwrap();
    assert!(pool.try_close().is_ok());
}

#[test]
fn pool_try_close_returns_owner_with_linear_hole() {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let handle = pool.allocate().unwrap();
    let report = pool.destroy(handle, true).unwrap();
    let nexo::physical::DestroyOutcome::Hole(hole) = report.outcome else {
        panic!("se esperaba un hueco lineal")
    };
    let failure = match pool.try_close() {
        Ok(()) => panic!("un pool con HoleToken pendiente no puede cerrarse"),
        Err(failure) => failure,
    };
    assert!(matches!(
        failure.error(),
        PoolError::Leak { live: 0, holes: 1 }
    ));
    let (mut pool, _) = (*failure).into_parts();
    pool.release_hole(hole).unwrap();
    assert!(pool.try_close().is_ok());
}

#[test]
fn pool_ambiguo_no_publica_capacidades_y_conserva_reintento() {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    pool.set_faults(FaultPlan::new().unknown_nth(FaultOp::Release, 1))
        .unwrap();
    let failure = match pool.try_close() {
        Ok(()) => panic!("release del pool debía quedar ambiguo"),
        Err(failure) => failure,
    };
    assert_eq!(
        failure.error(),
        &PoolError::Physical(PhysicalError::UnknownState(FaultOp::Release))
    );
    let (mut pool, _) = (*failure).into_parts();
    assert_eq!(
        pool.allocate(),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    pool.set_faults(FaultPlan::new()).unwrap();
    assert!(pool.try_close().is_ok());
}

#[test]
fn drop_reintenta_acotadamente_y_registra_fallo_terminal() {
    let before = drop_release_diagnostics();
    {
        let mut space = AddressSpace::reserve(SUPERPAGE, SUPERPAGE).unwrap();
        space.set_faults(FaultPlan::new().fail_always(FaultOp::Release));
    }
    let after = drop_release_diagnostics();
    assert_eq!(after.terminal_failures, before.terminal_failures + 1);
    assert_eq!(
        after.possibly_leaked_bytes,
        before.possibly_leaked_bytes + SUPERPAGE as u64
    );
}
