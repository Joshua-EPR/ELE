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
