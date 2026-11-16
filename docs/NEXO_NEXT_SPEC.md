# NEXO v0.4: Especificación de la siguiente evolución del modelo de memoria de ELE

**Estado:** Especificación arquitectónica y operacional para el subsistema experimental `ele-nexo`.  
**Rama:** `feat/nexo-v0.4-next-memory`  
**Base:** `feat/nexo-v0.3-physical-memory @ d4d8e76` (PR #69)  
**Fecha:** 2026-11-15  

---

## 1. Alcance, principios y reglas no negociables

NEXO v0.4 es la evolución incremental del modelo de memoria de ELE diseñado para cerrar las limitaciones L01–L09 identificadas en v0.3, optimizar el uso de memoria física y tiempo de ejecución, y preparar el sustrato para la futura integración con ELE-LIR sin degradar ninguna de las garantías preexistentes.

### Principios rectores
1. **No reescritura**: Se conserva íntegramente la implementación validada de NEXO v0.3 (Bi-Slab, allocator físico, fallos PFS01–PFS12, capacidades lineales en dos fases y pruebas A01–A12).
2. **Linealidad inquebrantable**: Todo objeto vivo posee exactamente un dueño en cada instante. No se admite clonación de `Handle` ni de `HoleToken`.
3. **Ausencia absoluta de UAF y Double-Free**: Ningún enlace desreferenciado puede acceder a memoria reciclada; ningún destructor puede ejecutarse dos veces sobre la misma capacidad.
4. **Protección contra ABA**: Ninguna generación puede sufrir wraparound que reactive un enlace antiguo retirado.
5. **Aislamiento de producción**: Las nuevas capacidades permanecen optativas y experimentales en `crates/nexo`; no se modifica el modelo predeterminado de ELE ni de `main`.

---

## 2. Matriz de estado real y evolución (v0.3 → v0.4)

| Funcionalidad | Especificada | Implementada (v0.3) | Probada | Demostrada | Evolución en v0.4 |
|---|---|---|---|---|---|
| **Propiedad lineal** | Sí (FORMAL §3) | Sí (`Handle`, `HoleToken` privados) | Sí (N01–N05, A01–A07, doctests) | Probada por arnés | **Conservar**: Extender a tokens de ámbito (`ScopeToken`) |
| **Préstamos** | Sí (FORMAL §5, R1–R7) | Sí (`verif/`, `maquina.rs`) | Sí (N06–N09, verificador 42 tests) | Parcial (lemas) | **Mejorar**: Préstamos acotados a regiones sin metadatos |
| **Generaciones** | Sí (FORMAL §2, §9.1) | Sí (32-bit, impar/par, `g_ret`) | Sí (N15, F12, F13, A08) | Probada por casos | **Extender**: Prototipo de generaciones compactas (16-bit) |
| **Revalidación** | Sí (FORMAL §6) | Sí (`revalidate` dinámico) | Sí (N16–N20, F07, A08) | Punto fijo | **Optimizar**: Hoisting de invariantes y verificación en lote |
| **Regiones / Ámbitos**| Parcial (MAREA/C6) | No en memoria física | Parcial (oráculo v0.2) | No | **Implementar**: Pila de datos / Arena por avance de puntero |
| **Reclaim físico** | Sí (FORMAL §9.1) | Sí (PFS01–PFS12, cuarentena) | Sí (S01–S12, child probe real) | Empírica (fuzz) | **Conservar**: Dos fases y reporte estructurado |
| **Concurrencia** | Sí en abstracto (C1–C6)| No en físico (`!Send`/`!Sync`)| Sí en oráculo v0.2 | Enunciado (T3)| **Fase E**: Transferencia exclusiva entre hilos (`Send`) |
| **Integración ELE** | Documentada (ELE_PORT)| No (aislada en `crates/nexo`)| No en compilador | No | **Preparar**: Definición de tipos y operaciones para ELE-LIR |

---

## 3. Especificación detallada de mejoras arquitectónicas

### 3.1 Asignación según posibilidad de enlace (Escape & Linkability Analysis)
- **Problema en v0.3**: Todo objeto asignado en un pool generacional incurre en metadatos generacionales (32 bits de generación, bits en bitmaps libre/hueco, entradas en índice de densidad y cabecera de superpágina), incluso si jamás se genera un `Link` sobre él.
- **Diseño v0.4**:
  - El compilador clasifica los sitios de asignación en:
    1. *Enlazables (`Linkable`)*: Objetos sobre los cuales se ejecuta `enlazar` o cuyo tipo/flujo expone identidades persistentes. Se asignan en el `PhysicalPool` generacional con cabecera y ciclo de vida Bi-Slab.
    2. *No enlazables (`Direct-only`)*: Objetos locales a un ámbito cuyo acceso se produce exclusivamente mediante el dueño lineal y préstamos locales `view`/`edit`. Se asignan en una **pila de datos / arena por ámbito**.
  - **Preservación de reglas**:
    - **R1**: Acceso directo garantizado por el token de propiedad o préstamo activo.
    - **R5**: Ningún préstamo puede escapar del ámbito del objeto raíz.
    - **R6**: Solo los objetos enlazables disponen de ordinal generacional. Intentar crear un enlace sobre un objeto de pila es rechazado estáticamente por el verificador (Regla R2).
    - **R9**: Los enlaces no pueden sobrevivir al pool que los contiene.

### 3.2 Pilas de datos y reutilización por ámbitos (MAREA Integration)
- **Estructura**: `ScopedArena` implementa asignación por avance lineal de puntero (*bump allocation*) en bloques contiguos de memoria virtual confirmada.
- **Ciclo de vida**:
  - Cada ámbito (`scope`) adquiere un `ScopeMarker` lineal.
  - Las asignaciones avanzan el puntero de asignación en tiempo $O(1)$.
  - Al salir del ámbito, `close_scope(marker)` ejecuta los destructores deterministas en orden inverso a la asignación y restablece el puntero de asignación al marcador inicial.
- **Garantías de seguridad**:
  - Ningún objeto de la arena puede fugarse fuera del `ScopeMarker`.
  - El borrowing checker de ELE asegura que no existen préstamos activos (`view` o `edit`) antes de ejecutar el restablecimiento de la arena.
  - Cero fragmentación interna para objetos temporales y cero syscalls por asignación individual.

### 3.3 Generaciones compactas (16 bits)
- **Diseño**: Para pools de tamaño acotado o vidas efímeras, se define `CompactGen`:
  - Espacio de estados: $0 \le g < 2^{16}$.
  - Generación impar: objeto vivo ($g \in \{1, 3, \dots, 65533\}$).
  - Generación par: slot reciclado / hueco ($g \in \{0, 2, \dots, 65532\}$).
  - Generación retirada: `g_ret = 0xfffe` (65534).
  - Saturación estricta: ante el intento de incrementar más allá de $65533$, el slot transiciona irreversiblemente a `g_ret` y se marca como permanentemente retirado.
- **Propiedad No-ABA**: Debido a que la generación retirada jamás se reutiliza y no hay wraparound aritmético, un enlace antiguo con generación $g_{old}$ jamás coincidirá con un slot reciclado.

### 3.4 Enlaces compactos (4 bytes)
- **Estructura**: `CompactLink` codificado en 32 bits exactos:
  - Bits 0–15 (16 bits): Índice de slot (soporta hasta $65.536$ slots por pool compacto).
  - Bits 16–23 (8 bits): Generación viva compacta ($1..253$), con retiro estricto irreversible en $254$ (`GEN_RETIRADO_8 = 0xfe`).
  - Bits 24–31 (8 bits): Identificador de pool de origen ($0..255$) para aislamiento estricto entre pools.
- **Inmunidad absoluta contra colisiones de hash**: Al retirar el slot definitivamente al alcanzar $254$, las generaciones impares vivas jamás se reutilizan ni sufren wraparound (eliminando colisiones como gen 1 vs gen 257). Un enlace antiguo jamás puede revalidar un objeto posterior.
- **Ámbito de aplicación**: Destinado a grafos de datos densos en memoria donde la sobrecarga de 8 o 12 bytes por enlace limita la densidad de caché. Requiere configuración explícita del pool (`PoolConfig::compact_links = true`).

### 3.5 Destrucción diferida por épocas
- **Separación de fases**:
  1. *Invalidación lógica inmediata*: La generación del slot se invalida inmediatamente en metadatos, garantizando que cualquier llamada concurrente o subsiguiente a `revalidate()` falle con `PoolError::StaleGeneration`.
  2. *Ejecución diferida del destructor*: La liberación de recursos pesados o la llamada a destructores anidados se encola en la cola de diferidos (`DeferredQueue`) y se drena al cruzar el límite del bloque básico o al vaciar el marco.
  3. *Reclamación física*: Descarte de páginas al SO condicionado a subpágina completamente vacía y no retenida por referencias temporales.

### 3.6 Congelación automática (Phased Lifecycle)
- **Fases**:
  - Fase 1: *Construcción* (acceso mutable exclusivo `edit`, no revalidaciones).
  - Fase 2: *Congelación (`Freeze`)*: El pool entra en estado inmutable. Todas las revalidaciones se convierten en comprobaciones $O(1)$ sin contención ni mutación de contadores de época.
  - Fase 3: *Disolución / Destrucción final*: Cierre o reciclaje en bloque.

### 3.7 Optimización de revalidación
- **Hoisting fuera de bucles**: Si un bucle ejecuta lecturas repetidas mediante un `Link` sobre un pool $P$, y el análisis de efectos del cuerpo del bucle demuestra que ningún efecto de mutación (`Destroy`, `Reorder`, `Invalidate`) afecta a $P$, la comprobación `revalidate` se eleva fuera del bucle (*loop-invariant code motion*).
- **Revalidación en lote (*Batch Revalidation*)**: Validación vectorizada de múltiples enlaces pertenecientes al mismo pool amortizando el acceso a la superpágina.

---

## 4. Mapa de correspondencias y preservación de reglas formales

| Regla / Invariante | Descripción | Estado en v0.3 | Conservación en v0.4 |
|---|---|---|---|
| **R1** | Asignación en pool devuelve dueño directo | Implementado | Se preserva para `Linkable`; objetos de arena devuelven `ScopedOwner` |
| **R2** | Solo clases autorizadas se enlazan en pool | Implementado | Se restringe: objetos en `ScopedArena` no admiten `Link` |
| **R3** | Lectura por enlace exige revalidar | Implementado | Se preserva; optimizable por hoisting si no hay efectos invalidantes |
| **R4** | Prohibido almacenar enlace en pool ajeno | Implementado | Se preserva estrictamente |
| **R5** | Préstamo no escapa de su raíz | Implementado | Se preserva para pools y se impone al límite del `ScopeMarker` |
| **R6** | Destrucción diferida no escapa del ámbito | Implementado | Se integra con la cola de épocas de la arena |
| **R7** | Exclusividad de `edit` vs `view` | Implementado | Se preserva íntegramente en el borrow checker |
| **R8** | Destrucción implícita / drop flags | Implementado | Se extiende con limpieza determinista de arenas |
| **R9** | Enlace no sobrevive a su pool | Implementado | Se preserva por invalidación de época y chequeo de ID |
| **C1–C6** | Reglas de concurrencia y particionado | Oráculo v0.2 | Base para la implementación física de `Send` |
| **I1–I10** | Invariantes abstractas de NEXO-Core | Implementadas | Se mantienen como precondiciones del modelo |
| **I11** | Correspondencia abstracto-física | Probada empíricamente | Se preserva mediante arnés diferencial extendido |
