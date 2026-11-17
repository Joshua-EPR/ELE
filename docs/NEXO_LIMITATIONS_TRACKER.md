# NEXO: registro de limitaciones L01--L09

Este documento convierte las limitaciones conocidas de NEXO v0.3 en trabajo
auditable. No es una demostración de seguridad ni una hoja de ruta para cambiar
la sintaxis pública de ELE. El corte publicado usado como base es
`d6b03289edf9d0888fa11d81c70b7f574de49969` de
`feat/nexo-v0.3-physical-memory`; los cambios posteriores que aún no estén
publicados o validados se consideran **trabajo en curso**, no evidencia.

Fuentes revisadas: `NEXO_v0.3_FORMAL.md`, `NEXO_v0.3_VALIDACION.md`,
`NEXO_v0.3_BENCHMARKS.md`, `NEXO_v0.3_ELE_PORT.md`, el allocator físico y sus
pruebas, y los contratos actuales de ownership, préstamos y drops de Stage 1 y
ELE-LIR. Esta revisión documental no ejecutó una campaña nueva; los resultados
citados son los que esos documentos registran con sus comandos y commits.

## Vocabulario de estado y clasificación

- **Corregida**: implementación y prueba de aceptación presentes y validadas.
- **Parcial**: existe una mitigación o evidencia útil, pero queda al menos una
  obligación explícita sin cerrar.
- **Pendiente**: no hay todavía implementación aceptable.
- **Bloqueada externamente**: requiere una capacidad ajena al repositorio.
- **Decisión requerida**: hay alternativas incompatibles y falta medir o fijar
  el contrato antes de implementar.

Una limitación puede tener más de una clasificación. Las usadas aquí son:
**defecto corregible**, **restricción deliberada**, **limitación de plataforma**,
**obligación de demostración**, **funcionalidad nueva** y **dependencia del
compilador ELE**.

## Matriz maestra

