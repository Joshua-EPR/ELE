//! Suite de pruebas de seguridad y autoridad para NEXO v0.4 (AUTH-01..20).
//!
//! Valida de manera exhaustiva y adversarial las garantías de:
//! - Sellado auténtico de traits de autoridad de memoria (`CompactPoolAuthority`, `CompactPoolAuthority64`).
//! - Vinculación infalsificable entre tokens de autoridad y memoria física (`PhysicalPool`).
//! - Rechazo estricto de registros duplicados por identidad física (`AlreadyRegistered`).
//! - Detección de identificadores foráneos, generaciones stale, retiro generacional y estados de página (incluyendo `SubpageQuarantined`).
//! - Inmunidad ante elevación de privilegios y confinamiento de préstamos (`CompactObjRef`).
//! - Agotamiento estricto y concurrencia segura en instancias aisladas de asignadores numéricos.

use std::process::Command;
use std::sync::Arc;
use std::thread;

use nexo::next::{
    CompactIdAllocator8, CompactIdAllocator16, CompactLink, CompactLink64, CompactObjRef,
    CompactObjRef64, CompactPhysicalPool, CompactPhysicalPool64, CompactPoolAuthority,
    CompactPoolAuthority64, CompactPoolError, CompactPoolRegistry, CompactPoolRegistry16,
    CompactPoolToken, CompactPoolToken16, CompactRevalidateError, GEN_RETIRADO_8, GEN_RETIRADO_16,
    MAX_COMPACT_POOLS, MAX_SLOT_COMPACT_32,
};
use nexo::physical::{FaultOp, FaultPlan, PageState, PhysicalPool, PoolConfig, ReclaimPolicy};

fn run_fixture_check(feature: &str) -> (bool, String) {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let fixture_dir = std::path::Path::new(manifest_dir)
        .join("tests")
        .join("fixtures")
        .join("external_consumer");

    let mut cmd = Command::new(env!("CARGO"));
    cmd.current_dir(&fixture_dir)
        .arg("check")
        .arg("--features")
        .arg(feature);

    let output = cmd
        .output()
        .expect("failed to execute cargo check on fixture");
    let success = output.status.success();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    (success, stderr)
}

fn test_pool_config() -> PoolConfig {
    PoolConfig {
        fields: 2,
        slot_size: 64,
        max_superpages: 1,
        initial_generation: 0,
        fail_reserve: false,
        fail_commit_at: None,
        reclaim: ReclaimPolicy::Aggressive,
        protect_before_discard: true,
    }
}

// ============================================================================
// AUTH-01: Intento de implementar CompactPoolAuthority desde fuera del crate falla
// ============================================================================
/// AUTH-01: Verifica mediante compilación externa real que ningún tipo externo
/// pueda implementar [`CompactPoolAuthority`].
#[test]
fn test_auth_01_sealed_trait_cannot_be_implemented_externally() {
    let (success, stderr) = run_fixture_check("implement-sealed-authority");
    assert!(
        !success,
        "La compilación externa debió ser rechazada por trait sellado"
    );
    assert!(
        stderr.contains("E0277") || stderr.contains("sealed"),
        "Se esperaba error E0277 o mención de trait sellado, recibido:\n{stderr}"
    );

    // Tipos legítimos del crate implementan el trait:
    fn assert_is_authority<T: CompactPoolAuthority>() {}
    assert_is_authority::<CompactPhysicalPool<'_>>();
}

// ============================================================================
// AUTH-02: Intento de implementar CompactPoolAuthority64 desde fuera del crate falla
// ============================================================================
/// AUTH-02: Verifica mediante compilación externa real que ningún tipo externo
/// pueda implementar [`CompactPoolAuthority64`].
#[test]
fn test_auth_02_sealed_trait_64_cannot_be_implemented_externally() {
    let (success, stderr) = run_fixture_check("implement-sealed-authority-64");
    assert!(
        !success,
        "La compilación externa debió ser rechazada por trait sellado de 64 bits"
    );
    assert!(
        stderr.contains("E0277") || stderr.contains("sealed"),
        "Se esperaba error E0277 o mención de trait sellado, recibido:\n{stderr}"
    );

    fn assert_is_authority_64<T: CompactPoolAuthority64>() {}
    assert_is_authority_64::<CompactPhysicalPool64<'_>>();
}

