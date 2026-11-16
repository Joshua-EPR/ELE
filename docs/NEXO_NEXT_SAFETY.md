# NEXO v0.4: Demostraciones y Obligaciones de Seguridad (Safety Obligations)

**Estado:** Documento de análisis formal de seguridad para NEXO v0.4.  
**Rama:** `feat/nexo-v0.4-next-memory`  
**Fecha:** 2026-11-15  

---

## 1. Obligaciones formales maestras

Para cada extensión incorporada en NEXO v0.4 se definen teoremas y obligaciones de seguridad auditables:

### T1: Ausencia de Use-After-Free (UAF)
$$\forall l \in \text{Link}, \forall t_1 < t_2 : \text{destroy}(h, t_1) \implies \text{revalidate}(l, t_2) = \text{Err}(\text{StaleGeneration})$$
- **Demostración en `PhysicalPool`**:
  1. En Fase B de `destroy`, la generación en metadatos $g$ se sustituye por $g' = g + 1$ (siendo $g'$ par, destruido).
  2. Para cualquier llamada subsiguiente a `revalidate(l)` en $t_2$, la comprobación compara $l.\text{generation}$ con $\text{meta.generations}[s]$.
  3. Como $l.\text{generation} = g$ (impar) y $\text{meta.generations}[s] \ge g'$ (par o posterior impar), $l.\text{generation} \neq \text{meta.generations}[s]$.
  4. Por tanto, la revalidación falla antes de calcular cualquier dirección física o emitir lecturas de memoria.

### T2: Ausencia de Double-Free
$$\forall h_1, h_2 \in \text{Handle} : h_1 = h_2 \implies \text{False (no duplicación)}$$
- **Demostración**:
  1. El tipo `Handle` no implementa `Clone` ni `Copy`.
  2. Sus campos internos son privados (`pool`, `slot`, `generation`) y carece de constructor público.
  3. `destroy(h)` toma posesión por valor de `h`.
  4. Por las reglas de ownership lineal de Rust y el verificador estático de ELE, un valor consumido no puede volver a invocarse (verificado por prueba de compilación negativa `compile_fail,E0382`).

### T3: No-ABA y Ausencia de Colisiones en Generaciones Compactas (16 bits y 8 bits)
- **Hipótesis**: Un slot se asigna y libera reiteradamente.
- **Riesgo**: Que tras ciclos repetidos la generación vuelva a $g_0$ o colisione en una codificación truncada (p. ej. Gen 1 vs Gen 257 en 8 bits).
- **Solución implementada**:
  1. En 16 bits (`CompactGen`), la generación inicia en $1$ y avanza $g \leftarrow g + 2$. Al alcanzar $65533$, el siguiente ciclo de destrucción marca el slot como `GEN_RETIRADO_16 = 0xfffe`.
  2. En 8 bits (`CompactLink`), la generación compacta inicia en $1$, avanza de 2 en 2, y al alcanzar $253$, la destrucción transiciona definitivamente a `GEN_RETIRADO_8 = 254` (`0xfe`).
  3. Todo intento de asignar o revalidar con generación $\ge 254$ es rechazado (`CompactGenError::Retired`, `CompactLinkError::GenerationRetired`).
  4. La generación 257 jamás puede ser alcanzada ni creada para ese slot, eliminando de forma absoluta cualquier colisión de hash módulo 256.
  5. `CompactLink::matches()` comprueba tanto la coincidencia estricta de `pool_id`, la no paridad (`is_live`, impar), el límite de retiro, y la igualdad exacta.

