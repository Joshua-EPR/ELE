# Modelo de asincronía de Proyecto L: futures, máquina de estados y suspensión

Estado: implementado y probado en ambos backends. Primer incremento (futures,
máquina de estados, suspensión) en `dev/native-async-foundation`; segundo
(`spawn`, `TaskHandle<T>`, planificador multitarea) en
`dev/native-spawn-structured`. El incremento de propietarios en
`dev/async-owned-aggregates` se describe en §8, la coordinación de tareas en §9 y §10,
los futures de primera clase en §11 (`dev/first-class-futures`), y las expresiones
generales de `await` con lowering ANF seguro en §13 (`dev/general-await-expressions`).
El runtime y el ejecutor están en
[FUTURE_RUNTIME.md](FUTURE_RUNTIME.md); los invariantes de memoria en
[MEMORY_MODEL.md](MEMORY_MODEL.md).

## 1. Sintaxis y tipos

```l
async fn obtenerNumero() -> Int {
    return 42
}

async fn main() {
    let resultado = await obtenerNumero()

    print(resultado)
}
```

- `async fn f(params) -> T` declara una función asíncrona. **Llamarla no ejecuta
  nada**: construye una tarea (un *future*) y devuelve su manejador.
- El tipo del resultado de la llamada es `Future<T>`, una abstracción de primera clase
  que representa una computación asíncrona diferida. Se puede anotar explícitamente,
  guardar en variables, mover, pasar como parámetro a funciones y retornar (con firma explícita).
  No se puede prestar (`&Future<T>` está prohibido) ni almacenar en agregados o colecciones.
- `await e` sondea el future `e` hasta que esté listo, suspendiendo la función
  async que lo espera mientras siga pendiente, y produce su resultado. Puede aplicarse
  tanto a una llamada directa `await f()` como a un future almacenado en una variable `await fut`.
- `spawn f(args)` registra la llamada async como **tarea independiente** del
  planificador y devuelve un `TaskHandle<T>` que la posee (§7). Solo dentro de
  una función async.
- `yieldNow()` es la primitiva de suspensión integrada: una función async
  predefinida que devuelve `Pending` exactamente una vez, notificando a la tarea
  de inmediato, y queda lista en el siguiente sondeo. Sirve para ceder el turno
  y para comprobar en pruebas que la suspensión es real.
- Una función async **no infiere** su resultado: sin `-> T` su resultado es `()`.
- `async fn main()` es válido: su tarea es la raíz que el planificador registra
  y ejecuta.

### Dónde puede aparecer `await`

Desde `dev/general-await-expressions`, `await` funciona como una **expresión general**
dentro de funciones `async fn`. Puede componerse libremente en cualquier posición de expresión:

```l
let total = (await f()) + 10                 // operaciones aritméticas
if (await validar()) > 0 { ... }             // condiciones y comparaciones
let ok = await paso1() && await paso2()      // operadores lógicos con cortocircuito
let res = sumar(await a(), await b())        // argumentos de funciones
return (await computar()) * 2                // expresiones de retorno
let punto = Punto { x: await posX(), y: 0 }  // literales de estructuras
while await continuar() { ... }              // condiciones de bucles
let val = (await obtener())?                 // operador de propagación Try
let opt = (await buscar()) ?? porDefecto     // operador de coalescencia
```

El compilador aplica una transformación ANF (*A-Normal Form*) controlada en el front-end
(`async_desugar.rs`), garantizando orden de evaluación estricto de izquierda a derecha y
promoviendo los temporales que deban sobrevivir a una suspensión a variables locales del frame
asíncrono (`f$estado.lN`), protegidos por Single Ownership y flags de drop deterministas.

**Restricciones estrictas**:
- Prohibido fuera de funciones `async fn` (rechazado con `L0015: await solo es válido dentro de funciones async`).
- Prohibido en declaraciones `const` globales o locales (rechazado con `L0015`).
- Prohibido el doble await de un mismo future por Single Ownership (rechazado con `L0005`).
- Prohibido await sobre expresiones que no producen un `Future<T>` o `TaskHandle<T>` (rechazado con `L0003`).

## 2. Ciclo de vida de una tarea

Estados observables de un future (en el campo `reanudar` de su estado):

