//! S01–S12: seguridad y recuperación ante fallos físicos parciales.
//!
//! Los fallos se inyectan de forma determinista antes de la llamada al SO
//! (`FaultPlan`), así que el estado externo tras el fallo es exactamente el
//! del último paso con éxito. Cada caso comprueba el estado lógico, el físico,
//! el espejo de cabecera y los invariantes, no solo que se devuelva `Err`.

use nexo::physical::{
    Command, CommandResult, DestroyOutcome, DifferentialHarness, FaultOp, FaultPlan, HeaderStatus,
    PageAccess, PageState, PhysicalError, PhysicalPool, PoolConfig, PoolError, ReclaimPolicy,
    ReclaimStatus,
};

fn pool_dos_fases() -> PhysicalPool {
    PhysicalPool::new(PoolConfig {
        max_superpages: 1,
        protect_before_discard: true,
        ..PoolConfig::default()
    })
    .unwrap()
}

fn falla(pool: &mut PhysicalPool, op: FaultOp) {
    pool.set_faults(FaultPlan::new().fail_nth(op, 1)).unwrap();
}

fn pendiente(access: PageAccess, op: FaultOp) -> ReclaimStatus {
    ReclaimStatus::Pending {
        error: PhysicalError::Injected(op),
        access,
    }
}

/// S01: falla `protect_none` antes de cambiar la protección.
#[test]
fn s01_falla_la_proteccion_antes_de_cambiar_nada() {
    let mut pool = pool_dos_fases();
    let h = pool.allocate().unwrap();
    let (slot, obj) = (h.slot(), h.obj());
    pool.write_int(obj, 0, 77).unwrap();
    falla(&mut pool, FaultOp::Protect);
    let r = pool.destroy(h, false).unwrap();
    assert_eq!(
        r.outcome,
        DestroyOutcome::Free,
        "la destrucción lógica se consumó"
    );
    assert_eq!(
        r.reclaim,
        pendiente(PageAccess::Accessible, FaultOp::Protect)
    );
    assert_eq!(pool.page_state(slot).unwrap(), PageState::ReclaimPending);
    assert_eq!(pool.physical_access(slot).unwrap(), PageAccess::Accessible);
    assert_eq!(pool.read_int(obj, 0), Err(PoolError::StaleGeneration));
    assert_eq!(pool.pending_reclaims(), 1);
    pool.check_invariants().unwrap();
}

/// S02: la protección tiene éxito y falla el descarte posterior.
#[test]
fn s02_proteccion_correcta_y_fallo_del_descarte() {
    let mut pool = pool_dos_fases();
    let h = pool.allocate().unwrap();
    let (slot, obj) = (h.slot(), h.obj());
    let antes = pool.address_metrics().unwrap();
    falla(&mut pool, FaultOp::Decommit);
    let r = pool.destroy(h, false).unwrap();
    assert_eq!(
        r.reclaim,
        pendiente(PageAccess::Protected, FaultOp::Decommit)
    );
    assert_eq!(pool.physical_access(slot).unwrap(), PageAccess::Protected);
    let despues = pool.address_metrics().unwrap();
    assert_eq!(
        despues.committed_bytes, antes.committed_bytes,
        "el backing sigue confirmado"
    );
    assert_eq!(
        despues.accessible_bytes,
        antes.accessible_bytes - 4096,
        "pero ya no es accesible"
    );
    assert_eq!(despues.os_calls.protect, antes.os_calls.protect + 1);
    assert_eq!(despues.os_calls.discard, antes.os_calls.discard);
    assert_eq!(pool.read_int(obj, 0), Err(PoolError::StaleGeneration));
    pool.check_invariants().unwrap();
}

