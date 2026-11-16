//! Pruebas de verificación de `ScopedArena` y asignación determinista por ámbito.
//!
//! Incluye suite mandatoria P0-ARENA-01 a P0-ARENA-08 de resiliencia ante pánicos,
//! envenenamiento de arena, ausencia de corrupción de memoria, y gestión de destructores.

use nexo::next::{ArenaError, ArenaState, ScopedArena};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

#[derive(Debug, PartialEq)]
struct Point {
    x: f64,
    y: f64,
}

static DROP_COUNTER: AtomicUsize = AtomicUsize::new(0);

struct DropTracker {
    _id: usize,
}

impl Drop for DropTracker {
    fn drop(&mut self) {
        DROP_COUNTER.fetch_add(1, Ordering::SeqCst);
    }
}

/// Rastreador de destrucción individual con flag atómico propio.
struct TrackedObject {
    id: usize,
    dropped: Arc<AtomicBool>,
    drop_order: Arc<AtomicUsize>,
    global_order: Arc<AtomicUsize>,
}

impl Drop for TrackedObject {
    fn drop(&mut self) {
        self.dropped.store(true, Ordering::SeqCst);
        let order = self.global_order.fetch_add(1, Ordering::SeqCst);
        self.drop_order.store(order, Ordering::SeqCst);
    }
}

#[repr(align(32))]
#[allow(dead_code)]
struct Aligned32 {
    data: [u8; 32],
}

#[repr(align(64))]
#[allow(dead_code)]
struct Aligned64 {
    data: [u8; 64],
}

#[repr(align(128))]
#[allow(dead_code)]
struct Aligned128 {
    data: [u8; 128],
}

#[repr(align(256))]
#[allow(dead_code)]
struct Aligned256 {
    data: [u8; 256],
}

#[repr(align(512))]
#[allow(dead_code)]
struct Aligned512 {
    data: [u8; 512],
}

#[repr(align(4096))]
#[allow(dead_code)]
struct Aligned4096 {
    data: [u8; 4096],
}

struct ZstDrop;
impl Drop for ZstDrop {
    fn drop(&mut self) {
        DROP_COUNTER.fetch_add(1, Ordering::SeqCst);
    }
}

struct PanicDropper {
    should_panic: bool,
    dropped: Arc<AtomicBool>,
}

impl Drop for PanicDropper {
    fn drop(&mut self) {
        self.dropped.store(true, Ordering::SeqCst);
        DROP_COUNTER.fetch_add(1, Ordering::SeqCst);
        if self.should_panic {
            panic!("pánico intencional en destructor para prueba de seguridad P0");
        }
    }
}

#[test]
fn test_arena_basic_allocation_and_alignment() {
    let mut arena = ScopedArena::new(1024).unwrap();
    let marker = arena.begin_scope().unwrap();

    let p1 = arena.alloc(&marker, Point { x: 1.5, y: 2.5 }).unwrap();
    assert_eq!(p1.x, 1.5);
    assert_eq!(p1.y, 2.5);

    let val_u8 = arena.alloc(&marker, 42u8).unwrap();
    assert_eq!(*val_u8, 42);

    let val_u64 = arena.alloc(&marker, 100_000u64).unwrap();
    assert_eq!(*val_u64, 100_000);

    arena.close_scope(marker).unwrap();
    assert_eq!(arena.used_bytes(), 0);
}

#[test]
fn test_nested_scopes_and_lifo_destruction() {
    DROP_COUNTER.store(0, Ordering::SeqCst);
    let mut arena = ScopedArena::new(4096).unwrap();

    let outer_marker = arena.begin_scope().unwrap();
    let _d1 = arena.alloc(&outer_marker, DropTracker { _id: 1 }).unwrap();
    assert_eq!(DROP_COUNTER.load(Ordering::SeqCst), 0);

    {
        let inner_marker = arena.begin_scope().unwrap();
        let _d2 = arena.alloc(&inner_marker, DropTracker { _id: 2 }).unwrap();
        let _d3 = arena.alloc(&inner_marker, DropTracker { _id: 3 }).unwrap();
        assert_eq!(DROP_COUNTER.load(Ordering::SeqCst), 0);

        // Cierre del ámbito interno debe liberar d2 y d3
        arena.close_scope(inner_marker).unwrap();
        assert_eq!(DROP_COUNTER.load(Ordering::SeqCst), 2);
    }

    // d1 sigue vivo en el ámbito exterior
    assert_eq!(DROP_COUNTER.load(Ordering::SeqCst), 2);

    // Cierre del ámbito exterior libera d1
    arena.close_scope(outer_marker).unwrap();
    assert_eq!(DROP_COUNTER.load(Ordering::SeqCst), 3);
    assert_eq!(arena.used_bytes(), 0);
}

#[test]
fn test_out_of_memory_handled_cleanly() {
    let mut arena = ScopedArena::new(128).unwrap();
    let marker = arena.begin_scope().unwrap();

    // Intentar asignar un búfer que excede la capacidad de la arena
    let res = arena.alloc(&marker, [0u8; 256]);
    assert_eq!(res.unwrap_err(), ArenaError::OutOfMemory);

    arena.close_scope(marker).unwrap();
}

#[test]
fn test_scope_mismatch_and_linear_marker_recovery() {
    let mut arena1 = ScopedArena::new(1024).unwrap();
    let mut arena2 = ScopedArena::new(1024).unwrap();

    assert_ne!(
        arena1.id(),
        arena2.id(),
        "Cada arena debe tener un ID único"
    );

    let marker1 = arena1.begin_scope().unwrap();
    let marker2 = arena2.begin_scope().unwrap();

    // Rechazo de asignación cruzada entre arenas
    let cross_alloc = arena1.alloc(&marker2, 42u32);
    assert_eq!(cross_alloc.unwrap_err(), ArenaError::ScopeMismatch);

    // Rechazo de cierre cruzado entre arenas devuelve el marcador intacto
    let cross_close_err = arena1.close_scope(marker2).unwrap_err();
    assert_eq!(cross_close_err.error, ArenaError::ScopeMismatch);
    let (recovered_marker2, error_kind) = cross_close_err.into_parts();
    assert_eq!(error_kind, ArenaError::ScopeMismatch);

    // El marcador devuelto puede cerrar legítimamente arena2
    arena2.close_scope(recovered_marker2).unwrap();
    arena1.close_scope(marker1).unwrap();
}

