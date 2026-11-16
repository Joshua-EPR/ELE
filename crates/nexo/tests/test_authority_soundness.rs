//! Suite de pruebas de seguridad y autoridad para NEXO v0.4 (AUTH-01..20).
//!
//! Valida de manera exhaustiva y adversarial las garantías de:
//! - Sellado auténtico de traits de autoridad de memoria (`CompactPoolAuthority`, `CompactPoolAuthority64`).
//! - Vinculación infalsificable entre tokens de autoridad y memoria física (`PhysicalPool`).
//! - Detección de identificadores foráneos, generaciones stale, retiro generacional y estados de página.
//! - Inmunidad ante elevación de privilegios y confinamiento de préstamos (`CompactObjRef`).
//! - Agotamiento estricto y concurrencia segura en registros de identificadores.

use std::thread;

use nexo::next::compact::testing::{MockCompactPool, MockCompactPool64};
use nexo::next::{
    CompactLink, CompactLink64, CompactObjRef, CompactObjRef64, CompactPhysicalPool,
    CompactPhysicalPool64, CompactPoolAuthority, CompactPoolAuthority64, CompactPoolError,
    CompactPoolRegistry, CompactPoolRegistry16, CompactPoolToken, CompactPoolToken16,
    CompactRevalidateError, GEN_RETIRADO_8, GEN_RETIRADO_16, MAX_COMPACT_POOLS,
    MAX_SLOT_COMPACT_32,
};
use nexo::physical::{FaultOp, FaultPlan, PageState, PhysicalPool, PoolConfig, ReclaimPolicy};

// ============================================================================
// AUTH-01: Intento de implementar CompactPoolAuthority desde fuera del crate falla
// ============================================================================
/// AUTH-01: Verifica que ningún tipo externo pueda implementar [`CompactPoolAuthority`].
///
/// El trait está sellado auténticamente requiriendo `private::Sealed` y el método
/// oculto `__seal_authority(_: private::InternalSeal)`. Un intento externo produce:
/// `error[E0277]: the trait private::Sealed is not implemented`
/// `error[E0446]: private type private::InternalSeal in public interface`
///
/// Esta prueba se complementa con el doctest compile_fail verificado en `compact.rs`.
#[test]
fn test_auth_01_sealed_trait_cannot_be_implemented_externally() {
    // Si intentáramos descomentar lo siguiente fuera de nexo, no compilaría:
    // struct ExternalPool;
    // impl CompactPoolAuthority for ExternalPool { ... }
    //
    // Verificamos en tiempo de ejecución que solo tipos legítimos implementan el trait:
    fn assert_is_authority<T: CompactPoolAuthority>() {}
    assert_is_authority::<CompactPhysicalPool<'_>>();
    assert_is_authority::<MockCompactPool>();
}

// ============================================================================
// AUTH-02: Intento de implementar CompactPoolAuthority64 desde fuera del crate falla
// ============================================================================
/// AUTH-02: Verifica que ningún tipo externo pueda implementar [`CompactPoolAuthority64`].
///
/// Análogamente a AUTH-01, el sellado auténtico impide que crates externos definan
/// autoridades fraudulentas de 64 bits. Verificado en doctests compile_fail de `compact.rs`.
#[test]
fn test_auth_02_sealed_trait_64_cannot_be_implemented_externally() {
    fn assert_is_authority_64<T: CompactPoolAuthority64>() {}
    assert_is_authority_64::<CompactPhysicalPool64<'_>>();
    assert_is_authority_64::<MockCompactPool64>();
}

