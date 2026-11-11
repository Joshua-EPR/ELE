# Estado de implementación — 2026-11-09

> Rama `dev/self-hosting-parser`. Parser autónomo completo en L con gramática Pratt,
> AST tipado e indexado en arenas continuas (`List<T>`), manejo de expresiones, sentencias,
> declaraciones, tipos y control de flujo; recuperación de errores sintácticos con sincronización;
> ejecutable autónomo nativo `parser-l` generado por Cranelift con cero fugas de memoria.
> Suite completa de 356 pruebas pasando (8 pruebas nuevas en `tests/parser_l.rs`).
> Véanse §34, [PARSER_ARCHITECTURE.md](PARSER_ARCHITECTURE.md), [AST_LAYOUT.md](AST_LAYOUT.md) y [AGENT_HANDOFF.md](AGENT_HANDOFF.md) §29.

Documento de traspaso: permite a otro agente continuar exactamente desde aquí.
Implementación incremental probada; **no** hay conformidad completa con Proyecto L v1.0.

Leyenda: **Diseñado** = solo en la especificación. **Implementado** = el compilador lo
acepta y genera código. **Probado** = cubierto por pruebas positivas y negativas que
ejecutan el binario nativo y comprueban stdout/stderr/código. **Pendiente** = no existe.

## 1. Arquitectura real

```text
fuente .l + prelude.l → lexer → parser → sema → LIR estructurada (lir.rs)
  → ownership.rs → LIR de bloques (cfg.rs, con Drop por región léxica)
  → elaboración de drops (drops.rs) → verificador (estructura, tipos, asignación
    definida e invariantes de propiedad)                      ← siempre
      ├─ --backend rustc     (predeterminado): backend.rs → Rust → rustc → exe
      └─ --backend cranelift: native.rs + native/runtime.rs → .obj → link.exe → exe
```

Detalle en [BACKEND.md](BACKEND.md); modelo de memoria formal en
[SEMANTICS.md](SEMANTICS.md#modelo-de-memoria-adaptive-ownership-primera-implementación).
Dependencias externas: Cranelift 0.137.1 y target-lexicon 0.13.5 (sin cambios).

## 2. Base heredada: memoria nativa y drops

| Fase | Estado |
|---|---|
| 1. Modelo de memoria (local, heap, estático, propietario, prestado, movido; invariantes; limitaciones) | **Hecho**, documentado en SEMANTICS.md |
| 2. Text dinámico nativo: literales, construcción en ejecución, interpolación, movimientos, liberación, longitud en bytes, print | **Hecho y probado** (`(ptr, len, cap)`; `cap == 0` estático) |
| 3. Drops automáticos: fin de scope, retornos anticipados, ramas, bucles, break/continue, movimientos, temporales, reasignación; drop flags | **Hecho y probado** |
| 4. LIR: `Drop(var, flag?)`, `Moved(var)`, elaboración tras sema+ownership, verificador de propiedad | **Hecho y probado** |
| 5. Runtime: reserva, liberación, construcción de cadenas, UTF-8, conversión Int/Bool→texto, fallo de reserva | **Hecho y probado** (heap del proceso, solo kernel32) |
| 6. Pruebas de seguridad con instrumentación | **Hecho**: 10 pruebas nativas + 2 de LIR (ver §4) |
| 7. Compatibilidad entre backends | **Hecho**: diferenciales sin cambios + todas las pruebas de memoria comparan con rustc |

Criterios de aceptación: 1–9 **cumplidos** para Text. Fuera de alcance de este hito y
rechazados con L0008 en nativo: enums, Option/Result, métodos con receptor y Float.
Structs se habilitan en el incremento descrito abajo.

Ejemplos objetivo (ambos backends, salida idéntica): `"Hola {nombre}"` → `Hola Ana`;
`crearMensaje(42)` → `Resultado: 42`; `examples/fibonacci.l` → `Fibonacci: 55` ahora
también en nativo.

## 3. Matriz de características

| Capacidad | rustc | cranelift |
|---|---|---|
| Int, Bool, (), aritmética con panics, comparaciones, `&&`/`||` | Probado | Probado |
| Text literal, interpolación dinámica, pasar/devolver/mover Text, liberación | Probado | Probado (instrumentado) |
| let/var/const, scopes, if/while/loop/for/break/continue, funciones, recursión | Probado | Probado |
| match sobre Int/Bool/Text (literales, `_`, bindings) | Probado | Probado |
| Float (f64), f32, f64, conversiones explícitas | Probado | Probado (IEEE 754, runtime l_rt_ftoa) |
| structs anidados, construcción, campos, paso/retorno por valor | Probado | Probado |
| movimientos parciales de structs, reinicialización y drops por campo | Probado | Probado con instrumentación |
| impl con receptor (fn, mut fn, static fn) y referencias | Probado | Probado (instrumentado) |
| enums, match sobre enums, Option/Result, `??`, `?` | Probado | Probado (instrumentado) |
| funciones y structs genéricos (`fn f<T>`, `struct Caja<T>`), métodos genéricos | Probado | Probado (monomorfizado, instrumentado) |
| traits, impl de traits (`impl Trait for Type`), trait bounds (`<T: Trait>`), static dispatch | Probado | Probado (monomorfizado estático) |
| regiones `region r { ... }`, buffers `Bytes` (`bytes`, `len`, `get`, `set`), escapes rechazados (L0011) | Probado | Probado (bump allocator, instrumentado) |
| referencias `&T`/`&mut T` como parámetros y bindings locales, slices y último uso | Probado | Probado |
| referencias almacenadas o devueltas (requieren lifetimes) | Rechazado con error | Rechazado con error |
| arrays `[T; N]`, slices `&[T]`/`&mut [T]`, `List<T>` (push/pop/reserve/length/capacity, índices, for) | Probado | Probado (instrumentado) |
| `async fn`, `await`, futures, suspensión real y ejecutor cooperativo | Probado (futures de Rust como referencia) | Probado (máquina de estados propia, instrumentado) |
| Parámetros y locales propietarios de `Text`, structs, enums, arrays y listas a través de una suspensión | Probado | Probado (CFG e instrumentación) |
| `spawn`, varias tareas, E/S asíncrona | Diseñado / rechazado con diagnóstico | — |
| i8–u64, Char, módulos | Diseñado | — |
| sistema de efectos estático (!{}, !{alloc, io, panic, block}), pureza, @noalloc | Probado | Probado (análisis interprocedimental) |

## 4. Pruebas

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'   # es 1.99.1
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

Base verificada: **125 pruebas, 0 fallos** en 17 suites (incluye `tests/regions.rs`; ver §11).
2 de LIR/propiedad en `tests/cfg.rs` + 10 en `tests/memory.rs`).

`tests/memory.rs` compila cada programa con rustc (referencia) y con cranelift
`--trace-alloc`, y exige: stdout y código idénticos, `allocs == frees`, ninguna
liberación inválida (cada `free` valida el puntero con `HeapValidate`) y heap íntegro
al salir. Casos: ejemplos del hito (1 reserva, 1 liberación cada uno); solo literales
(0 reservas); cadenas vacías; cadena larga construida en 3000 iteraciones (≥3000
reservas, todas liberadas); UTF-8 no ASCII (ñ, emoji, CJK); interpolaciones
múltiples y anidadas, `i64::MIN`; movimientos; scopes internos; movimiento en una
sola rama (drop flag); retornos anticipados con varios Text propios; `break` y
`continue` con Text vivos; reasignación; temporales descartados; match sobre Text
con bindings prestados; fallo de reserva inyectado (panic limpio «memoria
insuficiente», estado de abort, salida previa conservada); doble liberación forzada
saltándose el verificador (el verificador la rechaza; el runtime instrumentado la
detecta y aborta); panic con Text vivos (no hay drops ni informe: abort documentado);
y programas inseguros rechazados en compilación (uso tras movimiento, doble
movimiento, movimiento en una rama y uso posterior, movimiento en bucle, variable
sin inicializar).

`tests/cfg.rs` añade: el verificador de propiedad rechaza LIR con uso tras
movimiento, doble liberación, sobrescritura sin liberar, fuga al retornar y drop de
algo nunca asignado; y la elaboración elimina drops de valores movidos, pone flags
solo donde el estado es incierto, libera antes de reasignar y libera en los retornos
anticipados.

Comprobación adicional (no automatizada en la suite por duración): el benchmark
`text_build` (1.000.000 de interpolaciones) con `--trace-alloc` informa
`allocs=1000000 reallocs=0 frees=1000000 heap_ok=1`, y su memoria pico es plana
(~2,2 MiB).

## 5. Benchmarks (bench/results.md)

Intel i5-7300U, mediana de 5; rustc con **`-C opt-level=0`** (configuración actual del
backend rustc) frente a Cranelift `opt_level=speed`. Mismo alcance que antes: no
dice nada frente a Rust optimizado.

| Programa | Ejecutable rustc / cranelift (bytes) | Mediana rustc / cranelift (ms) |
|---|---|---|
| fib(32) | 135680 / 5120 | 78 / 31 |
| sum_loop | 136704 / 5120 | 7829 / 811 |
| collatz | 136704 / 5120 | 5917 / 414 |
| primes | 136192 / 5632 | 3792 / 1894 |
| text_build (1M interpolaciones) | 149504 / 5632 | 1359 / 242 |

El ejecutable nativo creció de 3,5 KB a 5–5,6 KB por el runtime de memoria.

## 6. Incremento dev/native-aggregates

Base real: `dev/native-memory`, commit `e07aead`. Auditoría inicial: árbol limpio,
66 pruebas aprobadas; ninguna rama local con trabajo posterior. No hay remoto.
Se conserva la arquitectura y la implementación de Claude. Dos casos negativos que
antes prohibían cualquier movimiento parcial ahora verifican el uso posterior
del campo movido; los movimientos válidos tienen cobertura positiva.

Implementado:

- Ownership por rutas de campos, incluidos structs anidados. Un movimiento parcial
  conserva hermanos y prohíbe usar el padre hasta reinicializarlo.
- Drops por hoja, flags para estados inciertos, liberación al reemplazar campos y
  de hermanos al extraer campos de temporales.
- Layout independiente de Cranelift: tamaño, alineación, padding y offsets.
- Structs nativos con Int/Bool/Text y structs anidados, construcción, campos,
  modificación, parámetros por valor, retorno sret y recursión.
- Fixture de structs trasladado de unsupported a la batería diferencial; métodos,
  enums y Float siguen teniendo pruebas de rechazo nativo.

Pruebas añadidas: layout anidado; rechazos de rutas movidas/prestadas; verificación
LIR de drops por campo y doble liberación; límite de expansión del layout;
ejecución nativa de movimientos parciales,
reinicialización en ambas ramas, reemplazos, temporales, retorno anticipado,
recursión, break/continue y parámetros agregados. Contadores de los casos dinámicos:
4 reservas/4 liberaciones y 10/10, heap_ok=1. La prueba con PATH vacío construye y
ejecuta un struct y Fibonacci sin rustc disponible, con stdout `30\nFibonacci: 55\n`,
stderr vacío y estado 0.

Validación final: **75 pruebas aprobadas, 0 fallos** (66 de la base + 9 nuevas).
`cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` pasan.
Registro local completo: `target/native-aggregates-tests.log` (artefacto ignorado por Git).

Los benchmarks de §5 son históricos de la base, no mediciones de este incremento;
no se afirma una mejora de rendimiento por habilitar structs.

## 7. Incremento dev/native-references-methods (2026-11-08)

Rama de desarrollo: dev/native-references-methods, derivada de dev/native-aggregates (722e881).
Estado validado: **80 pruebas aprobadas, 0 fallos** (75 anteriores + 5 en 	ests/references.rs).
cargo fmt --check y cargo clippy --all-targets -- -D warnings pasan limpios sin advertencias.

Implementado y verificado:
- **Métodos con receptor nativos en Cranelift**:
  - n: métodos con receptor inmutable / compartido (self).
  - mut fn: métodos con receptor mutable / exclusivo (self). Modificación in-place sobre el StackSlot original.
  - static fn: métodos sin receptor, invocables mediante Tipo.metodo().
- **Referencias seguras y Borrow Checking**:
  - Representación de referencias &T y &mut T.
  - Validación de aliasing: lectores múltiples o un escritor exclusivo.
  - Prohibición de mutar a través de &T.
  - Prohibición de mover valores prestados o a través de referencias.
  - Prohibición de modificar/reasignar variables con préstamos de lectura activos.
  - Prohibición de retornar referencias a variables locales de stack efímero.
- **Backend Cranelift**:
  - Detección de variables prestadas locales y asignación a StackSlot según el layout de memoria.
  - Paso de argumentos por referencia como punteros de máquina I64 (place_addr).
  - Desreferenciación y actualización in-place con offsets exactos en Store y place_values.
  - examples/contador.l y examples/structs.l ejecutan nativamente en Cranelift con --trace-alloc mostrando heap_ok=1 y 0 fugas de memoria.
- **Suite Diferencial**:
  - differential_programs_match ahora incluye methods.l.
  - unsupported_programs_are_rejected_not_miscompiled conserva la cobertura con enum_user.l.

## 8. Incremento dev/native-enums (2026-11-08)

Rama de desarrollo: `dev/native-enums`, derivada de `dev/native-references-methods`.
Estado validado: **89 pruebas aprobadas, 0 fallos** (80 anteriores + 9 nuevas en `tests/enums_native.rs`).
`cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` pasan limpios sin advertencias.

Implementado y verificado:
- **Layout nativo de Enums (`layout.rs`)**:
  - `EnumLayout` y `VariantLayout`: discriminante a offset 0 (8 bytes, alineación 8).
  - Campos de variantes calculados y empaquetados respetando alineación y padding individual de cada tipo.
  - Tamaño del enum = máximo tamaño entre todas las variantes redondeado a la alineación máxima (mínimo 8 bytes).
  - Descomposición en componentes `I64` para interoperabilidad directa con SSA en Cranelift.
- **Match nativo y acceso a payloads (`native.rs`)**:
  - Evaluación única del scrutinee en su propio `StackSlot`.
  - Discriminante leído como `I64` a offset 0 con bifurcación condicional a bloques de variante.
  - Proyecciones `cfg::Proj::Payload(variant, field)` resueltas con `place_byte_offset` a través de `place_addr`.
  - Paso de argumentos enum y retornos `sret` (puntero oculto).
- **Drops condicionados por variante (Variant-Sensitive Drops)**:
  - `type_needs_drop` identifica variantes que contienen recursos dinámicos (`Text`, structs con `Text` o enums anidados).
  - `drop_in_place` genera un switch sobre el discriminante: sólo se liberan los campos activos de la variante actual, evitando double-frees y fugas.
  - Verificado con `--trace-alloc`: `heap_ok=1`, `allocs == frees`.