| Estado | `reanudar` | Qué contiene |
|---|---|---|
| Creado | `0` | Los argumentos; el cuerpo no ha empezado |
| Suspendido | `k > 0` | Los valores guardados y el future que espera |
| Terminado | `-1` | El resultado, hasta que alguien lo consuma |
| Consumido / destruido | — | El bloque se liberó; el manejador ya no existe |

- `poll` devuelve `1` (listo) o `0` (pendiente). Progresa **solo** cuando se
  sondea: no hay hilos ni ejecución en segundo plano.
- `await` consume el future: mueve su resultado y libera su estado. Un segundo
  `await` sobre el mismo manejador es un uso tras movimiento (`L0005`).
- Un future terminado **nunca** se vuelve a sondear: su manejador se libera en
  cuanto se toma el resultado. El despacho de `poll` trata `reanudar = -1` como
  inalcanzable por construcción.
- Destruir un future es la forma de cancelación de este incremento (§5).

## 3. Transformación a máquina de estados

Cada `async fn f` se convierte, en la LIR de bloques, en **tres funciones**
verificadas como cualquier otra (tipos, asignación definida, propiedad) antes de
generar código:

| Función | Firma | Qué hace |
|---|---|---|
| `f` (el índice que llaman los programas) | `f(args) -> Future<T>` | Reserva el estado, guarda los argumentos, devuelve el manejador |
| `f$poll` | `poll(estado: &mut Estado) -> Int` | Reanuda el cuerpo donde quedó y lo ejecuta hasta terminar o suspender |
| `f$drop` | `drop(estado: &mut Estado)` | Libera lo que el estado aún posee |

El estado es un struct sintético `f$estado`:

```text
campo 0  reanudar: Int        punto de reanudación
campo 1  resultado: T         válido solo cuando reanudar = -1
campo 2+ p0, p1, …            parámetros
         l<id>, i<id>, n<id>  locales guardados y contador/límite de cada for
         f<índice>            el future que se está esperando (uno por tipo)
```

`f$poll` tiene esta forma:

```text
entrada:  restaura los parámetros desde el estado
          según reanudar: 1 -> reanudar_1, 2 -> reanudar_2, …, 0 -> inicio
inicio:   <cuerpo>
en cada await:
          estado.f<i> = future            (el estado pasa a poseerlo)
  sondeo: st = g$poll(&mut estado.f<i>)
          si st == 1 -> listo, si no -> suspender
suspender: guarda escalares, libera los propietarios del marco de poll,
           estado.reanudar = k, return 0 (Pending)
reanudar_k: restaura los locales guardados y vuelve a sondeo
  listo:  valor = mover estado.f<i>.resultado; limpiar ese campo;
          ejecutar g$drop y liberar el bloque; limpiar estado.f<i>
en cada return:
          estado.resultado = v; estado.reanudar = -1; return 1 (Ready)
```

`yieldNow` usa la misma maquinaria sin future al que esperar: guarda, notifica
(`wake`) y devuelve `Pending`; al reanudar continúa.

### Qué se guarda y qué no

- Se guardan en el estado los valores **que no poseen recursos**: `Int`,
  `Float`, `f32`, `Bool`, `()`. Copiarlos es siempre correcto.
- Los parámetros se restauran al principio de cada `poll` (son inmutables, así
  que ninguna suspensión necesita volver a guardarlos).
- Un `for i in a..b` guarda su contador, su límite y su variable, de modo que un
  `await` dentro del cuerpo reanuda en la iteración correcta.
- Los locales propietarios admitidos y los `TaskHandle<T>` viven en el estado. Los demás
  propietarios del marco se liberan al devolver `Pending`.

## 4. Propiedad y seguridad durante la suspensión

Reglas verificadas estáticamente (`L0015 [async]`), antes de generar código:

1. **Parámetros**. La llamada mueve `Text`, structs, enums, arrays y listas
   admitidos al estado. Los escalares se copian. Se rechazan modos de
   préstamo y tipos ligados a una región.
2. **Locales con recursos**. Los mismos tipos propietarios pueden seguir
   vivos, junto con los handles. Los tipos compuestos se admiten
   recursivamente si sus componentes son escalares o propietarios
   admitidos. Los propietarios no admitidos se liberan al suspender y su
   uso posterior se rechaza con `L0015`.