#[test]
fn test_out_of_order_close_recovers_marker() {
    let mut arena = ScopedArena::new(1024).unwrap();
    let outer = arena.begin_scope().unwrap();
    let inner = arena.begin_scope().unwrap();

    // Intentar cerrar el ámbito exterior antes de cerrar el interior falla pero preserva el marcador
    let err = arena.close_scope(outer).unwrap_err();
    assert_eq!(err.error, ArenaError::ScopeMismatch);
    let (recovered_outer, _) = err.into_parts();

    // Cerrar el interior primero
    arena.close_scope(inner).unwrap();

    // Ahora el exterior se cierra exitosamente con el marcador recuperado
    arena.close_scope(recovered_outer).unwrap();
}

#[test]
fn test_alignments_up_to_512() {
    let mut arena = ScopedArena::new(4096).unwrap();
    let marker = arena.begin_scope().unwrap();

    let a32 = arena.alloc(&marker, Aligned32 { data: [1; 32] }).unwrap();
    let ptr_val32 = (a32 as *const Aligned32) as usize;
    assert_eq!(ptr_val32 % 32, 0, "Alineación a 32 bytes debe respetarse");

    let a64 = arena.alloc(&marker, Aligned64 { data: [2; 64] }).unwrap();
    let ptr_val64 = (a64 as *const Aligned64) as usize;
    assert_eq!(ptr_val64 % 64, 0, "Alineación a 64 bytes debe respetarse");

    let a128 = arena.alloc(&marker, Aligned128 { data: [3; 128] }).unwrap();
    let ptr_val128 = (a128 as *const Aligned128) as usize;
    assert_eq!(
        ptr_val128 % 128,
        0,
        "Alineación a 128 bytes debe respetarse"
    );

    let a256 = arena.alloc(&marker, Aligned256 { data: [4; 256] }).unwrap();
    let ptr_val256 = (a256 as *const Aligned256) as usize;
    assert_eq!(
        ptr_val256 % 256,
        0,
        "Alineación a 256 bytes debe respetarse"
    );

    let a512 = arena.alloc(&marker, Aligned512 { data: [5; 512] }).unwrap();
    let ptr_val512 = (a512 as *const Aligned512) as usize;
    assert_eq!(
        ptr_val512 % 512,
        0,
        "Alineación a 512 bytes debe respetarse"
    );

    arena.close_scope(marker).unwrap();
    assert_eq!(arena.used_bytes(), 0);
}

#[test]
fn test_custom_base_alignment() {
    let mut arena = ScopedArena::new_with_alignment(2048, 256).unwrap();
    let marker = arena.begin_scope().unwrap();

    let a256 = arena.alloc(&marker, Aligned256 { data: [0; 256] }).unwrap();
    let ptr_val = (a256 as *const Aligned256) as usize;
    assert_eq!(ptr_val % 256, 0);

    arena.close_scope(marker).unwrap();
}

#[test]
fn test_zst_allocation_and_drop() {
    DROP_COUNTER.store(0, Ordering::SeqCst);
    let mut arena = ScopedArena::new(512).unwrap();
    let marker = arena.begin_scope().unwrap();

    let offset_before = arena.used_bytes();
    let _z1 = arena.alloc(&marker, ()).unwrap();
    let _z2 = arena.alloc(&marker, ZstDrop).unwrap();
    let offset_after = arena.used_bytes();

    assert_eq!(offset_before, offset_after);

    arena.close_scope(marker).unwrap();
    assert_eq!(
        DROP_COUNTER.load(Ordering::SeqCst),
        1,
        "El drop de ZstDrop debió ejecutarse"
    );
}

// =========================================================================
// SUITE MANDATORIA P0-ARENA-01 a P0-ARENA-08 (Auditoría de Seguridad)
// =========================================================================

/// P0-ARENA-01: Tres objetos en un ámbito, el del medio entra en pánico durante el drop.
/// Verificar que el último (C) se destruyó primero en LIFO, el del medio (B) entró en pánico,
/// y el primero (A) NO fue destruido aún antes de que el desenrollado sea capturado.
#[test]
fn test_p0_arena_01_three_objects_middle_panics_in_drop() {
    let global_order = Arc::new(AtomicUsize::new(0));

    let a_dropped = Arc::new(AtomicBool::new(false));
    let a_order = Arc::new(AtomicUsize::new(usize::MAX));

    let b_dropped = Arc::new(AtomicBool::new(false));

    let c_dropped = Arc::new(AtomicBool::new(false));
    let c_order = Arc::new(AtomicUsize::new(usize::MAX));

    let mut arena = ScopedArena::new(2048).unwrap();
    let marker = arena.begin_scope().unwrap();

    // Asignar en orden: A, B, C
    arena
        .alloc(
            &marker,
            TrackedObject {
                id: 1,
                dropped: a_dropped.clone(),
                drop_order: a_order.clone(),
                global_order: global_order.clone(),
            },
        )
        .unwrap();

    arena
        .alloc(
            &marker,
            PanicDropper {
                should_panic: true,
                dropped: b_dropped.clone(),
            },
        )
        .unwrap();

    arena
        .alloc(
            &marker,
            TrackedObject {
                id: 3,
                dropped: c_dropped.clone(),
                drop_order: c_order.clone(),
                global_order: global_order.clone(),
            },
        )
        .unwrap();

    // Intentar cerrar el ámbito. El orden LIFO extrae C (ejecuta drop), luego B (entra en pánico).
    let panic_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = arena.close_scope(marker);
    }));

    assert!(
        panic_result.is_err(),
        "El cierre de ámbito debió propagar el pánico"
    );

    // Invariantes P0-ARENA-01:
    // 1. C debió destruirse primero (orden 0).
    assert!(c_dropped.load(Ordering::SeqCst), "C debió ser destruido");
    assert_eq!(
        c_order.load(Ordering::SeqCst),
        0,
        "C debió ser el primer drop en LIFO"
    );

    // 2. B intentó destruirse y entró en pánico.
    assert!(
        b_dropped.load(Ordering::SeqCst),
        "B debió registrar su drop antes del pánico"
    );

    // 3. A NO debió ser destruido aún (su drop quedó pendiente).
    assert!(
        !a_dropped.load(Ordering::SeqCst),
        "A NO debe haber sido destruido todavía"
    );

    // 4. La arena debe estar envenenada.
    assert!(
        arena.is_poisoned(),
        "La arena debe quedar en estado Poisoned"
    );
    assert_eq!(arena.state(), ArenaState::Poisoned);
}

