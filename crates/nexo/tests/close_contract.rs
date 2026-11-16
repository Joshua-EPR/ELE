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

    // Pool está cerrado: toda inspección de metadatos o acceso físico debe fallar cerrado
    assert_eq!(pool.generation(slot), Err(PoolError::Closed));
    assert_eq!(pool.page_state(slot), Err(PoolError::Closed));
    assert_eq!(pool.physical_access(slot), Err(PoolError::Closed));
    assert_eq!(pool.revalidate(link), Err(PoolError::Closed));
    assert_eq!(pool.validate_superpage(0), Err(PoolError::Closed));
}

#[test]
fn release_uncertain_blocks_all_authority_and_revalidations() {
    use nexo::next::adapter::{CompactPhysicalPool, CompactPhysicalPool64};
    use nexo::next::compact::{
        CompactLink, CompactLink64, CompactPoolError, CompactPoolRegistry, CompactPoolRegistry16,
    };

    // 1. Pool operativo antes del fallo
    let mut pool = PhysicalPool::new(PoolConfig::default()).unwrap();
    assert!(pool.is_operational());
    assert!(!pool.is_closed());
    assert!(!pool.is_release_uncertain());
    assert!(pool.ensure_operational().is_ok());

    let token8 = CompactPoolRegistry::register_pool(&pool).unwrap();
    let token16 = CompactPoolRegistry16::register_pool(&pool).unwrap();
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let link = handle.link();
    let _link32 = CompactLink::new(token8.id(), slot, handle.generation() as u16).unwrap();
    let _link64 = CompactLink64::new(token16.id(), slot, handle.generation() as u16).unwrap();

    // Destruimos handle para permitir close sin leak
    pool.destroy(handle, false).unwrap();

    // 2. Inyectar fallo ambiguo en release y ejecutar try_close
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

    // 3. Bloqueo de registro compacto de 8 bits
    assert_eq!(
        CompactPoolRegistry::register_pool(&pool).unwrap_err(),
        CompactPoolError::ReleaseUncertain
    );

    // 4. Bloqueo de registro compacto de 16 bits
    assert_eq!(
        CompactPoolRegistry16::register_pool(&pool).unwrap_err(),
        CompactPoolError::ReleaseUncertain
    );

    // 5. Rechazo de construcción de adaptadores de 32 y 64 bits
    assert_eq!(
        CompactPhysicalPool::new(&pool, &token8).unwrap_err(),
        CompactPoolError::ReleaseUncertain
    );
    assert_eq!(
        CompactPhysicalPool64::new(&pool, &token16).unwrap_err(),
        CompactPoolError::ReleaseUncertain
    );

    // 6. Rechazo de consultas de generación
    assert_eq!(
        pool.generation(slot),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // 7. Rechazo de consultas de estado de página
    assert_eq!(
        pool.page_state(slot),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // 8. Rechazo de acceso físico y dirección base
    assert_eq!(
        pool.physical_access(slot),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.base_addr(),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // 9. Rechazo de revalidación ordinaria
    assert_eq!(
        pool.revalidate(link),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // 10. Rechazo de nuevas asignaciones o capacidades
    assert_eq!(
        pool.allocate(),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.validate_superpage(0),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );
    assert_eq!(
        pool.check_invariants(),
        Err(PoolError::Physical(PhysicalError::ReleaseUncertain))
    );

    // 11. Preservación de la capacidad de reintentar el cierre y cierre exitoso tras retirar fallo
    pool.set_faults(FaultPlan::new()).unwrap();
    assert!(pool.close().is_ok());

    // 12. Pool ahora está cerrado completamente
    assert!(pool.is_closed());
    assert!(!pool.is_open());
    assert!(!pool.is_release_uncertain());
    assert!(!pool.is_operational());
    assert_eq!(pool.ensure_operational(), Err(PoolError::Closed));
    assert_eq!(pool.validate_superpage(0), Err(PoolError::Closed));
    assert_eq!(pool.check_invariants(), Err(PoolError::Closed));
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