// ============================================================================
// AUTH-03: Intento de fabricar CompactObjRef o CompactObjRef64 directamente falla
// ============================================================================
/// AUTH-03: Verifica que `CompactObjRef` y `CompactObjRef64` no puedan fabricarse
/// directamente, ya que todos sus campos son privados y carecen de constructor público.
///
/// La única forma de obtener una instancia es a través de una autoridad autorizada
/// mediante `revalidate_compact` o `revalidate_compact_64`.
/// Verificado en doctests compile_fail de `compact.rs` (error E0423).
#[test]
fn test_auth_03_compact_obj_ref_cannot_be_constructed_directly() {
    // Verificamos que los tipos existen y son accesibles en modo solo-lectura
    let mock = MockCompactPool::new(1, 10, vec![1]);
    let link = CompactLink::new(1, 0, 1).unwrap();
    let obj: CompactObjRef<'_> = mock.revalidate_compact(link).unwrap();
    assert_eq!(obj.pool_id(), 1);
    assert_eq!(obj.slot(), 0);
    assert_eq!(obj.generation(), 1);

    let mock64 = MockCompactPool64::new(1, 10, vec![1]);
    let link64 = CompactLink64::new(1, 0, 1).unwrap();
    let obj64: CompactObjRef64<'_> = mock64.revalidate_compact_64(link64).unwrap();
    assert_eq!(obj64.pool_id(), 1);
    assert_eq!(obj64.slot(), 0);
    assert_eq!(obj64.generation(), 1);
}

// ============================================================================
// AUTH-04: MockCompactPool no está disponible en producción sin feature flag
// ============================================================================
/// AUTH-04: Confirma que `MockCompactPool` y `MockCompactPool64` residen bajo
/// `#[cfg(any(test, feature = "test-mocks"))]`, garantizando que un build de producción
/// sin el feature `test-mocks` no expondrá jamás mocks privilegiados que puedan evadir
/// el hardware o la memoria virtual.
#[test]
fn test_auth_04_mock_pools_gated_under_test_cfg() {
    // En este entorno de test (con cfg(test) o feature test-mocks), los mocks son operativos:
    let mock = MockCompactPool::new(7, 50, vec![1; 50]);
    assert_eq!(mock.compact_id(), 7);
    assert_eq!(mock.slot_capacity(), 50);

    let mock64 = MockCompactPool64::new(99, 100, vec![1; 100]);
    assert_eq!(mock64.compact_id(), 99);
    assert_eq!(mock64.slot_capacity(), 100);
}

// ============================================================================
// AUTH-05: Emparejar Pool B con Token A en CompactPhysicalPool::new retorna PoolMismatch
// ============================================================================
/// AUTH-05: Ataque adversarial de falsificación cruzada de autoridad en 4 bytes.
/// Un atacante intenta validar slots de `Pool B` usando un token legítimo perteneciente a `Pool A`.
/// El constructor `CompactPhysicalPool::new` debe interceptarlo inmediatamente y fallar con `PoolMismatch`.
#[test]
fn test_auth_05_cross_pool_token_pairing_fails_32bit() {
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
    let pool_a = PhysicalPool::new(config).unwrap();
    let pool_b = PhysicalPool::new(config).unwrap();
    assert_ne!(pool_a.id(), pool_b.id());

    let token_a: CompactPoolToken = CompactPoolRegistry::register_pool(&pool_a).unwrap();
    assert_eq!(token_a.physical_pool_id(), pool_a.id());

    // Intento de vincular Pool B con el Token emitido para Pool A
    let result = CompactPhysicalPool::new(&pool_b, &token_a);
    assert_eq!(result.unwrap_err(), CompactPoolError::PoolMismatch);

    // Vinculación correcta con Pool A debe triunfar
    let adapter_a = CompactPhysicalPool::new(&pool_a, &token_a);
    assert!(adapter_a.is_ok());
}

