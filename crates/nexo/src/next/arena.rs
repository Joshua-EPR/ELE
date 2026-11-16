//! Asignador por ámbito y pila de datos (`ScopedArena`).
//!
//! Permite asignar objetos efímeros mediante avance de puntero (*bump allocation*)
//! con destrucción determinista en orden inverso al salir del ámbito, sin incurrir
//! en sobrecarga de metadatos generacionales para objetos no enlazables.

use std::alloc::{Layout, alloc, dealloc};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicU64, Ordering};

/// Alineación base garantizada del búfer de la arena (128 bytes).
pub const ARENA_BASE_ALIGN: usize = 128;

static NEXT_ARENA_ID: AtomicU64 = AtomicU64::new(1);

/// Error de asignación en `ScopedArena`.
#[derive(Debug, Eq, PartialEq)]
pub enum ArenaError {
    OutOfMemory,
    InvalidAlignment,
    ScopeMismatch,
}

struct DropEntry {
    drop_fn: unsafe fn(*mut u8),
    ptr: *mut u8,
}

/// Marcador lineal de ámbito en una `ScopedArena`.
///
/// Deliberadamente no implementa `Clone` ni `Copy` para forzar su consumo
/// explícito mediante [`ScopedArena::close_scope`].
#[derive(Debug)]
pub struct ScopeMarker {
    arena_id: u64,
    scope_id: u64,
    offset: usize,
    drop_count: usize,
}

impl ScopeMarker {
    pub fn arena_id(&self) -> u64 {
        self.arena_id
    }

    pub fn scope_id(&self) -> u64 {
        self.scope_id
    }
}

/// Pila de datos y asignador por ámbito estructurado.
///
/// `ScopedArena` contiene punteros crudos (`NonNull<u8>`) y no implementa `Send` ni `Sync`,
/// garantizando que tipos no aptos para concurrencia (como `Rc`) no puedan ser transferidos
/// entre hilos a través de la arena.
pub struct ScopedArena {
    id: u64,
    buffer: NonNull<u8>,
    capacity: usize,
    offset: usize,
    active_scopes: u64,
    drops: Vec<DropEntry>,
}

impl ScopedArena {
    /// Crea una nueva arena con la capacidad en bytes indicada.
    pub fn new(capacity: usize) -> Result<Self, ArenaError> {
        if capacity == 0 {
            return Err(ArenaError::OutOfMemory);
        }
        let layout = Layout::from_size_align(capacity, ARENA_BASE_ALIGN)
            .map_err(|_| ArenaError::InvalidAlignment)?;
        let ptr = unsafe { alloc(layout) };
        let buffer = NonNull::new(ptr).ok_or(ArenaError::OutOfMemory)?;

        let id = NEXT_ARENA_ID.fetch_add(1, Ordering::Relaxed);

        Ok(Self {
            id,
            buffer,
            capacity,
            offset: 0,
            active_scopes: 0,
            drops: Vec::new(),
        })
    }

    pub fn id(&self) -> u64 {
        self.id
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }

    pub fn used_bytes(&self) -> usize {
        self.offset
    }

    pub fn available_bytes(&self) -> usize {
        self.capacity.saturating_sub(self.offset)
    }

    /// Inicia un nuevo ámbito estructurado y retorna un marcador lineal ligado a esta arena.
    pub fn begin_scope(&mut self) -> ScopeMarker {
        self.active_scopes = self.active_scopes.saturating_add(1);
        ScopeMarker {
            arena_id: self.id,
            scope_id: self.active_scopes,
            offset: self.offset,
            drop_count: self.drops.len(),
        }
    }

    /// Asigna un valor dentro del ámbito actual.
    ///
    /// Valida la afinidad estricta entre el marcador y la arena, así como el nivel de ámbito.
    /// Si el tipo `T` necesita destrucción (`std::mem::needs_drop`), su destructor se registrará
    /// para ejecución determinista LIFO al cerrar el ámbito.
    pub fn alloc<T>(&mut self, marker: &ScopeMarker, val: T) -> Result<&mut T, ArenaError> {
        if marker.arena_id != self.id || marker.scope_id != self.active_scopes {
            return Err(ArenaError::ScopeMismatch);
        }

        let layout = Layout::new::<T>();
        let align = layout.align();
        let size = layout.size();

        // Calcular desplazamiento de alineación de forma segura contra desbordamientos
        let current_ptr = unsafe { self.buffer.as_ptr().add(self.offset) };
        let align_offset = current_ptr.align_offset(align);
        if align_offset == usize::MAX {
            return Err(ArenaError::InvalidAlignment);
        }

        let total_needed = align_offset
            .checked_add(size)
            .ok_or(ArenaError::OutOfMemory)?;
        let new_offset = self
            .offset
            .checked_add(total_needed)
            .ok_or(ArenaError::OutOfMemory)?;

        if new_offset > self.capacity {
            return Err(ArenaError::OutOfMemory);
        }

        let target_ptr = unsafe { self.buffer.as_ptr().add(self.offset + align_offset) as *mut T };
        unsafe {
            target_ptr.write(val);
        }

        // Registrar destructor si el tipo necesita Drop
        if std::mem::needs_drop::<T>() {
            unsafe fn drop_wrapper<U>(raw: *mut u8) {
                let typed_ptr = raw as *mut U;
                unsafe { std::ptr::drop_in_place(typed_ptr) };
            }
            self.drops.push(DropEntry {
                drop_fn: drop_wrapper::<T>,
                ptr: target_ptr as *mut u8,
            });
        }

        self.offset = new_offset;
        unsafe { Ok(&mut *target_ptr) }
    }

    /// Cierra el ámbito estructurado consumiendo el marcador lineal.
    ///
    /// Valida la afinidad de arena y orden estricto de ámbito. Ante cualquier discordancia,
    /// aborta retornando `Err(ArenaError::ScopeMismatch)` sin ejecutar destructores ni corromper
    /// el offset o contador de ámbitos.
    pub fn close_scope(&mut self, marker: ScopeMarker) -> Result<(), ArenaError> {
        if marker.arena_id != self.id || marker.scope_id != self.active_scopes {
            return Err(ArenaError::ScopeMismatch);
        }

        // Ejecutar destructores registrados durante este ámbito en orden LIFO
        while self.drops.len() > marker.drop_count {
            if let Some(entry) = self.drops.pop() {
                unsafe {
                    (entry.drop_fn)(entry.ptr);
                }
            }
        }

        // Restaurar el offset al punto en que se inició el ámbito
        self.offset = marker.offset;
        self.active_scopes = self.active_scopes.saturating_sub(1);
        Ok(())
    }
}

impl Drop for ScopedArena {
    fn drop(&mut self) {
        // Ejecutar cualquier drop pendiente en orden LIFO
        while let Some(entry) = self.drops.pop() {
            unsafe {
                (entry.drop_fn)(entry.ptr);
            }
        }
        let layout = Layout::from_size_align(self.capacity, ARENA_BASE_ALIGN).unwrap();
        unsafe {
            dealloc(self.buffer.as_ptr(), layout);
        }
    }
}
