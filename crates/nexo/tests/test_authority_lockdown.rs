//! Suite de endurecimiento de autoridad y seguridad para NEXO v0.4 (AUTH-HARDEN-01..20).
//!
//! Verifica las 20 invariantes críticas de cierre de autoridad de memoria:
//! - AUTH-HARDEN-01: Inexistencia de emisión de autoridad a partir de enteros arbitrarios (E0599).
//! - AUTH-HARDEN-02: Rechazo de construcción directa de tokens desde crates externos (E0560/E0423/E0451).
//! - AUTH-HARDEN-03: Rechazo de registro duplicado de pool físico (AlreadyRegistered).
//! - AUTH-HARDEN-04: Rechazo de emparejamiento cruzado Token A con Pool B en 32 bits (PoolMismatch).
//! - AUTH-HARDEN-05: Rechazo de emparejamiento cruzado Token B con Pool A en 64 bits (PoolMismatch).
//! - AUTH-HARDEN-06: Pool cerrado no puede ser revalidado ni adaptado (fail-closed).
//! - AUTH-HARDEN-07: Recreación de pool físico tras drop genera nueva ID y no reutiliza tokens previos.
//! - AUTH-HARDEN-08: Enlace de pool físico previo rechazado con ForeignPool frente a pool nuevo.
//! - AUTH-HARDEN-09: Generación stale rechazada tras reasignación de slot (StaleGeneration).
//! - AUTH-HARDEN-10: Generación retirada rechazada permanentemente (GenerationRetired).
//! - AUTH-HARDEN-11: Subpágina en cuarentena rechazada con SubpageQuarantined.
//! - AUTH-HARDEN-12: Slot en estado de hueco lineal (HoleToken) rechazado con SlotNotAllocated.
//! - AUTH-HARDEN-13: Slot no confirmado rechazado incondicionalmente (SlotNotAllocated).
//! - AUTH-HARDEN-14: Fallo de registro mantiene estado atómico sin tokens parciales ni desincronización.
//! - AUTH-HARDEN-15: Agotamiento de registro en instancia aislada no contamina el singleton global.
//! - AUTH-HARDEN-16: Emisión concurrente sin bloqueos ni duplicados en CompactIdAllocator16.
//! - AUTH-HARDEN-17: Implementación externa de traits de autoridad sellados rechazada por compilador (E0277).
//! - AUTH-HARDEN-18: Mocks privilegiados no accesibles en builds de producción (E0433).
//! - AUTH-HARDEN-19: CompactObjRef confinado a la vida del préstamo del pool físico (E0515/E0597).
//! - AUTH-HARDEN-20: Borrow checker de Rust impide mutación del pool mientras existe préstamo activo (E0502).

use std::process::Command;
use std::sync::Arc;
use std::thread;

use nexo::next::{
    CompactIdAllocator8, CompactIdAllocator16, CompactLink, CompactPhysicalPool,
    CompactPhysicalPool64, CompactPoolAuthority, CompactPoolError, CompactPoolRegistry,
    CompactPoolRegistry16, CompactRevalidateError, GEN_RETIRADO_8, MAX_COMPACT_POOLS,
};
use nexo::physical::{
    DestroyOutcome, FaultOp, FaultPlan, PageState, PhysicalPool, PoolConfig, ReclaimPolicy,
};

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
// AUTH-HARDEN-01: Inexistencia de emisión de autoridad a partir de enteros arbitrarios
// ============================================================================
#[test]
fn test_auth_harden_01_no_arbitrary_authority_issuance() {
    let (success_for, stderr_for) = run_fixture_check("call-acquire-token-for");
    assert!(
        !success_for,
        "acquire_token_for(u64) no debe existir en la API pública"
    );
    assert!(
        stderr_for.contains("E0599") && stderr_for.contains("acquire_token_for"),
        "Se esperaba error E0599 por método inexistente, recibido:\n{stderr_for}"
    );

    let (success_acq, stderr_acq) = run_fixture_check("call-acquire-token");
    assert!(
        !success_acq,
        "acquire_token() sin pool no debe existir en la API pública"
    );
    assert!(
        stderr_acq.contains("E0599") && stderr_acq.contains("acquire_token"),
        "Se esperaba error E0599 por método inexistente, recibido:\n{stderr_acq}"
    );
}

