//! Pruebas exhaustivas de generaciones compactas (16 bits y 8 bits),
//! registro de identidades de pool y enlaces compactos (32 bits y 64 bits).

use nexo::next::{
    CompactGen, CompactGenError, CompactLink, CompactLink64, CompactLinkError, CompactObjRef,
    CompactObjRef64, CompactPhysicalPool, CompactPoolAuthority, CompactPoolAuthority64,
    CompactPoolError, CompactPoolRegistry, CompactPoolRegistry16, CompactPoolRegistryInstance,
    CompactPoolRegistryInstance16, CompactPoolToken, CompactPoolToken16, CompactRevalidateError,
    GEN_RETIRADO_8, GEN_RETIRADO_16, INVALID_COMPACT_POOL_ID, INVALID_COMPACT_POOL_ID_16,
    MAX_COMPACT_POOLS, MAX_COMPACT_POOLS_16, MAX_SLOT_COMPACT_32,
};
use nexo::physical::{HeaderStatus, PhysicalPool, PoolConfig, ReclaimPolicy};

#[test]
fn test_compact_gen_lifecycle_and_invariants() {
    let mut g = 0u16;

    // Allocate -> 1 (impar, vivo)
    g = CompactGen::allocate(g).unwrap();
    assert_eq!(g, 1);
    assert!(CompactGen::is_live(g));

    // No se puede volver a asignar un slot ya vivo
    assert_eq!(
        CompactGen::allocate(g).unwrap_err(),
        CompactGenError::InvalidInitialState
    );

    // Destroy -> 2 (par, no vivo)
    g = CompactGen::destroy(g).unwrap();
    assert_eq!(g, 2);
    assert!(!CompactGen::is_live(g));

    // No se puede volver a destruir un slot ya destruido
    assert_eq!(
        CompactGen::destroy(g).unwrap_err(),
        CompactGenError::InvalidInitialState
    );

    // Reallocate -> 3
    g = CompactGen::allocate(g).unwrap();
    assert_eq!(g, 3);
    assert!(CompactGen::is_live(g));
}

#[test]
fn test_compact_gen_exhaustion_and_no_aba() {
    // Probar el límite próximo a retiro en 16 bits
    let near_end_free = 0xfffc;
    let last_live = CompactGen::allocate(near_end_free).unwrap();
    assert_eq!(last_live, 0xfffd); // 65533

    // La destrucción de 0xfffd debe transicionar a GEN_RETIRADO_16 (0xfffe)
    let retired = CompactGen::destroy(last_live).unwrap();
    assert_eq!(retired, GEN_RETIRADO_16);
    assert!(CompactGen::is_retired(retired));

    // Una vez retirado, allocate y destroy son permanentemente rechazados
    assert_eq!(
        CompactGen::allocate(retired).unwrap_err(),
        CompactGenError::Retired
    );
    assert_eq!(
        CompactGen::destroy(retired).unwrap_err(),
        CompactGenError::Retired
    );
}

#[test]
fn test_exhaustive_8bit_domain_and_invariants() {
    // Verificación exhaustiva de TODOS los 256 valores del espacio de 8 bits
    for val in 0..=255u8 {
        if val >= GEN_RETIRADO_8 {
            // Valores >= 254 (0xfe, 0xff) están retirados/incompatibles
            assert!(!CompactGen::is_live_8(val), "val {val} no debe ser vivo");
            assert!(CompactGen::is_retired_8(val), "val {val} debe ser retirado");
            assert_eq!(
                CompactGen::allocate_8(val).unwrap_err(),
                CompactGenError::Retired
            );
            assert_eq!(
                CompactGen::destroy_8(val).unwrap_err(),
                CompactGenError::Retired
            );
        } else if val % 2 == 0 {
            // Valores pares menores a 254: libres / reciclables
            assert!(!CompactGen::is_live_8(val), "Par {val} no debe ser vivo");
            assert!(
                !CompactGen::is_retired_8(val),
                "Par {val} < 254 no está retirado"
            );
            // Destruir un slot ya destruido debe fallar
            assert_eq!(
                CompactGen::destroy_8(val).unwrap_err(),
                CompactGenError::InvalidInitialState
            );
            // Asignar transiciona a val + 1
            let next = CompactGen::allocate_8(val).unwrap();
            assert_eq!(next, val + 1);
            assert!(CompactGen::is_live_8(next));
        } else {
            // Valores impares menores a 254: objetos vivos
            assert!(CompactGen::is_live_8(val), "Impar {val} debe ser vivo");
            assert!(
                !CompactGen::is_retired_8(val),
                "Impar {val} no está retirado"
            );
            // Asignar un slot ya vivo debe fallar
            assert_eq!(
                CompactGen::allocate_8(val).unwrap_err(),
                CompactGenError::InvalidInitialState
            );
            // Destruir transiciona a val + 1 (o a 254 si val == 253)
            let next = CompactGen::destroy_8(val).unwrap();
            if val == 253 {
                assert_eq!(next, GEN_RETIRADO_8);
                assert!(CompactGen::is_retired_8(next));
            } else {
                assert_eq!(next, val + 1);
                assert!(!CompactGen::is_live_8(next));
            }
        }
    }
}