- **Option y Result nativos**:
  - `Option<T>` (`Some`, `None`, `??`) y `Result<T, E>` (`Ok`, `Err`, `?`) compilados y probados nativamente en Cranelift.
- **Batería de pruebas diferenciales**:
  - `enums.l` y `enum_user.l` trasladados a `tests/differential/` probando paridad exacta entre rustc y cranelift.
  - `float_arith.l` y `float_div.l` agregados a `tests/differential/unsupported/`.

## 9. Limitaciones y siguiente hito

- Float nativo pendiente (formateador en runtime e instrucciones de punto flotante).
- Soporte para traits e interfaces polimórficas.
- Arrays / listas dinámicas nativas.
- Panic sigue siendo abort limpio sin unwinding ni drops. Sin GC.

## 10. Git e integración

Rama local dev/native-enums. Sin remoto.
Para integrar en la rama base:
git merge dev/native-enums

Archivos modificados/creados:
- Frontend/Layout: crates/l/src/layout.rs.
- Backend: crates/l/src/native.rs.
- Pruebas: crates/l/tests/enums_native.rs, crates/l/tests/differential/enums.l, crates/l/tests/differential/enum_user.l, crates/l/tests/differential/unsupported/float_arith.l, crates/l/tests/differential/unsupported/float_div.l, crates/l/tests/structs.rs.
- Documentación: docs/IMPLEMENTATION_STATUS.md, BACKEND.md, SEMANTICS.md, DECISIONS.md, AGENT_HANDOFF.md.

## 11. Etapa dev/regions (2026-11-08)

Estado inicial verificado (Antigravity, `dev/effect-system` `3749c8f`): 109/109,
fmt/clippy limpios, árbol limpio.

| Trabajo | Resultado |
|---|---|
| Verificación del sistema de efectos | Correcto salvo un defecto: contratos de traits solo contra la última impl → corregido (`27b879c`), +2 pruebas |
| Seguridad de referencias | Referencia colgante ejecutable vía retorno por llamada, errores internos al guardar referencias → referencias de segunda clase (`8981023`), +2 pruebas |
| Aliasing en llamadas | `dos(&mut p, &p)` aceptado → rechazado (`688db71`), +1 prueba |
| Regiones de memoria | Implementadas (`688db71`): sintaxis, tipos con identidad de región, reglas de escape L0011, drops en todas las rutas, allocator bump nativo, runtime rustc equivalente, efectos `alloc`+`panic`, LIR explícita; 11 pruebas |
| Análisis de escape como pase | No implementado; garantías actuales por tipos (MEMORY_MODEL §6) |
| Optimización de asignaciones | No implementada |
| Async/await | No empezado (condicionado a lo anterior) |

Memoria (instrumentación `--trace-alloc`, programas de `bench/programs/region_*.l`,
200.000 buffers de 64 bytes, mismo resultado `25493856` en los tres):

| Patrón | Bloques reales (allocs = frees) | Reservas lógicas | Bytes pedidos | heap_ok |
|---|---:|---:|---:|---|
| una región por buffer | 200000 | 200000 | 12800000 | 1 |
| una región por lote de 1000 | 1000 | 200000 | 12800000 | 1 |
| una sola región | 12 | 200000 | 12800000 | 1 |

Tiempos (Intel i5-7300U, mediana de 5, `bench/results.md`), backend cranelift:
por buffer 77,6 ms / 2,5 MB pico; por lote 46,4 ms / 2,5 MB; región única
30,8 ms / **15,0 MB** (retiene todo hasta el final). El backend rustc
(`opt-level=0`, un `Box` por buffer) no es una referencia de rendimiento. No se
midieron por separado el tiempo de liberación ni "almacenamiento local" (L no
tiene todavía arrays en pila). No hay comparación con Rust/C++ optimizados.

Limitaciones de la etapa: ver MEMORY_MODEL §7 y AGENT_HANDOFF §6.

## 12. Etapa dev/native-collections-complete (2026-11-08)

Rama `dev/native-collections-complete`, derivada de `dev/regions` (`0716e9a`). Estado
inicial verificado: 125/125, fmt/clippy limpios. Commits (más antiguo primero):
`41c6688` front-end + backend rustc; `d4ef320` backend Cranelift + pruebas; el commit
de documentación y benchmarks que contiene este texto.

| Requisito | Estado |
|---|---|
| Arrays: inferencia, vacíos tipados, anidados, de structs/enums/Text/Float/Bool, parámetros y retornos, layout/alineación, drops de elementos | **Probado** (ambos backends) |
| Índice constante fuera de rango en compilación; comprobación dinámica de límites | **Probado** (`L0001`; panic con la misma posición en ambos backends) |
| Slices `&[T]`/`&mut [T]` sobre arrays, listas y slices: longitud, índice, iteración, parámetros | **Probado**; sin punteros crudos (vista `(ptr, len)` de segunda clase) |
| `List<T>`: vacía, literal, push, pop seguro (`T?`), length, capacity, reserve, índice, iteración, movimientos, drops, liberación, crecimiento geométrico con desbordamiento comprobado, reserve sin estado corrupto ante fallo | **Probado** (instrumentado) |
| Genéricos/layout: Int, Float, Text, structs (Persona), enums, listas anidadas, listas en structs | **Probado** |
| Ownership: movimiento, uso tras movimiento, sin mover elementos, sin modificar durante iteración, inmutabilidad | **Probado** (negativos) |
| Integración con regiones | Listas regionales en §13 (DECISIONS 86–87) |
| Efectos: array sin `alloc`; List/push/reserve `alloc`; `@noalloc` con List rechazado | **Probado** |

Pruebas añadidas: `tests/collections.rs` (18; 125 → 143). Cada positiva compila con
rustc y con cranelift `--trace-alloc` y exige salida idéntica, `allocs == frees` y heap
íntegro; las de panic exigen stdout/stderr/código idénticos. Incluye 100.000 `push`
(1 reserva + 15 realocaciones, capacidad final 131072), fallo de reserva inyectado
durante el crecimiento, elementos Text reemplazados y extraídos con `pop`, retornos
anticipados y `break`/`continue` con listas vivas.

Defectos encontrados y corregidos durante la etapa: la elaboración de drops trataba
`c[i] = v` como asignación al lugar y liberaba la colección entera (error interno
L0007); leer un campo de un elemento (`gente[3].nombre`) se trataba como movimiento.

Benchmarks (`bench/results.md`, i5-7300U, mediana de 5, rustc `-C opt-level=0`, no
comparable con Rust optimizado; tiempos de proceso completo, incluida la
construcción de la lista):

| Programa | rustc (ms) | cranelift (ms) | Pico KiB rustc / cranelift | Reservas / realoc. (cranelift) | Exe cranelift (bytes) |
|---|---:|---:|---:|---:|---:|
| list_push_1m (1M push) | 46,7 | 39,8 | 12268 / 11668 | 1 / 18 | 8192 |
| list_iter_1m (1M, 20 recorridos for) | 393,4 | 60,9 | 10876 / 10240 | 1 / 0 | 8192 |
| list_index_1m (1M, 20 recorridos `datos[j]`) | 682,4 | 169,1 | 10940 / 10240 | 1 / 0 | 8192 |
| list_search_1m (20 búsquedas lineales) | 221,3 | 46,6 | 12304 / 11696 | 1 / 18 | 8704 |
| list_text_100k (100k Text) | 93,4 | 31,2 | 8676 / 2564* | 100001 / 15 | 8704 |
| list_release_100k (50 × 100k, liberadas) | 149,5 | 61,5 | 4860 / 4300 | 50 / 750 | 8192 |

\* El pico se muestrea cada 5 ms; en ejecuciones de ~30 ms puede infravalorarse.
Compilación con `l build` (incluye enlazado): 100–175 ms en cranelift, 360–790 ms
en rustc. En esta tanda el equipo estaba cargado (p. ej. `fib` cranelift 1063 ms de
compilación, atípico frente a ~120 ms en la tanda anterior); los tiempos son
indicativos.

Limitaciones: ver SEMANTICS (colecciones, "No implementado") y AGENT_HANDOFF §6.


## 13. Listas regionales

Rama `dev/region-collections`, derivada de `7c1bd90`. La línea base pasó 143 pruebas.
Se añadió `r.list<T>()` a ambos backends, con crecimiento, indexación, pop, vistas de
llamada y drops antes de liberar la región. Seis pruebas nuevas de regiones cubren
también fallos de reserva, escapes y manipulación del orden de drops en la LIR.

Las reservas directas de arrays regionales y las vistas que sobreviven a la llamada
requieren un diseño adicional. Los arrays fijos sí se pueden almacenar por valor
en el buffer de una lista regional. Una lista ordinaria anidada mantiene sus
propias reservas de heap. El almacenamiento regional todavía no se expone como
tipo de parámetro o resultado. Véanse MEMORY_MODEL §9 y BACKEND §13.

Validación final: **149 pruebas aprobadas, 0 fallos**. `cargo fmt --check`
y `cargo clippy --all-targets -- -D warnings` pasaron. Las pruebas instrumentadas
validaron el heap y las liberaciones para las rutas ejecutadas. El entorno
de compilación usado fue Rust estable MSVC para Windows x64.

### Comparación nativa de almacenamiento

Ejecutar `pwsh -NoProfile -File bench/region-lists.ps1` tras `cargo build`.
Cinco repeticiones por programa, tiempos en milisegundos de proceso completo.
**Insertar** incluye llenar, consultar longitud y liberar. **Recorrer** incluye
llenar o construir el array, sumar los elementos y liberar. La medición incluye
arranque del proceso. La fase de liberación no se cronometra por separado.
El pico se toma del working set observado. «—» indica que el proceso terminó
antes de obtener una muestra. Las reservas se miden en un binario separado.

| N | Almacenamiento | Carga | Mediana [mín., máx.] ms | Pico KiB | EXE bytes | Reservas físicas / realocaciones / frees | Reservas regionales | Bytes regionales / retirados |
|---:|---|---|---:|---:|---:|---:|---:|---:|
| 1000 | Heap | Insertar | 4,67 [4,37, 38,09] | — | 8192 | 1 / 8 / 1 | 0 | 0 / 0 |
| 1000 | Heap | Recorrer | 5,18 [4,13, 40,12] | — | 8192 | 1 / 8 / 1 | 0 | 0 / 0 |
| 1000 | Región | Insertar | 5,28 [4,29, 28,82] | — | 8192 | 3 / 0 / 3 | 9 | 16352 / 8160 |
| 1000 | Región | Recorrer | 4,33 [4,11, 28,47] | — | 8192 | 3 / 0 / 3 | 9 | 16352 / 8160 |
| 1000 | Array | Recorrer | 5,39 [4,21, 32,35] | — | 51712 | 0 / 0 / 0 | 0 | 0 / 0 |
| 100000 | Heap | Insertar | 7,86 [5,74, 48,22] | — | 8192 | 1 / 15 / 1 | 0 | 0 / 0 |
| 100000 | Heap | Recorrer | 7,03 [5,35, 42,32] | — | 8192 | 1 / 15 / 1 | 0 | 0 / 0 |
| 100000 | Región | Insertar | 9,39 [7,63, 284,63] | 4284 | 8192 | 10 / 0 / 10 | 16 | 2097120 / 1048544 |
| 100000 | Región | Recorrer | 9,87 [8,62, 292,12] | 3292 | 8192 | 10 / 0 / 10 | 16 | 2097120 / 1048544 |
| 1000000 | Heap | Insertar | 13,41 [10,55, 37,43] | 7392 | 8192 | 1 / 18 / 1 | 0 | 0 / 0 |
| 1000000 | Heap | Recorrer | 16,99 [13,23, 42,07] | 11480 | 8192 | 1 / 18 / 1 | 0 | 0 / 0 |
| 1000000 | Región | Insertar | 25,25 [23,84, 462,22] | 18832 | 8192 | 13 / 0 / 13 | 19 | 16777184 / 8388576 |
| 1000000 | Región | Recorrer | 33,34 [29,24, 470,15] | 18876 | 8192 | 13 / 0 / 13 | 19 | 16777184 / 8388576 |

Con un millón de elementos, la lista regional acumuló cerca de 8 MiB de
capacidad retirada. A esa escala mostró mayor mediana y mayor pico observado.
El costo incluye inicializar el nuevo rango y copiar los elementos vivos, además
de retener rangos viejos hasta cerrar la región. La dispersión aconseja cautela al
interpretar diferencias pequeñas. El array fijo se comparó a 1.000 elementos por
los límites de tokens y componentes del compilador.


## 14. Préstamos locales

Incremento de `dev/lifetimes-escape` sobre `043a25f`. Se admiten orígenes locales
fijos, modos compartido y exclusivo, campos, elementos, représtamos y vistas.
El análisis de flujo usa último uso y comprueba conflictos antes del backend.
La fase actual excluye firmas con retorno prestado, referencias almacenadas en
agregados y análisis interprocedimental de escapes. La inferencia implementada
es la del tipo, lugar de origen y duración de un préstamo local.

Validación final: **158 pruebas aprobadas, 0 fallos** (149 de base y 9 nuevas).
Formato y Clippy limpios. El microbenchmark manual se ejecutó aparte.
Las pruebas diferenciales instrumentadas comprobaron integridad de heap y
liberaciones equilibradas en las rutas ejercitadas.

### Medición del análisis

`pwsh -NoProfile -File bench/lifetimes.ps1 -Baseline <l.exe de 043a25f> -Current <l.exe de esta rama>`
ejecuta 15 comprobaciones por caso después de un calentamiento. Compilar ambos
binarios en directorios de artefactos distintos. Se usaron binarios debug para
Windows x64 y el mismo toolchain MSVC. El cronómetro incluye el arranque, el
frontend, el CFG y su validación.

| Funciones | Sitios de préstamo local | Compilador | Mediana [mín., máx.] ms | Pico observado KiB |
|---:|---:|---|---:|---:|
| 2 | 0 | Base | 9,43 [8,59; 11,86] | 5188 |
| 2 | 0 | Actual | 9,21 [8,77; 11,75] | 2816 |
| 2 | 1 | Actual | 10,33 [8,91; 15,58] | 5312 |
| 81 | 0 | Base | 23,03 [18,58; 39,75] | 5064 |
| 81 | 0 | Actual | 23,65 [18,44; 37,64] | 5388 |
| 81 | 80 | Actual | 27,87 [21,66; 33,94] | 5260 |

