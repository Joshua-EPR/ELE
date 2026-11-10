# LIR de ELE en Stage 1

La fase 7 añade a Stage 1 una LIR tipada escrita en ELE. El lowering
parte del AST verificado, reutiliza el CFG, los move paths y el plan de
drops, verifica el resultado y lo serializa con el
[protocolo LIR versión 1](LIR_PROTOCOL.md). Un backend provisional en Rust
(`l build-lir`, `l run-lir`) lo compila con Cranelift **sin ejecutar el
frontend Rust**. Así Stage 1 ya produce ejecutables nativos para su
subconjunto.

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo build --bin l
$sema = & ./compiler-l/build-sema.ps1
& $sema ./programa.l --emit-lir > programa.lir
./target/debug/l.exe run-lir programa.lir
cargo test --test lir_l
powershell -NoProfile -ExecutionPolicy Bypass -File bench/stage1-lir.ps1 -Runs 5
```

## Arquitectura

| Módulo (ELE) | Responsabilidad |
| --- | --- |
| `lir_build.l` | Arenas por función: variables, constantes, lugares, argumentos e instrucciones; tablas de módulo (firmas y structs). |
| `sema_lower.l` | Canal de valor de las expresiones y reglas de lectura, movimiento y argumentos. |
| `sema_ops.l` | Literales, nombres, operadores, campos, interpolación y llamadas, con su comprobación de tipos. Se separó de `sema_expr.l` por el límite CORE-1. |
| `stmt_lower.l` | `let`, asignaciones, condiciones, `return` y `for`. |
| `lir_finish.l` | Intercala el plan de drops, crea las variables de flag y los terminadores. |
| `lir_verify.l` | Verificador independiente de la LIR. |
| `lir_emit.l`, `lir_write.l` | Serialización, decodificación de escapes y posiciones `@línea:col`. |
| `lir_module.l` | Tablas de módulo, cabecera, cierre de cada función y prueba de fallos. |

| Rust | Responsabilidad |
| --- | --- |
| `lir_protocol.rs` | Parser defensivo del protocolo y validación con `cfg::verify` y `drops::verify`. |
| `main.rs` | Comandos `build-lir` y `run-lir`: protocolo, validación, Cranelift y enlazado. |

El lowering se hace en el mismo recorrido que el análisis semántico: no
existe un segundo recorrido del AST ni otro CFG. Cada instrucción se emite
en el bloque CFG actual y guarda `pos`, el número de eventos de ownership
ya emitidos. Ese ancla permite insertar después cada operación del plan de
drops exactamente donde ocurrió su evento.

## Modelo

- **Función**: variables tipadas no SSA (`val` o `ref`, como `VarTy` de
  Stage 0; las primeras son los parámetros), bloques con instrucciones y
  un terminador.
- **Tipos**: Int, Bool, Text, Unit y structs; Float solo si llega por una
  firma, porque Stage 1 no tiene literales flotantes. Se usan los ids
  semánticos de Stage 1, sin reglas nuevas de coerción.
- **Operandos**: variable o constante.
- **Lugares**: variable más proyecciones de campo. Si la raíz es una
  referencia, el lugar denota el referente.
- **Instrucciones**: `use`, `unary`, `binary`, `call`, `struct`, `read`,
  `loan`, `textbuf`, `append`, `store`, `print`, `drop` y `dropfield`.
- **Terminadores**: `jump`, `branch`, `return`, `returnref` y
  `unreachable`.

Las variables no son SSA: una variable puede asignarse en varios bloques,
como en la LIR de bloques de Stage 0. Cranelift construye SSA con
`def_var`/`use_var`. La regla def-use es la **asignación definida**: toda
variable usada debe estar asignada en todos los caminos que llegan al uso.
El verificador la comprueba con un dataflow propio.

## Lowering

Cada expresión deja su resultado en el canal de valor: un lugar
(variable, campo o referente) o un operando. Los consumidores siguen las
convenciones de la LIR de Stage 0:

| Consumidor | Regla |
| --- | --- |
| Operando (aritmética, argumento por valor, `let`, `return`, constructor) | Lee con `read` un lugar Copy o proyectado; mueve una variable propia (`use`). |
| `print` e interpolación | Un `Text` en un lugar se pasa por referencia (`ref`, sin mover); el resto por valor. |
| Argumento `&T` / `&mut T` | `ref <lugar> <mut>` sobre el lugar prestado, implícito o explícito. |
| `let r = &x` o `return &x` | `loan` en una variable `ref`. |
| Llamada con resultado prestado | Variable `ref` del tipo apuntado. |

| Construcción | Lowering |
| --- | --- |
| `a && b` / `a \|\| b` | Una variable resultado guarda `a`; el bloque salta al de `b` (orden invertido para `\|\|`). |
| Interpolación | `textbuf` seguido de un `append` por parte; los segmentos vacíos desaparecen. |
| Asignación | `use` para una variable propia; `store` para campos y referentes. Las compuestas leen, operan y escriben. |
| `for i in a..b` | Contador y límite se evalúan una vez. La cabecera compara, el cuerpo liga `i` y un bloque de incremento propio es también el destino de `continue`. |
| Constantes globales | Se sustituyen por su literal. |

El bloque de incremento de `for` es un cambio en el CFG de Stage 1.
Antes, `continue` saltaba directamente a la cabecera y no había ningún
sitio donde incrementar.

## Drops y ownership

`lir_finish.l` consume el `DropPlan` de la fase 6.3 sin recalcularlo:

| Operación del plan | Lowering |
| --- | --- |
| `drop` | `drop v` (raíz) o `dropfield` (campo). |
| `cdrop` | Lo mismo, con su variable de flag. |
| `set` / `clear` | `use v<flag> cb1` / `use v<flag> cb0`; cada flag es una variable `Bool`. |
| `ref` | `dropfield` a través de la referencia; en la raíz, nada, porque el `store` del backend suelta el referente anterior (ABI de Stage 0). |

Una operación anclada antes del evento `e` va antes de la primera
instrucción emitida después de `e`. Una anclada después de `e` va antes de
la primera emitida después de `e + 1`. Así quedan en su sitio los drops
de reasignación (después de evaluar el valor nuevo y antes de escribir),
los de fin de ámbito y retorno (antes del terminador) y las
actualizaciones de flags. El valor retornado se mueve en el terminador.
Los temporales tienen su propia variable. Los movimientos completos y
parciales y las reinicializaciones son los del solver de ownership; el
lowering no los recalcula.

El backend vuelve a comprobar el ownership de la LIR recibida con
`drops::verify` de Stage 0: sin uso tras movimiento, sin doble liberación,
sin fuga al retornar y sin sobrescritura de un valor propio.

## Verificador

`lir_verify.l` no confía en el lowering. Comprueba cada id antes de
usarlo, recorre las cadenas de lugares con límite de pasos y aplica estas
reglas (fallo = `error[ICE]`, distinto de los diagnósticos de usuario):

| Regla | Defecto |
| ---: | --- |
| 1 | id de variable, constante, lugar, argumento o función fuera de rango |
| 2 | bloque fuera de rango o rama sin condición |
| 3 | tipo de operando o de resultado incompatible |
| 4 | llamada que no coincide con la firma (aridad, modo o tipo) |
| 5 | uso de una variable no asignada en todos los caminos |
| 6 | drop de un valor no propio o flag que no es `Bool` |
| 7 | retorno incompatible con el resultado |
| 8 | proyección sobre un no-struct o campo inexistente |
| 9 | instrucción listada en un bloque ajeno |

`sema-l archivo.l --lir-fault=K` corrompe una función verificada de 8
maneras para comprobar que cada regla se dispara.

## Backend provisional

`l build-lir archivo.lir` parsea el protocolo de forma defensiva, valida
la LIR y la propiedad, comprueba el subconjunto nativo, genera el objeto
con Cranelift y enlaza. `l run-lir` además lo ejecuta. El backend sigue en
Rust; el frontend, la semántica, el ownership, los drops y el lowering son
de Stage 1.

## Pruebas

`crates/l/tests/lir_l.rs` usa el binario Stage 1 con `PATH` vacío:

- **Diferencial de ejecución.** 35 programas compilados desde la LIR de
  Stage 1 producen la misma salida estándar, el mismo código de salida y
  el mismo stderr que Stage 0, con heap equilibrado en ambos. Cubren
  función vacía, retorno Int, aritmética, comparaciones, variables,
  asignaciones compuestas, `if`/`else`, `while`, `for` con `continue`,
  bucles anidados con `break`, `loop`, llamadas, recursión, retornos
  anticipados con drops, cortocircuito con efectos, `Text` con escapes y
  Unicode, interpolación, movimientos, reasignaciones, drops
  condicionales, movimientos parciales anidados, structs, referencias
  compartidas y mutables, escritura a través de `&mut`, retornos
  prestados, préstamos implícitos, temporales, constantes y código de
  salida.
- **Corpus.** 116 programas aceptados del borrow checker y de drops
  se compilan desde la LIR, pasando por la validación de ownership del
  backend, y sus ejecutables se comparan con Stage 0. Los que usan listas
  se rechazan con `L0016`.
- **Negativos.** Ocho programas inválidos se rechazan con su diagnóstico
  de usuario y sin emitir LIR: tipos, uso tras movimiento, valor quizá
  movido, préstamo incompatible, retorno colgante, asignación inmutable,
  nombre desconocido y construcción fuera de la LIR v1.
- **Verificador.** Las 8 corrupciones se rechazan con su regla.
- **Protocolo.** Dieciséis variantes malformadas o inseguras se rechazan
  con diagnóstico y sin pánico: versión, truncado, contenido tras `end`,
  instrucción desconocida, ids fuera de rango, overflow, bytes y UTF-8
  inválidos, campo inexistente, cantidad excesiva, separadores, tipo
  incompatible, doble drop y fuga.
- **Determinismo.** Dos emisiones del mismo programa son idénticas y se
  analizan y validan.

## Mediciones

Windows x86-64, driver Cranelift con traza, cinco ejecuciones tras una de
calentamiento (`bench/stage1-lir.ps1`). Las funciones combinan ramas,
bucles `for`, llamadas, `Text` propios (algunos quizá movidos, con flag),
campos de struct y retornos anticipados.

- `check` es `--check-ownership`: frontend, ownership, préstamos, plan de
  drops y el lowering durante el recorrido semántico.
- `emit` es `--emit-lir`: lo mismo, más intercalar drops, verificar y
  serializar.

La diferencia estima el coste de cerrar la LIR. El lowering dentro del
recorrido no se aísla porque ELE aún no tiene reloj.

| Instrucciones LIR | Funciones | Bloques | Drops | Flags | Bytes LIR | check ms | emit ms | Pico KiB (emit) | Reservas / liberaciones |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 244 | 1 | 82 | 41 | 10 | 10 491 | 40,94 | 46,31 | 3 344 | 2 070 / 2 070 |
| 3 763 | 1 | 748 | 1 301 | 100 | 143 089 | 517,54 | 556,75 | 12 088 | 24 822 / 24 822 |
| 37 612 | 10 | 7 426 | 13 001 | 1 000 | 1 458 879 | 5 172,89 | 5 559,36 | 20 348 | 246 249 / 246 249 |

Cerrar la LIR cuesta entre un 7 y un 13 % del proceso. La mayor parte
del tiempo es el frontend existente: con cientos de bloques por función,
los análisis densos de ownership, préstamos y drops crecen con
bloques × rutas. Todas las cargas tuvieron `heap_ok=1`. No se ejecutaron
sanitizers: el entorno no los soporta para el código que genera
Cranelift, y el balance de heap no demuestra por sí solo la ausencia de
errores de memoria.

## Límites

- LIR v1: sin enums, listas, arrays, `Option`/`Result`/`?`, regiones ni
  async. Stage 1 los rechaza antes de emitir.
- Stage 1 todavía no puede analizar su propio código fuente (sección
  [brecha de self-hosting](SELF_HOSTING_GAP_ANALYSIS.md#stage-1-sobre-su-propio-código)).
- El backend sigue en Rust (Cranelift, enlazador y runtime generado).
- No se ejecutaron sanitizers sobre el código generado por Cranelift.

## Actualización de fase 8.2

Antigravity añadió instrucciones de listas, indexación, plataforma y enums al modelo y al parser de protocolo. Su semántica y verificación todavía son parciales: ninguna fuente real del compilador probada pasó `--emit-lir`. La prueba nativa nueva de `Text.byteLength` proyectado sí cierra la ruta Stage 1 → LIR → backend para ese caso concreto. El siguiente bloqueo real es `List[]` con tipo contextual; ver [STAGE1_SELF_COVERAGE.md](STAGE1_SELF_COVERAGE.md). Mantener `ELE-LIR 1` explícito hasta decidir una versión compatible para las extensiones.

## Ampliación de listas en fase 8.3

Stage 1 emite `listlit`, `listpush`, `listreserve`, `len`, `cap` y lugares indexados con tipos parametrizados; el verificador comprueba tipos y el backend genera código nativo. `flow_cfg.l` pasa la prueba vertical. [Detalle](PHASE_8_3.md).