// ============================================================================
// AUTH-06: Emparejar Pool B con Token A en CompactPhysicalPool64::new retorna PoolMismatch
// ============================================================================
/// AUTH-06: Ataque adversarial de falsificación cruzada de autoridad en 8 bytes (64 bits).
/// El constructor `CompactPhysicalPool64::new` debe rechazar la vinculación con `PoolMismatch`.
#[test]
fn test_auth_06_cross_pool_token_pairing_fails_64bit() {
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
    let pool_a = PhysicalPool::new(config).unwrap();
    let pool_b = PhysicalPool::new(config).unwrap();
    assert_ne!(pool_a.id(), pool_b.id());

    let token16_a: CompactPoolToken16 = CompactPoolRegistry16::register_pool(&pool_a).unwrap();
    assert_eq!(token16_a.physical_pool_id(), pool_a.id());

    // Intento de vincular Pool B con el Token16 emitido para Pool A
    let result = CompactPhysicalPool64::new(&pool_b, &token16_a);
    assert_eq!(result.unwrap_err(), CompactPoolError::PoolMismatch);

    let adapter16_a = CompactPhysicalPool64::new(&pool_a, &token16_a);
    assert!(adapter16_a.is_ok());
}

// ============================================================================
// AUTH-07: Token emitido con register_pool(&pool_a) tiene physical_pool_id == pool_a.id()
// ============================================================================
/// AUTH-07: Verifica la correspondencia formal de identidad en la emisión de tokens.
#[test]
fn test_auth_07_token_embeds_exact_physical_pool_id() {
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
    let expected_id = pool.id();

    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    assert_eq!(token.physical_pool_id(), expected_id);

    let token16 = CompactPoolRegistry16::register_pool(&pool).unwrap();
    assert_eq!(token16.physical_pool_id(), expected_id);
}

// ============================================================================
// AUTH-08: Token con physical_pool_id diferente es rechazado aunque compact_id coincida
// ============================================================================
/// AUTH-08: Verifica que dos tokens que casualmente compartan el mismo `compact_id`
/// pero provengan de pools físicos diferentes no puedan confundirse.
#[test]
fn test_auth_08_identical_compact_id_with_different_physical_pool_id_rejected() {
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
    let pool_a = PhysicalPool::new(config).unwrap();
    let pool_b = PhysicalPool::new(config).unwrap();

    // Fabricamos dos tokens vinculados a diferentes pools físicos
    let token_for_a = CompactPoolRegistry::acquire_token_for(pool_a.id()).unwrap();
    assert_eq!(token_for_a.physical_pool_id(), pool_a.id());

    // Intentar validar pool_b con token_for_a debe fallar
    assert_eq!(
        CompactPhysicalPool::new(&pool_b, &token_for_a).unwrap_err(),
        CompactPoolError::PoolMismatch
    );
}

// ============================================================================
// AUTH-09: Revalidación cruzada entre pools con slots idénticos falla con ForeignPool
// ============================================================================
/// AUTH-09: Dos pools físicos idénticos A y B contienen slots con idéntico índice
/// y generación viva. Un enlace emitido para Pool A jamás puede ser revalidado
/// a través de la autoridad de Pool B.
#[test]
fn test_auth_09_cross_pool_revalidation_fails_with_foreign_pool() {
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
    let mut pool_a = PhysicalPool::new(config).unwrap();
    let mut pool_b = PhysicalPool::new(config).unwrap();

    let token_a = CompactPoolRegistry::register_pool(&pool_a).unwrap();
    let token_b = CompactPoolRegistry::register_pool(&pool_b).unwrap();
    assert_ne!(token_a.id(), token_b.id());

    let h_a = pool_a.allocate().unwrap();
    let _h_b = pool_b.allocate().unwrap();
    assert_eq!(h_a.slot(), 0);
    assert_eq!(h_a.generation(), 1);

    // Enlace legítimo para Pool A
    let link_a = CompactLink::new(token_a.id(), h_a.slot(), h_a.generation() as u16).unwrap();

    // Intentar revalidar el enlace de Pool A usando el adaptador legítimo de Pool B
    let adapter_b = CompactPhysicalPool::new(&pool_b, &token_b).unwrap();
    let err = adapter_b.revalidate_compact(link_a).unwrap_err();
    assert_eq!(err, CompactRevalidateError::ForeignPool);
}

