# Modelo de memoria de ELE: referencias, regiones y escapes

Estado: **implementado y probado** salvo donde se indica "pendiente". Complementa
[SEMANTICS.md](SEMANTICS.md#modelo-de-memoria-adaptive-ownership-primera-implementación)
(propiedad, movimientos, drops) y [BACKEND.md](BACKEND.md) (representación nativa).

## 1. Categorías de almacenamiento

| Categoría | Ejemplos | Quién libera | Cuándo |
|---|---|---|---|
| Valor local | Int, Bool, Float, structs y enums (en pila o registros) | nadie (sin recursos) | fin de vida del frame |
| Heap propio | buffer de un Text dinámico | su único dueño, vía `Drop` | fin de su región léxica, salvo si se movió |
| Estático | literales Text (`cap == 0`) | nunca | — |
| Región | bloques reservados por `region r { ... }` | la variable de región, vía `Drop` | al salir del bloque `region` por cualquier ruta |
| Vista de región | `Bytes` devuelto por `r.bytes(n)` | nadie: no posee nada | inválida cuando termina su región |
| Préstamo | `&T`, `&mut T` | nadie | último uso local o fin de la llamada |

No hay recolector de basura ni conteo de referencias.

## 2. Referencias locales y de llamada

Una referencia local contiene la dirección de un lugar que ya existe, con
modo compartido o exclusivo. Un slice contiene dirección y longitud. Cada
binding local tiene un origen fijo e inicializado. La sintaxis no permite
reasignar la dirección, introducirla en agregados ni pasarla como valor
propietario a una función genérica. El retorno prestado requiere el contrato
descrito en §10. Pasarla a un parámetro de referencia crea un
préstamo de llamada. Pasar el nombre por valor lee el referente según su
tipo y sus reglas de movimiento.

El pase `loans.rs` calcula liveness hacia atrás sobre el CFG. Une usos de
sucesores y mata el uso anterior al volver a definir la referencia, como
ocurre en bucles. El diagnóstico muestra el sitio que crea el préstamo y
un uso que lo mantiene vivo. Un représtamo mantiene vivo su origen. Las
raíces distintas y los campos disjuntos se pueden prestar simultáneamente.
Un índice puede coincidir con cualquier otro índice de la misma colección.

Mientras un préstamo está vivo, los accesos al lugar deben respetar su
modo. Se comprueban lectura, escritura, movimiento, llamadas, destrucción y
operaciones que pueden invalidar un índice o slice. Un préstamo de una
lista regional sigue las mismas reglas. La región y sus datos permanecen
dentro de sus scopes y el pase conserva los drops existentes.

Pendientes: lifetimes explícitos en firmas, referencias almacenadas en
agregados, análisis general de escapes y préstamos de elementos escritos
directamente en la lista de argumentos.

## 3. Regiones

```l
fn procesarBuffer(buffer: &Bytes) { ... }

fn procesar() {
    region temporal {
        var buffer = temporal.bytes(1024)
        procesarBuffer(buffer)
    }
}
```

**Identidad.** Cada `region nombre { ... }` es una región léxica con un id único en el
programa. El binding `nombre` tiene tipo `Region(id)`; un buffer reservado en ella
tiene tipo `Bytes(id)`. Un parámetro `&Bytes`/`&mut Bytes` tiene tipo
`Bytes(llamador)`: una región de algún llamador, que vive más que la llamada.

**Propietario y vida.** La variable de región es un recurso propietario que se libera
con la maquinaria de drops ya verificada: al terminar el bloque, en `return`, en
`break`/`continue` que salgan de él (y con drop flags si una ruta fuese incierta).
La vida de la región es exactamente la del bloque.

**Asignaciones.** `r.bytes(n)` reserva `n` bytes **inicializados a cero** y alineados
a 8. `n < 0` es panic. Un buffer no posee memoria: no tiene drop.

**Relaciones y anidamiento.** Una región interna termina antes que la externa; sus
locales (incluidos sus buffers) dejan de existir al cerrarla. Los buffers de una
región externa se pueden usar dentro de una interna, nunca al revés.

**Reglas de escape** (todas comprobadas en la semántica, no por patrones de texto):

| Vía de escape | Regla | Error |
|---|---|---|
| `return buffer` / expresión final | ningún resultado puede tener tipo `Bytes`/`Region` | L0011 |
| asignación a variable de otra región | `Bytes(a)` ≠ `Bytes(b)` | L0011 |
| campos de struct, parámetros por valor, retornos en la firma | el tipo `Bytes` solo se puede escribir como `&Bytes`/`&mut Bytes` de parámetro | L0011 |
| enums, `Option`, `Result`, structs genéricos | instanciar un genérico con un tipo de región se rechaza | L0011 |
| funciones genéricas | ídem | L0011 |
| llamadas | solo por referencia; la referencia no puede escapar de la llamada (§2) | — |
| uso tras cerrar la región | el nombre ya no está en el ámbito | L0001 |
| la región como valor | `let otra = r` se rechaza; solo `r.bytes(n)` | L0011 |
| listas | no existen aún (pendiente) | — |

**Movimiento.** `Bytes` no es Copy: `let b2 = b` mueve dentro de la misma región;
usar `b` después es error de ownership. No hay copias implícitas.

**Escritura.** `b.set(i, v)` exige binding `var` o `&mut Bytes`; `i` fuera de
`0..len` y `v` fuera de `0..=255` son panic con ubicación. `b.get(i)` comprueba límites.

**Destrucción.** Al salir de la región se destruyen primero sus otros locales (orden
inverso de declaración; p. ej. Text que hayan creado) y después la región libera sus
bloques. Un buffer nunca contiene recursos con destructor, así que liberar el
almacenamiento no omite ningún drop.

**Rutas de error.** `?` y `return Err(...)` dentro de una región son retornos
anticipados: la región se libera en esa ruta (probado).

**panic = abort.** Un panic termina el proceso sin ejecutar drops ni liberar
regiones; el sistema operativo recupera la memoria del proceso.

## 4. Allocator de regiones (backend nativo)

- Cabecera de 24 bytes en el frame que abre la región: `{bloque actual,
  desplazamiento, capacidad}`. Una región vacía **no reserva nada**.
- Bloques del heap del proceso encadenados (`[anterior, relleno, datos...]`, datos
  alineados a 16). Reserva *bump*: alinea el desplazamiento a 8 y avanza.
- Si no cabe: bloque nuevo de `max(n, 2·capacidad, 4096)` bytes; si el tamaño
  desbordaría, panic "memoria insuficiente" (igual que un fallo de `HeapAlloc`).
- `Drop` de la región: recorre la cadena y libera cada bloque una vez.
- Instrumentación (`--trace-alloc`): `region_allocs` (reservas lógicas),
  `region_bytes` (bytes pedidos), bloques reales en `allocs`/`frees`, comprobación
  de alineación de cada reserva y `HeapValidate` por liberación y al salir.
- Backend rustc: `LRegion` con un `Box<[u64]>` por buffer (comportamiento
  observable idéntico, no bump); se usa como referencia en pruebas diferenciales.

## 5. Efectos

- `r.bytes(n)` produce `alloc` y `panic`: una región **no** elude `@noalloc`.
- `get`/`set` producen `panic` (comprobación de límites); `len` y abrir una región
  no producen efectos. Liberar no es un efecto.
- Propuesta futura (no implementada): distinguir `alloc(region)` de `alloc(heap)`
  para permitir código "sin heap global" que sí use regiones acotadas. Requiere
  cambiar el retículo de efectos y no se hace en silencio.

## 6. Análisis de escape

Clasificación (spec de la tarea): 1) no escapa, 2) escapa al llamador, 3) escapa a
almacenamiento más longevo, 4) indeterminado.

