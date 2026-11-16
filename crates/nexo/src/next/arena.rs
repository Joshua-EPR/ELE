//! Asignador por ámbito y pila de datos (`ScopedArena`).
//!
//! Permite asignar objetos efímeros mediante avance de puntero (*bump allocation*)
//! con destrucción determinista en orden inverso al salir del ámbito, sin incurrir
//! en sobrecarga de metadatos generacionales para objetos no enlazables.

use std::alloc::{Layout, alloc, dealloc};
use std::fmt;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicU64, Ordering};

/// Alineación base garantizada por defecto del búfer de la arena (128 bytes).
pub const ARENA_BASE_ALIGN: usize = 128;

static NEXT_ARENA_ID: AtomicU64 = AtomicU64::new(1);

/// Error de asignación en `ScopedArena`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ArenaError {
    OutOfMemory,
    InvalidAlignment,
    ScopeMismatch,
}

impl fmt::Display for ArenaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OutOfMemory => write!(f, "arena memory or capacity exhausted"),
            Self::InvalidAlignment => write!(f, "invalid alignment requested"),
            Self::ScopeMismatch => write!(f, "scope marker mismatch or out-of-order scope access"),
        }
    }
}

impl std::error::Error for ArenaError {}

/// Error al cerrar un ámbito en `ScopedArena`.
///
/// Conserva la propiedad lineal del marcador [`ScopeMarker`] para permitir al llamador
/// recuperarse o reintentar el cierre tras resolver la condición de error, sin clonar ni
/// fabricar marcadores.
pub struct CloseScopeError {
    pub marker: ScopeMarker,
    pub error: ArenaError,
}

impl CloseScopeError {
    pub fn into_parts(self) -> (ScopeMarker, ArenaError) {
        (self.marker, self.error)
    }
}

impl fmt::Debug for CloseScopeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloseScopeError")
            .field("error", &self.error)
            .field("marker", &self.marker)
            .finish()
    }
}

impl fmt::Display for CloseScopeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "failed to close scope: {}", self.error)
    }
}

impl std::error::Error for CloseScopeError {}

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
/// garantizando formalmente que tipos no aptos para concurrencia (como `Rc`) no puedan ser transferidos
/// entre hilos a través de la arena.
pub struct ScopedArena {
    id: u64,
    buffer: NonNull<u8>,
    capacity: usize,
    base_align: usize,
    offset: usize,
    active_scopes: u64,
    drops: Vec<DropEntry>,
}

fn next_arena_id() -> Result<u64, ArenaError> {
    let mut current = NEXT_ARENA_ID.load(Ordering::Relaxed);
    loop {
        if current == u64::MAX {
            return Err(ArenaError::OutOfMemory);
        }
        let next = current + 1;
        match NEXT_ARENA_ID.compare_exchange_weak(
            current,
            next,
            Ordering::SeqCst,
            Ordering::Relaxed,
        ) {
            Ok(val) => return Ok(val),
            Err(actual) => current = actual,
        }
    }
}

impl ScopedArena {
    /// Crea una nueva arena con la capacidad en bytes indicada y alineación base de 128 bytes.
    pub fn new(capacity: usize) -> Result<Self, ArenaError> {
        Self::new_with_alignment(capacity, ARENA_BASE_ALIGN)
    }

    /// Crea una nueva arena con alineación base explícita (debe ser potencia de dos).
    pub fn new_with_alignment(capacity: usize, base_align: usize) -> Result<Self, ArenaError> {
        if capacity == 0 {
            return Err(ArenaError::OutOfMemory);
        }
        if base_align == 0 || !base_align.is_power_of_two() {
            return Err(ArenaError::InvalidAlignment);
        }
        let layout = Layout::from_size_align(capacity, base_align)
            .map_err(|_| ArenaError::InvalidAlignment)?;
        let ptr = unsafe { alloc(layout) };
        let buffer = NonNull::new(ptr).ok_or(ArenaError::OutOfMemory)?;

        let id = next_arena_id()?;

        Ok(Self {
            id,
            buffer,
            capacity,
            base_align,
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
    /// Exige `T: 'static` para garantizar formalmente que ningún valor con referencias a la pila
    /// o a objetos externos pueda ser almacenado y posteriormente accedido por un destructor tras
    /// expirar el ámbito de la referencia.
    ///
    /// Valida la afinidad estricta entre el marcador y la arena, así como el nivel de ámbito.
    /// Si el tipo `T` necesita destrucción (`std::mem::needs_drop`), su destructor se registrará
    /// pre-reservando memoria antes de escribir el valor, garantizando ausencia de fugas ante OOM.
    pub fn alloc<T: 'static>(
        &mut self,
        marker: &ScopeMarker,
        val: T,
    ) -> Result<&mut T, ArenaError> {
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

        // Si el tipo necesita Drop, pre-reservar espacio en el vector de destructores
        // ANTES de escribir el valor para evitar objetos vivos no registrados ante OOM.
        if std::mem::needs_drop::<T>() {
            self.drops
                .try_reserve(1)
                .map_err(|_| ArenaError::OutOfMemory)?;
        }

        let target_ptr = unsafe { self.buffer.as_ptr().add(self.offset + align_offset) as *mut T };
        unsafe {
            target_ptr.write(val);
        }

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
    /// aborta retornando `Err(CloseScopeError { marker, error: ScopeMismatch })` devolviendo el marcador
    /// intacto sin ejecutar destructores ni corromper el offset o contador de ámbitos.
    ///
    /// Si un destructor entra en pánico durante el cierre, un guard de limpieza garantiza que el
    /// estado de la arena quede consistente y ningún objeto sea doblemente destruido.
    pub fn close_scope(&mut self, marker: ScopeMarker) -> Result<(), CloseScopeError> {
        if marker.arena_id != self.id || marker.scope_id != self.active_scopes {
            return Err(CloseScopeError {
                marker,
                error: ArenaError::ScopeMismatch,
            });
        }

        // Estructura de guarda para asegurar consistencia ante pánicos en destructores
        struct CleanupGuard<'a> {
            arena: &'a mut ScopedArena,
            target_offset: usize,
            target_scopes: u64,
        }

        impl<'a> Drop for CleanupGuard<'a> {
            fn drop(&mut self) {
                self.arena.offset = self.target_offset;
                self.arena.active_scopes = self.target_scopes;
            }
        }

        let guard = CleanupGuard {
            target_offset: marker.offset,
            target_scopes: self.active_scopes.saturating_sub(1),
            arena: self,
        };

        // Ejecutar destructores registrados durante este ámbito en orden LIFO
        while guard.arena.drops.len() > marker.drop_count {
            if let Some(entry) = guard.arena.drops.pop() {
                unsafe {
                    (entry.drop_fn)(entry.ptr);
                }
            }
        }

        drop(guard);
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
        let layout = Layout::from_size_align(self.capacity, self.base_align).unwrap();
        unsafe {
            dealloc(self.buffer.as_ptr(), layout);
        }
    }
}