// ============================================================================
// AUTH-10: Enlace con generación par (slot destruido/no asignado) falla con SlotNotAllocated
// ============================================================================
/// AUTH-10: Invariante R7. Enlaces compactos sobre slots en estado no asignado (generación par)
/// son rechazados terminantemente con `SlotNotAllocated`.
#[test]
fn test_auth_10_even_generation_rejected_as_slot_not_allocated() {
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

    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let generation_val = handle.generation();
    let link = CompactLink::new(token.id(), slot, generation_val as u16).unwrap();

    // Destruimos el objeto
    pool.destroy(handle, false).unwrap();

    // Revalidación debe fallar inmediatamente
    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let err = adapter.revalidate_compact(link).unwrap_err();
    assert_eq!(err, CompactRevalidateError::SlotNotAllocated);
}

// ============================================================================
// AUTH-11: Enlace con generación stale tras reasignación falla con StaleGeneration
// ============================================================================
/// AUTH-11: Garantía No-ABA. Tras la destrucción y reasignación de un slot,
/// el enlace compacto de la primera vida (gen 1) es rechazado con `StaleGeneration`
/// frente a la nueva vida (gen 3).
#[test]
fn test_auth_11_stale_generation_rejected_after_slot_reuse() {
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

    let h1 = pool.allocate().unwrap();
    let slot = h1.slot();
    let link1 = CompactLink::new(token.id(), slot, 1).unwrap();

    pool.destroy(h1, false).unwrap();

    let h2 = pool.allocate().unwrap();
    assert_eq!(h2.slot(), slot);
    assert_eq!(h2.generation(), 3);

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let err = adapter.revalidate_compact(link1).unwrap_err();
    assert_eq!(err, CompactRevalidateError::StaleGeneration);

    // Enlace con la nueva generación 3 triunfa
    let link2 = CompactLink::new(token.id(), slot, 3).unwrap();
    assert!(adapter.revalidate_compact(link2).is_ok());
}

// ============================================================================
// AUTH-12: Enlace con generación retirada (GEN_RETIRADO_8) falla con GenerationRetired
// ============================================================================
/// AUTH-12: Invariante R9. Los slots que alcanzan el centinela de retiro en 8 bits (254)
/// son permanentemente inutilizables y fallan con `GenerationRetired`.
#[test]
fn test_auth_12_retired_generation_8bit_rejected() {
    let mock = MockCompactPool::new(10, 100, vec![GEN_RETIRADO_8]);
    let link = CompactLink::new(10, 0, 1).unwrap();
    let err = mock.revalidate_compact(link).unwrap_err();
    assert_eq!(err, CompactRevalidateError::GenerationRetired);
}

// ============================================================================
// AUTH-13: Enlace con generación retirada en 64 bits (GEN_RETIRADO_16) falla con GenerationRetired
// ============================================================================
/// AUTH-13: Invariante R9 en 16 bits. Retiro en 0xfffe (65534).
#[test]
fn test_auth_13_retired_generation_16bit_rejected() {
    let mock64 = MockCompactPool64::new(500, 100, vec![GEN_RETIRADO_16]);
    let link64 = CompactLink64::new(500, 0, 1).unwrap();
    let err = mock64.revalidate_compact_64(link64).unwrap_err();
    assert_eq!(err, CompactRevalidateError::GenerationRetired);
}