`cargo test --lib profile_local_loans -- --ignored --nocapture` aísla el pase de
préstamos sobre un CFG ya construido. La mediana fue 20,38 µs para 2 funciones
con un préstamo y 1.945,44 µs para 81 funciones con 80 préstamos, en 21 muestras
de 100 repeticiones. Los sitios son instrucciones `Loan`. El pase compara
accesos y estados de liveness directamente, sin una tabla separada de
restricciones. La inferencia local forma parte del frontend y el análisis
interprocedimental de escapes sigue pendiente. El muestreo de memoria del
proceso es aproximado y la dispersión impide atribuir cambios pequeños.


## 15. Retornos prestados

`dev/reference-returns` parte de `c1efd90`. La base pasó 158 pruebas.
El incremento implementa retornos compartidos y mutables anclados a un único
parámetro, incluidos campos, elementos, genéricos, métodos inherentes y
llamadas encadenadas o recursivas. Se verifican los retornos de cada cuerpo
y se propaga el préstamo al llamador. La prueba de Text mutable comprueba
los drops de valores locales en el callee y el reemplazo del referente.

Los retornos de slices completos o Bytes, los contratos de traits con
retorno prestado, los lifetimes con varios parámetros de origen, las
referencias en agregados y el análisis general de escapes siguen pendientes.
El resultado de una llamada prestada se vincula con `let` o se reenvía en
un retorno. La conservación de todo el argumento es una restricción
deliberada de este resumen inicial.

Validación final: **166 pruebas aprobadas, 0 fallos** (158 de base y ocho nuevas).
Formato y Clippy limpios. Los microbenchmarks manuales quedan fuera del conteo.
El ejecutable nativo del ejemplo imprimió `Ana 42` con PATH vacío. El trazado
registró una reserva, una liberación y `heap_ok=1`. La prueba negativa de CLI
señaló el archivo y el lugar de retorno con L0013.

### Costo de los contratos de retorno

`pwsh -NoProfile -File bench/lifetimes.ps1 -Baseline <l.exe de c1efd90> -ReferenceReturns`
ejecuta 15 repeticiones de `l check` por caso en binarios debug de Windows x64.
La base y la rama actual usan las mismas fuentes en las cargas comunes.
La carga de retornos solo se mide en la rama actual. El tiempo total incluye
arranque, resolución de firma, análisis semántico, CFG y verificación.

| Funciones | Carga | Compilador | Mediana [mín., máx.] ms | Pico observado KiB |
|---:|---|---|---:|---:|
| 2 | Sin préstamos locales | Actual | 8,21 [7,96; 11] | 3044 |
| 2 | Sin préstamos locales | Base | 8,38 [7,75; 11,97] | 5228 |
| 2 | Préstamos locales | Actual | 10 [7,97; 14,38] | 2876 |
| 2 | Préstamos locales | Base | 9,61 [7,94; 13,28] | 5304 |
| 2 | Retornos prestados | Actual | 8,79 [8,37; 11,37] | 5380 |
| 81 | Sin préstamos locales | Actual | 16,07 [13,53; 20,68] | 5416 |
| 81 | Sin préstamos locales | Base | 15,43 [12,97; 21,29] | 5360 |
| 81 | Préstamos locales | Actual | 19,85 [17,72; 26,02] | 5280 |
| 81 | Préstamos locales | Base | 19,11 [17,16; 25,63] | 5480 |
| 81 | Retornos prestados | Actual | 17,9 [15,46; 23,63] | 5512 |

`cargo test --lib profile_reference_returns -- --ignored --nocapture` mide
préstamos y escapes juntos sobre un CFG construido y luego aísla la validación de
origen usando las tablas de alias preparadas. Con 2 funciones y un contrato,
las medianas fueron 70,51 µs y 1,47 µs. Con 81 funciones y 80 contratos,
1.198,91 µs y 83,23 µs. Cada contrato fija un parámetro y un modo.
Se midieron 15 muestras de 100 repeticiones. La inferencia de firma forma parte
del frontend y no se cronometró por separado. El pico es una muestra de working
set y la dispersión de tiempos impide atribuir cambios pequeños.


## 16. Múltiples orígenes y clasificación de escapes

`dev/escape-aggregates` parte de `e064ac7`. La base pasó 166 pruebas.
Se admiten retornos compartidos, mutables y de slices con varios orígenes.
El CFG conserva el conjunto durante las llamadas. El compilador comprueba
cada origen y mantiene los préstamos de todos los posibles propietarios
hasta el último uso del resultado.

La API `escape_summaries` informa los retornos y los parámetros reenviados
a llamadas. Distingue campos, payloads e índices simbólicos en los lugares
observados. Los intentos de escape hacia campos, variantes o colecciones se
rechazan antes de emitir LIR. Véase [ESCAPE_ANALYSIS.md](ESCAPE_ANALYSIS.md).

El contrato conserva todo el argumento real. La precisión de proyecciones
dentro del callee, el almacenamiento de referencias en agregados, los
lifetimes explícitos y los retornos de Bytes quedan pendientes.

Validación final: **171 pruebas aprobadas, 0 fallos** (166 de base y cinco nuevas).
Formato y Clippy limpios. La ejecución nativa de vistas con PATH vacío imprimió
`21\n2\n11\n`, registró dos reservas, una realocación, dos liberaciones y
`heap_ok=1`. La CLI señaló archivo, línea y columna al rechazar un retorno que
podía apuntar a un local.

### Medición de conjuntos de procedencia

`pwsh -NoProfile -File bench/lifetimes.ps1 -Baseline <l.exe de e064ac7> -MultipleOrigins`
compara `l check` en las mismas fuentes cuando ambas versiones las admiten.
Los binarios debug son de Windows x64. Hay 15 repeticiones tras calentamiento.
La tabla muestra los casos de 81 funciones. El CSV conserva también los casos
de dos funciones, los sitios de préstamo y los conteos de contratos y relaciones.

| Carga | Compilador | Contratos / relaciones | Mediana [mín., máx.] ms | Pico observado KiB |
|---|---|---:|---:|---:|
| Sin préstamos locales | Actual | 0 / 0 | 19,25 [16,44; 31,79] | 5252 |
| Sin préstamos locales | Base | 0 / 0 | 20,05 [16,71; 28,13] | 5276 |
| Préstamos locales | Actual | 0 / 0 | 23,19 [21,59; 27,37] | 5664 |
| Préstamos locales | Base | 0 / 0 | 23,11 [20,36; 31,3] | 5392 |
| Un origen por contrato | Actual | 80 / 80 | 22,47 [19,87; 32,18] | 5644 |
| Un origen por contrato | Base | 80 / 80 | 20,49 [18,06; 24,9] | 5244 |
| Dos orígenes por contrato | Actual | 80 / 160 | 27,31 [21,44; 32,32] | 5692 |

La mediana del análisis conjunto de préstamos y escapes fue **1,76 ms** con
80 contratos de un origen y **1,64 ms** con 80 contratos de dos orígenes.
La verificación de escapes con tablas construidas tomó 0,077 y 0,123 ms.
Se midió mediante `cargo test --lib profile_reference_returns -- --ignored --nocapture`.
La inferencia de los contratos se ejecuta dentro del frontend y su costo
está incluido en `l check`. Los rangos de las cargas comunes se solapan.

En cinco ejecuciones de `l build --backend cranelift` sobre los archivos
`returns-80.l` y `multiple-80.l` generados por el script, incluyendo enlazado,
las medianas fueron 222,33 ms para la base, 203,35 ms para la rama actual con
la misma entrada y 232,21 ms con 160 relaciones de origen. Sus rangos fueron
[192,08; 347,58], [199,25; 353,73] y [220,03; 284,75] ms respectivamente.


## 17. Structs con campos compartidos

Rama `dev/aggregate-lifetimes`, derivada de `e20a62d`. La base pasó 171 pruebas.
Las vistas concretas almacenan referencias compartidas a escalares y Text,
pueden mover sus campos propietarios junto con los prestados y retienen
la procedencia al moverse. Ambos backends leen los campos y preservan el
orden de drops. El resumen de escapes distingue los parámetros almacenados
en una vista local.

Se mantienen rechazados los campos mutables, el anidamiento de vistas, los
retornos de vistas, su uso como parámetros, los métodos de vista y su
almacenamiento en enums o colecciones. Las vistas se vinculan con `let`.
[Modelo, restricciones y sintaxis](AGGREGATE_LIFETIMES.md).

Validación final: **177 pruebas aprobadas, 0 fallos** (171 de base y seis nuevas).
Formato y Clippy limpios. El ejemplo nativo imprimió `42` con PATH vacío,
cero reservas y `heap_ok=1`. La vista mixta con Text dinámico registró cuatro
reservas y cuatro liberaciones con heap íntegro. Un diagnóstico L0012 rechazó
una mutación de un posible propietario tras guardar su préstamo en una vista.

### Costo de las vistas

`pwsh -NoProfile -File bench/lifetimes.ps1 -Baseline <l.exe de e20a62d> -AggregateViews`
ejecuta 15 muestras de `l check` en Windows x64 con binarios debug.
El caso de vistas crea dos préstamos por función y mueve un struct con un
campo propietario anidado. El CSV guarda las cargas de dos y 41 funciones.
Las vistas solo se miden en la versión actual.

| Carga de 41 funciones | Compilador | Mediana [mín.–máx.] ms | Pico observado KiB |
|---|---|---:|---:|
| Sin préstamos locales | Actual | 16,02 [13,27–22,37] | 5484 |
| Sin préstamos locales | Base | 15,6 [13,04–17,8] | 5452 |
| Préstamos locales | Actual | 18,99 [15,98–25,83] | 5460 |
| Préstamos locales | Base | 18,36 [16,04–22,43] | 5676 |
| Un origen por contrato | Actual | 17,72 [14,43–58,7] | 5696 |
| Un origen por contrato | Base | 19,02 [14,46–132,06] | 5636 |
| Dos orígenes por contrato | Actual | 20,85 [17,78–30,9] | 5760 |
| Dos orígenes por contrato | Base | 20,81 [16,98–30,86] | 5396 |
| 40 vistas, 80 relaciones de campo | Actual | 39,24 [33,81–51,79] | 6148 |

`cargo test --lib profile_aggregate_views -- --ignored --nocapture` aísla el
análisis en un CFG construido. Para 40 vistas y 80 préstamos, la mediana fue
8,20 ms para la verificación conjunta y 1,08 ms para reconstruir procedencia.
Para una vista, las medianas fueron 0,202 y 0,045 ms. Se midieron 15 muestras
de 100 repeticiones. `l check` incluye la inferencia y el arranque del proceso.
Los picos son muestras del working set y los rangos de cargas comunes se solapan.


## 18. Retornos de agregados prestados y lifetimes interprocedimentales

Rama `dev/borrowed-aggregate-returns`, derivada de `dev/aggregate-lifetimes` (`0521d1a`). La base pasó 177 pruebas.
Las funciones y métodos pueden devolver structs que contienen referencias compartidas (`&T`), vinculando sus contratos de procedencia por campo (`FieldContract` y `ViewReturn`) a los parámetros formales de entrada.

- **Retornos por valor y ABI:** En Cranelift, el retorno utiliza `by_sret` con stack slot reservado en el llamador. Los campos punteros de 8 bytes son escritos por el callee y cargados por el llamador mediante `FieldLoan`.
- **Propagación interprocedimental:** Se implementó refinamiento de punto fijo en `check` y `escape_summaries` para propagar contratos a través de llamadas encadenadas (`crearVista(u).nombre`), reenvíos y llamadas anidadas.
- **Préstamos disjuntos por campo:** Si una vista devuelta retiene un préstamo a `usuario.nombre`, Proyecto L permite mutar campos disjuntos independientes como `usuario.edad`, mientras que mutar el campo prestado o mover el propietario completo se rechaza estáticamente con `L0012`.
- **Rechazo estricto de escapes inválidos:** Se rechazan con `L0014` y diagnóstico de ubicación exacto los intentos de devolver vistas que apunten a variables locales escalares, campos de agregados locales, temporales de expresiones, elementos de listas locales o buffers regionales.
- **Agregados mixtos y drops:** Vistas con campos propietarios (como `Text`) y prestados (`&Text`) destruyen adecuadamente los campos propietarios al salir de ámbito sin liberar los referentes prestados (`heap_ok=1`, `allocs == frees`).
- **Resolución topológica de alias:** Se sustituyó la asunción de orden secuencial estricto por `VarId` por una resolución topológica de dependencias en `collect_aliases`, detectando ciclos y resolviendo de forma segura alias interprocedimentales.

Validación final: **195 pruebas aprobadas, 0 fallos**. Formato `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios. [Detalle técnico y mediciones](BORROWED_AGGREGATE_RETURNS.md).

## 19. Referencias mutables en agregados y reasignación de vistas

Rama `dev/mutable-aggregate-views`, derivada de `dev/borrowed-aggregate-returns` (`954e2c5`). La base pasó 195 pruebas.
Permite structs que contienen referencias mutables exclusivas `&mut T` y reasignación segura de variables que contienen vistas prestadas (`var vista = ...; vista = ...`).

- **Campos mutables `&mut T`:** Introducción de `Type::MutField(SharedTarget)` en LIR y semántica. Permite `struct VistaMutable { valor: &mut Int }`.
- **Exclusividad estricta y aliasing:** No se permite duplicar permisos mutables ni solapar dos vistas mutables sobre el mismo lugar (`L0012`). Se prohíbe prestar bindings inmutables con `&mut` (`L0012`). Mutar o leer el propietario original mientras la vista mutable esté viva es rechazado con `L0012`.
- **Semántica Move:** Los structs que contienen referencias no implementan `Copy`. Cualquier movimiento de una vista (ej. `let v2 = v1`) invalida la variable origen; accesos posteriores se diagnostican con `L0005` (uso de valor movido).
- **Acceso, lectura y modificación por campos:** Las modificaciones directas e indirectas (`vista.valor = 42`, `self.valor += 1`) operan a través de `FieldLoan`, desreferenciando el puntero sin sobrescribir el struct. Intentos de modificar a través de referencias compartidas `&T` en campos se rechazan.
- **Métodos inherentes en vistas:** Soporte de `impl VistaMutable` con métodos mutables (`mut fn incrementar()`) y receptor `self` que actualiza los referentes.
- **Retornos de vistas mutables:** Las funciones pueden recibir `&mut T` y retornar `VistaMutable` con contrato exclusivo (`Receiver::Exclusive`), propagando la procedencia con seguridad interprocedimental.
- **Reasignación de vistas (`var vista`):** Se permite declarar `var vista = Vista(valor: &a)` y posteriormente reasignar `vista = Vista(valor: &b)`. El análisis de flujo de préstamos (`loans.rs`) genera identidades de préstamo sintéticas por campo para cada variable vista (`ViewFields`), acumulando las fuentes de procedencia en `definitions` y asociando `through` en `origins`. Esto soporta bifurcaciones (`if/else`) y termina los préstamos anteriores correctamente.
- **Codegen Cranelift y backend de referencia:** Se generan tipos de referencia mutable en Rust (`&'l mut T`) con el lifetime de vista `<'l>` en los receptores, y desreferenciación en native codegen (`FieldLoan`).

Validación final: **203 pruebas aprobadas, 0 fallos**. Formato `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios.