// ============================================================================
// AUTH-03: Intento de fabricar CompactObjRef o CompactObjRef64 directamente falla
// ============================================================================
/// AUTH-03: Verifica que `CompactObjRef` no puede construirse con sintaxis de struct,
/// y comprueba que la revalidación autorizada legítima funciona con pools reales.
#[test]
fn test_auth_03_compact_obj_ref_cannot_be_constructed_directly() {
    let (success, stderr) = run_fixture_check("construct-objref-struct");
    assert!(
        !success,
        "La construcción directa de referencias de objeto debió ser rechazada"
    );
    assert!(
        stderr.contains("E0423") || stderr.contains("E0451") || stderr.contains("E0560"),
        "Se esperaba rechazo de constructor de struct, recibido:\n{stderr}"
    );

    // Vía autorizada legítima sobre pool físico real
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    let token16 = CompactPoolRegistry16::register_pool(&pool).unwrap();

    let handle = pool.allocate().unwrap();
    let slot = handle.slot();

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let link = CompactLink::new(token.id(), slot, 1).unwrap();
    let obj: CompactObjRef<'_> = adapter.revalidate_compact(link).unwrap();
    assert_eq!(obj.pool_id(), token.id());
    assert_eq!(obj.slot(), slot);
    assert_eq!(obj.generation(), 1);

    let adapter16 = CompactPhysicalPool64::new(&pool, &token16).unwrap();
    let link64 = CompactLink64::new(token16.id(), slot, 1).unwrap();
    let obj64: CompactObjRef64<'_> = adapter16.revalidate_compact_64(link64).unwrap();
    assert_eq!(obj64.pool_id(), token16.id());
    assert_eq!(obj64.slot(), slot);
    assert_eq!(obj64.generation(), 1);
}

// ============================================================================
// AUTH-04: MockCompactPool no está disponible en producción
// ============================================================================
/// AUTH-04: Confirma que ningún mock de test está expuesto en la API pública de la librería.
#[test]
fn test_auth_04_mock_pools_gated_under_test_cfg() {
    let (success, stderr) = run_fixture_check("access-mock-compact-pool");
    assert!(
        !success,
        "El módulo de mocks no debe ser accesible desde crates externos"
    );
    assert!(
        stderr.contains("E0433") || stderr.contains("testing"),
        "Se esperaba error E0433 indicando que testing no existe en la API pública, recibido:\n{stderr}"
    );
}

// ============================================================================
// AUTH-05: Emparejar Pool B con Token A en CompactPhysicalPool::new retorna PoolMismatch
// ============================================================================
/// AUTH-05: Ataque adversarial de falsificación cruzada de autoridad en 4 bytes.
#[test]
fn test_auth_05_cross_pool_token_pairing_fails_32bit() {
    let pool_a = PhysicalPool::new(test_pool_config()).unwrap();
    let pool_b = PhysicalPool::new(test_pool_config()).unwrap();
    assert_ne!(pool_a.id(), pool_b.id());

    let token_a: CompactPoolToken = CompactPoolRegistry::register_pool(&pool_a).unwrap();
    assert_eq!(token_a.physical_pool_id(), pool_a.id());

    let result = CompactPhysicalPool::new(&pool_b, &token_a);
    assert_eq!(result.unwrap_err(), CompactPoolError::PoolMismatch);

    let adapter_a = CompactPhysicalPool::new(&pool_a, &token_a);
    assert!(adapter_a.is_ok());
}

// ============================================================================
// AUTH-06: Emparejar Pool B con Token A en CompactPhysicalPool64::new retorna PoolMismatch
// ============================================================================
/// AUTH-06: Ataque adversarial de falsificación cruzada de autoridad en 8 bytes (64 bits).
#[test]
fn test_auth_06_cross_pool_token_pairing_fails_64bit() {
    let pool_a = PhysicalPool::new(test_pool_config()).unwrap();
    let pool_b = PhysicalPool::new(test_pool_config()).unwrap();
    assert_ne!(pool_a.id(), pool_b.id());

    let token16_a: CompactPoolToken16 = CompactPoolRegistry16::register_pool(&pool_a).unwrap();
    assert_eq!(token16_a.physical_pool_id(), pool_a.id());

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
    let pool = PhysicalPool::new(test_pool_config()).unwrap();
    let expected_id = pool.id();

    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    assert_eq!(token.physical_pool_id(), expected_id);

    let token16 = CompactPoolRegistry16::register_pool(&pool).unwrap();
    assert_eq!(token16.physical_pool_id(), expected_id);
}