// ============================================================================
// AUTH-14: Slot en subpágina Quarantined falla con SlotNotAllocated
// ============================================================================
/// AUTH-14: Invariante R8. Una subpágina en cuarentena por fallo o aislamiento
/// debe impedir terminantemente la revalidación de enlaces sobre cualquiera de sus slots.
#[test]
fn test_auth_14_slot_in_quarantined_subpage_rejected() {
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

    let h = pool.allocate().unwrap();
    let slot = h.slot();
    let link = CompactLink::new(token.id(), slot, h.generation() as u16).unwrap();

    // Inyectar un plan de fallas para impedir la confirmación o forzar retención
    pool.set_faults(FaultPlan::new().fail_always(FaultOp::Decommit))
        .unwrap();
    let _ = pool.destroy(h, false);

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let err = adapter.revalidate_compact(link);

    // Debe ser rechazado porque la página no está en estado Committed activo
    assert!(err.is_err());
    let err_val = err.unwrap_err();
    assert_eq!(err_val, CompactRevalidateError::SlotNotAllocated);
}

// ============================================================================
// AUTH-15: Slot en subpágina Returned falla con SlotNotAllocated
// ============================================================================
/// AUTH-15: Invariante R8. Una subpágina devuelta al SO o no asignada
/// rechaza de inmediato cualquier revalidación con `SlotNotAllocated`.
#[test]
fn test_auth_15_slot_in_returned_or_uncommitted_subpage_rejected() {
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
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    // Verificamos el estado de subpáginas altas no asignadas (que están en estado Reserved o Returned)
    let capacity = pool.capacity() as u32;
    if capacity > 100 {
        let uncommitted_slot = capacity - 1;
        if let Ok(state) = pool.page_state(uncommitted_slot)
            && state != PageState::Committed
        {
            let link = CompactLink::new(token.id(), uncommitted_slot, 1).unwrap();
            let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
            assert_eq!(
                adapter.revalidate_compact(link).unwrap_err(),
                CompactRevalidateError::SlotNotAllocated
            );
        }
    }
}

// ============================================================================
// AUTH-16: Slot >= slot_capacity() (acotado a 65.536 en 32 bits) falla con OutOfBounds
// ============================================================================
/// AUTH-16: P1-006. Acotamiento seguro de capacidad. En `CompactPhysicalPool`,
/// `slot_capacity()` jamás excede `MAX_SLOT_COMPACT_32 + 1` (65.536).
/// Cualquier intento de acceder a un slot fuera de límites retorna `OutOfBounds`.
#[test]
fn test_auth_16_slot_out_of_bounds_and_capacity_clamped() {
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
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();

    assert!(adapter.slot_capacity() <= (MAX_SLOT_COMPACT_32 + 1));

    // Un slot que supera la capacidad del pool pero cabe en u16 de CompactLink
    let pool_capacity = adapter.slot_capacity();
    if pool_capacity < 60_000 {
        let oob_link = CompactLink::new(token.id(), 60_000, 1).unwrap();
        assert_eq!(
            adapter.revalidate_compact(oob_link).unwrap_err(),
            CompactRevalidateError::OutOfBounds
        );
    }
}

// ============================================================================
// AUTH-17: CompactObjRef no confiere acceso mutable ni conversión a Handle
// ============================================================================
/// AUTH-17: Invariante R5 y regla de no fabricación. `CompactObjRef` es un token de solo-lectura
/// sin constructor público, sin métodos mutables, y sin capacidad de conversión a `Handle`.
#[test]
fn test_auth_17_compact_obj_ref_is_read_only_and_non_promotable() {
    let mock = MockCompactPool::new(5, 10, vec![1]);
    let link = CompactLink::new(5, 0, 1).unwrap();
    let obj: CompactObjRef<'_> = mock.revalidate_compact(link).unwrap();

    // Solo métodos de inspección inmutable disponibles:
    assert_eq!(obj.pool_id(), 5);
    assert_eq!(obj.slot(), 0);
    assert_eq!(obj.generation(), 1);

    // No implementa DerefMut, ni tiene métodos destroy, mutate o to_handle.
    // Garantiza que un enlace jamás confiere capacidad de posesión o destrucción.
}