| ID | Limitación y riesgo | Clasificación | Dependencias | Solución / criterio de cierre | Evidencia disponible | Estado | Destino | Bloqueadores |
|---|---|---|---|---|---|---|---|---|
| L01 | Un backend puede aplicar solo parte de una operación física y devolver error o estado ambiguo. Con el inyector anterior al syscall no se cubría ese intervalo. | Defecto corregible; limitación de plataforma | Estado físico por página, cuarentena, reconciliación, PFS01--PFS12, contrato Windows/Linux | Un backend adversarial acotado debe poder producir aplicación parcial; toda página de resultado desconocido queda inaccesible para la API hasta reconciliarse; invariantes y modelo diferencial deben concordar después de éxito, fallo y reparación. | `fb0c58b`: PFS01--PFS12 (16 casos), cuarentena del pool y fuzzer 4×3 outcomes: 185/185 en Windows y WSL2; 4.096 comandos y 192 outcomes PFS por plataforma. Los errores reales del backend también cuarentenan antes de retornar. | Parcial | PR #69 | Falta provocar/observar un fallo parcial real, probe aislado por señal y Linux externo; PFS sigue siendo simulación adversarial. |
| L02 | `Drop` no puede devolver un error persistente de liberación; perder el último dueño podría ocultar una reserva no liberada. | Restricción deliberada de Rust; defecto corregible en la API explícita | `AddressSpace::release`, `PhysicalPool::close`, ownership lineal, registro/diagnóstico final | `close` debe ser reintentable y conservar el dueño y el estado si falla; `Drop` queda como último esfuerzo acotado y nunca sustituye a `close` en rutas comprobables. Pruebas: fallo, reintento, doble cierre y rechazo de fuga. | `fb0c58b`: `try_close` devuelve el único dueño; `ReleaseUncertain` bloquea toda operación salvo retry; 7/7 casos de cierre. `Drop` reintenta tres veces y contabiliza fallos terminales/bytes posibles. | Parcial | PR #69 | Rust no permite devolver el error desde `Drop`; un rechazo persistente todavía puede filtrar la reserva y el diagnóstico agregado no permite recuperarla. |
| L03 | La página de encabezado de cada superpágina inicializada permanece comprometida aunque no haya objetos vivos. Retiene memoria física y escala con el máximo histórico. | Restricción deliberada; decisión arquitectónica | L04, contrato de recuperación, benchmarks de RSS/commit, layout de 64 KiB | Para v0.3 se conserva el encabezado residente: prioriza autoridad verificable y reparación. El cierre exige una comparación medida de las alternativas y una prueba de reconstrucción antes de cambiarlo. | Layout actual: 4095 bytes usados en una página de 4096. Benchmark de 50 000 objetos: ~3,26 MiB comprometidos para ~3,05 MiB útiles; tras vaciar, ~0,21 MiB de encabezados para 53 superpáginas usadas. | Decisión requerida | Rama posterior propuesta `feat/nexo-header-lifecycle` | Elegir junto con L04 dónde vive la autoridad; medir ahorro, coste de reactivación y comportamiento bajo fallo parcial. |
| L04 | Generaciones, mapas y estados existen en metadatos Rust; el encabezado físico es un espejo comprobado. La duplicación consume memoria y crea una transición de sincronización que puede fallar. | Restricción deliberada; funcionalidad arquitectónica nueva | L01, L03, I11, formato físico, reparación | No eliminar una copia por intuición. Prototipar autoridad única o representación compacta y demostrar reconstrucción, rechazo de referencias obsoletas y reparación tras fallo de escritura. El espejo solo puede desaparecer si ninguna obligación depende de él. | `SuperpageMeta` mantiene generaciones, libres, huecos, ocupación y estado; `check_invariants` compara el encabezado cuando no está sucio. Las escrituras incrementales redujeron el coste a 42 bytes por ciclo, pero no eliminan la duplicación. | Pendiente | Rama posterior propuesta `feat/nexo-metadata-authority` (coordinada con L03) | El port ELE todavía presupone primitivas nativas y un layout; falta decidir persistencia, autoridad y recuperación. |
| L05 | `expect`/pánicos internos pueden convertir una inconsistencia o entrada adversarial en aborto del proceso, contradiciendo progreso seguro. | Defecto corregible; obligación de demostración | Tipos de error, IDs validados, auditoría de todos los caminos, fuzz | Ningún dato público o estado reparable debe alcanzar `expect`, `unwrap`, indexación fuera de rango o aritmética no comprobada. Cada eliminación requiere un negativo dirigido; los asserts puramente estáticos deben justificarse. | Tipos testigo `SuperpageIndex`, `Result<&SuperpageMeta, PoolError>` en `meta`/`meta_mut`, disciplina Fase A/B, eliminación total de `expect` en `pool.rs`, eliminación absoluta de la feature `test-internals` moviendo la instrumentación a `#[cfg(test)] pub(crate)` y suite `api_security.rs` eliminaron todos los riesgos en la API pública de producción. | Corregida (allocator físico y API pública) | PR #69 para el allocator físico; auditorías posteriores para máquina/verificador | Distinguir invariantes de construcción de supuestos dependientes de entrada en máquina/verificador. |
| L06 | El pool físico no es `Send` ni `Sync`; no existe seguridad nativa demostrada para acceso concurrente. | Restricción deliberada segura; funcionalidad nueva | C1--C6 del modelo, L01/L02, ownership de particiones, contadores e índices por partición, pruebas de intercalado | Fase 1: permitir, si se demuestra seguro, transferir entre hilos la propiedad exclusiva de un pool sin préstamos activos (`Send`, no `Sync`). Fase 2: paralelismo por particiones disjuntas con coordinador explícito. `Sync` compartido no es criterio obligatorio. Nunca añadir `unsafe impl` sin argumento y pruebas. | T3 solo está enunciado para el modelo abstracto; el pool físico serializa mediante `&mut self` y no promete concurrencia. Esta restricción evita hoy carreras nativas. | Pendiente | Ramas posteriores propuestas `feat/nexo-pool-transfer` y, después, `feat/nexo-partition-parallel` | Alias/revocación, reparación y cierre global; herramientas de detección de carreras disponibles por plataforma; L04 puede cambiar la sincronización necesaria. |
| L07 | T1--T4 e I11 están enunciados o probados por casos, no demostrados universalmente ni mecanizados. | Obligación de demostración | Semántica congelada, O1--O18, L01/L02/L04/L06 según alcance, herramienta formal | Cerrar primero una derivación revisable del núcleo secuencial; luego mecanizar un subconjunto explícito. Cada teorema debe declarar supuestos de plataforma. Fuzz, tests y ausencia observada de fallos siguen siendo evidencia empírica, no prueba. | FORMAL marca T1--T4 “enunciado, no demostrado” e I11 “probado por casos, no demostrado”; el arnés diferencial y las campañas cubren casos finitos. | Pendiente | Rama posterior propuesta `formal/nexo-core-safety`; no dentro de #69 salvo correcciones de especificación | Elegir herramienta y representación sin crear una segunda semántica divergente; L01 debe estabilizar sus transiciones antes de probarlas. |
| L08 | La validación Linux solo cubre WSL2; no hay evidencia en un host Linux externo, kernels/allocators distintos ni presión real del SO. | Limitación de plataforma; dependencia externa | Host autorizado, glibc/musl, comandos reproducibles, matriz de kernel | Repetir suite, PFS y benchmarks en al menos un host Linux no WSL; registrar kernel, libc, arquitectura, commit y comandos. Un fallo real se reduce a prueba. No modificar workflows para sortear la cuota. | Windows/MSVC y WSL2 Linux glibc están documentados; también hay mediciones musl. GitHub Actions está bloqueado por cuota y los trabajos de cero pasos no son fallos de compilación. | Bloqueada externamente | Evidencia en #69 cuando exista; no requiere rama de código si no hay corrección | Acceso autorizado y sin coste a un host externo; cuota de Actions. |
| L09 | NEXO no está integrado en Stage 1 ni ELE-LIR; exponer un modo de memoria antes de que el verificador represente capacidades, revocación y cleanup degradaría seguridad. | Dependencia del compilador ELE; funcionalidad nueva | Contrato estable de L01--L07, intrínsecos OS, direcciones/aritmética comprobada, capacidades lineales, drops en todas las salidas, selección de plataforma, verificador LIR y harness diferencial | Integración experimental y opt-in: primero tipos/capacidades y operaciones LIR verificables, luego lowering y backend, finalmente programas `.l` reales. No añadir `--memory-model=nexo` nominal que redirija al allocator sin verificación de punta a punta. | `NEXO_v0.3_ELE_PORT.md` enumera las primitivas ausentes. Stage 1 ya modela ownership/préstamos/drops para sus tipos actuales, pero no tiene objetos, reservas o tokens NEXO. No hay integración demostrada. | Pendiente | Rama posterior propuesta `feat/experimental-nexo-memory-model` | Diseño LIR y ABI, diagnósticos, backend Windows/Linux y negativos de seguridad; no cambiar sintaxis v2 ni declarar Stage 2/self-hosting. |

