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
  - Generación de 16 bits.
  - Inicia en 1 (impar, vivo).
  - Incremento por 2 en cada ciclo de asignación.
  - Al alcanzar $65533$, se retira permanentemente con `GEN_RETIRADO_16 = 0xfffe`.
  - Demostración de No-ABA por saturación en retiro.
- `CompactLink`:
  - Enlace de 4 bytes (`u32`).
  - 24 bits para índice de slot (hasta 16.777.216 slots).
  - 8 bits para generación truncada de validación rápida.

### 2.3 Optimizaciones de revalidación (`next/optimize.rs`)
- `BatchRevalidator`:
  - Estructura para comprobar múltiples enlaces pertenecientes al mismo pool de forma agrupada.
  - Accede una sola vez a la cabecera / metadatos de superpágina para validar un conjunto de enlaces contiguos.
- `InvariantRevalidation`:
  - Helper que modela la validez persistente de una revalidación cuando el análisis de efectos demuestra ausencia de mutaciones en el pool.