## 20. Referencias en enums, Option, Result y colecciones

Rama `dev/borrowed-variants-collections`, derivada de `dev/mutable-aggregate-views` (`fa8b251`). La base pasó 203 pruebas.
Extiende el modelo de préstamos y agregados para soportar tipos compuestos y colecciones con referencias internas:

- **Enums y variantes con referencias (`Option<&T>`, `Option<&mut T>`, `Result<&T, E>`, `Result<&mut T, E>` y enums definidos por el usuario):**
  - Variantes con campos que contienen `SharedField` y `MutField`.
  - Inferencia y verificación de procedencia interprocedimental a través de variantes y reenvío por `?`.
  - El desempaquetado mediante `match` asigna `VarTy::Ref` a los enlaces de referencia, permitiendo reempaquetar o retornar la referencia sin conversiones erróneas a valores leídos.
- **Colecciones de referencias:**
  - Arrays fijos `[&T; N]`.
  - Listas dinámicas `List<&T>` con métodos de extensión (`xs.push(&item)`) e indexación transparente (`xs[i]`).
  - Iteración de solo lectura `for v in xs` sobre colecciones de referencias.
  - Listas regionales `r.list<&T>()` conteniendo referencias con garantías de vida acotadas.
- **Modelo de préstamos unificado (`loans.rs`):**
  - Identificación unificada de sub-lugares mediante `ViewKey::Payload(variante, campo)` y `ViewKey::Index(indice)`.
  - Generación de préstamos asociada únicamente a la variante construida en `Rvalue::Variant`, evitando préstamos sintéticos en variantes sin referencias (ej. `Option.None`) que producían falsos escapes de retorno.
  - Propagación de alias a través de `Rvalue::Use` para `VarTy::Ref`, rastreando la procedencia hasta los parámetros formales.
  - Verificación estricta de escapes (`L0014`), aliasing mutable (`L0012`) y duraciones de vida (`L0013`).
- **Drops deterministas e integridad de memoria:**
  - Sin recolector de basura ni copias profundas automáticas.
  - Las variantes activas propietarias (ej. `Text` en `Result.Err(Text)`) se destruyen al salir de ámbito, mientras que los referentes prestados nunca son destruidos por el drop de la colección o variante (`heap_ok=1`, `allocs == frees`).
- **Backends Cranelift y Rustc:**
  - Rustc: cálculo de `lifetime_enums` y `lifetime_structs` para emitir el parámetro de lifetime `<'l>`, preservando la paridad diferencial en la ejecución de pruebas instrumentadas.
  - Cranelift: codegen nativo de punteros directos de 8 bytes en las cargas útiles de variantes y elementos de colecciones.