3. **Regiones**: no se puede suspender con una región abierta. La cabecera de la
   región vive en el marco de la llamada a `poll`, que termina al suspender.
4. **`for x in colección`**: no se puede suspender dentro del cuerpo; el
   recorrido mantiene la colección prestada durante todo el bucle. Se recorre con
   índices y `while` si hace falta suspender.
5. **Referencias y vistas**: no cruzan una suspensión (apuntan al marco de la
   llamada a `poll`). Siguen siendo de segunda clase (MEMORY_MODEL §2).
6. **Futures y handles**: se crean, se mueven entre locales y se consumen con
   `await` en la misma función. Los handles pueden integrarse en un grupo
   local (§10). El almacenamiento en otros agregados, los retornos y
   los argumentos siguen restringidos.
7. **Estado de los propietarios**. Un handle vacío usa un puntero nulo.
   Cada ranura propietaria usa una variante vacía u ocupada. El destructor consulta la
   etiqueta, y el verificador prueba que toda lectura alcanza una ranura
   ocupada incluso después de reanudar (§8).

## 5. Drops y cancelación

El destructor del estado (`f$drop`) libera **todos** los campos que poseen algo,
sin consultar el punto de reanudación. Es correcto porque el bloque se reserva a
cero y **el patrón de ceros no posee nada** en ningún tipo de L (un `Text` con
capacidad 0 es estático, una lista con capacidad 0 no tiene buffer, un manejador
nulo no tiene tarea). Después de mover un valor fuera del estado, el campo se
pone a cero explícitamente (`Clear`), así que nunca se libera dos veces.

Destruir un manejador (fin de scope, retorno anticipado, reasignación) ejecuta el
destructor del estado y libera el bloque. Según el estado:

| Momento | Qué se libera |
|---|---|
| Antes del primer sondeo | El bloque y sus parámetros propietarios |
| Suspendido | Las ranuras propietarias ocupadas, el objeto esperado y los handles que poseía, en cascada |
| Terminado sin consumir | El resultado |
| Después de consumir | Nada: el resultado ya se movió y el campo se limpió |

Esta es la cancelación disponible: **destruir un manejador pendiente**, sea un
future o un `TaskHandle`. No hay terminación forzosa de tareas arbitrarias ni
API de cancelación: una tarea solo deja de existir en un punto en el que el
runtime no la está ejecutando. `panic` sigue siendo abort sin desenrollado, así
que no ejecuta destructores.

Garantías de la cancelación, en las rutas soportadas:

- Una tarea cancelada **no vuelve a ejecutarse**: sale de la cola del
  planificador y su registro se libera en el momento de cancelarla.
- Se libera lo que su estado todavía poseía, **nada que ya se hubiera movido**
  (el campo movido vale cero) y **nada dos veces**.
- Cancelar una tarea **no afecta a las demás**: las tareas son independientes y
  ningún registro queda referenciado desde la cola ni desde un `waiter` (quien
  esperaba su resultado solo puede ser quien tenía su handle, es decir quien la
  está cancelando).

## 6. Efectos

| Operación | Efectos |
|---|---|
| Llamar a una función async (crear el future) | `alloc` + `panic` (reserva del estado; puede faltar memoria) |
| `spawn f(args)` | `alloc` + `panic` (estado y registro de la tarea) **y los efectos del cuerpo**: registrar la tarea compromete su ejecución |
| `await f` | Los efectos de la función que sondea, más los de crear el future |
| Suspenderse / `yieldNow()` | Ninguno: la suspensión cooperativa no bloquea un hilo ni reserva |
| `poll` de un future ya listo | Los del cuerpo que ejecuta |

Crear un future **no** hereda los efectos de ejecutarlo: solo los de su
construcción. Los hereda el `await`, que es quien lo ejecuta. Como el estado de
la tarea está en el heap, `@noalloc` no puede crear futures: no se ocultan
reservas dentro del runtime para que el contrato parezca cumplirse.

```l
@noalloc async fn malo() -> Int {
    let v = await otro()   // L0010: crear el future reserva memoria
    return v
}
```

