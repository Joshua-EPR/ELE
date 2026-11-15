//! Asignador por ámbito y pila de datos (`ScopedArena`).
//!
//! Permite asignar objetos efímeros mediante avance de puntero (*bump allocation*)
//! con destrucción determinista en orden inverso al salir del ámbito, sin incurrir
//! en sobrecarga de metadatos generacionales para objetos no enlazables.

use std::alloc::{Layout, alloc, dealloc};
use std::ptr::NonNull;

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
    scope_id: u64,
    offset: usize,
    drop_count: usize,
}

impl ScopeMarker {
    pub fn scope_id(&self) -> u64 {
        self.scope_id
    }
}

/// Pila de datos y asignador por ámbito estructurado.
pub struct ScopedArena {
    id: u64,
    buffer: NonNull<u8>,
    capacity: usize,
    offset: usize,
    active_scopes: u64,
    drops: Vec<DropEntry>,
}

unsafe impl Send for ScopedArena {}

impl ScopedArena {
    /// Crea una nueva arena con la capacidad en bytes indicada.
    pub fn new(capacity: usize) -> Result<Self, ArenaError> {
        if capacity == 0 {
            return Err(ArenaError::OutOfMemory);
        }
        let layout =
            Layout::from_size_align(capacity, 16).map_err(|_| ArenaError::InvalidAlignment)?;
        let ptr = unsafe { alloc(layout) };
        let buffer = NonNull::new(ptr).ok_or(ArenaError::OutOfMemory)?;

        Ok(Self {
            id: 1,
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

    /// Inicia un nuevo ámbito estructurado y retorna un marcador lineal.
    pub fn begin_scope(&mut self) -> ScopeMarker {
        self.active_scopes = self.active_scopes.saturating_add(1);
        ScopeMarker {
            scope_id: self.active_scopes,
            offset: self.offset,
            drop_count: self.drops.len(),
        }
    }

    /// Asigna un valor dentro del ámbito actual.
    ///
    /// El destructor del valor `T` se registrará automáticamente y será invocado
    /// de forma determinista cuando se cierre el ámbito correspondiente.
    pub fn alloc<T>(&mut self, marker: &ScopeMarker, val: T) -> Result<&mut T, ArenaError> {
        if marker.scope_id != self.active_scopes {
            return Err(ArenaError::ScopeMismatch);
        }

        let layout = Layout::new::<T>();
        let align = layout.align();
        let size = layout.size();

        // Alinear el offset actual
        let current_ptr = unsafe { self.buffer.as_ptr().add(self.offset) };
        let unaligned_addr = current_ptr as usize;
        let aligned_addr = (unaligned_addr + align - 1) & !(align - 1);
        let padding = aligned_addr - unaligned_addr;

        let total_needed = padding.checked_add(size).ok_or(ArenaError::OutOfMemory)?;
        let new_offset = self
            .offset
            .checked_add(total_needed)
            .ok_or(ArenaError::OutOfMemory)?;
        if new_offset > self.capacity {
            return Err(ArenaError::OutOfMemory);
        }

        let target_ptr = aligned_addr as *mut T;
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
    /// Ejecuta todos los destructores de los objetos asignados en el ámbito
    /// en orden LIFO y retrocede el puntero de asignación de forma atómica.
    pub fn close_scope(&mut self, marker: ScopeMarker) -> Result<(), ArenaError> {
        if marker.scope_id != self.active_scopes {
            return Err(ArenaError::ScopeMismatch);
        }

        // Ejecutar destructores registrados durante este ámbito en orden inverso
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
        let layout = Layout::from_size_align(self.capacity, 16).unwrap();
        unsafe {
            dealloc(self.buffer.as_ptr(), layout);
        }
    }
}
