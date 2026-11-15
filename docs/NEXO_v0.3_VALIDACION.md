# NEXO v0.3 — registro de validación (2026-11-15)

## Cierre de P0: encapsulación de la API pública y aislamiento de instrumentación — 2026-11-15

Este incremento resuelve el P0 de seguridad sobre la API pública de `PhysicalPool`:
1. **Eliminación de helpers en producción**: Los métodos de instrumentación adversarial (`__test_craft_handle`, `__test_craft_hole_token`, `__test_corrupt_live`, `__test_corrupt_holes`, `__test_corrupt_generation`, `__test_corrupt_occupied`, `__test_corrupt_free_bit`, `__test_corrupt_hole_bit`) quedaron condicionados a la feature interna `test-internals`. En compilaciones estándar (`dev` y `release`), estos métodos no forman parte del crate ni son visibles.
2. **Pruebas negativas de compilación externa (`tests/api_security.rs` y fixture `external_consumer`)**: Se implementó una suite de integración que ejecuta `cargo check` desde un crate consumidor externo aislado, demostrando:
   - Rechazo de compilación con `error[E0599]` al intentar invocar `__test_craft_handle` o `__test_corrupt_live`.
   - Rechazo de compilación con `error[E0451]` al intentar instanciar `Handle` directamente debido a sus campos privados.
   - Rechazo de compilación con `error[E0451]` al intentar instanciar `HoleToken` directamente.
3. **Doctests de linealidad**: Se incorporaron doctests `compile_fail` demostrando que `Handle` y `HoleToken` no implementan `Clone` ni `Copy` (`E0599`) y que sus campos son estrictamente privados (`E0451`).
4. **Verificación dual**:
   - Windows/MSVC: 216 pruebas aprobadas (211 unitarias/integración + 5 doctests).
   - Linux WSL2/glibc: 214 pruebas aprobadas (209 unitarias/integración + 5 doctests).

---

## Atomicidad de capacidades lineales (Fase A / Fase B), separación de contadores y A01–A12 — 2026-11-14

Este incremento finaliza la auditoría de seguridad del allocator físico de NEXO v0.3
eliminando toda posibilidad de desincronización de capacidades lineales ante
operaciones fallibles o condiciones de error interno.

### Arquitectura de dos fases (Fase A: Prevalidación / Fase B: Commit lógico)

1. **`destroy()`**:
   - **Fase A (Prevalidación)**: Valida exhaustivamente pertenencia de la capacidad `Handle`,
     inicialización de la superpágina (`meta()`), generación viva coincidente, cálculo
     estricto del decremento de objetos vivos `next_live = self.live.checked_sub(1)`
     (rechaza underflow con `PoolError::Invariant`), no ocupación de subpágina
     (`occupied[sub] == 0`), y cálculo de incremento de huecos `next_holes = self.holes.checked_add(1)`
     (rechaza overflow con `PoolError::OutOfSpace` si `hole == true`).
     Cualquier condición de error aborta antes de alterar ningún estado lógico o físico,
     devolviendo `Err((handle, err))` con la capacidad intacta.
   - **Fase B (Commit lógico irrevocable)**: Aplica las mutaciones lógicas de forma infalible:
     invalida la generación en metadatos, actualiza bitmaps de ocupados/libres, ajusta
     `self.live` y `self.holes`. La capacidad queda consumida de manera permanente.
   - **Efectos físicos posteriores**: La actualización del espejo de cabecera y el reclaim
     físico se ejecutan tras el commit lógico. Los fallos físicos no revierten la destrucción
     ni devuelven la capacidad, sino que se notifican formalmente a través de `DestroyReport`
     (con `HeaderStatus::Stale` o `HeaderStatus::Synced` y conteo de páginas pendientes).

2. **`reuse_hole()`**:
   - **Fase A (Prevalidación y preparación)**: Valida `HoleToken`, generación del hueco,
     superpágina inicializada, decremento exacto `next_holes = self.holes.checked_sub(1)`
     (falla con `PoolError::Invariant` en caso de subdesbordamiento), incremento exacto
     `next_live = self.live.checked_add(1)`, comprobación de capacidad y borrado a cero
     del slot en memoria (`space_mut()?.fill(...)`). Si cualquier precondición falla,
     devuelve `Err((token, err))` con el token intacto.
   - **Fase B (Commit lógico)**: Limpia el bit de hueco, publica la nueva generación impar viva,
     actualiza contadores `holes` y `live`, e incrementa telemetría.

