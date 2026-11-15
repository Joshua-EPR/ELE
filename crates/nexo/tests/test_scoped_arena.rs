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
fn test_scope_mismatch_rejected() {
    let mut arena = ScopedArena::new(1024).unwrap();
    let outer_marker = arena.begin_scope();
    let inner_marker = arena.begin_scope();

    // Intentar asignar usando el marcador externo cuando el interno está activo
    let res = arena.alloc(&outer_marker, 123u32);
    assert_eq!(res.unwrap_err(), ArenaError::ScopeMismatch);

    // Intentar cerrar el ámbito externo antes de cerrar el interno
    let close_outer = arena.close_scope(outer_marker);
    assert_eq!(close_outer.unwrap_err(), ArenaError::ScopeMismatch);

    // Cerrar en orden correcto (interno primero, luego externo)
    arena.close_scope(inner_marker).unwrap();
}
