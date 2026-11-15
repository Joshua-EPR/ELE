//! Pruebas de generaciones compactas (16 bits) y enlaces compactos (4 bytes).

use nexo::next::{
    CompactGen, CompactGenError, CompactLink, CompactLinkError, GEN_RETIRADO_16, MAX_SLOT_COMPACT,
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
    // Probar el límite próximo a retiro
    // El último estado libre antes del retiro es 0xfffc (65532)
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
fn test_compact_link_encoding_and_matching() {
    let slot = 42u32;
    let generation_val = 0x0105u16; // Tag = 0x05

    let link = CompactLink::new(slot, generation_val).unwrap();
    assert_eq!(link.slot(), 42);
    assert_eq!(link.gen_tag(), 0x05);
    assert!(link.matches(0x0105));
    assert!(link.matches(0x0205)); // Mismo tag de 8 bits
    assert!(!link.matches(0x0106)); // Distinto tag

    // Enlace no puede ser creado para un slot fuera del rango de 24 bits
    let overflow_slot = MAX_SLOT_COMPACT + 1;
    assert_eq!(
        CompactLink::new(overflow_slot, 1).unwrap_err(),
        CompactLinkError::SlotOverflow
    );

    // Enlace no puede crearse para una generación ya retirada
    assert_eq!(
        CompactLink::new(10, GEN_RETIRADO_16).unwrap_err(),
        CompactLinkError::GenerationRetired
    );
}
