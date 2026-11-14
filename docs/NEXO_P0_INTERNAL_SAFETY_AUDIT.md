# NEXO P0 — auditoría interna de cierre y pánicos

## Alcance y referencia

Auditoría de las limitaciones 2 (cierre/`Drop`) y 5 (`expect`, índices y
desbordamientos) sobre el commit `d6b03289edf9d0888fa11d81c70b7f574de49969`.
Las líneas de esta nota están ancladas a ese commit. Se excluyen los `unwrap` de
pruebas y ejemplos. Durante la auditoría había cambios concurrentes sin commit
en `physical/address_space.rs`; no se modificaron ni se usaron para atribuir
garantías al `HEAD`.

Clasificación usada:

- **P0**: puede romper identidad, memoria o el contrato de no pánico con entrada
  pública razonable.
- **P1**: fallo silencioso de disponibilidad/recursos o supuesto interno no
  representado por tipos.
- **P2**: desbordamiento teórico o pánico que requiere agotar un contador de 64
  bits; debe cerrarse para una afirmación formal de ausencia de pánicos.
- **Acotado**: la aritmética o el índice están demostrablemente acotados por el
  constructor y el flujo seguro actuales.

## Resultado ejecutivo

No se encontró liberación doble ni uso después de liberar en la API segura.
`AddressSpace::release` y `PhysicalPool::close` conservan el dueño cuando la
liberación explícita falla y, por tanto, permiten reintentar. El defecto de la
limitación 2 está en el último recurso: `AddressSpace::drop` descarta un error
real de `platform::release`, y `PhysicalPool` no tiene un cierre propietario que
obligue al llamador a observar el resultado. Si se omite `close`, también se
pierde el diagnóstico de `live`/`holes`.

No hay `unwrap()` de producción en estos dos archivos. Sí hay dos `expect` sobre
superpáginas inicializadas y un `unwrap_or` que convierte un error de observación
en `Protected`. Los primeros dependen de invariantes no expresadas por tipos; el
segundo no paniquea, pero puede ocultar estado físico desconocido. También hay
desbordamientos no controlados en el plan de fallos, métricas y el identificador
global del pool. No se halló una entrada pública de tamaño/índice que alcance
memoria fuera de rango: las rutas correspondientes están acotadas por
`max_superpages`, `slots_per_subpage` y `locate`.

## Limitación 2: cierre explícito y `Drop`

| Ubicación | Clasificación | Hecho y causa | Propuesta tipada | Prueba necesaria |
| --- | --- | --- | --- | --- |
| `physical/address_space.rs:395-406` | Acotado | `release(&mut self)` marca `released` solo después del éxito del backend. Un error conserva la reserva y permite reintentar; un segundo éxito es idempotente. | Mantener esta primitiva. Añadir una API propietaria `try_close(self) -> Result<ClosedAddressSpace, CloseFailure<AddressSpace, PhysicalError>>`, donde el error devuelve explícitamente el dueño. | Éxito, doble cierre, fallo antes de liberar y reintento; ya existen en `address_space.rs:643` y `:655`. Añadir un backend simulado cuyo primer `release` real falle y el segundo tenga éxito, no solo `FaultPlan`. |
| `physical/address_space.rs:471-477` | **P1** | `Drop` desactiva el fallo inyectado de `Release`, intenta una vez y descarta el resultado. Un fallo real del SO deja una fuga de espacio de direcciones sin señal observable. No produce UAF porque `released` solo cambia tras éxito. | `Drop` debe seguir siendo infalible, pero delegar a una política explícita: cierre propietario obligatorio en capas superiores y un `ReleaseObserver`/registro inyectable que contabilice el fallo terminal. No hacer bucles ilimitados dentro de `Drop`. | Backend de liberación inyectable con observador externo: exactamente un intento en `Drop`, incremento de `terminal_release_failures`, ausencia de doble liberación y prueba de que `try_close` devuelve el dueño reintentable. |
| `physical/pool.rs:915-926` | Acotado con brecha P1 de API | `close(&mut self)` rechaza `live != 0` o `holes != 0`; ante error de `release` no toma el `Option`, por lo que el pool sigue abierto. Solo borra `pending`/`deferred` tras liberar toda la reserva. Después del éxito, `space = None` hace que las operaciones físicas devuelvan `Closed`. | Ofrecer `try_close(self) -> Result<ClosedPool, CloseFailure<PhysicalPool, PoolError>>`. `ClosedPool` puede contener únicamente el informe final; `CloseFailure` devuelve el pool. Conservar temporalmente `close(&mut self)` como adaptador. | Fuga viva, fuga de hueco, reclamación pendiente, fallo de `Release` y reintento, cierre doble y llamadas posteriores. `physical.rs:213` y `recuperacion.rs:295` cubren parte; falta fuga de hueco aislada y la API consumidora. |
| `physical/pool.rs:390-404` (sin `impl Drop`) | **P1** | Al caer `PhysicalPool`, cae implícitamente `space`; se omite el chequeo `live`/`holes` y cualquier error terminal de liberación queda en el `Drop` anterior. Un `Handle` descartado por el usuario deja `live > 0`, pero el proceso no recibe diagnóstico. | Un guard de sesión `OpenPool` con `#[must_use]` y cierre consumidor; un observador de fugas en `Drop` solo como telemetría, nunca como sustituto de `try_close`. | `must_use`/compile-fail para ignorar el resultado de cierre; prueba con `Handle` olvidado que el cierre explícito devuelve `Leak`; observador externo al dejar caer el pool sin cerrar. |