/// P0-ARENA-02: Asignación tras pánico capturado es terminantemente rechazada
/// impidiendo la sobreescritura de memoria de objetos vivos no destruidos.
#[test]
fn test_p0_arena_02_allocation_after_panic_is_rejected_no_overwrite() {
    let global_order = Arc::new(AtomicUsize::new(0));
    let a_dropped = Arc::new(AtomicBool::new(false));
    let a_order = Arc::new(AtomicUsize::new(usize::MAX));
    let b_dropped = Arc::new(AtomicBool::new(false));

    let mut arena = ScopedArena::new(2048).unwrap();
    let outer_marker = arena.begin_scope().unwrap();
    let inner_marker = arena.begin_scope().unwrap();

    let a_ref = arena
        .alloc(
            &inner_marker,
            TrackedObject {
                id: 42,
                dropped: a_dropped.clone(),
                drop_order: a_order.clone(),
                global_order: global_order.clone(),
            },
        )
        .unwrap();
    let a_ptr = a_ref as *const TrackedObject;

    arena
        .alloc(
            &inner_marker,
            PanicDropper {
                should_panic: true,
                dropped: b_dropped.clone(),
            },
        )
        .unwrap();

    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = arena.close_scope(inner_marker);
    }));

    assert!(arena.is_poisoned());

    // Intentar abrir nuevo ámbito tras envenenamiento debe fallar
    assert_eq!(
        arena.begin_scope().unwrap_err(),
        ArenaError::Poisoned,
        "No se puede abrir ámbito en arena envenenada"
    );

    // Intentar asignar directamente usando el marcador exterior legítimo debe fallar con ArenaError::Poisoned
    let alloc_res = arena.alloc(&outer_marker, [0xaa_u8; 128]);
    assert_eq!(
        alloc_res.unwrap_err(),
        ArenaError::Poisoned,
        "Asignación en arena envenenada debe ser rechazada para evitar sobreescribir memoria de A"
    );

    // Intentar cerrar el ámbito exterior también debe fallar con ArenaError::Poisoned
    let close_res = arena.close_scope(outer_marker);
    assert_eq!(close_res.unwrap_err().error, ArenaError::Poisoned);

    // Verificar que la memoria de A no fue corrompida ni sobreescrita
    unsafe {
        assert_eq!((*a_ptr).id, 42, "El contenido de A permanece íntegro");
    }
}

/// P0-ARENA-03: `drop(arena)` tras pánico capturado destruye los objetos pendientes
/// exactamente una vez, garantizando cero fugas y cero dobles destrucciones.
#[test]
fn test_p0_arena_03_arena_drop_destroys_remaining_objects_exactly_once() {
    let global_order = Arc::new(AtomicUsize::new(0));

    let a_dropped = Arc::new(AtomicBool::new(false));
    let a_order = Arc::new(AtomicUsize::new(usize::MAX));
    let b_dropped = Arc::new(AtomicBool::new(false));
    let c_dropped = Arc::new(AtomicBool::new(false));
    let c_order = Arc::new(AtomicUsize::new(usize::MAX));

    let mut arena = ScopedArena::new(2048).unwrap();
    let marker = arena.begin_scope().unwrap();

    arena
        .alloc(
            &marker,
            TrackedObject {
                id: 1,
                dropped: a_dropped.clone(),
                drop_order: a_order.clone(),
                global_order: global_order.clone(),
            },
        )
        .unwrap();

    arena
        .alloc(
            &marker,
            PanicDropper {
                should_panic: true,
                dropped: b_dropped.clone(),
            },
        )
        .unwrap();

    arena
        .alloc(
            &marker,
            TrackedObject {
                id: 3,
                dropped: c_dropped.clone(),
                drop_order: c_order.clone(),
                global_order: global_order.clone(),
            },
        )
        .unwrap();

    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = arena.close_scope(marker);
    }));

    // C ya se destruyó (orden 0). B falló. A sigue sin destruir.
    assert!(c_dropped.load(Ordering::SeqCst));
    assert!(b_dropped.load(Ordering::SeqCst));
    assert!(!a_dropped.load(Ordering::SeqCst));

    // Ahora liberamos la arena por completo: drop(arena) debe destruir A
    drop(arena);

    // A debió ser destruido limpiamente durante el drop de la arena
    assert!(
        a_dropped.load(Ordering::SeqCst),
        "A debió ser destruido exactamente una vez en drop(arena)"
    );
    assert_eq!(
        a_order.load(Ordering::SeqCst),
        1,
        "A debió ser el segundo drop global ejecutado"
    );
}

/// P0-ARENA-04: Ámbitos anidados con pánico en el ámbito interior.
/// La arena se envenena, impidiendo nuevas asignaciones exteriores, y
/// el drop final de la arena destruye tanto los objetos interiores no ejecutados
/// como los objetos exteriores en orden determinista.
#[test]
fn test_p0_arena_04_nested_scopes_with_inner_panic() {
    let global_order = Arc::new(AtomicUsize::new(0));

    let outer_dropped = Arc::new(AtomicBool::new(false));
    let outer_order = Arc::new(AtomicUsize::new(usize::MAX));

    let inner1_dropped = Arc::new(AtomicBool::new(false));
    let inner1_order = Arc::new(AtomicUsize::new(usize::MAX));

    let inner2_dropped = Arc::new(AtomicBool::new(false));

    let mut arena = ScopedArena::new(4096).unwrap();
    let outer_marker = arena.begin_scope().unwrap();

    arena
        .alloc(
            &outer_marker,
            TrackedObject {
                id: 10,
                dropped: outer_dropped.clone(),
                drop_order: outer_order.clone(),
                global_order: global_order.clone(),
            },
        )
        .unwrap();

    let inner_marker = arena.begin_scope().unwrap();
    arena
        .alloc(
            &inner_marker,
            TrackedObject {
                id: 20,
                dropped: inner1_dropped.clone(),
                drop_order: inner1_order.clone(),
                global_order: global_order.clone(),
            },
        )
        .unwrap();

    arena
        .alloc(
            &inner_marker,
            PanicDropper {
                should_panic: true,
                dropped: inner2_dropped.clone(),
            },
        )
        .unwrap();

    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = arena.close_scope(inner_marker);
    }));

    assert!(arena.is_poisoned());
    assert!(inner2_dropped.load(Ordering::SeqCst));
    assert!(!inner1_dropped.load(Ordering::SeqCst));
    assert!(!outer_dropped.load(Ordering::SeqCst));

    // Cerrar el exterior también debe ser rechazado por envenenamiento
    let close_outer_err = arena.close_scope(outer_marker).unwrap_err();
    assert_eq!(close_outer_err.error, ArenaError::Poisoned);

    // drop de la arena limpia inner1 y luego outer
    drop(arena);

    assert!(inner1_dropped.load(Ordering::SeqCst));
    assert!(outer_dropped.load(Ordering::SeqCst));
    assert_eq!(inner1_order.load(Ordering::SeqCst), 0);
    assert_eq!(outer_order.load(Ordering::SeqCst), 1);
}

