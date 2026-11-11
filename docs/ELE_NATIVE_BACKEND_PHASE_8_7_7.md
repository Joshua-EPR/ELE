# Fase 8.7.7 — Referencias `view`/`edit`, consultas de Text y aritmética comprobada en el backend ELE

Estado: **implementado; verificado en Windows (aceptación, rechazo e imagen)
y ejecutado en Linux x86-64 (WSL) con salida idéntica a Stage 0**
(2026-11-11). No cierra el compilador.

Ruta: `programa.l` → Stage 1 → ELE-LIR 1 → `codegen/native_cfg_*.l` →
x86-64 → ELF64. Stage 1 ya emitía estas formas; el backend nativo las
rechazaba.

| Elemento | Antes | Ahora |
|---|---|---|
| `var vN ref T` (parámetro) | rechazado | Int, Bool, Text, `shape` (incluso anidado) y `choice` |
| Argumento `ref <lugar> 0\|1` | rechazado | dirección del lugar (variable, campo o subcampo; reborrow de otra referencia) |
| Lugar `pN` sin proyección | rechazado | referente de una referencia |
| `i read` / `i store` a través de referencia | rechazado | primitivos y agregados sin recursos; `store` exige exclusividad |
| `i print ref` / `i append` sobre una referencia | rechazado | desreferencia; `append` a `edit Text` |
| `i disc` / `i payload` sobre una referencia a `choice` | rechazado | aceptado |
| `i len` (Text.byteLength) | rechazado | segunda palabra del Text |
| `i byteat` (Text.byteAt) | rechazado | comprobación sin signo `0 <= i < len`, si no salida 127 |
| `i unary neg\|not` | rechazado | `neg` con overflow (125); `not` Bool |
| `binary div\|rem` | rechazado | `IDIV` truncado hacia cero; divisor 0, `MIN / -1` y `MIN % -1` salen con 125 |

## Modelo de referencias (`codegen/native_cfg_ref.l`)

Sólido por construcción para este subconjunto:

- Una referencia solo existe como parámetro y ocupa una palabra (la
  dirección del referente) que el llamador apila.
- Nunca es un valor: no se copia, mueve, devuelve, almacena, asigna ni
  libera. Por eso ninguna referencia sobrevive a la llamada que la creó y el
  llamado nunca libera ni mueve el referente. No hay préstamos locales
  (`i loan`) ni `returnref`: se rechazan.
- ELE-LIR no registra si un parámetro es `view` o `edit`. El backend infiere
  que es exclusivo si la función escribe a través de él (`store`, `append`)
  o lo reenvía como `ref … 1`; todo llamador debe pasarlo con `ref … 1`.
  Stage 1 comprueba los modos declarados; el backend garantiza que el código
  emitido nunca escribe a través de una referencia compartida.
- En una llamada, una referencia exclusiva no puede solaparse con otro
  argumento, y un valor movido no puede solaparse con una referencia.
  Campos distintos del mismo `shape` no se solapan.
- Leer un `Text` a través de una referencia (moverlo fuera del préstamo) o
  sobrescribirlo se rechaza. Copiar un agregado a través de una referencia
  es seguro porque todos los agregados aceptados carecen de recursos; esta
  regla debe restringirse cuando existan campos propietarios.

Códigos nuevos de rechazo: 95 Text movido, sobrescrito o liberado a
través de referencia; 96 referencia fuera de los parámetros o como
destino; 97 consulta de Text mal tipada; 98 parámetro exclusivo recibe una
referencia compartida; 99 argumentos solapados.

## Convención de llamada

Sin cambios para valores. Un argumento `ref` empuja una palabra: la
dirección del lugar (`RBP` + desplazamiento, o el puntero de una referencia
recibida + desplazamiento). El llamado accede al referente cargando la
dirección en `R11` justo antes de cada acceso.

## Estados de salida

125 aritmética (overflow, división o resto por cero, `MIN / -1`,
`MIN % -1`, `-MIN`), igual que el error único de Stage 0; 127 índice fuera
de rango, emitido solo si el programa usa `byteAt`.

## Pruebas

`crates/l/tests/native_refs_l.rs` (4 pruebas):

- `examples/native_refs_stage1.l`, `native_text_query_stage1.l` y
  `native_arith_stage1.l`: LIR de Stage 1 con las formas nuevas y, en Linux,
  salida idéntica a `*.expected` (generados con `l run`, Stage 0).
- Ocho programas de trampa: 125 en división/resto por cero, `MIN / -1`,
  `MIN % -1` y `-MIN`; 127 en `byteAt(len)` y `byteAt(-1)`; 0 en el último
  índice válido. Solo se imprime lo anterior al fallo.
- `native_cfg_ref_store_ok.lir`: escritura por `edit`, sale con 7.
- 16 rechazos (`native_cfg_ref_*.lir`, `native_cfg_text_query_bad.lir`,
  `native_cfg_text_byteat_bool.lir`, `native_cfg_unary_bad.lir`,
  `native_cfg_call_ref_arg.lir`, que ahora rechaza con 54).

CI: `native_refs_l` se ejecuta en Ubuntu y Windows; las 12 imágenes
ELF construidas en Windows se ejecutan en Linux con su estado esperado.

## Límites reales

- Sin préstamos locales (`hold r = view x`), sin referencias devueltas ni
  almacenadas, sin `Text` dentro de `shape`/`choice`, sin `List`.
- Paso y retorno de `shape`/`choice` por valor siguen rechazados (68 / 45).
- Sin comparación directa de Text (`==` sobre Text); se escribe con
  `byteLength`/`byteAt`.
- Solo Linux ELF64.

## Línea base de la suite completa (Windows/MSVC, `main` `f19ec01`)

`cargo test -p project-l --no-fail-fast` sobre un worktree limpio de
`main`: **479 aprobadas, 15 fallidas, 3 ignoradas**, y `conformance` aborta
por desbordamiento de pila. Ninguna depende de Cranelift ni de MSVC (todas
corren en Windows); CI no ejecuta estos binarios. Clasificación:

| Binario | Fallas | Causa |
|---|---|---|
| `cfg` | 1 | recorre `differential/unsupported`, que nunca existió en git (corregido en la rama `fix/stage0-diagnostic-files-token-limit`) |
| `differential` | 1 | misma carpeta inexistente; un caso real requiere superar el límite de 4096 tokens (defecto 2 de Stage 0) |
| `references` | 7 | fuentes de prueba con identificadores que la sintaxis v2 reservó (`se esperaba identificador, no palabra reservada`) |
| `regions` | 1 | misma causa |
| `modules_l` | 4 | deriva entre Stage 1 (`modules_l.l`) y las pruebas: ciclos, import ausente, identidad nominal, privados homónimos |
| `self_hosting` | 1 | `tokenKindValue` ya no existe en las fuentes de Stage 1 |
| `conformance` | aborta | 200 paréntesis anidados desbordan la pila del hilo de prueba en debug antes del límite de anidamiento 128 |

La rama `fix/stage0-diagnostic-files-token-limit` corrige `cfg`,
`conformance`, `differential`, `references`, `regions` y `borrow_l`
([detalle](STAGE0_DEFECTS_DIAGNOSTICS_TOKENS.md)). El resto queda como trabajo pendiente
documentado; no se desactivó ninguna prueba.
