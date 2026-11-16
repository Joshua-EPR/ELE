//! Pruebas de generaciones compactas (16 bits y 8 bits) y enlaces compactos (4 bytes).

use nexo::next::{
    CompactGen, CompactGenError, CompactLink, CompactLinkError, GEN_RETIRADO_8, GEN_RETIRADO_16,
    MAX_SLOT_COMPACT_32,
};

#[test]
fn test_compact_gen_lifecycle_and_invariants() {
    let mut g = 0u16; // Inicialmente libre/par

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
fn test_compact_gen_8bit_lifecycle_and_retirement() {
    let mut g = 0u8;

    g = CompactGen::allocate_8(g).unwrap();
    assert_eq!(g, 1);
    assert!(CompactGen::is_live_8(g));

    g = CompactGen::destroy_8(g).unwrap();
    assert_eq!(g, 2);
    assert!(!CompactGen::is_live_8(g));

    // Probar el límite próximo a retiro en 8 bits (252 libre -> 253 vivo -> 254 retirado)
    let near_end = 252u8;
    let last_live = CompactGen::allocate_8(near_end).unwrap();
    assert_eq!(last_live, 253);

    let retired = CompactGen::destroy_8(last_live).unwrap();
    assert_eq!(retired, GEN_RETIRADO_8);
    assert!(CompactGen::is_retired_8(retired));

    assert_eq!(
        CompactGen::allocate_8(retired).unwrap_err(),
        CompactGenError::Retired
    );
    assert_eq!(
        CompactGen::destroy_8(retired).unwrap_err(),
        CompactGenError::Retired
    );
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
    // Slot mayor a 16 bits rechazado
    let overflow_slot = MAX_SLOT_COMPACT_32 + 1;
    assert_eq!(
        CompactLink::new(0, overflow_slot, 1).unwrap_err(),
        CompactLinkError::SlotOverflow
    );

    // Generación par (no viva) rechazada
    assert_eq!(
        CompactLink::new(0, 10, 2).unwrap_err(),
        CompactLinkError::InvalidState
    );

    // Generación retirada rechazada
    assert_eq!(
        CompactLink::new(0, 10, GEN_RETIRADO_8 as u16).unwrap_err(),
        CompactLinkError::GenerationRetired
    );
}