/// En Windows sin protección previa la reclamación es un solo paso: si falla
/// el descarte, la página sigue accesible (y su objeto ya es inalcanzable).
#[cfg(target_os = "windows")]
#[test]
fn s02b_windows_un_solo_paso() {
    let mut pool = PhysicalPool::new(PoolConfig {
        max_superpages: 1,
        ..PoolConfig::default()
    })
    .unwrap();
    let h = pool.allocate().unwrap();
    let slot = h.slot();
    let antes = pool.address_metrics().unwrap().os_calls;
    falla(&mut pool, FaultOp::Decommit);
    let r = pool.destroy(h, false).unwrap();
    assert_eq!(
        r.reclaim,
        pendiente(PageAccess::Accessible, FaultOp::Decommit)
    );
    assert_eq!(
        pool.address_metrics().unwrap().os_calls.protect,
        antes.protect,
        "sin VirtualProtect"
    );
    pool.repair().unwrap();
    assert_eq!(pool.physical_access(slot).unwrap(), PageAccess::Discarded);
    let despues = pool.address_metrics().unwrap().os_calls;
    assert_eq!(
        (despues.protect, despues.discard - antes.discard),
        (antes.protect, 1)
    );
    pool.check_invariants().unwrap();
}

/// S03: reclamación pendiente y reintento con éxito.
#[test]
fn s03_reintento_con_exito() {
    let mut pool = pool_dos_fases();
    let h = pool.allocate().unwrap();
    let slot = h.slot();
    falla(&mut pool, FaultOp::Decommit);
    pool.destroy(h, false).unwrap();
    let committed = pool.address_metrics().unwrap().committed_bytes;
    let rep = pool.repair().unwrap();
    assert_eq!((rep.reclaimed, rep.still_pending), (1, 0));
    assert_eq!(pool.page_state(slot).unwrap(), PageState::Returned);
    assert_eq!(pool.physical_access(slot).unwrap(), PageAccess::Discarded);
    assert_eq!(
        pool.address_metrics().unwrap().committed_bytes,
        committed - 4096
    );
    assert_eq!(pool.pending_reclaims(), 0);
    assert_eq!(pool.metrics().reclaim_retries, 1);
    pool.check_invariants().unwrap();
}

/// S04: fallos repetidos: la página permanece en un estado seguro y
/// reintentable; nunca se marca devuelta sin que el SO lo confirme.
#[test]
fn s04_fallos_repetidos() {
    let mut pool = pool_dos_fases();
    let h = pool.allocate().unwrap();
    let slot = h.slot();
    pool.set_faults(FaultPlan::new().fail_always(FaultOp::Decommit))
        .unwrap();
    pool.destroy(h, false).unwrap();
    for intento in 1..=4 {
        let rep = pool.repair().unwrap();
        assert_eq!(
            (rep.reclaimed, rep.still_pending),
            (0, 1),
            "intento {intento}"
        );
        assert_eq!(rep.errors, vec![PhysicalError::Injected(FaultOp::Decommit)]);
        assert_eq!(pool.page_state(slot).unwrap(), PageState::ReclaimPending);
        assert_eq!(pool.physical_access(slot).unwrap(), PageAccess::Protected);
        pool.check_invariants().unwrap();
    }
    pool.faults_mut().unwrap().stop_failing(FaultOp::Decommit);
    assert_eq!(pool.repair().unwrap().reclaimed, 1);
    assert_eq!(pool.metrics().reclaim_failures, 5);
    pool.check_invariants().unwrap();
}

/// S05: la destrucción lógica se consume una sola vez. Un error previo al
/// consumo devuelve el `Handle`; tras el consumo, ninguna vía lo repite.
#[test]
fn s05_destruccion_consumida_una_vez() {
    let mut pool = pool_dos_fases();
    let mut otro = pool_dos_fases();
    let h = pool.allocate().unwrap();
    let link = h.link();
    // Error antes de consumir (pool ajeno): el handle vuelve intacto.
    let (h, error) = otro.destroy(h, false).unwrap_err();
    assert_eq!(error, PoolError::ForeignHandle);
    assert_eq!(pool.live_count(), 1);
    // Consumo con fallo físico: Ok, la capacidad ya no existe.
    falla(&mut pool, FaultOp::Decommit);
    let r = pool.destroy(h, false).unwrap();
    assert!(matches!(r.reclaim, ReclaimStatus::Pending { .. }));
    assert_eq!((pool.metrics().destructions, pool.live_count()), (1, 0));
    assert_eq!(pool.revalidate(link), Err(PoolError::StaleGeneration));
    // Un reintento de reclamación no vuelve a destruir.
    pool.repair().unwrap();
    assert_eq!(pool.metrics().destructions, 1);
    pool.check_invariants().unwrap();
}

