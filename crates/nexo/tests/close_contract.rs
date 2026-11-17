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

#[test]
fn closed_pool_rejects_generation_page_state_and_physical_access() {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let link = handle.link();
    pool.destroy(handle, false).unwrap();
    assert!(pool.close().is_ok());

    // CLOSED-01: generation() devuelve PoolError::Closed
    assert_eq!(pool.generation(slot), Err(PoolError::Closed));

    // CLOSED-02: page_state() rechaza el pool cerrado
    assert_eq!(pool.page_state(slot), Err(PoolError::Closed));

    // CLOSED-03: physical_access() rechaza el pool cerrado
    assert_eq!(pool.physical_access(slot), Err(PoolError::Closed));

    // CLOSED-04: validate_superpage() rechaza el pool cerrado
    assert_eq!(pool.validate_superpage(0), Err(PoolError::Closed));

    // CLOSED-05: check_invariants() rechaza la inspección física de un pool cerrado
    assert_eq!(pool.check_invariants(), Err(PoolError::Closed));

    // Acceso posterior al cierre adicional
    assert_eq!(pool.revalidate(link), Err(PoolError::Closed));
    assert_eq!(pool.base_addr(), Err(PoolError::Closed));
    assert_eq!(pool.allocate(), Err(PoolError::Closed));

    // Doble cierre
    assert_eq!(pool.close(), Err(PoolError::Closed));
}

