# CFG y movimientos de Stage 1

La fase 6 incorpora el primer incremento de ownership en L. La CLI
`sema-l archivo.l --check-ownership` analiza el archivo con el lexer,
parser, resolución y tipos de Stage 1. La verificación también se
ejecuta al omitir la opción. Stage 0 construye el ejecutable y sirve
de referencia en los tests. El ejecutable analiza sus entradas en L.

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo build --bin l
$sema = & ./compiler-l/build-sema.ps1
& $sema ./archivo.l --check-ownership
cargo test --test parser_l --test sema_l
pwsh -NoProfile -File bench/stage1-cfg.ps1 -Runs 5
```

## Auditoría

La rama `dev/self-hosting-borrow-checker` parte de `35ae505`.
El pase anterior clasificaba primitivas Copy y agregados Move. Solo
marcaba movimientos de nombres en argumentos por valor. No seguía
transferencias desde inicializadores, asignaciones, retornos ni
campos. La unión de `if` clonaba estados durante el recorrido
del AST y no distinguía ramas que retornaban. Los bucles se
recorrían una sola vez. El parser podía producir tipos de referencia
y operadores de préstamo, pero el pase no comprobaba aliasing,
procedencia ni lifetimes.

Stage 0 conserva su pipeline original. `ownership.rs` comprueba
movimientos en la LIR estructurada. `cfg.rs` baja a bloques y
verifica tipos e inicialización. `loans.rs` analiza alias, liveness
y procedencia. `drops.rs` elabora y verifica los drops. El CFG de
Stage 1 es una estructura semántica que reutiliza los tipos y
símbolos de L. La conversión a LIR y el codegen quedan pendientes.

| Área | Cobertura comprobada en Stage 1 |
| --- | --- |
| Copy y Move | Usa `semTypeIsMove` de la tabla de tipos existente. |
| Transferencias | Inicializadores, asignaciones, argumentos, campos de constructores, literales de colección y retornos explícitos. |
| Movimientos parciales | Campos de structs y proyecciones anidadas. Leer un campo hermano sigue siendo válido. Leer el agregado requiere sus descendientes vivos. |
| Reinicialización | Se restaura una variable mutable completa o un campo cuyo almacenamiento padre sigue vivo. |
| Ámbitos y parámetros | Los parámetros se inicializan en entrada. Cada declaración local tiene identidad de símbolo propia. |
| Ramas y bucles | `if`, cortocircuito, `while`, rangos `for`, `loop`, `break`, `continue` y retornos explícitos. |
| Referencias | Préstamos, NLL, procedencia y retornos prestados en [STAGE1_BORROW_CHECKER.md](STAGE1_BORROW_CHECKER.md). |
| Payloads, índices, regiones y drops | Quedan fuera del incremento. Las operaciones aún no modeladas se rechazan con `L0016`. |

## Representación e invariantes

`flow_cfg.l` mantiene arenas para bloques, instrucciones de ownership,
predecesores y rutas de movimiento. Los identificadores son índices
estables por función. Los sucesores están en cada bloque y las
listas enlazadas por índices permiten recorrer sus predecesores.
Una rama que retorna tiene salida explícita. Las sentencias siguientes
se analizan en un bloque separado y el solver solo visita bloques
alcanzables desde la entrada.

`sema_stmt.l` crea aristas durante el chequeo del AST. `sema_expr.l`
anota lecturas y movimientos al resolver las expresiones. Los eventos
conservan el rango de bytes para diagnósticos. El símbolo guarda el ID
de la raíz de su lugar. Las proyecciones usan el índice del campo en
la arena AST. Padre, primer hijo y hermano enlazan rutas sin
referencias propietarias entre ellas.

Cada ruta conserva una celda para su almacenamiento residual y
cada descendiente tiene la suya. Un movimiento o reinicialización
de una ruta afecta al subárbol. Una escritura de campo requiere
el almacenamiento residual vivo de sus ancestros. Así se distingue
una reasignación después de mover un campo de una escritura dentro
de un agregado que se movió completo. No hay clones implícitos.

## Punto fijo y diagnósticos

`ownership_l.l` guarda un vector de entrada por bloque con estados
sin inicializar, disponible, movido o incierto. La primera arista
alcanzable copia el vector. Las siguientes conservan una celda si
coincide y la hacen incierta si difiere. Un worklist sin duplicados
propaga cambios por los sucesores. Una segunda pasada valida
lecturas, movimientos y escrituras con los estados convergidos.
Una lectura o movimiento requiere disponibilidad en todos los
caminos. `L0005` identifica el primer evento inválido por función.
Una función con resultado distinto de `()` requiere retorno
explícito en cada salida alcanzable. La caída al final de la función
produce `L0003`. Las expresiones finales de bloque que Stage 0
trata como retorno implícito quedan fuera de este subconjunto.

La gramática actual exige inicializador en `let` y `var`. Las pruebas
de inicialización definitiva usan rutas donde un valor movido queda
reinicializado en todas las ramas o solo en algunas. El análisis es
conservador en condiciones de ejecución y no prueba constantes de
rangos. Stage 0 también tiene restricciones propias para movimientos
de valores externos dentro de bucles. La paridad comprobada corresponde
a los casos diferenciales, no a todas las formas de bucles.

Para B bloques y P rutas, los estados consumen O(B·P) celdas.
La estructura del grafo crece linealmente con bloques, aristas,
rutas y eventos. Una visita copia y une O(P) celdas por arista
y aplica eventos en tiempo proporcional a sus subárboles. Tras
la primera llegada, cada celda de entrada solo puede subir a
incierto. Hay límites de dos millones de celdas y cien mil
visitas por función. Excederlos produce `L0016` y estado 1.

## Límites y continuidad

El análisis no exporta todavía estados por punto de programa ni
un plan ejecutable de drops. El grafo y sus estados de entrada
permiten repetir la transferencia en cada instrucción. Para elaborar
drops falta registrar salidas léxicas por arista, orden de destrucción
y disponibilidad por variante. La próxima etapa puede usar los
predecesores para liveness de préstamos y añadir procedencia
sin cambiar la identidad de los lugares.

Las pruebas de trazas verifican reservas, liberaciones, heap y
handles del driver generado. No se ejecutó un sanitizador sobre
el código máquina de Cranelift.

## Validación y mediciones

La primera corrida sobre la base se detuvo en la prueba de traza del
parser. El harness buscaba un binario GNU preexistente aunque la
compilación activa era MSVC. Los harnesses de parser y sema ahora
construyen con el CLI de Cargo, leen la ruta devuelta y separan
binarios normales y trazados. La suite completa pasó con 373
pruebas, cero fallos y tres microbenchmarks ignorados. Cinco
pruebas de CFG agregan casos positivos, negativos y de estrés.
Las suites de parser y sema se volvieron a ejecutar tras los
ajustes finales. Formato y Clippy pasaron.

Windows x86-64, Cranelift con traza, cinco ejecuciones y un
calentamiento. El tiempo es mediana de proceso completo, con
arranque, lectura, lexer, parser, tipos y CFG. El pico de memoria
residente se muestrea mientras vive el proceso. El benchmark no
aísla construcción ni solver, y Stage 1 aún carece de liveness.
Las funciones incluyen ramas y bucles anidados. Las cargas grandes
usan hasta 1 000 declaraciones por función.

| Variables | Bloques | Aristas | Rutas | Visitas del solver | Total ms | Pico KiB | Reservas / liberaciones | Redimensionamientos |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 | 14 | 14 | 102 | 14 | 35,49 | 1 984 | 146 / 146 | 59 |
| 1 000 | 14 | 14 | 1 002 | 14 | 76,63 | 5 152 | 1 046 / 1 046 | 88 |
| 10 000 | 131 | 140 | 10 020 | 131 | 290,86 | 9 268 | 10 262 / 10 262 | 476 |

Todas las cargas tuvieron `heap_ok=1` y cierre de sus handles.
En una ejecución con `PATH` vacío, el uso de un agregado
parcialmente movido devolvió estado 1 y `L0005` con ubicación.
La traza registró 55 reservas y 55 liberaciones, con `heap_ok=1`.

## Préstamos (fase 6.2)

El mismo grafo transporta ahora eventos de creación y uso de préstamos.
`ownership_l.l` los ignora; `loans_check.l` calcula su liveness hacia
atrás con los predecesores de este CFG y verifica exclusividad.
[Diseño, paridad y mediciones](STAGE1_BORROW_CHECKER.md).

## Drops (fase 6.3)

El mismo grafo transporta eventos `FLOW_DROP` en cada salida de ámbito.
El solver los aplica y conserva sus estados de entrada para
`drops_plan.l`. [Plan de drops](STAGE1_DROP_ELABORATION.md).