/// S06: un enlace antiguo se rechaza durante la reclamación pendiente, tanto
/// si la página quedó accesible (falló la protección) como protegida.
#[test]
fn s06_enlace_antiguo_rechazado_durante_pendiente() {
    for op in [FaultOp::Protect, FaultOp::Decommit] {
        let mut pool = pool_dos_fases();
        let h = pool.allocate().unwrap();
        pool.write_int(h.obj(), 0, 1234).unwrap();
        let (link, obj) = (h.link(), h.obj());
        falla(&mut pool, op);
        pool.destroy(h, false).unwrap();
        assert_eq!(pool.pending_reclaims(), 1);
        assert_eq!(pool.revalidate(link), Err(PoolError::StaleGeneration));
        assert_eq!(pool.read_int(obj, 0), Err(PoolError::StaleGeneration));
        assert_eq!(pool.write_int(obj, 0, 1), Err(PoolError::StaleGeneration));
        assert_eq!(pool.read_link(obj, 0), Err(PoolError::StaleGeneration));
        pool.check_invariants().unwrap();
    }
}

/// S07: el hueco lineal se consume exactamente una vez ante fallos.
#[test]
fn s07_hueco_lineal_ante_fallos() {
    let mut pool = pool_dos_fases();
    let mut otro = pool_dos_fases();
    let ancla = pool.allocate().unwrap();
    let h = pool.allocate().unwrap();
    let DestroyOutcome::Hole(token) = pool.destroy(h, true).unwrap().outcome else {
        panic!("hueco")
    };
    // Error antes de consumir: el token vuelve.
    let (token, e) = otro.reuse_hole(token).unwrap_err();
    assert_eq!(e, PoolError::ForeignHandle);
    assert_eq!(pool.hole_count(), 1);
    // Reuso con fallo de cabecera: consumido, espejo sucio, identidad válida.
    falla(&mut pool, FaultOp::HeaderWrite);
    let nuevo = pool.reuse_hole(token).unwrap();
    assert_eq!((pool.hole_count(), pool.live_count()), (0, 2));
    assert_eq!(pool.dirty_headers(), 1);
    assert_eq!(pool.revalidate(nuevo.link()).unwrap(), nuevo.obj());
    pool.check_invariants().unwrap();
    // Liberación de un segundo hueco con fallo de reclamación.
    let DestroyOutcome::Hole(t2) = pool.destroy(nuevo, true).unwrap().outcome else {
        panic!("hueco")
    };
    pool.destroy(ancla, false).unwrap();
    falla(&mut pool, FaultOp::Decommit);
    let rep = pool.release_hole(t2).unwrap();
    assert!(matches!(rep.reclaim, ReclaimStatus::Pending { .. }));
    assert_eq!(pool.hole_count(), 0);
    pool.check_invariants().unwrap();
    let rep = pool.repair().unwrap();
    assert_eq!(
        (rep.reclaimed, rep.headers_resynced),
        (1, 0),
        "el espejo ya se rehízo al reusar"
    );
    pool.check_invariants().unwrap();
}