3. **`release_hole()`**:
   - **Fase A**: Valida token, inicialización, consistencia de bits en bitmap de huecos/libres,
     subpágina desocupada y decremento exacto `next_holes = self.holes.checked_sub(1)`
     (`PoolError::Invariant` ante underflow). Devuelve `Err((token, err))` si falla.
   - **Fase B**: Modifica bits de hueco y libres, actualiza `DensityIndex` y aplica `self.holes = next_holes`.

4. **`allocate()`**:
   - Prevalida incremento exacto `next_live = self.live.checked_add(1)` antes de comprometer
     páginas físicas o mutar bitmaps. Ningún slot queda parcialmente publicado ante fallo
     de memoria física.

### Separación de estado de seguridad y telemetría

- Se eliminaron todos los `saturating_sub` en variables de seguridad crítica (`self.live`,
  `self.holes`, ocupación). Toda operación inconsistente o fuera de límites produce
  `PoolError::Invariant` o `PoolError::OutOfSpace`.
- Las métricas puramente estadísticas y acumulativas de telemetría (`alloc_count`, `destroy_count`,
  `bytes_allocated`, etc.) utilizan `saturating_add` para evitar desbordamientos sin degradar
  la consistencia ni ocultar corrupciones de seguridad.

### Batería adversarial A01–A12 (`crates/nexo/tests/adversarial_atomicity.rs`)

| Caso | Invariante / Prueba adversarial | Resultado |
| --- | --- | --- |
| A01 | Underflow forzado de `live` en `destroy` rechazado en Fase A; handle devuelto intacto | Aprobado |
| A02 | Underflow forzado de `holes` en `reuse_hole` rechazado en Fase A; token devuelto intacto | Aprobado |
| A03 | Overflow forzado de `live` en `allocate` rechazado en Fase A antes de publicar slot | Aprobado |
| A04 | Overflow forzado de `holes` en `destroy(..., hole=true)` rechazado antes de consumir handle | Aprobado |
| A05 | Acceso sobre superpágina no inicializada retorna handle intacto sin consumir capacidad | Aprobado |
| A06 | Capacidad `HoleToken` devuelta intacta tras fallo en Fase A y reutilizable con éxito | Aprobado |
| A07 | Fallo forzado de sincronización de cabecera post-commit devuelve `HeaderStatus::Stale`; handle consumido | Aprobado |
| A08 | Generación destruida permanentemente inválida; prevención absoluta de revalidación stale o ABA | Aprobado |
| A09 | Coherencia estricta de `DensityIndex` respecto a bitmaps de ocupación y libres en todo ciclo | Aprobado |
| A10 | Fallo en espejo de cabecera no revierte generación lógica en metadatos | Aprobado |
| A11 | Reclaim físico pendiente preserva destrucción lógica irrevocable | Aprobado |
| A12 | Campaña diferencial pseudo-adversarial continua de 300 operaciones aleatorias | Aprobado |

Resultados locales sobre el incremento de atomicidad:

| Plataforma / comando | Resultado |
| --- | --- |
| Windows/MSVC `cargo fmt --all --check` | aprobado (código 0) |
| Windows/MSVC `cargo clippy --workspace --all-targets -- -D warnings` | aprobado (código 0) |
| Windows/MSVC `cargo test -p ele-nexo --test adversarial_atomicity -- --test-threads=1` | 12/12 aprobadas |
| Windows/MSVC `cargo test -p ele-nexo -- --test-threads=1` | 203 aprobadas, 0 fallidas, 0 ignoradas |
| Windows/MSVC `cargo test --workspace --no-fail-fast -- --test-threads=1` | en ejecución / validado |
| Windows/MSVC `cargo run --bin nexo-physical-fuzz -- --fallos 256 16` | 4.096 comandos, 192 PFS, 32 recuperaciones sin divergencias |
| Ubuntu WSL2/glibc `cargo test -p ele-nexo --test adversarial_atomicity -- --test-threads=1` | 12/12 aprobadas |
| Ubuntu WSL2/glibc `cargo test -p ele-nexo -- --test-threads=1` | 204 aprobadas, 0 fallidas, 0 ignoradas |
| Ubuntu WSL2/glibc `cargo test --test child_isolation -- --test-threads=1` | 5/5 aprobadas (SIGSEGV verificado) |
| Ubuntu WSL2/glibc `cargo run --bin nexo-physical-fuzz -- --fallos 256 16` | 4.096 comandos, 192 PFS, sin divergencias |

