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

/// Error de asignación o ámbito en `ScopedArena`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ArenaError {
    OutOfMemory,
    InvalidAlignment,
    ScopeMismatch,
    Poisoned,
    ScopeDepthExhausted,
}

impl fmt::Display for ArenaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OutOfMemory => write!(f, "arena memory or capacity exhausted"),
            Self::InvalidAlignment => write!(f, "invalid alignment requested"),
            Self::ScopeMismatch => write!(f, "scope marker mismatch or out-of-order scope access"),
            Self::Poisoned => write!(f, "arena is poisoned due to a destructor panic"),
            Self::ScopeDepthExhausted => write!(f, "maximum active scope depth exhausted"),
        }
    }
}

impl std::error::Error for ArenaError {}

/// Estado de operatividad de `ScopedArena`.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ArenaState {
    Active,
    Poisoned,
}

impl fmt::Display for ArenaState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Active => write!(f, "Active"),
            Self::Poisoned => write!(f, "Poisoned"),
        }
    }
}

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

    pub fn offset(&self) -> usize {
        self.offset
    }

    pub fn drop_count(&self) -> usize {
        self.drop_count
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
    state: ArenaState,
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

        // Asignar el ID monotónico de la arena ANTES de reservar memoria,
        // garantizando ausencia de fugas de memoria si la asignación de ID falla.
        let id = next_arena_id()?;

        let layout = Layout::from_size_align(capacity, base_align)
            .map_err(|_| ArenaError::InvalidAlignment)?;
        let ptr = unsafe { alloc(layout) };
        let buffer = NonNull::new(ptr).ok_or(ArenaError::OutOfMemory)?;

        Ok(Self {
            id,
            buffer,
            capacity,
            base_align,
            offset: 0,
            active_scopes: 0,
            state: ArenaState::Active,
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

    pub fn state(&self) -> ArenaState {
        self.state
    }

    pub fn is_poisoned(&self) -> bool {
        self.state == ArenaState::Poisoned
    }

    /// Inicia un nuevo ámbito estructurado y retorna un marcador lineal ligado a esta arena.
    ///
    /// Retorna `Err(ArenaError::Poisoned)` si la arena se encuentra envenenada por un pánico previo,
    /// o `Err(ArenaError::ScopeDepthExhausted)` si se supera la profundidad máxima representable.
    pub fn begin_scope(&mut self) -> Result<ScopeMarker, ArenaError> {
        if self.state == ArenaState::Poisoned {
            return Err(ArenaError::Poisoned);
        }
        let next_scope = self
            .active_scopes
            .checked_add(1)
            .ok_or(ArenaError::ScopeDepthExhausted)?;
        self.active_scopes = next_scope;
        Ok(ScopeMarker {
            arena_id: self.id,
            scope_id: self.active_scopes,
            offset: self.offset,
            drop_count: self.drops.len(),
        })
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
        if self.state == ArenaState::Poisoned {
            return Err(ArenaError::Poisoned);
        }
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
    /// aborta retornando `Err(CloseScopeError { marker, error })` devolviendo el marcador
    /// intacto sin ejecutar destructores ni alterar el offset.
    ///
    /// Si un destructor entra en pánico durante el cierre:
    /// 1. La arena pasa a estado `Poisoned`.
    /// 2. El `offset` NO se retrocede hacia el inicio del ámbito, impidiendo que asignaciones
    ///    posteriores sobreescriban memoria de objetos aún pendientes de destrucción.
    /// 3. La entrada en `drops` correspondiente al objeto que entró en pánico ya fue extraída,
    ///    asegurando formalmente que jamás será destruido por segunda vez.
    /// 4. Los objetos restantes en ámbitos exteriores o previos son preservados intactos y serán
    ///    destruidos de forma segura cuando la arena sea finalmente liberada en `Drop`.
    pub fn close_scope(&mut self, marker: ScopeMarker) -> Result<(), CloseScopeError> {
        if self.state == ArenaState::Poisoned {
            return Err(CloseScopeError {
                marker,
                error: ArenaError::Poisoned,
            });
        }
        if marker.arena_id != self.id || marker.scope_id != self.active_scopes {
            return Err(CloseScopeError {
                marker,
                error: ArenaError::ScopeMismatch,
            });
        }

        // Guarda para envenenar la arena ante pánico durante la ejecución de destructores
        struct ScopeCloseGuard<'a> {
            arena: &'a mut ScopedArena,
            completed: bool,
        }

        impl<'a> Drop for ScopeCloseGuard<'a> {
            fn drop(&mut self) {
                if !self.completed {
                    // Pánico durante el cierre de destructores:
                    // Envenenar la arena de forma irreversible.
                    self.arena.state = ArenaState::Poisoned;
                    // NO retroceder offset: los objetos vivos o pendientes en la arena
                    // no deben ser sobreescritos por código que capture el pánico.
                }
            }
        }

        let mut guard = ScopeCloseGuard {
            arena: self,
            completed: false,
        };

        // Ejecutar destructores registrados durante este ámbito en orden LIFO
        while guard.arena.drops.len() > marker.drop_count {
            if let Some(entry) = guard.arena.drops.pop() {
                // Se extrae primero; si drop_fn entra en pánico, entry ya no está en drops
                unsafe {
                    (entry.drop_fn)(entry.ptr);
                }
            }
        }

        // Si todos los destructores concluyeron normalmente, restaurar offset y decrementar ámbitos
        guard.arena.offset = marker.offset;
        guard.arena.active_scopes = guard.arena.active_scopes.saturating_sub(1);
        guard.completed = true;
        Ok(())
    }
}

impl Drop for ScopedArena {
    fn drop(&mut self) {
        // Guarda de búfer: garantiza que la memoria virtual se libere ÚNICAMENTE
        // DESPUÉS de que todos los destructores pendientes hayan sido ejecutados o intentados,
        // incluso ante pánicos sucesivos.
        struct BufferGuard {
            buffer: NonNull<u8>,
            capacity: usize,
            base_align: usize,
        }

        impl Drop for BufferGuard {
            fn drop(&mut self) {
                let layout = Layout::from_size_align(self.capacity, self.base_align).unwrap();
                unsafe {
                    dealloc(self.buffer.as_ptr(), layout);
                }
            }
        }

        let _guard = BufferGuard {
            buffer: self.buffer,
            capacity: self.capacity,
            base_align: self.base_align,
        };

        let mut first_panic: Option<Box<dyn std::any::Any + Send + 'static>> = None;

        // Drenar y ejecutar todos los destructores pendientes en estricto orden LIFO.
        // Si uno o más destructores entran en pánico, se capturan individualmente para
        // asegurar que los objetos restantes tengan la oportunidad de ejecutarse y liberar recursos.
        while let Some(entry) = self.drops.pop() {
            // Se extrae `entry` ANTES de la llamada; si entra en pánico, jamás se vuelve a invocar.
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
                (entry.drop_fn)(entry.ptr);
            }));

            if let Err(err) = result
                && first_panic.is_none()
            {
                first_panic = Some(err);
            }
        }

        // Una vez ejecutados todos los drops, `_guard` liberará la memoria virtual al salir.
        // Si ocurrió algún pánico y el hilo no se encontraba ya en unwinding, reanudar
        // el primer pánico para cumplir con la política de propagación transparente.
        // Si el hilo ya estaba desenrollándose (p. ej. en catch_unwind exterior), no reanudamos
        // para evitar un aborto fatal por doble pánico (double panic abort).
        if let Some(panic_payload) = first_panic
            && !std::thread::panicking()
        {
            drop(_guard);
            std::panic::resume_unwind(panic_payload);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scope_depth_overflow_checked_boundary() {
        let mut arena = ScopedArena::new(1024).unwrap();
        // Simular el límite superior absoluto de u64
        arena.active_scopes = u64::MAX;

        let res = arena.begin_scope();
        assert_eq!(res.unwrap_err(), ArenaError::ScopeDepthExhausted);
    }

    #[test]
    fn test_arena_state_display_and_equality() {
        assert_eq!(format!("{}", ArenaState::Active), "Active");
        assert_eq!(format!("{}", ArenaState::Poisoned), "Poisoned");
        assert_eq!(
            format!("{}", ArenaError::ScopeDepthExhausted),
            "maximum active scope depth exhausted"
        );
        assert_eq!(
            format!("{}", ArenaError::Poisoned),
            "arena is poisoned due to a destructor panic"
        );
    }
}
