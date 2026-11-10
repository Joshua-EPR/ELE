# Borrow checker de Stage 1

La fase 6.2 añade préstamos compartidos y mutables, exclusividad,
liveness no léxica (NLL), préstamos de campos, représtamos, procedencia
y retornos prestados al análisis de Stage 1. Todo se ejecuta en L desde
`sema-l archivo.l --check-ownership`, sobre el mismo CFG y las mismas
rutas de movimiento que el [análisis de ownership](STAGE1_CFG.md).
Stage 0 compila el ejecutable y sirve de oráculo en las pruebas; no
interviene en la decisión.

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo build --bin l
$sema = & ./compiler-l/build-sema.ps1
& $sema ./archivo.l --check-ownership
cargo test --test borrow_l --test sema_l
powershell -NoProfile -ExecutionPolicy Bypass -File bench/stage1-loans.ps1 -Runs 5
```

## Recuperación del trabajo de OpenCode

OpenCode dejó cambios sin confirmar sobre `f232067`: el struct `Loan`
y la tabla `binding_loans` en `flow_cfg.l`, `loans_l.l` (creación de
préstamos y `loanPlaceOf`), `loans_check.l` (liveness hacia atrás),
`borrow_scan.l` (contratos sintácticos de retorno), cambios de tipos en
`sema_context.l`/`sema_expr.l` y una sonda temporal de veredictos de
Stage 0. No compilaba: usaba `FLOW_LOAN_USE` sin definirlo, pasaba
`graph` donde se exigía `&mut graph`, comparaba enums con `==`,
`loans_check.l` no estaba importado y `sema_stmt.l` no vinculaba
préstamos. Además calculaba línea y columna de cada préstamo recorriendo
el fuente desde el inicio (coste cuadrático) y recorría todos los
préstamos en cada evento.

Se conservaron la representación (préstamos en el grafo, préstamo por
binding, `parent` para représtamos, réplica de proyecciones con
`loanPlaceOf`), la liveness hacia atrás con testigo y la lista de casos
de la sonda, que pasó a `crates/l/tests/borrow_l.rs`. Se reescribieron
el solver (worklist sobre los predecesores existentes, índice por
raíz), la integración semántica y la procedencia. `borrow_scan.l` se
retiró al adoptar el contrato por firma de Stage 0 (ver abajo).

## Arquitectura

| Módulo | Responsabilidad |
| --- | --- |
| `flow_cfg.l` | `Loan`, eventos `FLOW_LOAN_CREATE` y `FLOW_LOAN_USE`, `loans` y `binding_loans` del `FlowGraph`, `loanOverlaps` y `flowRootPath`. |
| `loans_l.l` | Creación y vinculación de préstamos, préstamos de parámetros, `loanPlaceOf`, nodos de resultado y comprobación de procedencia. |
| `loans_check.l` | Liveness hacia atrás hasta punto fijo y barrido de exclusividad. |
| `sema_borrow.l` | Reglas de posición, créditos de llamada, resultados prestados, retornos y tipos de referencia admitidos. |
| `sema_expr.l`, `sema_stmt.l`, `sema.l` | Emiten los eventos al resolver nombres, campos, llamadas, `let`, asignaciones y retornos; ejecutan el verificador tras el de ownership. |

No hay un CFG ni un sistema de ownership paralelo. Los préstamos son
eventos más del grafo de `flow_cfg.l`; el solver de disponibilidad los
ignora (`ownership_l.l`) y el de préstamos ignora la disponibilidad.

## Representación

- **Préstamo** (`Loan`): un sitio sintáctico de préstamo. Guarda tipo
  (`LOAN_SHARED`/`LOAN_MUT`), lugar prestado (ruta de movimiento),
  `parent` (préstamo del que reborrowea), `alt` (siguiente origen
  alternativo de un resultado prestado), `param` (índice del parámetro
  cuando el préstamo lo porta el propio parámetro) y su rango de bytes.
  Línea y columna solo se calculan al construir un diagnóstico.
- **Binding de referencia**: siempre es una ruta raíz. `binding_loans`
  asocia esa raíz con su préstamo. Un acceso `r` o `r.campo` es un uso
  del préstamo; `loanPlaceOf` replica la proyección sobre el lugar
  prestado (`r.campo` con `r = &p` denota `p.campo`).
- **Eventos**: `FLOW_LOAN_CREATE` en cada `&`, `&mut`, préstamo
  implícito de argumento o nodo de resultado; `FLOW_LOAN_USE` en la
  llamada para cada préstamo de argumento. Los accesos `READ`, `WRITE`,
  `MOVE` e `INIT` existentes completan el modelo. Antes del análisis se
  anota en cada acceso a través de una referencia el lugar alcanzado.
- **Grafo de préstamos**: `parent` y `alt` apuntan siempre a un id
  menor, así que el grafo es acíclico y los recorridos terminan.

## Reglas del subconjunto (Stage 0)

- Un préstamo `&lugar`/`&mut lugar` solo aparece como inicializador de
  `let`, argumento de un parámetro de referencia o valor de un retorno
  prestado. En otra posición: `L0001`; en `var` o sobre una expresión
  que no es lugar: `L0012`.
- Un parámetro `&T` acepta un lugar, que se presta implícitamente, o
  `&lugar`; `&mut T` exige `&mut lugar` explícito (`L0001`).
- `&mut` requiere un propietario `var` o una referencia `&mut`
  (`L0012` en `let`, `L0001` en argumentos).
- Leer una referencia lee el referente (`print(r)`, `r + 1`,
  `let b = r` copia el valor). Mover a través de una referencia: `L0005`.
- Asignar a un binding `&mut` escribe a través de él; a través de
  `&T`: `L0001`.
- Tipos de referencia: en parámetros, resultados y anotaciones de
  `let`. Referencias en campos de struct, arrays o anidadas: `L0012`.
- El resultado de una función que devuelve referencia se usa como
  inicializador de `let` (anotación compatible) o como retorno
  prestado; en otro caso `L0013`.

## Algoritmos

**Liveness (NLL).** Análisis hacia atrás. Una celda por bloque y préstamo
contiene 0 (muerto) o el desplazamiento + 1 del uso testigo más cercano.
Transferencia por evento, en orden inverso:

- uso de un binding o `FLOW_LOAN_USE`: el préstamo, sus ancestros
  `parent` y todas sus alternativas `alt` pasan a vivos;
- `FLOW_LOAN_CREATE`: el préstamo muere (kill).

La unión toma el testigo menor. Las celdas solo crecen (0 → testigo →
testigo menor), así que el worklist termina. Se siembra con todos los
bloques alcanzables y cada cambio reencola los predecesores mediante
las listas enlazadas que ya construía el CFG. Un préstamo termina tras
su último uso alcanzable, no al cerrar el ámbito; los bucles lo
mantienen vivo por la arista de retorno si se usa en la siguiente
iteración; los retornos cortan la propagación.

**Exclusividad.** Un barrido sobre los bloques alcanzables comprueba
cada evento contra los préstamos vivos inmediatamente después de él.
Solo se visitan los préstamos cuya raíz coincide con la del lugar
accedido (lista por raíz, más recientes primero).

| Evento | Conflicto con un préstamo vivo `m` que solapa |
| --- | --- |
| Lectura de un propietario | `m` mutable |
| Escritura, movimiento o inicialización de un propietario | cualquier `m` |
| Creación de un préstamo `L` | `m` no ancestro de `L` y alguno de los dos mutable |
| Uso del binding de `L` | `m` reborrow (descendiente) de `L` mutable; en escritura, cualquier descendiente |

Solapan dos lugares con la misma raíz cuando uno es ancestro o igual
del otro: `p.x` y `p.y` son disjuntos; `p` solapa con ambos. Los índices
dinámicos no forman lugares en Stage 1 (`L0016`), así que nunca se
consideran disjuntos.

**Représtamos.** `&a`/`&mut a` con `a` referencia crea un préstamo hijo
sobre el lugar de `a`. Mientras el hijo vive, el binding padre queda
suspendido según la tabla; al morir el hijo, el padre se reactiva.
Un `&mut` desde `&T` se rechaza.

**Llamadas.** Cada argumento de referencia crea un préstamo temporal
usado en el punto de la llamada, así que `g(&mut x, &x)` o
`g(&mut p, &mut p.y)` entran en conflicto y `g(&mut p.x, &mut p.y)` no.

**Retornos prestados y procedencia.** Contrato por firma, como Stage 0:
el resultado puede tomar prestado de cualquier parámetro de referencia.
En el llamador cada préstamo de argumento recibe un nodo de resultado
(`parent` = préstamo del argumento) encadenado por `alt`; el binding
`let r = f(...)` porta la cabeza. Usar `r` mantiene vivos todos los
orígenes posibles. En el llamado, cada `return` de una función con
resultado referencia debe llevar un préstamo de modo compatible (`&mut`
exige préstamo mutable) cuyo grafo de procedencia termine en préstamos
de parámetros (`loanRootedAtParams`). Un retorno de `&local`, de una
referencia a un local o de un resultado prestado con algún origen
local produce `L0013`. La procedencia se conserva a través de
asignaciones `let`, campos, ramas, bucles, llamadas y représtamos de
resultados con varios orígenes.

## Invariantes

1. Cada préstamo tiene exactamente un evento de creación por sitio
   (los préstamos de parámetros no lo necesitan: viven desde la
   entrada) y un binding de referencia es inmutable, así que su
   préstamo no cambia mientras está en ámbito.
2. Un binding de referencia no puede sobrevivir a su propietario en el
   subconjunto: solo se inicializa con un préstamo de un lugar visible
   en el mismo ámbito, no se reasigna, no se guarda en agregados y solo
   sale de la función por un retorno prestado con procedencia de
   parámetros. Por eso no se necesitan eventos de fin de almacenamiento.
3. El verificador de préstamos solo corre si el de disponibilidad no
   encontró errores; préstamos de valores movidos o parcialmente
   movidos se rechazan con `L0005` antes.
4. Lo que no puede demostrarse seguro se rechaza: posiciones de
   préstamo no listadas, referencias en agregados y límites del
   análisis (`L0016`, igual que el solver de ownership: dos millones de
   celdas bloque×préstamo y cien mil visitas por función).

## Pruebas y paridad con Stage 0

`crates/l/tests/borrow_l.rs` ejecuta el binario Cranelift de Stage 1
con `PATH` vacío sobre 181 programas y compara con `project_l::check`:

| Resultado | Casos |
| --- | ---: |
| Mismo veredicto y mismo código | 168 |
| Ambos rechazan con códigos distintos | 7 |
| Stage 1 rechaza y Stage 0 acepta (más estricto) | 6 |
| Stage 1 acepta y Stage 0 rechaza | 0 (afirmado por la prueba) |

Las diferencias de código: Stage 0 rechaza `*r` en el parser con
`L0003` (Stage 1 con `PARSER`); usa `L0005` para aliasing dentro de una
misma llamada (Stage 1 `L0012`); reasignar un binding inmutable que
copió un referente es `L0001` en Stage 0 y `L0006` en Stage 1; un struct
con campo referencia es `L0001` o `L0012` según el caso. Los seis casos
más estrictos guardan referencias en structs o en `List`.

En 26 conflictos `L0012` ambos compiladores citan la misma posición de
origen del préstamo y el mismo uso vivo; la prueba lo afirma. La
posición del acceso inválido sigue convenciones distintas: Stage 0
señala el valor asignado o el uso posterior, Stage 1 el acceso que
inicia el conflicto. En préstamos de campos Stage 0 cita el nombre del
campo y Stage 1 la raíz del lugar.

Cobertura positiva: múltiples préstamos compartidos, mutable válido,
NLL tras el último uso, campos disjuntos (en `let`, argumentos y a
través de parámetros), ramas, bucles `while`/`for`/`loop`, `break`,
retornos anticipados, représtamos en cadena, retornos de parámetros y
de campos de parámetros, cadenas de llamadas prestadas y resultados
con varios orígenes. Cobertura negativa: dos `&mut`, mutable con
compartido, lecturas y escrituras durante `&mut`, movimiento del
referente, préstamo de valor movido o posiblemente movido, retorno de
local (directo, por binding, por llamada y por représtamo), escape a
`var`/asignación/print/listas, représtamo inválido, conflicto tras
unión de ramas y por la arista de un bucle, escritura a través de `&T`.

`sema_l.rs` conserva los casos de CFG y ahora espera aceptación de
préstamos válidos y `L0013` para el escape de un local. La prueba de
escala comprueba 1 501 préstamos y el balance de heap del driver
trazado sobre un programa rechazado.

## Mediciones

Windows x86-64, driver Cranelift con traza, cinco ejecuciones y una de
calentamiento (`bench/stage1-loans.ps1`). Tiempo total de proceso
(arranque, lectura, lexer, parser, tipos, CFG, ownership y préstamos).
La variante `copias` tiene las mismas sentencias sin préstamos. L no
expone todavía un reloj a programas, así que no se aíslan las fases
dentro del proceso; la diferencia entre variantes es la estimación del
coste de préstamos y queda dentro del ruido.

| Préstamos | Funciones | Bloques | Rutas | Iter. ownership | Iter. préstamos | Total ms | Copias ms | Pico KiB | Reservas / liberaciones |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 101 | 1 | 18 | 104 | 25 | 11 | 45,53 | 57,13 | 2 168 | 253 / 253 |
| 1 001 | 1 | 27 | 1 004 | 91 | 20 | 70,16 | 61,82 | 5 940 | 1 702 / 1 702 |
| 10 001 | 10 | 225 | 10 022 | 883 | 191 | 932,41 | 984,32 | 12 092 | 16 498 / 16 498 |

Peor caso de solapamiento (todos los préstamos sobre el mismo
propietario, todos vivos a la vez, un solo bloque): 100, 1 000 y
2 000 préstamos en 110, 146 y 279 ms. Ese caso recorre la lista de la
raíz en cada acceso, O(eventos × préstamos de la raíz).

Coste: memoria O(B·L) por función para B bloques y L préstamos (tabla
densa, igual que el solver de ownership) y tiempo O(visitas × L) para la
liveness. Todas las cargas tuvieron `heap_ok=1` y reservas iguales a
liberaciones. No se ejecutaron sanitizers: no hay soporte para el
código máquina que genera Cranelift en este entorno. El balance de
heap no demuestra por sí solo ausencia de errores de memoria.

## Limitaciones

- Referencias en structs, enums, `List`/arrays y referencias anidadas
  quedan fuera (Stage 0 sí admite algunas).
- Contrato de retorno por firma: el resultado retiene todos los
  argumentos de referencia, aunque el cuerpo solo devuelva uno.
- La desreferencia explícita `*r` no existe en la gramática actual.
- Sin fin de almacenamiento explícito: la invariante 2 lo hace
  innecesario en el subconjunto; ampliar el subconjunto exigirá
  eventos de fin de ámbito.
- Memoria densa O(B·L); funciones con muchos bloques y préstamos llegan
  al límite y se rechazan con `L0016`.
- El plan de drops ya existe ([STAGE1_DROP_ELABORATION.md](STAGE1_DROP_ELABORATION.md)).

## Plan de drops (completado en la fase 6.3)

Ver [STAGE1_DROP_ELABORATION.md](STAGE1_DROP_ELABORATION.md). Texto
original del plan:

Dependencias ya disponibles: estados de disponibilidad por bloque
(vivo, movido, incierto) por ruta y campo, reinicializaciones,
predecesores y salidas por `return`, y liveness de préstamos. Falta:
eventos de fin de ámbito por arista (incluidos `break`/`continue` y
retornos anticipados), orden de destrucción por declaración, banderas
dinámicas para rutas inciertas y una representación del plan por
arista que la futura LIR de la fase 7 pueda consumir. Los referentes
de préstamos nunca se destruyen a través de la referencia y los
valores movidos no se destruyen.