Las restricciones generales de almacenamiento se comprueban por tipos. El
pase de procedencia de retornos prestados se describe en §10. Las
garantías actuales salen de reglas de tipos más simples y conservadoras:

| Valor | Clasificación efectiva |
|---|---|
| Préstamo (`&`) | 1 siempre: no puede salir de la llamada (§2) |
| Buffer de región | 1 respecto a su región; 2/3 rechazados con L0011 |
| Text, structs, enums | se mueven libremente (propietarios); su liberación la decide `drops.rs` |

Pendiente: un pase de escape sobre la LIR de bloques que permita (a) colocar en
pila valores que demostrablemente no escapan, (b) agrupar temporales en regiones
implícitas, y (c) relajar las reglas de §2 con lifetimes. Cualquier optimización
basada en él debe ser desactivable y validarse con las pruebas diferenciales.

## 7. Colecciones (2026-11-08)

- **Almacenamiento.** `[T; N]` vive donde vive su propietario (marco, campo, elemento);
  `List<T>` es una cabecera `(ptr, len, cap)` que posee un buffer del heap de `cap`
  elementos, de los que los `len` primeros están inicializados. `&[T]` es una vista
  `(ptr, len)` prestada de un array o una lista; no posee nada.
- **Invariantes.** (1) Solo los elementos `0..len` están vivos y se liberan exactamente
  una vez, al liberar la lista o al reemplazarlos con `c[i] = v`. (2) Ningún elemento
  sale de una colección salvo por `pop` (que reduce `len` antes de entregarlo).
  (3) Mientras exista un préstamo de la colección (iteración, parámetro slice) nada
  puede cambiar su longitud, capacidad ni buffer: no hay punteros colgantes por
  realocación. (4) Todo acceso por índice se comprueba contra la longitud viva.
  (5) Una lista movida no se libera en su origen (elaboración de drops ya verificada).