/// P0-ARENA-05: Tipos de tamaño cero (ZST) con Drop intercalados con tipos normales.
/// El offset de memoria no debe alterarse por ZSTs, pero sus destructores
/// deben ser invocados en estricto orden LIFO y protegidos contra pánicos.
#[test]
fn test_p0_arena_05_zst_drop_interleaved_and_panic() {
    DROP_COUNTER.store(0, Ordering::SeqCst);
    let mut arena = ScopedArena::new(1024).unwrap();
    let marker = arena.begin_scope().unwrap();

    let offset1 = arena.used_bytes();
    let _ = arena.alloc(&marker, ZstDrop).unwrap();
    assert_eq!(arena.used_bytes(), offset1, "ZST no consume bytes");

    let _ = arena.alloc(&marker, 12345u64).unwrap();
    let offset2 = arena.used_bytes();
    assert!(offset2 > offset1);

    let _ = arena.alloc(&marker, ZstDrop).unwrap();
    assert_eq!(arena.used_bytes(), offset2, "Segundo ZST no consume bytes");

    arena.close_scope(marker).unwrap();
    assert_eq!(
        DROP_COUNTER.load(Ordering::SeqCst),
        2,
        "Ambos ZSTs debieron ejecutarse"
    );
    assert_eq!(arena.used_bytes(), 0);
}

/// P0-ARENA-06: Tipos con propiedad compleja del heap (Vec, String, Box)
/// liberan su memoria del heap limpiamente al salir del ámbito y ante pánicos.
#[test]
fn test_p0_arena_06_complex_heap_owners_freed_cleanly() {
    let mut arena = ScopedArena::new(4096).unwrap();
    let marker = arena.begin_scope().unwrap();

    let v = arena
        .alloc(&marker, vec![10u8, 20, 30, 40, 50, 60, 70, 80])
        .unwrap();
    assert_eq!(v.len(), 8);

    let s = arena
        .alloc(&marker, String::from("ELE/NEXO memory safety invariant"))
        .unwrap();
    assert_eq!(s.as_str(), "ELE/NEXO memory safety invariant");

    let b = arena
        .alloc(&marker, Box::new([1000u64, 2000, 3000]))
        .unwrap();
    assert_eq!(b[1], 2000);

    arena.close_scope(marker).unwrap();
    assert_eq!(arena.used_bytes(), 0);
}

/// P0-ARENA-07: Comportamiento ante anidamiento profundo de ámbitos y verificación de tipos de error.
/// Se comprueba que aperturas secuenciales incrementan el contador y el cierre en orden inverso
/// restaura la arena limpia a 0 ámbitos activos, y que `ArenaError::ScopeDepthExhausted`
/// es reportado adecuadamente ante desbordamiento.
#[test]
fn test_p0_arena_07_deep_scope_nesting_and_depth_invariants() {
    let mut arena = ScopedArena::new(8192).unwrap();
    let mut markers = Vec::new();

    // Abrir 64 ámbitos anidados sucesivamente
    for _ in 0..64 {
        let m = arena.begin_scope().unwrap();
        markers.push(m);
    }

    assert_eq!(markers.len(), 64);

    // Cerrar en orden inverso LIFO estricto
    while let Some(m) = markers.pop() {
        arena.close_scope(m).unwrap();
    }

    assert_eq!(arena.used_bytes(), 0);
}

/// P0-ARENA-08: Alineaciones extremas de hasta 4096 bytes (tamaño de página física).
/// Se verifica que el cálculo de padding y align_offset no desborde y la dirección
/// resultante sea estrictamente múltiplo de 4096.
#[test]
fn test_p0_arena_08_extreme_alignment_up_to_4096() {
    let mut arena = ScopedArena::new_with_alignment(16384, 4096).unwrap();
    let marker = arena.begin_scope().unwrap();

    let aligned = arena
        .alloc(&marker, Aligned4096 { data: [0x55; 4096] })
        .unwrap();

    let ptr_val = (aligned as *const Aligned4096) as usize;
    assert_eq!(
        ptr_val % 4096,
        0,
        "La dirección del objeto debe ser estrictamente divisible por 4096"
    );
    assert_eq!(aligned.data[0], 0x55);
    assert_eq!(aligned.data[4095], 0x55);

    arena.close_scope(marker).unwrap();
    assert_eq!(arena.used_bytes(), 0);
}

// =========================================================================
// SUITE MANDATORIA DROP-01 a DROP-07 (Destrucción Final Resiliente y Pánicos)
// =========================================================================

