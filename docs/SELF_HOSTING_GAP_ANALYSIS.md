# Auditoría para self-hosting

Base auditada en `f0487fb`, descendiente de `48399cc`. La matriz de
capacidades refleja también el incremento de archivos y CLI. El workspace declara un
solo paquete, `project-l`, con biblioteca `project_l` y binario `l`.
Las líneas indicadas son aproximaciones del tamaño del archivo en la base.
Prioridades en orden de dependencia, con P0 para el primer ejecutable de
herramientas, P1 para un frontend completo y P2 para la primera recompilación.

## Inventario del compilador

| Componente | Módulo, interfaz y dependencias | Alcance y coste de migración |
| --- | --- | --- |
| CLI | `main.rs` (~216), `run`, usa `std::env`, `std::fs`, `Command` y ambos backends | Un archivo UTF-8, límite 256 KiB, emite AST/IR/CFG para inspección. El driver L usa argumentos, archivos y estados de salida de la API mínima. |
| Lexer | `lexer.rs` (~364), `lex(&str) -> Result<Vec<Token>, Diagnostic>` | ASCII para palabras, Unicode en espacios y texto, números, comentarios anidados, escapes e interpolación. P0, preservar posiciones y límites. |
| Parser | `parser.rs` (~1 618), `parse(Vec<Token>)`, Pratt, usa tokens, spans y `effects` | Subconjunto con precedencia y límites. P1, requiere secuencias, nodos indexados y diagnósticos. |
| AST | Tipos públicos `Expr`, `Stmt`, `Program` y declaraciones de `parser.rs` | Nodos recursivos con Box y Vec en Rust. P1, arena de nodos con índices como alternativa a Box. |
| Nombres | `sema.rs` (~6 340), tablas `Env` y scopes de `Body`, produce IDs | Completado en Proyecto L en `compiler-l/src/symbols.l` y `scopes.l`. Resolución jerárquica con enlaces a padre, sombreado y detección de duplicados en ámbito local. |
| Módulos | `parser::parse_inner` acepta cabecera `module` y solo `import std.io.print` | El parser reconoce `pub`, sin resolución entre archivos ni privacidad efectiva entre módulos. P1, conservar resolución absoluta de la especificación. |
| Tipos | `lir::Type`, tablas de `sema::Env`, `layout::Layouts` calcula representación | Completado en Proyecto L en `compiler-l/src/sema_types.l`. Arena de tipos con IDs base (0-7), constructores deduplicados para Ref, List, Array, Slice, equivalencia recursiva y predicados. |
| Inferencia | `sema::Body::expr` recibe tipo esperado, unifica casos concretos y resuelve firmas | Completado en Proyecto L en `compiler-l/src/sema_expr.l` y `sema_stmt.l`. Inferencia local, chequeo de operadores y validación de tipos contra firmas. |
| Análisis semántico | `sema::check`, consume AST, usa prelude, `consteval`, `exhaustive`, ownership y efectos | Completado en Proyecto L en `compiler-l/src/sema.l` (dos pasadas: recolección de declaraciones globales y comprobación de funciones). Emite diagnósticos canónicos L0001-L0006. |
| Ownership | `ownership.rs` en Stage 0, `ownership_l.l` en Stage 1 | Stage 1 verifica inicialización y movimientos completos y parciales en su CFG. |
| Borrow checker | `loans.rs` en Stage 0, `loans_check.l` y `sema_borrow.l` en Stage 1 | Stage 1 verifica préstamos, NLL, campos, représtamos y retornos prestados. Referencias en agregados siguen fuera del subconjunto. |
| Lifetimes | `sema.rs` modela firmas y vínculos, `loans.rs` valida propagación | Cobertura de préstamos y vistas documentada en el modelo de memoria, con restricciones para agregados. P2, requiere datos de flujo y tablas de ámbitos. |
| Escape | `loans::escape_summaries`, `ReturnOrigin`, `EscapeSummary`, procedencia interprocedimental | Contratos para retornos y proyecciones. P2, probar ciclos y correspondencia de parámetros antes de sustituir Stage 0. |
| CFG | `cfg.rs` en Stage 0, `flow_cfg.l` en Stage 1 | Stage 1 dispone de un CFG semántico con aristas, rutas de movimiento y plan de drops verificado. Pendientes lowering tipado y protocolo de backend. |
| LIR | `lir.rs` (~448), `Program`, `Function`, `ValueKind`, `Type` | Modelo estructurado para frontend y referencia. P1/P2, sus tipos internos no constituyen un formato persistente. |
| Verificador | `cfg::verify`, asignación definida y tipos, `drops::verify` para estados propietarios | Se ejecuta también para la ruta de referencia en `lower_to_cfg`. P2, ampliar cobertura antes de aceptar LIR externa. |
| Transformaciones | `consteval.rs` (~160), `async_desugar.rs` (~697), `async_state.rs` (~599), `drops.rs` (~721) | Constantes, ANF async, estado de suspensión y elaboración de drops. P1 para constantes, P2 para drops, async aplazable para el primer compilador síncrono. |
| Codegen y layout | `layout.rs` (~473), `native.rs` (~2 185), traducción de lugares, llamadas y sret a IR | Verificar layout, tags, alineación y ABI. P2, compartir mediante frontera de backend. |
| Cranelift | `native::check_supported` y `native::compile(&cfg::Module, Options)` | Emite objeto nativo mediante crates Cranelift, rechaza formas que el backend no soporta. P2, conservar esta ruta. |
| Referencia | `backend.rs` (~945), genera Rust desde LIR, `main.rs` invoca `rustc` | Camino predeterminado actual y oráculo diferencial. Se conserva durante bootstrap, P2. |
| Runtime | `native/runtime.rs` (~1 821), `native/timers.rs` (~483), y `backend/*_runtime.inc.rs` | Emite Win32, heap, UTF-8, scheduler y temporizadores. La referencia usa std de Rust. P2, separar servicios de plataforma de generación de IR. |
| Enlazado | `linker.rs` (~130), `find`, `link_with_libraries` | Windows x86-64 MSVC, `vswhere`, `link.exe`, SDK, overrides `L_LINKER` y `L_LIBPATH`. P2, conservar detección y diagnósticos. |
| Diagnósticos | `lib.rs` (~73), `Span`, `Diagnostic`, formato y archivo en `main.rs` | Línea/columna con clasificación y primer error. P0/P1, separar byte offset de columnas Unicode para mostrar diagnósticos. |
| Pruebas | `crates/l/tests`, pruebas de módulo y `bench` | Casos estáticos y ejecutables, comparación de canales/salida y trazas. Reutilizar como puerta de migración, sin depender del backend de referencia para la ruta habitual futura. |

