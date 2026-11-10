# Elaboración de drops de Stage 1

La fase 6.3 calcula en L qué recursos posee cada función y en qué punto
del CFG se destruyen. `sema-l archivo.l --check-ownership` construye y
verifica el plan de drops de cada función; `--drop-plan` además lo
imprime. Stage 0 compila el ejecutable y sirve de oráculo en las pruebas;
no participa en la decisión. **Stage 1 todavía no genera código**: el
plan es una representación intermedia lista para la LIR de la fase 7, no
drops ejecutados en binarios producidos por Stage 1.

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo build --bin l
$sema = & ./compiler-l/build-sema.ps1
& $sema ./archivo.l --drop-plan
cargo test --test drops_l
powershell -NoProfile -ExecutionPolicy Bypass -File bench/stage1-drops.ps1 -Runs 5
```

## Arquitectura

| Módulo | Responsabilidad |
| --- | --- |
| `flow_cfg.l` | Eventos `FLOW_DROP` (fin de vida léxica) y `FLOW_DROP_REF` (escritura a través de `&mut`); por ruta, `drop_types` (hoja propietaria) y `origins` (origen para diagnósticos); estados de entrada conservados. |
| `ownership_l.l` | El solver existente aplica `FLOW_DROP` (subárbol sin inicializar) y guarda `entry`/`reached` al converger. |
| `sema_drop.l` | `needs_drop` por tipo, materialización de hojas, ámbitos, `return`/`break`/`continue` y temporales. |
| `drops_plan.l` | Construye el `DropPlan` a partir de los eventos y los estados del solver. |
| `drops_verify.l` | Verificador independiente del plan e inyección de fallos para pruebas. |
| `drops_dump.l` | Forma textual determinista del plan (`--drop-plan`). |
| `loans_check.l` | Trata `FLOW_DROP` como escritura del propietario: destruir un valor prestado vivo es un conflicto `L0012`. |

No hay un CFG ni un seguimiento de movimientos paralelo: los drops son
eventos del mismo grafo y sus estados son los del solver de ownership.
El plan no depende de Cranelift ni de ningún backend.

## Modelo

**Recursos.** Un tipo necesita drop (como `Ownership::needs_drop` de
Stage 0) si es `Text`, `List`, un array de elementos que lo necesitan, un
enum con algún payload que lo necesita o un struct con algún campo que lo
necesita. Las referencias nunca poseen su referente.

**Hojas.** Al declarar un binding propietario (parámetro por valor, `let`
o temporal) se crea una ruta por hoja: los campos de struct que necesitan
drop se materializan recursivamente en orden de declaración y las hojas
(`Text`, `List`, arrays, enums) son atómicas. Los movimientos, escrituras
y drops actúan así sobre las mismas celdas del solver.

**Eventos.**

- `FLOW_INIT`: declaración, parámetro o temporal.
- `FLOW_WRITE`: reasignación de una variable o un campo.
- `FLOW_MOVE`: transferencia por valor.
- `FLOW_DROP`: fin de la vida léxica de un binding o temporal.
- `FLOW_DROP_REF`: escritura a través de `&mut` (se suelta el referente anterior).

**Plan** (`DropPlan`):

| Campo | Contenido |
| --- | --- |
| `ops` | Operaciones `DropOp` en orden de ejecución, agrupadas por bloque (`block_first`, `block_count`). |
| `DropOp` | Tipo, ruta de la hoja o lugar escrito, flag, bloque, evento ancla, antes/después del ancla y tipo semántico. |
| `flag_of`, `flag_paths` | Flag dinámico por hoja y hoja por flag. |

| Operación | Significado (equivalente LIR) |
| --- | --- |
| `drop` | `DropOperation` incondicional de una hoja. |
| `cdrop` | `ConditionalDrop`: solo si el flag es verdadero. |
| `set` / `clear` | `DropFlagUpdate`. |
| `ref` | Drop del valor anterior a través de una referencia mutable antes de escribir. |

Los `ScopeExit` son los eventos `FLOW_DROP` y las `OwnershipTransfer`
son los `FLOW_MOVE` del CFG. Cada operación tiene ID de ruta, flag,
bloque y evento válidos, tipo y origen (`origins`: desplazamiento del
inicializador o `-1 - i` para el parámetro `i`).

## Finalización de ámbitos y drops por arista

`sema_drop.l` mantiene la lista de bindings propietarios vivos en orden
de declaración y una marca por ámbito y por bucle:

| Salida | Drops emitidos en el bloque que toma la arista |
| --- | --- |
| Fin de bloque `{}` o de iteración | Bindings del ámbito, el último declarado primero. |
| `return` | Temporales de la sentencia y todos los bindings vivos, incluidos parámetros; el valor retornado ya se movió. |
| `break` / `continue` | Bindings declarados dentro del bucle. |
| Caída al final de la función | Parámetros. |
| Fin de sentencia | Temporales, el último creado primero. |

Como los eventos están en el bloque de la arista que abandona el ámbito,
cada ruta del CFG solo ejecuta los drops de los ámbitos que realmente
abandona. Los bloques inalcanzables (tras `return`, `break`) no generan
operaciones. No hay `?` ni unwinding en el subconjunto: un pánico aborta
sin drops, igual que en Stage 0.

**Orden.** Ámbito más interno primero, orden inverso de declaración; los
parámetros al final; dentro de un agregado, campos en orden inverso y en
profundidad (el árbol de rutas guarda los hijos en orden inverso, así que
un recorrido en preorden produce el orden de Stage 0). Los temporales de
una interpolación se sueltan antes que su búfer.

## Movimientos, flags y reasignación

Para cada hoja, el estado en cada punto es el que ya demostró el solver
de ownership:

- `LIVE`: drop incondicional;
- `MAYBE`: drop condicionado por flag;
- `MOVED` o `UNINIT`: nada.

Un movimiento completo deja el subárbol `MOVED`; uno parcial solo el campo,
así que el agregado suelta únicamente los campos que todavía posee.

Una hoja recibe flag solo si está en `MAYBE` en algún punto de liberación
(primera pasada). El flag se pone a falso al entrar en la función, a
verdadero tras `FLOW_INIT`/`FLOW_WRITE` y a falso tras un movimiento o un
drop. Como en Stage 0, el flag solo gobierna la destrucción: la lectura de
un valor quizá movido sigue rechazándose con `L0005`.

**Reasignación** (`x = v`, `x.f = v`): primero se evalúa el valor nuevo
(un movimiento desde `x` dentro de `v` ya cuenta), después se sueltan las
hojas antiguas que siguen vivas (condicionalmente si están en `MAYBE`),
después se escribe y se marcan los flags. A través de `&mut` la operación
`ref` suelta el referente anterior: el propietario sigue vivo con el valor
nuevo. Stage 0 hace lo mismo con un `DropField` en campos y de forma
implícita en el backend para la raíz; Stage 1 lo hace explícito en ambos.

## Préstamos y funciones

- Las referencias, parámetros `&T`/`&mut T` y resultados prestados no se
  destruyen: no tienen hojas.
- Un `FLOW_DROP` sobre un propietario con un préstamo vivo que lo solapa es
  un conflicto `L0012` (destrucción prematura). En el subconjunto actual un
  binding de referencia no puede sobrevivir a su propietario, así que la
  regla es defensiva.
- NLL no adelanta drops: el fin de un préstamo no termina la vida del
  propietario, que se destruye en la salida de su ámbito.
- Un valor retornado se mueve antes de los drops del `return` y nunca se
  destruye en la función. Los parámetros por valor se sueltan en cada
  salida si siguen poseídos.

## Tipos compuestos

| Tipo | Tratamiento |
| --- | --- |
| Structs | Por campo, con movimientos parciales y reinicialización de campos. |
| Enums | Hoja atómica, como en Stage 0: el glue de drop del backend destruye solo el payload de la variante activa. El subconjunto de Stage 1 no construye variantes ni hace `match`; los enums llegan como parámetros. |
| `List<T>` y arrays | Hoja atómica que posee su almacenamiento y elementos. Las anotaciones `List<T>` no se resuelven en Stage 1. |
| `Option`, `Result`, `?` | Fuera del subconjunto de Stage 1 (`L0016`). |
| Proyección de un temporal propietario (`mk().campo`) | Rechazada con `L0016`. |

## Verificador

`drops_verify.l` no usa los estados del solver. Recalcula, por hoja, el
conjunto de pares posibles (posee, flag) a partir de los eventos y las
operaciones, con su propio punto fijo, y comprueba:

| Regla | Defecto |
| ---: | --- |
| 1 | ID de ruta, bloque u hoja inválido, o campo inexistente |
| 2 | drop de algo no poseído con certeza (doble drop, valor movido o no inicializado) |
| 3 | flag ausente o de otra hoja |
| 4 | flag distinto de la propiedad real en un drop condicional |
| 5 | inicialización o escritura sobre una hoja todavía poseída (fuga) |
| 6 | movimiento de un valor no poseído |
| 7 | fin de ámbito con una hoja todavía poseída |
| 8 | salida de la función con una hoja todavía poseída |
| 9 | operación anclada fuera de su bloque |
| 10 | `ref` que no escribe a través de una referencia |
| 11 | límite del análisis |

Un fallo es un error interno (`error[ICE]`), distinto de los diagnósticos
por código L inválido. `--drop-fault=K` corrompe un plan correcto de 7
maneras para comprobar que el verificador lo rechaza.

## Pruebas

`crates/l/tests/drops_l.rs` (6 pruebas, binario Cranelift con `PATH` vacío):

- **Diferencial por caminos.** El plan de Stage 1 y el CFG elaborado de
  Stage 0 (`lower_to_cfg`) se ejecutan en todos los caminos con hasta siete
  decisiones de rama, simulando flags. La secuencia de lugares liberados
  debe ser idéntica en cada camino. Se cubren 39 programas de drops
  (332 caminos) y los 80 programas aceptados del corpus del borrow
  checker (199 caminos).
- **Solo Stage 1.** Dos programas mueven un valor exterior dentro de un
  bucle; Stage 0 los rechaza con `L0005` y Stage 1 los acepta con un plan
  verificado, con drop condicional cuando corresponde.
- **Verificador.** Siete corrupciones se rechazan con la regla esperada.
- **Negativos de usuario.** Seis programas inseguros (lectura tras
  movimiento o quizá movido, agregado parcialmente movido, movimiento o
  escritura con préstamo vivo, retorno colgante) siguen rechazándose con
  el mismo código que Stage 0 y sin errores internos.
- **Escala y memoria.** 1 000 bindings propietarios con ámbitos, bucle y
  retornos (100 flags) y balance de heap del driver trazado.

La cobertura positiva incluye: variable simple, dos recursos y orden,
transferencia, movimiento a llamada, movimiento parcial y anidado,
reinicialización de variable y de campo, reasignación con valor quizá
movido, retorno anticipado, `if`/`else`, `while`, `for`, `loop`, `break`,
`continue`, retornos en bucles anidados, parámetros propietarios y
movidos, retorno de locales, de campos y de agregados construidos,
ámbitos anidados, sombreado, temporales, listas, enums con payload,
préstamos compartidos y mutables, escritura a través de `&mut`, NLL
seguido de movimiento, resultados prestados y cortocircuito.

## Mediciones

Windows x86-64, driver Cranelift con traza, cinco ejecuciones tras una de
calentamiento (`bench/stage1-drops.ps1`). Por grupo hay tres variables,
un ámbito propio, un `Text` movido en una rama, reinicializado en grupos
pares y quizá movido en impares, y un struct con dos campos propietarios
y uno movido. Uno de cada diez grupos tiene `return`. La variante `plain`
tiene las mismas sentencias con `Int` y no posee nada.

L no tiene todavía reloj, así que el coste de drops se estima como
diferencia de procesos completos y queda cerca del ruido. Entre corridas
la variante `plain` llegó a variar de 1,3 a 3,0 s en la carga mayor.

| Variables | Funciones | Bloques | Rutas | Drops | Flags | Operaciones | Iter. verificador | Total ms | Plain ms | Pico KiB | Reservas / liberaciones |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 1 | 115 | 167 | 109 | 16 | 176 | 136 | 33,58 | 32,68 | 2 940 | 591 / 591 |
| 1 000 | 2 | 1 136 | 1 668 | 1 099 | 166 | 1 796 | 1 367 | 106,77 | 79,69 | 30 620 | 5 208 / 5 208 |
| 10 000 | 12 | 11 346 | 16 678 | 10 999 | 1 666 | 17 996 | 13 677 | 1 348,48 | 1 420,07 | 39 516 | 51 378 / 51 378 |

La primera versión del verificador unía celdas con aritmética de bits en
cada celda; en una corrida añadió unos 1,3 s a la carga mayor. El atajo
para celdas iguales o vacías lo eliminó. Coste: O(B·P) celdas por función en el
elaborador y en el verificador (como el solver de ownership, con el mismo
límite de dos millones de celdas) y O(subárbol) por evento. Todas las
cargas tuvieron `heap_ok=1`. No se ejecutaron sanitizers: no hay soporte
para el código que genera Cranelift en este entorno, y el balance de heap
no demuestra por sí solo la ausencia de errores de memoria.

## Limitaciones

- Stage 1 no genera código: los drops existen como plan verificado.
- Enums sin construcción ni `match` en Stage 1; `Option`, `Result` y `?`
  fuera del subconjunto.
- Proyecciones de temporales propietarios rechazadas.
- Stage 0 rechaza mover valores exteriores dentro de bucles, así que esos
  planes solo se validan con el verificador de Stage 1.
- Memoria densa O(B·P); funciones muy grandes llegan al límite (`L0016`).

## Preparación para LIR

Para cada función, la fase 7 dispone de:

- el CFG con sus bloques y aristas;
- los eventos de ownership y de préstamos;
- los estados de entrada por bloque;
- el `DropPlan`, con operaciones ancladas a eventos (antes o después), sus
  flags y los tipos de cada hoja.

El lowering puede emitir una instrucción `Drop`/`DropField` por `drop`, un
`Drop` con flag por `cdrop`, una variable `Bool` por flag con sus
asignaciones `set`/`clear`, y un drop a través de puntero por `ref`. El
verificador puede ejecutarse después de cada transformación del plan.