### T4: Seguridad de Ámbitos, Arenas (`ScopedArena`), Lifetimes y Aislamiento de Hilos
- **Teorema**: Ningún préstamo o puntero derivado de `ScopedArena` puede sobrevivir a `close_scope(marker)`, ni transferirse incorrectamente entre arenas o hilos, ni retener referencias efímeras en destructores.
- **Demostración**:
  1. `ScopedArena::begin_scope()` genera un `ScopeMarker` lineal que contiene tanto el identificador atómico único de arena (`arena_id`) como el nivel de ámbito activo (`scope_id`).
  2. `alloc()` restringe el tipo a `T: 'static`, impidiendo formalmente en safe Rust que se almacenen objetos con referencias de vida más corta que la arena que luego puedan ser accedidas tras expirar por sus destructores.
  3. `alloc()` y `close_scope()` validan estrictamente la coincidencia de `arena_id` y `scope_id`. Cualquier marcador foráneo o de orden incorrecto es rechazado inmediatamente con `CloseScopeError`, devolviendo el `ScopeMarker` intacto al llamador para permitir recuperación y cierre ordenado sin clonación.
  4. Pre-reserva estricta: `alloc()` ejecuta `drops.try_reserve(1)` antes de escribir el valor, previniendo objetos vivos no registrados en caso de OOM.
  5. Resiliencia ante pánicos y envenenamiento (`ArenaState::Poisoned`): Si un destructor entra en pánico durante `close_scope`, `ScopeCloseGuard` marca la arena como `Poisoned`. El `offset` NO se retrocede al inicio del ámbito, blindando la memoria de los objetos no destruidos contra sobreescrituras en caso de captura de pánico (`catch_unwind`). La entrada que causó pánico fue retirada previamente de `drops`, garantizando cero dobles destrucciones. Toda operación subsiguiente (`alloc`, `begin_scope`, `close_scope`) sobre la arena envenenada es rechazada con `ArenaError::Poisoned`.
  6. Protocolo de Destrucción Final Resiliente (`Drop for ScopedArena`): Al ejecutarse `drop(arena)`, se drenan y ejecutan todos los destructores pendientes en orden LIFO estricto. Cada destructor se ejecuta encapsulado en `std::panic::catch_unwind`. Si uno o varios destructores fallan con pánico, los restantes continúan ejecutándose hasta vaciar completamente `drops`, asegurando que ningún objeto sufra omisión de su destructor ni retención indebida de recursos externos (ficheros, memoria heap, sockets). Una vez drenados todos los objetos, `BufferGuard` desasigna la memoria virtual. Si ocurrieron pánicos y el hilo no se encontraba previamente en unwinding (`!std::thread::panicking()`), se reanuda el primer pánico registrado mediante `std::panic::resume_unwind`, cumpliendo con la propagación transparente del error y evitando simultáneamente abortos fatales por doble pánico (*double panic abort*).
  7. `close_scope` consume el `ScopeMarker` por valor.
  8. Si existiese cualquier préstamo activo de la arena, el borrow checker rechaza la llamada a `close_scope` por solapamiento de préstamos vivos.
  9. `ScopedArena` no implementa `Send` ni `Sync` (retiene punteros crudos `NonNull<u8>`), impidiendo formalmente que tipos no aptos para concurrencia (como `Rc`) sean transferidos entre hilos a través de la arena.
  10. La arena garantiza alineación base de 128 bytes (o configurable como potencia de dos) y soporta alineaciones arbitrarias de tipos (probado hasta 4096 bytes) sin desbordamiento aritmético gracias a `align_offset` y comprobaciones `checked_add`. Tipos de tamaño cero (ZST) no consumen capacidad de memoria y ejecutan sus destructores deterministamente.
  11. `begin_scope()` retorna `Result<ScopeMarker, ArenaError>` y previene desbordamiento del contador de ámbitos con `checked_add(1)` retornando `ArenaError::ScopeDepthExhausted`.

### T5: Frontera de Autoridad y Revalidación de Enlaces Compactos
- **Separación de conceptos**:
  1. **Enlace como dato (`CompactLink`, `CompactLink64`)**: Identificador plano de 32 o 64 bits copiable (`Copy`, `Clone`). Carece por completo de autoridad propietaria o capacidad de desreferenciación directa. Sus métodos `matches()` son predicados puramente representacionales.
  2. **Token lineal de autoridad única (`CompactPoolToken`, `CompactPoolToken16`)**: Token no clonable (`!Clone`, `!Copy`) emitible exclusivamente por el registro global de producción (`CompactPoolRegistry::acquire_token`). Garantiza unicidad global absoluta dentro del espacio de direcciones y ausencia de colisiones por instancias independientes.
  3. **Trait sellado (`CompactPoolAuthority: private::Sealed`, `CompactPoolAuthority64: private::Sealed`)**: Solo implementaciones verificadas y auditadas del runtime (`CompactPhysicalPool`, `CompactPhysicalPool64`) pueden implementar el contrato de autoridad. Se rechaza estáticamente cualquier intento de consumidores externos de fabricar autoridades ficticias.
  4. **Revalidación autorizada y acotada por préstamo (`CompactObjRef<'a>`, `CompactObjRef64<'a>`)**: Operación ejecutada exclusivamente por el pool físico bajo verificación estricta de:
     - Afinidad de `pool_id` mediante posesión de `CompactPoolToken`.
     - Límites de capacidad (`slot < slot_capacity`).
     - Estado de confirmación de subpágina en memoria virtual (rechaza `Quarantined`, `Reserved`, `ReclaimPending`, `Returned`).
     - Estado de asignación del slot (no libre, no en hueco, impar).
     - Estado no retirado ($\text{gen} < \text{GEN\_RETIRADO}$).
     - Coincidencia exacta de generación viva.
  5. **Token de acceso no propietario acotado (`CompactObjRef<'a>`)**: Representación opaca con campos privados y sin constructor público, ligada formalmente al préstamo `'a` del pool. Mientras exista un token revalidado, el pool no puede ser mutado exclusivamente ni destruido. Jamás es convertible a `Handle` (conservación estricta de las reglas de posesión R2, R3, R6, R7, R8 y R9 de ELE).