// ============================================================================
// AUTH-08: Rechazo estricto de registro duplicado de pool físico
// ============================================================================
/// AUTH-08: Verifica que un mismo pool físico no pueda ser registrado múltiples veces,
/// evitando duplicación de dominios de autoridad y desperdicio de IDs.
#[test]
fn test_auth_08_duplicate_pool_registration_rejected() {
    let pool_a = PhysicalPool::new(test_pool_config()).unwrap();
    let pool_b = PhysicalPool::new(test_pool_config()).unwrap();

    let token_a = CompactPoolRegistry::register_pool(&pool_a).unwrap();
    assert_eq!(token_a.physical_pool_id(), pool_a.id());

    // Registro duplicado de pool_a debe fallar con AlreadyRegistered
    let dup_err = CompactPoolRegistry::register_pool(&pool_a).unwrap_err();
    assert_eq!(
        dup_err,
        CompactPoolError::AlreadyRegistered {
            physical_pool_id: pool_a.id()
        }
    );

    // Registro de pool_b triunfa y genera un token diferente
    let token_b = CompactPoolRegistry::register_pool(&pool_b).unwrap();
    assert_ne!(token_a.id(), token_b.id());
    assert_eq!(token_b.physical_pool_id(), pool_b.id());

    // Token A no puede ser usado para construir adaptador sobre Pool B
    assert_eq!(
        CompactPhysicalPool::new(&pool_b, &token_a).unwrap_err(),
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
    let mut pool_a = PhysicalPool::new(test_pool_config()).unwrap();
    let mut pool_b = PhysicalPool::new(test_pool_config()).unwrap();

    let token_a = CompactPoolRegistry::register_pool(&pool_a).unwrap();
    let token_b = CompactPoolRegistry::register_pool(&pool_b).unwrap();
    assert_ne!(token_a.id(), token_b.id());

    let h_a = pool_a.allocate().unwrap();
    let _h_b = pool_b.allocate().unwrap();
    assert_eq!(h_a.slot(), 0);
    assert_eq!(h_a.generation(), 1);

    let link_a = CompactLink::new(token_a.id(), h_a.slot(), h_a.generation() as u16).unwrap();

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
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let generation_val = handle.generation();
    let link = CompactLink::new(token.id(), slot, generation_val as u16).unwrap();

    pool.destroy(handle, false).unwrap();

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let err = adapter.revalidate_compact(link).unwrap_err();
    assert_eq!(err, CompactRevalidateError::SlotNotAllocated);
}

// ============================================================================
// AUTH-11: Enlace con generación stale tras reasignación falla con StaleGeneration
// ============================================================================
/// AUTH-11: Garantía No-ABA. Tras la destrucción y reasignación de un slot,
/// el enlace compacto de la primera vida (gen 1) es rechazado con `StaleGeneration`.
#[test]
fn test_auth_11_stale_generation_rejected_after_slot_reuse() {
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
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

    let link2 = CompactLink::new(token.id(), slot, 3).unwrap();
    assert!(adapter.revalidate_compact(link2).is_ok());
}

// ============================================================================
// AUTH-12: Enlace con generación retirada (GEN_RETIRADO_8) falla con GenerationRetired
// ============================================================================
/// AUTH-12: Invariante R9 en 8 bits. Un pool físico inicializado en `GEN_RETIRADO_8` (254)
/// rechaza permanentemente la revalidación con `GenerationRetired`.
#[test]
fn test_auth_12_retired_generation_8bit_rejected() {
    let mut config = test_pool_config();
    config.initial_generation = GEN_RETIRADO_8 as u32; // 254
    let mut pool = PhysicalPool::new(config).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    let h = pool.allocate().unwrap();
    let slot = h.slot();
    assert_eq!(h.generation(), 255); // impar, pero >= 254

    let link = CompactLink::new(token.id(), slot, 1).unwrap();
    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let err = adapter.revalidate_compact(link).unwrap_err();
    assert_eq!(err, CompactRevalidateError::GenerationRetired);
}

// ============================================================================
// AUTH-13: Enlace con generación retirada en 64 bits (GEN_RETIRADO_16) falla con GenerationRetired
// ============================================================================
/// AUTH-13: Invariante R9 en 16 bits. Retiro en 0xfffe (65534).
#[test]
fn test_auth_13_retired_generation_16bit_rejected() {
    let mut config = test_pool_config();
    config.initial_generation = GEN_RETIRADO_16 as u32; // 65534
    let mut pool = PhysicalPool::new(config).unwrap();
    let token16 = CompactPoolRegistry16::register_pool(&pool).unwrap();

    let h = pool.allocate().unwrap();
    let slot = h.slot();
    assert_eq!(h.generation(), 65535);

    let link64 = CompactLink64::new(token16.id(), slot, 1).unwrap();
    let adapter16 = CompactPhysicalPool64::new(&pool, &token16).unwrap();
    let err = adapter16.revalidate_compact_64(link64).unwrap_err();
    assert_eq!(err, CompactRevalidateError::GenerationRetired);
}

// ============================================================================
// AUTH-14: Slot en subpágina Quarantined falla con SubpageQuarantined
// ============================================================================
/// AUTH-14: Invariante R8 y P0-003. Una subpágina en cuarentena por fallo parcial
/// o estado ambiguo del SO debe ser verificada en estado `PageState::Quarantined`
/// y rechazar terminantemente la revalidación con `SubpageQuarantined`.
#[test]
fn test_auth_14_slot_in_quarantined_subpage_rejected() {
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    let h = pool.allocate().unwrap();
    let slot = h.slot();
    let link = CompactLink::new(token.id(), slot, h.generation() as u16).unwrap();

    // Inyectar fallo ambiguo en Decommit para forzar la subpágina a Quarantined
    pool.set_faults(FaultPlan::new().unknown_nth(FaultOp::Decommit, 1))
        .unwrap();
    let _ = pool.destroy(h, false);

    // Verificar explícitamente que la subpágina está en cuarentena
    assert_eq!(pool.page_state(slot), Ok(PageState::Quarantined));

    // Revalidación sobre slot en subpágina en cuarentena debe retornar SubpageQuarantined
    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let err = adapter.revalidate_compact(link);
    assert_eq!(err.unwrap_err(), CompactRevalidateError::SubpageQuarantined);
}

// ============================================================================
// AUTH-15: Slot en subpágina no confirmada (Returned) falla incondicionalmente
// ============================================================================
/// AUTH-15: Invariante R8. Una subpágina devuelta al SO (Returned) rechaza
/// incondicionalmente cualquier revalidación con `SlotNotAllocated`.
#[test]
fn test_auth_15_slot_in_returned_or_uncommitted_subpage_rejected() {
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    // Asignamos y destruimos un objeto para llevar la subpágina a PageState::Returned
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let link = CompactLink::new(token.id(), slot, 1).unwrap();

    let _ = pool.destroy(handle, false).unwrap();
    assert_eq!(pool.page_state(slot), Ok(PageState::Returned));

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    assert_eq!(
        adapter.revalidate_compact(link).unwrap_err(),
        CompactRevalidateError::SlotNotAllocated
    );
}

// ============================================================================
// AUTH-16: Slot >= slot_capacity() (acotado a 65.536 en 32 bits) falla con OutOfBounds
// ============================================================================
/// AUTH-16: Acotamiento seguro de capacidad. En `CompactPhysicalPool`,
/// `slot_capacity()` jamás excede `MAX_SLOT_COMPACT_32 + 1` (65.536).
#[test]
fn test_auth_16_slot_out_of_bounds_and_capacity_clamped() {
    let pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();

    assert!(adapter.slot_capacity() <= (MAX_SLOT_COMPACT_32 + 1));

    let oob_link = CompactLink::new(token.id(), 60_000, 1).unwrap();
    assert_eq!(
        adapter.revalidate_compact(oob_link).unwrap_err(),
        CompactRevalidateError::OutOfBounds
    );
}

// ============================================================================
// AUTH-17: CompactObjRef no confiere acceso mutable ni conversión a Handle
// ============================================================================
/// AUTH-17: Invariante R5 y regla de no fabricación. `CompactObjRef` es de solo lectura
/// y el compilador rechaza cualquier intento de convertirlo a `Handle`.
#[test]
fn test_auth_17_compact_obj_ref_is_read_only_and_non_promotable() {
    let (success, stderr) = run_fixture_check("convert-compact-objref-to-handle");
    assert!(
        !success,
        "La conversión de CompactObjRef a Handle debe ser rechazada por el compilador"
    );
    assert!(
        stderr.contains("E0599") || stderr.contains("to_handle"),
        "Se esperaba error E0599 por método inexistente, recibido:\n{stderr}"
    );

    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let link = CompactLink::new(token.id(), slot, 1).unwrap();

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let obj: CompactObjRef<'_> = adapter.revalidate_compact(link).unwrap();
    assert_eq!(obj.pool_id(), token.id());
    assert_eq!(obj.slot(), slot);
    assert_eq!(obj.generation(), 1);
}

// ============================================================================
// AUTH-18: CompactObjRef expira con el préstamo del pool; borrow checker previene mutación
// ============================================================================
/// AUTH-18: Invariante R4. El préstamo de `CompactObjRef` está atado al pool
/// y previene tanto retorno que escape al pool como mutaciones concurrentes.
#[test]
fn test_auth_18_compact_obj_ref_lifetime_bound_to_pool_borrow() {
    let (success_ret, stderr_ret) = run_fixture_check("retain-compact-objref-past-pool");
    assert!(
        !success_ret,
        "Retener CompactObjRef más allá de la vida del pool debe ser rechazado"
    );
    assert!(
        stderr_ret.contains("E0515") || stderr_ret.contains("E0597"),
        "Se esperaba error de lifetime E0515/E0597, recibido:\n{stderr_ret}"
    );

    let (success_mut, stderr_mut) = run_fixture_check("mutate-pool-while-borrowed");
    assert!(
        !success_mut,
        "Mutar el pool mientras existe un CompactObjRef activo debe ser rechazado por el borrow checker"
    );
    assert!(
        stderr_mut.contains("E0502"),
        "Se esperaba error de aliasing E0502, recibido:\n{stderr_mut}"
    );
}

// ============================================================================
// AUTH-19: Agotamiento de identificadores en instancia aislada de CompactIdAllocator8
// ============================================================================
/// AUTH-19: Agotamiento seguro sin contaminación del registro global ni wraparound.
#[test]
fn test_auth_19_compact_pool_registry_bounded_issuance() {
    assert_eq!(MAX_COMPACT_POOLS, 255);
    let allocator = CompactIdAllocator8::new();
    assert_eq!(allocator.allocated_count(), 0);

    let mut ids = Vec::new();
    while let Ok(id) = allocator.allocate_id() {
        assert_ne!(id, 0);
        ids.push(id);
    }

    assert_eq!(ids.len(), 255);
    assert_eq!(
        allocator.allocate_id().unwrap_err(),
        CompactPoolError::PoolIdExhausted
    );
    assert_eq!(allocator.allocated_count(), MAX_COMPACT_POOLS);
    assert!(allocator.is_valid_id(1));
    assert!(allocator.is_valid_id(255));
    assert!(!allocator.is_valid_id(0));
}

// ============================================================================
// AUTH-20: Concurrencia de emisión en CompactIdAllocator16 sin colisiones
// ============================================================================
/// AUTH-20: Emisiones concurrentes en `CompactIdAllocator16` aislado desde múltiples hilos.
#[test]
fn test_auth_20_concurrent_issuance_in_registry16_no_duplicates() {
    let threads = 8;
    let allocations_per_thread = 500;
    let allocator = Arc::new(CompactIdAllocator16::new());
    let mut handles = Vec::new();

    for _ in 0..threads {
        let alloc_clone = Arc::clone(&allocator);
        handles.push(thread::spawn(move || {
            let mut issued = Vec::new();
            for _ in 0..allocations_per_thread {
                if let Ok(id) = alloc_clone.allocate_id() {
                    issued.push(id);
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

    let total_len = all_ids.len();
    all_ids.sort_unstable();
    all_ids.dedup();
    assert_eq!(all_ids.len(), total_len);
}