## 7. Tareas: `spawn`, `TaskHandle<T>` y concurrencia estructurada

```l
async fn calcular(numero: Int) -> Int {
    await yieldNow()
    return numero * 2
}

async fn main() {
    let primera = spawn calcular(10)
    let segunda = spawn calcular(20)

    let a = await primera
    let b = await segunda

    print(a + b)              // 60
}
```

`spawn f(args)` construye el future como una llamada normal y **lo entrega al
planificador**, que pasa a poseer su estado. El resultado es un
`TaskHandle<T>`: un tipo opaco, propio de cada función async (como su
`Future<T>`), de 8 bytes, propietario y no copiable.

| Operación sobre un handle | Qué hace |
|---|---|
| `let t = spawn f(x)` | Registra la tarea, lista para sondearse; nada se ha ejecutado aún |
| `let v = await t` | Consume el handle: suspende hasta que la tarea termine y produce su resultado |
| Fin de scope, `return`, `break` | Destruye el handle: **cancela** la tarea |
| Mover a otro local | Transfiere la propiedad; el origen ya no se puede usar (`L0005`) |

### Política de concurrencia estructurada

1. **Una tarea pertenece al scope async que la creó.** `spawn` solo es válido
   dentro de una función async; el handle no se puede nombrar en una anotación,
   almacenar en un agregado, pasar como argumento ni devolver (`L0015`, y la
   misma regla cierra ese hueco para los futures). Por tanto **no existen tareas
   desatendidas**: el único camino por el que una tarea sobrevive a su creador
   no existe.
2. **Un handle se consume una sola vez.** `await` lo mueve; un segundo `await`,
   o leerlo tras moverlo, es `L0005`.
3. **Destruir un handle pendiente cancela su tarea** (§5). No hay operación
   explícita de cancelación ni transferencia de propiedad a nadie más.
4. **Terminar el scope destruye los handles vivos**, también en un retorno
   anticipado o un `break`, y cancela sus tareas.
5. **La cancelación baja en cascada**: destruir el estado de una tarea destruye
   los handles que ese estado poseía, así que cancelar la raíz de un árbol
   cancela el árbol. La cascada es iterativa (FUTURE_RUNTIME §3), así que la
   profundidad del árbol no cuesta pila.

### Un handle a través de una suspensión

`let a = await primera` puede suspender mientras `segunda` sigue viva. El
segundo handle vive en el estado. Moverlo pone el puntero a cero y destruir
su ranura cancela la tarea si aún está presente.

## 8. Ranuras propietarias e inicialización por reanudación

El estado tiene una ranura por parámetro propietario y por local explícito
de un tipo admitido. El constructor transfiere los argumentos por valor
al estado. Una ranura usa un enum interno monomorfizado por tipo con
`Empty = 0` y `Full(T) = 1`. Las ranuras locales empiezan vacías. La etiqueta
ocupa ocho bytes y reutiliza el layout y destructor de enums.

Mover todo el valor lee la carga y vacía la etiqueta. Mover un campo de
struct conserva la etiqueta y pone a cero el subárbol movido. Este patrón
representa ausencia de recursos para los tipos admitidos. Reasignar libera
lo que aún quede en el destino y después escribe el nuevo valor. Fin de
ámbito, `return`, `?`, `break` y `continue` limpian los ámbitos que abandonan.

El verificador propaga inicialización definida desde el constructor por
aristas normales y aristas lógicas `Suspend(destino)`. El índice escrito
debe despachar al destino lógico. La etiqueta y los subárboles de struct
tienen estados independientes de vacío, lleno o incierto. Los caminos se
dividen en subárboles en función de los movimientos y escrituras que
aparecen en el CFG. La lectura de un valor completo exige que todos los
subárboles que abarca estén inicializados. Un `poll` listo exige que todas
sus ranuras propietarias se hayan vaciado.

Los enums y las colecciones se rastrean como unidades de propiedad. Un
acceso directo a un payload persistente requiere una prueba de variante activa
que siga siendo válida tras las uniones y escrituras del CFG. Un
`match` que mueve un payload transfiere el enum completo a un temporal
del brazo correspondiente. Los payloads extraídos se ponen a cero y el
destructor usa el discriminante para liberar los restantes. Acceder a un
elemento o reemplazarlo conserva la propiedad de la colección. El crecimiento
de `List<T>` y los drops de elementos usan el runtime ya existente.