/// S08: reactivación segura de una página pendiente: confirmada de nuevo,
/// slot a cero, generación +2 y el enlace viejo sigue muerto. Si la
/// reconfirmación falla, la página sigue pendiente y nada se publica.
#[test]
fn s08_reactivacion_de_pagina_pendiente() {
    let mut pool = pool_dos_fases();
    let h = pool.allocate().unwrap();
    let (slot, generation, link) = (h.slot(), h.generation(), h.link());
    pool.write_int(h.obj(), 0, -9).unwrap();
    falla(&mut pool, FaultOp::Decommit);
    pool.destroy(h, false).unwrap();
    assert_eq!(pool.physical_access(slot).unwrap(), PageAccess::Protected);

    falla(&mut pool, FaultOp::Recommit);
    assert_eq!(
        pool.allocate().unwrap_err(),
        PoolError::Physical(PhysicalError::Injected(FaultOp::Recommit))
    );
    assert_eq!((pool.live_count(), pool.pending_reclaims()), (0, 1));
    assert_eq!(pool.page_state(slot).unwrap(), PageState::ReclaimPending);
    pool.check_invariants().unwrap();

    let nuevo = pool.allocate().unwrap();
    assert_eq!((nuevo.slot(), nuevo.generation()), (slot, generation + 2));
    assert_eq!(
        pool.read_int(nuevo.obj(), 0).unwrap(),
        0,
        "los bytes antiguos no se exponen"
    );
    assert_eq!(pool.page_state(slot).unwrap(), PageState::Committed);
    assert_eq!(pool.pending_reclaims(), 0);
    assert_eq!(pool.revalidate(link), Err(PoolError::StaleGeneration));
    pool.check_invariants().unwrap();
}

/// S09: cierre del pool con reclamaciones pendientes, y cierre cuya
/// liberación falla (el pool sigue abierto, consistente y reintentable).
#[test]
fn s09_cierre_con_reclamaciones_pendientes() {
    let mut pool = pool_dos_fases();
    let h = pool.allocate().unwrap();
    pool.set_faults(FaultPlan::new().fail_always(FaultOp::Decommit))
        .unwrap();
    pool.destroy(h, false).unwrap();
    assert_eq!(pool.pending_reclaims(), 1);
    pool.faults_mut().unwrap().stop_failing(FaultOp::Decommit);
    falla(&mut pool, FaultOp::Release);
    assert_eq!(
        pool.close(),
        Err(PoolError::Physical(PhysicalError::Injected(
            FaultOp::Release
        )))
    );
    assert!(pool.base_addr().is_ok(), "sigue abierto");
    pool.check_invariants().unwrap();
    pool.close().unwrap();
    assert_eq!(pool.base_addr(), Err(PoolError::Closed));
    assert_eq!(pool.pending_reclaims(), 0, "desaparecen con la reserva");
}

/// S10: invariantes consistentes tras cada fallo inyectado, para cada punto
/// de inyección y varias posiciones, en una secuencia fija de operaciones.
#[test]
fn s10_invariantes_tras_cada_fallo() {
    let ops = [
        FaultOp::Commit,
        FaultOp::Recommit,
        FaultOp::Protect,
        FaultOp::Decommit,
        FaultOp::HeaderWrite,
    ];
    for op in ops {
        for n in 1..=6 {
            for policy in [
                ReclaimPolicy::Aggressive,
                ReclaimPolicy::Deferred { keep_empty: 1 },
            ] {
                let mut pool = PhysicalPool::new(PoolConfig {
                    max_superpages: 1,
                    slot_size: 1024,
                    protect_before_discard: true,
                    reclaim: policy,
                    ..PoolConfig::default()
                })
                .unwrap();
                pool.set_faults(FaultPlan::new().fail_nth(op, n)).unwrap();
                let mut vivos = Vec::new();
                for paso in 0..40 {
                    if paso % 3 == 2 && !vivos.is_empty() {
                        let h = vivos.remove(0);
                        pool.destroy(h, paso % 2 == 0).map_err(|(_, e)| e).unwrap();
                    } else if let Ok(h) = pool.allocate() {
                        vivos.push(h);
                    }
                    pool.check_invariants()
                        .unwrap_or_else(|e| panic!("{op:?} n={n} {policy:?} paso {paso}: {e:?}"));
                }
                // Recuperación completa.
                pool.set_faults(FaultPlan::new()).unwrap();
                for h in vivos {
                    pool.destroy(h, false).unwrap();
                }
                pool.repair().unwrap();
                pool.check_invariants().unwrap();
                assert_eq!((pool.pending_reclaims(), pool.dirty_headers()), (0, 0));
            }
        }
    }
}

