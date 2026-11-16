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
  5. Si un destructor entra en pánico durante `close_scope`, un guard de limpieza (`CleanupGuard`) restaura el offset y nivel de ámbito de forma infalible, previniendo dobles destrucciones de objetos ya procesados.
  6. `close_scope` consume el `ScopeMarker` por valor.
  7. Si existiese cualquier préstamo activo de la arena, el borrow checker rechaza la llamada a `close_scope` por solapamiento de préstamos vivos.
  8. `ScopedArena` no implementa `Send` ni `Sync` (retiene punteros crudos `NonNull<u8>`), impidiendo formalmente que tipos no aptos para concurrencia (como `Rc`) sean transferidos entre hilos a través de la arena.
  9. La arena garantiza alineación base de 128 bytes (o configurable como potencia de dos) y soporta alineaciones arbitrarias de tipos (hasta 4096 bytes) sin desbordamiento aritmético gracias a `align_offset` y comprobaciones `checked_add`. Tipos de tamaño cero (ZST) no consumen capacidad de memoria y ejecutan sus destructores deterministamente.

---

## 2. Matriz de verificación empírica

| Propiedad | Mecanismo de control | Prueba automatizada | Estado |
|---|---|---|---|
| **No-UAF** | Generación impar/par y descarte físico | `adversarial_atomicity::a08`, `physical::f07` | Verificada |
| **No-Double-Free** | Linearidad de `Handle` | `pool.rs` compile_fail doctests, `api_security.rs` | Verificada |
| **No-ABA (32-bit)** | Retirada en $2^{32}-2$ | `bislab::agotamiento_de_generacion_sin_wraparound` | Verificada |
| **No-ABA (16-bit)** | Retirada en $2^{16}-2$ | `test_compact_nexo::test_exhaustion_no_aba_16bit` | Verificada |
| **Aislamiento Scope** | Marcador lineal de ámbito | `test_scoped_arena::test_scope_cleanup_and_reset` | Verificada |
| **PFS Reconcile** | Cuarentena y reparación | PFS01–PFS12, `nexo-physical-fuzz` | Verificada |
