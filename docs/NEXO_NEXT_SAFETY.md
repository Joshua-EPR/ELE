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

### T3: No-ABA en Generaciones Compactas (16 bits)
- **Hipótesis**: Un slot se asigna y libera reiteradamente.
- **Riesgo**: Que tras $2^{16}$ ciclos la generación vuelva a $g_0$ y valide un enlace antiguo.
- **Solución implementada**:
  1. La generación inicia en $1$ y avanza $g \leftarrow g + 2$ en cada asignación.
  2. Al alcanzar el umbral de seguridad $g_{\text{max}} = 65533$, el siguiente ciclo de destrucción marca el slot como `GEN_RETIRADO_16 = 0xfffe`.
  3. Todo slot en estado retirado queda permanentemente excluido de las listas y bitmaps de asignación.
  4. La función `allocate()` rechaza slots retirados.
  5. Ningún enlace antiguo puede volver a colisionar con una generación reutilizada.

### T4: Seguridad de Ámbitos y Arenas (`ScopedArena`)
- **Teorema**: Ningún préstamo o puntero derivado de `ScopedArena` puede sobrevivir a `close_scope(marker)`.
- **Demostración**:
  1. `ScopedArena::begin_scope()` genera un `ScopeMarker` lineal que contiene un contador de generación de ámbito.
  2. Las referencias emitidas dentro del ámbito portan una ligadura de tiempo de vida estática $\alpha$ subordinada al marcador.
  3. `close_scope` consume el `ScopeMarker` por valor.
  4. Si existiese cualquier préstamo activo de la arena, el borrow checker rechaza la llamada a `close_scope` por solapamiento de préstamos vivos.
  5. Una vez ejecutada `close_scope`, la memoria queda invalidada para los objetos anteriores y el puntero de asignación se restablece de forma segura.

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
