//! test_prototype_01.rs — Test de integración de extremo a extremo para NEXO Prototype 0.1.
//!
//! Valida el ciclo de vida completo de objetos usando exclusivamente las APIs públicas
//! de `PhysicalPool`:
//! 1. Creación de pool con configuración personalizada.
//! 2. Asignación masiva de objetos.
//! 3. Escritura y lectura cruzada tipada de enteros y enlaces.
//! 4. Revalidación de enlaces válidos y rechazo de generaciones obsoletas.
//! 5. Destrucción selectiva con preservación de huecos lineales.
//! 6. Reutilización determinista de huecos y verificación de avance de generación (+2).
//! 7. Destrucción final, verificación de invariantes y cierre ordenado del pool.

use nexo::physical::{DestroyOutcome, PhysicalPool, PoolConfig, PoolError};

#[test]
fn test_prototype_01_full_lifecycle_e2e() {
    let config = PoolConfig {
        slot_size: 64,
        fields: 4,
        max_superpages: 2,
        ..PoolConfig::default()
    };
    let mut pool = PhysicalPool::new(config).expect("Fallo al crear PhysicalPool");
    assert!(pool.is_open());
    assert!(!pool.is_closed());

    let num_objects = 128;
    let mut handles = Vec::with_capacity(num_objects);
    let mut links = Vec::with_capacity(num_objects);
    let mut objs = Vec::with_capacity(num_objects);

    // 1. Asignación y escritura inicial
    for i in 0..num_objects {
        let h = pool.allocate().expect("Fallo al asignar handle");
        let obj = h.obj();
        let link = h.link();

        pool.write_int(obj, 0, (i * 10) as i64)
            .expect("Fallo en write_int[0]");
        pool.write_int(obj, 1, (i * 100) as i64)
            .expect("Fallo en write_int[1]");

        objs.push(obj);
        links.push(link);
        handles.push(h);
    }
    assert_eq!(pool.live_count(), num_objects as u64);

    // 2. Verificación de lecturas y escritura de enlaces en cadena (obj[i] -> link[i+1])
    for (i, &obj) in objs.iter().enumerate() {
        let v0 = pool.read_int(obj, 0).expect("Fallo en read_int[0]");
        let v1 = pool.read_int(obj, 1).expect("Fallo en read_int[1]");
        assert_eq!(v0, (i * 10) as i64);
        assert_eq!(v1, (i * 100) as i64);

        let next_idx = (i + 1) % num_objects;
        pool.write_link(obj, 2, links[next_idx])
            .expect("Fallo en write_link");
    }

    // 3. Verificación de enlaces y revalidación
    for (i, &obj) in objs.iter().enumerate() {
        let next_idx = (i + 1) % num_objects;
        let read_lnk = pool.read_link(obj, 2).expect("Fallo en read_link");
        assert_eq!(read_lnk, links[next_idx]);

        let reval_obj = pool.revalidate(read_lnk).expect("Fallo al revalidar");
        assert_eq!(reval_obj.slot(), links[next_idx].slot());
        assert_eq!(reval_obj.generation(), links[next_idx].generation());
    }

    // 4. Destrucción de la mitad par reteniendo huecos
    let mut holes = Vec::new();
    let mut remaining_handles = Vec::new();

    for (i, h) in handles.into_iter().enumerate() {
        if i % 2 == 0 {
            let slot = h.slot();
            let generation = h.generation();
            let report = pool.destroy(h, true).expect("Fallo en destroy con hueco");
            match report.outcome {
                DestroyOutcome::Hole(token) => {
                    assert_eq!(token.slot(), slot);
                    assert_eq!(token.generation(), generation + 1); // Generación par (hueco)
                    holes.push((slot, generation, token));
                }
                _ => panic!("Se esperaba DestroyOutcome::Hole"),
            }
        } else {
            remaining_handles.push(h);
        }
    }
    assert_eq!(pool.live_count(), (num_objects / 2) as u64);
    assert_eq!(pool.hole_count(), (num_objects / 2) as u64);

    // 5. Verificación fail-closed de referencias obsoletas (stale check)
    for i in (0..num_objects).step_by(2) {
        assert_eq!(
            pool.read_int(objs[i], 0).unwrap_err(),
            PoolError::StaleGeneration
        );
        assert_eq!(
            pool.write_int(objs[i], 0, 999).unwrap_err(),
            PoolError::StaleGeneration
        );
        assert_eq!(
            pool.revalidate(links[i]).unwrap_err(),
            PoolError::StaleGeneration
        );
    }

    // 6. Reutilización determinista de huecos
    let mut reused_handles = Vec::new();
    for (orig_slot, orig_gen, hole_token) in holes {
        let new_handle = pool
            .reuse_hole(hole_token)
            .unwrap_or_else(|_| panic!("Fallo al reutilizar hueco"));
        assert_eq!(new_handle.slot(), orig_slot);
        assert_eq!(new_handle.generation(), orig_gen + 2); // Invariante de avance de generación

        pool.write_int(new_handle.obj(), 0, 7777)
            .expect("Fallo al escribir en handle reutilizado");
        assert_eq!(pool.read_int(new_handle.obj(), 0).expect("Lectura"), 7777);
        reused_handles.push(new_handle);
    }
    assert_eq!(pool.hole_count(), 0);
    assert_eq!(pool.live_count(), num_objects as u64);

    // 7. Destrucción total
    for h in remaining_handles.into_iter().chain(reused_handles) {
        pool.destroy(h, false).expect("Fallo en destrucción final");
    }
    assert_eq!(pool.live_count(), 0);

    // 8. Invariantes del pool y cierre
    pool.check_invariants().expect("Invariantes violados");
    pool.close().expect("Fallo al cerrar pool");
    assert!(pool.is_closed());
}