## Dependencias

Clases A (bootstrap), B (backend), C (reemplazo con biblioteca L), D
(frontera nativa), E (transitoria) y F (pendiente para independencia).

| Dependencia | Clases y uso |
| --- | --- |
| Rust, Cargo y `rust-toolchain.toml` | A/E. Construyen y prueban Stage 0 y el backend provisional. `build.rs` prepara el objeto Win64 `no_std` para los programas que acceden a archivos o argumentos. |
| Rust std en el frontend y CLI | A/C. Vec, mapas, sets, String, Box, Cell, colecciones de camino, archivos, entorno y procesos. Algoritmos y colecciones pueden migrar a L. I/O, rutas nativas y procesos necesitan plataforma (D). |
| `rustc` invocado por `main.rs` | A/E/F. Se ejecuta en cada build del backend de referencia. Su runtime generado usa std de Rust, compilada en el ejecutable de referencia. |
| `cranelift-codegen`, `-frontend`, `-module`, `-object`, `-native` 0.137.1, `target-lexicon` 0.13.5 | B/D/F. Construcción de IR, ISA, módulos, objeto, selección de target. Son bibliotecas compiladas en `l.exe`; un build por Cranelift no inicia `rustc`. |
| Transitivas del backend | B/F. Ensamblador x64 y generadores Cranelift, regalloc2, object, gimli, colecciones hash, utilidades y metaprogramación. El árbol efectivo incluye dependencias de construcción; `Cargo.lock` incluye además ramas condicionales de otros targets. Reproducir con `cargo tree --locked -e normal,build --target x86_64-pc-windows-msvc`. |
| MSVC `link.exe` y SDK | B/D. Herramientas del host para producir PE, `kernel32.lib`, `mincore.lib` para temporizadores y `shell32.lib` para el objeto de plataforma. Las bibliotecas de importación se usan al enlazar. |
| Win32 en ejecutables nativos | D. Proceso, heap, stdout/stderr y reloj/espera si se usan. El runtime central se emite con Cranelift. El objeto opcional de archivos y argumentos está escrito en Rust `no_std` y comparte el allocator. |

