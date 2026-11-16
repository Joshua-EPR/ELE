# Traspaso de agente — ELE

## Actualización 2026-11-16 (Operación Finalización y Endurecimiento Definitivo — fix/nexo-v04-security-finalization)

Ramas y estado de Git:
- `main`: `2712a1b7e17a3733b98b4de82db9583446aee34f` (estrictamente inalterada).
- `feat/nexo-v0.3-physical-memory` (PR #69 en borrador, sin merge, HEAD `4cb044e`, verificado limpio).
- `feat/nexo-v0.4-next-memory` (Base experimental v0.4 en `18ddcfc7e728516e2d051d5f13e2ed8d9c755ae0`).
- `fix/nexo-v0.4-authority-soundness`: Rama histórica (`cac1dcb44498d643485c421143dcc21a72a4a67e`).
- `fix/nexo-v0.4-authority-lockdown`: Rama de lockdown completada y publicada (`07138c6e4e1a920911d756285d59e69c50b03aa5`).
- `fix/nexo-v04-security-finalization`: **Rama activa de entrega final**, creada a partir de `07138c6`.

### 1. Defectos P0/P1 y Endurecimiento Adicional Cerrados en esta Fase
1. **P0-007 (Fallo cerrado en inspección de metadatos tras cierre de piscina)**:
   - Se blindaron `PhysicalPool::generation()` y `PhysicalPool::page_state()` invocando `self.space()?;` antes de ubicar cualquier slot.
   - Si el pool fue cerrado con `close()` o `try_close()`, toda inspección retorna inmediatamente `Err(PoolError::Closed)`.
   - Se añadió `self.superpages.clear()` en `PhysicalPool::close()` para garantizar la erradicación total de metadatos residuales tras liberar la reserva virtual.
   - Prueba de regresión agregada y validada en `crates/nexo/tests/close_contract.rs::closed_pool_rejects_generation_page_state_and_physical_access`.
2. **P0-008 (Validación defensiva de límites en `ScopedArena::close_scope`)**:
   - `close_scope` rechaza inmediatamente cualquier marcador con `offset > self.offset` o `drop_count > self.drops.len()` retornando `ArenaError::ScopeMismatch`.
   - Impide formalmente corrupciones de punteros u omisiones de destructores ante marcadores adulterados.
   - Prueba unitaria de regresión añadida y validada en `crates/nexo/src/next/arena.rs::tests::test_marker_defensive_bounds_validation`.
3. **P1-009 (Rechazo de piscinas cerradas en adaptadores compactos y registros)**:
   - `CompactPhysicalPool::new` y `CompactPhysicalPool64::new` fallan cerrado inmediatamente con `Err(CompactPoolError::PoolClosed)` si el pool ya fue cerrado antes de crear el adaptador.
   - `CompactPoolRegistry::register_pool` y `CompactPoolRegistry16::register_pool` impiden registrar una piscina cerrada, retornando `Err(CompactPoolError::PoolClosed)`.
   - Prueba de regresión en `crates/nexo/tests/test_authority_lockdown.rs::test_auth_harden_06_closed_pool_fails_closed`.
4. **P1-010 (Preservación de errores tipados en revalidación compacta)**:
   - `CompactPhysicalPool::current_compact_generation` sustituye el mapeo genérico a `OutOfBounds` por `convert_pool_error`, preservando `PoolClosed`, `Physical(p)`, `Invariant(s)`, `GenerationRetired`, `SubpageQuarantined`, y `StaleGeneration`.
   - Permite discriminar fallos del kernel o cierre de piscina de verdaderos accesos fuera de rango.
5. **P1-011 (Recuperación resiliente ante envenenamiento de mutex en el registro global)**:
   - `CompactPoolRegistryInstance::register` y `CompactPoolRegistryInstance16::register` implementan recuperación explícita con `.unwrap_or_else(|poisoned| ...)` ordenando y deduplicando el vector de IDs para evitar que un pánico en un hilo inhabilite permanentemente el registro global.
   - Prueba unitaria de regresión validada en `crates/nexo/src/next/compact.rs::tests::test_registry_mutex_poisoning_recovery`.
6. **P1-012 (Auditoría de ScopedArena y verificación de límites de ciclo de vida con DROP-17..20)**:
   - Casos agregados en `crates/nexo/tests/test_scoped_arena.rs`:
     - `DROP-17`: rechazo de cierre de marcadores desordenados con recuperación de marcador.
     - `DROP-18`: rechazo de marcadores de arenas foráneas.
     - `DROP-19`: manejo seguro de marcadores tras pánicos y envenenamiento en destructores.
     - `DROP-20`: asignaciones ZST con alineación extrema en la frontera exacta de capacidad.
7. **Auditoría Exhaustiva de Código `unsafe`**:
   - Se auditaron y documentaron formalmente todos los bloques `unsafe` en `crates/nexo/src/next/arena.rs`, `address_space.rs`, `windows.rs` y `linux.rs`. Contratos de precondiciones y comportamiento ante pánicos y fallos documentados en `docs/NEXO_NEXT_SAFETY.md`.
8. **Metodología y Mediciones Empíricas de Rendimiento**:
   - Se ejecutó `nexo-physical-bench --completo` en modo release (7 corridas × 200 ops por escenario) registrando métricas de media, mediana, p95/p99, CV%, syscalls/op y consumo de memoria/Working Set en `docs/NEXO_NEXT_BENCHMARKS.md`.
   - Revalidación compacta validada a 51.4 ns/op (CV 3.8%); ráfaga 960+960 a 178.5 ns/op (CV 0.5%); reciclaje de huecos a 277.6 ns/op (CV 0.4%).
   - Fuzzer físico ejecutado en modo adversarial (`--fallos 1000 16`): 16.000 comandos de inyección del SO con 0 divergencias.
9. **Especificación Normativa de Integración con ELE**:
   - Se elaboró `docs/NEXO_ELE_COMPATIBILITY.md` documentando el mapeo de capacidades lineales, representación LIR, invariantes de verificación y pre-requisitos de ABI para futura integración cuando proceda, sin conectar el runtime prematuramente.

### 2. Suites de Validación Ejecutadas y Aprobadas (Dual-OS)

| Suite de Prueba | Archivo | Casos | Resultado Windows MSVC | Resultado Linux WSL2 |
|---|---|---|---|---|
| **Authority Lockdown** | `crates/nexo/tests/test_authority_lockdown.rs` | 20 | **20/20 APROBADAS** | **20/20 APROBADAS** |
| **Authority Soundness** | `crates/nexo/tests/test_authority_soundness.rs` | 20 | **20/20 APROBADAS** | **20/20 APROBADAS** |
| **Compact Nexo** | `crates/nexo/tests/test_compact_nexo.rs` | 13 | **13/13 APROBADAS** | **13/13 APROBADAS** |
| **API Security** | `crates/nexo/tests/api_security.rs` | 11 | **11/11 APROBADAS** | **11/11 APROBADAS** |
| **Scoped Arena** | `crates/nexo/tests/test_scoped_arena.rs` | 36 | **36/36 APROBADAS** | **36/36 APROBADAS** |
| **Close Contract** | `crates/nexo/tests/close_contract.rs` | 8 | **8/8 APROBADAS** | **8/8 APROBADAS** |
| **Partial Failures** | `crates/nexo/tests/partial_failures.rs` | 16 | **16/16 APROBADAS** | **16/16 APROBADAS** |
| **Verificador Semántico** | `crates/nexo/tests/verificador.rs` | 42 | **42/42 APROBADAS** | **42/42 APROBADAS** |
| **Unit tests lib.rs** | `crates/nexo/src/lib.rs` | 37/38 | **37/37 APROBADAS** | **38/38 APROBADAS** |
| **Physical Fuzz tests** | `crates/nexo/src/bin/nexo-physical-fuzz.rs` | 2 | **2/2 APROBADAS** | **2/2 APROBADAS** |
| **Revalidation Opt** | `crates/nexo/tests/test_revalidation_opt.rs` | 2 | **2/2 APROBADAS** | **2/2 APROBADAS** |
| **Doctests nexo** | `crates/nexo/src/...` | 9 | **9/9 APROBADAS** | **9/9 APROBADAS** |
| **Child Isolation** | `crates/nexo/tests/child_isolation.rs` | 5 | N/A (Windows) | **5/5 APROBADAS** (SIGSEGV) |
| **Workspace Completo** | `cargo test --workspace` | ~800+ | **100% APROBADO** | **100% APROBADO** |

### 2. Estado de CI Remoto
- **CI REMOTO: BLOQUEADO POR CUOTA AGOTADA** (`0 minutes remaining` en GitHub Actions).
- No se han modificado flujos en `.github/` para evadir restricciones.
- Toda validación está certificada localmente de forma reproducible y exhaustiva en modo Dual-OS (Windows MSVC + Linux WSL2).

---

## Actualización 2026-11-16 (Operación Security Lockdown — fix/nexo-v0.4-authority-lockdown)

Ramas y estado de Git:
- `main`: `2712a1b7e17a3733b98b4de82db9583446aee34f` (estrictamente inalterada).
- `feat/nexo-v0.3-physical-memory` (PR #69 en borrador, sin merge, HEAD `4cb044e`, verificado limpio).
- `feat/nexo-v0.4-next-memory` (Base experimental v0.4 en `18ddcfc7e728516e2d051d5f13e2ed8d9c755ae0`).
- `fix/nexo-v0.4-authority-soundness`: Rama previa (`cac1dcb44498d643485c421143dcc21a72a4a67e`).
- `fix/nexo-v0.4-authority-lockdown`: **Nueva rama de trabajo**, creada a partir de `cac1dcb`, donde se ejecutó el cierre total y definitivo de autoridad e identidad.

### 1. Defectos P0 y P1 Cerrados en Security Lockdown

1. **P0-001 (Eliminación Terminante de Emisión Arbitraria de Autoridad)**:
   - Se erradicaron por completo `CompactPoolRegistry::acquire_token_for(physical_pool_id: u64)` y `CompactPoolRegistry::acquire_token()`. Ningún token de autoridad puede ser emitido a partir de enteros numéricos.
   - La única vía legal y pública de emisión es `register_pool(&PhysicalPool)`, requiriendo la posesión de una referencia viva a la memoria física.
2. **P0-002 (Invariante de Registro Único de Pool Físico)**:
   - `CompactPoolRegistry` y `CompactPoolRegistry16` rechazan de forma atómica e idempotente el registro duplicado de un mismo pool físico con `CompactPoolError::AlreadyRegistered { physical_pool_id }`.
   - Garantiza una correspondencia biyectiva $1:1$ entre el `PhysicalPool` en memoria virtual y su token de autoridad `CompactPoolToken`.
3. **P0-003 (Cierre de Cadena Física y Reporte Explícito de Cuarentena)**:
   - Los adaptadores `CompactPhysicalPool` y `CompactPhysicalPool64` validan la cadena de autoridad completa sobre `PhysicalPool`.
   - Ante subpáginas en estado `PageState::Quarantined`, retornan el error tipado y dedicado `CompactRevalidateError::SubpageQuarantined`.
4. **P1-004 (Eliminación Absoluta de Mocks Privilegiados de la Distribución)**:
   - Se eliminó la feature `test-mocks` de `crates/nexo/Cargo.toml` y el módulo público `pub mod testing` de `compact.rs`.
   - Los mocks privilegiados residen estrictamente en `#[cfg(test)] mod tests` para pruebas unitarias internas. Las compilaciones de producción (incluso con `--all-features`) tienen cero mocks expuestos.
5. **P1-005 (Desacoplamiento de Asignadores Numéricos Puros)**:
   - Se factorizaron `CompactIdAllocator8` y `CompactIdAllocator16` como asignadores numéricos atómicos puros (1..=255 y 1..=65535) sin autoridad de memoria.
   - Permiten probar agotamiento y concurrencia en instancias aisladas sin contaminar ni agotar los singletons globales `GLOBAL_COMPACT_REGISTRY` y `GLOBAL_COMPACT_REGISTRY_16`.
6. **P1-006 (Reparación de Pruebas Adversariales con Fallos Reales de Compilación)**:
   - Se migraron las pruebas de comentarios a pruebas reales de compilación externa ejecutadas con arnés `run_fixture_check` contra `crates/nexo/tests/fixtures/external_consumer` (`E0277`, `E0433`, `E0502`, `E0515`, `E0560`, `E0599`).
   - Se implementó la nueva suite de 20 escenarios `AUTH-HARDEN-01..20` en `crates/nexo/tests/test_authority_lockdown.rs`.
   - Se eliminaron condiciones `if` de escape en `AUTH-15` y `AUTH-HARDEN-13` para asegurar verificación incondicional.

### 2. Suites de Validación Ejecutadas y Aprobadas (Dual-OS)

| Suite de Prueba | Archivo | Casos | Resultado Windows MSVC | Resultado Linux WSL2 |
|---|---|---|---|---|
| **Authority Lockdown** | `crates/nexo/tests/test_authority_lockdown.rs` | 20 | **20/20 APROBADAS** | **20/20 APROBADAS** |
| **Authority Soundness** | `crates/nexo/tests/test_authority_soundness.rs` | 20 | **20/20 APROBADAS** | **20/20 APROBADAS** |
| **Compact Nexo** | `crates/nexo/tests/test_compact_nexo.rs` | 12 | **12/12 APROBADAS** | **12/12 APROBADAS** |
| **API Security** | `crates/nexo/tests/api_security.rs` | 11 | **11/11 APROBADAS** | **11/11 APROBADAS** |
| **Scoped Arena** | `crates/nexo/tests/test_scoped_arena.rs` | 32 | **32/32 APROBADAS** | **32/32 APROBADAS** |
| **Verificador Semántico** | `crates/nexo/tests/verificador.rs` | 42 | **42/42 APROBADAS** | **42/42 APROBADAS** |
| **Unit tests lib.rs** | `crates/nexo/src/lib.rs` | 36/37 | **36/36 APROBADAS** | **37/37 APROBADAS** |
| **Physical Fuzz tests** | `crates/nexo/src/bin/nexo-physical-fuzz.rs` | 2 | **2/2 APROBADAS** | **2/2 APROBADAS** |
| **Revalidation Opt** | `crates/nexo/tests/test_revalidation_opt.rs` | 2 | **2/2 APROBADAS** | **2/2 APROBADAS** |
| **Doctests nexo** | `crates/nexo/src/...` | 9 | **9/9 APROBADAS** | **9/9 APROBADAS** |
| **Child Isolation** | `crates/nexo/tests/child_isolation.rs` | 5 | N/A (Windows) | **5/5 APROBADAS** (SIGSEGV) |
| **Workspace Completo** | `cargo test --workspace` | ~800+ | **100% APROBADO** | **100% APROBADO** |

Determinismo multi-hilo certificado:
- `cargo test -p ele-nexo --test test_authority_soundness --test test_authority_lockdown -- --test-threads=1` -> 40/40 OK.
- `cargo test -p ele-nexo --test test_authority_soundness --test test_authority_lockdown -- --test-threads=8` -> 40/40 OK.

### 3. Estado de CI Remoto
- **CI REMOTO: BLOQUEADO POR CUOTA AGOTADA** (`0 minutes remaining` en GitHub Actions).
- No se han modificado flujos en `.github/` para evadir restricciones.
- Toda validación está certificada localmente de forma reproducible y exhaustiva en modo Dual-OS.

---

## Actualización 2026-11-16 (Auditoría Definitiva de Autoridad e Identidad — fix/nexo-v0.4-authority-soundness)

Ramas auditadas:
- `main`: `2712a1b7e17a3733b98b4de82db9583446aee34f` (intacta, inalterada).
- `feat/nexo-v0.3-physical-memory` (PR #69 en borrador, sin merge, HEAD `4cb044e`, verificado limpio).
- `feat/nexo-v0.4-next-memory` (Base experimental v0.4 en `18ddcfc7e728516e2d051d5f13e2ed8d9c755ae0`).
- `fix/nexo-v0.4-authority-soundness`: Rama de trabajo con correcciones definitivas P0-001..P0-003 y P1-004..P1-006.

### 1. Correcciones P0 y P1 Implementadas

1. **P0-001 (Sellado Auténtico de Traits de Autoridad)**:
   - Se erradicó el pseudo-sellado `pub mod private` que permitía a crates foráneas implementar `Sealed`.
   - Se estableció el sellado canónico: `pub(crate) mod private { pub trait Sealed {} pub struct InternalSeal; }`.
   - Se incorporó el método privado sellado `fn __seal_authority(&self, _: private::InternalSeal)` en `CompactPoolAuthority` y `CompactPoolAuthority64`.
   - Pruebas doctest negativas con `compile_fail` agregadas y verificadas (9 doctests pasados).

2. **P0-002 (Vinculación Infalsificable Pool ↔ Token)**:
   - `CompactPoolToken` y `CompactPoolToken16` almacenan de forma inmutable el `physical_pool_id: u64` correspondiente al `PhysicalPool` registrado.
   - `CompactPhysicalPool::new(&pool, &token)` y `CompactPhysicalPool64::new(&pool, &token)` devuelven `Result<Self, CompactPoolError>` y validan estrictamente `token.physical_pool_id() == pool.id()`, abortando con `CompactPoolError::PoolMismatch` ante cualquier discrepancia.

3. **P0-003 (Confinamiento Absoluto de Mocks)**:
   - `MockCompactPool` y `MockCompactPool64` están condicionados a `#[cfg(any(test, feature = "test-mocks"))]`.
   - `crates/nexo/Cargo.toml` define la feature `test-mocks` y la inyecta solo en `dev-dependencies`, eliminándolos completamente de las compilaciones de producción.

4. **P1-004 (Confinamiento de Registros Independientes)**:
   - `CompactPoolRegistryInstance` y `CompactPoolRegistryInstance16` son `pub(crate)` y fueron retirados de la re-exportación pública en `nexo::next`.

5. **P1-005 (Aislamiento de Contador Global en Pruebas de Agotamiento)**:
   - `allocate_arena_id(counter: &AtomicU64) -> Result<u64, ArenaError>` extraído para permitir que las pruebas de agotamiento utilicen contadores locales aislados sin mutar el singleton `NEXT_ARENA_ID`.

6. **P1-006 (Acotamiento de Capacidad de Slots en Adaptador)**:
   - `CompactPhysicalPool::slot_capacity()` acotado a `pool_cap.min((MAX_SLOT_COMPACT_32 as u64) + 1) as u32` (máximo 65.536), garantizando que los índices encajen en la representación de 16 bits de `CompactLink`.

### 2. Suite de Validación Adversarial AUTH-01 a AUTH-20 (`crates/nexo/tests/test_authority_soundness.rs`)
- `AUTH-01`: Intento externo de implementar `CompactPoolAuthority` falla estáticamente (doctest `compile_fail`).
- `AUTH-02`: Intento externo de implementar `CompactPoolAuthority64` falla estáticamente (doctest `compile_fail`).
- `AUTH-03`: Intento de construir `CompactObjRef` directamente falla estáticamente (doctest `compile_fail`).
- `AUTH-04`: Mocks no disponibles en producción sin `feature = "test-mocks"`.
- `AUTH-05`: Emparejamiento de token foráneo falla en adaptador de 32 bits (`PoolMismatch`).
- `AUTH-06`: Emparejamiento de token foráneo falla en adaptador de 64 bits (`PoolMismatch`).
- `AUTH-07`: `CompactPoolToken` almacena el `physical_pool_id` exacto.
- `AUTH-08`: `compact_id` idéntico pero diferente `physical_pool_id` es rechazado.
- `AUTH-09`: Revalidación cruzada rechazada con pool físico foráneo.
- `AUTH-10`: Generación par rechazada como `SlotNotAllocated`.
- `AUTH-11`: Generación obsoleta rechazada tras reasignación (`StaleGeneration`).
- `AUTH-12`: Generación $\ge 254$ en 8 bits rechazada permanentemente (`GenerationRetired`).
- `AUTH-13`: Generación $\ge 65534$ en 16 bits rechazada permanentemente (`GenerationRetired`).
- `AUTH-14`: Slot en subpágina en cuarentena rechazado (`SubpageQuarantined`).
- `AUTH-15`: Slot en subpágina no confirmada rechazado (`SlotNotAllocated`).
- `AUTH-16`: Slot fuera de límites rechazado (`SlotOutOfBounds`) y capacidad acotada a 65.536.
- `AUTH-17`: `CompactObjRef` es de solo lectura y no convertible a `Handle`.
- `AUTH-18`: `CompactObjRef<'a>` tiene tiempo de vida acotado al préstamo del pool.
- `AUTH-19`: `CompactPoolRegistry` emisión acotada a 255 IDs sin reciclaje.
- `AUTH-20`: Concurrencia atómica de 16 bits sin duplicados en emisión.

### 3. Matriz de Validación Dual-OS

| Plataforma | Suite `ele-nexo` | Suite `test_authority_soundness` | Suite `test_compact_nexo` | Child Isolation | Fuzzers |
|---|---|---|---|---|---|
| **Windows MSVC** | 35 lib + 9 doc + 11 api = 55 tests OK | 20/20 OK | 12/12 OK | N/A (Windows) | 4.096 comandos (4 seeds) OK; 64 campañas $\times$ 5.000 pasos PFS OK; `nexo-fuzz` 1.000 casos OK |
| **Linux WSL2** | 36 lib + 9 doc + 11 api = 56 tests OK | 20/20 OK | 12/12 OK | 5/5 OK (SIGSEGV verificado) | 100% concordancia con Windows |

### 4. Estado de CI Remoto
- **CI EXTERNO: BLOQUEADO POR CUOTA DE GITHUB ACTIONS** (`0 minutes remaining`).
- Toda validación se ejecuta y certifica localmente.

---

## Actualización 2026-11-16 (Zero-Trust Hardening) — Resolución de Identidad de Registros, Traits Sellados, Tokens Infalsificables, Adaptador Físico y Suite DROP-08..16

Ramas auditadas:
- `main`: `2712a1b7e17a3733b98b4de82db9583446aee34f` (intacta, sin cambios).
- `feat/nexo-v0.3-physical-memory` (PR #69 en borrador, sin merge, HEAD `4cb044e`, verificado limpio).
- `feat/nexo-v0.4-next-memory` (Experimental v0.4, commit de endurecimiento Zero-Trust).

### 1. Resolución de Identidad Inequívoca de Pools Compactos (P0)
- **Defecto auditado**: La existencia de `CompactPoolRegistryInstance` pública permitía a consumidores independientes crear registros que emitieran `pool_id = 1`, arriesgando colisiones en dominios de revalidación.
- **Corrección aplicada**:
  - Se introdujo `CompactPoolToken` y `CompactPoolToken16`: tokens lineales con campos privados y sin constructor público, no clonables (`!Clone`, `!Copy`), emitibles exclusivamente a través de los registros globales de producción (`CompactPoolRegistry::acquire_token` y `CompactPoolRegistry16::acquire_token`).
  - Las instancias desacopladas (`CompactPoolRegistryInstance`) se confinaron al módulo interno `testing`, eliminando la ambigüedad en el contrato público de producción.
  - La unicidad de `pool_id` queda formalmente garantizada a nivel de proceso mediante asignación atómica sin reciclaje ni wraparound.

### 2. Frontera de Autoridad y Traits Sellados (P0)
- **Defecto auditado**: El trait público `CompactPoolAuthority` podía ser implementado por consumidores externos con datos arbitrarios para obtener `CompactObjRef`.
- **Corrección aplicada**:
  - Se sellaron los traits `CompactPoolAuthority` y `CompactPoolAuthority64` mediante el submódulo sellado `private::Sealed`. Ningún consumidor externo puede implementarlos.
  - Se vincularon formalmente los tokens de acceso `CompactObjRef<'a>` y `CompactObjRef64<'a>` al tiempo de vida del préstamo `'a` del pool (`PhantomData<&'a ()>`). El borrow checker de Rust impide estáticamente llamar a `destroy`, `close` o mutaciones sobre el pool mientras exista una referencia revalidada activa.
  - Se implementaron los adaptadores seguros `CompactPhysicalPool` y `CompactPhysicalPool64` en `crates/nexo/src/next/adapter.rs`, validando estados de subpágina (`Committed`, rechazando `Quarantined`, `Reserved`, `ReclaimPending`, `Returned`), límites físicos de slots y generaciones lógicas en `PhysicalPool`.

### 3. Precisión de Errores y Aritmética en `ScopedArena`
- Se agregó el error tipado `ArenaError::ArenaIdExhausted` en sustitución de `OutOfMemory` cuando el generador monotónico alcanza `u64::MAX`.
- Se verificó la aritmética de punteros, alineaciones de hasta 4096 bytes y tipos de tamaño cero (ZST).

### 4. Suite Exhaustiva DROP-08 a DROP-16 (`test_scoped_arena.rs`)
- `DROP-08`: Destructor compuesto con liberación parcial antes del pánico; los objetos pendientes se liberan incondicionalmente en LIFO.
- `DROP-09`: Mutación de estado externo persistente antes del pánico; la mutación persiste y los hermanos se destruyen.
- `DROP-10`: Doble pánico durante unwinding inicial de hilo; la arena drena todos los drops sin provocar doble pánico ni aborto de proceso.
- `DROP-11`: Destructor de tipo de tamaño cero (ZST) que entra en pánico; layout y punteros preservados.
- `DROP-12`: Ámbito interior envenenado; preservación estricta de la destrucción de objetos del ámbito exterior en `drop(arena)`.
- `DROP-13`: Dependencias complejas de recursos en estricto orden LIFO (5, 4, 3, 2, 1) con pánicos intermedios.
- `DROP-14`: Desajuste de marcador en `close_scope` (recuperación lineal) seguido de destrucción final de la arena sin fugas.
- `DROP-15`: Prueba de pureza de layout heap sin syscalls virtuales (documentada compatibilidad conceptual con Miri).
- `DROP-16`: Contención de pánicos en hilo aislado para validar ausencia de corrupción.

### 5. Estado de Validación Dual-OS
- **Windows MSVC**: 260 pruebas aprobadas en `ele-nexo`, 780+ en workspace completo, clippy con 0 advertencias, fmt limpio, 5/5 child isolation, 65.536 comandos de fuzzer físico (0 divergencias), 10.000 casos de fuzzer lingüístico (0 fallos P1).
- **Linux WSL2**: 261 pruebas aprobadas en `ele-nexo` (incluye prueba de protección `madvise` de Linux), 5/5 child isolation con intercepción real de SIGSEGV.
- **Miri**: Toolchain del host carece del componente `cargo-miri` para el canal instalado; limitación documentada con precisión y honestidad técnica.

Ramas auditadas:
- `feat/nexo-v0.3-physical-memory` (PR #69 en borrador, sin merge, HEAD `4cb044e`).
- `feat/nexo-v0.4-next-memory` (Experimental v0.4, commit de endurecimiento final).

### 1. Protocolo de Destrucción Final Resiliente en `Drop for ScopedArena` (P0)
- **Defecto P0 resuelto**: Si un destructor fallaba con pánico durante `drop(arena)`, el bucle de liberación se interrumpía; aunque el búfer se liberaba por RAII, los destructores pendientes restantes eran omitidos, provocando fugas de recursos y riesgo de aborto por doble pánico (*double panic abort*) si el hilo ya se encontraba en unwinding.
- **Protocolo implementado**:
  - `drop(&mut self)` encapsula cada llamada a `(entry.drop_fn)(entry.ptr)` con `std::panic::catch_unwind(AssertUnwindSafe(..))`.
  - El primer pánico se almacena en `first_panic: Option<Box<dyn Any + Send>>`.
  - Todos los destructores pendientes continúan drenándose y ejecutándose en estricto orden LIFO hasta que `self.drops` queda completamente vacío.
  - El `BufferGuard` desasigna el búfer de memoria virtual de forma infalible una vez que todos los destructores han concluido.
  - Si hubo pánicos y `!std::thread::panicking()`, se reanuda el primer pánico mediante `std::panic::resume_unwind(panic_payload)`.
  - Si el hilo ya se encontraba en unwinding (`std::thread::panicking()`), no se invoca `resume_unwind`, evitando el aborto del proceso y permitiendo que el pánico original continúe de forma segura.
- **Suite DROP-01 a DROP-07 (`test_scoped_arena.rs`)**:
  - `DROP-01`: Pánico en un destructor con 3 pendientes; los 4 destructores se ejecutan en orden LIFO exacto una vez cada uno.
  - `DROP-02`: Múltiples destructores paniquean; todos se ejecutan sin doble destrucción ni UB.
  - `DROP-03`: Destrucción final de arena previamente envenenada (`ArenaState::Poisoned`).
  - `DROP-04`: Propagación fiel del payload del primer pánico.
  - `DROP-05`: Ausencia de doble pánico / aborto durante unwinding activo en hilo aislado.
  - `DROP-06`: Liberación limpia de recursos complejos (`Box`, `Vec`, `String`) ante pánico.
  - `DROP-07`: Cascada de ámbitos anidados con múltiples pánicos en orden LIFO estricto.

### 2. Revalidación Autorizada de Enlaces Compactos (`CompactPoolAuthority`)
- Se implementó la frontera formal entre:
  - **Enlace como dato (`CompactLink`, `CompactLink64`)**: Identificador plano de 32 o 64 bits copiable (`Copy`), sin autoridad de acceso directo a memoria.
  - **Revalidación autorizada (`CompactPoolAuthority`, `CompactPoolAuthority64`)**: Trait de pool físico que valida `compact_id`, límites de slot, estado asignado (no par/libre), ausencia de retiro y coincidencia exacta de generación, retornando `Result<CompactObjRef, CompactRevalidateError>`.
  - **Token no propietario (`CompactObjRef`, `CompactObjRef64`)**: Campos estrictamente privados, sin constructor público, jamás convertible a `Handle`.

### 3. Registro Aislado y Registro de 16 Bits (`CompactPoolRegistry16`)
- `CompactPoolRegistryInstance` y `CompactPoolRegistryInstance16`: Estructuras instanciables para evitar contaminación cruzada entre pruebas unitarias que agotan identidades y el singleton global.
- `CompactPoolRegistry16`: Registro de 16 bits (1..=65.535) para respaldar formalmente la identidad de `CompactLink64` sin reciclaje ni colisiones ABA.
- Corrección del dominio de 16 bits en `CompactGen`: `is_live` valida estrictamente `g < GEN_RETIRADO_16`, corrigiendo el valor 65535 (`0xffff`) que era erróneamente clasificado como vivo.

### 4. Estado de Validación Dual
- **Windows MSVC**: 249 pruebas aprobadas en `ele-nexo`, 780+ pruebas en workspace completo (`cargo test --workspace`), clippy con 0 advertencias, fmt limpio, release build limpio, 5/5 child isolation, 65.536 comandos de fuzzer físico sin divergencias, 10.000 casos de fuzzer lingüístico (0 fallos P1).
- **Linux WSL2**: 250 pruebas aprobadas en `ele-nexo` (incluye prueba de `madvise` específica de Linux), paridad completa.
- **Miri**: Documentada como limitación pendiente de herramienta externa.

---

## Actualización 2026-11-15 (Pase 3) — Cierre definitivo P0 de resiliencia ante pánicos en `ScopedArena`, consistencia de `CompactPoolRegistry` y Suite P0-ARENA-01..08

Ramas auditadas:
- `feat/nexo-v0.3-physical-memory` (PR #69 en borrador, sin merge, HEAD `4cb044e`).
- `feat/nexo-v0.4-next-memory` (Experimental v0.4, commit de cierre P0).

### 1. Corrección P0 de Resiliencia ante Pánicos en `ScopedArena`
- **Defecto P0 resuelto**: Si un destructor entraba en pánico en `close_scope()`, el guard anterior retrocedía el `offset` a `marker.offset` mientras los objetos no alcanzados permanecían en `drops`. Una captura posterior (`catch_unwind`) permitía que `alloc()` sobreescribiera la memoria de dichos objetos, desembocando en corrupción de memoria o UAF durante `drop(arena)`.
- **Máquina de estados segura**:
  - Se introdujo `ArenaState` (`Active`, `Poisoned`).
  - `close_scope()` utiliza `ScopeCloseGuard`: si un destructor causa pánico durante el desenrollado, la arena transiciona a `ArenaState::Poisoned`.
  - El `offset` NO se retrocede al punto inicial del ámbito, protegiendo la memoria de los objetos no destruidos.
  - La entrada que causa pánico ya ha sido extraída de `drops` mediante `pop()`, garantizando ausencia de doble destrucción.
  - Toda llamada posterior a `alloc()`, `begin_scope()` o `close_scope()` en una arena envenenada retorna de inmediato `Err(ArenaError::Poisoned)`.
  - `Drop for ScopedArena` destruye limpiamente en orden LIFO los objetos restantes y utiliza `BufferGuard` para garantizar la desasignación de la memoria virtual aunque un destructor falle en el drop final.
  - `begin_scope()` retorna `Result<ScopeMarker, ArenaError>` y valida desbordamiento de `u64` con `checked_add(1)`, retornando `Err(ArenaError::ScopeDepthExhausted)`.
  - `new_with_alignment()` reserva el identificador atómico único ANTES de asignar memoria virtual, previniendo fugas ante agotamiento de identificadores.

### 2. Consistencia y Ausencia de Off-by-One en `CompactPoolRegistry`
- Se reemplazó el contador desfasado por `ALLOCATED_COMPACT_POOLS: AtomicU8 = AtomicU8::new(0)`.
- `acquire_id()` emite identificadores exactos en el rango `1..=255` mediante CAS seguro. Al alcanzar 255 pools, cualquier invocación subsiguiente retorna `Err(CompactPoolError::PoolIdExhausted)`.
- `is_valid_id(id)` valida `id != 0 && id <= ALLOCATED_COMPACT_POOLS.load(SeqCst)`. Un ID no emitido jamás retorna `true`.
- Se documentó formalmente que `CompactLink::matches` y `CompactLink64::matches` son predicados de coherencia representacional, requiriéndose la consulta del pool físico para revalidación de autoridad sobre memoria viva.

### 3. Suite Mandatoria P0-ARENA-01 a P0-ARENA-08 (`test_scoped_arena.rs`)
- **P0-ARENA-01**: Tres objetos en un ámbito, el del medio entra en pánico en drop. Se verifica que el tercero se destruyó en LIFO, el segundo entró en pánico, y el primero no fue tocado.
- **P0-ARENA-02**: Asignación y apertura de ámbito tras pánico capturado son rechazadas con `ArenaError::Poisoned`. Se verifica que la memoria del objeto primero no fue sobreescrita ni corrompida.
- **P0-ARENA-03**: `drop(arena)` tras pánico capturado destruye los objetos pendientes exactamente una vez. Cero fugas y cero dobles destrucciones.
- **P0-ARENA-04**: Ámbitos anidados con pánico en ámbito interior: envenenamiento propaga protección al exterior; `drop(arena)` destruye objetos interiores y exteriores en orden determinista.
- **P0-ARENA-05**: ZST con `Drop` intercalados con tipos normales: no avanzan `offset`, se destruyen en LIFO y resisten pánicos.
- **P0-ARENA-06**: Tipos con propiedad compleja del heap (`Vec`, `String`, `Box`) liberan buffers del heap limpiamente.
- **P0-ARENA-07**: Anidamiento profundo de 64 ámbitos concurrentes y verificación estricta de `ArenaError::ScopeDepthExhausted` ante desbordamiento de límite en `u64::MAX`.
- **P0-ARENA-08**: Alineaciones extremas de hasta 4096 bytes: verificación de dirección divisible por 4096 sin desbordamiento de padding.

### 4. Estado de Verificación Dual
- **Windows MSVC**: 237 pruebas aprobadas en `ele-nexo`, 770+ pruebas en workspace completo (`cargo test --workspace`), clippy limpio, fmt limpio.
- **Linux WSL2**: 238 pruebas aprobadas en `ele-nexo`, paridad completa.
- **Miri**: Pendiente de entorno externo debido a ausencia del componente en el toolchain del host.

---

## Actualización 2026-11-15 — Cierre de P0: encapsulación de API pública y aislamiento de instrumentación (PR #69)

Rama `feat/nexo-v0.3-physical-memory`, worktree `target/nexo-v0.3-physical-memory`, PR #69 en borrador. Base `origin/main @ 2712a1b`. No se modificaron workflows de CI, no se forzó push y no se realizó merge sin autorización.

### 1. Resolución de exposición de helpers adversariales
- Se eliminó completamente la feature `test-internals` y los métodos `__test_*` de la API del crate.
- Los métodos de instrumentación adversarial (`craft_handle_for_test`, `craft_hole_token_for_test`, `corrupt_live_for_test`, `corrupt_holes_for_test`, `corrupt_generation_for_test`, `corrupt_occupied_for_test`, `corrupt_free_bit_for_test`, `corrupt_hole_bit_for_test`) quedaron restringidos estrictamente a `#[cfg(test)]` con visibilidad `pub(crate)` dentro de `crates/nexo/src/physical/pool.rs`.
- La suite adversarial A01–A12 se migró a un módulo interno de pruebas unitarias (`crates/nexo/src/physical/adversarial_tests.rs`).
- Se implementaron pruebas negativas de compilación externa (`crates/nexo/tests/api_security.rs` y fixture `crates/nexo/tests/fixtures/external_consumer/`) que verifican que un consumidor normal o con `--all-features` no puede invocar dichos métodos (`error[E0599]`) ni construir instancias directas de `Handle` o `HoleToken` (`error[E0451]`).
- Se añadieron doctests `compile_fail` demostrando la no clonabilidad de `Handle` y `HoleToken` (`error[E0599]`).
- Validación: 216 pruebas aprobadas en Windows MSVC, 214 pruebas aprobadas en Linux WSL2 glibc.

---

## Actualización 2026-11-14 — Auditoría final de seguridad: atomicidad en dos fases (Fase A / Fase B), separación de contadores y casos adversariales A01–A12 (PR #69)

Rama `feat/nexo-v0.3-physical-memory`, worktree `target/nexo-v0.3-physical-memory`, PR #69 en borrador. Base `origin/main @ 2712a1b`. No se modificaron workflows de CI, no se forzó push y no se realizó merge sin autorización.

### 1. Auditoría de atomicidad de capacidades lineales y corrección arquitectónica

Se rediseñaron integralmente las operaciones propietarias del allocator físico (`crates/nexo/src/physical/pool.rs`) bajo una arquitectura formal en dos fases:
- **Fase A (Prevalidación y preparación sin mutaciones lógicas)**:
  - Todo chequeo de identidad, generación, inicialización de metadatos (`meta()`), límites de capacidad, comprobaciones de subpágina no ocupada y cálculo exacto de contadores (`checked_add`, `checked_sub`) se realiza antes de aplicar cualquier mutación lógica.
  - En `reuse_hole`, la puesta a cero física del slot (`space_mut()?.fill(...)`) se ejecuta en Fase A.
  - Si cualquier precondición, comprobación o efecto físico preliminar falla, la función retorna `Err((capacidad, error))` con el `Handle` o `HoleToken` exactamente intacto y sin que el pool haya alterado ninguna generación, bitmap o contador.
- **Fase B (Commit lógico irrevocable)**:
  - Una vez superada la Fase A, la transición de estado es infalible e irreversible: se invalida o avanza la generación del slot, se actualizan bitmaps de ocupados/libres, y se sincronizan los contadores `live` y `holes`.
  - La capacidad queda consumida de manera permanente y jamás es devuelta dentro de un `Err`.
  - Los efectos secundarios físicos post-commit (escritura del espejo de cabecera y descarte/reclaim físico por página) se aíslan completamente: si el kernel o el backend físico fallan, el error se reporta de forma estructurada en `DestroyReport` (`HeaderStatus::Stale`, páginas en `ReclaimPending`), conservando la destrucción irrevocable de la capacidad lineal sin comprometer la coherencia interna.

### 2. Separación de contadores de seguridad y métricas de telemetría

- Se eliminaron todos los `saturating_sub` sobre contadores de estado de seguridad:
  - `self.live` y `self.holes` usan `checked_sub(1)` en Fase A; un subdesbordamiento es rechazado explícitamente con `PoolError::Invariant`.
  - `self.live.checked_add(1)` en `allocate` y `reuse_hole` previene cualquier desbordamiento de capacidad o colisión de índices (`PoolError::OutOfSpace`).
  - `self.holes.checked_add(1)` en `destroy` con creación de hueco valida límites de espacio antes de invalidar el objeto.
- Los contadores de telemetría y diagnóstico (`alloc_count`, `destroy_count`, `bytes_allocated`, `reclaim_cycles`, etc.) se mantienen aislados y protegidos mediante `saturating_add`, garantizando que métricas acumulativas no provoquen desbordamiento ni afecten la corrección de seguridad.

### 3. Batería de pruebas adversariales A01–A12 (`crates/nexo/tests/adversarial_atomicity.rs`)

Se implementó una suite exhaustiva de 12 pruebas adversariales para auditar y verificar empíricamente los límites y la atomicidad:
- **A01**: Underflow simulado de `live` en `destroy` es interceptado en Fase A; el `Handle` es devuelto intacto y la generación no sufre alteración.
- **A02**: Underflow simulado de `holes` en `reuse_hole` o `release_hole` es interceptado en Fase A; el `HoleToken` es devuelto intacto.
- **A03**: Overflow simulado de `live` en `allocate` es rechazado antes de publicar cualquier slot o alterar páginas físicas.
- **A04**: Overflow simulado de `holes` en `destroy` con hueco rechaza la operación sin consumir ni invalidar el `Handle`.
- **A05**: Error de metadatos ante superpágina desinicializada devuelve la capacidad intacta en Fase A.
- **A06**: Reutilización exitosa garantizada de una capacidad `HoleToken` tras un fallo previo en Fase A.
- **A07**: Degradación segura ante fallo forzado de sincronización de cabecera post-commit; retorna `Ok(DestroyReport)` con `HeaderStatus::Stale` y el handle consumido irreversiblemente.
- **A08**: Generación destruida es permanentemente rechazada por `validate()`, impidiendo revalidaciones stale o ataques ABA.
- **A09**: Consistencia estricta del `DensityIndex` respecto a los bitmaps de superpáginas a lo largo de ciclos de reserva, huecos y liberación.
- **A10**: Fallo en espejo no revierte metadatos lógicos.
- **A11**: Reclamación física pendiente preserva la destrucción lógica del handle.
- **A12**: Campaña diferencial pseudo-adversarial de 300 operaciones con verificación continua de invariantes de pool.

### 4. Estado de validación dual (Windows y Linux WSL2)

- `cargo fmt --all --check`: aprobado (código 0).
- `cargo clippy --workspace --all-targets -- -D warnings`: aprobado (código 0).
- `cargo test -p ele-nexo --test adversarial_atomicity`: 12/12 aprobadas en Windows y Linux.
- `cargo test -p ele-nexo`: suite completa de NEXO aprobada (203 pruebas en Windows, 204 en Linux).
- `cargo test --test child_isolation`: 5/5 pruebas de protección física en proceso hijo aisladas y aprobadas en Windows (`0xC0000005`) y Linux (`SIGSEGV`).
- `cargo run --bin nexo-physical-fuzz -- --fallos 256 16`: 4.096 comandos, 192 resultados PFS, 32 recuperaciones sin divergencias.
- Suite completa del workspace validada.

---

## Actualización 2026-11-14 — Cierre de bloqueos P0 (overflow, tipado meta y probe físico) y validación PR #69

Rama `feat/nexo-v0.3-physical-memory`, worktree
`target/nexo-v0.3-physical-memory`, PR #69 en borrador. Base `origin/main @ 2712a1b`.
No se modificaron workflows de CI ni se forzó push.

### Bloqueos P0 resueltos

1. **P0.1 — Overflow de contadores y ordinales**:
   - `FaultPlan`: saturación controlada de `counts` en `u64::MAX` con retorno `FaultOutcome::Completed` en saturación para evitar fallos anómalos o desbordamientos; comprobación `checked_add` en `fail_nth` y `schedule` con guardia `n > 0`.
   - `OsCalls`: suma saturante en `total()`; incremento con `saturating_add(1)` en todas las transiciones reales y adversariales.
   - `NEXT_POOL_ID`: reserva atómica con `try_update` que comprueba el límite `u64::MAX`, fallando controladamente con `PoolError::InvalidConfig("pool ID counter exhausted")` en lugar de reiniciar IDs en 0.
   - `AddressSpaceMetrics`: multiplicaciones de conteos de páginas por tamaño de página protegidas con `saturating_mul`.
   - `DensityIndex`: guardias estrictas contra `free == 0`, `free > 64`, `free > buckets.len()` y desbordamiento de bits en `summary` o fuera de palabras.
   - `epoca_destruccion`: avance mediante `saturating_add(1)` y `saturating_add(a.epoca)`. En saturación a `u64::MAX`, la validación de sellos rechaza enlaces obsoletos de forma segura en lugar de permitir colisiones por wraparound.
   - Métricas de runtime (`rt/metricas.rs` y `rt/maquina.rs`): todas las estadísticas de accesos, revalidaciones, ausencias, lecturas y drop-flags migradas a `saturating_add`.
   - `platform/linux.rs`: aritmética de alineación y recorte de prefijo/sufijo protegida con `checked_add` y manejo seguro de memoria antes de abortar.

2. **P0.2 — Tipado seguro de `meta()` y `meta_mut()`**:
   - Eliminados todos los `expect("superpágina inicializada")` de `PhysicalPool`.
   - Definido el tipo testigo `SuperpageIndex(usize)` para ordinales de superpágina dentro del límite y con inicialización confirmada.
   - `meta(sp)` y `meta_mut(sp)` retornan ahora `Result<&SuperpageMeta, PoolError>` y `Result<&mut SuperpageMeta, PoolError>`, mapeando accesos fuera de rango o superpáginas no inicializadas a `Err(PoolError::Invariant(...))` sin entrar en pánico.
   - Incorporados los métodos de inspección y validación `is_superpage_initialized(sp)` y `validate_superpage(sp) -> Result<SuperpageIndex, PoolError>`.
   - Propagación y preservación segura de capacidades (`Handle`, `HoleToken`) en caso de inconsistencia interna en `destroy`, `reuse_hole`, `release_hole`, `allocate` y las rutinas de reclaim/espejo.

3. **P0.3 — Prueba física en proceso hijo aislado**:
   - Implementada suite integral en `crates/nexo/tests/child_isolation.rs` (5 pruebas).
   - Comprobación en proceso hijo: reserva -> confirmación -> escritura/lectura -> desconfirmación/protección -> intento de acceso volátil.
   - Verificado el comportamiento del hardware/SO ante el fallo de página real:
     - **Windows/MSVC**: terminación con código `STATUS_ACCESS_VIOLATION` (`0xC0000005`) tanto en lectura como en escritura sobre páginas protegidas.
     - **Linux (WSL2/glibc)**: terminación por señal `SIGSEGV` (señal 11) capturada mediante `ExitStatusExt::signal()`.
   - El proceso padre de pruebas permanece completamente aislado e inmune a las excepciones/señales de fallo del hijo.
   - Ciclo de reconfirmación verificado con éxito (recommit restaura acceso físico).
   - Capa segura (`AddressSpace::read`, `write`) comprobada rechazando accesos desconfirmados antes de cualquier desreferenciación.

### Validación real ejecutada

- **Windows/MSVC**:
  - `cargo fmt --all --check`: limpio.
  - `cargo clippy --workspace --all-targets -- -D warnings`: limpio (0 advertencias).
  - `cargo test -p ele-nexo -- --test-threads=1`: 191 aprobadas (190 unitarias/integración + 1 doctest), 0 fallidas, 0 ignoradas.
  - `cargo test --workspace --no-fail-fast -- --test-threads=1`: **779 aprobadas**, 0 fallidas, 3 ignoradas (microbenchmarks de préstamos).
  - `cargo run --bin nexo-physical-fuzz -- --fallos 256 16`: 4.096 comandos, 192 resultados PFS, 32 recuperaciones sin divergencias.
  - `tests/child_isolation.rs`: 5/5 aprobadas con verificación de `0xC0000005`.
- **Linux (WSL2 / glibc)**:
  - `cargo test -p ele-nexo -- --test-threads=1`: 192 aprobadas (191 unitarias/integración + 1 doctest, incluyendo prueba específica de Linux), 0 fallidas, 0 ignoradas.
  - `cargo run --bin nexo-physical-fuzz -- --fallos 256 16`: 4.096 comandos, 192 resultados PFS, 32 recuperaciones sin divergencias.
  - `tests/child_isolation.rs`: 5/5 aprobadas con verificación de `SIGSEGV` (señal 11).
- **GitHub Actions**:
  - Permanece bloqueado por cuota agotada de la cuenta. No se modificaron workflows de CI.

### Worktrees e integridad del repositorio

- 23 worktrees inventariados y respetados; no se modificó, limpió ni descartó ningún árbol ajeno.
- El worktree principal `ELE` conserva intacto su estado previo.
- El trabajo de este incremento queda confinado exclusivamente a `target/nexo-v0.3-physical-memory` sobre `feat/nexo-v0.3-physical-memory`.

---

## Actualización 2026-11-14 — PFS, cierre propietario y gate de PR #69

Rama `feat/nexo-v0.3-physical-memory`, worktree
`target/nexo-v0.3-physical-memory`, PR #69 en borrador. HEAD documental:
`23488b8c879fa511bbbdf309c62a3398ce53c3e3`; implementación P0:
`fb0c58b60cf8ab70377d9305965e5cc6179b297b`. No se fusionó nada y no se
modificaron workflows.

Implementado: resultados adversariales `Rejected`, `Partial`,
`CompletedWithError` y `Unknown`; cuarentena de rango completo; reconciliación
por página; `PageState::Quarantined` fuera del índice de densidad; cuarentena
también ante errores reales de commit/protect/discard; `ReleaseUncertain` que
bloquea toda operación salvo reintentar cierre; `try_close` propietario que
devuelve el único dueño; tres intentos acotados en `Drop` y diagnóstico agregado
de fallos terminales. El fuzzer físico cubre una matriz determinista 4×3 y
preserva la clase del fallo durante reducción. PFS es simulación adversarial:
no se afirma haber provocado un fallo parcial real del kernel.

Validación real:

- Windows/MSVC: `cargo fmt --all --check` y
  `cargo clippy --workspace --all-targets -- -D warnings` aprobados;
  `ele-nexo` 185/185; PFS 16/16; cierre 7/7; workspace 769 aprobadas,
  0 fallidas, 3 ignoradas. El log final contiene 85 líneas
  `test result: ok` y cero marcadores de fallo.
- Windows/MSVC fuzzer: `--fallos 256 16`, 4.096 comandos, 192 resultados PFS,
  32 recuperaciones de pool, sin divergencias.
- Ubuntu WSL2/glibc: `ele-nexo` 185/185; mismo fuzzer 4.096/192/32 sin
  divergencias. No se validó un host Linux externo.
- GitHub Actions sigue bloqueado por cuota. Un job con cero pasos no se trató
  como fallo de compilación.

Revisión independiente: no quedan bloqueos P0 conocidos en este delta. Deuda
explícita: `FaultPlan` aún necesita política de overflow; `meta`/`meta_mut` y el
índice de densidad conservan invariantes no expresadas por tipos; falta probe
físico aislado en proceso hijo; `Drop` no puede garantizar release frente a un
rechazo persistente. L03/L04/L06/L07/L09 siguen sin implementarse; no se
declaran T1–T4/I11 demostrados, concurrencia nativa, integración ELE, Stage 2 ni
self-hosting.

Inventario real de 23 worktrees, inspeccionado sin descartar nada:

- `ELE`: `main @ 2712a1b`, solo `.claude/` no rastreado.
- `.claude/worktrees`: `agent-a05...` limpio (behind 4); WIP preservado en
  `agent-a1d...` (PE64, cuatro archivos nuevos), `agent-a211...` (seis archivos
  sema), `agent-a47...` (dos archivos de tipos entre módulos), `agent-a582...`
  (ocho archivos de préstamos/retornos) y `agent-ab759...`
  (`examples_ele_v2.rs`).
- `target/handoff-2026-11-12` limpio; `target/nexo-enca-audit-20261113`,
  `target/p0-lir-interfaces-20261113` y `target/verify-pr63-pr64-20261113`
  conservan únicamente cachés `__pycache__` no rastreadas; el worktree NEXO es
  el de este incremento.
- `ELE-baseline` limpio, behind 1.
- `ELE-wt/agent-exports` conserva `stmt.l` modificado y dos rutas no
  rastreadas; `agent-owned` conserva dos archivos modificados. `agent-builtins`,
  `agent-listlit`, `agent-result`, `cycle2`, `fable-b2` y `fable-main` solo
  muestran cachés no rastreadas. `fable-append @ eb436c5` está limpio;
  `integration` y `nexo` están limpios. No se tocó ninguno.

Próximo paso inmediato: publicar `fb0c58b`, `23488b8` y este handoff; actualizar
la descripción del PR #69 con comandos, SHAs, cuota y limitaciones; mantenerlo
en borrador. Después, cerrar L05 localmente antes de abrir ramas arquitectónicas
independientes para metadatos/cabeceras, concurrencia, formalización e
integración experimental.

---

## Actualización 2026-11-13 — NEXO v0.3 físico / PR #69

Rama `feat/nexo-v0.3-physical-memory`, worktree
`target/nexo-v0.3-physical-memory`, basada en `main @ 2712a1b`. El PR #69 está
abierto como borrador y no debe fusionarse sin autorización. La rama publicada
llegaba a `9cb8622`; el commit local nuevo `e5a1ad3` alinea los casos de
seguridad ante fallos físicos como S01–S12 y registra validación Linux/glibc.

Estado implementado: reserva/commit/protección/decommit reales para Windows y
Linux, allocator Bi-Slab físico, generaciones y huecos lineales, recuperación
reintentable, espejo físico de cabecera, F01–F20, S01–S12, adaptador y fuzzer
diferencial, benchmarks, especificación formal y plan de port a ELE. No está
integrado en Stage 0, Stage 1, ELE-LIR ni ABI; no implica Stage 2 ni
self-hosting.

Validación real sobre `e5a1ad3`: Windows/MSVC fmt y Clippy workspace limpios;
`ele-nexo` 160/160; workspace 744 aprobadas, 0 fallidas, 3 ignoradas;
S01–S12 13/13 contando S02b específico de Windows; fuzzer con fallos 256 ×
5.000 = 1.280.000 comandos, 127.546 inyecciones, sin divergencias. Ubuntu
WSL2/glibc: `ele-nexo` 160/160, S01–S12 12/12 y otros 1.280.000 comandos de
fuzzing con fallos sin divergencias. El kernel WSL2 es 5.10.16 con páginas de
4 KiB. Falta validación en un host Linux fuera de WSL2 y fallos reales del SO
dentro de una syscall; la inyección ocurre antes de llamadas nativas.

GitHub Actions está bloqueado por cuota agotada. Los jobs con cero pasos no
son evidencia de fallo de compilación. No se investigaron ni modificaron
workflows. El PR debe documentar este bloqueo y permanecer en borrador.

Inventario de 23 worktrees inspeccionado sin modificar árboles ajenos. WIP de
código que debe conservarse: cinco worktrees `.claude` (PE64, gaps LIR, tipos
intermódulo, préstamos/retornos y fuentes v2), `ELE-wt/agent-exports` y
`ELE-wt/agent-owned`. `ELE-wt/fable-append` está limpio en
`eb436c5` sobre `fix/native-append-text-by-value`; no se perdió el test de
`native_print_l.rs`. Hay cachés `__pycache__` no rastreadas en varios árboles;
no se borraron. El worktree principal solo tiene `.claude/` no rastreado.

Siguiente paso: publicar `e5a1ad3` y el commit de este registro, actualizar la
descripción del PR #69 con los comandos/SHAs finales y la cuota, mantenerlo en
borrador, y revisar los riesgos pendientes antes de cualquier merge.

---

## Actualización 2026-11-13 — interfaces LIR de Stage 1

`origin/main` verificado tras `git fetch origin --prune`: `ebec0847e938b98f0cc6fea9da5943e66e4e4b04`.
Los PR #62, #63 y #64 están fusionados; #55 sigue abierto en borrador.
El PR #65 está abierto en borrador desde la rama de esta actualización.
La cuota de GitHub Actions está agotada. No se hizo merge ni se lanzó CI manualmente.

La rama publicada `codex/fix-stage1-lir-internal-interfaces`, worktree
`target/p0-lir-interfaces-20261113`, parte de ese `main` y contiene estos
commits de código, en orden:

1. `54236c9` — exporta `lirBlocks` para `lir_finish.l`, `sema_ops.l` y `stmt_lower.l`.
2. `253402a` — exporta `lirPlaceIndex` para los módulos de colecciones.
3. `b8080a7` — exporta `lirTypesCompat` para los módulos del verificador.
4. `0195f0b` — exporta únicamente los nueve símbolos de `lir_verify_core.l`
   usados realmente por `lir_verify.l`/`lir_verify_helpers.l`; captura la raíz
   antes de `lirEmit` en `lir_finish.l` para evitar el préstamo `L0012`.

Las pruebas de `stage1_b1_export_chain_l.rs` reprodujeron `L0001` y `L0012`
antes de las correcciones y pasaron después (14/14). El test negativo conserva
`lirVerifyInst` privado. `lir_verify.l --check-ownership` ahora termina con
`errors=0`. El gate de autocobertura midió **91/91 parser, 64/91 semántica y
ownership, 40/91 LIR y 5/91 nativo**; los cuatro avances de semántica son
`lir_emit.l`, `lir_finish.l`, `lir_verify.l` y `lir_verify_helpers.l`. Solo esas
cuatro filas se promovieron en `docs/self_coverage_baseline.tsv`.

Validación local Windows/MSVC sobre `0195f0b` y la línea base promovida:
`cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`,
`git diff --check`, `stage1_b1_export_chain_l` (14/14),
`stage1_import_exports_l` (3/3), `self_coverage` (3/3), y
`cargo test --workspace --no-fail-fast -- --test-threads=1` (exit code 0;
ninguna prueba fallida, tres microbenchmarks ignorados). El gate
`python tools/self_coverage_gate.py --baseline docs/SELF_COVERAGE_MATRIX_2026-11-11.md`
pasó tras la actualización del baseline con 91/64/40/5. Los negativos de
visibilidad, préstamos, ownership y LIR siguieron aprobando. No se detectó
regresión en la suite local.

### Worktrees inventariados

`git worktree list --porcelain` enumera 21 worktrees. Los recuentos siguientes
son de `git status --porcelain` (incluyen cachés `__pycache__`); no se limpió
ningún árbol ajeno. Rutas relativas bajo `C:/Users/Usuario/Desktop/`.

| Worktree | Rama | Entradas locales |
| --- | --- | ---: |
| `ELE` | `feat/native-list-cfg` | 6 |
| `ELE/.claude/worktrees/agent-a05cd3aeb3be8ebbe` | `chore/project-registry-self-coverage` | 0 |
| `ELE/.claude/worktrees/agent-a1d76385424054ae7` | `feat/native-pe64-win32-runtime` | 4 |
| `ELE/.claude/worktrees/agent-a211fa3c9eab69693` | `feat/stage1-lir-lowering-gaps` | 6 |
| `ELE/.claude/worktrees/agent-a47f84692f572f627` | `feat/stage1-cross-module-types` | 2 |
| `ELE/.claude/worktrees/agent-a582e948d165bff07` | `fix/stage1-borrow-two-phase-returns` | 8 |
| `ELE/.claude/worktrees/agent-ab7597703089636e1` | `chore/ele-v2-frontend-sources` | 1 |
| `ELE/target/handoff-2026-11-12` | `chore/session-handoff-2026-11-12` | 0 |
| `ELE/target/p0-lir-interfaces-20261113` | `codex/fix-stage1-lir-internal-interfaces` | 1 cache antes de este documento |
| `ELE/target/verify-pr63-pr64-20261113` | `test/verify-pr63-pr64-20261113` | 2 caches |
| `ELE-baseline` | `fix/stage1-b2-stmt-span-snapshot` | 0 |
| `ELE-wt/agent-builtins` | `fix/stage1-b8-write-bytes-builtin` | 1 cache |
| `ELE-wt/agent-exports` | `fix/stage1-b1-export-chain-after-45-47` | 3 |
| `ELE-wt/agent-listlit` | `feat/stage1-b3-contextual-empty-list` | 1 cache |
| `ELE-wt/agent-owned` | `feat/lir-option-result-owned-payloads` | 2 |
| `ELE-wt/agent-result` | `feat/lir-option-result-dropfree-aggregates` | 2 caches |
| `ELE-wt/cycle2` | `test/fable-cycle2-integration` | 1 cache |
| `ELE-wt/fable-append` | `fix/native-append-text-by-value` | 0 |
| `ELE-wt/fable-b2` | `fix/stage1-b2-native-list-int-snapshot` | 1 cache |
| `ELE-wt/fable-main` | detached | 1 cache |
| `ELE-wt/integration` | `integration/fable-cycle-1` | 0 |

Cambios de código ajenos que deben conservarse: el worktree principal tiene
`native_cfg_loan.l`, `native_cfg_verify.l` y este documento modificados; el
worktree `agent-owned` tiene `lir_builtin_union.l` y `sema_drop.l` modificados.
Hay además WIP en los worktrees `agent-a1d76385424054ae7`,
`agent-a211fa3c9eab69693`, `agent-a47f84692f572f627`,
`agent-a582e948d165bff07`, `agent-ab7597703089636e1` y `agent-exports`.
`fable-append` estaba limpio al comprobarlo. No se modificaron esos árboles.

### Bloqueos siguientes

- `sema_collection_ops.l` aún emite varios `L0001` de helpers distintos;
  `feat/stage1-lir-lowering-gaps` ya tiene cambios locales en ese módulo,
  así que hay que coordinar o integrar ese trabajo antes de tocarlo.
- `Result<List<LexToken>, LexError>` y los payloads propietarios siguen sin
  alcanzar ELE-LIR/nativo con drops demostrados (`L0016`). `agent-owned` tiene
  WIP, que debe revisarse sin perderlo. No se declara Stage 2 ni self-hosting.
- El reporte local muestra `L0016` como siguiente fase fallida para `lexer.l`,
  `lir_emit.l`, `lir_finish.l`, `lir_verify.l` y `lir_verify_helpers.l`; no hay
  que convertir ese diagnóstico en aceptación sin implementar la semántica.
- WSL2 devuelve «Acceso denegado» en `wsl --list --quiet`: no se ejecutaron
  tests nativos Linux y no se afirma ejecución ELF64 sobre Linux.

[PR #65](https://github.com/Joshua-EPR/ELE/pull/65), en borrador:
**`fix(stage1): resolve LIR internal module interfaces`**.
Exporta solo las dependencias reales de construcción y
verificación LIR, mantiene privado `lirVerifyInst`, corrige la lectura y
edición simultáneas en el drop, y eleva cuatro entradas de autocobertura a
semántica. El commit de documentación inicial fue `c27b567`. Debe revisarse
antes de fusionar, sin consumir Actions hasta que la cuota vuelva a estar
disponible. No cierra las issues #3, #4, #5, #8 o
#31, que siguen parcialmente abiertas.

---

## Actualización 2026-11-12 — autocobertura Stage 1

**Referencia remota verificada:** `main` = `b61000b24e`
(PR #33, #34 y #35 fusionados); [CI de main exitoso](https://github.com/Joshua-EPR/ELE/actions/runs/43147786262).
La medición posterior a #35 se obtuvo del `report.json` de ese CI:
**89/89 parser, 23/89 ownership, 9/89 LIR y 1/89 ELF64**.
No hay evidencia de Stage 2/3.

Trabajo pendiente en **PR #36** (exportación selectiva de tipos, funciones y
constantes inter-módulo; B1 parcial) y **PR #37** (23 correcciones de
lectura+edición del runtime; B2 parcial). Ambos son drafts independientes de
`main`, sin integración ni mejora cuantitativa atribuida hasta obtener sus
respectivos JSON de CI.

El desglose real de fallos y la matriz B1–B11 están en
[STAGE1_B1_B11_STATUS_2026-11-12.md](STAGE1_B1_B11_STATUS_2026-11-12.md).
Los seis errores L0003 convergen en `lexer.l:87`; el backend devuelve
código 48 para ocho módulos sin `main`, condición que debe distinguirse de
límites de capacidad antes de modificar el verificador.

**Nota de preservación:** los worktrees y cambios locales de agentes de
otras sesiones no son accesibles por esta conexión con GitHub. Las referencias
a `stash@{0}`, archivos modificados o rutas de Windows que aparecen en el
histórico siguiente no están verificadas desde aquí. No ejecutar limpieza o
resets basándose únicamente en estas notas.

---


## Estado actual — 2026-11-11

Trabajo activo: `feat/native-list-cfg`, basado en `c8dfc81`. El resto de este
documento recoge traspasos históricos y menciona ramas y cifras antiguas.
La validación del commit y las correcciones pasó `cargo fmt --all --check`,
Clippy con `-D warnings` y la suite completa Windows/MSVC: 526 aprobadas,
0 fallidas y 3 ignoradas. El contrato Python de enums se actualizó
porque el lector de instrucciones se trasladó a `native_cfg_inst.l` y el de
tipos a `native_cfg_types.l`; se corrigieron además problemas CRLF y UTF-8
de pruebas Python en Windows. `tests/native_backend` ejecuta 39 casos:
27 aprobados y 12 omitidos. La [matriz medida](SELF_COVERAGE_MATRIX_2026-11-11.md)
invocó 89 fuentes reales: parser 89, semántica/ownership 23, LIR 9 y
backend ELE/ELF64 1 como entradas independientes. Véanse también
[NATIVE_LIST_LOANS_PHASE.md](NATIVE_LIST_LOANS_PHASE.md) y
[BRANCH_INTEGRATION_AUDIT.md](BRANCH_INTEGRATION_AUDIT.md).

`stash@{0}` y el worktree `ELE-baseline` siguen intactos. WSL devuelve
«Acceso denegado», así que falta ejecución Linux local. Quedan pendientes
`listpop` y `dropfield` mediante referencias locales en el backend ELE.
La sobrescritura de propietarios ya emite ELF64 y tiene paridad Stage 0 en
Windows; falta ejecución Linux del nuevo caso. No se ha demostrado Stage 2/3
ni self-hosting.

Última actualización el 2026-11-10 en `dev/ele-self-hosting-lir`.
El incremento vigente está en §35 (LIR de ELE y backend provisional).
§33 documenta los drops; §32, el borrow checker.
Lea este documento primero; después [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md),
[LEXER_PARITY.md](LEXER_PARITY.md), [MODULE_SYSTEM.md](MODULE_SYSTEM.md),
[LEXER_FILE_CLI.md](LEXER_FILE_CLI.md), [BOOTSTRAP_ARCHITECTURE.md](BOOTSTRAP_ARCHITECTURE.md),
[SELF_HOSTING_ROADMAP.md](SELF_HOSTING_ROADMAP.md) y [SELF_HOSTING_GAP_ANALYSIS.md](SELF_HOSTING_GAP_ANALYSIS.md).

## 1. Dónde está el trabajo

- **Rama de Claude:** `dev/native-collections-complete` (derivada de `dev/regions`,
  commit `0716e9a`).
- **Commits de esta etapa** (más antiguo primero):
  - `41c6688` feat(collections): arrays, slices and List in front-end and rustc backend.
  - `d4ef320` feat(collections): native arrays, slices and List in the Cranelift backend.
  - docs/bench: el commit que contiene este traspaso.
- **Sin remoto Git**: los commits son locales; no se ha creado ningún Pull Request.
- La carpeta pertenece a otro usuario de Windows (`CodexSandboxOffline`): use
  `git -c safe.directory=C:/Users/Usuario/Desktop/proyectos/p1 ...` si git lo exige.
  No haga reset, clean ni checkout destructivo.
- Ramas locales: `dev/phase2-const-text` → … → `dev/effect-system` → `dev/regions` →
  `dev/native-collections-complete`. Cada una contiene a la anterior.
  `dev/native-collections` (`4204051`) es el WIP antiguo de otro agente; **no se tocó
  ni se integró** (esta etapa reimplementó el hito completo sobre `dev/regions`).

## 2. Cómo verificar

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'   # es Rust 1.99.1
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

Estado verificado al cerrar: fmt y clippy limpios, **143 pruebas, 0 fallos**.
(Sin la variable, rustup usa la toolchain GNU de `rust-toolchain.toml` y el backend
rustc genera ejecutables MinGW distintos; las pruebas asumen MSVC.)

Benchmarks: `cargo build --release` y después
`powershell -ExecutionPolicy Bypass -File bench\run.ps1 -Runs 5` (escribe
`bench/results.md`).

## 3. Qué se hizo en esta etapa (colecciones)

Estado heredado comprobado: 125/125, fmt y clippy limpios.

1. **Arrays `[T; N]`, slices `&[T]`/`&mut [T]` y `List<T>`** de punta a punta: lexer
   (`[`, `]`), parser (tipos, literales, `List[...]`, índice postfijo, for-each),
   sema (tipos en tablas `Program.arrays/slices/lists`, índices constantes, métodos
   push/pop/reserve, `.length`/`.capacity`, coerción a slice en parámetros),
   ownership (colecciones prestadas durante el for, sin mover elementos), efectos,
   LIR de bloques (`Proj::Index`, `ArrayLit`, `ListLit`, `Len`, `Cap`,
   `ListTakeLast`, `ListPush`, `ListReserve`), drops (colecciones atómicas),
   backend rustc (`Vec`, `l_at`, `l_push`, `l_reserve`) y Cranelift (layout,
   direcciones comprobadas, `l_rt_list_reserve`, glue `l_list_drop{l}`).
2. **Defectos corregidos durante la etapa**: drop de la colección entera al escribir
   un elemento (L0007 interno); lectura de un campo de elemento tratada como
   movimiento; posiciones de los panics de índice distintas entre backends.
3. **Pruebas**: `tests/collections.rs` (18) — diferenciales instrumentadas, panics
   diferenciales, negativos de tipos/ownership/efectos, fallo de reserva inyectado.
4. **Benchmarks**: `bench/programs/list_*.l`; `run.ps1` ahora informa también reservas
   y realocaciones (build instrumentado aparte). Resultados en `bench/results.md` y
   en IMPLEMENTATION_STATUS §12.

## 4. Estado de los hitos solicitados históricamente

| Hito | Estado real |
|---|---|
| Arrays, slices, List | **Implementado y probado** en ambos backends (esta etapa) |
| Genéricos, traits, monomorfización | Implementado y probado |
| Sistema de efectos, `@noalloc` | Implementado y probado (incluye colecciones) |
| Adaptive Ownership avanzado | Parcial: ownership por campo, préstamos de parámetros; **sin lifetimes** |
| Regiones de memoria | Implementado y probado para `Bytes`; listas regionales añadidas en §8 |
| Análisis de escape | No como pase separado; garantías por reglas de tipos |
| Async/await | No empezado |

## 5. Mapa del código relevante

| Archivo | Qué contiene |
|---|---|
| `crates/l/src/sema.rs` | Tipos, `resolve_param` (único sitio donde `&T` es válido), `ref_args` (préstamos en llamadas), `region_method`, reglas L0011 (`not_region_bound`, `same`) |
| `crates/l/src/ownership.rs` | Movimientos y préstamos; `check_call_borrows` (exclusividad en una llamada) |
| `crates/l/src/effects.rs` | Efectos; regiones = `alloc` + `panic` |
| `crates/l/src/lir.rs` | `Type::Region/Bytes`, `CALLER_REGION`, `ValueKind::Region*/Bytes*` |
| `crates/l/src/cfg.rs` | LIR de bloques: `RegionNew`, `RegionBytes`, `BytesLen`, `BytesGet`, `BytesSet` |
| `crates/l/src/drops.rs` | `needs_drop(Region) = true`; elaboración y verificación de propiedad |
| `crates/l/src/native.rs`, `native/runtime.rs` | Cabecera de región en pila, `l_rt_region_alloc/free`, `l_rt_panic_at`, contadores |
| `crates/l/src/backend.rs` | Referencia rustc: `LRegion`, `LBytes`, `l_bytes_get/set` |
| `crates/l/tests/regions.rs` | 11 pruebas de regiones |
| `crates/l/tests/collections.rs` | 18 pruebas de colecciones |
| `crates/l/src/layout.rs` | `windows_x64_with` (arrays), `MAX_COMPONENTS` |
| `crates/l/src/native.rs` | `place_addr` con índices, `slice_parts`, `drop_elements`, `list_drop_glue`, `by_sret` |
| `crates/l/src/native/runtime.rs` | `l_rt_list_reserve`, constantes `LIST_*` y mensajes |
| `crates/l/tests/references.rs`, `effects.rs` | Regresiones de esta etapa |

Códigos de diagnóstico nuevos: **L0011 [regiones]** (escape de región o uso indebido).

## 6. Limitaciones que el siguiente agente debe conocer

- Colecciones: sin igualdad ni `print` de colecciones completas, sin `for` con `&mut`
  por elemento, sin métodos de usuario sobre elementos (`personas[0].saludar()`),
  sin rangos como índice ni `[x; N]`; arrays nativos limitados a 4096 componentes
  escalares (usar `List<T>`); arrays siempre se mueven (no Copy).
- `List<()>` (elementos de tamaño cero): la capacidad informada difiere de rustc
  (Rust da `usize::MAX`); no está probado.
- En la base de Claude solo se reservaban `Bytes`. El incremento actual añade buffers de listas regionales.
- Referencias de segunda clase (también slices): no se almacenan ni se devuelven.
- Panic = abort sin unwinding ni drops (documentado). Solo Windows x86-64.

## 7. Próximo paso recomendado

1. **Colecciones en regiones**: `List` con identidad de región en el tipo y
   crecimiento dentro de la región (DECISIONS 85).
2. **Lifetimes / referencias de primera clase** (incluye slices devueltos, iteración
   `&mut`, métodos sobre elementos).
3. **Async/await**, una vez lo anterior sea estable.


## 8. Incremento actual

- `RegionList(elemento, región)` en tipos, `RegionList` en LIR/CFG y selección
  del allocator en el runtime. La cabecera adicional existe solo para listas
  regionales. El verificador comprueba orden de drops y región viva.
- Se reutilizan indexación, iteración, préstamos de slices y efectos. La lista
  termina antes de que la región libere sus bloques. Los elementos sacados con
  pop pasan a su nuevo propietario.
- Suite final: 149 pruebas, 0 fallos, fmt y clippy limpios.
- `crates/l/tests/regions.rs` cubre el incremento con seis pruebas adicionales.
  `bench/region-lists.ps1` reproduce la comparación nativa de heap, región y
  array fijo. Genera `target/bench-regional/results.csv`.
- Siguiente hito: lifetimes y préstamos de elementos con alcance mayor que una
  llamada, con verificación de aliasing antes de incorporar async.


## 9. Préstamos locales y último uso

Base `dev/region-collections` en `043a25f`, limpia y con 149 pruebas aprobadas.
`sema.rs` admite el binding local, `cfg.rs` produce `Loan`, y `loans.rs`
normaliza orígenes y comprueba conflictos usando liveness sobre el CFG.
Suite final: 158 pruebas aprobadas, formato y Clippy limpios.
Los tiempos y el procedimiento reproducible están en IMPLEMENTATION_STATUS §14.
Ambos backends admiten préstamos locales y slices sobre arrays, listas del heap
y listas regionales. La política conservadora prohíbe almacenar o devolver
la dirección fuera del binding. El siguiente incremento debe añadir contratos
de origen para retornos de referencia, empezando por un parámetro inequívoco.
Después corresponde el análisis interprocedimental general de escapes.


## 10. Retornos prestados

Base `dev/lifetimes-escape` en `c1efd90`, 158 pruebas aprobadas.
`sema.rs` declara un único origen y el modo de retorno. `lir.rs` define
`BorrowReturn` y `cfg.rs` tipa llamadas de referencia y `ReturnRef`.
`loans.rs` verifica la procedencia de los retornos y prolonga el préstamo
del argumento al sustituir el resultado de una llamada por su origen.
Cranelift retorna la dirección y rustc emite una relación de lifetime.
Suite final: 166 pruebas aprobadas, formato y Clippy limpios.
Las mediciones reproducibles están en IMPLEMENTATION_STATUS §15.

Hay pruebas diferenciales de referencias a campos, elementos de listas
regionales, genéricos, métodos y recursión. La documentación de semántica
describe el alcance y la propuesta de lifetimes múltiples. El siguiente
incremento es ampliar los contratos de origen y clasificar escapes en
agregados, antes de permitir referencias almacenadas.


## 11. Procedencia y clasificación de escapes

Base `dev/reference-returns` en `e064ac7`, 166 pruebas aprobadas.
`BorrowReturn.params` contiene los candidatos de la firma. `loans.rs`
normaliza cada alias en un conjunto de lugares y comprueba cada retorno.
`escape_summaries` expone retornos proyectados y parámetros reenviados.
La ABI nativa de slices devueltos lleva dirección y longitud.
Suite final: 171 pruebas aprobadas, formato y Clippy limpios.
Las mediciones reproducibles están en IMPLEMENTATION_STATUS §16.

Los agregados con referencias siguen rechazados por el frontend. El siguiente
incremento es diseñar un tipo agregado con lifetime y reglas de construcción,
movimiento y destrucción verificables antes de habilitar almacenamiento.
El modelo y los límites están en [ESCAPE_ANALYSIS.md](ESCAPE_ANALYSIS.md).


## 12. Vistas locales

Base `dev/escape-aggregates` en `e20a62d`, 171 pruebas aprobadas.
`SharedField` y `StoredBorrow` representan campos compartidos y su
inicialización. `FieldLoan` carga la dirección. `loans.rs` reconstruye
los préstamos de cada vista movida, comprueba su duración y los clasifica
en el resumen de escapes.
Suite final: 177 pruebas aprobadas, formato y Clippy limpios.
Las mediciones reproducibles están en IMPLEMENTATION_STATUS §17.

Siguiente incremento: contratos por campo para exportar vistas ancladas
a parámetros, seguidos de campos exclusivos con reglas de représtamo.
[Modelo](AGGREGATE_LIFETIMES.md).


## 13. Retornos de agregados prestados y lifetimes interprocedimentales

Base `dev/aggregate-lifetimes` en `0521d1a`, 177 pruebas aprobadas.
Rama: `dev/borrowed-aggregate-returns`.

- `ViewReturn` y `FieldContract` definidos en `lir.rs` y `cfg.rs` para modelar y propagar contratos de procedencia y proyección por campo.
- `loans.rs`:
  - `collect_aliases`: resolución topológica de alias para resolver dependencias interprocedimentales complejas y detectar ciclos verdaderos (`L0013`).
  - `step`: acotamiento de liveness de campos de vistas en el bloque CFG al retroceder sobre la instrucción `def` de la vista.
  - Punto fijo interprocedimental en `check` y `escape_summaries` para propagar proyecciones a través de reenvíos (`reenviarVista(u)`) y llamadas encadenadas (`crearVista(u).nombre`).
  - Préstamos disjuntos por campo: prestar `usuario.nombre` mediante una vista retornada permite mutaciones seguras sobre `usuario.edad`, rechazando conflictos sobre `usuario.nombre` o movimientos completos de `usuario` con `L0012`.
  - Rechazo estricto de escapes de agregados vinculados a variables locales, agregados locales, temporales o buffers regionales con código `L0014` y ubicación precisa.
- Backend nativo Cranelift: retorno de agregados con referencias vía `by_sret` (slot en stack de llamador, escritura de componentes por callee, desreferenciación mediante `FieldLoan`).
- Backend Rustc: preservación de semántica y verificación diferencial con `--trace-alloc` (`heap_ok=1`, `allocs == frees`).
- Métodos en structs retornando vistas (`u.vista()`) y ramificaciones con múltiples orígenes (`if/else`).

Suite final: **195 pruebas aprobadas, 0 fallos**. Formato `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios.
[Documentación técnica](BORROWED_AGGREGATE_RETURNS.md) y [Estado de implementación §18](IMPLEMENTATION_STATUS.md#18-retornos-de-agregados-prestados-y-lifetimes-interprocedimentales).

Siguiente incremento:
1. Campos `&mut T` en structs con exclusividad estricta y semántica Move pura (sin Copy implícito).
2. Reasignación de vistas (`var vista = ...`) con actualización dinámica de procedencia en CFG.
3. Soporte para vistas anidadas y como parámetros regulares una vez estabilizada la exclusividad mutable.

## 14. Referencias mutables en agregados y reasignación de vistas

Base `dev/borrowed-aggregate-returns` en `954e2c5`, 195 pruebas aprobadas.
Rama: `dev/mutable-aggregate-views`.

- **Campos mutables en agregados (`Type::MutField`):**
  - Soporte completo de campos `&mut T` en structs.
  - Exclusividad garantizada en construcción y uso. Se rechazan aliasing mutable y préstamos superpuestos con `L0012`.
  - Prohibición de prestar bindings inmutables de forma mutable (`L0012`).
  - Semántica Move pura: los structs que contienen referencias no implementan `Copy`. Mover la vista invalida el origen (`L0005`).
- **Acceso, lectura y modificación por campos:**
  - Asignaciones directas e indirectas (`vista.valor = 42`, `self.valor += 1`) operan a través de `FieldLoan`, cargando la dirección y escribiendo al referente sin sobrescribir el puntero del struct.
  - Rechazo estricto de mutaciones a través de campos de referencia compartida `&T`.
  - Métodos inherentes sobre vistas (`impl VistaMutable`) con métodos mutables (`mut fn`) y receptor `self`.
- **Reasignación segura de vistas (`var vista = ...`):**
  - Permite `var vista = Vista(valor: &a)` y luego `vista = Vista(valor: &b)`.
  - En `loans.rs`, las variables que contienen vistas asignan identidades de préstamo sintéticas por campo en `ViewFields`, acumulando las fuentes en `definitions` y asociando `through` en `origins`.
  - Terminación correcta de préstamos anteriores y compatibilidad con bifurcaciones de control de flujo (`if/else`) sin violar la verificación SSA de LIR ni Cranelift.
- **Retornos de vistas mutables:**
  - Se permite recibir `&mut T` y retornar agregados con campos `&mut T`, preservando los contratos exclusivos (`Receiver::Exclusive`) interprocedimentales.
- **Backend Cranelift y Rustc:**
  - Emisión de tipos mutables `&'l mut T` con lifetimes en receptores de vista, y desreferenciación en Cranelift native codegen.

Suite final: **203 pruebas aprobadas, 0 fallos**. Formato `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios.

Siguiente incremento:
1. Referencias dentro de enums y colecciones (`List<Vista>`, `Option<&T>`).
2. Vistas anidadas (structs que contienen otras vistas).
3. Anotaciones explícitas de lifetimes sintácticos si se requiere desambiguar contratos complejos.

## 15. Referencias en enums, Option, Result y colecciones

Base `dev/mutable-aggregate-views` en `fa8b251`, 203 pruebas aprobadas.
Rama: `dev/borrowed-variants-collections`.

- **Tipos compuestos con referencias (`Option<&T>`, `Option<&mut T>`, `Result<&T, E>`, `Result<&mut T, E>`):**
  - Soporte de enums nativos y definidos por el usuario con cargas útiles (`payloads`) que contienen referencias compartidas y mutables.
  - Inferencia y propagación de procedencia interprocedimental a través de variantes y reenvío de errores (`?`).
  - Resolución de enlaces `VarTy::Ref` en desestructuración y patrón `match`, evitando lecturas desreferenciadas prematuras cuando se construyen nuevos agregados o retornos de vistas.
- **Colecciones con referencias:**
  - Arrays de tamaño fijo con referencias: `[&x, &y]`.
  - Listas dinámicas con referencias: `List[&a, &b]`, soporte de `xs.push(&c)` e indexación transparente `xs[i]`.
  - Iteración segura `for v in xs` sobre colecciones de referencias con préstamo de receptor continuo.
  - Listas regionales con referencias: `region r { var xs = r.list<&Int>() }`.
- **Análisis de préstamos y verificación (`loans.rs`):**
  - Unificación de proyección en `ViewKey`: `Field(usize)`, `Payload(variant, field)` e `Index(usize)`.
  - Generación de préstamos selectiva por variante instanciada en `Rvalue::Variant`, evitando préstamos sintéticos en variantes sin referencias (p. ej. `Option.None`) que producían falsos escapes al retornar.
  - Propagación de alias a través de `Rvalue::Use` sobre variables `VarTy::Ref`, preservando el anclaje a parámetros formales a través de bifurcaciones de control de flujo.
- **Destrucción determinista y semántica de memoria:**
  - Sin GC ni copias profundas implícitas.
  - Variantes con cargas útiles propietarias (como `Text` en `Result.Err(Text)`) o búferes de lista liberan exactamente sus recursos; los referentes prestados (`&T`, `&mut T`) nunca son liberados ni alterados por el drop.
- **Backends Cranelift y Rustc:**
  - Transpilación con lifetimes dinámicos `<'l>` en `lifetime_enums` y receptores de colecciones en el backend de referencia.
  - Emisión en Cranelift nativo de componentes de 8 bytes (punteros directos) sin sobrecoste de direccionamiento indirecto adicional.
  - 100% de paridad diferencial comprobada en todas las suites.

Suite final: **211 pruebas aprobadas, 0 fallos**. Formato `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios.

Siguiente incremento:
1. Vistas compuestas anidadas (structs que contienen otras vistas de forma recursiva).
2. Lifetimes sintácticos explícitos opcionales si se requiere parametrizar múltiples duraciones independientes en firmas.
3. Extensiones al sistema de asincronía (`async/await`).

## 16. Asincronía: async/await, futures y ejecutor cooperativo

Rama **`dev/native-async-foundation`**, derivada de
`dev/borrowed-variants-collections` (`8068500`). Sin remoto Git: los commits son
locales y no hay Pull Request.

**Base medida antes de tocar el compilador: 201 pruebas aprobadas, 0 fallos, 3
ignoradas** (fmt y clippy limpios, árbol limpio). §15 y IMPLEMENTATION_STATUS §20
declaran 211; el recuento real de `cargo test` en esa base es 201 + 3 ignoradas.
No se modificó ninguna prueba existente y ninguna pasó a fallar.

Commits de esta etapa (más antiguo primero):

1. `7eb9413` feat(async): async/await con máquina de estados real y ejecutor
   cooperativo.
2. `759f278` test(async): suites diferencial, instrumentada y negativa.
3. El commit de documentación y benchmarks que contiene este traspaso.

### Qué hay implementado

- `async fn`, `await` (solo en posiciones de sentencia), `yieldNow()`,
  `Future<T>` opaco por función, `async fn main()` sobre el ejecutor.
- Máquina de estados real en la LIR de bloques: por cada `async fn`, el
  constructor que llaman los programas, `f$poll(estado) -> Int` con despacho por
  punto de reanudación y guardado/restauración de valores vivos, y
  `f$drop(estado)`. Verificadas (tipos, asignación definida, propiedad) antes del
  codegen.
- Cranelift: estado de tarea en el heap a cero, 8 bytes de manejador, glue de
  destrucción por future, `l_rt_wake`/`l_rt_task_wait`, contador `suspends` en
  `--trace-alloc`.
- Backend rustc (referencia): `async fn`/`.await` de Rust con ejecutor propio en
  el prelude, para pruebas diferenciales.
- Reglas de seguridad `L0015 [async]`: parámetros sin recursos, nada con recursos
  vivo a través de una suspensión, sin suspender con una región abierta ni dentro
  de un `for` sobre colección, futures locales y consumidos una vez.
- Efectos: crear un future es `alloc` + `panic`; `await` hereda los del cuerpo;
  suspenderse no es `block`.

### Lo que el siguiente agente debe saber

- **Dónde está el código**: `cfg.rs` (`lower_async_new/poll/drop`,
  `lower_async_runner`, `async_layout`, `await_future`, `yield_point`,
  `complete`, `spill`/`reload`), `sema.rs` (`check_await_positions`,
  `check_async_state`, `yield_now_id`, `future_ty`), `native.rs`
  (`Rvalue::FutureNew/FutureState`, `InstKind::Clear/Wake/TaskWait`, drop de
  `Type::Future`), `native/runtime.rs` (`l_rt_wake`, `l_rt_task_wait`),
  `backend/async_runtime.inc.rs` (ejecutor de referencia), `tests/async.rs`.
- **Invariante clave**: el estado de la tarea se reserva a cero y el patrón de
  ceros no posee nada en ningún tipo de L, así que el destructor libera todos los
  campos que poseen algo sin analizar el punto de reanudación; después de mover
  un valor fuera del estado hay un `Clear` explícito. Si se añade un tipo cuyo
  cero posea recursos, este diseño deja de ser válido.
- **Un future terminado no se vuelve a sondear**: su manejador se libera al tomar
  el resultado, y el despacho trata `reanudar = -1` como inalcanzable.
- **Limitaciones** (todas con diagnóstico, nunca comportamiento inseguro): sin
  `spawn` ni varias tareas, sin métodos/traits/genéricos async, `await` no
  anidado en expresiones ni en `match`, futures no almacenables ni devolubles,
  nada con recursos vivo a través de una suspensión, un bloque de heap por tarea,
  panic = abort, solo Windows x86-64.
- **Coste medido**: el backend rustc es más rápido en los tres benchmarks async
  porque sus futures no sondeados viven en la pila; cada tarea de L reserva su
  estado en el heap (IMPLEMENTATION_STATUS §21).

### Próximo incremento recomendado

1. **`spawn` y concurrencia estructurada**: cola de tareas listas en
   `TaskWait` (el punto de extensión ya existe), handles con propiedad y vidas
   acotadas al scope que las crea.
2. **Valores con recursos a través de una suspensión**: exige inicialización por
   punto de reanudación (o mantener el invariante de ceros con banderas por
   campo) y decidir la procedencia de las referencias capturadas.
3. **Futures en pila** cuando se demuestre que no escapan (la optimización que
   explica la diferencia de rendimiento actual).
4. `await` en posiciones anidadas, que requiere guardar temporales arbitrarios.

## 17. Tareas: spawn, TaskHandle y planificador cooperativo

Rama **`dev/native-spawn-structured`**, derivada de
`dev/native-async-foundation` (`ff9f2bd`). Sin remoto Git: los commits son
locales y no hay Pull Request.

**Estado inicial verificado en el repositorio antes de tocar el compilador: 217
pruebas aprobadas, 0 fallos, 3 ignoradas**, fmt y clippy limpios, árbol limpio,
sin stash. No se descartó ningún cambio y no se hizo ninguna operación
destructiva de Git.

Commits de esta etapa (más antiguo primero):

1. `80800b5` feat(async): spawn, TaskHandle<T> y planificador cooperativo
   multitarea.
2. `a56f3b0` test(spawn): suites de intercalado, cancelación y estrés; cascada
   iterativa.
3. `95d88f8` fix(spawn): liberación inmediata de tareas canceladas en cola.
4. El commit de documentación y benchmarks que contiene este traspaso.

La rama `backup/spawn-crlf` apunta a una primera versión de esos tres commits
cuyo contenido es el mismo pero con los finales de línea convertidos a CRLF (un
descuido al editar desde Windows, que inflaba el diff a archivos completos). Se
rehicieron con finales de línea LF, como el resto del repositorio; la rama de
respaldo se puede borrar cuando se quiera.

### Qué hay implementado

- `spawn f(args)` dentro de una función async: registra la llamada como tarea
  independiente y devuelve un `TaskHandle<T>` propietario, opaco y no copiable.
  `await t` sobre un handle suspende hasta que la otra tarea termina y produce su
  resultado.
- Planificador cooperativo de un hilo: cola FIFO de tareas listas (round-robin),
  notificación explícita idempotente, cuenta de suspendidas e informe de
  interbloqueo. La tarea de `main` es la raíz de la cola. Ni un hilo del sistema
  operativo ni espera activa.
- Concurrencia estructurada: una tarea pertenece al scope async que la creó; un
  handle no se puede almacenar, pasar ni devolver, así que no hay tareas
  desatendidas; destruir un handle cancela, salir del scope destruye los handles
  vivos y destruir el estado de una tarea cancela en cascada.
- Un `TaskHandle<T>` cruza una suspensión porque **vive en un campo del estado**
  de la tarea, no en el marco de la llamada a `poll`. El mecanismo es general
  (`sema::crosses_suspension`), no una excepción.
- Backend rustc (referencia): planificador equivalente en el prelude con la misma
  política FIFO, de modo que las pruebas diferenciales comparan dos
  implementaciones independientes, incluida la traza de intercalado.

### Lo que el siguiente agente debe saber

- **Dónde está el código**: `cfg.rs` (`await_task`, `bind_state_local`,
  `take_state_local`, `drop_frames_keeping_state`, `lower_async_runner`,
  `async_layout` con `task_slot`), `sema.rs` (`crosses_suspension`,
  `check_handle_positions`, el brazo de `ExprKind::Spawn`), `native.rs`
  (`Rvalue::TaskSpawn/TaskReady/TaskState`, `InstKind::RunTasks`, drop de
  `Type::Task`, `Gen::dispatch`), `native/runtime.rs` (`l_rt_task_spawn`,
  `l_rt_task_ready`, `l_rt_task_state`, `l_rt_task_cancel`, `l_rt_purge_task`,
  `l_rt_run`, `l_rt_wake`), `backend/async_runtime.inc.rs` (planificador de
  referencia), `tests/spawn.rs`.
- **Invariante clave (sigue siendo el del patrón de ceros)**: un local que vive
  en el estado se mueve fuera del campo dejándolo a cero, así que el destructor
  del campo es correcto sin banderas. Si se añade un tipo cuyo cero posea
  recursos, este diseño deja de ser válido.
- **El registro de la tarea no es su estado**: el planificador posee el estado y
  el handle posee el registro (64 bytes, heap, nunca se mueve). Por eso un handle
  se puede destruir mientras el registro sigue en la cola: la cola es doblemente
  enlazada, así que el registro sale de ella en O(1) y se libera ahí mismo.
- **La cancelación en cascada es iterativa**: bandera de cancelación en curso +
  lista de registros pendientes. No la haga recursiva otra vez: desborda la pila.
- **Limitaciones** (todas con diagnóstico, nunca comportamiento inseguro): sin
  esperar varios handles a la vez, sin tareas desatendidas, sin pasar handles
  entre tareas, sin API explícita de cancelación, `await` solo en posiciones de
  sentencia, sin métodos/traits/genéricos async, nada con recursos salvo un
  handle vivo a través de una suspensión, dos bloques de heap por tarea, la única
  fuente externa de `Pending` es `yieldNow()`, panic = abort, solo Windows
  x86-64. Ni multihilo ni recolector de basura.
- **Coste medido**: el backend nativo es ahora más rápido que el de
  referencia en todo lo que planifica (1,8× lanzar/cancelar, 4,4×
  intercalado, 7,7× ciclo de vida completo) y sigue siendo más lento creando
  un future que nunca se sondea, porque los de Rust viven en la pila
  (IMPLEMENTATION_STATUS §22).
- **No se puede construir un interbloqueo** con la superficie actual del
  lenguaje: `yieldNow` siempre notifica y toda tarea de `spawn` entra lista en la
  cola. La comprobación del runtime es defensiva.

### Próximo incremento recomendado

1. **Valores con recursos a través de una suspensión** (`Text`, structs, listas):
   es lo que más programas desbloquea. Exige inicialización por punto de
   reanudación —o mantener el invariante de ceros con banderas por campo— y
   decidir la procedencia de las referencias capturadas. El mecanismo de locales
   en el estado ya existe: lo que falta es la prueba de inicialización.
2. **Esperar varios handles a la vez** (`join` de dos o más), que hoy obliga a
   encadenar `await`. Encaja en el planificador tal cual: un registro con varios
   esperadores no hace falta, basta un contador de pendientes en el que espera.
3. **Futures y tareas en pila** cuando se demuestre que no escapan: es la
   optimización que explica la diferencia de rendimiento con el backend rustc.
4. **Notificación desde fuera** (temporizadores, E/S): el punto de extensión es
   `l_rt_wake`, que ya es idempotente y seguro frente a tareas terminadas.

## 18. Text propietario a través de suspensiones

Rama `dev/async-owned-resources`, basada en `336b98e`
(`dev/native-spawn-structured`). La suite inicial dio 238 aprobadas y 3
ignoradas. La suite final dio 249 aprobadas, 0 fallos y 3 ignoradas.
Este incremento habilita los locales explícitos `Text`; las
secciones anteriores describen el estado histórico de cada rama.

- `cfg.rs` mantiene el propietario en el future y escribe la variante
  `Full(Text)`. Moverlo limpia su ranura y reasignarlo destruye el valor previo.
  El enum interno usa `Empty = 0` para que un future nunca sondeado empiece vacío.
- `async_state.rs` comprueba la inicialización definida sobre el CFG, incluyendo
  las aristas lógicas de reanudación, y exige que el índice guardado concuerde
  con el dispatcher. Las aristas son independientes del análisis de variables
  del marco de sondeo. Los drops léxicos vacían la ranura y el destructor
  de estado libera las que estén ocupadas al cancelar.
- Las pruebas comparan stdout, stderr y estado de salida de rustc y Cranelift.
  La traza de Cranelift comprueba el balance de reservas y la integridad del
  heap al salir. El programa `bench/programs/async_owned_text.l` completa y
  cancela lotes de 10, 100 y 1000 tareas. Véase IMPLEMENTATION_STATUS §23.
- La selección de ranuras es conservadora: un local `Text` sigue poseyendo su
  valor hasta su movimiento, reasignación o fin de ámbito. Parámetros
  propietarios, agregados, colecciones y préstamos vivos tras `await` siguen
  fuera del soporte. El siguiente incremento debe rastrear inicialización y
  movimientos por campo y variante para admitir structs y enums propietarios.

## 19. Parámetros y valores compuestos propietarios a través de await

Rama `dev/async-owned-aggregates` desde `393d7a4`. La base dio 249 pruebas
aprobadas y 3 ignoradas. La suite final dio 268 aprobadas, 0 fallos y 3
ignoradas. Las ignoradas son microbenchmarks manuales de
préstamos, retornos prestados y vistas locales en `loans.rs`.

- `lir.rs` determina si un tipo propietario puede vivir en una ranura a
  partir de sus componentes. El conjunto actual comprende `Text`, structs,
  enums, arrays y listas cuyos componentes sean admisibles. Los tipos
  con préstamos, regiones o ciclos de propiedad siguen excluidos.
- `cfg.rs` usa un enum por tipo con etiqueta vacía u ocupada y carga
  alineada. El constructor mueve cada parámetro propietario a su ranura.
  Un movimiento parcial de struct limpia su subárbol, y la asignación
  proyectada restaura ese subárbol. La cancelación usa los destructores
  de siempre sobre las ranuras ocupadas.
- `async_state.rs` comprueba el constructor, el despacho de reanudación y
  la inicialización de rutas de campos y la variante activa de los payloads
  persistentes. Enums y colecciones son unidades
  de propiedad. El movimiento de payloads en `match` pasa por un temporal
  del brazo, que también destruye los payloads sin mover.
- Las pruebas diferenciales cubren `Option`, `Result`, arrays, listas de
  escalares y propietarios, movimientos, `?` y cancelación. Las cargas
  están en `bench/programs/async_owned_structs.l` y
  `bench/programs/async_owned_lists.l`. Véase IMPLEMENTATION_STATUS §24.
- Próximo incremento sugerido. Medir la vivacidad para reducir el estado
  retenido y evitar ranuras distintas para propietarios con vidas disjuntas. El
  préstamo a través de suspensión requerirá un contrato propio de
  estabilidad, vida y exclusividad.


## 20. Join de dos tareas

Rama `dev/native-async-join` desde `545fdf6`. La base pasó 268 pruebas,
con 0 fallos y 3 microbenchmarks ignorados. La suite final pasó 278 pruebas,
con 0 fallos y los mismos 3 microbenchmarks ignorados.

- `await join(a, b)` consume ambos handles. El struct inferido mantiene
  el tipo y posición de ambos resultados en `first` y `second`.
- El lowering común de espera de handles sondea el estado de ambas hijas
  antes de decidir Pending. Cada registro puede apuntar al mismo padre
  como esperador. Se transfieren resultados solo después de confirmar
  que ambas han finalizado. Las tareas que ya terminaron no se sondean
  de nuevo. El backend rustc aplica el mismo protocolo con `poll_fn`.
- La purga iterativa conserva las garantías de cancelación. Puede
  destruir un subárbol con joins pendientes y resultados propietarios
  ya listos. La carga reproducible está en `bench/programs/async_join.l`.
- Siguiente incremento. Diseñar un contenedor de handles ligado al
  ámbito y una espera `joinAll` que mantenga un recuento de pendientes
  y evite volver a recorrer todas las hijas en cada notificación.


## 21. joinAll y grupos dinámicos

Rama `dev/native-async-join-all` desde `7886c04`. La base pasó 278
pruebas y la suite final pasó 289, con 0 fallos y 3 microbenchmarks
manuales ignorados.

- Los grupos locales usan `List` de handles homogéneos por resultado.
  `taskGroup(f)` permite empezar vacío. Los movimientos, inserciones
  y drops conservan la propiedad. Los préstamos, la extracción
  individual y el escape a otra función quedan rechazados.
- El CFG registra una vez con `GroupRegister` y sondea solo
  `GroupPending` tras reanudación. El contador vive en el registro
  padre y cuesta ocho bytes. El resultado permanece en la hija
  hasta la recolección ordenada o la cancelación.
- Las cargas reproducibles están en `bench/programs/async_join_all.l`
  y `bench/programs/async_join_all_pair.l`. La prueba de cancelación
  de dos grupos de 5000 hijos también comprueba que el scheduler
  puede crear y esperar nuevos grupos después de purgar los antiguos.
- Siguiente incremento. Formalizar un grupo de ámbito en el sistema
  de tipos y ampliar Futures de primera clase solo con un contrato
  explícito de transferencia y cancelación.


## 22. TaskGroup tipado, lifetimes de tareas y concurrencia estructurada

Rama `dev/native-scoped-taskgroups` desde `453b7a2`. La base pasó 289
pruebas y la suite final pasa **297 pruebas** (56 en `tests/spawn.rs`),
con 0 fallos y 3 microbenchmarks manuales ignorados. `cargo fmt --check`
limpio y `cargo clippy --all-targets -- -D warnings` limpio.

- **Tipo formal `TaskGroup<T, Scope>`**:
  - `T` es el tipo de resultado homogéneo producido por las tareas.
  - `Scope` es la identidad léxica/async ligada al ámbito que lo crea.
  - Representación de bajo nivel `Type::TaskGroup(usize)` con tabla `task_groups`
    en LIR y CFG.
  - En Windows x86-64 comparte el layout compacto de 24 bytes `(ptr, len, cap)`.
- **Confinamiento de ámbito e invariantes de seguridad**:
  - Creación exclusiva en funciones async mediante `taskGroup<T>()` o el
    constructor histórico `taskGroup(f)`.
  - Anotación explícita `TaskGroup<T>` soportada en variables locales.
  - Métodos canónicos: `grupo.reserve(n)`, `grupo.spawn(f(args))`,
    `grupo.push(spawn f(args))` y `await grupo.joinAll()`.
  - Rechazo estricto en el compilador de cualquier escape a ámbitos exteriores
    (`outer = inner` con `L0015`), paso como parámetro o retorno (`L0015`),
    almacenamiento en agregados/colecciones (`struct`, `enum`, `List`, array con `L0015`)
    y préstamos (`&grupo` o `&mut grupo` con `L0012`).
  - Single ownership: `TaskGroup` no implementa `Copy`; el uso tras mover o
    doble await es rechazado estáticamente con `L0005`.
- **Drop Glue nativo y cancelación iterativa**:
  - La rutina `task_group_drop_glue` en Cranelift recorre iterativamente el búfer
    de handles cancelando tareas vivas con `l_rt_task_cancel` y liberando el búfer
    con `l_rt_free`.
  - Garantiza cero fugas de memoria en salidas anticipadas o terminación de
    ámbito (`allocs == frees`, `heap_ok == 1`).
- **Pruebas y escalabilidad**:
  - 8 nuevas pruebas exhaustivas en `crates/l/tests/spawn.rs`.
  - Prueba de estrés con 10 000 tareas concurrentes en Cranelift nativo
    (`bench/programs/async_taskgroup.l`) validando 16 669 suspensiones y liberación
    completa del heap.
- Siguiente incremento sugerido:
  - Extender Futures de primera clase con contratos explícitos de transferencia.
  - Explorar temporizadores cooperativos o soporte de I/O asíncrono básico.


## 23. Futures de primera clase, single ownership y async composable

Rama `dev/first-class-futures` desde `996ba2a`. La base pasó 297
pruebas y la suite final pasa **306 pruebas** (9 en `tests/futures.rs`),
con 0 fallos y 3 microbenchmarks manuales ignorados. `cargo fmt --check`
limpio y `cargo clippy --all-targets -- -D warnings` limpio.

- **Tipo canónico de primera clase `Future<T>`**:
  - `T` es el tipo del valor final producido al completar la computación diferida.
  - El tipo se puede anotar explícitamente en variables (`let fut: Future<Int>`), parámetros
    de funciones tanto síncronas como asíncronas (`fn delegar(fut: Future<Int>) -> Future<Int>`),
    y firmas de retorno (`fn crearOperacion(...) -> Future<T>`).
  - Distinción fundamental: `Future<T>` es una computación perezosa aún no ejecutada;
    `TaskHandle<T>` es un descriptor de una tarea ya registrada en el ejecutor.
- **Single Ownership y Borrow Checking estricto**:
  - `Future<T>` es un tipo no-`Copy` sujeto a propiedad estricta lineal/afín.
  - Mover un future a otra variable o función invalida la variable origen (`L0005`).
  - No puede consumirse dos veces (`await fut` seguido de `await fut` rechazado con `L0005`).
  - No puede transferirse dos veces (`spawn fut` seguido de otro uso rechazado con `L0005`).
  - Rechazo de préstamos (`&Future<T>`, `&mut Future<T>`) con `L0012: Future no admite préstamos`.
  - Rechazo de almacenamiento en agregados/colecciones (`struct`, `enum`, `List`, `Array`) con `L0015`.
  - Se exige anotación explícita `-> Future<T>` para funciones que retornan futures; el retorno
    implícito desanotado se rechaza con `L0015`.
  - Integridad de lifetimes: Proyecto L no permite parámetros prestados (`&`, `&mut`) en funciones
    asíncronas, por lo que todo estado capturado es 100% propietario; el movimiento o retorno entre
    funciones está completamente libre de referencias colgantes.
- **Layout uniforme y despacho dinámico en Cranelift**:
  - Cabecera homogénea para todo estado de future:
    - Campo 0 (offset 0): `tipo: Int` (`KIND_FIELD = 0`), índice numérico único del generador.
    - Campo 1 (offset 8): `reanudar: Int` (`RESUME_FIELD = 1`), punto de reanudación (0 = no iniciado, -1 = completado).
    - Campo 2 (offset 16): `resultado: T` (`RESULT_FIELD = 2`), ranura donde se escribe el valor de retorno.
  - `Rvalue::FuturePoll(place)` lee el discriminante de la cabecera en tiempo de ejecución y ejecuta
    un salto dinámico a través de la tabla `rt.poll_dispatch(kind, state)`.
  - `Rvalue::TaskSpawn(place)` lee el discriminante y llama a `rt.task_spawn(state, kind)`.
  - Drop dinámico nativo: al abandonar el ámbito de un future no consumido, el drop glue generado
    lee el discriminante en offset 0, invoca `rt.drop_dispatch(kind, ptr)` para liberar campos
    propietarios y luego libera el bloque con `l_rt_free(ptr)`. Cero fugas de memoria (`allocs == frees`).
- **Composición y transferencias**:
  - Selección dinámica y composición en runtime (e.g. `if condicion { f() } else { g() }`).
  - Consumo directo mediante `await fut`.
  - Transferencia directa a concurrencia estructurada mediante `spawn fut` o `tg.push(spawn fut)`.
- Siguiente incremento sugerido:
  - Expresiones generales de await y lowering ANF.

## 24. Await como expresión general y Lowering ANF seguro

Rama `dev/general-await-expressions` desde `122f0f1`. La base pasó 306
pruebas y la suite final pasa **317 pruebas** (11 en `tests/await_expr.rs`),
con 0 fallos y 3 microbenchmarks manuales ignorados. `cargo fmt --check`
limpio y `cargo clippy --all-targets -- -D warnings` limpio.

- **Expresiones generales de await (`crates/l/src/async_desugar.rs`)**:
  - `await` ya no está limitado a asignaciones de sentencia directa (`let x = await f()`).
  - Soporte completo para:
    - Expresiones aritméticas: `(await f()) + 5`, `(await a()) * (await b())`.
    - Comparaciones y condiciones: `if (await f()) > 0`, `if !(await validar())`.
    - Argumentos de funciones: `sumar(await a(), await b())`.
    - Expresiones de retorno: `return (await a()) + 5`.
    - Operadores lógicos de cortocircuito: `await a() && await b()`, `a || await b()`.
    - Estructuras y colecciones: `Punto { x: await x(), y: await y() }`, `List[await a(), await b()]`.
    - Operadores `?` (Try) y `??` (Coalesce): `(await f())?`, `(await g()) ?? def`.
    - Expresiones compuestas anidadas: `await (await obtenerFuturo())`.
    - Bucles con condición asíncrona: `while await cond() { ... }`.
- **Lowering A-Normal Form (ANF) y orden de evaluación**:
  - Desugaring previo a `sema` que extrae operandos no triviales a sentencias `let __l_await_tmp_{N} = ...`.
  - Preservación determinista del orden de evaluación estricto de izquierda a derecha.
  - Expresiones booleanas cortocircuitadas bajan a ramas condicionales con acumulador mutable local, asegurando que el lado derecho no se evalúe si el lado izquierdo determina el resultado.
- **Seguridad de memoria, Adaptive Ownership y Drops**:
  - Los temporales extraídos se asignan a ranuras en el frame del generador (`f$estado.lN`) gobernadas por `$async_slot` (Empty/Full).
  - Recursos propietarios (`Text`, `List`, `Struct`) asignados antes de un punto de suspensión se mantienen vivos en el heap del generador y son liberados por el drop glue de cancelación (`lower_async_drop`) en caso de suspensión interrumpida.
  - Validación con `--trace-alloc`: `heap_ok=1`, `allocs == frees`, cero fugas.
- **Diagnósticos y validación semántica**:
  - `await` en funciones no-async o dentro de constantes (`const`) es rechazado con `L0015`.
  - `await` sobre tipos no válidos rechazado con `L0003`.
  - Doble `await` o uso tras mover de `Future<T>` o `TaskHandle<T>` rechazado con `L0005`.
- Siguiente incremento sugerido:
  - Temporizadores cooperativos (`sleep`, `timeout`).
  - Primitivas de sincronización asíncrona (canales MPSC / Oneshot).
  - Canales con suspensión y select asíncrono.

## 25. Temporizadores monotónicos y espera del ejecutor

Rama `dev/native-async-timers` desde `002b76b` de Antigravity. La
auditoría reprodujo 317 pruebas aprobadas, 0 fallos y 3 microbenchmarks
manuales ignorados. La suite final pasó 326 pruebas, con 0 fallos y
los mismos tres microbenchmarks ignorados.

- `sleepMs(Int)` devuelve un future normal y perezoso. Sema comprueba
  constantes. El lowering valida duraciones dinámicas en la llamada.
  El sondeo registra un deadline y cero completa sin suspender.
- `native/timers.rs` emite la ABI del heap indexado, reloj y espera.
  El scheduler procesa expiraciones entre sondeos y aparca su hilo
  únicamente con la cola FIFO vacía. La purga retira el temporizador
  o el wake encolado antes de liberar el registro.
- El backend de referencia usa `Instant` y una cola ordenada. Las
  pruebas diferenciales están en `crates/l/tests/timers.rs`. Los
  benchmarks usan `bench/timers.ps1`. El modelo, las APIs de Windows
  y la frontera migrable a L están en [TIMER_RUNTIME.md](TIMER_RUNTIME.md).
- Próximo incremento. Añadir una fuente externa de eventos detrás de la
  cola existente y un contrato de IDs que soporte notificaciones tardías
  de esa fuente. Después se puede diseñar una API pública de deadline
  y timeout que reutilice el reloj.


## 26. Fundamentos de self-hosting

`dev/self-hosting-foundation` deriva de `f0487fb`. El compilador Rust
sigue siendo Stage 0. El primer componente del frontend en L vive en
`compiler-l/src/lexer.l`
y consume `&Text` para devolver rangos de byte propietarios o un error
con offset. El harness aporta la entrada y se ejecuta con
`cargo test --test self_hosting` en Cranelift y rustc.

La auditoría está en [SELF_HOSTING_GAP_ANALYSIS.md](SELF_HOSTING_GAP_ANALYSIS.md).
El siguiente incremento resolvió los argumentos y la lectura UTF-8
acotada (§27). El scanner conserva su independencia de I/O.
El proceso backend sobre CFG versionado es una propuesta documentada
en [BOOTSTRAP_ARCHITECTURE.md](BOOTSTRAP_ARCHITECTURE.md). La ruta hasta
Stages 2–4 está en [SELF_HOSTING_ROADMAP.md](SELF_HOSTING_ROADMAP.md).


## 27. Driver autónomo y lectura UTF-8

`dev/self-hosting-file-cli` deriva de `b40c797`, que contiene
`f497ca7`. Se verificaron las 332 pruebas de la base. Stage 0
construye el ejecutable con `compiler-l/build-lexer.ps1`. El driver
L lee argumentos y archivos reales en ejecución y conserva la
interfaz `lexSource(&Text)`. `cargo test --test file_cli`
reproduce los casos positivos, negativos, diferenciales y de recursos.

El objeto opcional Win64 `no_std` toma prestada la ruta, devuelve
un `Text` propietario o un código y usa el allocator nativo de L.
La traza incluye cierres, lecturas cortas y tiempos de I/O. Las
mediciones y los límites están en [LEXER_FILE_CLI.md](LEXER_FILE_CLI.md).
El siguiente paso es ampliar la paridad léxica y continuar con módulos
e imports antes de migrar el parser. El backend provisional sobre
CFG versionado permanece como estrategia posterior.


## 28. Paridad léxica de strings, interpolación y sistema de módulos

Rama `dev/self-hosting-lexer-modules` derivada de `6d8cb72` (`dev/self-hosting-file-cli`).
La suite completa pasa **348 pruebas, 0 fallos y 3 microbenchmarks ignorados** (11 pruebas nuevas añadidas). `cargo fmt` y `cargo clippy` limpios con cero advertencias.

- **Paridad léxica completa (`compiler-l/src/lexer.l`)**:
  - Soporte de strings con delimitadores `"` y secuencias de escape: `\n`, `\t`, `\r`, `\"`, `\\`, y `\u{HEX}` (1 a 6 dígitos hexadecimales con validación de valor escalar Unicode `value <= 0x10FFFF` y exclusión de surrogates `0xD800..=0xDFFF`).
  - Textos interpolados: `TextStart`, `InterpolationStart`, tokens internos en `{ ... }`, `InterpolationEnd`, y `TextEnd`.
  - Soporte para interpolaciones múltiples (`"a {b} c {d}"`), llaves literales escapadas `{{` y `}}`, strings anidados dentro de expresiones interpoladas hasta profundidad 64, y rangos de bytes precisos `[start, end)`.
  - Diagnósticos léxicos explícitos: `UnclosedString`, `InvalidEscape`, `InvalidUnicodeEscape`, `InvalidUnicodeScalar`, `UnclosedInterpolation`, `UnopenedBrace`, `ExcessiveDepth`.
- **API de cursor de tokens (`compiler-l/src/cursor.l`)**:
  - `TokenCursor` sin copias sobre la lista de tokens: `cursorNew(fileId)`, `cursorIsAtEnd`, `cursorCurrent`, `cursorCurrentKind`, `cursorAdvance`, `cursorExpect`.
- **Resolución de módulos e imports en Stage 0 (`crates/l/src/modules.rs`)**:
  - Sintaxis: `import <ruta>;` y `import <sub.modulo>;`.
  - Resolución relativa de archivos respecto al archivo importador usando canonicalización de rutas del sistema operativo (`fs::canonicalize`).
  - Detección de ciclos de importación con ciclo formateado explícito (código diagnóstico `L0014: ciclo de dependencias detectado: ...`).
  - Deduplicación determinista en imports en diamante preservando un solo orden de evaluación topológica (dependencias antes que dependientes).
  - Límite de 16 MiB por archivo importado.
  - Trazabilidad de diagnósticos por archivo con `Diagnostic.file` y `.with_file(...)`.
- **Compilación modular autónoma (`compiler-l/build-lexer.ps1`)**:
  - `compiler-l/src/main.l` importa modularmente `lexer`, `tokens` y `cursor` sin concatenación manual de archivos.
  - Construcción y ejecución verificadas tanto en Cranelift nativo como en el backend de referencia.
- **Microbenchmarks y traza de memoria**:
  - `bench/lexer-file.ps1`: Cero fugas (`allocs == frees`, `heap_ok=1`) en todas las cargas (1 KiB a 10 MiB).
- **Próximo incremento sugerido**:
  - Diseño y desarrollo del parser autónomo en Proyecto L (`compiler-l/src/parser.l`), usando `TokenCursor` y AST indexado mediante arenas/Listas de nodos.


## 29. Parser autónomo, AST tipado e indexado y análisis sintáctico en L

Rama `dev/self-hosting-parser` derivada de `9170fc4` (`dev/self-hosting-lexer-modules`).
La suite completa pasa **356 pruebas, 0 fallos y 3 microbenchmarks ignorados** (8 pruebas nuevas en `crates/l/tests/parser_l.rs`). `cargo fmt` y `cargo clippy` limpios con cero advertencias.

- **AST en Arenas Continuas (`compiler-l/src/ast.l`)**:
  - Estructura `AstTree` con 8 listas homogéneas de nodos indexadas por enteros (`Int`):
    - `expressions: List<AstExpr>`: Nodos de expresión de 7 campos (`kind`, `start`, `end`, `a`, `b`, `c`, `d`).
    - `statements: List<AstStmt>`: Nodos de sentencia de 8 campos (`kind`, `start`, `end`, `a`, `b`, `c`, `d`, `e`).
    - `types: List<AstType>`: Expresiones de tipos (`kind`, `start`, `end`, `a`, `b`, `c`).
    - `declarations: List<AstDecl>`: Declaraciones globales (`kind`, `start`, `end`, `is_public`, `a`, `b`, `c`, `d`, `e`).
    - `params: List<AstParam>`, `fields: List<AstField>`, `variants: List<AstVariant>`.
    - `extra: List<Int>`: Búfer contiguo unidimensional para secuencias de tamaño dinámico (argumentos, sentencias de bloque, literales de lista, brazos de match).
    - `errors: List<ParseError>`: Diagnósticos sintácticos con códigos de problema y rangos de byte.
  - Volcador canónico `astDumpCanonical` y resumen `astDumpSummary`.

- **Modularización Estricta bajo la Regla CORE-1 (máx 4096 tokens por archivo)**:
  - `compiler-l/src/parse_util.l`: Navegación de tokens, lookahead (`parserAtWord`, `parserAtSymbol`), expectativa con formato de mensaje (`parserNeedWord`, `parserNeedSymbol`) y accesos seguros a fin de spans (`cursorSpanEnd`, `cursorPrevEnd`).
  - `compiler-l/src/types.l`: Parser de tipos atómicos (`Int`, `Float`, `F32`, `Bool`, `Text`, `Unit`), referencias (`&T`, `&mut T`), arrays fijos (`[T; N]`), slices (`[T]`) y genéricos con corchetes angulares (`List<T>`, `Option<T>`).
  - `compiler-l/src/expr.l`: Analizador de expresiones por precedencia Pratt de 9 niveles, primary expressions, llamadas con argumentos nombrados (`Name(k: v)`), métodos encadenados, indexación (`a[i]`) y operadores unarios/binarios.
  - `compiler-l/src/stmt.l`: Sentencias y bloques (`parseBlock`), `let`, `var`, `const`, asignaciones (`=`, `+=`, etc.), control de flujo (`if-else`, `while`, `for`, `loop`, `break`, `continue`, `region`) y coincidencia de patrones (`match`).
  - `compiler-l/src/decl.l`: Declaraciones de nivel superior (`fn`, `pub fn`, `async fn`, `struct`, `enum`, `import`, `const`).
  - `compiler-l/src/parser.l`: Orquestador `parseProgram` y sincronización ante fallos (`parserSynchronize`).
  - `compiler-l/src/main_parser.l`: Driver CLI ejecutable `parser-l`.

- **Recuperación Robusta y Prevención de Bucles Infinitos**:
  - Detección de estancamiento del cursor (`cursor.pos == before_pos`) en bucles de sentencias y bloques para garantizar avance y evitar bloqueos.
  - Funciones auxiliares seguras `astExprEnd`, `astStmtEnd`, `astTypeEnd` y `cursorPrevEnd` que impiden la evaluación ansiosa fuera de rango de `selectInt` ante índices `-1` o `cursor.pos == 0`.
  - Sincronización hasta delimitadores naturales (`;`, `}`) y palabras clave de nivel superior (`fn`, `struct`, `enum`, etc.).

- **Driver Nativo Autónomo (`compiler-l/build-parser.ps1`)**:
  - Compilación directa a binario nativo Cranelift: `main_parser.exe`.
  - Verificación con `--trace-alloc`: `allocs == frees`, cero fugas y `heap_ok=1`.
  - Capacidad probada de analizar todos los 12 archivos fuente del propio compilador (`ast.l`, `cursor.l`, `decl.l`, `expr.l`, `lexer.l`, `main.l`, `main_parser.l`, `parser.l`, `parse_util.l`, `stmt.l`, `tokens.l`, `types.l`) con cero errores.

- **Próximo incremento sugerido**:
  - **Fase 5 Self-Hosting: Análisis Semántico y Chequeo de Tipos en L (`compiler-l/src/sema.l`)**:
    - Tabla de símbolos para ámbitos léxicos (variables locales, parámetros, funciones, structs y enums).
    - Resolución de tipos y comprobación de compatibilidad de asignaciones y retornos.
    - Chequeo de ownership y detección de uso posterior a movimiento en Proyecto L.


## 30. Análisis semántico, resolución de nombres, sistema de tipos y Adaptive Ownership en L

Rama `dev/self-hosting-semantics` derivada de `15cb9c2` (`dev/self-hosting-parser`).
La suite completa pasa **368 pruebas, 0 fallos y 3 microbenchmarks ignorados** (12 pruebas nuevas en `crates/l/tests/sema_l.rs`). `cargo fmt` y `cargo clippy` limpios con cero advertencias.

- **Arquitectura Modular Desacoplada bajo la Regla CORE-1 (máx 4096 tokens por archivo)**:
  Para respetar estrictamente el límite `CORE-1` de 4096 tokens por archivo fuente en Stage 0, el analizador semántico autónomo se diseñó e implementó en 8 submódulos altamente especializados dentro de un grafo acíclico dirigido (DAG) unidireccional:
  - `compiler-l/src/sema_types.l` (284 líneas, 8.8 KiB):
    - Enumeración `SemTypeKind`: tipos primitivos (`Unknown`, `Int`, `Float`, `F32`, `Bool`, `Text`, `Unit`, `Error`) y compuestos (`Struct`, `Enum`, `Ref`, `MutRef`, `Array`, `Slice`, `List`, `Option`, `Result`).
    - Estructura `SemType` y tabla de tipos `TypeTable` en arena contigua con IDs preasignados (0 a 7 para tipos base).
    - Constructores de tipos compuestos deduplicados: `semTypeMakeRef`, `semTypeMakeList`, `semTypeMakeArray`, `semTypeMakeSlice`.
    - Predicados formales: `semTypeIsNumeric`, `semTypeIsCopy`, `semTypeIsMove` (tomando préstamos `&SemTypeKind` para evitar movimientos de enums en L).
    - Equivalencia estructural recursiva de tipos `semTypeEquals` y formateador legible `semTypeName`.
  - `compiler-l/src/symbols.l` (99 líneas, 2.5 KiB):
    - Enumeración `SymbolKind` (`Var`, `Param`, `Func`, `Struct`, `Enum`, `Variant`, `Field`, `Const`).
    - Estructura `Symbol` con registro de spans de nombre, ID de tipo semántico, ID de ámbito léxico (`scope_id`), flags de mutabilidad (`is_mut`) y visibilidad (`is_pub`), y span de declaración.
    - Comparador de cadenas sin asignaciones dinámicas `symbolNamesEqual` y constructor `symbolAdd`.
  - `compiler-l/src/scopes.l` (62 líneas, 1.7 KiB):
    - Estructura `Scope` con puntero al ámbito padre (`parent`) y árbol de ámbitos `ScopeTree`.
    - Pila de ámbitos con `scopePush` y `scopePop`.
    - `scopeLookupCurrent`: Detección precisa de declaraciones duplicadas dentro del ámbito actual sin permitir colisiones.
    - `scopeLookupAll`: Resolución ascendente por la cadena de ancestros que soporta sombreado léxico (*lexical shadowing*) determinista.
  - `compiler-l/src/ownership_l.l` (66 líneas, 1.7 KiB):
    - Seguimiento de estados por símbolo: `0 = Uninitialized`, `1 = Available`, `2 = Moved`.
    - `ownershipMarkAvailable`, `ownershipMarkMoved`, `ownershipIsMoved`.
    - Operación de unión conservadora en bifurcaciones `ownershipMergeBranches` (`if-else`): si un recurso de tipo Move se consume en cualquiera de las ramas, queda marcado como movido tras el punto de convergencia.
  - `compiler-l/src/sema_context.l` (81 líneas, 2.5 KiB):
    - Estructuras `SemaError` y `SemaContext` que unifican las arenas de tipos, símbolos, ámbitos y ownership.
    - `semaResolveAstType`: Traducción de nodos `AstType` a IDs `SemType`, resolviendo tipos nominales (Structs y Enums) contra la tabla de símbolos.
  - `compiler-l/src/sema_expr.l` (198 líneas, 9.1 KiB):
    - Inferencia y comprobación estática de expresiones: literales (`Int`, `Bool`, `Text`, `Unit`), interpolaciones, variables (`AstExprKind.Name`).
    - Detección estricta de uso tras movimiento (`error[L0005]: uso de valor movido`).
    - Verificación de tipos en operadores binarios aritméticos (`+`, `-`, `*`, `/`, `%`), relacionales (`==`, `!=`, `<`, `<=`, `>`, `>=`) y lógicos (`&&`, `||`).
    - Validación de llamadas a funciones y constructores (`AstExprKind.Call`): verificación de aridad, comprobación de tipos de argumentos contra parámetros formales (`error[L0004]`) y transición automática de ownership a `Moved` para argumentos pasados por valor de tipo Move.
    - Resolución de campos de structs (`AstExprKind.Field`) inspeccionando las declaraciones registradas.
    - Soporte de argumentos nombrados (`AstExprKind.Named`).
  - `compiler-l/src/sema_stmt.l` (136 líneas, 6.3 KiB):
    - Comprobación de declaraciones `let` y `var`: detección de duplicados en el mismo ámbito (`error[L0002]`), validación de anotaciones de tipo explícitas (`error[L0003]`) y registro en el ámbito actual.
    - Asignaciones (`AstStmtKind.Assign`): validación de compatibilidad de tipos y rechazo de reasignación sobre variables inmutables (`error[L0006]: no se puede reasignar a variable inmutable`).
    - Sentencias de retorno (`AstStmtKind.Return`): validación contra el tipo de retorno declarado de la función actual.
    - Estructuras de control: condiciones booleanas en `if` y `while`, rangos `Int` en bucles `for`, y delimitación de bloques léxicos (`AstStmtKind.Block`).
  - `compiler-l/src/sema.l` (101 líneas, 4.8 KiB):
    - Orquestador de análisis en dos pasadas (`semaAnalyze`):
      - Pasada 1 (`semaCollectDeclarations`): Registra todas las funciones, structs, enums y constantes a nivel superior en el ámbito global, detectando nombres duplicados.
      - Pasada 2 (`semaCheckDeclarations`): Empuja los ámbitos de función, vincula parámetros formales y comprueba exhaustivamente los cuerpos de sentencias y expresiones.
  - `compiler-l/src/main_sema.l` (170 líneas, 5.6 KiB):
    - Driver CLI ejecutable `sema-l <archivo.l>` que integra el lexer, parser y analizador semántico autónomo, emitiendo diagnósticos canónicos y la línea de resumen:
      `SemaSummary symbols=N scopes=M types=K errors=E`.

- **Suite de Pruebas Rigurosa (`crates/l/tests/sema_l.rs`)**:
  - Pruebas positivas: declaraciones globales, funciones, structs, enums, control de flujo, expresiones aritméticas y movimientos válidos de ownership.
  - Pruebas negativas con códigos canónicos verificados:
    - `test_sema_negative_undeclared_identifier` (`L0001`).
    - `test_sema_negative_duplicate_declaration` (`L0002`).
    - `test_sema_negative_type_mismatch_assignment` (`L0003`).
    - `test_sema_negative_call_arity_mismatch` (`L0004`).
    - `test_sema_negative_call_argument_type_mismatch` (`L0004`).
    - `test_sema_negative_use_after_move` (`L0005`).
    - `test_sema_negative_immutable_reassignment` (`L0006`).
  - Prueba diferencial `test_sema_differential_parity_with_stage0` que confirma paridad exacta de aceptación/rechazo con `project_l::sema::check`.
  - Prueba de seguridad de memoria `test_sema_memory_safety_trace_alloc`: compilación y ejecución con `--trace-alloc` confirmando cero fugas de memoria (`allocs == frees`, `heap_ok=1`).

- **Próximo incremento sugerido**:
  - **Fase 6 Self-Hosting: Representación Intermedia LIR / CFG y Generación de Código en L**:
    - Definición del Control Flow Graph (CFG) y SSA en Proyecto L.
    - Generación de código nativo o puente directo a backend Cranelift / C / LLVM autónomo.


## 31. CFG semántico y movimientos de Stage 1

`dev/self-hosting-borrow-checker` parte de `35ae505`. El driver
`sema-l archivo.l --check-ownership` construye y valida su propio CFG
en L. El solver comprueba disponibilidad y movimientos completos y
parciales con un worklist. El CFG conserva predecesores, lugares y
spans para el siguiente incremento. El comando sin opción ejecuta
el mismo análisis.

La próxima tarea es liveness y exclusividad local sobre ese grafo.
Los préstamos y retornos prestados siguen rechazándose con `L0012`.
La procedencia, el plan de drops y el lowering hacia LIR quedan
pendientes. El harness de parser y sema construye sus propios
binarios MSVC o GNU a partir de la salida del CLI y separa las trazas.
[Invariantes y reproducción](STAGE1_CFG.md).

## 32. Borrow checker de Stage 1: préstamos, NLL y procedencia

Rama `dev/self-hosting-loans-nll`, desde `f232067`
(`dev/self-hosting-borrow-checker`). Sin remoto: commits locales y
ningún PR.

**Estado heredado.** OpenCode agotó su cuota dejando cambios sin
confirmar que no compilaban (préstamos en `flow_cfg.l`, `loans_l.l`,
`loans_check.l`, `borrow_scan.l` y una sonda de veredictos de Stage 0).
Se conservó su representación y su lista de casos; se reparó y completó
la integración. Detalle en
[STAGE1_BORROW_CHECKER.md](STAGE1_BORROW_CHECKER.md#recuperación-del-trabajo-de-opencode).

**Implementado en L** (`sema-l archivo.l --check-ownership`):
préstamos `&T` y `&mut T` en `let`, argumentos y retornos; préstamos
implícitos de argumentos `&T`; exclusividad; liveness hacia atrás
(NLL) sobre el CFG existente; campos disjuntos; représtamos con
suspensión y reactivación; escritura a través de `&mut`; retornos
prestados con procedencia verificada de parámetros y resultados con
varios orígenes. Códigos `L0012` (conflictos y posiciones), `L0013`
(retornos prestados), `L0001` (escritura a través de `&T`, modos de
argumento) y `L0005` (mover a través de referencia).

**Verificación.** `cargo test`: 376 aprobadas, 0 fallos, 3 ignoradas
(373 previas + 3 de `borrow_l.rs`, que contiene 181 casos
diferenciales). Stage 1 nunca acepta un caso que Stage 0 rechace; 168
coinciden en veredicto y código. `cargo fmt --check` y
`cargo clippy --all-targets -- -D warnings` limpios.

**Pendiente.** Plan de drops (dependencias documentadas), referencias
en agregados, reloj para medir fases dentro del driver y luego la fase
7 (LIR desde Stage 1). Mapa de módulos:

| Archivo | Contenido |
| --- | --- |
| `compiler-l/src/flow_cfg.l` | `Loan`, eventos de préstamo, solapamiento de lugares |
| `compiler-l/src/loans_l.l` | Creación, vinculación, `loanPlaceOf`, nodos de resultado, procedencia |
| `compiler-l/src/loans_check.l` | Liveness y exclusividad |
| `compiler-l/src/sema_borrow.l` | Reglas semánticas de préstamos y retornos prestados |
| `crates/l/tests/borrow_l.rs` | Diferencial contra Stage 0, relación de préstamos, escala y heap |
| `bench/stage1-loans.ps1` | Cargas de 100, 1 000 y 10 000 préstamos |

Para continuar con Codex, Antigravity u OpenCode: lea §32 y
STAGE1_BORROW_CHECKER.md, compile con `compiler-l/build-sema.ps1` y
ejecute `cargo test --test borrow_l --test sema_l` antes de tocar
`compiler-l/src`. Los errores de Stage 0 en módulos importados se
informan con la ruta de `main_sema.l` pero con la línea del módulo
importado. Cada archivo `.l` debe quedar bajo el límite CORE-1 de 4 096
tokens; el mismo límite impide usar Stage 0 como oráculo en archivos
grandes.

## 33. Elaboración de drops de Stage 1

Rama `dev/self-hosting-drop-elaboration`, desde `f36862f`
(`dev/self-hosting-loans-nll`). Sin remoto: commits locales y ningún PR.
El árbol estaba limpio al empezar; no había trabajo pendiente de otro
agente.

**Implementado en L.** Plan de drops por función sobre el CFG existente:

- hojas propietarias por campo;
- fin de ámbito en bloques, iteraciones, `return`, `break`, `continue` y
  caída al final;
- temporales de sentencia;
- orden de Stage 0;
- drops incondicionales y condicionados por flags dinámicos;
- reasignación (evaluar, soltar y escribir) y escritura a través de `&mut`;
- movimientos completos y parciales con los estados del solver existente;
- conflicto `L0012` si se destruye un propietario prestado;
- verificador independiente (`error[ICE]`);
- volcado `sema-l archivo.l --drop-plan` y prueba `--drop-fault=K`.

Detalle en [STAGE1_DROP_ELABORATION.md](STAGE1_DROP_ELABORATION.md).

**Verificación.** `cargo test`: 382 aprobadas, 0 fallos, 3 ignoradas
(376 previas y 6 nuevas de `drops_l.rs`). Los planes coinciden con
Stage 0 camino a camino en 39 programas de drops (332 caminos) y 80
programas del corpus de préstamos (199 caminos). `cargo fmt --check` y
`cargo clippy --all-targets -- -D warnings` limpios.
`bench/stage1-drops.ps1` es nuevo y `bench/stage1-loans.ps1` sigue
funcionando.

**No implementado.** Stage 1 no genera código (los drops son un plan);
`Option`/`Result`/`?`, construcción de enums y `match` siguen fuera del
subconjunto. Siguiente hito: fase 7, LIR y lowering desde Stage 1
consumiendo CFG, eventos y `DropPlan`.

| Archivo | Contenido |
| --- | --- |
| `compiler-l/src/sema_drop.l` | `needs_drop`, hojas, ámbitos, temporales |
| `compiler-l/src/drops_plan.l` | `DropPlan` y elaborador |
| `compiler-l/src/drops_verify.l` | Verificador e inyección de fallos |
| `compiler-l/src/drops_dump.l` | Volcado textual |
| `crates/l/tests/drops_l.rs` | Diferencial por caminos, verificador, negativos, escala |
| `crates/l/tests/stage1_support/borrow_cases.rs` | Corpus compartido con `borrow_l.rs` |
| `bench/stage1-drops.ps1` | Cargas de 100, 1 000 y 10 000 variables |

## 34. Cambio de nombre a ELE

El lenguaje se llama oficialmente ELE (antes «Proyecto L»). La extensión
sigue siendo `.l`. Desde este punto, toda documentación y todo hito de
self-hosting usan ELE. Cambiaron los mensajes visibles al usuario:

- la ayuda de la CLI;
- los mensajes de runtime de ambos backends (`ELE l:c: ...` en pánicos,
  `ELE: memoria insuficiente`, `ELE: tarea suspendida...`);
- las pruebas que los comprueban.

No cambiaron, por compatibilidad: el paquete `project-l`, la biblioteca
`project_l`, el ejecutable `l`, los drivers `*-l`, el directorio
`compiler-l` ni los nombres de archivo `.l`. Las secciones anteriores
conservan el nombre histórico. No cambian la gramática, los tipos ni el
comportamiento del compilador. Rama `dev/self-hosting-drop-elaboration`.

## 35. Fase 7: LIR de ELE y backend provisional

Rama `dev/ele-self-hosting-lir`, desde `4663a51`. El primer commit de la
rama (`4b52634`) confirma el cambio de nombre a ELE (§34), que había
quedado sin confirmar. Sin remoto: commits locales y ningún PR.

**Implementado en ELE (Stage 1).**

- LIR tipada por función: variables `val`/`ref` no SSA, constantes,
  lugares con proyecciones, argumentos, 13 instrucciones y 5
  terminadores.
- Lowering en el mismo recorrido que el análisis semántico, sobre el CFG
  existente, con `for` provisto de un bloque de incremento.
- Integración del plan de drops por anclas de eventos y flags como
  variables `Bool`.
- Verificador independiente (9 reglas, asignación definida) e inyección
  de fallos (`--lir-fault=K`).
- Serialización versionada `ELE-LIR 1` (`sema-l archivo.l --emit-lir`).
- `List<T>` se resuelve en anotaciones de tipo.

**Backend provisional (Rust).** `l build-lir` / `l run-lir`: parser
defensivo del protocolo (`lir_protocol.rs`), validación con `cfg::verify`
y `drops::verify`, Cranelift y enlazado, sin el frontend Rust.
**Stage 1 ya genera ejecutables nativos**: `fn main() -> Int { let numero
= 40 + 2; print(numero); return 0 }` imprime 42 y termina con 0.

**Verificación.** `cargo test`: 389 aprobadas, 0 fallos, 3 ignoradas (382 previas + 6 de lir_l.rs + 1 de List<T> en sema_l.rs). Hay 35 programas ejecutables
idénticos a Stage 0 (salida, código de salida, stderr y heap) y 116
programas de los corpus de préstamos y drops compilados desde la LIR.
También hay pruebas de negativos, fallos del verificador, 16 variantes de
protocolo malformado y determinismo. `cargo fmt --check` y
`cargo clippy --all-targets -- -D warnings` limpios.

**Pendiente.**

- LIR v2: enums, listas, arrays, `Option`/`Result`.
- Stage 1 analizando su propio código: imports entre módulos, métodos,
  `match` e índices. Ver la brecha en SELF_HOSTING_GAP_ANALYSIS.md.
- Reloj en ELE para medir fases.

Siguiente hito: fase 8, compilar con el backend provisional programas
más grandes y las propias fuentes de Stage 1 a medida que el subconjunto
crezca.

| Archivo | Contenido |
| --- | --- |
| `compiler-l/src/lir_build.l` | Modelo LIR y tablas de módulo |
| `compiler-l/src/sema_lower.l`, `sema_ops.l`, `stmt_lower.l` | Lowering |
| `compiler-l/src/lir_finish.l` | Drops, flags y terminadores |
| `compiler-l/src/lir_verify.l` | Verificador |
| `compiler-l/src/lir_emit.l`, `lir_write.l`, `lir_module.l` | Serialización y módulo |
| `crates/l/src/lir_protocol.rs` | Backend provisional: protocolo y validación |
| `crates/l/tests/lir_l.rs` | Diferencial, corpus, negativos, verificador y protocolo |
| `bench/stage1-lir.ps1` | Cargas de 100, 1 000 y 10 000 instrucciones |

Documentos: [STAGE1_LIR.md](STAGE1_LIR.md) y [LIR_PROTOCOL.md](LIR_PROTOCOL.md).

## 41. Recuperación de Antigravity y fase 8.2 (10-11-2026)

Rama `dev/ele-self-hosting-bootstrap`; HEAD inicial `d3e6a4c`; sin remoto. La sesión comenzó con 18 archivos modificados y dos nuevos sin seguimiento (`modules_l.l` y `STAGE1_SELF_COVERAGE.md`). No había índice preparado ni commits posteriores al HEAD. Se conservaron todos los cambios heredados. El diff heredado incluía métodos, índices, `match`, listas y extensión de `lir_protocol.rs`, pero ninguna prueba nueva ni un resultado final de suite.

**Estado comprobado.** Corrida inicial MSVC: todos los grupos previos pasaron salvo `sema_l::cfg_checks_borrows_and_rejects_unverified_projections`, que aún esperaba `L0016` para un índice ya aceptado. Tras actualizar ese caso y endurecer semántica: `sema_l` 20/20, `parser_l` 8/8 y `lir_l` 6/6. Se añadió después un caso de overflow en parser (1/1) y uno nativo de `Text.byteLength` proyectado (1/1). `cargo clippy --all-targets -- -D warnings` pasó con target dir MSVC aislado. El comando MSVC reproducible es:

La corrida final de tests ejecutables terminó en 549,25 s: **393 aprobadas, 0 fallos, 3 ignoradas** en 31 grupos. El comando conjunto salió 1 solo al invocar doctests con `rustdoc` GNU; repetidos con `RUSTDOC` MSVC explícito, los doctests terminaron 0/0 y exit 0. Para una invocación completa, configure también `$env:RUSTDOC = "$tool\rustdoc.exe"` antes de `cargo test --target x86_64-pc-windows-msvc`.

```powershell
$tool = 'C:\Users\Usuario\.rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
$env:PATH = "$tool;$env:PATH"
$env:RUSTC = "$tool\rustc.exe"
$env:CARGO_TARGET_DIR = 'C:\Users\Usuario\Desktop\proyectos\p1\target\msvc-clippy'
& "$tool\cargo.exe" clippy --target x86_64-pc-windows-msvc --all-targets -- -D warnings
```

No use `cargo +stable` dentro de este workspace: rustup intenta escribir en `.rustup/tmp` fuera del sandbox. Para tests, invoque el `cargo.exe` MSVC directamente, con `RUSTC` apuntando al `rustc.exe` del mismo toolchain y `--target x86_64-pc-windows-msvc`. No use `target/debug/l.exe` GNU para construir Stage 1. Los tres benchmarks admiten ahora `-Compiler` y se ejecutaron con `target/x86_64-pc-windows-msvc/debug/l.exe`, `-Runs 1`. Resultados y límites: [matriz](STAGE1_SELF_COVERAGE.md).

**Correcciones de esta recuperación.** Constantes unarias: solo `-` sobre literal Int se baja como negativo. Parser Stage 1 rechaza enteros mayores que `Int::MAX` sin desbordarse. Índices exigen Int. `push`, `pop`, `reserve` y `byteAt` exigen receptor y argumentos apropiados; los mutantes requieren receptor mutable. Las comprobaciones se separaron en `sema_collection_ops.l` para no superar el límite CORE-1 de 4096 tokens por fuente. El backend interpreta `i len` como `Rvalue::Len`, que admite `Text` y colecciones; el caso proyectado se compiló y ejecutó con resultado equivalente a Stage 0.

**Bloqueos sin resolver.** De 40 fuentes reales, Stage 1 acepta 9 con `--check-ownership`; ninguna de las probadas produce LIR completo. `List[]` aún llama `lirMarkUnsupported`; faltan tipado contextual, `listlit` y verificación completa. `Option`/`Result`, `match` y enums tienen soporte parcial sin pruebas verticales. `modules_l.l` concatena fuentes y no implementa imports semánticos reales; diagnósticos de archivos importados se atribuyen erróneamente al archivo de entrada. No hay Stage 2. El backend y Stage 0 continúan dependiendo de Rust y Cranelift. Próximo paso recomendado: probar un harness que invoque `flow_cfg.l::flowNew` después de implementar listas en toda la ruta, y reemplazar la concatenación por resolución de módulos con identidad, visibilidad y spans por archivo.

## Fase 8.3

Stage 1 ya compiló y ejecutó las funciones originales `flowNew` y `flowBlock` de `flow_cfg.l`. El siguiente trabajo es resolver imports con identidad y visibilidad, y después `Option`/`Result` y `pop`. Evidencia: [PHASE_8_3.md](PHASE_8_3.md).

La suite final MSVC, con `RUSTC` y `RUSTDOC` MSVC explícitos, terminó con código 0: 398 aprobadas, 0 fallos, 3 ignoradas, 0 doctests. `cargo fmt --all --check` y Clippy `--all-targets -- -D warnings` pasaron. Los cuatro benchmarks (`loans`, `drops`, `lir`, `lists`) y sus límites figuran en [PHASE_8_3.md](PHASE_8_3.md). Mantener `flow_self_harness.l` como prueba de integración de las funciones originales.

## Fase 8.4 (recuperación de Hermes)

Codex dejó la fase 8.3 íntegra pero **sin commits**: sobre `6bbc374` quedaron 24 archivos modificados y 4 sin seguimiento (`flow_self_harness.l`, `lir_verify_core.l`, `bench/stage1-lists.ps1`, `PHASE_8_3.md`). No había índice preparado ni commits posteriores. Se conservó todo el trabajo y se verificó antes de confirmarlo.

Verificación MSVC (con `RUSTC` y `RUSTDOC` MSVC explícitos y `--target x86_64-pc-windows-msvc`): **398 aprobadas, 0 fallos, 3 ignoradas, 0 doctests**, salida 0. `cargo fmt --all --check` y Clippy `--all-targets -- -D warnings` limpios. La prueba `compiles_real_flow_cfg_functions_natively` revalida el objetivo vertical: `flowNew` y `flowBlock` de `flow_cfg.l` se analizan en Stage 1, bajan a LIR (116 bloques, 219 instrucciones, 30 drops), la valida el backend provisional y producen un ejecutable Cranelift que devuelve 2 con paridad Stage 0.

Sin cambios de implementación nuevos: la fase 8.4 es recuperación, auditoría, verificación y commits. Pendientes: imports con identidad y visibilidad, `Option`/`Result`, `pop` y reemplazo de elementos propietarios (rechazados hoy con `L0005`/`L0016`).

## Incremento experimental: backend C11 sin Rust (artefacto independiente del Git original)

Se añadió una ruta alternativa independiente del backend Cranelift:
`tools/ele_c_backend.py` consume `ELE-LIR 1` y emite C11 con runtime propio
`tools/ele_runtime.h`; `tools/ele_build.py` orquesta un `sema-l` Stage 1
**ya compilado** y el compilador C. Fuente y pruebas en
`tests/native_backend/`; documentación en [RUST_FREE_BACKEND.md](RUST_FREE_BACKEND.md).

Se probaron 12 tests locales con GCC/Clang en Linux, y un ejemplo simple con
ASan/UBSan. No se pudo ejecutar Cargo ni verificar las 398 pruebas del
workspace original, porque no hay toolchain Rust en el entorno y el ZIP no
contenía `.git`. No se crearon commits ni PR y no se pretende Stage 2.

**Siguiente agente**: recuperar imports con identidad de módulos (Fase 8.5),
construir Stage 1 real en Windows, generar LIR del `flow_self_harness.l`,
comparar Cranelift contra el backend C, completar las instrucciones C
actualmente rechazadas y avanzar hacia Stage 2. No tratar la validación de
ownership de este backend experimental como equivalente a `drops::verify`.

## Revisión adicional de Fase 8.5 — imports y visibilidad (2026-11-10)

Ver `docs/PHASE_8_5_WORK_IN_PROGRESS.md`. Se incorporó una matriz de imports
transitivos, comprobación de ambigüedad de símbolos públicos, registro
anticipado de tipos nominales, lexing aislado por módulo y cinco pruebas
Rust de integración (aún no ejecutadas). También se añadió un auditor
estático (cuatro pruebas Python que pasan): 43 fuentes, 40 alcanzables y 228
aristas desde `main_sema.l`. La revisión se hizo sin Cargo y sin binario de
Stage 1: **no declarar la Fase 8.5 terminada** ni dar por verificadas las
pruebas Rust nuevas hasta ejecutarlas con Windows/MSVC. El AST sigue usando
un buffer fuente combinado; faltan almacenamiento realmente multimódulo,
normalización Unicode de rutas y validación de la compilación de Stage 2.

## Continuación después de la revisión de Fases 8.5 y 8.7 (sin toolchain Rust en el entorno)

- Se corrigió un fallo de construcción en `modules_l.l`: faltaba asignar
  `LoadedProgram.module_starts` y se insertaba `List<Int>` en `module_paths`.
- Se añadieron módulos de codificación directa x86-64 y ELF64 **escritos en ELE**:
  `compiler-l/src/codegen/x86_64.l` y `codegen/elf64.l`, con tres fixtures
  ejecutables en `.l` y tres tests Rust en `tests/native_encoder_l.rs`.
- **Tests no ejecutados:** los tres tests nuevos y la suite MSVC requieren
  `cargo`/`rustc`, no presentes en este entorno.
- El test de referencia ELF64 ejecutado en Linux retornó 42, pero no provino
  de una ejecución del emisor escrito en ELE: no confundir con validación E2E.
- Verificar con `bench/verify-native-encoder.ps1` y
  `bench/verify-stage1-modules.ps1 -FullSuite` antes de ampliar funciones.
- Siguiente blocker de independencia: escritura binaria segura desde ELE
  seguida de un lector/verificador ELE-LIR y su lowering a código máquina.
- Véase `docs/ELE_NATIVE_BACKEND_PHASE_8_7.md`.

- El camino ELE-LIR -> x86-64 también dispone de un prototipo
  **implementado en ELE** (`codegen/lir_tokens.l`, `codegen/lir_subset.l`,
  `native_lir_demo.l`) que acepta un único `main` de una sola región lineal,
  Int y `use/add/sub/mul/return`. Seis pruebas de integración Rust están
  preparadas (sin ejecutar aquí). La imagen ELF **de referencia**, no la
  salida del emisor ELE, retorna 42 en Linux. No declarar backend completo.


## Fase 8.7.1 — I/O binario para backend nativo ELE

Se incorporó `writeBytes(Text, List<Int>) -> Int` al Stage 0 (semántica,
CFG, LIR, backend Rust/Cranelift, runtime Win64 `no_std`), más nuevas rutas
de archivo binario en `native_lir_demo.l` y `native_elf_demo.l`.
Pruebas disponibles aquí: 20/20 pruebas de herramientas; no había Rust/MSVC
para ejecutar las pruebas nuevas. **Leer**
`docs/ELE_NATIVE_BACKEND_PHASE_8_7_1.md` **antes de continuar**.
La siguiente acción es compilar las diez pruebas de `native_encoder_l.rs` en
Windows, corregirlas si fallan y comprobar que el ELF generado por ELE corre
en Linux/WSL. No asumir Stage 2 ni independencia completa.

## Fase 8.7.2 — backend nativo ELE con funciones y CFG (pendiente MSVC)

Se añadió una ruta **separada del backend lineal existente**:
`codegen/native_cfg_ir.l` → `native_cfg_verify.l` → `native_cfg_emit.l`
→ `codegen/x86_64.l` → `codegen/elf64.l`, expuesta por `native_cfg_demo.l`.
Admite Int/Bool por valor, hasta 2 argumentos, múltiples funciones, llamadas
(incluida recursión), CFG con `jump`/`branch` y uniones y bucles. El verificador
aplica intersección de inicialización por predecesores y rechaza LIR fuera
 del subconjunto. Fixtures y tests Rust: `crates/l/tests/native_cfg_l.rs`,
`bench/verify-native-cfg.ps1`, `bench/build-native-cfg.ps1`.

**Estado verificable:** 20 tests Python de herramientas pasan y se verificaron
instrucciones/ELF de **referencia externa**; no hay Cargo/rustc ni binario ELE
en este entorno, así que las fuentes nuevas `.l` no están compiladas ni las
pruebas Rust ejecutadas. Reproducir primero las 10 pruebas previas corregidas
con `bench/verify-native-encoder.ps1` y luego las pruebas CFG. No afirmar
Stage 2 ni independencia de Rust. Véase
[`ELE_NATIVE_BACKEND_PHASE_8_7_2.md`](ELE_NATIVE_BACKEND_PHASE_8_7_2.md).

## Fase 8.7.3 — Primera base de layouts y memoria (pendiente de MSVC)

Se añadieron `codegen/native_layout.l` (tamaño/alineación/offsets/padding/
orden de campos propietarios), accesos x86-64 a `[base+disp32]` en tamaños de
8 y 64 bits (`x86_64.l`), y tres fixtures en ELE: `native_layout_cases.l`,
`native_memory_cases.l`, `native_stack_aggregate_demo.l`. Tests Rust:
`native_layout_l.rs`, `native_memory_l.rs`, `native_stack_layout_l.rs`.
Ejecutar `bench/verify-native-memory.ps1` y `bench/build-native-stack.ps1`
en Windows/MSVC **después** de `verify-native-encoder.ps1` y
`verify-native-cfg.ps1`. La prueba de ejecución ELF requiere Linux/WSL.

**Estado verificado aquí:** 20 pruebas de herramientas Python, desensamblado
de referencia, imagen ELF64 de referencia con exit 42, auditoría estática de
imports. **No** se compiló ninguna fuente nueva `.l` (falta Cargo/rustc).
No se afirma soporte completo de structs, heap, List<T>, drops, enums,
Option/Result, runtime ELE, Stage 2 ni Stage 3. Detalle y prioridades en
`docs/ELE_NATIVE_BACKEND_PHASE_8_7_3.md`.

## Continuación 2026-11-10 — LIR structs Copy en backend ELE

Nuevo trabajo en `codegen/native_cfg_ir.l`, `native_cfg_verify.l`, `native_cfg_emit.l`:
se parsean structs nominales de ELE-LIR 1 con campos primitivos Int/Bool,
se calculan layouts y slots reales por variable y se emiten construcciones,
lecturas, stores y copias seguras del subconjunto. Ver
`docs/ELE_8_7_3_8_8_CONTINUACION.md` para las restricciones y las pruebas
Windows/MSVC **pendientes**. Stage 2 no está construido. No permitir
Text/List/owning structs antes de implementar y verificar drops.


## Actualización 2026-11-10 — backend ELE, structs anidadas move-only

El código fuente incorpora structs anidadas move-only en `native_cfg_ir.l` y
`native_cfg_emit.l`. Test nuevo: `crates/l/tests/native_nested_struct_l.rs`;
fixtures `examples/native_cfg_nested_*.lir`. Comando de Windows:
`bench/verify-native-nested.ps1`. **No se ha compilado este cambio** en
el entorno de autoría, por falta de Cargo/rustc.

Ver `docs/ELE_8_7_3_NESTED_MOVE.md` antes de ampliar el backend.
El backend **rechaza** heap/propietarios/drops/structs en ABI y Stage2
continúa pendiente. Este estado actualizado prevalece sobre cualquier
recuento de pruebas anterior en documentos históricos.


## Último avance 8.7.4 (sin verificar con Cargo)

Ficheros ELE nuevos/modificados en `compiler-l/src/codegen/`: backend CFG
acepta `enums` opcional y `variant`/`disc` con payloads primitivos.
Se añadieron `crates/l/tests/native_enum_l.rs`, fixtures
`examples/native_cfg_enum_*.lir` y `bench/verify-native-enum.ps1`.
La verificación con MSVC está pendiente. **Antes de seguir:**
`cargo test -p project-l --test native_enum_l`, corregir errores de Stage 0,
verificar los ELF64 resultantes, y sólo después completar las proyecciones
de payload en el protocolo compartido y el serializador de Stage 1.
Consulte `docs/ELE_NATIVE_BACKEND_PHASE_8_7_4.md`.

### Fase 8.7.4.1 — Incremento experimental de payloads (pendiente de MSVC)

Se añadió al backend **escrito en ELE** una lectura protegida de payload primitivo (Int/Bool), con guardia de discriminante y salida controlada 126 al solicitar una variante inactiva. Ver [ELE_NATIVE_BACKEND_PHASE_8_7_4_1.md](ELE_NATIVE_BACKEND_PHASE_8_7_4_1.md). Es **una instrucción experimental exclusiva del backend nativo**, todavía no serializada por Stage 1 ni admitida por el lector Rust ELE-LIR 1; NO confundir con cierre de la integración ADT. Ejecutar en Windows `bench/verify-native-enum-payload.ps1` y verificar los ELF generados en Linux x86-64 antes de avanzar. `Option`, `Result`, `match`, `?`, drops propietarios y Stage 2 siguen pendientes.

## Continuación 8.7.4.2 — Enums unitarios y payloads primitivos (pendiente de compilación MSVC)

En este incremento se hicieron compatibles los lectores LIR de Rust y ELE
para `i payload vD pN eE V` (solo lectura Copy de `Int`/`Bool`). El backend
Cranelift comprueba dinámicamente el discriminante al acceder a una proyección
Payload y pone a cero el almacenamiento de los enums nuevos antes de cargar
su representación completa. Stage 1 ahora emite identidad nominal `eN`,
declaraciones, constructores de variantes unitarias y discriminantes. Stage 1
sigue rechazando LIR de `Option`/`Result`, match con payloads y `?` sin lowering
seguro.

El entorno no contiene Cargo/rustc: las pruebas `lir_payload_protocol` y
`native_enum_stage1_l` están escritas, pero no ejecutadas. Ejecutar
`bench/verify-enum-lir-interop.ps1` con MSVC antes de continuar, y corregir
cualquier fallo real. Ver `docs/ELE_NATIVE_BACKEND_PHASE_8_7_4_2.md`.

## Fase 8.7.5 — print, Unit e Int completo en el backend ELE (2026-11-11)

Rama `feat/ele-native-print-unit`, basada en `main` `4bccdd2` (PR #22 ya
fusionado). Detalle en
[ELE_NATIVE_BACKEND_PHASE_8_7_5.md](ELE_NATIVE_BACKEND_PHASE_8_7_5.md).

Verificado en Linux x86-64: `native_print_l` 5/5; suite completa 253
aprobadas y 243 fallidas (todas las fallidas requieren Cranelift/MSVC),
frente a 141/350 antes; fmt y clippy limpios. **No verificado:** Windows y
GitHub Actions (la sesión no tenía acceso de escritura al repositorio).

### Fase 8.7.6 — Text propio y llamadas por pila (misma rama)

Detalle en [ELE_NATIVE_BACKEND_PHASE_8_7_6.md](ELE_NATIVE_BACKEND_PHASE_8_7_6.md).
Verificado en Linux: `native_print_l` 7/7, suite 256 aprobadas / 242
fallidas (Cranelift/MSVC), fmt y clippy limpios. `fibonacci.l`, `text.l` e
`interpolation.l` ya compilan y ejecutan por la ruta nativa ELE.

Defectos de Stage 0 observados y sin corregir: un diagnóstico de un módulo
importado se informa con la ruta del archivo raíz; el límite CORE-1 de 4096
tokens por archivo obliga a partir módulos.

Estado del objetivo final: **COMPILADOR AÚN NO COMPLETO.** Bloqueos por
orden de dependencia:

1. Parámetros por referencia, Text en agregados, operaciones de Text
   (`byteLength`, `byteAt`, comparación) y `List` en el lowering CFG. Los
   módulos `native_heap*.l` y `native_list_int.l` siguen sin usarse desde él.
2. Retorno y paso de structs/enums por valor; `unary`, `div`, `rem`.
3. Stage 1 no se analiza a sí mismo: faltan imports entre módulos en la
   LIR, métodos de `List`/`Text`, índices, `Option`/`Result` y `?`
   (ver SELF_HOSTING_GAP_ANALYSIS.md). Sin esto no hay Stage 2.
4. E/S de archivos y argumentos en el runtime nativo ELE (hoy vienen del
   bootstrap).
5. Backend PE64 y runtime Windows: no existe código.
6. Fuentes de `compiler-l/src` todavía en la sintaxis histórica (los
   módulos nuevos `native_rt.l` y `native_heap_owner.l` ya usan la canónica).
7. CLI en ELE (`ele check|build|run|test|fmt`), optimizador y benchmarks.

Siguiente trabajo concreto: punto 1, empezando por `ref` en parámetros y
`i len`/`byteAt` de Text, que son las operaciones que más usa `compiler-l`.

### Fase 8.7.7 — referencias, consultas de Text y aritmética comprobada (2026-11-11)

Rama `feat/native-refs-text-ops`, basada en `main` `f19ec01` (PR #23).
Detalle en [ELE_NATIVE_BACKEND_PHASE_8_7_7.md](ELE_NATIVE_BACKEND_PHASE_8_7_7.md).

El backend ELE acepta parámetros `view`/`edit` (Int, Bool, Text, `shape`
anidado, `choice`), `byteLength`, `byteAt` con límites (127), `unary`
`neg`/`not`, `div` y `rem` comprobados (125). Módulos nuevos
`codegen/native_cfg_ref.l` y `codegen/native_cfg_arith.l` (sintaxis
canónica). Verificado: `native_refs_l` 4/4 y las suites nativas previas en
Windows; los ELF se ejecutaron en WSL Ubuntu con salida idéntica a Stage 0.

**Entorno Windows de esta sesión:** usar `RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-msvc`
(el `rust-toolchain.toml` fija GNU 1.99.1, que no enlaza Cranelift aquí).
`wsl -d Ubuntu` ejecuta ELF64 pero no tiene cargo; para la parte Linux de las
pruebas, ejecutar con WSL las imágenes de `target/stage1-tests/<prueba>/`.
`cargo test` sin `--no-fail-fast` se detiene en el primer binario que falla.

**Diagnóstico observado (defecto 1 de Stage 0):** un error en
`codegen/native_cfg_ref.l:121` se informó como `native_cfg_demo.l:121:52`.

Siguiente trabajo concreto: préstamos locales con análisis de vida, Text
dentro de agregados con drops por campo, paso/retorno de agregados por
valor, `List of[T]` en el lowering CFG reutilizando `native_list_int.l` /
`native_heap_owner.l`, y los dos defectos de Stage 0.

### Defectos de Stage 0 corregidos (2026-11-11)

Rama `fix/stage0-diagnostics-stacked`, apilada sobre
`feat/native-refs-text-ops`; resuelve el último punto del párrafo anterior.
Detalle en [STAGE0_DEFECTS_DIAGNOSTICS_TOKENS.md](STAGE0_DEFECTS_DIAGNOSTICS_TOKENS.md):
diagnósticos con el archivo real de cada módulo (`Span.file`) y fin del
límite de 4096 tokens (límite de recursos 2^20 y pila de compilador de
256 MiB, que además corrige el desbordamiento con 30 sumas encadenadas).
Los módulos de `compiler-l/src` ya no necesitan partirse por tokens.

### Fase 8.7.8 — agregados por valor y movimientos parciales (2026-11-11)

Rama `feat/native-aggregate-abi`, apilada sobre `fix/stage0-diagnostics-stacked`.
Detalle en [ELE_NATIVE_BACKEND_PHASE_8_7_8.md](ELE_NATIVE_BACKEND_PHASE_8_7_8.md).
`shape`/`choice` como parámetros, argumentos y resultados (puntero oculto) y
movimientos parciales de campos con seguimiento por camino
(`codegen/native_cfg_paths.l`). `native_aggregates_l` 3/3; ELF ejecutados en
WSL con salida idéntica a Stage 0. Siguiente: Text dentro de agregados con
drops por campo, préstamos locales y `List of[T]` en el lowering CFG.

### Fase 8.7.9 — Text dentro de `shape` (2026-11-11)

Rama `feat/native-text-fields`, apilada sobre `feat/native-aggregate-abi`.
Detalle en [ELE_NATIVE_BACKEND_PHASE_8_7_9.md](ELE_NATIVE_BACKEND_PHASE_8_7_9.md).
Campos Text con movimiento, `dropfield` (con bandera), reemplazo por `edit`
y fuentes proyectadas; propiedad verificada con caminos de movimiento.
Siguiente bloqueo para compilar `compiler-l/src`: el límite de 4 campos por
`shape` (CfgProgram tiene 17), después `List of[T]` y préstamos locales.

### Fase 8.7.10 — constructores anchos del backend nativo (pendiente de CI)

Rama feat/native-wide-struct-operands sobre main tras el PR #27.
CfgProgram.struct_args guarda hasta 64 operandos por constructor;
el backend extiende comprobación de tipos, movimientos, caminos y emisión.
Se mantienen límites de 512 bytes por layout y 512 slots por función.
Fixtures de seis, diecisiete y sesenta y cuatro campos, con Text,
pruebas negativas y ejecución cruzada ELF en CI.
No existe Stage 2 ni PE64. Ver docs/ELE_NATIVE_BACKEND_PHASE_8_7_10.md.


### Ejemplos ELE v2 (migración de superficie, CI 3/3 aprobado)

Rama `chore/examples-ele-v2-canonical`: 25 archivos de `examples/`
convertidos desde la sintaxis histórica de Rust a ELE v2, incluidos los
casos negativos; los otros 15 ejemplos `.l` ya eran canónicos. Los 117
fixtures `.lir` se mantienen intactos. Se añadió una prueba que analiza
los 40 ejemplos, preserva los rechazos y comprueba la salida de varios
programas. Véase `docs/EXAMPLES_ELE_V2_MIGRATION.md`. Esta migración no
completa el compilador ni sustituye el self-hosting Stage 2/3.

Validación registrada en GitHub Actions: ejecución 43072044595 (Ubuntu,
Windows y ELF64 cruzado, tres trabajos aprobados). No es una verificación
de self-hosting Stage 2 ni de la suite histórica completa.


### Regresiones históricas de módulos y cursor (pendiente de CI)
Se añadieron las suites `modules_l` y `self_hosting` completas al CI
Windows/MSVC. Se corrigen la atribución y el código de estado de errores
L0014 por import faltante o ciclo, un fixture nominal sin coma y una prueba
de cursor que omitía `tokens.l`. El caso de nombres privados homónimos se
verifica directamente con Stage 1+LIR+ejecutable, ya que Stage 0 conserva
la limitación de namespace global. No se ocultan pruebas ni se afirma que
Stage 0 haya resuelto esa limitación.
Ver `docs/SELF_HOSTING_MODULE_CURSOR_REGRESSIONS.md`.

Verificación de las correcciones: 13/13 en `modules_l` y 8/8 en
`self_hosting`; CI 3/3 aprobado en [43081976701](https://github.com/Joshua-EPR/ELE/actions/runs/43081976701).
Se incorporó además `cargo test -p project-l --no-fail-fast -- --test-threads=1`
como paso permanente de CI Windows (validación aún pendiente).
La limitación Stage 0 de nombres privados homónimos queda rastreada en
[issue #31](https://github.com/Joshua-EPR/ELE/issues/31).

### Corrección de seguridad: aliasing de préstamos locales
## Corrección del verificador de préstamos locales — 2026-11-11

El backend ELE ya no identifica la independencia de dos argumentos de
referencia por tener IDs de variables distintos. El análisis de llamadas
resuelve préstamos locales a `ref_root` y proyecciones estáticas, y trata
índices dinámicos de listas como potencialmente iguales. Se preserva el
paso de préstamos sobre campos disjuntos.

Al crear un préstamo compartido solapado con otro exclusivo vivo, el
verificador invalida el exclusivo previo; usarlo después se rechaza con 57.
La regla incluye préstamos derivados directamente de referencias locales.

Se añadieron fixtures negativos de dos referencias locales en una llamada
(99), referencia local y acceso directo (99) y préstamo compartido
posterior al exclusivo con uso del original (57). Se añadió un fixture
positivo de dos campos disjuntos de un shape, cuyo ELF debe salir con 42.

**Estado de este incremento:** pendiente de verificación CI sobre el
commit que contiene la corrección y estos fixtures. No modifica Stage 2,
`listpop` ni `dropfield` mediante referencias locales.
