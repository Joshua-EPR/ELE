//! Pruebas de verificación de `ScopedArena` y asignación determinista por ámbito.

use nexo::next::{ArenaError, ScopedArena};
use std::sync::atomic::{AtomicUsize, Ordering};

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

struct ZstDrop;
impl Drop for ZstDrop {
    fn drop(&mut self) {
        DROP_COUNTER.fetch_add(1, Ordering::SeqCst);
    }
}

struct PanicDropper {
    should_panic: bool,
}

impl Drop for PanicDropper {
    fn drop(&mut self) {
        DROP_COUNTER.fetch_add(1, Ordering::SeqCst);
        if self.should_panic {
            panic!("pánico intencional en destructor para prueba de seguridad");
        }
    }
}

#[test]
fn test_arena_basic_allocation_and_alignment() {
    let mut arena = ScopedArena::new(1024).unwrap();
    let marker = arena.begin_scope();

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

    let outer_marker = arena.begin_scope();
    let _d1 = arena.alloc(&outer_marker, DropTracker { _id: 1 }).unwrap();
    assert_eq!(DROP_COUNTER.load(Ordering::SeqCst), 0);

    {
        let inner_marker = arena.begin_scope();
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
    let marker = arena.begin_scope();

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

    let marker1 = arena1.begin_scope();
    let marker2 = arena2.begin_scope();

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
    let outer = arena.begin_scope();
    let inner = arena.begin_scope();

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
    let marker = arena.begin_scope();

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
    let marker = arena.begin_scope();

    let a256 = arena.alloc(&marker, Aligned256 { data: [0; 256] }).unwrap();
    let ptr_val = (a256 as *const Aligned256) as usize;
    assert_eq!(ptr_val % 256, 0);

    arena.close_scope(marker).unwrap();
}

#[test]
fn test_zst_allocation_and_drop() {
    DROP_COUNTER.store(0, Ordering::SeqCst);
    let mut arena = ScopedArena::new(512).unwrap();
    let marker = arena.begin_scope();

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

#[test]
fn test_panic_in_destructor_is_handled_cleanly_without_double_drop() {
    DROP_COUNTER.store(0, Ordering::SeqCst);
    let mut arena = ScopedArena::new(1024).unwrap();
    let outer = arena.begin_scope();

    let _d1 = arena.alloc(&outer, DropTracker { _id: 1 }).unwrap();

    let inner = arena.begin_scope();
    let _p = arena
        .alloc(&inner, PanicDropper { should_panic: true })
        .unwrap();

    // Intentar cerrar el ámbito interior con un destructor que entra en pánico
    let panic_result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = arena.close_scope(inner);
    }));
    assert!(
        panic_result.is_err(),
        "El destructor debió causar un pánico capturado"
    );

    // El contador de drops incrementó 1 (el objeto que entró en pánico)
    assert_eq!(DROP_COUNTER.load(Ordering::SeqCst), 1);

    // Al salir del ámbito y dropear la arena, d1 del ámbito exterior debe dropearse normalmente
    // sin doble drop de p
    drop(arena);
    assert_eq!(DROP_COUNTER.load(Ordering::SeqCst), 2);
}