- **Crecimiento.** Realocación con `HeapReAlloc` (los elementos se trasladan por bytes,
  lo cual es válido porque los valores de L no tienen autorreferencias); fallo →
  panic, sin modificar la cabecera.
- **Instrumentación.** `--trace-alloc` cuenta reservas, realocaciones y liberaciones,
  valida cada `free` y el heap al salir; las pruebas de `tests/collections.rs` exigen
  `allocs == frees`, con escenarios de realocación, elementos Text/struct/enum, listas
  anidadas, salidas anticipadas y fallo de reserva inyectado.
- **Regiones.** El hito posterior de listas regionales se describe en §9.

## 8. Limitaciones conocidas

- `Bytes` y buffers de elementos de listas regionales pueden residir en la región.
  Arrays, structs y enums pueden ser elementos por valor. Las asignaciones internas
  de un elemento, como el buffer de Text o de una lista ordinaria, siguen en el heap.
- Las referencias pueden vincularse a un `let` local. Solo las vistas locales concretas pueden almacenar referencias.
- `allocs == frees` y `HeapValidate` cubren las rutas que ejecutan las pruebas; no
  son una demostración general de ausencia de fugas.


## 9. Almacenamiento de listas regionales

- La región posee sus bloques. La lista posee los elementos inicializados
  en `[0, len)`. Mover la cabecera transfiere esa responsabilidad.
- Crecer reserva otro rango alineado en la misma región y traslada el prefijo
  vivo. El rango anterior se retiene hasta el final de la región y se vuelve
  inaccesible. Sus bytes no representan elementos vivos.
- El drop de la lista destruye sus elementos. Se ejecuta también al reemplazarla
  o terminar su scope antes que la región. El drop de la región devuelve los
  bloques encadenados al heap. Las salidas anticipadas usan el orden léxico de
  drops, incluida la propagación por `?`. Panic conserva la política de abort.
- Slices prestados mantienen el almacenamiento válido durante la llamada o
  hasta su último uso local. Se pueden retornar con un contrato válido. Su almacenamiento en agregados sigue prohibido.
  Tampoco se admiten tipos de lista regional como elementos de otra colección.
- El verificador de CFG exige región viva para las operaciones de ownership de
  la lista y rechaza liberar la región con listas posiblemente vivas. Los tipos
  regionales se verifican al construir la cabecera y al transferirla.
- El trazado `region_retired` suma bytes de capacidad abandonada por crecimiento.
  Es un acumulado durante el proceso. No incluye padding, capacidad sin ocupar
  de la lista actual ni espacio que quede en el último bloque de una región.


## 10. Procedencia interprocedimental de retornos

Cada firma soportada publica `BorrowReturn { params, mode }`. El CFG conserva
el retorno como `ReturnRef`. El análisis normaliza el lugar a través de los
représtamos locales y sustituye el resultado de una llamada por su conjunto de argumentos
prestados de origen. Comprueba todos los retornos contra el contrato, también
si una función reenvía el resultado de otra o llama recursivamente. Cada cuerpo
se verifica con el mismo contrato que usan sus llamadores.

Un retorno cuenta como uso de la referencia después de los drops de salida.
El puntero se evalúa antes de esos drops. Cada origen debe pertenecer a los parámetros
prestados del contrato, por lo que los propietarios del frame no pueden salir prestados.
La comprobación de aliasing prolonga el préstamo del argumento real en el
llamador hasta el último uso del resultado. El resumen conserva el origen
completo del argumento, sin inferir la proyección exacta devuelta.