El árbol normal y de build para MSVC clasifica las transitivas como B/F en
estos grupos. Se pueden reemplazar junto con el backend que las consume.

- Generación y soporte de Cranelift: `cranelift-assembler-x64`,
  `cranelift-assembler-x64-meta`, `cranelift-bforest`, `cranelift-bitset`,
  `cranelift-codegen-meta`, `cranelift-codegen-shared`, `cranelift-control`,
  `cranelift-entity`, `cranelift-isle` y `cranelift-srcgen`.
- Registros y objetos: `regalloc2`, `object`, `gimli`, `crc32fast` y
  `memchr`.
- Colecciones y utilidades: `allocator-api2`, `anyhow`, `arbitrary`,
  `bumpalo`, `cfg-if`, `equivalent`, `fnv`, `foldhash`, `hashbrown`
  (dos versiones), `heck`, `indexmap`, `libm`, `log`, `rustc-hash`,
  `smallvec` y `wasmtime-internal-core`.
- Otras entradas del lock fuera de este árbol efectivo, también B/F:
  `libc`, `mach2`, `proc-macro2`, `quote`, `serde`, `serde_core`,
  `serde_derive`, `stable_deref_trait`, `syn` y `unicode-ident`.

## Capacidades del lenguaje para herramientas

| Capacidad | Estado auditado y prioridad |
| --- | --- |
| Módulos, imports, múltiples archivos y visibilidad | Resolución de imports relativos, subdirectorios dot-notation, detección de ciclos L0014, deduplicación en diamante y orden topológico implementados en Stage 0. Privacidad granular de visibilidad aún no restrictiva. P1. |
| List, arrays y slices | Probados en el subconjunto, con restricciones de slices prestados, elementos y regiones. Suficientes para tokens y arenas indexadas. |
| HashMap y HashSet | Ausentes en L. P1 para interning y sema escalable, opcionales para el lexer inicial. |
| Tipos recursivos y árboles | Representación por ID y arenas indexadas con `List<T>` implementadas completamente en `compiler-l/src/ast.l` para el AST del parser autónomo. Nodos de tamaño constante con payload variable en `extra: List<Int>`. Recursión propietaria mediante Box y representación general ausentes. |
| Funciones genéricas y traits | Parciales y probados, monomorfización y dispatch estático. Adaptar el diseño a los contratos comprobados, sin asumir trait objects. |
| Texto y bytes | Parcial. Text es UTF-8 y puede ser propietario. Bytes regional admite `len/get/set`, sin una vista de Text en la base. El incremento habilita `.byteLength` y `.byteAt(Int)`. Byte/u8 y buffers binarios generales siguen pendientes. |
| Unicode | Text e interpolación UTF-8, escapes (\n, \t, \r, \", \\, \u{HEX}) e interpolación anidada con validación escalar completa en el lexer L. Sin iterador `.chars()` general en L. |
| Archivos, directorios y rutas | Lectura UTF-8 acotada y rutas Unicode probadas en el driver. Pendientes lectura binaria, escritura, enumeración y biblioteca de rutas. |
| Argumentos, entorno y salida | Argumentos Unicode, stderr y estado explícito de `main` síncrono probados. Pendientes acceso al entorno y lanzamiento de procesos. |
| Errores y diagnósticos | `Option`, `Result`, match y propagación probados en el subconjunto. `Diagnostic` del compilador Rust no está expuesto a programas L. P0 para códigos y posiciones del lexer, P1 para spans de fuentes. |
| Escritura binaria | Ausente en L. P2 para enviar LIR versionada y escribir artefactos. |
| Conversiones | Parcial, `Int`, `Float` y `f32` explícitos, falta familia completa de anchos y conversiones para formatos binarios. |
| Grafos, recursión e iteradores | Recursión de funciones y loops probados. Grafos construibles con índices y List. Iteración de rangos y colecciones parcial, sin infraestructura general de iteradores. |
| Memoria dinámica | Probada para Text, List, regiones y tareas con límites del subconjunto; sin GC obligatorio. Ownership y drops se preservan. |
| FFI, ABI, sistema operativo y enlazado | FFI de usuario y ABI C público ausentes. Win64 y llamadas de runtime internas probadas. P0 para servicios de plataforma y P2 para invocar backend y enlazador. |
| Async, GPU, Android, multihilo, I/O asíncrono | Opcionales para el bootstrap síncrono. |

## Drops

| Componente | Stage 0 | Stage 1 |
| --- | --- | --- |
| Elaboración | `drops::elaborate` sobre la LIR de bloques | `drops_plan.l` sobre el CFG semántico, con el mismo orden y flags |
| Verificación | `drops::verify` | `drops_verify.l`, independiente del solver |
| Ejecución | Backends rustc y Cranelift | Pendiente: Stage 1 no genera código |

## Stage 1 sobre su propio código

Medido el 2026-11-10 ejecutando `sema-l` sobre cada archivo de
`compiler-l/src` por separado. Los diagnósticos más frecuentes:

| Diagnóstico | Apariciones | Causa |
| --- | ---: | --- |
| campo desconocido o proyección no verificada | 598 | campos de tipos de otros módulos, `.length`, campos sobre índices |
| función no encontrada | 460 | funciones de módulos importados |
| expresión fuera del subconjunto | 441 | llamadas a métodos (`push`, `byteAt`), índices, `match` |
| tipo desconocido | 344 | tipos de módulos importados |
| comparaciones con tipos de error | 310 | consecuencia de lo anterior |
| import fuera del subconjunto semántico | 138 | imports entre módulos |
| destino de asignación no verificado | 112 | asignaciones a índices (`lista[i] = x`) |

`List<T>` en anotaciones ya se resuelve (fase 7). Para que Stage 1 se
analice a sí mismo faltan, por orden, imports con resolución entre
módulos, métodos de `List` y `Text`, índices, enums con `match`,
`Option`/`Result` y referencias a elementos. Después, la LIR deberá
representar esas construcciones.

## Verificación de fase 8.2

La tabla anterior es la línea base de fase 7, previa a la recuperación. El 10-11-2026 se repitió el barrido con los cambios de Antigravity: **9 de 40** fuentes pasan `--check-ownership`; ninguna de las fuentes propias probadas pasa `--emit-lir`. El primer bloqueo vertical es `List[]` con tipo contextual y lowering LIR. Los imports heredados concatenan fuentes y no resuelven visibilidad ni identidad de módulo; `tokens.l` y `cursor.l` aún fallan con tipos externos desconocidos. La [matriz de fase 8.2](STAGE1_SELF_COVERAGE.md#5-verificación-reproducible-de-fuentes-reales-10-11-2026) contiene archivos, resultados y prioridades.

## Actualización de fase 8.3

La ruta de `List[]`, `push`, `reserve`, `length`, `capacity` e índices está probada nativamente. `flow_cfg.l::flowNew` y `flowBlock` se ejecutan desde LIR de Stage 1. Persisten imports semánticos, `Option`/`Result`, `pop`, enums y `match`. [Evidencia](PHASE_8_3.md).