Un registro persistente de reservas no liberadas permitiría reintentos fuera de
`Drop`, pero cambia la propiedad global y necesita diseño explícito: no debe
introducir un puntero reutilizable ni afirmar que una liberación fallida es
segura de reintentar en todos los backends sin conocer su contrato.

## Limitación 5: pánicos, índices y desbordamientos

### Sitios que requieren corrección o tipado

| Ubicación | Clasificación | Causa | Propuesta tipada | Prueba necesaria |
| --- | --- | --- | --- | --- |
| `physical/pool.rs:931-940` | **P1** | `meta` y `meta_mut` indexan `superpages[sp]` y hacen `expect("superpágina inicializada")`. Hoy los llamadores reciben `sp` de `DensityIndex`, `locate` tras validar, o las colas internas. La relación “índice presente implica `Some`” no está en el tipo y una desincronización interna paniquea en vez de producir `PoolError::Invariant`. | Introducir `InitializedSuperpage(usize)` creado únicamente al instalar `Some`, y hacer que densidad/pendientes/diferidos guarden una clave tipada; alternativamente, que `meta*` devuelva `Result<_, PoolError>` en límites de reparación. | Fuzzer determinista con `catch_unwind` sobre secuencias públicas; pruebas de propiedades tras cada transición. Para probar corrupción interna, test unitario privado que inyecte una clave huérfana y espere `Invariant`, no pánico. |
| `physical/pool.rs:356-385` | **P1** | `DensityIndex::set/contains/first` indexan buckets y words sin validar. Las llamadas actuales cumplen `1 <= free <= slots_per_subpage <= 64` y `g < max_superpages*15`, pero el contrato es implícito; un bit residual en `summary` también puede seleccionar un bucket inexistente. | `FreeCount(NonZeroU8)`, `GlobalSubpage` y un `DensityIndex::key(...) -> Result<DensityKey, InvariantError>`; `first` debe validar que el bit de resumen corresponde a un bucket existente y a un `g` dentro de rango. | Unitarias de frontera para `free=1`, `free=64`, último `g`; corrupción de resumen/bucket debe devolver `Invariant`; propiedad `set(false)`/`set(true)` conserva `first` y `contains`. |
| `physical/pool.rs:1025` | **P1** (no pánico) | `page_access(offset).unwrap_or(PageAccess::Protected)` oculta cualquier error de observación tras un fallo de `decommit`. `Protected` es conservador para acceso, pero afirma un estado conocido que puede no corresponder al backend tras fallos parciales. | `ObservedAccess::{Known(PageAccess), Unknown(PhysicalError)}` o un estado `Quarantined`; propagarlo en `ReclaimStatus::Pending` y prohibir reutilización hasta reconciliar. | Fallos de protección/descarte antes, después y parciales; el resultado desconocido queda en cuarentena y `allocate` no lo reutiliza hasta `repair`. |
| `physical/address_space.rs:68-69,89-90` | **P2**, con entrada inmediata en `fail_nth` | `base + n` y el incremento de ocurrencias son `u64` no comprobados. `fail_nth(op, u64::MAX)` puede desbordar si el contador ya es distinto de cero; el contador paniquea en debug o vuelve a cero en release. | `FaultOrdinal(NonZeroU64)` y `try_fail_nth(...) -> Result<Self, FaultPlanError>` con `checked_add`; en `check`, `checked_add` y error explícito `CounterExhausted`. | Llamar una vez, programar `u64::MAX`, y verificar error sin pánico en debug/release; estado del plan sin mutación parcial. |
| `physical/address_space.rs:109-112` y `:277,296,327,338,403` | **P2** | Contadores de llamadas y `OsCalls::total` suman sin política de overflow. Requiere aproximadamente `2^64` operaciones, pero invalida una garantía absoluta de no pánico. | Métricas saturantes (`saturating_add`) con bit `saturated`, o contadores `u128` más conversión comprobada. No usar wrapping silencioso. | Test unitario privado iniciado en `u64::MAX`: saturación indicada, `total` no paniquea y nunca decrece. |
| `physical/pool.rs:449` | **P2 de seguridad de identidad** | `NEXT_POOL_ID.fetch_add(1, Relaxed)` vuelve a cero tras agotar `u64`; podría reciclar una identidad y aceptar un enlace antiguo si coexistieran generaciones compatibles. | Reservar `0`, usar `fetch_update` comprobado y devolver `PoolError::PoolIdsExhausted`; idealmente un `PoolId(NonZeroU64)`. | Inicializar el contador cerca de `u64::MAX` en test aislado: último ID válido es único y la siguiente construcción falla sin reservar memoria. |
| `physical/pool.rs:555-580,609-629,670-700,782-801,978-1104` | **P2** para métricas; Acotado para ocupación | Las métricas `u64` no tienen política de overflow. En cambio `live`, `holes` y `occupied` están acotados por la capacidad máxima y por capacidades validadas; sus sumas/restas requieren una violación previa para fallar. | Métricas saturantes con señal. Para contadores de seguridad, encapsular en `LiveCount`/`Occupancy` con operaciones comprobadas que devuelvan `Invariant`, para que la prueba no dependa de razonamiento informal. | Pruebas privadas al máximo de métricas; propiedades `live + free + retired` y `occupied <= slots_per_subpage` tras cada operación y fallo. |