#[test]
fn test_compact_link_encoding_and_matching() {
    let pool_id = 7u8;
    let slot = 42u32;
    let generation_val = 5u16;

    let link = CompactLink::new(pool_id, slot, generation_val).unwrap();
    assert_eq!(link.pool_id(), 7);
    assert_eq!(link.slot(), 42);
    assert_eq!(link.generation(), 5);

    // Coincidencia exacta
    assert!(link.matches(7, 5));

    // Rechazo por pool incorrecto
    assert!(!link.matches(8, 5));

    // Rechazo por generación distinta viva
    assert!(!link.matches(7, 7));

    // Rechazo por generación par (destruida)
    assert!(!link.matches(7, 6));

    // Rechazo por generación retirada
    assert!(!link.matches(7, GEN_RETIRADO_8 as u16));
    assert!(!link.matches(7, GEN_RETIRADO_16));
}

#[test]
fn test_compact_link_no_8bit_collision_gen1_vs_gen257() {
    let pool_id = 1u8;
    let slot = 10u32;

    // Enlace creado en generación 1
    let link = CompactLink::new(pool_id, slot, 1).unwrap();
    assert!(link.matches(1, 1));

    // Demostrar que la generación 257 (que tendría el mismo byte bajo 0x01)
    // es RECHAZADA terminantemente sin colisión de hash
    assert!(
        !link.matches(1, 257),
        "Gen 257 no debe validar un enlace de gen 1"
    );

    // Intentar crear un enlace con generación >= 254 debe fallar por estar retirado
    let res = CompactLink::new(pool_id, slot, 257);
    assert_eq!(res.unwrap_err(), CompactLinkError::GenerationRetired);
}

#[test]
fn test_compact_link_slot_and_generation_boundaries() {
    // Pool ID 0 (inválido) rechazado
    assert_eq!(
        CompactLink::new(INVALID_COMPACT_POOL_ID, 10, 1).unwrap_err(),
        CompactLinkError::InvalidPoolId
    );

    // Slot mayor a 16 bits rechazado
    let overflow_slot = MAX_SLOT_COMPACT_32 + 1;
    assert_eq!(
        CompactLink::new(1, overflow_slot, 1).unwrap_err(),
        CompactLinkError::SlotOverflow
    );

    // Generación par (no viva) rechazada
    assert_eq!(
        CompactLink::new(1, 10, 2).unwrap_err(),
        CompactLinkError::InvalidState
    );

    // Generación retirada rechazada
    assert_eq!(
        CompactLink::new(1, 10, GEN_RETIRADO_8 as u16).unwrap_err(),
        CompactLinkError::GenerationRetired
    );
}

#[test]
fn test_compact_pool_registry_bounded_issuance() {
    let registry = CompactPoolRegistryInstance::new();

    // Asignar IDs hasta alcanzar el límite exacto de 255
    let mut allocated = Vec::new();
    while let Ok(id) = registry.acquire_id() {
        assert_ne!(id, INVALID_COMPACT_POOL_ID);
        allocated.push(id);
    }

    assert_eq!(allocated.len(), MAX_COMPACT_POOLS as usize);
    assert_eq!(allocated[0], 1);
    assert_eq!(allocated[MAX_COMPACT_POOLS as usize - 1], MAX_COMPACT_POOLS);

    // Una vez agotado, cualquier intento posterior debe retornar PoolIdExhausted
    assert_eq!(
        registry.acquire_id().unwrap_err(),
        CompactPoolError::PoolIdExhausted
    );

    // Verificar que jamás hubo wraparound a 0 ni a valores ya asignados
    assert!(registry.is_valid_id(1));
    assert!(registry.is_valid_id(MAX_COMPACT_POOLS));
    assert!(!registry.is_valid_id(INVALID_COMPACT_POOL_ID));
    assert_eq!(registry.allocated_count(), MAX_COMPACT_POOLS);
}