Este pase cubre escapes por retorno, directos e indirectos. Las referencias
como elementos de contenedores o campos que atraviesan firmas quedan pendientes. Las vistas con tipo
slice pueden retornarse. Véase [ESCAPE_ANALYSIS.md](ESCAPE_ANALYSIS.md).


## 11. Lifetimes de vistas locales

El campo prestado es un puntero sin destructor. Su procedencia pertenece a la
instancia y se copia al mover el struct, manteniendo viva la relación con el
propietario. El análisis de último uso activa los préstamos de los campos al
usar la vista. Los drops del struct se aplican a campos propietarios, sin
desreferenciar ni liberar sus campos prestados. [Alcance](AGGREGATE_LIFETIMES.md).


## 12. Retornos de agregados prestados e invariantes interprocedimentales

Las funciones pueden retornar agregados que contienen referencias compartidas (`&T`), asociadas mediante `ViewReturn` y `FieldContract`.
- **Invariante de procedencia:** Ningún campo prestado de una vista retornada puede apuntar a almacenamiento que pertenezca al stack frame de la función retornante (variables locales, temporales o agregados locales). Todo campo prestado debe enraizarse en un parámetro formal prestado de la función.
- **Invariante de liveness:** El llamador mantiene activos los préstamos de los campos de la vista durante toda la vida útil de la misma. Al terminar el último uso de la vista (o de cualquiera de sus campos proyectados con `FieldLoan`), el préstamo sobre el propietario se libera.
- **Invariante de drops:** El agregado retornado es propietario de sus campos no prestados (p. ej. `Text`), los cuales se destruyen al salir de ámbito en el llamador. Los campos prestados son tratados como punteros opacos durante el drop: nunca se destruye ni libera la memoria del referente prestado.
- **Invariante de disyunción por campo:** Cuando una vista retiene un préstamo sobre una proyección específica (p. ej. `p.nombre`), los campos disjuntos (p. ej. `p.edad`) pueden ser mutados por el propietario siempre que se demuestre estáticamente que sus proyecciones no se solapan. [Detalle](BORROWED_AGGREGATE_RETURNS.md).

## 13. Referencias mutables en agregados y reasignación de vistas

Los agregados pueden almacenar referencias mutables exclusivas `&mut T` (`Type::MutField`).
- **Invariante de exclusividad:** No pueden existir simultáneamente dos vistas mutables ni una vista mutable y una compartida que apunten al mismo lugar o a lugares que se solapen. Durante la vigencia de una vista mutable, el propietario original no puede ser leído, modificado ni movido directamente.
- **Invariante de movimiento (No Copy):** Las vistas que contienen referencias mutables no implementan `Copy`. La transferencia de propiedad (asignación o paso por valor) mueve el agregado e invalida permanentemente la variable origen (`L0005`).
- **Invariante de mutación por desreferenciación:** La mutación a través de un campo `&mut T` (`vista.campo = valor`, `self.campo += 1`) se desreferencia en LIR mediante `FieldLoan`, modificando el dato en la dirección referenciada sin sobrescribir el puntero del struct ni alterar el layout del agregado.
- **Invariante de reasignación:** Cuando una variable vista es reasignada (`var vista = Vista(&a); vista = Vista(&b)`), el préstamo sobre el referente anterior (`a`) termina inmediatamente en el punto de reasignación a menos que `vista` vuelva a unirse en una bifurcación de control de flujo (`if/else`). Cada variable vista mantiene identidades de préstamo sintéticas por campo que unifican los orígenes según el flujo del programa.

## 14. Lifetimes y drops en variantes y colecciones con referencias

Los tipos compuestos (`Option<&T>`, `Result<&T, E>`, enums con cargas útiles prestadas, arrays `[&T; N]`, listas dinámicas `List<&T>` y listas regionales `r.list<&T>()`) preservan los mismos invariantes de seguridad de Adaptive Ownership:

- **Invariante de procedencia en variantes:** Cada carga útil de variante prestada (`ViewKey::Payload(variante, campo)`) retiene la procedencia del lugar origen. Cuando una función construye y retorna una variante con una referencia, dicha referencia debe originarse en un parámetro formal. Variantes sin carga útil prestada (como `Option.None`) no retienen préstamos ni limitan la vida de variables locales.
- **Invariante de colecciones de referencias:** Los elementos de arrays y listas que almacenan referencias (`ViewKey::Index(i)`) mantienen activos los préstamos de los lugares enraizados mientras la colección esté viva. Empujar una referencia a una lista (`xs.push(&b)`) extiende el préstamo de `b` por toda la vigencia de `xs`.
- **Invariante de drops selectivos:** Al destruirse una variante compuesta o una colección que almacena referencias:
  - Las cargas útiles propietarias (por ejemplo, una cadena `Text` en `Result.Err(Text)`) se destruyen llamando a su destructor determinista.
  - Los búferes de asignación de la colección (`List`) se liberan devolviendo la memoria al allocator (o reteniéndola según la política de `Region`).
  - Los referentes apuntados por las referencias compartidas `&T` o mutables `&mut T` dentro de la variante o colección **nunca** son liberados ni alterados por el drop del contenedor.