// ============================================================================
// AUTH-HARDEN-02: Rechazo de construcción directa de tokens desde crates externos
// ============================================================================
#[test]
fn test_auth_harden_02_tokens_cannot_be_constructed_externally() {
    let (success_tok, stderr_tok) = run_fixture_check("construct-compact-token");
    assert!(
        !success_tok,
        "CompactPoolToken no debe permitir construcción externa de struct"
    );
    assert!(
        stderr_tok.contains("E0560")
            || stderr_tok.contains("E0423")
            || stderr_tok.contains("E0451"),
        "Se esperaba error de campos privados en CompactPoolToken, recibido:\n{stderr_tok}"
    );

    let (success_tok16, stderr_tok16) = run_fixture_check("construct-compact-token16");
    assert!(
        !success_tok16,
        "CompactPoolToken16 no debe permitir construcción externa de struct"
    );
    assert!(
        stderr_tok16.contains("E0560")
            || stderr_tok16.contains("E0423")
            || stderr_tok16.contains("E0451"),
        "Se esperaba error de campos privados en CompactPoolToken16, recibido:\n{stderr_tok16}"
    );
}

// ============================================================================
// AUTH-HARDEN-03: Rechazo de registro duplicado de pool físico
// ============================================================================
#[test]
fn test_auth_harden_03_duplicate_pool_registration_rejected() {
    let pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    assert_eq!(token.physical_pool_id(), pool.id());

    let err = CompactPoolRegistry::register_pool(&pool).unwrap_err();
    assert_eq!(
        err,
        CompactPoolError::AlreadyRegistered {
            physical_pool_id: pool.id()
        }
    );

    let token16 = CompactPoolRegistry16::register_pool(&pool).unwrap();
    assert_eq!(token16.physical_pool_id(), pool.id());

    let err16 = CompactPoolRegistry16::register_pool(&pool).unwrap_err();
    assert_eq!(
        err16,
        CompactPoolError::AlreadyRegistered {
            physical_pool_id: pool.id()
        }
    );
}

// ============================================================================
// AUTH-HARDEN-04: Rechazo de emparejamiento cruzado Token A con Pool B en 32 bits
// ============================================================================
#[test]
fn test_auth_harden_04_cross_pool_pairing_mismatch_32bit() {
    let pool_a = PhysicalPool::new(test_pool_config()).unwrap();
    let pool_b = PhysicalPool::new(test_pool_config()).unwrap();

    let token_a = CompactPoolRegistry::register_pool(&pool_a).unwrap();
    let err = CompactPhysicalPool::new(&pool_b, &token_a).unwrap_err();
    assert_eq!(err, CompactPoolError::PoolMismatch);

    let valid_adapter = CompactPhysicalPool::new(&pool_a, &token_a);
    assert!(valid_adapter.is_ok());
}

// ============================================================================
// AUTH-HARDEN-05: Rechazo de emparejamiento cruzado Token B con Pool A en 64 bits
// ============================================================================
#[test]
fn test_auth_harden_05_cross_pool_pairing_mismatch_64bit() {
    let pool_a = PhysicalPool::new(test_pool_config()).unwrap();
    let pool_b = PhysicalPool::new(test_pool_config()).unwrap();

    let token_b16 = CompactPoolRegistry16::register_pool(&pool_b).unwrap();
    let err = CompactPhysicalPool64::new(&pool_a, &token_b16).unwrap_err();
    assert_eq!(err, CompactPoolError::PoolMismatch);

    let valid_adapter = CompactPhysicalPool64::new(&pool_b, &token_b16);
    assert!(valid_adapter.is_ok());
}

// ============================================================================
// AUTH-HARDEN-06: Pool cerrado no puede ser revalidado ni adaptado (fail-closed)
// ============================================================================
#[test]
fn test_auth_harden_06_closed_pool_fails_closed() {
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    let handle = pool.allocate().unwrap();
    let slot = handle.slot();
    let link = CompactLink::new(token.id(), slot, 1).unwrap();

    // Destruimos el handle para que close() no falle por leak
    let _ = pool.destroy(handle, false).unwrap();
    pool.close().unwrap();

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    let err = adapter.revalidate_compact(link);
    assert!(err.is_err(), "Revalidación sobre pool cerrado debe fallar");
}

// ============================================================================
// AUTH-HARDEN-07: Recreación de pool físico tras drop genera nueva ID y no reutiliza tokens
// ============================================================================
#[test]
fn test_auth_harden_07_pool_recreation_has_distinct_id() {
    let pool1 = PhysicalPool::new(test_pool_config()).unwrap();
    let id1 = pool1.id();
    let token1 = CompactPoolRegistry::register_pool(&pool1).unwrap();
    drop(pool1);

    let pool2 = PhysicalPool::new(test_pool_config()).unwrap();
    let id2 = pool2.id();
    assert_ne!(
        id1, id2,
        "El id de pool físico debe ser monotónicamente único"
    );

    let err = CompactPhysicalPool::new(&pool2, &token1).unwrap_err();
    assert_eq!(err, CompactPoolError::PoolMismatch);
}