Validación final: **211 pruebas aprobadas, 0 fallos** (203 de base y 8 nuevas). Formato `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios.

## 21. Etapa dev/native-async-foundation (2026-11-08): async/await

Rama `dev/native-async-foundation`, derivada de `dev/borrowed-variants-collections`
(`8068500`). **Estado inicial medido: 201 pruebas aprobadas, 0 fallos, 3
ignoradas**, fmt y clippy limpios, árbol limpio. (Las secciones §15–§20 y
AGENT_HANDOFF §15 declaraban 211; el recuento real de `cargo test` en esa base es
201 + 3 ignoradas. No se tocó ninguna prueba existente.)

Modelo completo en [ASYNC_MODEL.md](ASYNC_MODEL.md), runtime y ejecutor en
[FUTURE_RUNTIME.md](FUTURE_RUNTIME.md), invariantes en
[MEMORY_MODEL.md](MEMORY_MODEL.md) §15.

| Requisito del encargo | Estado |
|---|---|
| Auditoría previa de ownership/referencias | **Hecha**: 201/201 en la base, sin cambios en las garantías existentes; las reglas de suspensión se construyen sobre ellas (§4 de ASYNC_MODEL) |
| Sintaxis `async fn` / `await` reconocida | **Probado** |
| Tipos `Future<T>` | **Probado** (opacos, uno por función async; DECISIONS 102) |
| Análisis semántico (posiciones, propiedad, efectos) | **Probado** (`L0015 [async]`, 9 pruebas negativas) |
| Representación de máquina de estados | **Probado**: tres funciones por `async fn` en la LIR de bloques, verificadas antes del codegen |
| Suspensión y reanudación reales | **Probado**: `suspends` del runtime instrumentado distingue una suspensión real de un cuerpo ejecutado de corrido |
| Varios `await`, condiciones, retornos anticipados, bucles | **Probado** (while, for sobre rango, loop/break, if/else, `?`) |
| Generación nativa (Cranelift) | **Probado** |
| Ejecutor cooperativo con notificación | **Probado**: `Wake`/`TaskWait`, sin hilos, sin espera activa, interbloqueo informado |
| Drops dependientes del estado y cancelación | **Probado**: destructor por estado, destrucción de futures sin sondear y en cascada |
| Contratos de efectos con async | **Probado**: crear ≠ ejecutar; `@noalloc` no puede crear futures |
| Pruebas de memoria instrumentadas | **Probado**: `allocs == frees` y `heap_ok=1` en los 10 programas positivos, incluido fallo de reserva inyectado |
| `spawn` y concurrencia estructurada | **No implementado** (rechazado con diagnóstico; hito siguiente) |
| Recursos vivos a través de una suspensión | **No implementado**: rechazado con `L0015` (DECISIONS 105) |
| Multihilo, E/S asíncrona, sockets | Fuera de alcance de este hito |

Pruebas añadidas: `tests/async.rs`, **16** (10 positivas diferenciales e
instrumentadas, 6 negativas con 24 programas rechazados). Total: **217 aprobadas,
0 fallos, 3 ignoradas**; `cargo fmt --check` y `cargo clippy --all-targets -- -D
warnings` limpios.

Defectos corregidos durante la etapa:

1. **La elaboración de drops descartaba los drops de lugares detrás de una
   referencia** (consultaba un estado de propiedad que no existe para ellos).
   Sin esto, el estado de cada tarea se filtraba (`allocs=2 frees=1`).
2. Las variables guardadas en el estado se registraban en el marco de la
   sentencia en lugar del marco del scope, así que desaparecían antes de la
   suspensión (LIR inválida: variable usada sin asignar).
3. El retorno de suspensión no liberaba lo que el cuerpo aún poseía (fuga
   detectada por el verificador).
4. Dos construcciones producían un error interno del compilador en lugar de un
   diagnóstico: suspender dentro de un `for` sobre una colección y suspender con
   una región abierta. Ahora son `L0015` con mensaje y posición.
5. Un `await` sobre un future ya consumido informaba el mensaje de suspensión; se
   corrigió para que lo informe la propiedad (`L0005`, uso tras movimiento).
6. Una función async genérica no se rechazaba hasta instanciarse (nunca, si nadie
   la llama); ahora se rechaza al declararla.

### Memoria (instrumentación `--trace-alloc`)

Todos los programas positivos: `allocs == frees`, `heap_ok=1`, cada liberación
validada contra el heap del proceso. Tamaño del estado de una tarea (layout
determinista): 8 bytes de `reanudar`, el resultado, los parámetros, los locales
guardados y un campo por tipo de future esperado; por ejemplo `async fn f(n: Int)
-> Int` sin `await` ocupa 24 bytes y `yieldNow` 8.

| Programa | Tareas creadas | Reservas | Liberaciones | Suspensiones |
|---|---:|---:|---:|---:|
| ejemplo canónico (42) | 2 | 2 | 2 | 0 |
| dos cesiones con `yieldNow` | 4 | 4 | 4 | 2 |
| anidado + while + for | 14 | 14 | 14 | 6 |
| future abandonado sin sondear | 6+ | = frees | = allocs | 2 |

### Rendimiento (bench/results.md, i5-7300U, mediana de 5)

Un millón de iteraciones por programa. **El backend rustc (`-C opt-level=0`) es
aquí más rápido, y la causa está medida**: los futures de Rust que no se sondean
viven en la pila y no reservan nada, mientras que cada tarea de L reserva su
bloque de estado en el heap (DECISIONS 103).

| Programa | rustc (ms) | cranelift (ms) | Reservas (cranelift) | Suspensiones | Pico KiB cranelift |
|---|---:|---:|---:|---:|---:|
| async_create_1m (crear y destruir) | 29,9 | 169,1 | 1 000 001 | 0 | 2512 |
| async_ready_1m (crear, sondear listo, destruir) | 45,5 | 200,1 | 1 000 001 | 0 | 2512 |
| async_suspend_1m (suspender y reanudar) | 135,0 | 374,3 | 2 000 001 | 1 000 000 | 2512 |

Por iteración en nativo: ~169 ns crear + destruir una tarea, ~200 ns crear +
sondear + destruir, ~374 ns un ciclo completo de suspensión y reanudación (dos
tareas y una notificación). El pico de memoria es plano (~2,5 MiB): una tarea
viva a la vez. Compilar estos programas tarda 107–115 ms con cranelift (348–605
ms con el backend rustc): el lowering async no degrada el tiempo de compilación.
La optimización pendiente evidente es reservar en pila los futures que no
escapan.

## 22. Etapa dev/native-spawn-structured (2026-11-08): spawn y planificador

Rama `dev/native-spawn-structured`, derivada de `dev/native-async-foundation`
(`ff9f2bd`). **Estado inicial verificado en el repositorio: 217 pruebas
aprobadas, 0 fallos, 3 ignoradas**, fmt y clippy limpios, árbol limpio, sin
remoto Git ni stash. Las 217 que §21 declaraba se midieron de nuevo antes de
tocar el compilador.

Modelo en [ASYNC_MODEL.md §7](ASYNC_MODEL.md), planificador en
[FUTURE_RUNTIME.md §3](FUTURE_RUNTIME.md), invariantes en
[MEMORY_MODEL.md §15](MEMORY_MODEL.md), generación de código en
[BACKEND.md §21](BACKEND.md).

| Requisito del encargo | Estado |
|---|---|
| Auditoría inicial y verificación de las 217 pruebas | **Hecha** (medidas, no asumidas) |
| `TaskHandle<T>` tipado, propietario, no duplicable | **Probado** (opaco, un tipo por función async; DECISIONS 109) |
| `spawn` reconocido en la gramática y resuelto | **Probado** |
| Registro de tareas y poll funcional | **Probado** |
| `await` sobre un handle | **Probado** (misma forma que sobre un future) |
| Generación nativa (Cranelift) | **Probado** |
| Varias tareas simultáneamente pendientes | **Probado** (hasta 2 002 tareas vivas) |
| Intercalado cooperativo real | **Probado con trazas deterministas**, no por tiempos |
| Wakers / notificaciones | **Probado**: notificación explícita idempotente, sin notificaciones perdidas ni dobles |
| Sin busy waiting | **Probado por construcción**: el bucle solo saca de la cola de listas |
| Ownership de tareas y handles no copiables | **Probado** (`L0005` al usarlos tras moverlos) |
| Restricciones de lifetime / concurrencia estructurada | **Probado**: un handle no escapa de su scope async; sin tareas desatendidas |
| Cancelación segura | **Probado**: antes de empezar, suspendida, en retorno anticipado, en cascada y en cadenas de 20 000 tareas |
| Drops correctos | **Probado**: `allocs == frees` y `heap_ok=1` en los 15 programas positivos |
| Efectos integrados con spawn | **Probado**: reserva contabilizada y efectos del cuerpo heredados |
| Comparación entre backends | **Probado**: los 15 programas positivos, con la misma traza de intercalado |
| Benchmarks básicos | **Hechos** (abajo) |
| Multihilo, robo de trabajo, E/S asíncrona, sockets | Fuera de alcance de este hito |
| Recursos distintos de un handle a través de una suspensión | **No implementado**: rechazado con `L0015` (DECISIONS 111) |

Pruebas añadidas: `tests/spawn.rs`, **21** (15 positivas diferenciales e
instrumentadas, 6 negativas con 27 programas rechazados). Total: **238
aprobadas, 0 fallos, 3 ignoradas**; fmt y clippy limpios. Las 217 anteriores
siguen pasando; de `tests/async.rs` solo cambiaron tres aserciones de recuento
de reservas (ahora cada tarea tiene también su registro) y se quitó el caso que
comprobaba que `spawn` se rechazaba.

### Defectos corregidos durante la etapa

1. **La cascada de cancelación era recursiva**: destruir un árbol profundo de
   tareas suspendidas desbordaba la pila (`STATUS_STACK_OVERFLOW` con 60 000
   niveles, reproducido en ambos backends). Ahora los dos runtimes mantienen una
   lista de registros pendientes de destruir y la vacían iterativamente.
2. **Una tarea cancelada mientras seguía en la cola de listas no se liberaba
   hasta que el planificador le daba turno**, y la cola era simplemente
   enlazada. Un programa que lanza y descarta muchas tareas sin suspenderse
   acumulaba un registro por tarea. La cola pasó a ser doblemente enlazada, de
   modo que cancelar saca el registro en O(1) y lo libera ahí mismo. En el
   planificador de referencia (Rust) el mismo caso era cuadrático, porque
   registrar una tarea buscaba un hueco libre recorriendo la tabla; ahora hay
   lista de huecos libres.
3. **Un future o un handle se podía meter en un agregado** (`List[f()]`), lo que
   lo desligaba del scope async que lo posee. Era un hueco del incremento
   anterior, no de este. Se cerró con una comprobación general de posiciones de
   manejador (`L0015`).

### Memoria (instrumentación `--trace-alloc`)

Los 15 programas positivos: `allocs == frees`, `heap_ok=1`, cada liberación
validada contra el heap del proceso. Una tarea cuesta dos bloques: su estado
(layout determinista, §21) y su registro en el planificador (56 bytes).

| Programa | Tareas | Reservas | Liberaciones | Suspensiones |
|---|---:|---:|---:|---:|
| ejemplo del encargo (42) | 2 | 5 | 5 | 2 |
| dos tareas (60) | 3 | 8 | 8 | 3 |
| tres tareas intercaladas | 4 | 26 | 26 | 10 |
| tarea cancelada sin empezar | 2 | 4 | 4 | 0 |
| tarea cancelada suspendida | 2 | 8 | 8 | 4 |
| cadena de 20 000 tareas cancelada | 20 001 | 48 004 | 48 004 | 35 999 |
| 50 000 tareas canceladas sin empezar | 50 001 | 100 004 | 100 004 | 0 |
| 1 000 niveles (2 002 tareas) | 2 002 | 6 004 | 6 004 | 3 001 |

Contadores equilibrados son evidencia de las rutas que ejercitan estos
programas, no una demostración de ausencia de fugas en general.

### Rendimiento de las tareas (bench/results.md, i5-7300U, mediana de 5)

| Programa | rustc (ms) | cranelift (ms) | Reservas | Suspensiones | Pico KiB cranelift |
|---|---:|---:|---:|---:|---:|
| spawn_cancel_1m (lanzar y cancelar sin empezar) | 2438,2 | **449,7** | 2 000 002 | 0 | 2516 |
| spawn_await_1m (ciclo de vida completo) | 6268,8 | **818,4** | 3 000 002 | 2 000 000 | 2224 |
| spawn_interleave_100k (200 002 tareas vivas) | 1138,0 | **259,2** | 600 004 | 300 001 | 32 524 |
| async_create_1m (crear y destruir un future) | **23,2** | 135,5 | 1 000 002 | 0 | 2224 |
| async_ready_1m (crear, sondear listo, destruir) | **60,0** | 173,2 | 1 000 002 | 0 | 2224 |
| async_suspend_1m (suspender y reanudar) | 1150,3 | **327,0** | 2 000 002 | 1 000 000 | 2224 |

Por iteración en nativo: **~450 ns** lanzar y cancelar una tarea sin empezarla
(dos reservas y dos liberaciones), **~818 ns** un ciclo de vida completo
(`spawn`, planificación, suspensión, notificación, reanudación, resultado y
liberación, con tres reservas y dos suspensiones) y **~1,3 µs** por tarea en el
caso de 200 002 tareas vivas a la vez. El pico de memoria con 300 000 tareas
vivas es de 32,5 MiB, unos 110 bytes por tarea viva (estado + registro de 64
bytes); con una tarea a la vez el pico es plano (~2,2 MiB). Compilar estos
programas tarda 117–198 ms con cranelift frente a 805–1766 ms con el backend
rustc: el lowering de tareas no degrada el tiempo de compilación.

**El backend nativo es ahora más rápido en todo lo que planifica** (1,8× en
lanzar/cancelar, 4,4× en intercalado, 7,7× en el ciclo de vida completo). Sigue
siendo más lento en crear y destruir un future que nunca se sondea, y la causa
es la misma que en §21: los futures de Rust que no se sondean viven en la pila y
no reservan nada, mientras que cada tarea de L reserva su estado en el heap
(DECISIONS 103). Es la optimización pendiente evidente.

Dos avisos de honestidad sobre esta tabla:

- Las cifras de §21 son la medición de aquel incremento; esta tabla y
  bench/results.md las sustituyen. En particular, `async_suspend_1m` no es
  comparable con el 135,0 ms que §21 midió para el
  backend rustc: su ejecutor pasó de sondear una sola tarea a ser un
  planificador completo, así que ahora paga el coste de la cola y de los
  registros. La cifra de cranelift (374,3 → 327,0 ms) sí es comparable.
- El backend rustc se compila con `-C opt-level=0`, que es su configuración
  actual. Estas cifras no son una comparación con Rust optimizado ni con Tokio,
  que no se ha medido en condiciones comparables.

## 23. Etapa dev/async-owned-resources (2026-11-09)

Base `336b98e` con 238 pruebas aprobadas, 0 fallos y 3 ignoradas. La suite
final aprobó 249 pruebas, con 0 fallos y 3 ignoradas. Se agregaron 11
pruebas. Pasaron `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings`.
Este
incremento cubre el almacenamiento de `Text` local, lectura y movimiento
al reanudar, reemplazo, destrucción léxica y cancelación. El análisis del
CFG separa el flujo de las ranuras del flujo de los temporales de cada
sondeo. Véanse ASYNC_MODEL §8 y BACKEND §22.

Los casos de ejecución incluyen bucles, reasignación desde `await`, préstamos
nuevos en cada sondeo, `match`, `?`, cancelación antes del primer sondeo,
cancelación en cascada y resultados listos sin consumir. Los rechazos cubren uso tras movimiento, préstamos
usados tras suspender y CFG alterados con ranuras vacías o con índices de
reanudación inconsistentes. Continúan vigentes los rechazos de parámetros
propietarios, regiones abiertas y agregados o colecciones locales usados
tras suspender.

Cada ranura de `Text` en Windows x64 agrega 32 bytes al estado existente:
8 bytes de etiqueta y 24 bytes de carga. No crea otra reserva. El registro
del planificador sigue ocupando 64 bytes cuando se usa `spawn`. En el programa
de carga, el manejador `Future<T>` mide 8 bytes y el layout calculado de los
estados `trabajo` y `lote` mide 80 y 112 bytes, respectivamente. La vivacidad
conservadora mantiene las ranuras hasta el fin de ámbito, aunque el último uso
ocurra antes de la suspensión. Quedan por implementar movimientos parciales
de campos, agregados y colecciones persistentes y un análisis de vivacidad
más preciso.


### Pruebas de carga y costes

`bench/programs/async_owned_text.l` completa y cancela 10, 100 y 1000
tareas por lote. Ambos ejecutables imprimieron `10`, `100` y `1000` y
salieron con código 0. La variante Cranelift instrumentada registró
11 105 reservas, 11 105 liberaciones, 5550 suspensiones y `heap_ok=1`.
La ejecución nativa se verificó con `PATH` vacío. El caso canónico imprimió
`Hola Ana`, con 5 reservas, 5 liberaciones y una suspensión. La cancelación
de una tarea pendiente y otra sin sondear registró 9 reservas, 9 liberaciones
y 2 suspensiones. La cancelación en cascada y la destrucción de un resultado
listo sin consumir registraron 16 reservas, 16 liberaciones y 5 suspensiones.
En ambos casos de cancelación se verificó `heap_ok=1`.

Medianas de siete compilaciones y siete ejecuciones por backend en Windows
x64 con el CLI de depuración. Compilar incluye el enlazado y ejecutar incluye
arrancar el proceso. El pico es el máximo de las muestras del conjunto
residente del proceso.

| Backend | Compilar (ms) | Ejecutar (ms) | Ejecutable (bytes) | Pico observado (KiB) |
|---|---:|---:|---:|---:|
| rustc | 551 | 39,4 | 183 808 | 3116 |
| Cranelift | 310 | 34,3 | 13 312 | 2520 |

El programa nuevo no era admitido en la base. Estas mediciones comparan
backends. En un microbenchmark de depuración, la mediana de siete diferencias
pareadas fue de 89 µs adicionales por verificación del CFG. Cada par promedió
200 verificaciones del mismo módulo con y sin el pase de ranuras, alternando el
orden. No se cronometró cada sondeo, la construcción ni la cancelación por
separado. La instrumentación comprueba el balance de bloques y la validación del heap
al final del proceso. No se ejecutaron sanitizers.

## 24. Etapa dev/async-owned-aggregates (2026-11-09)

Base `393d7a4`, con 249 pruebas aprobadas, 0 fallos y 3 ignoradas. Las
ignoradas corresponden a microbenchmarks manuales en `crates/l/src/loans.rs`
para el pase de préstamos, retornos prestados y vistas locales. La suite
final aprobó 268 pruebas, con 0 fallos y 3 ignoradas. Se agregaron 19 pruebas.
Pasaron `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings`.

- Los propietarios por valor se transfieren al crear el future. `Text`,
  structs, enums, arrays y `List<T>` admitidos usan el mismo tipo de ranura.
- El análisis de CFG prueba inicialización por campo de struct y verifica
  el constructor, las reanudaciones y los accesos a la variante activa.
  Un struct parcialmente movido
  conserva los campos disjuntos y permite restaurar los movidos mediante
  asignación. Los enums conservan su discriminante y los destructores
  visitan solo su variante activa. Arrays y listas conservan sus elementos
  y las listas pueden crecer al reanudar.
- Se probaron tareas canceladas antes del primer sondeo, con parámetros
  propietarios, después de varios awaits, tras reemplazo y en cascada.
  También se probó `?` con `Result` persistente y la liberación de
  propietarios en la ruta de error.
- Los efectos siguen siendo los de las operaciones existentes. La etiqueta
  de ranura vive en el bloque del future. Se mantienen las restricciones
  de préstamos, vistas, regiones abiertas y recorridos prestados. Vaciar
  un campo se verifica como escritura. Un préstamo disjunto puede seguir
  vivo durante ese movimiento dentro del mismo sondeo.

### Estado y cancelación

En Windows x64 el manejador `Future<T>` mide 8 bytes. El estado de la tarea
de trabajo mide 80 bytes en la carga Text, 128 en la de structs y 112 en la
de listas. Las ranuras medidas son 32 bytes para `Text` o `List<Dato>` y
56 para el struct de dos campos `Text`. La etiqueta usa ocho bytes del
estado y no requiere una reserva independiente. Con `spawn` se añade el
registro de planificación de 64 bytes.

| Caso instrumentado | Reservas | Liberaciones | Suspensiones |
|---|---:|---:|---:|
| Struct parcialmente movido y tarea sin sondear | 16 | 16 | 4 |
| Enum activo, inactivo y tarea sin sondear | 15 | 15 | 3 |
| Resultado de `?` listo sin consumir y parámetro array propietario | 10 | 10 | 3 |
| Cascada de 1001 tareas con listas y reemplazos | 10 015 | 10 015 | 2004 |

Los cuatro casos dieron `heap_ok=1`. La cascada llegó al último hijo antes
de soltar el handle raíz. El caso con `?` también se ejecutó manualmente
en ambos backends. Ambos imprimieron `propagar` y `fin` y devolvieron código
0. La carga de listas se compiló y ejecutó con Cranelift y `PATH` vacío.

### Cargas de 10, 100 y 1000 tareas

Los programas `async_owned_text.l`, `async_owned_structs.l` y
`async_owned_lists.l` de `bench/programs` imprimieron `10`, `100` y `1000`
en ambos backends. Estos datos se pueden volver a medir con el ejecutor
de benchmarks del repositorio. Las cifras siguientes son medianas de siete
compilaciones y siete ejecuciones por backend con el CLI de depuración
en Windows x64. Compilar incluye enlazado. Ejecutar incluye arrancar el
proceso. Los picos son máximos observados del conjunto residente.

| Carga | Compilar Cranelift / rustc (ms) | Ejecutar Cranelift / rustc (ms) | Pico Cranelift / rustc (KiB) | Reservas / liberaciones nativas |
|---|---:|---:|---:|---:|
| Text | 376 / 671 | 44,3 / 50,4 | 2248 / 2840 | 11 105 / 11 105 |
| Structs | 334 / 759 | 39,5 / 45,0 | 2272 / 2848 | 13 325 / 13 325 |
| Listas | 358 / 724 | 41,5 / 46,3 | 2252 / 2848 | 17 765 / 17 765 |

Las tres trazas nativas dieron 5550 suspensiones y `heap_ok=1`. La carga de
listas registró 1110 llamadas a realocación. La carga comparable de Text
conservó sus contadores y los 80 bytes de estado del trabajador. Su tiempo
de compilación observado pasó de 310 a 376 ms con Cranelift y de 551 a 671 ms
con rustc entre las mediciones de §23 y §24. Son mediciones de extremo a
extremo en sesiones distintas. No se aislaron los tiempos por suspensión,
reanudación o cancelación. El código máquina de Cranelift no se instrumentó
con sanitizers. El balance de bloques y `HeapValidate` solo comprueban las
ejecuciones realizadas.


## 25. Etapa dev/native-async-join (2026-11-09)

Base `545fdf6`, con 268 pruebas aprobadas, 0 fallos y 3 ignoradas. La suite
final pasó 278 pruebas, 0 fallos y 3 ignoradas. Se agregaron 10 pruebas.
Pasaron `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings`.
Las ignoradas siguen siendo microbenchmarks manuales de préstamos.
La ruta nativa coordina dos handles con las consultas del scheduler
existente. La ruta de referencia usa `poll_fn`. El padre puede
comprobar el estado tras la primera notificación y solo toma los
resultados cuando ambas hijas terminaron.

Las pruebas cubren resultados inmediatos, orden de finalización distinto
al de argumentos, resultados propietarios, `Result` y `?`, y joins
anidados. Los negativos comprueban aridad, tipo de operandos, movimiento
único de handles y resultados, y préstamos incompatibles o vivos al
suspender. Las pruebas de cancelación incluyen un padre sin sondear,
una hija lista, ambas hijas listas sin que el padre haya reanudado
y cascadas con hijas pendientes y resultados propietarios listos.

`joinAll` y las colecciones de handles siguen pendientes. La espera
binaria usa ranuras del padre y no asigna un bloque propio.

### Trazas verificadas

| Caso Cranelift | Reservas | Liberaciones | Suspensiones |
|---|---:|---:|---:|
| Ejemplo `20`, `40` con `PATH` vacío | 8 | 8 | 3 |
| La segunda hija termina primero | 11 | 11 | 6 |
| Cancelación sin sondear, con una hija lista o con ambas listas | 31 | 31 | 7 |
| Cancelación de joins anidados | 25 | 25 | 9 |
| Cascada de 1001 tareas descendientes del ejecutor | 4016 | 4016 | 2012 |

Todas las trazas dieron `heap_ok=1`. El ejemplo se compiló y ejecutó
con Cranelift y `PATH` vacío. Con un handle repetido, la CLI salió con
código 1 y dio `L0005` en la línea y columna del segundo argumento.
La carga de cascada construye 500 padres de join pendientes, 500
hermanas que producen listas y una hoja profunda que sigue pendiente
hasta la cancelación. La carga anterior de 1001 tareas también conservó
10 015 reservas, 10 015 liberaciones y 2004 suspensiones.

### Medición de coordinación

La carga `bench/programs/async_join.l` imprime `10`, `100` y `1000`.
El comparador secuencial lanza los mismos dos hijos y espera primero
el de `Text` y después el de `List<Text>`. La variante se reproduce
sustituyendo la espera del par por dos `spawn`, seguidos de dos
`await`, y leyendo la longitud del segundo resultado. La cascada se
reproduce con `deep_join_cascade_cancels_pending_branches_and_drops_completed_lists`
en `crates/l/tests/spawn.rs`.

Se midieron medianas de siete compilaciones y siete ejecuciones por
backend en Windows x64. Se usó el CLI de depuración con los ajustes
vigentes de cada backend. Rustc genera código con `opt-level=0`.
Compilar incluye enlazado. Ejecutar incluye el arranque del proceso
y el pico es el máximo observado del conjunto residente.

| Carga | Compilar Cranelift / rustc (ms) | Ejecutar Cranelift / rustc (ms) | Pico Cranelift / rustc (KiB) |
|---|---:|---:|---:|
| Join | 281 / 561 | 29,8 / 34,9 | 2260 / 3284 |
| Esperas secuenciales | 353 / 616 | 33,2 / 38,5 | 1976 / 2860 |
| Cascada | 335 / 668 | 33,0 / 39,1 | 2300 / 3672 |

Join y las esperas secuenciales registraron 6110 reservas, 6110
liberaciones, 2220 suspensiones y `heap_ok=1`. La igualdad se refiere
a esta carga. Las mediciones incluyen el ciclo completo y quedan
sin medir por separado el wake y la purga de cancelación. El código
máquina de Cranelift se validó con traza y `HeapValidate`, sin
instrumentación de sanitizers.


## 26. Etapa dev/native-async-join-all (2026-11-09)

Base `7886c04`, con 278 pruebas aprobadas y 3 microbenchmarks manuales
ignorados. La suite final pasó 289 pruebas, con 0 fallos y los mismos
3 microbenchmarks ignorados. Pasaron `cargo fmt --check` y Clippy con
`--all-targets -- -D warnings`. Se añadieron 11 pruebas. Los grupos soportan tamaños dinámicos y resultados
homogéneos de distintas funciones. El registro de tarea nativo
pasa de 64 a 72 bytes. El contador de pendientes evita volver a
recorrer los handles tras cada finalización. Las ranuras del padre
conservan la propiedad durante la suspensión y la recolección
mueve resultados al prefijo inicializado de la lista de salida.

El ejemplo del traspaso compiló y ejecutó con Cranelift y `PATH` vacío.
Imprimió `20`, `40` y `60` con 13 reservas, 13 liberaciones, 4
suspensiones y `heap_ok=1`. El duplicado de un handle se rechazó con
`L0005` en `duplicado.l:4:35`.

### Memoria, cancelación y pruebas

- La carga de 10, 100, 1000 y 10 000 tareas produjo el mismo stdout en
  rustc y Cranelift. En la traza nativa hubo 61 119 reservas,
  61 119 liberaciones, 16 669 suspensiones y `heap_ok=1`.
- La cancelación de dos subgrupos de 5000 hijas conservó los resultados
  tempranos hasta purgar el padre. Los dos backends ejecutaron después
  otro grupo. La traza nativa dio 30 028 reservas y liberaciones,
  10 009 suspensiones y `heap_ok=1`.
- Se verificó la cancelación con todas las hijas pendientes y con todas
  listas sin entregar el resultado. Se verificaron los movimientos de
  grupos descartados, la reutilización de registros, resultados de
  tipos compuestos y el orden independiente de la finalización.
- Además de los rechazos de ownership, el caso manual `@noalloc`
  produjo `L0010` con la causa `joinAll: lista de resultados`.
- La carga anterior de join binario conservó 6110 reservas y
  liberaciones, 2220 suspensiones y `heap_ok=1`.

### Benchmarks reproducibles

Las cargas en `bench/programs/async_join_all.l` y
`bench/programs/async_join_all_pair.l` pueden ejecutarse con el
runner de benchmarks del repositorio. La variante comparable de
`join` binario sustituye `await joinAll(List[spawn trabajo(...),
spawn trabajo(...)])` por `await join(spawn trabajo(...), spawn trabajo(...))`
y suma `par.first.length + par.second.length`. La variante por tamaño
deja en `main` solo una llamada a `lote(n)`. La carga de cancelación
se obtiene de la prueba `join_all_cancels_nested_large_groups_and_reuses_records`
en `crates/l/tests/spawn.rs`.

Medianas de siete compilaciones y ejecuciones en Windows x64, con
el CLI de depuración y los ajustes de cada backend. Rustc genera
código con `opt-level=0`. La compilación incluye enlazado. La
ejecución incluye el arranque del proceso y el pico es el máximo
observado del conjunto residente.

| Carga | Compilar Cranelift / rustc (ms) | Ejecutar Cranelift / rustc (ms) | Pico Cranelift / rustc (KiB) |
|---|---:|---:|---:|
| Grupos de 10, 100, 1000 y 10 000 | 318 / 578 | 47,5 / 61,6 | 5032 / 6048 |
| Grupos de dos, 550 pares | 623 / 584 | 45,4 / 58,7 | 2260 / 3272 |
| Join binario comparable, 550 pares | 302 / 573 | 38,0 / 45,9 | 2160 / 3280 |
| Cancelación anidada | 411 / 654 | 38,5 / 53,3 | 4072 / 5736 |

En la comparación de pares, la traza Cranelift midió 7154 reservas
y 2200 suspensiones para `joinAll`, frente a 6054 reservas y 2750
suspensiones para el join binario. Ambos liberaron todas sus
reservas y dieron `heap_ok=1`. Los 1100 bloques adicionales son
los dos buffers de lista por par. En esta carga el contador
evitó un segundo Pending del padre en cada par.

| Grupo aislado en Cranelift | Compilar (ms) | Ejecutar (ms) | Pico (KiB) |
|---|---:|---:|---:|
| 100 tareas | 343 | 30,7 | 1976 |
| 1000 tareas | 367 | 32,0 | 2740 |
| 10 000 tareas | 299 | 46,3 | 5236 |

El grupo de 10 000 costó 4,63 µs por tarea completada al dividir
el tiempo total, que incluye arranque y recolección. No se
aislaron los tiempos de creación, notificación, recolección y
purga. El código máquina de Cranelift se comprobó con la traza
y `HeapValidate`. No se ejecutaron sanitizers.

## 27. TaskGroup tipado y concurrencia estructurada nativa (dev/native-scoped-taskgroups)

La etapa anterior (`dev/native-async-join-all`, commit `453b7a2`) permitía esperar grupos
dinámicos mediante listas de handles homogéneos y `taskGroup(f)`. Este incremento formaliza
`TaskGroup<T, Scope>` en todo el compilador y runtime nativo:

1. **Sistema de tipos (`sema.rs`)**:
   - Tipo de primera clase `TaskGroup<T>` con scope implícito ligado al ámbito léxico.
   - Constructor `taskGroup<T>()` con argumento de tipo explícito y método `.spawn(llamadaAsync)`.
   - Compatibilidad total con `taskGroup(f)`, `.push(spawn ...)`, `.reserve(n)` y `await joinAll(grupo)`.
   - Invariantes de confinamiento: prohibido pasar como parámetro o retornar (`L0015`),
     prohibido almacenar en agregados/colecciones (`struct`, `enum`, `List`, array) (`L0015`),
     prohibido prestar (`&` o `&mut`) (`L0012`), y prohibido escapar de un ámbito menor a uno
     mayor (`outer = inner` con `L0015`).
   - Ownership verificado: sin semántica `Copy`, consumo único en `await grupo.joinAll()`
     y rechazo de use-after-move con `L0005`.
2. **LIR y CFG (`lir.rs`, `cfg.rs`, `layout.rs`)**:
   - `Type::TaskGroup(usize)` con tabla de definiciones en `Program`.
   - Layout compacto de 24 bytes `(ptr, len, cap)` idéntico a `List`.
   - Monomorfización y verificación de LIR para manipulación segura de punteros a tareas.
3. **Generación nativa Cranelift (`native.rs`)**:
   - Declaración de funciones de drop glue `task_group_drop_glue` para cada tipo de `TaskGroup`.
   - Cancelación iterativa de cada tarea viva en el búfer mediante `l_rt_task_cancel`, evitando recursión no acotada.
   - Liberación determinista del búfer con `l_rt_free`, garantizando cero fugas en retornos tempranos o fin de ámbito (`allocs == frees`).
4. **Verificación y Pruebas**:
   - 297 pruebas pasando limpiamente (56 en `tests/spawn.rs`).
   - Carga de estrés reproducible `bench/programs/async_taskgroup.l` (10 000 tareas) completada con éxito.
   - `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios al 100%.