#[test]
fn test_compact_pool_registry_concurrent_issuance_no_duplicates() {
    use std::sync::Arc;
    let registry = Arc::new(CompactPoolRegistryInstance::new());
    let mut handles = Vec::new();

    for _ in 0..8 {
        let reg = registry.clone();
        handles.push(std::thread::spawn(move || {
            let mut issued = Vec::new();
            while let Ok(id) = reg.acquire_id() {
                issued.push(id);
            }
            issued
        }));
    }

    let mut all_issued = Vec::new();
    for h in handles {
        all_issued.extend(h.join().unwrap());
    }

    assert_eq!(all_issued.len(), MAX_COMPACT_POOLS as usize);
    all_issued.sort_unstable();
    all_issued.dedup();
    assert_eq!(all_issued.len(), MAX_COMPACT_POOLS as usize);
}

#[test]
fn test_compact_pool_registry_16_bounded_issuance() {
    let registry16 = CompactPoolRegistryInstance16::new();
    assert_eq!(registry16.allocated_count(), 0);
    assert!(!registry16.is_valid_id(INVALID_COMPACT_POOL_ID_16));
    assert!(!registry16.is_valid_id(1));

    let id1 = registry16.acquire_id().unwrap();
    assert_eq!(id1, 1);
    assert!(registry16.is_valid_id(1));
    assert!(!registry16.is_valid_id(2));
    assert_eq!(registry16.allocated_count(), 1);

    assert_eq!(MAX_COMPACT_POOLS_16, 65535);
    assert!(!CompactPoolRegistry16::is_valid_id(
        INVALID_COMPACT_POOL_ID_16
    ));
    assert!(!CompactPoolRegistry::is_valid_id(INVALID_COMPACT_POOL_ID));
}

#[test]
fn test_compact_link_authorized_revalidation_boundary() {
    let pool = nexo::next::compact::testing::MockCompactPool {
        id: 42,
        capacity: 100,
        generations: vec![1, 2, 3, GEN_RETIRADO_8], // 0: vivo (1), 1: par (2), 2: vivo (3), 3: retirado (254)
    };

    // Revalidación autorizada exitosa
    let link = CompactLink::new(42, 0, 1).unwrap();
    let obj: CompactObjRef<'_> = pool.revalidate_compact(link).unwrap();
    assert_eq!(obj.pool_id(), 42);
    assert_eq!(obj.slot(), 0);
    assert_eq!(obj.generation(), 1);

    // Revalidación fallida por pool foráneo
    let foreign = CompactLink::new(43, 0, 1).unwrap();
    assert_eq!(
        pool.revalidate_compact(foreign).unwrap_err(),
        CompactRevalidateError::ForeignPool
    );

    // Revalidación fallida por slot par (no asignado)
    let even = CompactLink::new(42, 1, 1).unwrap();
    assert_eq!(
        pool.revalidate_compact(even).unwrap_err(),
        CompactRevalidateError::SlotNotAllocated
    );

    // Revalidación fallida por generación stale
    let stale = CompactLink::new(42, 2, 1).unwrap();
    assert_eq!(
        pool.revalidate_compact(stale).unwrap_err(),
        CompactRevalidateError::StaleGeneration
    );

    // Revalidación fallida por generación retirada
    let ret_link = CompactLink::new(42, 3, 1).unwrap();
    assert_eq!(
        pool.revalidate_compact(ret_link).unwrap_err(),
        CompactRevalidateError::GenerationRetired
    );
}

#[test]
fn test_compact_link64_encoding_and_matching() {
    let pool_id = 1000u16;
    let slot = 1_000_000u32;
    let generation_val = 15u16;

    let link = CompactLink64::new(pool_id, slot, generation_val).unwrap();
    assert_eq!(link.pool_id(), 1000);
    assert_eq!(link.slot(), 1_000_000);
    assert_eq!(link.generation(), 15);

    // Coincidencia exacta
    assert!(link.matches(1000, 15));

    // Rechazo por pool incorrecto
    assert!(!link.matches(1001, 15));

    // Rechazo por generación par (destruida)
    assert!(!link.matches(1000, 16));

    // Rechazo por generación retirada en 16 bits
    assert!(!link.matches(1000, GEN_RETIRADO_16 as u32));
}

#[test]
fn test_compact_pool_token_unforgeability_and_monotonicity() {
    let token1: CompactPoolToken = CompactPoolRegistry::acquire_token().unwrap();
    let token2: CompactPoolToken = CompactPoolRegistry::acquire_token().unwrap();
    assert!(token2.id() > token1.id());

    let token16_1: CompactPoolToken16 = CompactPoolRegistry16::acquire_token().unwrap();
    let token16_2: CompactPoolToken16 = CompactPoolRegistry16::acquire_token().unwrap();
    assert!(token16_2.id() > token16_1.id());
}