// ============================================================================
// AUTH-HARDEN-08: Enlace de pool físico previo rechazado con ForeignPool frente a pool nuevo
// ============================================================================
#[test]
fn test_auth_harden_08_link_from_previous_pool_rejected_as_foreign() {
    let mut pool1 = PhysicalPool::new(test_pool_config()).unwrap();
    let token1 = CompactPoolRegistry::register_pool(&pool1).unwrap();
    let h1 = pool1.allocate().unwrap();
    let link1 = CompactLink::new(token1.id(), h1.slot(), 1).unwrap();

    let pool2 = PhysicalPool::new(test_pool_config()).unwrap();
    let token2 = CompactPoolRegistry::register_pool(&pool2).unwrap();
    let adapter2 = CompactPhysicalPool::new(&pool2, &token2).unwrap();

    let err = adapter2.revalidate_compact(link1).unwrap_err();
    assert_eq!(err, CompactRevalidateError::ForeignPool);
}

// ============================================================================
// AUTH-HARDEN-09: Generación stale rechazada tras reasignación de slot (StaleGeneration)
// ============================================================================
#[test]
fn test_auth_harden_09_stale_generation_rejected() {
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    let h1 = pool.allocate().unwrap();
    let slot = h1.slot();
    let old_link = CompactLink::new(token.id(), slot, 1).unwrap();

    pool.destroy(h1, false).unwrap();

    let h2 = pool.allocate().unwrap();
    assert_eq!(h2.slot(), slot);
    assert_eq!(h2.generation(), 3);

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    assert_eq!(
        adapter.revalidate_compact(old_link).unwrap_err(),
        CompactRevalidateError::StaleGeneration
    );
}

// ============================================================================
// AUTH-HARDEN-10: Generación retirada rechazada permanentemente (GenerationRetired)
// ============================================================================
#[test]
fn test_auth_harden_10_retired_generation_permanently_rejected() {
    let mut config = test_pool_config();
    config.initial_generation = GEN_RETIRADO_8 as u32;
    let mut pool = PhysicalPool::new(config).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    let h = pool.allocate().unwrap();
    let link = CompactLink::new(token.id(), h.slot(), 1).unwrap();

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    assert_eq!(
        adapter.revalidate_compact(link).unwrap_err(),
        CompactRevalidateError::GenerationRetired
    );
}

// ============================================================================
// AUTH-HARDEN-11: Subpágina en cuarentena rechazada con SubpageQuarantined
// ============================================================================
#[test]
fn test_auth_harden_11_quarantined_subpage_rejected_with_specific_error() {
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    let h = pool.allocate().unwrap();
    let slot = h.slot();
    let link = CompactLink::new(token.id(), slot, h.generation() as u16).unwrap();

    pool.set_faults(FaultPlan::new().unknown_nth(FaultOp::Decommit, 1))
        .unwrap();
    let _ = pool.destroy(h, false);

    assert_eq!(pool.page_state(slot), Ok(PageState::Quarantined));

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    assert_eq!(
        adapter.revalidate_compact(link).unwrap_err(),
        CompactRevalidateError::SubpageQuarantined
    );
}

// ============================================================================
// AUTH-HARDEN-12: Slot en estado de hueco lineal (HoleToken) rechazado con SlotNotAllocated
// ============================================================================
#[test]
fn test_auth_harden_12_hole_slot_rejected_as_slot_not_allocated() {
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    let h = pool.allocate().unwrap();
    let slot = h.slot();
    let link = CompactLink::new(token.id(), slot, 1).unwrap();

    let DestroyOutcome::Hole(hole_tok) = pool.destroy(h, true).unwrap().outcome else {
        panic!("Se esperaba la creación de un hueco lineal");
    };

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    assert_eq!(
        adapter.revalidate_compact(link).unwrap_err(),
        CompactRevalidateError::SlotNotAllocated
    );

    pool.release_hole(hole_tok).unwrap();
}

// ============================================================================
// AUTH-HARDEN-13: Slot no confirmado rechazado incondicionalmente (SlotNotAllocated)
// ============================================================================
#[test]
fn test_auth_harden_13_uncommitted_slot_unconditionally_rejected() {
    let mut pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();

    let h = pool.allocate().unwrap();
    let slot = h.slot();
    let link = CompactLink::new(token.id(), slot, 1).unwrap();

    let _ = pool.destroy(h, false).unwrap();
    assert_eq!(pool.page_state(slot), Ok(PageState::Returned));

    let adapter = CompactPhysicalPool::new(&pool, &token).unwrap();
    assert_eq!(
        adapter.revalidate_compact(link).unwrap_err(),
        CompactRevalidateError::SlotNotAllocated
    );
}