## 28. Futures de primera clase, ownership y async composable (dev/first-class-futures)

Este incremento formaliza `Future<T>` como un valor de primera clase con garantías de Single Ownership y paridad nativa completa:

1. **Sistema de tipos (`sema.rs`)**:
   - Tipo de primera clase `Future<T>` con unificación nominal y estructural sobre el resultado `T`.
   - Compatibilidad completa para almacenar en variables (`let fut: Future<T> = ...`), mover, pasar como argumento y retornar desde funciones (`-> Future<T>`).
   - Retorno explícito exigido: funciones que retornan futuros sin anotación explícita son rechazadas con `L0015` para prevenir fuga de tipos de máquinas de estado anónimos.
   - Restricciones de seguridad: no admite préstamos (`&Future` o `&mut Future` rechazados con `L0012`), no admite agregación en structs/enums/listas/arrays (`L0015`).
   - Single ownership: consumo único verificado estáticamente; doble `await`, doble `spawn` o uso tras mover rechazados con `L0005`.
2. **Layout y Despacho Dinámico (`cfg.rs`, `native.rs`)**:
   - Encabezado autocontenido y determinista en todas las máquinas de estado:
     - Offset 0: `tipo: i64` (`KIND_FIELD`)
     - Offset 8: `reanudar: i64` (`RESUME_FIELD`)
     - Offset 16: `resultado: T` (`RESULT_FIELD`)
     - Offset 24+: parámetros y variables locales capturadas.
   - Estabilidad de offsets: cualquier futuro con resultado `T` expone su ranura de resultado en el byte 16, posibilitando acceso universal tras el sondeo.
   - Polimorfismo en tiempo de ejecución: `Rvalue::FuturePoll(p)` lee `kind = *(i64*)state` y despacha a `rt.poll_dispatch`.
   - Limpieza determinista: el destructor de `Type::Future` lee `kind = *(i64*)ptr`, invoca `rt.drop_dispatch` y libera la reserva con `l_rt_free`, garantizando cero fugas en futuros abandonados.
   - `Rvalue::TaskSpawn` lee dinámicamente `kind` del estado del futuro en lugar de requerir fijación estática.
3. **Backend de referencia (`backend.rs`)**:
   - Mapeo transparente a `LFuture<T> = std::pin::Pin<Box<dyn std::future::Future<Output = T>>>`.
   - Llamadas asíncronas empaquetadas en `Box::pin(f{id}(...))` compatibles con `.await` y `l_spawn`.
4. **Verificación y Pruebas**:
   - 306 pruebas pasando limpiamente (33 en `tests/async.rs`, 56 en `tests/spawn.rs`, 9 en nueva suite `tests/futures.rs`).
   - Paridad diferencial total entre rustc y Cranelift en ejecución y salidas.
   - Validación de memoria instrumentada (`--trace-alloc`): `heap_ok=1`, `allocs == frees`.
   - `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios al 100%.

## 29. Await como expresión general y Lowering ANF seguro (dev/general-await-expressions)

Este incremento universaliza la posición de `await`, permitiendo utilizarlo libremente como una subexpresión compuesta dentro de cualquier función `async fn`:

1. **Lowering A-Normal Form (ANF) en el Front-End (`crates/l/src/async_desugar.rs`)**:
   - Fase preliminar ejecutada en `sema::lower()` antes del typechecking y la construcción del CFG.
   - Algoritmo recursivo que inspecciona el AST identificando expresiones compuestas que contengan `await`.
   - Extracción de operandos: cualquier subexpresión evaluada con anterioridad a un punto de suspensión asíncrono es extraída a una sentencia `let __l_await_tmp_{N} = ...`.
   - Detección de trivialidad: literales (`Int`, `Float`, `Bool`, `Unit`) e identificadores de variables locales (`Name`) se consideran triviales y no generan bindings temporales innecesarios.
   - Preservación estricta del orden de evaluación: los operandos se ejecutan rigurosamente de izquierda a derecha.
   - Cortocircuito lógico: expresiones `lhs && rhs` y `lhs || rhs` con operandos asíncronos se bajan a estructuras condicionales con variables acumuladoras mutables, garantizando que el segundo operando solo se evalúe si es estrictamente necesario.
   - Bucles asíncronos: bucles `while await cond()` son transformados a bucles infinitos con verificación interna y sentencia `break`, garantizando que la condición se reevalúe y suspenda limpiamente en cada iteración.
   - Preservación de argumentos con nombre en constructores de estructuras (`Named(field, val)`).
2. **Ciclo de vida y Adaptive Ownership a través de suspensiones**:
   - Los temporales extraídos quedan declarados como variables locales estándar del ámbito.
   - El compilador les asigna ranuras en el struct de estado del generador (`f$estado.lN`) gestionadas mediante `$async_slot` (Empty/Full).
   - Tipos propietarios (`Text`, `List`, `Struct`) que sobreviven a una suspensión son limpiados automáticamente por el drop glue del generador (`lower_async_drop`) en caso de cancelación prematura, garantizando ausencia total de memory leaks (`allocs == frees`, `heap_ok=1`).
3. **Diagnósticos y validación semántica (`sema.rs`)**:
   - `await` fuera de funciones `async fn` sigue siendo estrictamente rechazado con `L0015: await solo es válido dentro de funciones async`.
   - `await` dentro de constantes globales o sentencias `const` es estrictamente rechazado con `L0015`.
   - `await` sobre tipos no compatibles (no-`Future`, no-`TaskHandle`) rechazado con `L0003`.
   - Single Ownership verificado: doble consumo o uso de un future tras mover rechazado con `L0005`.
4. **Verificación y Pruebas**:
   - 317 pruebas pasando limpiamente (33 en `tests/async.rs`, 56 en `tests/spawn.rs`, 9 en `tests/futures.rs`, y 11 nuevas pruebas exhaustivas en `tests/await_expr.rs`).
   - Paridad total entre `backend.rs` (rustc) y `native.rs` (Cranelift).
   - `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios al 100%.

## 30. Etapa dev/native-async-timers (2026-11-09)