### Índices y aritmética actualmente acotados

| Ubicación | Clasificación | Demostración actual | Endurecimiento recomendado |
| --- | --- | --- | --- |
| `physical/address_space.rs:256,264-339,424-458` | Acotado | `page_access` comprueba `offset < len`; `page_range` usa `checked_add`, alineación y `end <= len`; `check_accessible` usa `checked_add` y trata `len == 0` antes de `end - 1`. Los slices reciben rangos ya validados. | Mantener las funciones como única puerta; un `PageRange` validado evitaría repetir la relación entre `pages` y bytes. |
| `physical/address_space.rs:68,85,89-90` | Acotado para índice | `FaultOp` tiene siete variantes contiguas y `N_FAULT_OPS == 7`; el cast produce `0..=6`. | `#[repr(u8)]` y una aserción de longitud, o sustituir el array por campos/`EnumMap`; esto separa el índice seguro del overflow de contador ya indicado. |
| `physical/pool.rs:417-457` | Acotado | El constructor fuerza `64 <= slot_size <= 4096`, múltiplo de 8; por ello `1 <= slots_per_subpage <= 64`. `max_superpages` se limita y el tamaño de reserva usa `checked_mul`. `fields*8` también se comprueba. | Conservar estas comprobaciones; materializar `PoolLayout` validado para que el resto no acepte enteros crudos. |
| `physical/pool.rs:538-759,832-887,1047-1085,1131-1184` | Acotado, supuesto disperso | `sub` está en `0..15`; `bit` viene de un bitmap no vacío o de `locate`; `index < 15*slots_per_subpage`; `sp < superpages.len()`. `HEADER_USED=4095` y como máximo hay 960 generaciones, por lo que los slices de cabecera caben. `field_offset` comprueba las sumas, y sus multiplicaciones previas están acotadas por `bit<64`, `slot_size<=4096` y `fields*8<=slot_size`. | `SubpageIndex`, `SlotIndex` y `PoolLayout`; cambiar `data_offset` a retorno comprobado o aceptar solo esas claves. Añadir `const` assertions para los offsets de cabecera. |
| `physical/pool.rs:959-980` | Acotado | `sp` procede de `position(Option::is_none)`, así que cabe en `superpages`; el offset usa `checked_mul` antes del commit y solo después se instala `Some`. | Hacer que `initialize_superpage` reciba `VacantSuperpage` y devuelva `InitializedSuperpage`. |

## Matriz mínima de pruebas antes de cerrar P0

1. Cierre propietario de `AddressSpace` y `PhysicalPool`: éxito, idempotencia del
   adaptador, fallo observable, devolución del dueño y reintento.
2. `Drop`: backend simulado que falle realmente al liberar, observador externo,
   exactamente un intento y cero dobles liberaciones. La inyección desactivada
   en `Drop` no cubre este caso.
3. Fugas del pool: `live`, `hole` y ambas; el mapping sigue vivo tras `Leak` y
   puede cerrarse después de resolver las capacidades.
4. Índices: primer/último pool, subpágina, slot, field y bucket; entradas fuera
   de rango devuelven error y ninguna secuencia pública paniquea.
5. Corrupción interna dirigida: densidad, pendiente y `summary` inválidos
   producen `PoolError::Invariant`, nunca `expect` ni index panic.
6. Overflow: ordinal de fallo público, ID global y métricas cerca del máximo,
   tanto en perfil debug como release.
7. Fallo físico parcial/desconocido: el estado se marca `Unknown/Quarantined`, no
   se reemplaza por `Protected`, no se reutiliza y `repair` es la única salida.

## Conclusión de gate

El `HEAD` auditado demuestra cierre explícito reintentable y rangos públicos
validados, pero **no** permite afirmar todavía “cierre garantizado” ni “cero
pánicos internos”: faltan el resultado propietario de cierre, observabilidad de
fallos terminales en `Drop`, tipado del índice de densidad/superpágina y una
política comprobada para ordinales, IDs y métricas. Estas correcciones no
requieren relajar ownership, drops ni el verificador LIR.