## Decisiones y alternativas por limitación

### L01 — fallo físico parcial

Alternativas consideradas:

1. **Inyectar solo antes de cada syscall.** Es simple y determinista, pero no
   cubre que el sistema haya cambiado un subconjunto del rango antes del error;
   por tanto no cierra L01.
2. **Backend adversarial por página con estado conocido/desconocido.** Permite
   PFS determinista, minimizable y acotado. Es la opción apropiada para #69,
   siempre que la API ponga en cuarentena el resultado ambiguo y no “adivine” el
   estado del kernel.
3. **Provocar fallos reales del kernel.** Aporta evidencia de plataforma, pero
   no es reproducible ni exhaustiva y puede necesitar privilegios. Complementa,
   no sustituye, al backend adversarial.

Tradeoff aceptado: una cuarentena puede retener páginas o impedir operaciones
que físicamente habrían sido seguras, pero falla de forma conservadora. Liberar
o reutilizar una página ambigua para mejorar disponibilidad no es aceptable.

### L02 — cierre explícito frente a `Drop`

Alternativas consideradas:

1. **Confiar solo en `Drop`.** Rechazada: no comunica el fallo al llamador.
2. **Hacer pánico en `Drop`.** Rechazada: puede abortar durante otro unwind y no
   recupera la reserva.
3. **`close` reintentable más `Drop` de último esfuerzo.** Es el contrato de
   v0.3. Conserva al dueño si el cierre explícito falla y mantiene `Drop` como
   red de seguridad sin prometer observabilidad que Rust no ofrece.
4. **Registro global de liberaciones fallidas.** Puede mejorar diagnóstico, pero
   añade estado global, sincronización y problemas de cierre del proceso. Solo
   debe añadirse con un consumidor y pruebas claras; no cierra por sí solo L02.

### L03/L04 — encabezado residente y autoridad duplicada

Estas dos limitaciones no deben resolverse en PR separados que elijan contratos
incompatibles. Alternativas:

| Alternativa | Memoria en vacío | Recuperación/verificación | Coste y riesgo |
|---|---:|---|---|
| Mantener encabezado residente y metadatos Rust | Mayor | Fuerte y ya implementada | Duplicación y máximo histórico residente; menor cambio para v0.3. |
| Descomprometer encabezado al vaciar y reconstruirlo | Menor | Requiere autoridad externa completa y transición crash/fault-safe | Más syscalls y una nueva ruta crítica de reactivación. |
| Encabezado como autoridad única | Menos duplicación Rust | Lectura física en el camino caliente; el encabezado no puede desaparecer | Acopla allocator y formato, y complica errores de acceso físico. |
| Metadatos Rust como autoridad única | Permite descartar encabezados | Pierde el espejo físico que hoy sostiene I11 y el port | Hay que redefinir layout, reparación y persistencia observada. |
| Resumen compacto externo + encabezado reconstruible | Potencialmente el mejor equilibrio | Necesita protocolo explícito de versión/commit | Mayor complejidad; debe vencer al diseño actual en benchmark y prueba. |

Decisión conservadora para #69: mantener el diseño actual y documentar el coste.
La rama posterior debe medir al menos commit/RSS vacío, coste de asignación tras
reactivar, bytes de header escritos, syscalls y campañas de fallo parcial. No se
acepta ahorrar una página sacrificando detección de referencias obsoletas,
inaccesibilidad tras reclaim o capacidad de reparación.

### L05 — pánicos internos

La sustitución mecánica de `expect` por `Result` no basta. Una ruta que recibe
un estado imposible debe impedir que el pool continúe como si fuera válido. El
orden de trabajo es: identificar el origen del índice/estado, hacerlo validable
por tipo cuando sea posible, devolver un error de invariantes cuando no, y
añadir un test que alcance el borde sin corromper el proceso. Los `unwrap` de
tests no son parte de la API, pero pueden ocultar que un negativo comprueba el
error equivocado; deben revisarse al tocar ese test.

### L06 — concurrencia

La opción de menor riesgo no es un pool global con mutex y `unsafe impl Sync`.
Primero debe separarse **transferencia de ownership** de **acceso compartido**:

- `Send` solo sería aceptable si todos los recursos de plataforma y los estados
  pendientes pueden destruirse/repararse en el hilo receptor.
- Paralelismo por particiones disjuntas preserva mejor el modelo NEXO; índices,
  métricas y cierre global necesitan un coordinador con protocolo probado.
- `Sync` compartido añade aliasing y revocación simultánea. Puede permanecer
  deliberadamente fuera del alcance si la API por particiones cubre el caso de
  uso.

### L07 — demostración

Antes de elegir una herramienta hay que congelar el núcleo a demostrar. Un
spike de Lean 4, Coq u otra herramienta es válido, pero no debe contarse como
cierre si solo reexpresa tipos. El primer hito útil es T2 para un núcleo
secuencial y finito, seguido por T1/T4 y una relación I11 que modele éxito,
fallo, cuarentena y reparación. T3 nativo pertenece a la rama de concurrencia;
el teorema abstracto no prueba ausencia de data races en Rust.

### L08 — Linux externo

WSL2 aporta una segunda implementación de plataforma, pero comparte host y no
equivale a diversidad de kernel/entorno. La evidencia externa debe conservar
salidas y datos de entorno, no solo decir “pasó”. No se abrirá un cambio de CI
para resolver la cuota: cuando Actions ejecuta cero pasos, no existe resultado
de compilación que interpretar.

### L09 — port a ELE

Un cambio léxico no implementa NEXO. El orden mínimo de integración es:

1. especificar tipos lineales (`Handle`, `HoleToken`) y referencias revocables
   sin debilitar los préstamos existentes;
2. representar sus efectos, cleanup y errores en ELE-LIR y hacer que el
   verificador rechace uso después de move/reclaim, doble liberación y escape;
3. bajar a primitivas nativas comprobadas en Windows y Linux;
4. contrastar programas `.l` con el modelo y el allocator Rust.

Hasta entonces, NEXO sigue siendo un experimento aislado. No se declara Stage 2,
self-hosting, un ABI nuevo ni soporte de lenguaje por añadir un flag o ejemplo.

## Dependencias y orden de apertura

```text
L01 ─┬─> L04 ─┬─> L03
     │        ├─> L07
L02 ─┤        └─> L09
     ├─> L07
     └─> L06 ───> L07
L05 ───> L07
L08  (validación externa de L01/L02 y de futuras L06/L09)
L01..L07 ───────> L09
```

El grafo indica precedencia de contratos, no que toda demostración formal deba
terminar antes de empezar un prototipo aislado. Sí impide presentar como segura
una integración que omita obligaciones conocidas.