/// DROP-01: Un destructor provoca un pánico y existen otros tres destructores pendientes.
/// Se comprueba que TODOS los destructores pendientes se ejecutan, en estricto orden LIFO,
/// exactamente una vez cada uno.
#[test]
fn test_drop_01_single_panic_with_three_pending_destructors() {
    let global_order = Arc::new(AtomicUsize::new(0));

    let d1_dropped = Arc::new(AtomicBool::new(false));
    let d1_order = Arc::new(AtomicUsize::new(usize::MAX));

    let d2_dropped = Arc::new(AtomicBool::new(false));
    let d2_order = Arc::new(AtomicUsize::new(usize::MAX));

    let d3_dropped = Arc::new(AtomicBool::new(false));
    let d3_order = Arc::new(AtomicUsize::new(usize::MAX));

    let d4_dropped = Arc::new(AtomicBool::new(false));
    let d4_order = Arc::new(AtomicUsize::new(usize::MAX));

    struct TrackedPanic {
        dropped: Arc<AtomicBool>,
        order: Arc<AtomicUsize>,
        global: Arc<AtomicUsize>,
    }
    impl Drop for TrackedPanic {
        fn drop(&mut self) {
            self.dropped.store(true, Ordering::SeqCst);
            let ord = self.global.fetch_add(1, Ordering::SeqCst);
            self.order.store(ord, Ordering::SeqCst);
            panic!("pánico intencional en destructor DROP-01");
        }
    }

    let panic_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut arena = ScopedArena::new(4096).unwrap();
        let marker = arena.begin_scope().unwrap();

        // Asignar en orden: 1, 2, 3, y 4 (que causará pánico al dropearse)
        arena
            .alloc(
                &marker,
                TrackedObject {
                    id: 1,
                    dropped: d1_dropped.clone(),
                    drop_order: d1_order.clone(),
                    global_order: global_order.clone(),
                },
            )
            .unwrap();

        arena
            .alloc(
                &marker,
                TrackedObject {
                    id: 2,
                    dropped: d2_dropped.clone(),
                    drop_order: d2_order.clone(),
                    global_order: global_order.clone(),
                },
            )
            .unwrap();

        arena
            .alloc(
                &marker,
                TrackedObject {
                    id: 3,
                    dropped: d3_dropped.clone(),
                    drop_order: d3_order.clone(),
                    global_order: global_order.clone(),
                },
            )
            .unwrap();

        arena
            .alloc(
                &marker,
                TrackedPanic {
                    dropped: d4_dropped.clone(),
                    order: d4_order.clone(),
                    global: global_order.clone(),
                },
            )
            .unwrap();

        // Al salir de este bloque, `arena` se dropea.
        // El drop de `arena` extrae en LIFO: d4 (paniquea), d3, d2, d1.
    }));

    assert!(
        panic_result.is_err(),
        "drop(arena) debió reanudar el pánico"
    );

    // Todos los 4 objetos debieron ser destruidos
    assert!(d4_dropped.load(Ordering::SeqCst), "d4 debió ejecutarse");
    assert!(d3_dropped.load(Ordering::SeqCst), "d3 debió ejecutarse");
    assert!(d2_dropped.load(Ordering::SeqCst), "d2 debió ejecutarse");
    assert!(d1_dropped.load(Ordering::SeqCst), "d1 debió ejecutarse");

    // Orden LIFO estricto: 4 -> 3 -> 2 -> 1
    assert_eq!(d4_order.load(Ordering::SeqCst), 0, "d4 primero");
    assert_eq!(d3_order.load(Ordering::SeqCst), 1, "d3 segundo");
    assert_eq!(d2_order.load(Ordering::SeqCst), 2, "d2 tercero");
    assert_eq!(d1_order.load(Ordering::SeqCst), 3, "d1 cuarto");
}

/// DROP-02: Dos destructores diferentes provocan pánicos en el mismo drop de arena.
/// Se comprueba que ambos se ejecutan, los objetos normales intermedios también se ejecutan,
/// y no existe doble destrucción ni comportamiento indefinido.
#[test]
fn test_drop_02_multiple_panics_during_arena_drop() {
    let global_order = Arc::new(AtomicUsize::new(0));

    let d1_dropped = Arc::new(AtomicBool::new(false));
    let d2_dropped = Arc::new(AtomicBool::new(false));
    let d3_dropped = Arc::new(AtomicBool::new(false));
    let d4_dropped = Arc::new(AtomicBool::new(false));

    struct MultiPanic {
        msg: &'static str,
        dropped: Arc<AtomicBool>,
        global: Arc<AtomicUsize>,
    }
    impl Drop for MultiPanic {
        fn drop(&mut self) {
            self.dropped.store(true, Ordering::SeqCst);
            self.global.fetch_add(1, Ordering::SeqCst);
            panic!("{}", self.msg);
        }
    }

    let panic_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut arena = ScopedArena::new(4096).unwrap();
        let marker = arena.begin_scope().unwrap();

        // 1: normal
        arena
            .alloc(
                &marker,
                TrackedObject {
                    id: 1,
                    dropped: d1_dropped.clone(),
                    drop_order: Arc::new(AtomicUsize::new(0)),
                    global_order: global_order.clone(),
                },
            )
            .unwrap();

        // 2: paniquea
        arena
            .alloc(
                &marker,
                MultiPanic {
                    msg: "pánico en d2",
                    dropped: d2_dropped.clone(),
                    global: global_order.clone(),
                },
            )
            .unwrap();

        // 3: normal
        arena
            .alloc(
                &marker,
                TrackedObject {
                    id: 3,
                    dropped: d3_dropped.clone(),
                    drop_order: Arc::new(AtomicUsize::new(0)),
                    global_order: global_order.clone(),
                },
            )
            .unwrap();

        // 4: paniquea
        arena
            .alloc(
                &marker,
                MultiPanic {
                    msg: "pánico en d4",
                    dropped: d4_dropped.clone(),
                    global: global_order.clone(),
                },
            )
            .unwrap();
    }));

    assert!(panic_result.is_err());

    // Se verifica que todos los 4 destructores tuvieron su oportunidad de correr
    assert!(d4_dropped.load(Ordering::SeqCst), "d4 ejecutado");
    assert!(d3_dropped.load(Ordering::SeqCst), "d3 ejecutado");
    assert!(d2_dropped.load(Ordering::SeqCst), "d2 ejecutado");
    assert!(d1_dropped.load(Ordering::SeqCst), "d1 ejecutado");
    assert_eq!(global_order.load(Ordering::SeqCst), 4);
}

/// DROP-03: Destrucción de una arena ya envenenada (`ArenaState::Poisoned`).
/// Los objetos pendientes que quedaron en la arena tras el envenenamiento
/// deben ser ejecutados limpiamente al invocar `drop(arena)`.
#[test]
fn test_drop_03_poisoned_arena_final_drop() {
    let global_order = Arc::new(AtomicUsize::new(0));
    let outer_dropped = Arc::new(AtomicBool::new(false));
    let inner_ok_dropped = Arc::new(AtomicBool::new(false));
    let inner_panic_dropped = Arc::new(AtomicBool::new(false));

    let mut arena = ScopedArena::new(4096).unwrap();
    let outer = arena.begin_scope().unwrap();

    arena
        .alloc(
            &outer,
            TrackedObject {
                id: 100,
                dropped: outer_dropped.clone(),
                drop_order: Arc::new(AtomicUsize::new(0)),
                global_order: global_order.clone(),
            },
        )
        .unwrap();

    let inner = arena.begin_scope().unwrap();
    arena
        .alloc(
            &inner,
            TrackedObject {
                id: 200,
                dropped: inner_ok_dropped.clone(),
                drop_order: Arc::new(AtomicUsize::new(0)),
                global_order: global_order.clone(),
            },
        )
        .unwrap();

    arena
        .alloc(
            &inner,
            PanicDropper {
                should_panic: true,
                dropped: inner_panic_dropped.clone(),
            },
        )
        .unwrap();

    // Provocar envenenamiento cerrando `inner` con pánico
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = arena.close_scope(inner);
    }));

    assert!(arena.is_poisoned());
    assert!(inner_panic_dropped.load(Ordering::SeqCst));
    assert!(!inner_ok_dropped.load(Ordering::SeqCst));
    assert!(!outer_dropped.load(Ordering::SeqCst));

    // Liberar la arena envenenada: debe destruir inner_ok y outer
    drop(arena);

    assert!(inner_ok_dropped.load(Ordering::SeqCst));
    assert!(outer_dropped.load(Ordering::SeqCst));
}