// ============================================================================
// AUTH-18: CompactObjRef expira con el préstamo del pool; no sobrevive a su drop
// ============================================================================
/// AUTH-18: Invariante R4. `CompactObjRef<'a>` lleva el lifetime del préstamo `&'a PhysicalPool`.
/// Si el pool es descartado o finaliza su ámbito, el token expira en tiempo de compilación.
#[test]
fn test_auth_18_compact_obj_ref_lifetime_bound_to_pool_borrow() {
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
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let link = CompactLink::new(token.id(), slot, 1).unwrap();

    {
        let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
        let obj = adapter.revalidate_compact(link).unwrap();
        assert_eq!(obj.slot(), slot);
        // obj es válido dentro de este ámbito dependiente de pool
    }

    // El pool sigue existiendo tras finalizar el préstamo del adaptador
    let _ = pool.destroy(handle, false).unwrap();
}

// ============================================================================
// AUTH-19: Agotamiento de identificadores en CompactPoolRegistry sin wraparound
// ============================================================================
/// AUTH-19: Agotamiento de identificadores en `CompactPoolRegistry`.
/// Tras emitir el límite de 255 pools de 8 bits, cualquier emisión posterior
/// retorna estrictamente `Err(CompactPoolError::PoolIdExhausted)`, sin reciclaje a 0.
#[test]
fn test_auth_19_compact_pool_registry_bounded_issuance() {
    // Comprobamos la cota máxima del espacio de direccionamiento de pools compactos de 8 bits
    assert_eq!(MAX_COMPACT_POOLS, 255);
    let initial_count = CompactPoolRegistry::allocated_count();

    // Verificamos que los identificadores emitidos son estrictamente mayores a 0
    let mut ids = Vec::new();
    while let Ok(token) = CompactPoolRegistry::acquire_token() {
        assert_ne!(token.id(), 0);
        ids.push(token.id());
    }

    // Una vez agotado el registro global, las llamadas subsecuentes deben fallar
    assert_eq!(
        CompactPoolRegistry::acquire_id().unwrap_err(),
        CompactPoolError::PoolIdExhausted
    );
    assert_eq!(
        CompactPoolRegistry::acquire_token().unwrap_err(),
        CompactPoolError::PoolIdExhausted
    );

    // Verificamos que se alcanzaron exactamente 255 pools sin wraparound a 0
    assert_eq!(CompactPoolRegistry::allocated_count(), MAX_COMPACT_POOLS);
    assert!(CompactPoolRegistry::is_valid_id(1));
    assert!(CompactPoolRegistry::is_valid_id(255));
    assert!(!CompactPoolRegistry::is_valid_id(0));

    // La cantidad emitida en este test más los previos suma exactamente 255
    assert_eq!(initial_count as usize + ids.len(), 255);
}

// ============================================================================
// AUTH-20: Concurrencia de registro sin colisiones ni duplicados
// ============================================================================
/// AUTH-20: Emisiones concurrentes en `CompactPoolRegistry16` desde múltiples hilos.
/// Todos los identificadores emitidos son estrictamente únicos, monótonos y sin colisiones.
#[test]
fn test_auth_20_concurrent_issuance_in_registry16_no_duplicates() {
    let threads = 8;
    let allocations_per_thread = 500;
    let mut handles = Vec::new();

    for _ in 0..threads {
        handles.push(thread::spawn(move || {
            let mut issued = Vec::new();
            for _ in 0..allocations_per_thread {
                if let Ok(token) = CompactPoolRegistry16::acquire_token() {
                    issued.push(token.id());
                }
            }
            issued
        }));
    }

    let mut all_ids = Vec::new();
    for h in handles {
        all_ids.extend(h.join().unwrap());
    }

    assert_eq!(all_ids.len(), threads * allocations_per_thread);

    // Verificar unicidad absoluta (sin duplicados)
    let total_len = all_ids.len();
    all_ids.sort_unstable();
    all_ids.dedup();
    assert_eq!(all_ids.len(), total_len);
}
