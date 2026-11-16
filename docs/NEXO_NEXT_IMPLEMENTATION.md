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

## 3. Estado de resolución de defectos de seguridad (P0 / P1 Lockdown)

| Defecto | Clasificación | Solución implementada | Validación |
|---|---|---|---|
| **P0-001** | Emisión de tokens de autoridad desde enteros arbitrarios (`acquire_token_for`) | Eliminados totalmente `acquire_token_for(u64)` y `acquire_token()`. La autoridad solo se emite mediante `register_pool(&PhysicalPool)`. | `AUTH-HARDEN-01`, `run_fixture_check("call-acquire-token-for")` (E0599) |
| **P0-002** | Registros duplicados descontrolados de un mismo pool físico | `CompactPoolRegistry` y `CompactPoolRegistry16` imponen registro atómico único ($1:1$) rechazando duplicados con `AlreadyRegistered { physical_pool_id }`. | `AUTH-08`, `AUTH-HARDEN-03`, `AUTH-HARDEN-14` |
| **P0-003** | Falta de reporte explícito de subpáginas en cuarentena | Adaptadores `CompactPhysicalPool` y `CompactPhysicalPool64` distinguen `PageState::Quarantined` y retornan `SubpageQuarantined`. | `AUTH-14`, `AUTH-HARDEN-11` |
| **P1-004** | Exposición de mocks privilegiados bajo feature flag en producción | Eliminada la feature `test-mocks` de `Cargo.toml` y retirado `pub mod testing`. Mocks confinados a `#[cfg(test)] mod tests` de `compact.rs`. | `AUTH-04`, `AUTH-HARDEN-18`, `run_fixture_check("access-mock-compact-pool")` (E0433) |
| **P1-005** | Contaminación y agotamiento del registro global en pruebas | Factorizados `CompactIdAllocator8` y `CompactIdAllocator16` para instancias aisladas de prueba de agotamiento y concurrencia sin alterar los singletons. | `AUTH-19`, `AUTH-20`, `AUTH-HARDEN-15`, `AUTH-HARDEN-16` |
| **P1-006** | Pruebas adversariales insuficientes o basadas en comentarios | Convertidas en pruebas reales mediante `run_fixture_check` contra `external_consumer` verificando errores de compilación (`E0277`, `E0433`, `E0502`, `E0515`, `E0560`, `E0599`). | `AUTH-01..20`, `AUTH-HARDEN-01..20` |

---

## 4. Suites de Validación de Autoridad y Seguridad

- **`test_authority_soundness.rs` (AUTH-01..20)**: Validación completa de sellado, vinculación de pool físico, rechazo de estados corruptos/retirados, no-ABA y confinamiento de préstamos.
- **`test_authority_lockdown.rs` (AUTH-HARDEN-01..20)**: Validación adversarial de endurecimiento exhaustivo que cubre las 20 invariantes de cierre de autoridad.
- **`api_security.rs` (11 pruebas)**: Encapsulación de capacidades lineales y helpers internos.
- **`test_compact_nexo.rs` (12 pruebas)**: Integración de adaptadores compactos, enlaces de 32/64 bits y dominios de generación.
- **`child_isolation.rs` (5 pruebas)**: Verificación a nivel de SO y hardware de aislamiento de memoria física en procesos hijos con captura de SIGSEGV.