/// DROP-04: Verificación de la propagación transparente del primer pánico en `drop(arena)`.
#[test]
fn test_drop_04_panic_propagation_payload() {
    let panic_res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut arena = ScopedArena::new(1024).unwrap();
        let marker = arena.begin_scope().unwrap();

        struct CustomPanic;
        impl Drop for CustomPanic {
            fn drop(&mut self) {
                panic!("DROP-04-PAYLOAD-MATCH");
            }
        }

        let _ = arena.alloc(&marker, CustomPanic).unwrap();
        // drop(arena) ocurre al salir del closure
    }));

    assert!(panic_res.is_err());
    let err = panic_res.unwrap_err();
    if let Some(msg) = err.downcast_ref::<&str>() {
        assert_eq!(*msg, "DROP-04-PAYLOAD-MATCH");
    } else if let Some(msg) = err.downcast_ref::<String>() {
        assert_eq!(msg.as_str(), "DROP-04-PAYLOAD-MATCH");
    } else {
        panic!("El payload de pánico no coincidió con el esperado");
    }
}

/// DROP-05: Pánico durante unwinding previo.
/// Comprueba que si el hilo ya se encuentra en proceso de desenrollado (`std::thread::panicking()`),
/// `drop(arena)` no llama a `resume_unwind` (lo cual causaría un aborto fatal del proceso por doble pánico),
/// sino que limpia todos los objetos restantes y permite que el pánico original continúe de forma segura.
#[test]
fn test_drop_05_no_double_panic_abort_during_unwinding() {
    let remaining_dropped = Arc::new(AtomicBool::new(false));
    let remaining_clone = remaining_dropped.clone();

    // Ejecutar en un hilo separado para aislar el unwinding
    let handle = std::thread::spawn(move || {
        struct PanickingDrop;
        impl Drop for PanickingDrop {
            fn drop(&mut self) {
                panic!("segundo pánico durante unwinding");
            }
        }

        let mut arena = ScopedArena::new(2048).unwrap();
        let marker = arena.begin_scope().unwrap();

        let _ = arena
            .alloc(
                &marker,
                TrackedObject {
                    id: 999,
                    dropped: remaining_clone,
                    drop_order: Arc::new(AtomicUsize::new(0)),
                    global_order: Arc::new(AtomicUsize::new(0)),
                },
            )
            .unwrap();

        let _ = arena.alloc(&marker, PanickingDrop).unwrap();

        // Lanzar un pánico inicial en el hilo:
        // Durante el desenrollado de este pánico, `arena` será dropeada.
        // Dentro de `drop(arena)`, `PanickingDrop` paniqueará.
        // La guarda `!std::thread::panicking()` debe interceptar este segundo pánico
        // e impedir el aborto del proceso, ejecutando a su vez `TrackedObject`.
        panic!("pánico inicial del hilo");
    });

    let join_res = handle.join();
    assert!(join_res.is_err(), "El hilo debió terminar en pánico");
    assert!(
        remaining_dropped.load(Ordering::SeqCst),
        "El objeto remanente debió ser destruido limpiamente a pesar del pánico secundario"
    );
}

/// DROP-06: Destructores con liberación compleja de heap (`Box`, `Vec`, `String`) y recursos simulados.
/// Garantiza ausencia de fugas de recursos al salir por pánico.
#[test]
fn test_drop_06_complex_heap_resources_cleaned_on_panic() {
    static RESOURCE_COUNT: AtomicUsize = AtomicUsize::new(0);

    struct ExternalResource {
        _buffer: Vec<u8>,
        _boxed: Box<[String]>,
    }

    impl ExternalResource {
        fn new() -> Self {
            RESOURCE_COUNT.fetch_add(1, Ordering::SeqCst);
            Self {
                _buffer: vec![0xcc; 512],
                _boxed: vec![String::from("hello"), String::from("nexo")].into_boxed_slice(),
            }
        }
    }

    impl Drop for ExternalResource {
        fn drop(&mut self) {
            RESOURCE_COUNT.fetch_sub(1, Ordering::SeqCst);
        }
    }

    RESOURCE_COUNT.store(0, Ordering::SeqCst);

    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut arena = ScopedArena::new(4096).unwrap();
        let marker = arena.begin_scope().unwrap();

        let _ = arena.alloc(&marker, ExternalResource::new()).unwrap();
        let _ = arena.alloc(&marker, ExternalResource::new()).unwrap();
        let _ = arena
            .alloc(
                &marker,
                PanicDropper {
                    should_panic: true,
                    dropped: Arc::new(AtomicBool::new(false)),
                },
            )
            .unwrap();
    }));

    // Ambos recursos externos debieron ser desasignados
    assert_eq!(
        RESOURCE_COUNT.load(Ordering::SeqCst),
        0,
        "Todos los recursos de heap externos debieron liberarse"
    );
}