/// S11: un fallo al sincronizar la cabecera no expone ninguna identidad
/// inválida: la validez se decide con los metadatos lógicos, el espejo queda
/// marcado como sucio y `repair` lo rehace.
#[test]
fn s11_fallo_de_cabecera_sin_identidad_invalida() {
    let mut pool = pool_dos_fases();
    let ancla = pool.allocate().unwrap();
    let h = pool.allocate().unwrap();
    let link = h.link();
    falla(&mut pool, FaultOp::HeaderWrite);
    let r = pool.destroy(h, false).unwrap();
    assert_eq!(
        r.header,
        HeaderStatus::Stale(PhysicalError::Injected(FaultOp::HeaderWrite))
    );
    assert_eq!(pool.dirty_headers(), 1);
    assert_eq!(pool.revalidate(link), Err(PoolError::StaleGeneration));
    pool.check_invariants().unwrap();
    // Asignación con el espejo sucio: identidad válida y espejo rehecho.
    falla(&mut pool, FaultOp::HeaderWrite);
    let otro = pool.allocate().unwrap();
    assert_eq!(pool.revalidate(otro.link()).unwrap(), otro.obj());
    assert_eq!(
        pool.dirty_headers(),
        1,
        "el reintento del espejo también falló"
    );
    let rep = pool.repair().unwrap();
    assert_eq!((rep.headers_resynced, rep.headers_still_dirty), (1, 0));
    assert_eq!(pool.dirty_headers(), 0);
    pool.check_invariants().unwrap();
    pool.destroy(otro, false).unwrap();
    pool.destroy(ancla, false).unwrap();
    pool.check_invariants().unwrap();
}

/// S12: equivalencia observable con el modelo abstracto después de
/// recuperar fallos (el arnés compara identidades, valores y contadores en
/// cada paso y el refinamiento del estado de página).
#[test]
fn s12_equivalencia_tras_recuperar() {
    let mut h = DifferentialHarness::new(PoolConfig {
        max_superpages: 1,
        slot_size: 1024,
        protect_before_discard: true,
        ..PoolConfig::default()
    })
    .unwrap();
    let mut ids = Vec::new();
    for v in 0..6 {
        let CommandResult::Allocated { id, .. } = h.apply(Command::Allocate { value: v }).unwrap()
        else {
            panic!()
        };
        ids.push(id);
    }
    // Vaciar la primera subpágina (4 slots de 1 KiB) con el descarte fallando.
    h.apply(Command::Inject {
        op: FaultOp::Decommit,
    })
    .unwrap();
    for id in &ids[..4] {
        h.apply(Command::Destroy {
            id: *id,
            hole: false,
        })
        .unwrap();
    }
    assert_eq!(h.snapshot().unwrap().pending_reclaims, 1);
    for id in &ids[..4] {
        assert_eq!(
            h.apply(Command::ProbeStale { id: *id }).unwrap(),
            CommandResult::Rejected
        );
    }
    // La subpágina más densa con hueco es la segunda (2 de 4 libres): se
    // llena primero, sin reconfirmar nada, igual que en el modelo abstracto.
    for v in 7..9 {
        let r = h.apply(Command::Allocate { value: v }).unwrap();
        assert!(
            matches!(r, CommandResult::Allocated { slot: 6 | 7, .. }),
            "{r:?}"
        );
    }
    // Ahora la asignación cae en la página pendiente: reconfirmación.
    h.apply(Command::Inject {
        op: FaultOp::Recommit,
    })
    .unwrap();
    assert_eq!(
        h.apply(Command::Allocate { value: 9 }).unwrap(),
        CommandResult::AllocationFailed
    );
    for v in 10..14 {
        assert!(matches!(
            h.apply(Command::Allocate { value: v }).unwrap(),
            CommandResult::Allocated { .. }
        ));
    }
    h.apply(Command::Repair).unwrap();
    let s = h.snapshot().unwrap();
    assert_eq!((s.pending_reclaims, s.dirty_headers, s.live), (0, 0, 8));
    h.finish().unwrap();
}