Base `002b76b` de Antigravity, con 317 pruebas aprobadas, 0 fallos y
3 microbenchmarks manuales ignorados. Se añadieron 9 pruebas. La suite
final pasó 326 pruebas, con 0 fallos y 3 ignoradas. Pasaron `cargo fmt
--check` y `cargo clippy --all-targets -- -D warnings`.

El ejemplo de un segundo se compiló y ejecutó con Cranelift y
`PATH` vacío. Imprimió `Inicio` y `Un segundo después`, con 4 reservas,
4 liberaciones, un registro, un wake, una espera de Windows y
`heap_ok=1`.

También se verificó manualmente la cancelación con wake ya encolado.
La hija registró `sleepMs(75)`. El padre mantuvo trabajo listo con
un bucle de suma y cedió antes de soltar el handle. La traza dio un
wake y cero retiros de temporizador durante la purga. La hija no
imprimió. Hubo 8 reservas, 8 liberaciones y `heap_ok=1`.

Los negativos cubren duración negativa, valor extremo, tipo incorrecto,
aridad, doble consumo y `@noalloc`. En ambos backends se verificó el
panic localizado de una duración dinámica inválida.
[Resultados de rendimiento](TIMER_RUNTIME.md).


## 31. Fundamentos de self-hosting

`Text.byteLength` devuelve la longitud UTF-8 en bytes como `Int`.
`Text.byteAt(Int)` lee un byte como entero 0–255 y comprueba límites.
Ambas operaciones conservan la propiedad del receptor y carecen de
asignación propia. `byteAt` declara el efecto `panic`. Cranelift
reutiliza la lectura comprobada de bytes del CFG y la referencia usa
el mismo contrato sobre el slice UTF-8 de Rust.

El lexer inicial en L admite palabras ASCII, enteros decimales como
rangos, símbolos, saltos de línea y comentarios. Devuelve rangos de byte
y EOF, o clase de error y offset. En esa fase la entrada llegaba desde el
harness. Este incremento construyó un componente
con Stage 0. Las recompilaciones del propio compilador empiezan en Stage 2.

Suite final con 332 pruebas aprobadas, cero fallos y tres microbenchmarks
manuales ignorados. Pasaron `cargo fmt --check` y
`cargo clippy --all-targets -- -D warnings`.

[Alcance, pruebas y próximos hitos](SELF_HOSTING_ROADMAP.md).


## 32. Self-hosting fase 2

`lexer-l` analiza archivos reales con argumentos Unicode, tope de
16 MiB, validación UTF-8, rangos de byte y diagnósticos por stderr.
El lexer L permanece separado de la plataforma. El build combina
sus fuentes y el ejecutable obtiene su entrada del sistema de
archivos en ejecución.

La API de plataforma incluye `processArgCount`, `processArg`,
`readText` y `printError`. `main` síncrono admite resultado
`Int` explícito para el estado de salida. Cranelift conserva el
codegen y añade un objeto auxiliar Win64 a demanda. La referencia
tiene una implementación equivalente con Rust std.

Suite final con 337 pruebas aprobadas, cero fallos y tres
microbenchmarks ignorados. Pasaron `cargo fmt --check` y
`cargo clippy --all-targets -- -D warnings`.

[Contrato, pruebas y benchmarks](LEXER_FILE_CLI.md).


## 33. Self-hosting fase 3: Paridad léxica, strings, interpolación y sistema de módulos (dev/self-hosting-lexer-modules)

Este incremento completa los fundamentos del frontend self-hosted y la compilación multifichero:

1. **Paridad léxica completa (`compiler-l/src/lexer.l`)**:
   - Literales de texto simples: delimitación `"..."`, strings vacíos `""`, cadenas con Unicode.
   - Escapes estándar: `\n`, `\t`, `\r`, `\"`, `\\`.
   - Escapes Unicode: `\u{HEX}` (1 a 6 dígitos), con validación de rango `<= 0x10FFFF` y exclusión de surrogates (`0xD800..=0xDFFF`).
   - Llaves literales: `{{` y `}}` representan `{` y `}` sin iniciar interpolación.
   - Interpolación completa: delimitadores `{...}`, fragmentos `TextStart`, `Text`, `InterpolationStart`, `InterpolationEnd` y `TextEnd`.
   - Anidamiento recursivo de expresiones y strings dentro de interpolaciones hasta 64 niveles (`ExcessiveDepth`).
   - Diagnósticos con offsets exactos: `UnclosedString`, `InvalidEscape`, `InvalidUnicodeEscape`, `InvalidUnicodeScalar`, `UnclosedInterpolation`, `UnopenedBrace`, `ExcessiveDepth`.
2. **Interfaz de Cursor de Tokens (`compiler-l/src/cursor.l`)**:
   - `struct TokenCursor`: puntero de posición e identidad de archivo.
   - Operaciones seguras sin copia sobre `List<LexToken>`: `cursorNew`, `cursorIsAtEnd`, `cursorCurrent`, `cursorCurrentKind`, `cursorAdvance`, `cursorExpect`.
   - Prepara la frontera limpia requerida para comenzar el parser escrito en L.
3. **Sistema de Módulos e Imports en Stage 0 (`crates/l/src/modules.rs`)**:
   - Sentencia `import <modulo>` con terminador de línea o `;`.
   - Resolución canónica con `std::fs::canonicalize`, soportando rutas relativas y submódulos jerárquicos con puntos (`import sub.motor` -> `sub/motor.l`).
   - Deduplicación determinista en grafos de dependencias en diamante: cada archivo se procesa exactamente una vez.
   - Detección de ciclos (`L0014: ciclo de dependencias detectado: ...`).
   - Consolidación en orden topológico previa al análisis semántico (`sema::check`).
   - Preservación de procedencia de archivo en `Diagnostic` (`file: Option<String>`).
4. **Construcción Modular del Compilador Self-Hosted**:
   - `compiler-l/src/main.l` importa formalmente `lexer`, `tokens` y `cursor`.
   - `compiler-l/build-lexer.ps1` compila `src/main.l` directamente sin requerir concatenación de archivos.