#[test]
fn release_uncertain_blocks_all_authority_and_revalidations() {
    // 1. Pool operativo antes del fallo
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    assert!(pool.is_operational());
    assert!(!pool.is_closed());
    assert!(!pool.is_release_uncertain());
    assert!(pool.ensure_operational().is_ok());

    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let link = handle.link();

    // Destruimos handle para permitir close sin leak
    pool.destroy(handle, false).unwrap();

    let dirty_before = pool.dirty_headers();
    let live_before = pool.live_count();
    let holes_before = pool.hole_count();

    // UNCERTAIN-01: Provocar una liberación incierta mediante el mecanismo adversarial existente
    pool.set_faults(FaultPlan::new().unknown_nth(FaultOp::Release, 1))
        .unwrap();
    let failure = match pool.try_close() {
        Ok(()) => panic!("release debía quedar ambiguo"),
        Err(failure) => failure,
    };
    assert_eq!(
        failure.error(),
        &PoolError::Physical(PhysicalError::UnknownState(FaultOp::Release))
    );
    let (mut pool, _) = (*failure).into_parts();

    // El pool NO está cerrado (space es Some), pero está en ReleaseUncertain y NO es operativo
    assert!(!pool.is_closed());
    assert!(pool.is_open());
    assert!(pool.is_release_uncertain());
    assert!(!pool.is_operational());
    assert_eq!(
        pool.ensure_operational(),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // UNCERTAIN-02: base_addr() rechaza la solicitud
    assert_eq!(
        pool.base_addr(),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // UNCERTAIN-03: generation() rechaza la solicitud
    assert_eq!(
        pool.generation(slot),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // UNCERTAIN-04: page_state() rechaza la solicitud
    assert_eq!(
        pool.page_state(slot),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // UNCERTAIN-05: physical_access() rechaza la solicitud
    assert_eq!(
        pool.physical_access(slot),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // UNCERTAIN-06: validate_superpage() rechaza la solicitud
    assert_eq!(
        pool.validate_superpage(0),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // UNCERTAIN-07: check_invariants() no accede a memoria física ambigua
    assert_eq!(
        pool.check_invariants(),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // UNCERTAIN-08: revalidate() rechaza una referencia previamente válida
    assert_eq!(
        pool.revalidate(link),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // UNCERTAIN-09: allocate() no publica nuevas capacidades
    assert_eq!(
        pool.allocate(),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // UNCERTAIN-12: Comprobar que los contadores no cambian indebidamente ante operaciones rechazadas
    assert_eq!(pool.live_count(), live_before);
    assert_eq!(pool.hole_count(), holes_before);
    assert_eq!(pool.dirty_headers(), dirty_before);

    // UNCERTAIN-10: Retirar el fallo inyectado y reintentar el cierre correctamente
    pool.set_faults(FaultPlan::new()).unwrap();
    assert!(pool.close().is_ok());

    // Pool ahora está cerrado completamente
    assert!(pool.is_closed());
    assert!(!pool.is_open());
    assert!(!pool.is_release_uncertain());
    assert!(!pool.is_operational());
    assert_eq!(pool.ensure_operational(), Err(PoolError::Closed));

    // UNCERTAIN-11: Comprobar que ningún token o referencia obsoleta recupera autoridad después del cierre
    assert_eq!(pool.revalidate(link), Err(PoolError::Closed));
    assert_eq!(pool.base_addr(), Err(PoolError::Closed));
    assert_eq!(pool.generation(slot), Err(PoolError::Closed));
    assert_eq!(pool.page_state(slot), Err(PoolError::Closed));
    assert_eq!(pool.physical_access(slot), Err(PoolError::Closed));
    assert_eq!(pool.validate_superpage(0), Err(PoolError::Closed));
    assert_eq!(pool.check_invariants(), Err(PoolError::Closed));
    assert_eq!(pool.allocate(), Err(PoolError::Closed));
}

#[test]
fn superpage_validation_lifecycle_and_operational_invariants() {
    let mut pool = PhysicalPool::new(PoolConfig {
        max_superpages: 4,
        ..PoolConfig::default()
    })
    .unwrap();

    // 1. Superpágina fuera de rango
    assert_eq!(pool.validate_superpage(4), Err(PoolError::OutOfBounds));
    assert_eq!(pool.validate_superpage(999), Err(PoolError::OutOfBounds));

    // 2. Superpágina dentro de rango pero no inicializada
    assert_eq!(
        pool.validate_superpage(0),
        Err(PoolError::Invariant(
            "superpágina 0 no inicializada".to_string()
        ))
    );

    // 3. Superpágina inicializada y pool operativo
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let link = handle.link();
    let sp_idx = pool
        .validate_superpage(0)
        .expect("superpágina 0 debe ser válida");
    assert_eq!(sp_idx.get(), 0);

    // Superpágina 1 sigue no inicializada
    assert_eq!(
        pool.validate_superpage(1),
        Err(PoolError::Invariant(
            "superpágina 1 no inicializada".to_string()
        ))
    );

    // Snapshot de estado y métricas
    let dirty_before = pool.dirty_headers();

    // 4. Inyección de fallo ambiguo en release
    pool.destroy(handle, false).unwrap();
    pool.set_faults(FaultPlan::new().unknown_nth(FaultOp::Release, 1))
        .unwrap();
    let failure = match pool.try_close() {
        Ok(()) => panic!("cierre debía fallar con estado ambiguo"),
        Err(f) => f,
    };
    assert_eq!(
        failure.error(),
        &PoolError::Physical(PhysicalError::UnknownState(FaultOp::Release))
    );
    let (mut pool, _) = (*failure).into_parts();

    // 5. Estado ReleaseUncertain rechaza toda validación operativa de superpáginas
    assert!(pool.is_release_uncertain());
    assert_eq!(
        pool.validate_superpage(0),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.validate_superpage(sp_idx.get()),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.validate_superpage(1),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.validate_superpage(999),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // 6. Rechazo de reutilización indebida de un índice previamente validado:
    // Las operaciones que dependan del índice o del slot fallan cerrado
    assert_eq!(
        pool.generation(slot),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.page_state(slot),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.physical_access(slot),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.revalidate(link),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.check_invariants(),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // 7. Ausencia de modificaciones de metadatos después de un rechazo
    assert_eq!(pool.live_count(), 0);
    assert_eq!(pool.hole_count(), 0);
    assert_eq!(pool.dirty_headers(), dirty_before);

    // 8. Reintento exitoso de cierre tras retirar fallos
    pool.set_faults(FaultPlan::new()).unwrap();
    assert!(pool.close().is_ok());

    // 9. Pool cerrado: validate_superpage y check_invariants devuelven PoolError::Closed
    assert!(pool.is_closed());
    assert_eq!(pool.validate_superpage(0), Err(PoolError::Closed));
    assert_eq!(
        pool.validate_superpage(sp_idx.get()),
        Err(PoolError::Closed)
    );
    assert_eq!(pool.validate_superpage(1), Err(PoolError::Closed));
    assert_eq!(pool.validate_superpage(999), Err(PoolError::Closed));
    assert_eq!(pool.check_invariants(), Err(PoolError::Closed));
}

#[test]
fn pool_failed_release_keeps_owner_and_retries() {
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    let handle = pool.allocate().unwrap();
    pool.destroy(handle, false).unwrap();

    pool.set_faults(FaultPlan::new().fail_nth(FaultOp::Release, 1))
        .unwrap();
    let failure = match pool.try_close() {
        Ok(()) => panic!("el release del pool debía fallar"),
        Err(failure) => failure,
    };
    assert_eq!(
        failure.error(),
        &PoolError::Physical(PhysicalError::Injected(FaultOp::Release))
    );
    let (mut pool, _) = (*failure).into_parts();
    assert!(pool.is_open());
    assert!(!pool.is_closed());
    assert!(!pool.is_release_uncertain());
    assert!(pool.is_operational());

    // Retirar el fallo y reintentar
    pool.set_faults(FaultPlan::new()).unwrap();
    assert!(pool.try_close().is_ok());
}