#[test]
fn test_compact_physical_pool_adapter_integration() {
    let config = PoolConfig {
        fields: 2,
        slot_size: 64,
        max_superpages: 1,
        initial_generation: 0,
        fail_reserve: false,
        fail_commit_at: None,
        reclaim: ReclaimPolicy::Aggressive,
        protect_before_discard: true,
    };
    let mut physical_pool = PhysicalPool::new(config).unwrap();
    let token = CompactPoolRegistry::acquire_token().unwrap();

    // Asignar un slot en el pool físico
    let handle = physical_pool.allocate().unwrap();
    let slot = handle.slot();
    let generation_val = handle.generation();
    assert_eq!(generation_val, 1);

    // Crear un enlace compacto válido respaldado por el token legítimo
    let compact_link = CompactLink::new(token.id(), slot, generation_val as u16).unwrap();

    // 1. Revalidación autorizada a través del adaptador físico
    {
        let adapter = CompactPhysicalPool::new(&physical_pool, &token);
        let obj_ref = adapter.revalidate_compact(compact_link).unwrap();
        assert_eq!(obj_ref.pool_id(), token.id());
        assert_eq!(obj_ref.slot(), slot);
        assert_eq!(obj_ref.generation(), 1);

        // Rechazo por pool foráneo
        let foreign_token = CompactPoolRegistry::acquire_token().unwrap();
        let foreign_link = CompactLink::new(foreign_token.id(), slot, 1).unwrap();
        assert_eq!(
            adapter.revalidate_compact(foreign_link).unwrap_err(),
            CompactRevalidateError::ForeignPool
        );

        // Rechazo por slot fuera de límites (pero válido en 16 bits del CompactLink)
        let oob_link = CompactLink::new(token.id(), 60_000, 1).unwrap();
        assert_eq!(
            adapter.revalidate_compact(oob_link).unwrap_err(),
            CompactRevalidateError::OutOfBounds
        );
    }

    // 3. Destrucción del objeto físico
    let report = physical_pool.destroy(handle, false).unwrap();
    assert_eq!(report.header, HeaderStatus::Synced);

    // 4. Intentar revalidar el enlace compacto tras la destrucción -> Rechazado
    {
        let adapter = CompactPhysicalPool::new(&physical_pool, &token);
        let err = adapter.revalidate_compact(compact_link).unwrap_err();
        // El slot ahora tiene generación par (destruido/no asignado)
        assert_eq!(err, CompactRevalidateError::SlotNotAllocated);
    }

    // 5. Reasignar el slot (reutilización) -> avanza a generación 3
    let handle2 = physical_pool.allocate().unwrap();
    assert_eq!(handle2.slot(), slot);
    assert_eq!(handle2.generation(), 3);

    // El enlace antiguo (gen 1) ahora es stale frente a la nueva vida (gen 3)
    {
        let adapter = CompactPhysicalPool::new(&physical_pool, &token);
        let err = adapter.revalidate_compact(compact_link).unwrap_err();
        assert_eq!(err, CompactRevalidateError::StaleGeneration);
    }
}

#[test]
fn test_compact_pool_64_revalidation_and_adapter() {
    let pool64 = nexo::next::compact::testing::MockCompactPool64 {
        id: 100,
        capacity: 10_000,
        generations: vec![1, 2, 3, GEN_RETIRADO_16],
    };

    let link = CompactLink64::new(100, 0, 1).unwrap();
    let obj: CompactObjRef64<'_> = pool64.revalidate_compact_64(link).unwrap();
    assert_eq!(obj.pool_id(), 100);
    assert_eq!(obj.slot(), 0);
    assert_eq!(obj.generation(), 1);

    // Enlace foráneo
    let foreign = CompactLink64::new(101, 0, 1).unwrap();
    assert_eq!(
        pool64.revalidate_compact_64(foreign).unwrap_err(),
        CompactRevalidateError::ForeignPool
    );

    // Slot par (no asignado)
    let even = CompactLink64::new(100, 1, 1).unwrap();
    assert_eq!(
        pool64.revalidate_compact_64(even).unwrap_err(),
        CompactRevalidateError::SlotNotAllocated
    );

    // Stale
    let stale = CompactLink64::new(100, 2, 1).unwrap();
    assert_eq!(
        pool64.revalidate_compact_64(stale).unwrap_err(),
        CompactRevalidateError::StaleGeneration
    );

    // Retirado
    let retired = CompactLink64::new(100, 3, 1).unwrap();
    assert_eq!(
        pool64.revalidate_compact_64(retired).unwrap_err(),
        CompactRevalidateError::GenerationRetired
    );
}