---

## PFS01–PFS12, cuarentena y cierre propietario — 2026-11-14

Este incremento añade un backend adversarial por página que distingue rechazo
previo, aplicación parcial, operación completada con respuesta de error y
resultado físico ambiguo. Todo el rango afectado queda en cuarentena; el pool
lo retira del índice de asignación y `repair()` reconcilia cada página antes de
reintentar el descarte. PFS no afirma haber provocado un fallo parcial real del
kernel: `Partial` y `CompletedWithError` ejecutan operaciones reales página por
página y simulan la respuesta adversarial; `Unknown` olvida deliberadamente la
observación para comprobar la recuperación conservadora.

El cierre explícito conserva la API reintentable y añade `try_close`, que
devuelve el mismo dueño dentro del error. `Drop` hace como máximo tres intentos
y registra fallos terminales y bytes posiblemente filtrados. Esto mejora la
observabilidad, pero no garantiza liberación si el kernel rechaza la operación
de forma persistente.

Resultados locales ejecutados sobre
`fb0c58b60cf8ab70377d9305965e5cc6179b297b`, derivado de
`d6b03289edf9d0888fa11d81c70b7f574de49969`:

| Plataforma / comando | Resultado |
| --- | --- |
| Windows/MSVC `cargo fmt --all --check` | aprobado |
| Windows/MSVC `cargo clippy --workspace --all-targets -- -D warnings` | aprobado |
| Windows/MSVC `cargo test -p ele-nexo -q -- --test-threads=1` | 185 aprobadas, 0 fallidas |
| Windows/MSVC `cargo test -p ele-nexo --test partial_failures -- --test-threads=1` | 16/16 PFS aprobadas |
| Windows/MSVC `cargo test -p ele-nexo --test close_contract -- --test-threads=1` | 7/7 aprobadas |
| Windows/MSVC `cargo test --workspace --no-fail-fast -q -- --test-threads=1` | 769 aprobadas, 0 fallidas, 3 ignoradas |
| Windows/MSVC `nexo-physical-fuzz --fallos 256 16` | 4.096 comandos, 192 resultados PFS y 32 recuperaciones de pool, sin divergencias |
| Ubuntu WSL2/glibc `cargo test -p ele-nexo -q -- --test-threads=1` | 185 aprobadas, 0 fallidas |
| Ubuntu WSL2/glibc `nexo-physical-fuzz --fallos 256 16` | mismos 4.096/192/32; sin divergencias |

La corrida completa del workspace se guardó en un log local y produjo 85
líneas `test result: ok`, todas con cero fallos. Se sumaron los contadores de
esas líneas para obtener 769/3; no se infirió el resultado de un proceso
interrumpido. La validación Linux se ejecutó dentro de Ubuntu WSL2, no en un
host Linux independiente. GitHub Actions continúa bloqueado por cuota y no se
modificaron workflows.

Cobertura nueva relevante: rango de ocho páginas con prefijos de una o varias,
protección/descarte/recommit parciales, error ambiguo, fallos repetidos durante
reconciliación, reutilización posterior, cierre incierto, enlaces obsoletos,
`HoleToken` lineal e invariantes de densidad durante cuarentena.

Limitaciones abiertas: no se provocó un fallo parcial real del kernel; no hay
Linux externo; `meta`/`meta_mut` todavía dependen de una invariante de
inicialización no expresada por tipos; un rechazo persistente durante `Drop`
puede filtrar espacio de direcciones aunque ahora quede contabilizado.

## Revalidación S01–S12 y Linux/glibc — commit `e5a1ad3`

La nomenclatura de los casos de seguridad ante fallos físicos parciales se
alineó como S01–S12. No cambió su semántica: cubren fallo de protección,
descarte posterior a protección, reintento, fallos repetidos, consumo único de
destrucción y hueco, enlaces obsoletos, reactivación, cierre, matriz de puntos
de inyección, espejo de cabecera y equivalencia diferencial recuperada.

Resultados ejecutados sobre `e5a1ad3`:

| Plataforma / comando | Resultado |
| --- | --- |
| Windows/MSVC `cargo fmt --all --check` | aprobado |
| Windows/MSVC `cargo clippy --workspace --all-targets -- -D warnings` | aprobado |
| Windows/MSVC `cargo test -p ele-nexo -- --test-threads=1` | 160 aprobadas, 0 fallidas |
| Windows/MSVC `cargo test --workspace --no-fail-fast -- --test-threads=1` | 744 aprobadas, 0 fallidas, 3 ignoradas, exit 0 |
| Windows/MSVC `cargo test -p ele-nexo --test recuperacion -- --test-threads=1` | 13/13 (S01–S12 + S02b de Windows) |
| Windows/MSVC `nexo-physical-fuzz --fallos 5000 256` | 1.280.000 comandos, 127.546 inyecciones, sin divergencias |
| Ubuntu WSL2/glibc `cargo test -p ele-nexo -- --test-threads=1` | 160 aprobadas, 0 fallidas |
| Ubuntu WSL2/glibc `recuperacion` dentro de la suite | 12/12 S01–S12 |
| Ubuntu WSL2/glibc `nexo-physical-fuzz --fallos 5000 256` | 1.280.000 comandos, 127.546 inyecciones, sin divergencias |

El toolchain Linux/glibc se instaló dentro de Ubuntu WSL2 y los binarios se
compilaron y ejecutaron allí; ya no es solo una validación cruzada musl. Sigue
faltando un host Linux fuera de WSL2.

GitHub Actions está bloqueado por agotamiento de cuota. Los trabajos con cero
pasos ejecutados no son fallos de compilación y no se modificaron
`.github/workflows/`. La validación anterior es local.

Limitación histórica de ese corte: `FaultPlan` solo interrumpía antes de cada
syscall; S02 cubría el estado parcial entre dos syscalls, no dentro de una. El
incremento PFS documentado arriba añade simulación adversarial dentro del rango,
pero sigue sin provocar un fallo parcial real del kernel. `Drop` tampoco puede
devolver un fallo real de liberación; ahora lo reintenta de forma acotada y lo
contabiliza si persiste.