### T6: Resiliencia Exhaustiva de Destrucción y Ausencia de Corrupción ante Pánicos en `ScopedArena`
- **Garantías de DROP-01 a DROP-16**:
  1. **Drenaje LIFO Total**: Si un destructor entra en pánico durante el cierre de la arena o `drop(arena)`, todos los destructores restantes se ejecutan incondicionalmente en estricto orden inverso.
  2. **Prevención de Aborto por Doble Pánico**: Al desenrollar durante un pánico preexistente del hilo, la arena detecta `std::thread::panicking()` y suprime el relanzamiento secundario, evitando abortos del proceso (*double panic abort*).
  3. **Preservación de Memoria Virtual**: `BufferGuard` garantiza que el bloque virtual se libera únicamente tras finalizar todos los destructores.
  4. **Tipos de Tamaño Cero (ZST)**: Destrucción determinista sin avance de offset ni desalineación.
  5. **Ámbitos Anidados Envenenados**: Un pánico en un ámbito interior envenena la arena pero preserva la destrucción LIFO de los objetos del ámbito exterior en `drop(arena)`.

---

## 2. Matriz de verificación empírica y formal

Clasificación de estados:
- **ESPECIFICADA**: Formalizada matemáticamente o en especificación normativa.
- **IMPLEMENTADA**: Codificada en Rust en las crates del workspace.
- **PROBADA**: Validada mediante arnés de pruebas automatizado con evidencia reproducible.
- **DEMOSTRADA**: Deducción lógica o prueba por tipos en safe Rust.
- **PENDIENTE / BLOQUEADA**: Requiere infraestructura externa o desarrollo en etapas futuras.