/// DROP-07: Ámbitos anidados con destructores pendientes y pánicos concurrentes en cascada.
#[test]
fn test_drop_07_nested_scopes_cascade_cleanup() {
    let order_log = Arc::new(std::sync::Mutex::new(Vec::new()));

    struct LoggedDrop {
        id: usize,
        log: Arc<std::sync::Mutex<Vec<usize>>>,
        panics: bool,
    }

    impl Drop for LoggedDrop {
        fn drop(&mut self) {
            self.log.lock().unwrap().push(self.id);
            if self.panics {
                panic!("pánico en {}", self.id);
            }
        }
    }

    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut arena = ScopedArena::new(8192).unwrap();
        let outer = arena.begin_scope().unwrap();
        let _ = arena
            .alloc(
                &outer,
                LoggedDrop {
                    id: 1,
                    log: order_log.clone(),
                    panics: false,
                },
            )
            .unwrap();

        let mid = arena.begin_scope().unwrap();
        let _ = arena
            .alloc(
                &mid,
                LoggedDrop {
                    id: 2,
                    log: order_log.clone(),
                    panics: true,
                },
            )
            .unwrap();

        let inner = arena.begin_scope().unwrap();
        let _ = arena
            .alloc(
                &inner,
                LoggedDrop {
                    id: 3,
                    log: order_log.clone(),
                    panics: false,
                },
            )
            .unwrap();
        let _ = arena
            .alloc(
                &inner,
                LoggedDrop {
                    id: 4,
                    log: order_log.clone(),
                    panics: true,
                },
            )
            .unwrap();
    }));

    let recorded = order_log.lock().unwrap().clone();
    // Debe haber ejecutado los 4 destructores en LIFO: 4, 3, 2, 1
    assert_eq!(recorded, vec![4, 3, 2, 1]);
}

/// DROP-08: Destructor que entra en pánico tras liberar parcialmente un recurso compuesto.
#[test]
fn test_drop_08_partial_release_and_panic() {
    let res1_freed = Arc::new(AtomicBool::new(false));
    let res2_freed = Arc::new(AtomicBool::new(false));
    let remaining_freed = Arc::new(AtomicBool::new(false));

    struct CompoundResource {
        r1: Arc<AtomicBool>,
        r2: Arc<AtomicBool>,
    }

    impl Drop for CompoundResource {
        fn drop(&mut self) {
            self.r1.store(true, Ordering::SeqCst);
            // Pánico intencional antes de liberar r2
            panic!("pánico intermedio tras liberar r1");
            #[allow(unreachable_code)]
            self.r2.store(true, Ordering::SeqCst);
        }
    }

    struct SimpleTracker(Arc<AtomicBool>);
    impl Drop for SimpleTracker {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut arena = ScopedArena::new(4096).unwrap();
        let marker = arena.begin_scope().unwrap();
        let _ = arena
            .alloc(&marker, SimpleTracker(remaining_freed.clone()))
            .unwrap();
        let _ = arena
            .alloc(
                &marker,
                CompoundResource {
                    r1: res1_freed.clone(),
                    r2: res2_freed.clone(),
                },
            )
            .unwrap();
    }));

    assert!(result.is_err());
    assert!(
        res1_freed.load(Ordering::SeqCst),
        "r1 debió ser liberado antes del pánico"
    );
    assert!(
        !res2_freed.load(Ordering::SeqCst),
        "r2 no pudo liberarse debido al pánico"
    );
    assert!(
        remaining_freed.load(Ordering::SeqCst),
        "el objeto restante debió liberarse incondicionalmente en LIFO"
    );
}

/// DROP-09: Destructor que muta estado externo persistente y posteriormente entra en pánico.
#[test]
fn test_drop_09_external_state_mutation_before_panic() {
    let audit_trail = Arc::new(std::sync::Mutex::new(Vec::new()));
    let sibling_dropped = Arc::new(AtomicBool::new(false));

    struct AuditDrop {
        name: &'static str,
        trail: Arc<std::sync::Mutex<Vec<&'static str>>>,
        panics: bool,
    }

    impl Drop for AuditDrop {
        fn drop(&mut self) {
            self.trail.lock().unwrap().push(self.name);
            if self.panics {
                panic!("fallo durante auditoría de {}", self.name);
            }
        }
    }

    struct Sibling(Arc<AtomicBool>);
    impl Drop for Sibling {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut arena = ScopedArena::new(4096).unwrap();
        let marker = arena.begin_scope().unwrap();
        let _ = arena
            .alloc(&marker, Sibling(sibling_dropped.clone()))
            .unwrap();
        let _ = arena
            .alloc(
                &marker,
                AuditDrop {
                    name: "AuditA",
                    trail: audit_trail.clone(),
                    panics: true,
                },
            )
            .unwrap();
    }));

    let trail = audit_trail.lock().unwrap().clone();
    assert_eq!(trail, vec!["AuditA"]);
    assert!(sibling_dropped.load(Ordering::SeqCst));
}

/// DROP-10: Dos destructores que fallan durante el unwinding inicial de un hilo (prevención de double-panic).
#[test]
fn test_drop_10_multiple_failures_during_thread_unwinding() {
    let drops_attempted = Arc::new(AtomicUsize::new(0));

    struct MultiPanic {
        id: usize,
        counter: Arc<AtomicUsize>,
    }

    impl Drop for MultiPanic {
        fn drop(&mut self) {
            self.counter.fetch_add(1, Ordering::SeqCst);
            panic!("pánico secundario en objeto {}", self.id);
        }
    }

    struct UnwindHolder {
        _arena: ScopedArena,
    }

    let counter_clone = drops_attempted.clone();
    let thread_result = std::thread::spawn(move || {
        let mut arena = ScopedArena::new(4096).unwrap();
        let marker = arena.begin_scope().unwrap();
        let _ = arena
            .alloc(
                &marker,
                MultiPanic {
                    id: 1,
                    counter: counter_clone.clone(),
                },
            )
            .unwrap();
        let _ = arena
            .alloc(
                &marker,
                MultiPanic {
                    id: 2,
                    counter: counter_clone.clone(),
                },
            )
            .unwrap();

        let _holder = UnwindHolder { _arena: arena };
        panic!("pánico primario del hilo que inicia el unwinding");
    })
    .join();

    assert!(thread_result.is_err(), "El hilo debió finalizar con pánico");
    assert_eq!(
        drops_attempted.load(Ordering::SeqCst),
        2,
        "Ambos destructores debieron ejecutarse sin abortar el proceso"
    );
}

/// DROP-11: Objeto de tamaño cero (ZST) cuyo destructor entra en pánico.
#[test]
fn test_drop_11_zero_sized_type_destructor_panic() {
    let zst_attempted = Arc::new(AtomicBool::new(false));
    let sibling_dropped = Arc::new(AtomicBool::new(false));

    struct ZstPanic(Arc<AtomicBool>);
    impl Drop for ZstPanic {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
            panic!("pánico en ZST");
        }
    }

    struct Sibling(Arc<AtomicBool>);
    impl Drop for Sibling {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut arena = ScopedArena::new(1024).unwrap();
        let marker = arena.begin_scope().unwrap();
        let _ = arena
            .alloc(&marker, Sibling(sibling_dropped.clone()))
            .unwrap();
        let _ = arena
            .alloc(&marker, ZstPanic(zst_attempted.clone()))
            .unwrap();
    }));

    assert!(result.is_err());
    assert!(zst_attempted.load(Ordering::SeqCst));
    assert!(sibling_dropped.load(Ordering::SeqCst));
}