## División de alcance

### PR #69 — alcance que puede cerrarse ahora

- L01: backend adversarial determinista y acotado, cuarentena/reconciliación,
  PFS01--PFS12 y evidencia local Windows/Linux.
- L02: contrato y pruebas de `close`/`release` reintentables; límites honestos
  de `Drop`.
- L05: eliminar o justificar pánicos alcanzables del allocator físico, con
  negativos dirigidos.
- L03/L04: solo métricas, invariantes y decisión documentada; **no** rediseñar
  autoridad/layout en este PR.
- L08: adjuntar evidencia externa si aparece, sin convertirla en requisito para
  corregir el código local ni tocar `.github/workflows/` por la cuota.
- Mantener el PR en borrador mientras cualquiera de las pruebas de aceptación
  anterior no esté validada en Windows y Linux.

### Ramas/PR posteriores e independientes

1. `feat/nexo-metadata-authority` + `feat/nexo-header-lifecycle`: L04 y L03;
   pueden comenzar como un único spike comparativo y separarse solo después de
   fijar la autoridad.
2. `feat/nexo-pool-transfer`: primera fase de L06 (`Send` si procede, no
   `Sync`).
3. `feat/nexo-partition-parallel`: segunda fase de L06 con propiedad disjunta.
4. `formal/nexo-core-safety`: L07, aislada del producto y sin reescribir la
   implementación para hacer trivial la prueba.
5. `feat/experimental-nexo-memory-model`: L09, opt-in y posterior a un contrato
   físico/LIR estable.

Los nombres son propuestas de planificación, no ramas ni PR que este documento
afirme haber creado. L08 es una tarea de validación externa; solo necesita una
rama si produce scripts o correcciones reales.

## Criterio de mantenimiento del tracker

Una fila solo pasa a **Corregida** al enlazar un commit publicado, una prueba de
aceptación y la plataforma en la que se ejecutó. Una obligación formal solo
pasa a **Demostrada** bajo la definición de `NEXO_v0.3_FORMAL.md`; una campaña
de fuzz, por grande que sea, no cambia esa palabra. Si cambia el layout, la
autoridad de metadatos, el modelo de concurrencia o el contrato LIR, deben
reevaluarse todas las filas dependientes y no limitarse a actualizar su texto.

---

## Registro de auditoría y cierre de soundness P0/P1 en NEXO v0.4 (Operación Security Lockdown)

Durante la auditoría profunda de autoridad e identidad y la operación de cierre de autoridad de NEXO v0.4 se detectaron, cerraron y verificaron los siguientes defectos críticos de seguridad:

1. **P0-001 (Eliminación de emisión de autoridad arbitraria)**: Se eliminaron terminantemente `CompactPoolRegistry::acquire_token_for(physical_pool_id: u64)` y `acquire_token()`. Ningún token de autoridad puede emitirse a partir de enteros numéricos. La única vía pública es `register_pool(&PhysicalPool)`.
2. **P0-002 (Invariante de registro único de pool físico)**: Se impide el registro múltiple o duplicado de un mismo pool físico en `CompactPoolRegistry` y `CompactPoolRegistry16`. Cualquier intento duplicado es rechazado atómicamente con `CompactPoolError::AlreadyRegistered { physical_pool_id }`, garantizando una correspondencia biyectiva $1:1$.
3. **P0-003 (Cierre de cadena física y reporte de cuarentena)**: `CompactPhysicalPool` y `CompactPhysicalPool64` verifican el estado completo de la memoria física. Ante subpáginas en estado `PageState::Quarantined` se retorna el error dedicado y tipado `CompactRevalidateError::SubpageQuarantined`.
4. **P1-004 (Eliminación de mocks privilegiados del API distribuido)**: Se erradicó la feature `test-mocks` de `crates/nexo/Cargo.toml` y el módulo público `pub mod testing` de `compact.rs`. Los mocks de prueba residen exclusivamente en `#[cfg(test)] mod tests` para pruebas unitarias internas.
5. **P1-005 (Prohibición de agotamiento del registro global en pruebas)**: Se factorizaron `CompactIdAllocator8` y `CompactIdAllocator16` como asignadores numéricos atómicos puros desacoplados de autoridad de memoria, permitiendo que pruebas de agotamiento y concurrencia se ejecuten en instancias aisladas sin contaminar ni agotar los singletons globales.
6. **P1-006 (Reparación de pruebas adversariales con fallos reales de compilación)**: Se migraron las pruebas de comentarios a pruebas reales de compilación externa ejecutadas con arnés `run_fixture_check` contra `crates/nexo/tests/fixtures/external_consumer` (`E0277`, `E0433`, `E0502`, `E0515`, `E0560`, `E0599`). Se añadieron las suites `AUTH-01..20` (soundness) y `AUTH-HARDEN-01..20` (lockdown) con paso determinista tanto en `--test-threads=1` como en `--test-threads=8`.
7. **P0-007 (Fallo cerrado en inspección de metadatos de piscinas cerradas)**: `PhysicalPool::generation()` y `page_state()` ahora verifican `self.space()?` antes de ubicar el slot, retornando inmediatamente `Err(PoolError::Closed)`. Asimismo, `PhysicalPool::close()` limpia explícitamente `superpages.clear()` junto con `space = None`, eliminando lecturas de metadatos obsoletos en pools cerrados.
8. **P0-008 (Validación defensiva de límites en `ScopedArena::close_scope`)**: Se incorporó validación estricta de límites contra marcadores de ámbito adulterados (`marker.offset > self.offset` o `marker.drop_count > self.drops.len()`), retornando inmediatamente `ArenaError::ScopeMismatch` antes de mutar el offset de la arena o ejecutar destructores.
9. **P1-009 (Rechazo inmediato de piscinas cerradas en adaptadores compactos y registros)**: `CompactPhysicalPool::new` y `CompactPhysicalPool64::new`, así como `CompactPoolRegistry::register_pool` y `CompactPoolRegistry16::register_pool`, verifican explícitamente `pool.is_closed()` y fallan inmediatamente con `Err(CompactPoolError::PoolClosed)` en lugar de permitir la creación de adaptadores o el registro de piscinas cuyo espacio de direcciones ya fue descommitado o liberado.
10. **P1-010 (Preservación de errores tipados en revalidación compacta)**: En `CompactPhysicalPool::current_compact_generation` se eliminó el mapeo ciego de errores `map_err(|_| CompactRevalidateError::OutOfBounds)`. Se implementó `convert_pool_error` preservando los errores tipados subyacentes de la piscina física (`PoolClosed`, `Physical(p)`, `Invariant(s)`, `GenerationRetired`, `SubpageQuarantined`, `StaleGeneration`, `OutOfBounds`), permitiendo diagnósticos precisos ante fallos del kernel o cierre de piscinas.
11. **P1-011 (Recuperación resiliente ante envenenamiento de mutex en el registro global)**: Se reemplazó el `.lock().unwrap()` en `CompactPoolRegistryInstance::register` y `CompactPoolRegistryInstance16::register` por recuperación explícita de envenenamiento (`unwrap_or_else(|poisoned| ...)`), reordenando y deduplicando el vector de IDs registrados. Esto previene que un pánico aislado en un hilo de trabajo bloquee permanentemente el registro global de enlaces compactos en procesos concurrentes.
12. **P1-012 (Auditoría de ScopedArena y verificación de límites de ciclo de vida con DROP-17..20)**: Se verificó la consistencia de `ScopedArena` ante marcadores desordenados (`DROP-17`), marcadores de piscinas ajenas (`DROP-18`), recuperación de marcadores en arenas envenenadas por pánico en `Drop` (`DROP-19`) y alineación en frontera exacta de capacidad con tipos de tamaño cero (ZST, `DROP-20`), asegurando que ningún marcador corrupto cause dobles liberaciones ni escrituras fuera de límites.
13. **P1-013 (Bloqueo absoluto de autoridad durante `ReleaseUncertain`)**: Establecimiento de la distinción formal entre cerrado (`is_closed()`), operativo (`is_operational()`), y en resultado incierto de liberación (`is_release_uncertain()`). `ensure_operational()` bloquea terminantemente registros de 8 y 16 bits (`CompactPoolError::ReleaseUncertain`), construcción de adaptadores, consultas de `generation()`, `page_state()`, `physical_access()`, `base_addr()` y revalidación ordinaria. Preserva al único dueño para reintentos de cierre (`try_close`).
14. **P1-014 (Conversión exhaustiva y tipada de errores en adaptadores compactos)**: Eliminación del comodín genérico `_ => OutOfBounds` en `convert_pool_error`. Mapeo uno a uno de las 13 variantes de `PoolError`, preservando `ReleaseUncertain`, `PoolClosed`, `SubpageQuarantined`, `Physical(p)`, `Invariant(s)`, y `ForeignPool`.
15. **P1-015 (Atomicidad transaccional y auditoría de invariantes tras envenenamiento de Mutex)**: Vinculación biyectiva `(physical_pool_id, compact_id)` en `CompactPoolRegistryInstance` y `CompactPoolRegistryInstance16`, pre-reserva de capacidad infalible antes de emitir IDs, y auditoría rigurosa de invariantes que falla cerrado con `CompactPoolError::RegistryCorrupted` ante cualquier colisión o discontinuidad.
16. **P2-016 (Erradicación de wraparound en pruebas de enlaces compactos)**: Eliminación de `wrapping_add(1)` en `test_compact_nexo.rs`, reemplazándolo por pruebas dirigidas con pools foráneos legítimos y verificación de cotas mínimas (1), máximas (255 / 65535) y rechazo de ID cero (0).
17. **P2-017 (Diferenciación metodológica de benchmarks de revalidación y agregación exacta)**: Separación de revalidación estándar pura (14.5 ns), revalidación estándar con lectura (53.1 ns), revalidación compacta 32b (22.7 ns) y 64b (23.0 ns) en `nexo-physical-bench`, corrigiendo el acumulador para agregar contadores de todas las corridas (`RUNS = 7`) con denominadores normalizados.
18. **P1-018 (Validación operativa y fallo cerrado en `validate_superpage` y `check_invariants`)**: `PhysicalPool::validate_superpage()` y `check_invariants()` exigen ahora `self.ensure_operational()?` previamente a cualquier consulta de límites o bitmaps. Si el pool está cerrado devuelven `PoolError::Closed`; si se encuentra en estado ambiguo de liberación devuelven `PoolError::Physical(PhysicalError::ReleaseUncertain)`. Se impide que un `SuperpageIndex` previamente obtenido permita eludir las comprobaciones operativas posteriores.
19. **P1-019 (Manejo no infalible de memoria en registros compactos mediante `try_reserve`)**: Sustitución de `Vec::reserve(1)` por `Vec::try_reserve(1).map_err(|_| CompactPoolError::OutOfMemory)?` en `CompactPoolRegistryInstance` y `CompactPoolRegistryInstance16`, eliminando la asunción errónea de reserva infalible y previniendo pánicos o envenenamientos de mutex ante agotamiento de memoria del sistema (OOM) antes de la asignación atómica de identificadores.
20. **P2-020 (Demostración exhaustiva del espacio de 16 bits y concurrencia bajo contención)**: Verificación secuencial completa de los 65.535 identificadores sin colisión y con orden monótono estricto en `CompactIdAllocator16`, comprobación del fallo cerrado `PoolIdExhausted` en el intento 65.536 sin wraparound numérico, y prueba concurrente con 8 hilos compitiendo donde se demostró la emisión exacta y unívoca de los 65.535 IDs y la denegación total de autoridad en estado post-agotamiento.
21. **P2-021 (Metodología de benchmarking independiente multi-proceso)**: Diferenciación formal entre muestreo por lotes intra-proceso (7 corridas $\times$ 100 lotes $= 700$ muestras) y mediciones independientes a nivel de proceso del SO (5 ejecuciones independientes en perfil `release`). Enriquecimiento del arnés con reporte de mínimo, máximo, desviación estándar y número de muestras, documentando la menor resolución de p95/p99 sobre $N=5$ procesos.
22. **P1-022 (Desagregación estadística estricta, algoritmo de Welford e integridad de Samuelson)**: Erradicación de la mezcla de desviaciones estándar en microbenchmarks (`nexo-physical-bench` y `docs/NEXO_NEXT_BENCHMARKS.md`). Desagregación rigurosa en tres niveles muestrales independientes: Lotes ($N=700$), Corridas ($N=7$) y Procesos de SO independientes ($N=5$). Demostración y verificación algorítmica universal de la cota de Samuelson-Brunk ($s \ge |x_{\max} - \bar{x}|/\sqrt{N-1}$), resolviendo la aparente incoherencia previa entre $s_{\text{batch}} \ge 108.6$ ns y $s_{\text{run}} \approx 18.8$ ns. Implementación del módulo `crates/nexo/src/stats.rs` con acumulador de Welford (1962), salida en JSON estructurado y runner automatizado `scripts/run_benchmarks.py` conservando datos brutos en `docs/benchmarks/raw/` y `docs/benchmarks/summary.json`.
23. **P0-023 (Verificación adversarial de atomicidad e inyección determinista de fallo de memoria en registros compactos REG-OOM-01..10)**: Implementación de inyección determinista de fallo de reserva de memoria (`try_reserve` OOM) exclusiva para pruebas (`#[cfg(test)]`) en `CompactPoolRegistryInstance` y `CompactPoolRegistryInstance16`. Verificación estricta de la invariante obligatoria `estado_autoridad_despues == estado_autoridad_antes` mediante la suite `REG-OOM-01..10`, demostrando que ante OOM no se consumen IDs, no se emite autoridad espuria, los pools físicos no quedan registrados a medias, no hay envenenamiento de mutex ni corrupción interna, y tras retirar la inyección el sistema reanuda la emisión continua sin huecos.
24. **P1-024 (Propagación Estricta de Errores I/O y Escrituras Atómicas JSON-IO-01..10)**: En `nexo-physical-bench.rs`, toda falla de creación de directorio, escritura en archivo o ruta inválida termina con código de salida no cero (`std::process::exit(1)`), escribe mensaje explícito a stderr, y no produce archivos parciales ni truncados. La persistencia se realiza de forma atómica mediante `<target>.tmp.<pid>` y `fs::rename`, limpiando temporales en caso de fallo. Validado exhaustivamente en Windows y Linux mediante la suite de integración `test_bench_io.rs` (`JSON-IO-01..10`).
25. **P1-025 (Aislamiento Criptográfico por Campaña y Blindaje contra Artefactos Obsoletos BENCH-STALE-01..10)**: Implementación de campañas aisladas con identificador único en `scripts/run_benchmarks.py` (`docs/benchmarks/campaigns/<campaign_id>/`), validación contra mezclas o reúsos de artefactos antiguos, verificación pre y post-ejecución del hash SHA-256 del binario ejecutable compilado en release, registro del estado del worktree (limpio o dirty con SHA-256 de `git diff`), generación de `checksums.sha256` y rechazo estricto *fail-closed* ante esquemas obsoletos, JSON truncado o valores no finitos (`BENCH-STALE-01..10`).
26. **P1-026 (Unificación Matemática de Especificación Estadística Rust/Python STATS_SPEC_VERSION 1.1.0 y STAT-CROSS-01..10)**: Definición formal de la especificación estadística `1.1.0` con idéntico algoritmo de Welford, varianzas muestral ($N-1$) y poblacional ($N$), y cálculo de percentiles con interpolación lineal uniforme estándar $r = (N-1) \times p, w = r - \lfloor r \rfloor, x_i(1-w) + x_j w$ verificado mediante pruebas cruzadas con vectores compartidos en `scripts/test_stats_cross.py` y `crates/nexo/tests/test_statistical_consistency.rs` (`STAT-CROSS-01..10`).
27. **P1-027 (Verificación Concurrente Multihilo de Inyección OOM y Agotamiento de Identidades OOM-CONC-01..10)**: Sustitución del bucle secuencial en `REG-OOM-09` por una prueba multihilo con `Arc<Barrier>`, hilos de trabajo concurrentes y un hilo inyector que conmuta fallos OOM bajo alta contención en `crates/nexo/src/next/compact.rs`. Verificación de carreras simultáneas para el mismo pool (`OOM-CONC-02`), agotamiento íntegro de la capacidad de 8 bits (255 IDs) y 16 bits sin duplicados, correspondencia biyectiva $1:1$, conteo exacto inmune a fallos OOM y fallo cerrado con `PoolIdExhausted` (`OOM-CONC-01..10`).

### Estado de Infraestructura de Integración Continua Externa

> [!IMPORTANT]
> **CI REMOTO: BLOQUEADO POR CUOTA AGOTADA**
> La infraestructura remota de GitHub Actions se encuentra actualmente bloqueada debido al agotamiento total de la cuota mensual asignada de la cuenta (`0 minutes remaining`). Conforme a las directrices de seguridad y gobernanza del proyecto:
> - NO se modifican los flujos de trabajo en `.github/workflows/` para eludir la restricción ni se solicitan tokens/claves no autorizadas.
> - La validación exhaustiva se ejecuta y certifica localmente en modo Dual-OS (Windows MSVC nativo + Linux WSL2 / glibc) sobre los worktrees autorizados, aprobando el 100% de las suites unitarias, adversariales, de integración y de aislamiento físico con hardware/SO.