| Propiedad | Mecanismo de control | Prueba automatizada | Clasificación |
|---|---|---|---|
| **No-UAF** | Generación impar/par y descarte físico | `adversarial_atomicity::a08`, `physical::f07` | IMPLEMENTADA / PROBADA |
| **No-Double-Free** | Linearidad de `Handle` | `pool.rs` compile_fail doctests, `api_security.rs` | DEMOSTRADA / PROBADA |
| **No-ABA (32-bit)** | Retirada en $2^{32}-2$ | `bislab::agotamiento_de_generacion_sin_wraparound` | IMPLEMENTADA / PROBADA |
| **No-ABA (16-bit)** | Retirada en $2^{16}-2$ | `test_compact_nexo::test_compact_gen_exhaustion_and_no_aba`, `test_compact_gen_16bit_boundary_correctness` | IMPLEMENTADA / PROBADA |
| **No-ABA (8-bit)** | Retirada en 254 (`GEN_RETIRADO_8`) | `test_compact_nexo::test_exhaustive_8bit_domain_and_invariants` | IMPLEMENTADA / PROBADA |
| **Compact Registry 8-bit** | Límite estricto 255 IDs sin reciclaje ni colisiones concurrentes | `test_compact_nexo::test_compact_pool_registry_bounded_issuance`, `test_compact_pool_registry_concurrent_issuance_no_duplicates` | IMPLEMENTADA / PROBADA |
| **Compact Registry 16-bit** | Límite estricto 65.535 IDs sin reciclaje | `test_compact_nexo::test_compact_pool_registry_16_bounded_issuance` | IMPLEMENTADA / PROBADA |
| **Tokens Unforgeable** | `CompactPoolToken` lineal privado | `test_compact_nexo::test_compact_pool_token_unforgeability_and_monotonicity` | DEMOSTRADA / PROBADA |
| **Compact Authority Sealed** | Trait sellado y revalidación en `PhysicalPool` | `test_compact_nexo::test_compact_link_authorized_revalidation_boundary`, `test_compact_physical_pool_adapter_integration` | DEMOSTRADA / PROBADA |
| **64-bit Compact Authority**| Trait sellado de 8 bytes y revalidación | `test_compact_nexo::test_compact_pool_64_revalidation_and_adapter` | IMPLEMENTADA / PROBADA |
| **Aislamiento Scope** | Marcador lineal de ámbito | `test_scoped_arena::test_nested_scopes_and_lifo_destruction` | DEMOSTRADA / PROBADA |
| **Panic Resilience** | Envenenamiento y guard LIFO | `test_scoped_arena::test_p0_arena_01_three_objects_middle_panics_in_drop` | IMPLEMENTADA / PROBADA |
| **No Memory Overwrite** | Bloqueo de asignación envenenada | `test_scoped_arena::test_p0_arena_02_allocation_after_panic_is_rejected_no_overwrite` | IMPLEMENTADA / PROBADA |
| **DROP-01 (Single Panic)** | Drenado total LIFO ante pánico individual | `test_scoped_arena::test_drop_01_single_panic_with_three_pending_destructors` | IMPLEMENTADA / PROBADA |
| **DROP-02 (Multi-Panic)** | Drenado total LIFO ante múltiples pánicos | `test_scoped_arena::test_drop_02_multiple_panics_during_arena_drop` | IMPLEMENTADA / PROBADA |
| **DROP-03 (Poisoned Drop)**| Liberación de arena envenenada | `test_scoped_arena::test_drop_03_poisoned_arena_final_drop` | IMPLEMENTADA / PROBADA |
| **DROP-04 (Payload)** | Reanudación fiel de carga útil de pánico | `test_scoped_arena::test_drop_04_panic_propagation_payload` | IMPLEMENTADA / PROBADA |
| **DROP-05 (No Abort)** | Intercepción segura durante unwinding activo | `test_scoped_arena::test_drop_05_no_double_panic_abort_during_unwinding` | IMPLEMENTADA / PROBADA |
| **DROP-06 (Complex Heap)** | Liberación de buffers complejos de heap | `test_scoped_arena::test_drop_06_complex_heap_resources_cleaned_on_panic`, `test_p0_arena_06_complex_heap_owners_freed_cleanly` | IMPLEMENTADA / PROBADA |
| **DROP-07 (Nested Cascade)**| Limpieza en cascada en ámbitos anidados | `test_scoped_arena::test_drop_07_nested_scopes_cascade_cleanup`, `test_p0_arena_04_nested_scopes_with_inner_panic` | IMPLEMENTADA / PROBADA |
| **DROP-08 (Partial Panic)**| Destructor con pánico tras liberación parcial | `test_scoped_arena::test_drop_08_partial_release_and_panic` | IMPLEMENTADA / PROBADA |
| **DROP-09 (State Mutation)**| Mutación externa persistente antes de fallo | `test_scoped_arena::test_drop_09_external_state_mutation_before_panic` | IMPLEMENTADA / PROBADA |
| **DROP-10 (Thread Unwind)**| Múltiples fallos durante unwinding de hilo | `test_scoped_arena::test_drop_10_multiple_failures_during_thread_unwinding` | IMPLEMENTADA / PROBADA |
| **DROP-11 (ZST Panic)** | Destructor de ZST que entra en pánico | `test_scoped_arena::test_drop_11_zero_sized_type_destructor_panic`, `test_p0_arena_05_zst_drop_interleaved_and_panic` | IMPLEMENTADA / PROBADA |
| **DROP-12 (Inner Poison)** | Ámbito interior envenenado con pendientes | `test_scoped_arena::test_drop_12_inner_scope_poisoned_with_outer_pending` | IMPLEMENTADA / PROBADA |
| **DROP-13 (Strict LIFO)** | Dependencias estrictas de orden LIFO | `test_scoped_arena::test_drop_13_strict_dependency_lifo_order` | IMPLEMENTADA / PROBADA |
| **DROP-14 (Mismatch Drop)**| Desajuste de marcador seguido de drop final | `test_scoped_arena::test_drop_14_close_scope_mismatch_then_final_drop` | IMPLEMENTADA / PROBADA |
| **DROP-15 (Miri Pureness)**| Layout de memoria pura heap sin syscalls | `test_scoped_arena::test_drop_15_miri_layout_and_zero_leak_verification` | ESPECIFICADA / PENDIENTE MIRI |
| **DROP-16 (Process Guard)**| Contención de pánicos en hilo aislado | `test_scoped_arena::test_drop_16_isolated_child_panic_resilience` | IMPLEMENTADA / PROBADA |
| **Scope Overflow** | `checked_add` y `ScopeDepthExhausted` | `test_scoped_arena::test_p0_arena_07_deep_scope_nesting_and_depth_invariants` | DEMOSTRADA / PROBADA |
| **Arena ID Exhaustion** | Detección exacta de `ArenaIdExhausted` | `next::arena::tests::test_arena_id_exhausted_boundary` | DEMOSTRADA / PROBADA |
| **Alineación 4096** | Padding seguro y potencia de dos | `test_scoped_arena::test_p0_arena_08_extreme_alignment_up_to_4096` | IMPLEMENTADA / PROBADA |
| **PFS Reconcile** | Cuarentena y reparación | PFS01–PFS12, `nexo-physical-fuzz` | IMPLEMENTADA / PROBADA |
| **Child Isolation** | Protección de página de SO en proceso hijo | `child_isolation::p03_*` (SIGSEGV verificado) | IMPLEMENTADA / PROBADA |