La selección de ranuras conserva los propietarios hasta movimiento,
reasignación o fin de ámbito. El análisis de temporales de `poll` sigue
viendo cada reanudación como una llamada nueva. Se permiten préstamos
formados y usados dentro de un sondeo, con las reglas normales de aliasing.

## 9. Esperar dos tareas con join

```l
async fn calcular(n: Int) -> Int {
    await yieldNow()
    return n * 2
}

async fn main() {
    let a = spawn calcular(10)
    let b = spawn calcular(20)
    let resultados = await join(a, b)
    print(resultados.first)
    print(resultados.second)
}
```

`await join(a, b)` mueve dos handles al estado del padre. Evalúa sus
argumentos de izquierda a derecha. Cada sondeo consulta ambas tareas y
registra al padre como esperador de cada una que siga pendiente. Si una
finaliza primero, el padre puede despertar y volver a comprobar el par.
El cuerpo que sigue al `await` solo continúa cuando ambos resultados
están listos. Las hijas completadas conservan sus resultados hasta la
transferencia o cancelación.

El resultado es un struct inferido con `first` y `second`, en orden de
argumentos. Los tipos pueden ser distintos. Los campos obedecen las reglas
normales de movimiento y drop. El nombre diagnóstico `JoinPair<A, B>`
describe el tipo interno. La primera versión usa inferencia y carece de
sintaxis para anotar o construir ese tipo directamente.

`join` es una operación directa bajo `await` en las posiciones de
sentencia ya admitidas. Los handles siguen confinados a su función
creadora. Al cancelar al padre, las ranuras liberan ambos handles, lo
que cancela hijas pendientes y destruye resultados listos sin consumir.

## 10. Grupos dinámicos y joinAll

`await joinAll(tareas)` mueve una lista de handles del mismo tipo de
resultado. Sus funciones productoras pueden ser distintas. Devuelve
`List<T>` en el orden de inserción. Un grupo vacío o ya completado se
entrega en el mismo sondeo. Si quedan hijas pendientes, el padre se
suspende y la última finalización lo notifica.

```l
async fn calcular(n: Int) -> Int {
    await yieldNow()
    return n * 2
}

async fn main() {
    var tareas = taskGroup(calcular)
    for i in 1..4 {
        tareas.push(spawn calcular(i * 10))
    }
    let resultados = await joinAll(tareas)
    for resultado in resultados {
        print(resultado)
    }
}
```

También se puede inferir un grupo con `List[spawn calcular(10), ...]`.
El nuevo `taskGroup<T>()` o `taskGroup(calcular)` crea un grupo con tipo formal
`TaskGroup<T>`, confinado estrictamente a su ámbito léxico. Admite
`.reserve(n)`, `.spawn(llamadaAsync)`, `.push(spawn ...)` y `await grupo.joinAll()`.
Al abandonar su ámbito se cancelan iterativamente las hijas que todavía posea.
El grupo no se presta, no se indexa, no se extrae con `pop`, no se pasa a funciones
ni se almacena en otros agregados.
Véase la documentación detallada en [STRUCTURED_CONCURRENCY.md](STRUCTURED_CONCURRENCY.md).

## 11. Futures de primera clase y composición

Desde el hito `dev/first-class-futures`, `Future<T>` es una abstracción de primera clase:

- **Almacenamiento en variables**:
  ```l
  let fut: Future<Int> = calcular(10)
  var f = calcular(20)
  ```
- **Paso a funciones**:
  ```l
  fn envolver(fut: Future<Int>) -> Future<Int> {
      return fut
  }
  async fn ejecutar(fut: Future<Int>) -> Int {
      return await fut
  }
  ```
- **Retorno explícito**:
  Toda función que devuelva un future debe anotar formalmente `-> Future<T>` en su firma.
- **Composición y selección dinámica**:
  ```l
  let fut = if condicion { calcular(10) } else { calcular(20) }
  let res = await fut
  ```