5. **Verificación y Calidad**:
   - 348 pruebas aprobadas, cero fallos y 3 microbenchmarks manuales ignorados.
   - 11 pruebas nuevas (9 en `tests/modules.rs`, 2 en `tests/self_hosting.rs`).
   - Pruebas diferenciales idénticas en Cranelift y rustc.
   - `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios al 100%.
   - Benchmarks reproducibles con `bench/lexer-file.ps1` confirmando cero fugas de memoria (`allocs == frees`, `heap_ok=1`).

## 34. Self-hosting fase 4: Parser autónomo, AST tipado y análisis sintáctico en L (dev/self-hosting-parser)

Este incremento completa el analizador sintáctico completo escrito en Proyecto L:

1. **AST Tipado e Indexado en Arenas Continuas (`compiler-l/src/ast.l`)**:
   - Estructura `AstTree` con arenas respaldadas por `List<T>`: `expressions: List<AstExpr>`, `statements: List<AstStmt>`, `types: List<AstType>`, `declarations: List<AstDecl>`, `params: List<AstParam>`, `fields: List<AstField>`, `variants: List<AstVariant>`, `extra: List<Int>`, `errors: List<ParseError>`.
   - Identificadores enteros estables como referencias entre nodos para máxima localidad y cero punteros dispersos.
   - Buffer plano `extra: List<Int>` para argumentos, secuencias de bloques, listas literales y brazos de match.
   - Volcador canónico `astDumpCanonical` y resumen `astDumpSummary`.

2. **Modularización Estricta bajo la Regla CORE-1 (máximo 4096 tokens por archivo)**:
   - `compiler-l/src/parse_util.l`: utilidades léxicas, lookahead (`parserAtWord`, `parserAtSymbol`), expectativas (`parserNeedWord`, `parserNeedSymbol`) y accesos seguros a fin de spans (`cursorSpanEnd`, `cursorPrevEnd`).
   - `compiler-l/src/types.l`: tipos primitivos (`Int`, `Float`, `F32`, `Bool`, `Text`, `Unit`), referencias (`&T`, `&mut T`), arrays (`[T; N]`), slices (`[T]`) y genéricos nombrados (`List<T>`).
   - `compiler-l/src/expr.l`: parser de precedencia Pratt (`parseExpr`) de 9 niveles, primary expressions, llamadas con argumentos nombrados (`Name(k: v)`), métodos encadenados, indexación (`a[i]`) y operadores unarios/binarios.
   - `compiler-l/src/stmt.l`: bloques (`parseBlock`), `let`, `var`, `const`, asignaciones (`=`, `+=`), `if-else`, `while`, `for`, `loop`, `break`, `continue`, `region` y `match`.
   - `compiler-l/src/decl.l`: declaraciones de nivel superior (`fn`, `pub fn`, `async fn`, `struct`, `enum`, `import`, `const`).
   - `compiler-l/src/parser.l`: orquestador `parseProgram` y sincronización ante fallos (`parserSynchronize`).
   - `compiler-l/src/main_parser.l`: driver CLI del compilador `parser-l`.

3. **Recuperación Robusta de Errores y Seguridad de Memoria**:
   - Detección de estancamiento del cursor (`cursor.pos == before_pos`) en bucles de sentencias y bloques para garantizar avance y evitar bucles infinitos.
   - Funciones `astExprEnd`, `astStmtEnd`, `astTypeEnd` y `cursorPrevEnd` que evitan la evaluación ansiosa fuera de rango de `selectInt`.
   - Sincronización hasta delimitadores naturales (`;`, `}`) y palabras clave de nivel superior.

4. **Driver Nativo Autónomo (`build-parser.ps1`)**:
   - Generación de binario ejecutable con Cranelift: `target/compiler-l/target/cranelift/x86_64-pc-windows-gnu/main_parser.exe`.
   - Salida estructurada de resumen y diagnóstico sintáctico preciso con línea y columna.
   - Verificación con `--trace-alloc`: balance perfecto `allocs == frees`, cero fugas y `heap_ok=1`.

5. **Verificación y Calidad**:
   - 356 pruebas aprobadas en la suite, 0 fallos y 3 microbenchmarks ignorados.
   - 8 pruebas nuevas de integración en `crates/l/tests/parser_l.rs` cubriendo declaraciones, expresiones y precedencia, control de flujo, pattern matching, todos los 12 archivos fuentes del compilador self-hosted, diagnósticos negativos, trace de memoria diferencial y paridad contra Stage 0.

## 35. Self-hosting fase 5: Análisis semántico, resolución de nombres, sistema de tipos y Adaptive Ownership en L (dev/self-hosting-semantics)

Este incremento completa el analizador semántico autónomo implementado íntegramente en Proyecto L:

1. **Sistema de Tipos Semánticos y Constructores Deduplicados (`compiler-l/src/sema_types.l`)**:
   - `SemTypeKind`: tipos primitivos (`Unknown`, `Int`, `Float`, `F32`, `Bool`, `Text`, `Unit`, `Error`) y compuestos nominales y algebraicos (`Struct`, `Enum`, `Ref`, `MutRef`, `Array`, `Slice`, `List`, `Option`, `Result`).
   - Arena indexada `TypeTable` con tipos base preinicializados en posiciones 0 a 7.
   - Constructores unificados: `semTypeMakeRef`, `semTypeMakeList`, `semTypeMakeArray`, `semTypeMakeSlice`.
   - Predicados formales de categorías de tipos: `semTypeIsNumeric`, `semTypeIsCopy`, `semTypeIsMove` mediante préstamos inmutables (`&SemTypeKind`) para garantizar seguridad de ownership en Proyecto L.
   - Algoritmo de equivalencia estructural recursivo `semTypeEquals` y formateador textual `semTypeName`.

2. **Tabla de Símbolos y Resolución Jerárquica de Ámbitos (`compiler-l/src/symbols.l`, `compiler-l/src/scopes.l`)**:
   - Símbolos en arena plana `SymbolTable` indexada por enteros (`Int`): `SymbolKind` (`Var`, `Param`, `Func`, `Struct`, `Enum`, `Variant`, `Field`, `Const`).
   - Registro de tipo resuelto, ámbito creador (`scope_id`), flags de mutabilidad (`is_mut`) y visibilidad (`is_pub`), y span en el código fuente.
   - Comparación de identificadores de cero asignaciones `symbolNamesEqual`.
   - Árbol jerárquico de ámbitos `ScopeTree`:
     - `scopeLookupCurrent`: detección inmediata de identificadores duplicados en el mismo ámbito léxico (`error[L0002]`).
     - `scopeLookupAll`: resolución ascendente hacia los ámbitos ancestros (padre, abuelo, global) que implementa naturalmente el sombreado léxico (*shadowing*) determinista.

3. **Modelo de Adaptive Ownership Autónomo (`compiler-l/src/ownership_l.l`)**:
   - Seguimiento por símbolo con estados discretos: `0 = Uninitialized`, `1 = Available`, `2 = Moved`.
   - `ownershipMarkAvailable`, `ownershipMarkMoved`, `ownershipIsMoved`.
   - Operación de unión conservadora en bifurcaciones `ownershipMergeBranches` (`if-else`): si un valor se consume en cualquiera de las ramas, queda marcado como movido tras el punto de unión.

4. **Inferencia y Comprobador Estático en Dos Pasadas (`compiler-l/src/sema_context.l`, `compiler-l/src/sema_expr.l`, `compiler-l/src/sema_stmt.l`, `compiler-l/src/sema.l`)**:
   - Contexto de análisis `SemaContext` y diagnósticos estructurados `SemaError`.
   - Resolución de tipos sintácticos a semánticos `semaResolveAstType`, mapeando nombres a Structs/Enums conocidos.
   - **Pasada 1 (`semaCollectDeclarations`)**: Registra todas las funciones, estructuras, enumeraciones y constantes a nivel superior en el ámbito global, detectando nombres duplicados antes de inspeccionar cuerpos.
   - **Pasada 2 (`semaCheckDeclarations`)**:
     - Empuja el ámbito léxico de la función e inserta parámetros formales como símbolos disponibles.
     - Comprobación de sentencias (`semaCheckStmt`): `let` y `var` con validación de tipo explícito vs inferido, asignaciones (`=`) con verificación de mutabilidad (`error[L0006]: no se puede reasignar a variable inmutable`), validación de expresiones en sentencias `return` contra el tipo de retorno de la función, condiciones en `if`/`while` (restringidas a `Bool`), rangos en `for` (restringidos a `Int`) y bloques (`AstStmtKind.Block`).
     - Comprobación de expresiones (`semaCheckExpr`): literales, variables, rechazo de uso posterior a movimiento (`error[L0005]: uso de valor movido`), operadores binarios aritméticos, relacionales y lógicos, llamadas a funciones y constructores (`AstExprKind.Call`) con verificación estricta de aridad y tipos de argumentos (`error[L0004]`), y transición de ownership a `Moved` para argumentos por valor de tipos no Copy.
     - Acceso a campos de structs (`AstExprKind.Field`) y argumentos nombrados (`AstExprKind.Named`).

5. **Driver Nativo Autónomo (`compiler-l/build-sema.ps1`, `compiler-l/src/main_sema.l`)**:
   - Generación de ejecutable nativo Cranelift: `target/compiler-l/target/cranelift/x86_64-pc-windows-gnu/main_sema.exe`.
   - Salida formateada con ubicación exacta (`archivo:línea:columna: error[CÓDIGO]: mensaje`) y línea canónica:
     `SemaSummary symbols=N scopes=M types=K errors=E`.
   - Verificación con `--trace-alloc`: `allocs == frees`, cero fugas y `heap_ok=1`.

6. **Verificación y Calidad**:
   - 368 pruebas aprobadas en la suite, 0 fallos y 3 microbenchmarks ignorados.
   - 12 pruebas nuevas de integración en `crates/l/tests/sema_l.rs` cubriendo:
     - Pruebas positivas: declaraciones y ámbitos, expresiones y aritmética, y movimientos válidos de ownership.
     - Pruebas negativas con códigos canónicos verificados: `L0001` (identificador no declarado), `L0002` (declaración duplicada), `L0003` (discrepancia de tipo en asignación), `L0004` (desajuste de aridad y de tipo en llamada), `L0005` (uso tras movimiento), `L0006` (reasignación a variable inmutable).
     - Prueba diferencial de paridad contra Stage 0 (`project_l::sema::check`).
     - Prueba de balance y seguridad de memoria con `--trace-alloc`.
   - Las 21 fuentes de `compiler-l/src/` cumplen rigurosamente el presupuesto de tokens `CORE-1` (todos bajo 18 KiB / 380 líneas).
   - `cargo fmt --check` y `cargo clippy --all-targets -- -D warnings` limpios al 100%.


## 36. Self-hosting fase 6

Stage 1 tiene CFG de ownership en L. Comprueba inicialización
definitiva, movimientos, campos anidados y reinicialización con
punto fijo en bifurcaciones y bucles. Los diagnósticos citan la
posición del evento inválido. Stage 0 sigue como bootstrap y
oráculo externo de pruebas.

La fase 6 entrega el incremento de CFG y movimientos. Aún quedan
préstamos, lifetimes y elaboración de drops. Las operaciones fuera
del subconjunto se rechazan. [Cobertura, comparación y mediciones](STAGE1_CFG.md).

Suite completa con 373 pruebas aprobadas, cero fallos y tres
microbenchmarks ignorados. Formato y Clippy pasaron.

## 37. Self-hosting fase 6.2: borrow checker de Stage 1

Stage 1 verifica en L préstamos compartidos y mutables, exclusividad,
liveness no léxica, campos disjuntos, représtamos, procedencia y
retornos prestados sobre su CFG. El binario Cranelift decide sin
Stage 0; las pruebas lo comparan con Stage 0 en 181 programas (168
idénticos, 7 rechazos con otro código, 6 rechazos más estrictos y
ninguna aceptación que Stage 0 rechace). Queda el plan de drops.
[Diseño, paridad y mediciones](STAGE1_BORROW_CHECKER.md).

Suite completa con 376 pruebas aprobadas, cero fallos y tres
microbenchmarks ignorados. Formato y Clippy pasaron.

## 38. Self-hosting fase 6.3: elaboración de drops de Stage 1

Stage 1 produce en L un plan de drops por función. El plan se construye
por arista del CFG, respeta el orden de Stage 0 y usa flags dinámicos
para valores quizá movidos. Cubre movimientos completos y parciales,
reasignaciones, escritura a través de `&mut`, temporales, bucles,
`break`, `continue` y retornos anticipados. Un verificador independiente
lo comprueba y las pruebas lo ejecutan camino a camino contra el CFG
elaborado por Stage 0. Stage 1 aún no genera código para esos drops.
[Modelo, pruebas y mediciones](STAGE1_DROP_ELABORATION.md).

Suite completa con 382 pruebas aprobadas, cero fallos y tres
microbenchmarks ignorados. Formato y Clippy pasaron.

## 39. Nombre oficial: ELE

El lenguaje se llama ELE; la extensión sigue siendo `.l`. La ayuda de la
CLI y los mensajes de runtime de ambos backends usan el nuevo nombre.
Los nombres internos (`project-l`, `l`, `compiler-l`) no cambian.
Ver [DECISIONS.md](DECISIONS.md#nombre-del-lenguaje).

## 40. Self-hosting fase 7: LIR de ELE y primeros ejecutables de Stage 1

Stage 1 baja su subconjunto a una LIR tipada escrita en ELE, intercala el
plan de drops, la verifica y la serializa (`ELE-LIR 1`). El backend
provisional (`l build-lir` / `l run-lir`) la compila con Cranelift sin
ejecutar el frontend Rust. Los ejecutables coinciden con Stage 0 en 35
programas y en 116 programas de los corpus de préstamos y drops.
[Diseño](STAGE1_LIR.md), [protocolo](LIR_PROTOCOL.md).

Suite completa: 389 aprobadas, 0 fallos, 3 ignoradas (382 previas + 6 de lir_l.rs + 1 de List<T> en sema_l.rs). Formato y Clippy pasaron.

## 41. Fase 8.2: recuperación y autocobertura

El trabajo interrumpido de Antigravity se preservó en `dev/ele-self-hosting-bootstrap`. La corrida inicial MSVC encontró una prueba con expectativa obsoleta para indexación; se corrigió y se añadieron pruebas de firmas de métodos, índices, constantes negativas, overflow y `Text.byteLength` proyectado. `cargo fmt --check` y Clippy MSVC pasan. La corrida final de ejecutables: **393 aprobadas, 0 fallos, 3 ignoradas**; doctests MSVC: 0/0. [Comandos y límite del entorno](AGENT_HANDOFF.md#41-recuperación-de-antigravity-y-fase-82-10-11-2026).

De 40 fuentes `.l`, nueve pasan análisis semántico y ownership de Stage 1, ninguna fuente propia probada genera LIR completa y no existe Stage 2. Listas, imports entre módulos, `match`, Option/Result y enums siguen parciales. El backend provisional permanece en Rust/Cranelift. [Resultados por módulo](STAGE1_SELF_COVERAGE.md).

## 42. Self-hosting fase 8.3

`List<T>` ya tiene ruta Stage 1 → LIR → backend provisional para los casos probados, y `flow_cfg.l` produce código nativo ejecutado con paridad Stage 0. Véase [PHASE_8_3.md](PHASE_8_3.md).

Suite final MSVC: 398 aprobadas, 0 fallos, 3 ignoradas y 0 doctests; formato y Clippy correctos. No se declara Stage 2.

## 43. Self-hosting fase 8.4: recuperación y verificación

La fase 8.3 de Codex quedó sin confirmar; se conservó y verificó antes de crear commits locales. Suite MSVC: 398 aprobadas, 0 fallos, 3 ignoradas, 0 doctests; `cargo fmt --all --check` y Clippy `--all-targets -- -D warnings` limpios. La ruta vertical `flow_cfg.l::flowNew`/`flowBlock` se revalidó con la prueba `compiles_real_flow_cfg_functions_natively`.

`List<T>` cubre: literal (`List[]` y `List[a, b]`), `push`, `reserve`, `length`, `capacity`, lectura por índice de elemento Copy, escritura de elemento Copy, iteración, retorno, campo de struct y `List<FlowBlock>`. Quedan rechazados con diagnóstico (no bloquean la autocobertura parcial): `pop`, mover un elemento propietario fuera de la colección (`L0005`) y reemplazar un elemento propietario (`L0016`). Sin Stage 2. [Evidencia](PHASE_8_3.md).

## 44. Backend nativo ELE — incremento 8.7.2 (pendiente de verificación MSVC)

Se incorporaron un parser/verificador ELE-LIR 1 para Int/Bool con múltiples
funciones y CFG, una ABI interna de hasta 2 argumentos y generación x86-64
con frames, saltos relativos y llamadas, íntegramente en archivos `.l`.
Hay pruebas de integración Rust preparadas, **no ejecutadas aquí**.
La suite auxiliar Python: 20/20; desensamblado y programa de referencia
externos no prueban que el emisor ELE compile. Sin Stage 2 ni Stage 3.
Véase [`ELE_NATIVE_BACKEND_PHASE_8_7_2.md`](ELE_NATIVE_BACKEND_PHASE_8_7_2.md).


## Actualización del backend ELE — 2026-11-10 (8.7.3 parcial)

El backend experimental ELE-LIR 1 → x86-64/ELF64, **separado del backend
Cranelift existente**, ahora incluye un camino de structs anidadas move-only:
construir/usar/leer/escribir campos agregados con layout de tipo nominal.
Las pruebas de herramientas (28) pasan, **pero no prueban compilación `.l`**;
las nuevas pruebas MSVC/Stage1 están pendientes. Sin ownership heap/drops,
enums, runtime autónomo, PE64 ni Stage2. Detalles en
`docs/ELE_8_7_3_NESTED_MOVE.md`.


## 2026-11-10 — 8.7.4 inicio: enums tagged (sin ejecución Stage 0)

El backend nativo ELE (`native_cfg_ir/verify/emit.l`) incorpora parseo provisional
de `enums` de ELE-LIR 1, variantes unitarias o con un payload primitivo
`Int`/`Bool`, discriminantes, movimientos de agregado y rechazo de
payloads propietarios. No representa `Option`/`Result`/`match` completos,
ni la extracción de payload, ni la semántica completa del operador `?`.
El entorno carece de Cargo; ver `docs/ELE_NATIVE_BACKEND_PHASE_8_7_4.md`
para resultados comprobados y validación Windows pendiente.

### Complemento fase 8.7.4.1 (solo fuentes, no verificado con Stage 0)

El backend nativo experimental admite ahora `i payload vD pN eK V` para copiar un payload `Int`/`Bool` **solo si el discriminante coincide en tiempo de ejecución**. El fallo controlado sale con código 126 en ELF64 Linux. No es una operación estandarizada de ELE-LIR 1 ni está integrada en Stage 1; no constituye soporte nativo completo de `Option`/`Result`/`match`. Las pruebas nativas de integración requieren Cargo/MSVC, no disponible en el entorno de implementación. Ver `docs/ELE_NATIVE_BACKEND_PHASE_8_7_4_1.md`.

## Fase 8.7.4.2 (incremento parcial, 2026-11-10)

- **Código implementado, pendiente de Cargo/MSVC:** operación `payload`
  interoperable (solo Int/Bool Copy), comprobación de discriminante en
  backend Cranelift, inicialización de almacenamiento de enums, tabla nominal
  de enums unitarios y emisión `variant`/`disc` en Stage 1.
- **Verificación local:** `python3 -m unittest discover -s tests/native_backend`
  — 34 pruebas de herramientas y contratos aprobadas. No es una verificación
  de compilación de ELE.
- **Pendiente:** integración real de variantes con payload en Stage 1,
  Option/Result y `match` con bindings, drops propietarios y Stage 2.
- **Próximo paso:** ejecutar `bench/verify-enum-lir-interop.ps1` y reparar
  regresiones observadas antes de ampliar el frontend.

## Fase 8.7.7 — referencias y consultas de Text en el backend ELE (2026-11-11)

- **Implementado y ejecutado:** parámetros `view`/`edit` de Int, Bool,
  Text, `shape` anidado y `choice`; lectura, escritura, `print`, `append`,
  `disc` y `payload` a través de ellos; `Text.byteLength`; `Text.byteAt`
  con comprobación de límites (salida 127); `unary` `neg`/`not`; `div` y
  `rem` con la misma trampa que Stage 0 (salida 125).
- **Verificación:** `native_refs_l` 4/4 en Windows (aceptación, 16
  rechazos, imágenes); las 12 imágenes se ejecutaron en Linux x86-64 (WSL)
  con salida idéntica a Stage 0. Suites nativas previas sin regresión.
- **Pendiente:** préstamos locales, Text en agregados, agregados por valor
  en llamadas y retornos, `List of[T]`, comparación directa de Text.
  Ver [ELE_NATIVE_BACKEND_PHASE_8_7_7.md](ELE_NATIVE_BACKEND_PHASE_8_7_7.md).

## Fase 8.7.8 — agregados por valor en el backend ELE (2026-11-11)

`shape`/`choice` por valor en llamadas y retornos, y movimientos parciales
con seguimiento por camino. Verificado: `native_aggregates_l` 3/3 y suites
nativas previas sin regresión; ejecución Linux idéntica a Stage 0. Ver
[ELE_NATIVE_BACKEND_PHASE_8_7_8.md](ELE_NATIVE_BACKEND_PHASE_8_7_8.md).

## Fase 8.7.9 — Text dentro de `shape` en el backend ELE (2026-11-11)

Campos Text con movimiento, liberación por campo y reemplazo por `edit`.
Verificado: `native_text_fields_l` 3/3; ejecución Linux idéntica a Stage 0 y
reservas equilibradas. Ver [ELE_NATIVE_BACKEND_PHASE_8_7_9.md](ELE_NATIVE_BACKEND_PHASE_8_7_9.md).

## Fase 8.7.10 — shapes de más de cuatro campos (pendiente de CI)

i struct utiliza ahora tabla separada de operandos, con 1..64 campos
y máximo de 512 bytes por layout. El verificador recorre y consume
todos los operandos, preservando ownership. Añade pruebas de 6/17/64
campos y rechazos. Sin soporte completo de List, préstamos locales,
Stage 2, Stage 3 ni PE64. No declarar el compilador completo.


### Ejemplos ELE v2 (migración de superficie, pendiente de CI)

Rama `chore/examples-ele-v2-canonical`: 25 archivos de `examples/`
convertidos desde la sintaxis histórica de Rust a ELE v2, incluidos los
casos negativos; los otros 15 ejemplos `.l` ya eran canónicos. Los 117
fixtures `.lir` se mantienen intactos. Se añadió una prueba que analiza
los 40 ejemplos, preserva los rechazos y comprueba la salida de varios
programas. Véase `docs/EXAMPLES_ELE_V2_MIGRATION.md`. Esta migración no
completa el compilador ni sustituye el self-hosting Stage 2/3.

Validación de la migración: GitHub Actions 43072044595 con tres trabajos
aprobados (Ubuntu, Windows y ELF64 cruzado). La suite total histórica
de Stage 0 no se declara íntegramente corregida por esta migración.