- **Invariante de no-aliasing mutable en colecciones y variantes:** No es posible almacenar simultáneamente dos referencias mutables al mismo lugar ni compartir una referencia mientras exista una referencia mutable en la misma o en distinta variante/colección (`L0012`).

## 15. Tareas asíncronas: estado, suspensión y cancelación

Detalle en [ASYNC_MODEL.md](ASYNC_MODEL.md).

- **Almacenamiento.** El estado de una tarea es un bloque del heap reservado **a
  cero**, propiedad de exactamente un manejador (`Future<T>`, un puntero). Vive
  mientras viva el manejador, así que su dirección es estable mientras la tarea
  está suspendida: nada se mueve bajo los punteros internos. Tras un `spawn` el
  propietario del estado es el planificador, y el handle (`TaskHandle<T>`, otro
  puntero) posee el **registro** de la tarea: 72 bytes del heap que tampoco se
  mueven nunca.
- **Invariante del patrón de ceros.** En Proyecto L, el bit pattern todo ceros es
  un valor válido y sin recursos para cualquier tipo (Text con capacidad 0 es
  estático, lista con capacidad 0 no tiene buffer, manejador nulo no tiene
  tarea, discriminante 0 con payload a cero no posee nada). De ahí que el estado
  se reserve a cero y que el destructor pueda liberar todos sus campos que poseen
  algo sin consultar el punto de reanudación.
- **Invariante de consumo único.** Tras mover un valor fuera del estado (el
  resultado al consumirlo, el future esperado al liberarlo) el campo se pone a
  cero explícitamente, de modo que ninguna liberación posterior lo toca: ni doble
  liberación ni liberación de algo movido.
- **Propietarios persistentes.** Un parámetro propietario se transfiere al
  crear el future. Los parámetros y locales propietarios admitidos viven
  en ranuras etiquetadas. El handle vacío usa un puntero nulo.
- **Movimientos parciales.** Los caminos de campos de struct distinguen
  inicialización definida de vacío o incierto. Mover un subárbol deja su
  representación sin recursos, sin cambiar la etiqueta del struct. El
  vaciado cuenta como escritura para el verificador de préstamos, que
  permite préstamos disjuntos y rechaza los que solapan el subárbol.
  Enums y colecciones son unidades de propiedad en el estado. El
  destructor de enum visita la variante activa, y los destructores de
  colecciones visitan los elementos que siguen en su almacenamiento.
- **Invariante de suspensión.** No sobrevive un puntero prestado al marco
  de `poll`. Las referencias y vistas vivas tras la suspensión, las
  regiones abiertas y suspender durante un recorrido prestado de
  colección siguen rechazados.
- **Cancelación.** Destruir un manejador ejecuta el destructor del estado y
  libera el bloque: antes del primer sondeo se liberan los parámetros propietarios y el
  bloque; suspendido, se liberan también los locales ocupados y se
  destruyen en cascada el objeto esperado y los handles que poseía; terminado sin consumir, se libera el resultado. No hay terminación
  forzosa ni manejadores reanudables después de destruirse (una tarea terminada
  nunca se vuelve a sondear y una cancelada se descarta sin sondearse). La
  cascada se recorre **iterativamente**, con una lista de registros pendientes de
  destruir, así que la profundidad del árbol de tareas no consume pila. Una tarea
  cancelada que aún estaba en la cola de listas sale de ella en O(1) (la cola es
  doblemente enlazada) y se libera de inmediato: nada queda retenido hasta el
  siguiente turno del planificador.
- **Instrumentación.** `--trace-alloc` cuenta los bloques de estado y los
  registros de tarea junto al resto del heap y añade `suspends`; las pruebas de
  `tests/async.rs` y `tests/spawn.rs` exigen `allocs == frees` y `heap_ok=1` en
  cada programa, incluidas las rutas de retorno anticipado, `break`, futures
  abandonados sin sondear, tareas canceladas antes de empezar, tareas canceladas
  mientras estaban suspendidas, cadenas de 20 000 tareas y fallo de reserva al
  construir una tarea.