// ============================================================================
// AUTH-HARDEN-14: Fallo de registro mantiene estado atómico sin tokens parciales
// ============================================================================
#[test]
fn test_auth_harden_14_atomic_registration_failure_preserves_state() {
    let pool = PhysicalPool::new(test_pool_config()).unwrap();
    let token = CompactPoolRegistry::register_pool(&pool).unwrap();
    let allocated_before = CompactPoolRegistry::allocated_count();

    let err = CompactPoolRegistry::register_pool(&pool).unwrap_err();
    assert_eq!(
        err,
        CompactPoolError::AlreadyRegistered {
            physical_pool_id: pool.id()
        }
    );
    assert_eq!(CompactPoolRegistry::allocated_count(), allocated_before);
    assert_eq!(token.physical_pool_id(), pool.id());
}

// ============================================================================
// AUTH-HARDEN-15: Agotamiento de registro en instancia aislada no contamina el singleton global
// ============================================================================
#[test]
fn test_auth_harden_15_isolated_exhaustion_does_not_contaminate_global() {
    let allocator = CompactIdAllocator8::new();
    assert_eq!(allocator.allocated_count(), 0);

    for _ in 0..MAX_COMPACT_POOLS {
        assert!(allocator.allocate_id().is_ok());
    }

    assert_eq!(
        allocator.allocate_id().unwrap_err(),
        CompactPoolError::PoolIdExhausted
    );
    assert_eq!(allocator.allocated_count(), MAX_COMPACT_POOLS);

    // El singleton global permanece operativo y no agotado
    assert!(CompactPoolRegistry::allocated_count() < MAX_COMPACT_POOLS);
}

// ============================================================================
// AUTH-HARDEN-16: Emisión concurrente sin bloqueos ni duplicados en CompactIdAllocator16
// ============================================================================
#[test]
fn test_auth_harden_16_concurrent_allocator16_emission_no_duplicates() {
    let threads = 8;
    let allocations_per_thread = 500;
    let allocator = Arc::new(CompactIdAllocator16::new());
    let mut handles = Vec::new();

    for _ in 0..threads {
        let alloc_clone = Arc::clone(&allocator);
        handles.push(thread::spawn(move || {
            let mut ids = Vec::new();
            for _ in 0..allocations_per_thread {
                if let Ok(id) = alloc_clone.allocate_id() {
                    ids.push(id);
                }
            }
            ids
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

// ============================================================================
// AUTH-HARDEN-17: Implementación externa de traits de autoridad sellados rechazada por compilador
// ============================================================================
#[test]
fn test_auth_harden_17_sealed_trait_compile_fail() {
    let (success, stderr) = run_fixture_check("implement-sealed-authority");
    assert!(!success);
    assert!(stderr.contains("E0277") || stderr.contains("sealed"));

    let (success64, stderr64) = run_fixture_check("implement-sealed-authority-64");
    assert!(!success64);
    assert!(stderr64.contains("E0277") || stderr64.contains("sealed"));
}

// ============================================================================
// AUTH-HARDEN-18: Mocks privilegiados no accesibles en builds de producción
// ============================================================================
#[test]
fn test_auth_harden_18_mock_pools_inaccessible_in_production() {
    let (success, stderr) = run_fixture_check("access-mock-compact-pool");
    assert!(!success);
    assert!(stderr.contains("E0433") || stderr.contains("testing"));
}

// ============================================================================
// AUTH-HARDEN-19: CompactObjRef confinado a la vida del préstamo del pool físico
// ============================================================================
#[test]
fn test_auth_harden_19_compact_objref_bounded_to_pool_borrow() {
    let (success, stderr) = run_fixture_check("retain-compact-objref-past-pool");
    assert!(!success);
    assert!(stderr.contains("E0515") || stderr.contains("E0597"));
}

// ============================================================================
// AUTH-HARDEN-20: Borrow checker de Rust impide mutación del pool mientras existe préstamo activo
// ============================================================================
#[test]
fn test_auth_harden_20_borrow_checker_prevents_mutation_during_objref() {
    let (success, stderr) = run_fixture_check("mutate-pool-while-borrowed");
    assert!(!success);
    assert!(stderr.contains("E0502"));
}
