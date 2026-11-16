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

### T5: Frontera de Autoridad, Traits Sellados Auténticos y Vinculación Infalsificable de Pool
- **Separación de conceptos y teoremas**:
  1. **Enlace como dato (`CompactLink`, `CompactLink64`)**: Identificador plano de 32 o 64 bits copiable (`Copy`, `Clone`). Carece por completo de autoridad propietaria o capacidad de desreferenciación directa. Sus métodos `matches()` son predicados puramente representacionales.
  2. **Token lineal de autoridad y vinculación de identidad (`CompactPoolToken`, `CompactPoolToken16`)**: Token no clonable (`!Clone`, `!Copy`) emitible exclusivamente por el registro global de producción (`CompactPoolRegistry::register_pool` y `CompactPoolRegistry16::register_pool`). Quedó totalmente erradicada cualquier función que emita autoridad a partir de un entero (`acquire_token_for` o `acquire_token`). Almacena de forma inmutable tanto el `compact_id` asignado como el `physical_pool_id: u64` correspondiente al `PhysicalPool` registrado. Si un pool físico ya está registrado, re-registrarlo es rechazado atómicamente con `CompactPoolError::AlreadyRegistered`, garantizando biyección $1:1$.
  3. **Trait sellado auténtico (*Authentic Sealed Trait*)**: Los traits `CompactPoolAuthority` y `CompactPoolAuthority64` exigen el supertrait `private::Sealed` (donde `private` es `pub(crate)`) y el método privado sellado `fn __seal_authority(&self, _: private::InternalSeal)`. Crates externas no pueden nombrar el tipo `InternalSeal` ni implementar `Sealed`, garantizando que únicamente adaptadores del núcleo (`CompactPhysicalPool`, `CompactPhysicalPool64`) puedan implementar la interfaz de autoridad (demostrado formalmente mediante pruebas externas de compilación con arnés `run_fixture_check` y doctests `compile_fail`).
  4. **Invariante de no emparejamiento cruzado (*No Cross-Pool Token Pairing*)**: La instanciación de un adaptador autorizado `CompactPhysicalPool::new(&pool, &token)` o `CompactPhysicalPool64::new(&pool, &token)` valida `token.physical_pool_id() == pool.id()`, abortando con `CompactPoolError::PoolMismatch` ante cualquier discrepancia. Un token adquirido para el pool $A$ jamás otorga autoridad de revalidación sobre el pool $B$.
  5. **Invariante de capacidad de slot (*Slot Capacity Clamping*)**: Para enlaces de 32 bits (`CompactLink`), los índices de slot se limitan a 16 bits ($0..65.535$). El adaptador acota estrictamente la capacidad reportada mediante `pool_cap.min((MAX_SLOT_COMPACT_32 as u64) + 1) as u32`, asegurando que no se expongan slots que desborden la codificación del enlace.
  6. **Revalidación autorizada y acotada por préstamo (`CompactObjRef<'a>`, `CompactObjRef64<'a>`)**: Operación ejecutada exclusivamente por el pool físico bajo verificación estricta de:
     - Afinidad de `pool_id` mediante posesión de `CompactPoolToken`.
     - Límites de capacidad (`slot < slot_capacity`).
     - Estado de confirmación de subpágina en memoria virtual (rechaza `Quarantined` con error dedicado `SubpageQuarantined`, y `Reserved`, `ReclaimPending`, `Returned` con `SlotNotAllocated`).
     - Estado de asignación del slot (no libre, no en hueco, impar).
     - Estado no retirado ($\text{gen} < \text{GEN\_RETIRADO}$).
     - Coincidencia exacta de generación viva.
  7. **Token de acceso no propietario acotado (`CompactObjRef<'a>`)**: Representación opaca con campos privados y sin constructor público, ligada formalmente al préstamo `'a` del pool. Mientras exista un token revalidado, el pool no puede ser mutado exclusivamente ni destruido. Jamás es convertible a `Handle` (conservación estricta de las reglas de posesión R2, R3, R6, R7, R8 y R9 de ELE).
  8. **Aislamiento absoluto de mocks de prueba**: `MockCompactPool` y `MockCompactPool64` residen estrictamente dentro de `#[cfg(test)] mod tests` en `compact.rs`. La feature `test-mocks` fue eliminada de `Cargo.toml`. No existen mocks en binarios de producción ni en compilaciones con `--all-features`.
  9. **Desacoplamiento de asignadores numéricos puros**: `CompactIdAllocator8` y `CompactIdAllocator16` encapsulan la emisión atómica de enteros de 8 y 16 bits sin autoridad de memoria, permitiendo probar agotamiento y concurrencia sin contaminar el registro global ni generar carreras entre pruebas concurrentes.

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
| **AUTH-01 (Sealed 32)** | Imposibilidad de implementar trait sellado externo | `test_authority_soundness::test_auth_01` (`run_fixture_check`) + doctest `compile_fail` | DEMOSTRADA / PROBADA |
| **AUTH-02 (Sealed 64)** | Imposibilidad de implementar trait sellado 64 externo | `test_authority_soundness::test_auth_02` (`run_fixture_check`) + doctest `compile_fail` | DEMOSTRADA / PROBADA |
| **AUTH-03 (Encapsulation)** | `CompactObjRef` carece de constructor público | `test_authority_soundness::test_auth_03` (`run_fixture_check`) + doctests `compile_fail` | DEMOSTRADA / PROBADA |
| **AUTH-04 (Mock Eradication)** | Mocks eliminados de la API de producción | `test_authority_soundness::test_auth_04` (`run_fixture_check`) | DEMOSTRADA / PROBADA |
| **AUTH-05 (Token Binding 32)** | Token de pool foráneo rechazado en adaptador 32 | `test_authority_soundness::test_auth_05_cross_pool_token_pairing_fails_32bit` | DEMOSTRADA / PROBADA |
| **AUTH-06 (Token Binding 64)** | Token de pool foráneo rechazado en adaptador 64 | `test_authority_soundness::test_auth_06_cross_pool_token_pairing_fails_64bit` | DEMOSTRADA / PROBADA |
| **AUTH-07 (Pool ID Embed)** | `CompactPoolToken` almacena `physical_pool_id` | `test_authority_soundness::test_auth_07_token_embeds_exact_physical_pool_id` | IMPLEMENTADA / PROBADA |
| **AUTH-08 (Duplicate Reject)** | Registro duplicado del mismo pool rechazado con `AlreadyRegistered` | `test_authority_soundness::test_auth_08_duplicate_pool_registration_rejected` | IMPLEMENTADA / PROBADA |
| **AUTH-09 (Foreign Pool)** | Revalidación rechazada con pool físico foráneo | `test_authority_soundness::test_auth_09_cross_pool_revalidation_fails_with_foreign_pool` | IMPLEMENTADA / PROBADA |
| **AUTH-10 (Even Generation)** | Generación par rechazada como `SlotNotAllocated` | `test_authority_soundness::test_auth_10_even_generation_rejected_as_slot_not_allocated` | IMPLEMENTADA / PROBADA |
| **AUTH-11 (Stale Generation)** | Generación antigua rechazada tras reasignación | `test_authority_soundness::test_auth_11_stale_generation_rejected_after_slot_reuse` | IMPLEMENTADA / PROBADA |
| **AUTH-12 (Retired Gen 8)** | Generación $\ge 254$ rechazada permanentemente con pool real | `test_authority_soundness::test_auth_12_retired_generation_8bit_rejected` | IMPLEMENTADA / PROBADA |
| **AUTH-13 (Retired Gen 16)** | Generación $\ge 65534$ rechazada permanentemente con pool real | `test_authority_soundness::test_auth_13_retired_generation_16bit_rejected` | IMPLEMENTADA / PROBADA |
| **AUTH-14 (Quarantine)** | Subpágina en cuarentena rechazada con `SubpageQuarantined` | `test_authority_soundness::test_auth_14_slot_in_quarantined_subpage_rejected` | IMPLEMENTADA / PROBADA |
| **AUTH-15 (Uncommitted)** | Subpágina no confirmada rechazada incondicionalmente con `SlotNotAllocated` | `test_authority_soundness::test_auth_15_slot_in_returned_or_uncommitted_subpage_rejected` | IMPLEMENTADA / PROBADA |
| **AUTH-16 (Slot Clamping)** | Slot fuera de límites y acotado por 65.536 | `test_authority_soundness::test_auth_16_slot_out_of_bounds_and_capacity_clamped` | IMPLEMENTADA / PROBADA |
| **AUTH-17 (Non-Promotable)** | `CompactObjRef` es de solo lectura y no convertible a `Handle` | `test_authority_soundness::test_auth_17_compact_obj_ref_is_read_only_and_non_promotable` | DEMOSTRADA / PROBADA |
| **AUTH-18 (Lifetime Bound)** | `CompactObjRef<'a>` confinado al préstamo de pool y previene mutaciones | `test_authority_soundness::test_auth_18_compact_obj_ref_lifetime_bound_to_pool_borrow` | DEMOSTRADA / PROBADA |
| **AUTH-19 (Isolated Exhaustion)** | Agotamiento acotado sin reciclaje en instancia aislada | `test_authority_soundness::test_auth_19_compact_pool_registry_bounded_issuance` | IMPLEMENTADA / PROBADA |
| **AUTH-20 (Concurrency)** | Concurrencia atómica de 16 bits sin duplicados en instancia aislada | `test_authority_soundness::test_auth_20_concurrent_issuance_in_registry16_no_duplicates` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-01** | Inexistencia de emisión de autoridad a partir de enteros arbitrarios | `test_authority_lockdown::test_auth_harden_01_no_arbitrary_authority_issuance` (E0599) | DEMOSTRADA / PROBADA |
| **AUTH-HARDEN-02** | Campos privados y rechazo de construcción de tokens externos | `test_authority_lockdown::test_auth_harden_02_tokens_cannot_be_constructed_externally` | DEMOSTRADA / PROBADA |
| **AUTH-HARDEN-03** | Registro duplicado de pool rechazado con `AlreadyRegistered` | `test_authority_lockdown::test_auth_harden_03_duplicate_pool_registration_rejected` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-04** | Emparejamiento cruzado de Token A con Pool B falla con `PoolMismatch` (32b) | `test_authority_lockdown::test_auth_harden_04_cross_pool_pairing_mismatch_32bit` | DEMOSTRADA / PROBADA |
| **AUTH-HARDEN-05** | Emparejamiento cruzado de Token B con Pool A falla con `PoolMismatch` (64b) | `test_authority_lockdown::test_auth_harden_05_cross_pool_pairing_mismatch_64bit` | DEMOSTRADA / PROBADA |
| **AUTH-HARDEN-06** | Pool cerrado falla de forma cerrada ante revalidación y adaptación | `test_authority_lockdown::test_auth_harden_06_closed_pool_fails_closed` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-07** | Recreación de pool tras drop produce nueva ID y rechaza tokens viejos | `test_authority_lockdown::test_auth_harden_07_pool_recreation_has_distinct_id` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-08** | Enlace de pool previo rechazado con `ForeignPool` frente a pool nuevo | `test_authority_lockdown::test_auth_harden_08_link_from_previous_pool_rejected_as_foreign` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-09** | Enlace con generación stale rechazado con `StaleGeneration` tras reasignar | `test_authority_lockdown::test_auth_harden_09_stale_generation_rejected` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-10** | Enlace con generación retirada permanentemente rechazado (`GenerationRetired`) | `test_authority_lockdown::test_auth_harden_10_retired_generation_permanently_rejected` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-11** | Subpágina en cuarentena rechazada con error dedicado `SubpageQuarantined` | `test_authority_lockdown::test_auth_harden_11_quarantined_subpage_rejected_with_specific_error` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-12** | Slot en estado de hueco lineal (HoleToken) rechazado como `SlotNotAllocated` | `test_authority_lockdown::test_auth_harden_12_hole_slot_rejected_as_slot_not_allocated` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-13** | Slot no confirmado rechazado incondicionalmente con `SlotNotAllocated` | `test_authority_lockdown::test_auth_harden_13_uncommitted_slot_unconditionally_rejected` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-14** | Fallo de registro atómico preserva contador y estado sin tokens parciales | `test_authority_lockdown::test_auth_harden_14_atomic_registration_failure_preserves_state` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-15** | Agotamiento de instancia aislada no contamina ni agota el singleton global | `test_authority_lockdown::test_auth_harden_15_isolated_exhaustion_does_not_contaminate_global` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-16** | Emisión concurrente multi-hilo en `CompactIdAllocator16` sin colisiones | `test_authority_lockdown::test_auth_harden_16_concurrent_allocator16_emission_no_duplicates` | IMPLEMENTADA / PROBADA |
| **AUTH-HARDEN-17** | Intento de implementar traits sellados rechazado externamente por compilador | `test_authority_lockdown::test_auth_harden_17_sealed_trait_compile_fail` (E0277) | DEMOSTRADA / PROBADA |
| **AUTH-HARDEN-18** | Mocks de prueba completamente inaccesibles en binarios de producción | `test_authority_lockdown::test_auth_harden_18_mock_pools_inaccessible_in_production` (E0433) | DEMOSTRADA / PROBADA |
| **AUTH-HARDEN-19** | Lifetime de `CompactObjRef` atado a préstamo de pool impidiendo escape | `test_authority_lockdown::test_auth_harden_19_compact_objref_bounded_to_pool_borrow` (E0515) | DEMOSTRADA / PROBADA |
| **AUTH-HARDEN-20** | Borrow checker impide mutación del pool físico mientras exista préstamo activo | `test_authority_lockdown::test_auth_harden_20_borrow_checker_prevents_mutation_during_objref` (E0502) | DEMOSTRADA / PROBADA |
