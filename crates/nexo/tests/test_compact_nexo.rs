//! Pruebas exhaustivas de generaciones compactas (16 bits y 8 bits),
//! registro de identidades de pool y enlaces compactos (32 bits y 64 bits).

use nexo::next::{
    CompactGen, CompactGenError, CompactLink, CompactLink64, CompactLinkError, CompactObjRef,
    CompactObjRef64, CompactPhysicalPool, CompactPhysicalPool64, CompactPoolAuthority,
    CompactPoolAuthority64, CompactPoolRegistry, CompactPoolRegistry16, CompactRevalidateError,
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
fn test_compact_pool_registry_public_api() {
    assert_eq!(MAX_COMPACT_POOLS, 255);
    assert_eq!(MAX_COMPACT_POOLS_16, 65535);
    assert!(!CompactPoolRegistry::is_valid_id(INVALID_COMPACT_POOL_ID));
    assert!(!CompactPoolRegistry16::is_valid_id(
        INVALID_COMPACT_POOL_ID_16
    ));

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
    let pool = PhysicalPool::new(config).unwrap();
    let allocated = CompactPoolRegistry::allocated_count();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    assert_eq!(CompactPoolRegistry::allocated_count(), allocated + 1);
    assert!(CompactPoolRegistry::is_valid_id(token.id()));
    assert!(CompactPoolRegistry::is_pool_registered(&pool));

    let allocated16 = CompactPoolRegistry16::allocated_count();
    let token16 = CompactPoolRegistry16::register_pool(&pool).unwrap();
    assert_eq!(CompactPoolRegistry16::allocated_count(), allocated16 + 1);
    assert!(CompactPoolRegistry16::is_valid_id(token16.id()));
    assert!(CompactPoolRegistry16::is_pool_registered(&pool));
}

#[test]
fn test_compact_link_authorized_revalidation_boundary() {
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
    let mut pool = PhysicalPool::new(config).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    let h0 = pool.allocate().unwrap();
    assert_eq!(h0.slot(), 0);
    assert_eq!(h0.generation(), 1);

    let h1 = pool.allocate().unwrap();
    let slot1 = h1.slot();
    let _ = pool.destroy(h1, false);

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();

    // Revalidación autorizada exitosa
    let link = CompactLink::new(token.id(), 0, 1).unwrap();
    let obj: CompactObjRef<'_> = adapter.revalidate_compact(link).unwrap();
    assert_eq!(obj.pool_id(), token.id());
    assert_eq!(obj.slot(), 0);
    assert_eq!(obj.generation(), 1);

    // Revalidación fallida por pool foráneo legítimo
    let pool_other = PhysicalPool::new(PoolConfig::default()).unwrap();
    let token_other = CompactPoolRegistry::register_pool(&pool_other).unwrap();
    let foreign = CompactLink::new(token_other.id(), 0, 1).unwrap();
    assert_eq!(
        adapter.revalidate_compact(foreign).unwrap_err(),
        CompactRevalidateError::ForeignPool
    );

    // Revalidación fallida por slot par (no asignado)
    let even = CompactLink::new(token.id(), slot1, 1).unwrap();
    assert_eq!(
        adapter.revalidate_compact(even).unwrap_err(),
        CompactRevalidateError::SlotNotAllocated
    );

    // Revalidación fallida por slot fuera de límites
    let oob = CompactLink::new(token.id(), 60_000, 1).unwrap();
    assert_eq!(
        adapter.revalidate_compact(oob).unwrap_err(),
        CompactRevalidateError::OutOfBounds
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
    let pool1 = PhysicalPool::new(config).unwrap();
    let pool2 = PhysicalPool::new(config).unwrap();

    let token1 = CompactPoolRegistry::register_pool(&pool1).unwrap();
    let token2 = CompactPoolRegistry::register_pool(&pool2).unwrap();
    assert!(token2.id() > token1.id());
    assert_eq!(token1.physical_pool_id(), pool1.id());
    assert_eq!(token2.physical_pool_id(), pool2.id());

    let token16_1 = CompactPoolRegistry16::register_pool(&pool1).unwrap();
    let token16_2 = CompactPoolRegistry16::register_pool(&pool2).unwrap();
    assert!(token16_2.id() > token16_1.id());
    assert_eq!(token16_1.physical_pool_id(), pool1.id());
    assert_eq!(token16_2.physical_pool_id(), pool2.id());
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
    let token = CompactPoolRegistry::register_pool(&physical_pool).unwrap();

    // Asignar un slot en el pool físico
    let handle = physical_pool.allocate().unwrap();
    let slot = handle.slot();
    let generation_val = handle.generation();
    assert_eq!(generation_val, 1);

    // Crear un enlace compacto válido respaldado por el token legítimo
    let compact_link = CompactLink::new(token.id(), slot, generation_val as u16).unwrap();

    // 1. Revalidación autorizada a través del adaptador físico
    {
        let adapter = CompactPhysicalPool::new(&physical_pool, &token).unwrap();
        let obj_ref = adapter.revalidate_compact(compact_link).unwrap();
        assert_eq!(obj_ref.pool_id(), token.id());
        assert_eq!(obj_ref.slot(), slot);
        assert_eq!(obj_ref.generation(), 1);

        // Rechazo por pool foráneo
        let foreign_pool = PhysicalPool::new(config).unwrap();
        let foreign_token = CompactPoolRegistry::register_pool(&foreign_pool).unwrap();
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
        let adapter = CompactPhysicalPool::new(&physical_pool, &token).unwrap();
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
        let adapter = CompactPhysicalPool::new(&physical_pool, &token).unwrap();
        let err = adapter.revalidate_compact(compact_link).unwrap_err();
        assert_eq!(err, CompactRevalidateError::StaleGeneration);
    }
}

#[test]
fn test_compact_pool_64_revalidation_and_adapter() {
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
    let token16 = CompactPoolRegistry16::register_pool(&physical_pool).unwrap();

    let handle = physical_pool.allocate().unwrap();
    let slot = handle.slot();
    let link = CompactLink64::new(token16.id(), slot, 1).unwrap();

    {
        let adapter = CompactPhysicalPool64::new(&physical_pool, &token16).unwrap();
        let obj: CompactObjRef64<'_> = adapter.revalidate_compact_64(link).unwrap();
        assert_eq!(obj.pool_id(), token16.id());
        assert_eq!(obj.slot(), slot);
        assert_eq!(obj.generation(), 1);

        // Enlace foráneo
        let foreign_pool = PhysicalPool::new(config).unwrap();
        let foreign_token = CompactPoolRegistry16::register_pool(&foreign_pool).unwrap();
        let foreign = CompactLink64::new(foreign_token.id(), slot, 1).unwrap();
        assert_eq!(
            adapter.revalidate_compact_64(foreign).unwrap_err(),
            CompactRevalidateError::ForeignPool
        );

        // Out of bounds
        let oob = CompactLink64::new(token16.id(), 10_000, 1).unwrap();
        assert_eq!(
            adapter.revalidate_compact_64(oob).unwrap_err(),
            CompactRevalidateError::OutOfBounds
        );
    }

    // Destruir objeto
    let _ = physical_pool.destroy(handle, false).unwrap();

    // Revalidación tras destrucción -> SlotNotAllocated
    {
        let adapter = CompactPhysicalPool64::new(&physical_pool, &token16).unwrap();
        assert_eq!(
            adapter.revalidate_compact_64(link).unwrap_err(),
            CompactRevalidateError::SlotNotAllocated
        );
    }

    // Reasignar slot -> gen 3
    let handle2 = physical_pool.allocate().unwrap();
    assert_eq!(handle2.slot(), slot);
    assert_eq!(handle2.generation(), 3);

    // Stale generation
    {
        let adapter = CompactPhysicalPool64::new(&physical_pool, &token16).unwrap();
        assert_eq!(
            adapter.revalidate_compact_64(link).unwrap_err(),
            CompactRevalidateError::StaleGeneration
        );
    }
}

/// Prueba dirigida de preservación de errores y equivalencia estricta entre 32 y 64 bits.
#[test]
fn test_adapter_32_and_64_equivalence_and_error_preservation() {
    let mut pool = PhysicalPool::new(PoolConfig {
        slot_size: 64,
        fields: 2,
        max_superpages: 1,
        ..PoolConfig::default()
    })
    .unwrap();

    let token32 = CompactPoolRegistry::register_pool(&pool).unwrap();
    let token64 = CompactPoolRegistry16::register_pool(&pool).unwrap();

    let h1 = pool.allocate().unwrap();
    let slot = h1.slot();
    let gen_val = h1.generation() as u16;
    let link32 = CompactLink::new(token32.id(), slot, gen_val).unwrap();
    let link64 = CompactLink64::new(token64.id(), slot, gen_val).unwrap();

    // 1. Éxito simétrico
    {
        let adapter32 = CompactPhysicalPool::new(&pool, &token32).unwrap();
        let adapter64 = CompactPhysicalPool64::new(&pool, &token64).unwrap();
        assert!(adapter32.revalidate_compact(link32).is_ok());
        assert!(adapter64.revalidate_compact_64(link64).is_ok());
    }

    // 2. ForeignPool simétrico mediante un segundo pool legítimo
    {
        let foreign_pool = PhysicalPool::new(PoolConfig {
            slot_size: 64,
            fields: 2,
            max_superpages: 1,
            ..PoolConfig::default()
        })
        .unwrap();
        let foreign_tok32 = CompactPoolRegistry::register_pool(&foreign_pool).unwrap();
        let foreign_tok64 = CompactPoolRegistry16::register_pool(&foreign_pool).unwrap();

        let adapter32 = CompactPhysicalPool::new(&pool, &token32).unwrap();
        let adapter64 = CompactPhysicalPool64::new(&pool, &token64).unwrap();
        let foreign32 = CompactLink::new(foreign_tok32.id(), slot, gen_val).unwrap();
        let foreign64 = CompactLink64::new(foreign_tok64.id(), slot, gen_val).unwrap();

        assert_eq!(
            adapter32.revalidate_compact(foreign32).unwrap_err(),
            CompactRevalidateError::ForeignPool
        );
        assert_eq!(
            adapter64.revalidate_compact_64(foreign64).unwrap_err(),
            CompactRevalidateError::ForeignPool
        );
    }

    // 3. OutOfBounds simétrico
    {
        let adapter32 = CompactPhysicalPool::new(&pool, &token32).unwrap();
        let adapter64 = CompactPhysicalPool64::new(&pool, &token64).unwrap();
        let oob_slot = adapter32.slot_capacity();
        let oob32 = CompactLink::new(token32.id(), oob_slot, 1).unwrap();
        let oob64 = CompactLink64::new(token64.id(), oob_slot, 1).unwrap();

        assert_eq!(
            adapter32.revalidate_compact(oob32).unwrap_err(),
            CompactRevalidateError::OutOfBounds
        );
        assert_eq!(
            adapter64.revalidate_compact_64(oob64).unwrap_err(),
            CompactRevalidateError::OutOfBounds
        );
    }

    // 4. StaleGeneration simétrico tras destruir y reasignar slot
    pool.destroy(h1, false).unwrap();
    let h2 = pool.allocate().unwrap();
    assert_eq!(h2.slot(), slot);
    assert_eq!(h2.generation(), (gen_val + 2) as u32);
    {
        let adapter32 = CompactPhysicalPool::new(&pool, &token32).unwrap();
        let adapter64 = CompactPhysicalPool64::new(&pool, &token64).unwrap();

        assert_eq!(
            adapter32.revalidate_compact(link32).unwrap_err(),
            CompactRevalidateError::StaleGeneration
        );
        assert_eq!(
            adapter64.revalidate_compact_64(link64).unwrap_err(),
            CompactRevalidateError::StaleGeneration
        );
    }

    // 5. Destrucción final y cierre del pool
    let orig_link = h2.link();
    pool.destroy(h2, false).unwrap();
    pool.close().unwrap();

    // 6. Rechazo en constructores de adaptador sobre pool cerrado
    assert_eq!(
        CompactPhysicalPool::new(&pool, &token32).unwrap_err(),
        nexo::next::CompactPoolError::PoolClosed
    );
    assert_eq!(
        CompactPhysicalPool64::new(&pool, &token64).unwrap_err(),
        nexo::next::CompactPoolError::PoolClosed
    );

    // 7. Revalidación directa sobre pool cerrado preserva error Closed
    assert_eq!(
        pool.revalidate(orig_link),
        Err(nexo::physical::PoolError::Closed)
    );
}

/// Verifica exhaustivamente las cotas de identificadores compactos:
/// ID mínimo (1), ID máximo (255 y 65535), ID cero inválido (0),
/// agotamiento sin colisiones y rechazo estricto de identidades foráneas.
#[test]
fn test_compact_id_boundary_invariants() {
    // 1. ID cero es inválido en enlaces compactos de 32 y 64 bits
    assert_eq!(
        CompactLink::new(0, 0, 1).unwrap_err(),
        nexo::next::compact::CompactLinkError::InvalidPoolId
    );
    assert_eq!(
        CompactLink64::new(0, 0, 1).unwrap_err(),
        nexo::next::compact::CompactLinkError::InvalidPoolId
    );

    // 2. ID mínimo legítimo es 1
    assert!(CompactLink::new(1, 0, 1).is_ok());
    assert!(CompactLink64::new(1, 0, 1).is_ok());

    // 3. ID máximo legítimo: 255 para 8-bit, 65535 para 16-bit
    assert!(CompactLink::new(255, 0, 1).is_ok());
    assert!(CompactLink64::new(65535, 0, 1).is_ok());

    // 4. Agotamiento y ausencia de colisiones en asignador aislado de 8 bits
    let alloc8 = nexo::next::compact::CompactIdAllocator8::new();
    assert_eq!(alloc8.allocated_count(), 0);
    assert!(!alloc8.is_valid_id(0));
    assert!(!alloc8.is_valid_id(1));

    let mut ids = std::collections::HashSet::new();
    for _ in 1..=255u8 {
        let id = alloc8.allocate_id().unwrap();
        assert!(id >= 1);
        assert!(
            ids.insert(id),
            "Colisión detectada en ID compacto 8b: {}",
            id
        );
    }
    assert_eq!(ids.len(), 255);
    assert_eq!(alloc8.allocated_count(), 255);
    assert_eq!(
        alloc8.allocate_id().unwrap_err(),
        nexo::next::CompactPoolError::PoolIdExhausted
    );

    // 5. Asignador de 16 bits: verificar límites mínimo, máximo y agotamiento
    let alloc16 = nexo::next::compact::CompactIdAllocator16::new();
    let id1 = alloc16.allocate_id().unwrap();
    assert_eq!(id1, 1);
    assert!(alloc16.is_valid_id(1));
    assert!(!alloc16.is_valid_id(0));
    assert_eq!(alloc16.allocated_count(), 1);
}
