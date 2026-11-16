# NEXO v0.4: Registro de Implementación Experimental

**Estado:** Documento de diseño e implementación para NEXO v0.4.  
**Rama:** `feat/nexo-v0.4-next-memory`  
**Fecha:** 2026-11-15  

---

## 1. Módulos y arquitectura de código

El desarrollo experimental de NEXO v0.4 se estructura de forma estrictamente modular dentro de `crates/nexo/src/next/` para no alterar ni interferir con las rutas probadas de `crates/nexo/src/physical/`:

```text
crates/nexo/src/
├── lib.rs
├── physical/          # Allocator v0.3 probado (PR #69)
│   ├── address_space.rs
│   ├── generation.rs
│   ├── oracle_adapter.rs
│   ├── platform/
│   └── pool.rs
└── next/              # Prototipos experimentales v0.4
    ├── mod.rs
    ├── arena.rs       # Pila de datos / Asignador por ámbito (ScopedArena)
    ├── compact.rs     # Generaciones (16-bit) y Enlaces compactos (4 bytes)
    └── optimize.rs    # Optimizaciones de revalidación en lote y hoisting
```

---

## 2. Descripción de componentes

### 2.1 `ScopedArena` (`next/arena.rs`)
- Implementa asignación contigua mediante avance de puntero (*bump pointer*).
- Gestiona memoria virtual confirmada en bloques elásticos.
- Soporta anidamiento de ámbitos mediante marcadores lineales `ScopeMarker`:
  - `begin_scope(&mut self) -> ScopeMarker`
  - `close_scope(&mut self, marker: ScopeMarker)`
- Al cerrar un ámbito:
  - Se ejecutan los destructores de los objetos alojados en orden LIFO.
  - El puntero de asignación retrocede a la posición inicial del marcador.
  - Cero fragmentación, sin metadatos generacionales por objeto.

### 2.2 Generaciones y Enlaces compactos (`next/compact.rs`)
- `CompactGen`:
  - Soporte dual de 16 bits (`GEN_RETIRADO_16 = 0xfffe`) y 8 bits (`GEN_RETIRADO_8 = 0xfe`).
  - Inicia en 1 (impar, vivo).
  - Incremento por 2 en cada ciclo de asignación.
  - Al alcanzar 253 (8 bits) o 65533 (16 bits), se retira permanentemente sin wraparound.
  - Demostración de No-ABA por saturación en retiro.
- `CompactPoolRegistry`:
  - Registro acotado de identificadores únicos de pool compacto (1..=255).
  - Monotónico y sin reciclaje para evitar que un pool posterior reutilice la identidad de enlaces antiguos.
  - Al agotar los 255 IDs, falla con `CompactPoolError::PoolIdExhausted`.
- `CompactLink` (32 bits, 4 bytes):
  - 16 bits para índice de slot (0..65.535 slots por pool).
  - 8 bits para generación compacta viva (1..253).
  - 8 bits para identidad de pool de origen (1..255).
  - Cero colisiones generacionales (gen 1 vs gen 257 eliminado).
- `CompactLink64` (64 bits, 8 bytes):
  - 32 bits para índice de slot (hasta 4.294.967.295).
  - 16 bits para generación completa de 16 bits (retira en 65534).
  - 16 bits para identificador de pool extendido (1..65535).

### 2.3 Optimizaciones de revalidación (`next/optimize.rs`)
- `BatchRevalidator`:
  - Estructura para comprobar múltiples enlaces pertenecientes al mismo pool de forma agrupada.
  - Accede una sola vez a la cabecera / metadatos de superpágina para validar un conjunto de enlaces contiguos.
- `InvariantRevalidation`:
  - Helper que modela la validez persistente de una revalidación cuando el análisis de efectos demuestra ausencia de mutaciones en el pool.

### 2.4 Adaptadores Físicos Autorizados (`next/adapter.rs`)
- `CompactPhysicalPool` y `CompactPhysicalPool64`:
  - Enlazan una referencia prestada `&'a PhysicalPool` con un `&'a CompactPoolToken` verificado.
  - El constructor valida estrictamente `token.physical_pool_id() == pool.id()`, impidiendo falsificación de autoridad.
  - Implementan el trait sellado `CompactPoolAuthority` y `CompactPoolAuthority64` validando el estado real de la memoria física:
    - Estado de subpágina `PageState::Committed` (rechazo estricto de `Quarantined`, `Reserved`, `Returned`, `ReclaimPending`).
    - Límite de slot verificado contra la capacidad física y acotado por `(MAX_SLOT_COMPACT_32 as u64) + 1`.
    - Generación viva impar verificada contra los metadatos de superpágina y el espejo físico.
  - Devuelven `CompactObjRef<'a>` o `CompactObjRef64<'a>`, tokens opacos de lectura enlazados al tiempo de vida `'a` del pool prestado.

---

## 3. Estado de resolución de defectos de seguridad (P0 / P1)

| Defecto | Clasificación | Solución implementada | Validación |
|---|---|---|---|
| **P0-001** | Pseudo-sellado de `CompactPoolAuthority` (`pub mod private`) | Módulo `pub(crate) mod private { pub trait Sealed {} pub struct InternalSeal; }` con método sellado `__seal_authority` y doctests `compile_fail`. | `AUTH-01`, `AUTH-02`, 9 doctests |
| **P0-002** | Emparejamiento no verificado de Pool ↔ Token | `CompactPoolToken` y `CompactPoolToken16` almacenan `physical_pool_id: u64`; constructores de adaptadores validan coincidencia exacta con `pool.id()`. | `AUTH-05`, `AUTH-06`, `AUTH-07`, `AUTH-08`, `AUTH-09` |
| **P0-003** | Fuga de `MockCompactPool` a producción | Aislados detrás de `#[cfg(any(test, feature = "test-mocks"))]`. Crate de producción no exporta mocks. | `AUTH-04`, compilación de producción |
| **P1-004** | Exposición pública de registros independientes | `CompactPoolRegistryInstance` y `CompactPoolRegistryInstance16` son `pub(crate)` y excluidos de la API pública. | `AUTH-19`, `AUTH-20`, pruebas unitarias |
| **P1-005** | Mutación de contador global en pruebas de agotamiento | `next_arena_id` refactorizado para delegar en `allocate_arena_id(&AtomicU64)`. Pruebas usan contadores atómicos locales. | Pruebas concurrentes en `arena.rs` |
| **P1-006** | Capacidad de slot desbordaba representación de 16 bits | `slot_capacity()` en `CompactPhysicalPool` acotado a `pool_cap.min((MAX_SLOT_COMPACT_32 as u64) + 1) as u32`. | `AUTH-16` |