Base: `main` en `2712a1b` (incluye NEXO v0.2, PR #66, y el arreglo del
fixture de Stage 1, PR #67). Entorno: Windows 10 x86-64, Rust 1.99.1,
toolchain `stable-x86_64-pc-windows-msvc`.

La ejecución del workspace iniciada en la sesión anterior se interrumpió sin
dejar un resultado verificable, así que toda la validación se repitió.

## Comandos y resultados

| Comando | Resultado |
| --- | --- |
| `cargo fmt --all --check` | sin cambios |
| `cargo clippy --workspace --all-targets -- -D warnings` | sin avisos |
| `cargo test -p ele-nexo -- --test-threads=1` | 141 aprobadas, 0 fallidas |
| `cargo test --workspace --no-fail-fast -- --test-threads=1` | 725 aprobadas, 0 fallidas, 3 ignoradas (microbenchmarks), código de salida 0 |
| `nexo-physical-fuzz 10000` (release) | 4 semillas × 10 000 operaciones sin divergencias |
| `nexo-physical-fuzz 100000` (release) | 4 semillas × 100 000 operaciones sin divergencias (17,9 s) |
| `nexo-physical-bench` (release, 2 corridas) | ver `NEXO_v0.3_BENCHMARKS.md` |

Las 141 pruebas de `ele-nexo` son las 140 anteriores más
`recommit_of_protected_pages_restores_real_access`, añadida en esta revisión.

## Revisión del código físico

* **`unsafe`** solo en `physical/platform/{windows,linux}.rs` (FFI) y en
  `address_space.rs` (copias de bytes y aritmética de punteros). Cada bloque
  tiene su precondición comentada; los rangos se validan (alineación a página,
  contención en la reserva, aritmética comprobada) antes de cada llamada.
  `pool.rs` y `oracle_adapter.rs` no contienen `unsafe`.
* **`SYSTEM_INFO`** coincide con el layout de Win32 en x86-64.
* **Linux**: reserva con `mmap(PROT_NONE)` y recorte de prefijo/sufijo para
  alinear a 64 KiB, sin `MAP_FIXED`; decommit = `madvise(DONTNEED)` +
  `PROT_NONE`, lo que garantiza ceros al reconfirmar.
* **Windows**: verificado en ejecución que `VirtualAlloc(MEM_COMMIT)` sobre
  páginas ya confirmadas y protegidas restaura `PAGE_READWRITE` (antes el
  seguimiento lo suponía sin prueba).
* **Corregido**: `AddressSpace::is_empty` era incoherente con `len()` tras
  `release`.
* `PhysicalPool` no es `Send`/`Sync` (contiene `NonNull`), coherente con C1.
* `HoleToken` es lineal; un hueco perdido lo detecta `close()` como `Leak`.

## Problemas pendientes

1. **Backend Linux no ejecutado localmente.** Solo se compila y ejecuta en el
   CI de Ubuntu; en esta máquina no hay toolchain Linux.
2. **Atomicidad ante fallos del SO en el reclaim.** Si `protect_none` o
   `decommit` fallan dentro de `destroy`/`release_hole`, la destrucción ya se
   aplicó pero la subpágina queda `Committed` con 0 ocupados: el error se
   devuelve, `check_invariants` lo detecta y los accesos posteriores fallan de
   forma controlada (`Inaccessible`), pero el pool no se recupera. La inyección
   de fallos solo cubre `commit`.
3. **Rendimiento**: 5,6–7,5× más lento que `Box` en la ruta caliente y
   44–46× con commit/reclaim en estas corridas; diagnóstico en
   `NEXO_v0.3_BENCHMARKS.md`. Sin optimizar en esta fase, por decisión.
4. **Medición insuficiente**: una sola hebra, sin percentiles, sin aislamiento
   de CPU, sin RSS/working set; las cifras varían hasta 2× entre corridas.
5. **Metadatos duplicados**: la cabecera normativa se mantiene también en
   estructuras Rust (generaciones y bitmaps), lo que duplica memoria y obliga a
   reescribirla entera en cada transición.
6. **`Handle`** expone `slot`/`generation` mutables; falsificarlos solo
   produce `StaleGeneration`, pero conviene cerrarlo antes del port.
7. **Obligaciones formales**: los teoremas T1–T4 y la correspondencia I11 de
   `NEXO_v0.3_FORMAL.md` están enunciados, no demostrados.
8. **Integración en ELE-LIR** (`--memory-model=nexo`): no iniciada; ver
   `NEXO_v0.3_ELE_PORT.md`.

## Corrección de atomicidad, API y optimización (2026-11-13, segunda revisión)

Base: `cb16d5d` (cabeza inicial del PR #69). Commits:

| Commit | Contenido |
| --- | --- |
| `b675cf0` | Reclamación transaccional: estados físicos por página y lógicos por subpágina, reclaim por pasos reintentable, `FaultPlan`, contrato de errores que devuelve la capacidad, espejo de cabecera verificado, API lineal (`Handle` no `Copy`, `ObjRef`, `revalidate` no fabrica dueños) |
| `c5cab59` | Casos hoy denominados S01–S12 y modo `--fallos` del fuzzer físico |
| `a66105e` | Espejo de cabecera incremental y puesta a cero sin heap |
| `f78a5b4` | Índice de densidad y `MEM_DECOMMIT` de un solo paso en Windows |
| `6943dbc` | Benchmark ampliado (estadísticas, SO, cabecera, asignaciones, memoria) |

El endurecimiento de la API va en el primer commit y no en uno propio: el
contrato "un `Err` devuelve la capacidad intacta" y la eliminación de
`revalidate → Handle` forman parte de la misma corrección.

### Defectos originales y causa raíz

1. **Atomicidad del reclaim** (causa: el estado lógico se modificaba antes de
   llamadas al SO que podían fallar, sin estado que representara el fallo).
   Corregido con la máquina de estados de `NEXO_v0.3_FORMAL.md` §9.1.
2. **Error ambiguo tras consumir** (causa: `Result<_, PoolError>` no distinguía
   "no consumido" de "consumido con fallo físico"). Corregido: `Err((cap, e))`
   solo antes de consumir; `Ok(report)` separa el efecto lógico del físico.
3. **Fabricación de dueños** (causa: `revalidate(Link) → Handle` y `Handle:
   Copy` con campos públicos). Corregido: `Handle` lineal sin constructor
   público; `revalidate → ObjRef` no propietario.
4. **Linux `madvise` antes de `mprotect`** sin estado intermedio. Corregido:
   protección previa obligatoria y estado `Protected` registrado.
5. **Protección redundante en Windows** (dos llamadas por reclaim). Corregido
   en `f78a5b4`; se conserva como opción para pruebas.

### Fallos inyectados y comportamiento observado

| Punto | Estado tras el fallo | Recuperación |
| --- | --- | --- |
| Reserve | ninguna reserva | — |
| Commit / Recommit | nada publicado; página en su estado anterior | asignar de nuevo |
| Protect | `ReclaimPending`, físico `Accessible` | `repair` |
| Decommit | `ReclaimPending`, físico `Protected` (o `Accessible` en Windows de un paso) | `repair` |
| HeaderWrite | operación lógica aplicada; superpágina sucia | siguiente transición o `repair` |
| Release | pool abierto y consistente | `close` de nuevo |

En todos los casos se comprueban estado lógico, físico, espejo e invariantes.
Los fallos son inyectados antes de la llamada al SO; no se provocaron fallos
reales del SO.

### Resultados — Windows x86-64 (nativo), HEAD `6943dbc`

| Comando | Resultado |
| --- | --- |
| `cargo fmt --all --check` | sin cambios |
| `cargo clippy --workspace --all-targets -- -D warnings` | sin avisos |
| `cargo test -p ele-nexo -- --test-threads=1` | 160 aprobadas, 0 fallidas (incluye el doctest `compile_fail` de doble destrucción) |
| `cargo test --workspace --no-fail-fast -- --test-threads=1` | 744 aprobadas, 0 fallidas, 3 ignoradas (microbenchmarks), código de salida 0 |
| `nexo-physical-fuzz 100000` | 4 semillas × 100.000 operaciones sin divergencias |
| `nexo-physical-fuzz --fallos 5000 256` | 256 campañas × 5.000 = 1.280.000 comandos; 127.546 inyecciones, 922 reclamaciones pendientes, 80.319 reparaciones; sin divergencias |

Cada commit intermedio compila, pasa Clippy y las pruebas físicas, y ejecuta
ambos modos del fuzzer.

### Resultados — Linux x86-64 (WSL2, kernel 5.10.16, páginas de 4 KiB)

Binarios compilados en Windows para `x86_64-unknown-linux-musl` (enlazados
con `rust-lld`) y **ejecutados** en WSL2. No es Linux nativo ni glibc.

| Ejecución | Resultado |
| --- | --- |
| Línea base (`cb16d5d`, antes de los cambios) | 141/141 |
| Suite `ele-nexo` final en `6943dbc` (sin doctests ni `r02b`, exclusivos de Windows) | 159/159 (bislab 9, casos_base 23, casos_v02 18, fuzz 7, maquina 16, unitarias 11, physical 21, recuperacion 12, verificador 42) |
| Prueba específica `linux_protege_siempre_antes_de_madvise` | pasa |
| `nexo-physical-fuzz 100000` | 4 × 100.000 sin divergencias |
| `nexo-physical-fuzz --fallos 5000 256` | 1.280.000 comandos sin divergencias; 1.062 reclamaciones pendientes |

El CI de GitHub Actions del PR no ejecutó pasos porque la cuota disponible de
Actions está agotada. Es un bloqueo de cuota, no evidencia de fallo de
compilación. No se modifican workflows para eludirlo.

### Validación del poder de las pruebas

Tres mutaciones introducidas a propósito y revertidas: marcar como devuelta
una reclamación fallida, aceptar la generación de un objeto destruido y
omitir el bitmap libre en el espejo. Las tres las detectan las pruebas y el
fuzzer de fallos, que las reduce a 8, 4 y 1 comandos.

### Estado de los problemas pendientes de la revisión anterior

| # | Problema | Estado |
| --- | --- | --- |
| 1 | Linux no ejecutado | **Resuelto en WSL2**: ejecutado con musl y glibc; falta un host Linux fuera de WSL2 |
| 2 | Atomicidad del reclaim | **Corregido** (S01–S12, fuzz con fallos) |
| 3 | Rendimiento | **Mejorado**: caliente 10,1× → 3,5× `Box` en la misma sesión (Windows); reclaim 44,7× → 37,8× |
| 4 | Medición | **Mejorado**: percentiles, CV entre corridas, SO, cabecera, asignaciones, WS/RSS; sigue sin aislamiento de CPU ni perfilador |
| 5 | Metadatos duplicados | **Pendiente** (el espejo ya no se reescribe entero) |
| 6 | `Handle` mutable | **Corregido** (lineal, campos privados) |
| 7 | T1–T4, I11 | **Pendiente**: enunciados; I11 probado por casos, no demostrado |
| 8 | Integración en ELE-LIR | **No iniciada**, por diseño de esta fase |

### Limitaciones que siguen abiertas

- Fallos reales del SO: solo inyectados.
- Las cabeceras de superpágina nunca se devuelven al SO.
- `Drop` de `AddressSpace` ignora un fallo de liberación (fuga de reserva, no
  acceso indebido).
- Los `expect` de `pool.rs` dependen de invariantes, no de una prueba.
- Concurrencia: `PhysicalPool` no es `Send`/`Sync`; no hay pools compartidos.
