//! F01–F20: memoria virtual real y correspondencia con el modelo abstracto.

use nexo::physical::{DestroyOutcome, PageState, PhysicalPool, PoolConfig, PoolError};
use nexo::rt::pool::{Eventos, GEN_RETIRADO, Palabra, Pool, SUPERPAGINA};

fn config(slot_size: u32, fields: usize, max_superpages: u32) -> PoolConfig {
    PoolConfig {
        slot_size,
        fields,
        max_superpages,
        ..PoolConfig::default()
    }
}

#[test]
fn f01_reserva_virtual_real_y_base_estable() {
    let mut pool = PhysicalPool::new(config(64, 2, 2)).unwrap();
    let base = pool.base_addr().unwrap();
    let _ = pool.allocate().unwrap();
    assert_eq!(pool.base_addr().unwrap(), base);
    assert_eq!(
        pool.address_metrics().unwrap().reserved_bytes,
        2 * 64 * 1024
    );
}

#[test]
fn f02_alineacion_de_superpagina() {
    let pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    assert_eq!(pool.base_addr().unwrap() % SUPERPAGINA as usize, 0);
}

#[test]
fn f03_layout_de_cabecera_y_offsets() {
    let pool = PhysicalPool::new(config(64, 8, 1)).unwrap();
    assert_eq!(pool.slots_per_subpage(), 64);
    assert_eq!(pool.slots_per_superpage(), 960);
    assert_eq!(960 * 4 + 15 * 8 + 15 * 8 + 15, 4095);
}

#[test]
fn f04_confirmacion_de_memoria() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    assert_eq!(pool.address_metrics().unwrap().committed_bytes, 0);
    pool.allocate().unwrap();
    assert_eq!(pool.address_metrics().unwrap().committed_bytes, 8192);
}

#[test]
fn f05_lectura_y_escritura_tipadas() {
    let mut pool = PhysicalPool::new(config(64, 2, 1)).unwrap();
    let handle = pool.allocate().unwrap();
    pool.write_int(handle, 0, -42).unwrap();
    pool.write_link(handle, 1, handle.link()).unwrap();
    assert_eq!(pool.read_int(handle, 0).unwrap(), -42);
    assert_eq!(pool.read_link(handle, 1).unwrap(), handle.link());
}

#[test]
fn f06_destruccion_segura() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let handle = pool.allocate().unwrap();
    assert!(matches!(
        pool.destroy(handle, false),
        Ok(DestroyOutcome::Free)
    ));
    assert_eq!(pool.live_count(), 0);
    pool.check_invariants().unwrap();
}

#[test]
fn f07_obsoleto_rechazado_antes_de_dereferenciar() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let handle = pool.allocate().unwrap();
    pool.destroy(handle, false).unwrap();
    assert!(matches!(
        pool.read_int(handle, 0),
        Err(PoolError::StaleGeneration)
    ));
}

#[test]
fn f08_reutilizacion_lineal_de_hueco() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let first = pool.allocate().unwrap();
    let DestroyOutcome::Hole(hole) = pool.destroy(first, true).unwrap() else {
        panic!("se esperaba hueco")
    };
    let second = pool.reuse_hole(hole).unwrap();
    assert_eq!(second.slot, first.slot);
    assert_eq!(second.generation, first.generation + 2);
}

#[test]
fn f09_doble_liberacion_rechazada() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let handle = pool.allocate().unwrap();
    pool.destroy(handle, false).unwrap();
    assert!(matches!(
        pool.destroy(handle, false),
        Err(PoolError::DoubleFree)
    ));
    pool.check_invariants().unwrap();
}

#[test]
fn f10_subpagina_vacia_devuelta_realmente() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let handle = pool.allocate().unwrap();
    pool.destroy(handle, false).unwrap();
    assert_eq!(pool.page_state(handle.slot).unwrap(), PageState::Returned);
    assert_eq!(pool.address_metrics().unwrap().committed_bytes, 4096);
    assert_eq!(pool.metrics().data_returned, 1);
}

#[test]
fn f11_reconfirmacion_de_pagina_devuelta() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let first = pool.allocate().unwrap();
    pool.destroy(first, false).unwrap();
    let second = pool.allocate().unwrap();
    assert_eq!(second.slot, first.slot);
    assert_eq!(pool.metrics().data_recommitted, 1);
    assert_eq!(pool.page_state(second.slot).unwrap(), PageState::Committed);
}

#[test]
fn f12_generaciones_sobreviven_al_reclaim() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let first = pool.allocate().unwrap();
    pool.destroy(first, false).unwrap();
    assert_eq!(pool.generation(first.slot).unwrap(), first.generation + 1);
    let second = pool.allocate().unwrap();
    assert_eq!(second.generation, first.generation + 2);
}

#[test]
fn f13_agotamiento_retira_slot_sin_wraparound() {
    let mut cfg = config(4096, 1, 1);
    cfg.initial_generation = GEN_RETIRADO - 2;
    let mut pool = PhysicalPool::new(cfg).unwrap();
    let handle = pool.allocate().unwrap();
    assert_eq!(handle.generation, GEN_RETIRADO - 1);
    assert!(matches!(
        pool.destroy(handle, false),
        Ok(DestroyOutcome::Retired)
    ));
    assert_eq!(pool.generation(handle.slot).unwrap(), GEN_RETIRADO);
    assert_ne!(pool.allocate().unwrap().slot, handle.slot);
}