### Ownership durante join

`await join(a, b)` toma ambos handles por valor. El estado del padre los
mantiene en campos distintos, incluso si las hijas tienen el mismo tipo.
Durante Pending, los resultados listos permanecen en sus tareas de origen.
Al concluir, se mueven al par y sus campos de origen se vacían antes de
liberar cada handle. El par sigue las reglas de propiedad y movimiento
parcial de un struct. La cancelación destruye las tareas pendientes y
los resultados aún almacenados mediante la purga iterativa del planificador.


### Grupos de handles

Un grupo local posee el prefijo inicializado de una lista de handles.
`push` mueve el handle al siguiente elemento y el crecimiento traslada
el buffer según las reglas de listas. El análisis impide obtener un
alias al grupo o extraer un handle individual. `joinAll` lo mueve a una
ranura del padre, que lo conserva hasta terminar o cancelar. Tras
completarse todas las hijas, cada resultado se mueve desde su estado
y se limpia el origen. Cancelar antes de entregar el grupo destruye
los resultados que siguen en las hijas y cancela las pendientes.

### Cancelación de temporizadores

Una entrada del heap referencia un registro de tarea que sigue vivo.
El vencimiento retira la entrada antes de encolar la tarea. La
cancelación retira la entrada o desenlaza el wake ya encolado antes
de liberar o reciclar el registro. El turno de purga sigue siendo
monohilo e iterativo. [Temporizadores](TIMER_RUNTIME.md).


## 16. Disponibilidad de lugares en Stage 1

El CFG semántico de Stage 1 combina estados de disponibilidad por
ruta antes de comprobar cada acceso. Las proyecciones anidadas
usan identidades de campo y no punteros a nodos. La liveness de
préstamos y el plan de drops ya usan esos datos.
[Invariantes de rutas y estados](STAGE1_CFG.md).

## 17. Préstamos en Stage 1

Un préstamo es un sitio sintáctico con lugar, padre (représtamo) y
orígenes alternativos. Su vida es no léxica: termina tras el último uso
alcanzable. Dos préstamos solapados no conviven si uno es mutable, y un
propietario no se escribe ni se mueve mientras un préstamo solapado
vive. Un binding de referencia no puede sobrevivir a su propietario en
el subconjunto, y un retorno prestado debe tener procedencia exclusiva
de parámetros. [Invariantes](STAGE1_BORROW_CHECKER.md#invariantes).

## 18. Plan de drops en Stage 1

Cada hoja propietaria (`Text`, `List`, arrays, enums y campos de struct
que los contienen) se destruye una sola vez, en la arista que abandona
su ámbito, si todavía la posee la función. Si el CFG no permite decidirlo
estáticamente, un flag guarda «posee un valor». Un verificador
independiente rechaza dobles drops, drops de valores movidos o no
inicializados, fugas por sobrescritura o al salir y flags incoherentes.
[Invariantes](STAGE1_DROP_ELABORATION.md#verificador).

## 19. Drops en la LIR de Stage 1

El plan de drops llega a la LIR como instrucciones `drop`/`dropfield`,
condicionadas por variables `Bool` cuando hacen falta flags. El backend
vuelve a verificar con `drops::verify` que no haya uso tras movimiento,
doble liberación ni fugas. [Detalle](STAGE1_LIR.md#drops-y-ownership).

## Alcance de la verificación de fase 8.2

Las pruebas nuevas rechazan métodos mutantes sobre un receptor inmutable y la suite conserva los casos de borrow, drops y heap. Los benchmarks MSVC de fase 8.2 mostraron `allocs == frees` y `file_opens == file_closes`; esas trazas no demuestran ausencia general de errores de memoria. Listas y variantes nuevas del LIR siguen sin validación vertical completa. [Estado y mediciones](STAGE1_SELF_COVERAGE.md).

## Memoria de listas en Stage 1, fase 8.3

La ruta nativa usa la cabecera de 24 bytes `(ptr,len,cap)`. `FLOW_MUTATE` permite mutación in situ sin soltar la lista. Las pruebas diferenciales con `List<Text>` y `List<FlowBlock>` y el harness propio comprueban trazas equilibradas. `heap_ok=1` solo cubre los recorridos ensayados. [Alcance](PHASE_8_3.md).