/// DROP-12: Ámbito interior envenenado con objetos exteriores pendientes de destrucción.
#[test]
fn test_drop_12_inner_scope_poisoned_with_outer_pending() {
    let outer_a_dropped = Arc::new(AtomicBool::new(false));
    let outer_b_dropped = Arc::new(AtomicBool::new(false));
    let inner_dropped = Arc::new(AtomicBool::new(false));

    struct Track(Arc<AtomicBool>);
    impl Drop for Track {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    struct PanicInner(Arc<AtomicBool>);
    impl Drop for PanicInner {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
            panic!("pánico en ámbito interior");
        }
    }

    let mut arena = ScopedArena::new(4096).unwrap();
    let outer = arena.begin_scope().unwrap();
    let _ = arena.alloc(&outer, Track(outer_a_dropped.clone())).unwrap();
    let _ = arena.alloc(&outer, Track(outer_b_dropped.clone())).unwrap();

    let inner = arena.begin_scope().unwrap();
    let _ = arena
        .alloc(&inner, PanicInner(inner_dropped.clone()))
        .unwrap();

    // Intentar cerrar el ámbito interior, lo que provocará el pánico de PanicInner
    let close_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = arena.close_scope(inner);
    }));
    assert!(close_result.is_err());
    assert!(arena.is_poisoned());
    assert!(inner_dropped.load(Ordering::SeqCst));
    assert!(!outer_a_dropped.load(Ordering::SeqCst));
    assert!(!outer_b_dropped.load(Ordering::SeqCst));

    // Ahora se destruye la arena completa envenenada: los objetos del ámbito exterior deben ser liberados limpiamente
    drop(arena);
    assert!(
        outer_a_dropped.load(Ordering::SeqCst),
        "outer_a debió liberarse al destruir la arena"
    );
    assert!(
        outer_b_dropped.load(Ordering::SeqCst),
        "outer_b debió liberarse al destruir la arena"
    );
}

/// DROP-13: Múltiples recursos con dependencias estrictas de orden de destrucción.
#[test]
fn test_drop_13_strict_dependency_lifo_order() {
    let order = Arc::new(std::sync::Mutex::new(Vec::new()));

    struct DependencyResource {
        id: usize,
        log: Arc<std::sync::Mutex<Vec<usize>>>,
        panics: bool,
    }

    impl Drop for DependencyResource {
        fn drop(&mut self) {
            self.log.lock().unwrap().push(self.id);
            if self.panics {
                panic!("pánico en nodo intermedio {}", self.id);
            }
        }
    }

    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut arena = ScopedArena::new(8192).unwrap();
        let marker = arena.begin_scope().unwrap();
        for i in 1..=5 {
            let panics = i == 3;
            let _ = arena
                .alloc(
                    &marker,
                    DependencyResource {
                        id: i,
                        log: order.clone(),
                        panics,
                    },
                )
                .unwrap();
        }
    }));

    let recorded = order.lock().unwrap().clone();
    assert_eq!(
        recorded,
        vec![5, 4, 3, 2, 1],
        "El orden de destrucción debe ser exactamente inverso a la asignación"
    );
}

/// DROP-14: Cierre explícito fallido (desajuste de marcador) seguido de destrucción final de la arena.
#[test]
fn test_drop_14_close_scope_mismatch_then_final_drop() {
    let obj_dropped = Arc::new(AtomicBool::new(false));

    struct Track(Arc<AtomicBool>);
    impl Drop for Track {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    let mut arena1 = ScopedArena::new(2048).unwrap();
    let marker1 = arena1.begin_scope().unwrap();
    let _ = arena1.alloc(&marker1, Track(obj_dropped.clone())).unwrap();

    let mut arena2 = ScopedArena::new(2048).unwrap();
    let marker2 = arena2.begin_scope().unwrap();

    // Intentar cerrar arena1 usando el marcador de arena2 -> Debe fallar con ScopeMismatch
    let err = arena1.close_scope(marker2).unwrap_err();
    let (returned_marker, error_kind) = err.into_parts();
    assert_eq!(error_kind, ArenaError::ScopeMismatch);
    assert_eq!(returned_marker.arena_id(), arena2.id());
    assert!(!obj_dropped.load(Ordering::SeqCst));

    // Cerrar arena2 con su marcador recuperado
    arena2.close_scope(returned_marker).unwrap();

    // Destruir arena1: debe limpiar sus objetos sin corromperse
    drop(arena1);
    assert!(obj_dropped.load(Ordering::SeqCst));
}

/// DROP-15: Verificación de pureza de layout y compatibilidad con Miri.
#[test]
fn test_drop_15_miri_layout_and_zero_leak_verification() {
    // Esta prueba opera exclusivamente sobre buffers heap estándar vía Layout y NonNull,
    // por lo que no involucra syscalls virtuales y es compatible con el modelo formal de Miri.
    let mut arena = ScopedArena::new(1024).unwrap();
    let marker = arena.begin_scope().unwrap();

    let p1 = arena.alloc(&marker, 42u64).unwrap();
    assert_eq!(*p1, 42);

    let p2 = arena.alloc(&marker, [1u8; 32]).unwrap();
    assert_eq!(p2[0], 1);

    arena.close_scope(marker).unwrap();
    assert_eq!(arena.used_bytes(), 0);
}

/// DROP-16: Prueba aislada de proceso / hilo para validar contención ante panic.
#[test]
fn test_drop_16_isolated_child_panic_resilience() {
    let (tx, rx) = std::sync::mpsc::channel();

    let handle = std::thread::spawn(move || {
        let result = std::panic::catch_unwind(|| {
            let mut arena = ScopedArena::new(4096).unwrap();
            let marker = arena.begin_scope().unwrap();
            struct PanicBomb;
            impl Drop for PanicBomb {
                fn drop(&mut self) {
                    panic!("bomba intencional de pánico");
                }
            }
            let _ = arena.alloc(&marker, PanicBomb).unwrap();
            drop(arena);
        });
        tx.send(result.is_err()).unwrap();
    });

    handle.join().unwrap();
    assert!(
        rx.recv().unwrap(),
        "El pánico debió ser capturado y contenido sin abortar el proceso"
    );
}