#[test]
fn f14_agotamiento_virtual_es_controlado() {
    let mut pool = PhysicalPool::new(config(4096, 1, 1)).unwrap();
    let handles: Vec<_> = (0..15).map(|_| pool.allocate().unwrap()).collect();
    assert!(matches!(pool.allocate(), Err(PoolError::OutOfSpace)));
    assert_eq!(pool.live_count(), handles.len() as u64);
    pool.check_invariants().unwrap();
}

#[test]
fn f15_fallos_inyectados_no_publican_asignaciones() {
    let mut reserve = config(64, 1, 1);
    reserve.fail_reserve = true;
    assert!(matches!(
        PhysicalPool::new(reserve),
        Err(PoolError::InjectedFailure("reserve"))
    ));

    let mut commit = config(64, 1, 1);
    commit.fail_commit_at = Some(1);
    let mut pool = PhysicalPool::new(commit).unwrap();
    assert!(matches!(
        pool.allocate(),
        Err(PoolError::InjectedFailure("commit"))
    ));
    assert_eq!(pool.live_count(), 0);
    pool.check_invariants().unwrap();
    assert!(pool.allocate().is_ok(), "el pool sigue utilizable");
}

#[test]
fn f16_cierre_rechaza_fugas_y_luego_libera_mapping() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let handle = pool.allocate().unwrap();
    assert!(matches!(
        pool.close(),
        Err(PoolError::Leak { live: 1, holes: 0 })
    ));
    assert_eq!(pool.read_int(handle, 0).unwrap(), 0);
    pool.destroy(handle, false).unwrap();
    pool.close().unwrap();
    assert!(matches!(pool.base_addr(), Err(PoolError::Closed)));
}

#[test]
fn f17_dos_pools_son_independientes() {
    let mut first = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let second = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let handle = first.allocate().unwrap();
    assert_ne!(first.base_addr().unwrap(), second.base_addr().unwrap());
    assert!(matches!(
        second.revalidate(handle.link()),
        Err(PoolError::ForeignHandle)
    ));
}

#[test]
fn f18_clases_de_tamano_y_alineacion() {
    for size in [64, 72, 96, 128, 200, 1000, 2048, 3000, 4096] {
        let mut pool = PhysicalPool::new(config(size, 1, 1)).unwrap();
        let handle = pool.allocate().unwrap();
        pool.write_int(handle, 0, size as i64).unwrap();
        assert_eq!(pool.read_int(handle, 0).unwrap(), size as i64);
        pool.destroy(handle, false).unwrap();
    }
}

#[test]
fn f19_indices_adversariales_no_tocan_memoria() {
    let mut pool = PhysicalPool::new(config(64, 1, 1)).unwrap();
    let handle = pool.allocate().unwrap();
    assert!(matches!(
        pool.generation(u32::MAX),
        Err(PoolError::OutOfBounds)
    ));
    assert!(matches!(
        pool.read_int(handle, usize::MAX),
        Err(PoolError::InvalidField)
    ));
    assert_eq!(pool.read_int(handle, 0).unwrap(), 0);
}

#[test]
fn f20_diferencial_largo_con_semilla_fija() {
    for seed in [0xF20u64, 0xC0FFEE, 0x5EED] {
        let mut random = seed;
        let mut abstract_events = Eventos::default();
        let mut abstract_pool = Pool::nuevo(0, 1, 64, 4, 0).unwrap();
        let mut physical_pool = PhysicalPool::new(config(64, 1, 4)).unwrap();
        let mut live = Vec::new();
        for step in 0..2_000i64 {
            random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
            if live.is_empty() || random % 3 != 0 {
                let abstract_handle = abstract_pool.asignar(0, &mut abstract_events).unwrap();
                let physical_handle = physical_pool.allocate().unwrap();
                assert_eq!(
                    abstract_handle,
                    (physical_handle.slot, physical_handle.generation)
                );
                abstract_pool
                    .escribir(abstract_handle.0, abstract_handle.1, 0, Palabra::Int(step))
                    .unwrap();
                physical_pool.write_int(physical_handle, 0, step).unwrap();
                live.push((abstract_handle, physical_handle));
            } else {
                let index = (random as usize) % live.len();
                let (abstract_handle, physical_handle) = live.swap_remove(index);
                assert_eq!(
                    abstract_pool
                        .leer(abstract_handle.0, abstract_handle.1, 0)
                        .unwrap(),
                    Palabra::Int(physical_pool.read_int(physical_handle, 0).unwrap())
                );
                abstract_pool
                    .destruir(
                        abstract_handle.0,
                        abstract_handle.1,
                        false,
                        &mut abstract_events,
                    )
                    .unwrap();
                physical_pool.destroy(physical_handle, false).unwrap();
            }
            abstract_pool.comprobar_invariantes().unwrap();
            physical_pool.check_invariants().unwrap();
        }
    }
}