- **Transferencia a concurrencia estructurada**:
  Un future se puede transferir a una tarea en segundo plano mediante `spawn fut` o
  añadirse a un grupo estructurado con `tg.push(spawn fut)`.
- **Single Ownership y seguridad**:
  - No implementa `Copy`: mover un future invalida el origen (`L0005`).
  - No admite doble consumo: `await fut` seguido de `await fut` se rechaza en compilación (`L0005`).
  - No admite préstamos: `&Future<T>` o `&mut Future<T>` se rechaza con `L0012`.
  - No puede almacenarse en colecciones o agregados (`struct`, `enum`, `List`, `Array` rechazado con `L0015`).
  - Destrucción segura: si un future se abandona sin sondear o a medio ejecutar, su destructor
    libera dinámicamente sus campos propietarios y la memoria del estado (`allocs == frees`, cero fugas).
  - Véase la documentación técnica completa en [FIRST_CLASS_FUTURES.md](FIRST_CLASS_FUTURES.md).

## 12. Limitaciones de este incremento

- Sin métodos async, traits async ni funciones async genéricas.
- Los handles (`TaskHandle<T>`) y grupos (`TaskGroup<T>`) siguen confinados a su función o ámbito creador;
  los futures (`Future<T>`) sí pueden transferirse entre funciones con single ownership.
- Ni futures ni handles pueden almacenarse en agregados (`struct`, `enum`, `List`, `Array`).
- Las referencias, vistas, tipos de región y tipos propietarios recursivos
  siguen fuera de las ranuras de suspensión. Suspender durante un recorrido prestado
  de colección sigue rechazado. Los elementos se pueden acceder por índice
  en sondeos separados.
- Sin API de cancelación explícita ni colecciones de handles fuera del grupo local. Tampoco hay tareas
  desatendidas y sin pasar handles entre tareas.
- Un future por tarea en el heap: no hay futures en pila ni fusión de estados.
  Es la decisión que mantiene direcciones estables mientras la tarea está
  suspendida (DECISIONS 103).
- Sin E/S asíncrona ni sockets. El ejecutor admite plazos de `sleepMs`.
- Panic = abort, sin desenrollado ni drops (como en el resto del lenguaje).
- Solo Windows x86-64 en el backend nativo.

## 13. Await como expresión general y Lowering ANF (dev/general-await-expressions)

El hito `dev/general-await-expressions` elimina la limitación histórica de `await`
restringido a sentencias aisladas:

1. **Lowering ANF (`crates/l/src/async_desugar.rs`)**:
   - Transforma el cuerpo de toda función `async fn` antes del typechecking (`sema.rs`) y CFG.
   - Detecta de forma determinista cualquier subexpresión compuesta que contenga `await`.
   - Extrae operandos no triviales previos a la suspensión en bindings `let __l_await_tmp_{N} = ...`,
     preservando estrictamente el orden de evaluación de izquierda a derecha.
   - Preserva el cortocircuito en operadores lógicos booleanos (`&&`, `||`) transformando
     la evaluación condicional mediante variables acumuladoras mutables.
   - Desazucara bucles `while await cond()` en `loop { let c = await cond(); if !c { break } ... }`
     para re-evaluar la condición en cada iteración.
2. **Ciclo de vida y drops en suspensión**:
   - Cada temporal extraído se registra como variable local estándar en LIR y CFG.
   - Los tipos propietarios (`Text`, structs, `List`) reciben ranuras `$async_slot` con drop flags
     deterministas en el heap (`f$estado.lN`), garantizando su supervivencia a través de suspensiones
     y su liberación automática si la tarea se cancela.
3. **Paridad total y validación**:
   - 317 pruebas pasando al 100% (11 pruebas dedicadas en `tests/await_expr.rs`).
   - Cero fugas de memoria (`heap_ok=1`, `allocs == frees`).
   - Salidas idénticas entre Cranelift y `rustc`.

### Temporizadores

`await sleepMs(ms)` suspende la tarea hasta un plazo monotónico.
`sleepMs(0)` completa en el mismo sondeo. Las tareas listas pueden
avanzar durante una espera. El scheduler solo se aparca si se vacía
su cola y queda un deadline. Véase [TIMER_RUNTIME.md](TIMER_RUNTIME.md).
