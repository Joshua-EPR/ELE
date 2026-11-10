# Runtime de tareas: ejecutor cooperativo, notificaciones e instrumentación

Complemento de [ASYNC_MODEL.md](ASYNC_MODEL.md) (semántica y máquina de estados)
y de [BACKEND.md](BACKEND.md) (generación de código). Describe lo implementado
en `dev/native-async-foundation` (una tarea) y `dev/native-spawn-structured`
(planificador multitarea) y `dev/async-owned-aggregates` (ranuras propietarias).

## 1. Representación en memoria (backend nativo)

- Un `Future<T>` es **un puntero** (8 bytes, alineación 8) al bloque de estado de
  su tarea.
- El bloque es una reserva del heap del proceso, **a cero**, con el layout del
  struct `f$estado` (ASYNC_MODEL §3). Vive mientras viva el manejador, así que su
  dirección es estable mientras la tarea está suspendida: ninguna estructura
  autorreferencial se mueve.
- Tamaño del bloque = tamaño del struct de estado: 8 bytes de `reanudar`, el
  resultado, los parámetros, los locales guardados y un campo por tipo de future
  esperado. Cada ranura propietaria usa una etiqueta de ocho bytes
  seguida de su carga con la alineación del tipo. `Text` ocupa 32 bytes
  en una ranura en Windows x64. No hay cabecera de runtime, vtable ni contador de referencias.
- El manejador se guarda en memoria (un stack slot) en la función que lo posee,
  para que su destructor pueda ejecutarse en su sitio.

Un `TaskHandle<T>` es también **un puntero** (8 bytes), pero al *registro* de la
tarea en el planificador, no a su estado. El registro son 72 bytes del heap que
no se mueven nunca, así que el handle sigue siendo válido mientras la tarea
exista:

| Campo | Qué contiene |
|---|---|
| `estado` | Puntero al bloque de estado de la tarea; `0` tras liberarlo |
| `tipo` | Índice del tipo de future: selecciona su `poll` y su destructor |
| `situación` | Lista / suspendida / terminada / cancelada |
| `siguiente`, `anterior` | Enlaces intrusivos de la cola FIFO de tareas listas |
| `esperador` | Registro de la tarea que espera su resultado, o `0` |
| `pendientes del grupo` | Hijas registradas que todavía no terminaron, o `0` |
| `en_cola` | 1 mientras el registro está en la cola de listas |
| `purga` | Enlace de la lista de registros pendientes de destruir |

El registro **no** es el estado: el planificador posee el estado (lo recibió del
future que `spawn` consumió) y el handle posee el registro. Separarlos es lo que
permite destruir un handle mientras el registro aún está en la cola: el registro
sale de la cola y se libera, y el estado se destruye por separado.

## 2. Operaciones del runtime

Dos primitivas de la LIR de bloques, verificadas antes del codegen, que el
backend nativo traduce a dos funciones del runtime generado en Cranelift IR:

| LIR | Runtime | Contrato |
|---|---|---|
| `Wake` | `l_rt_wake()` | Marca la tarea en curso como lista para volver a sondearse |
| `TaskSpawn(f, tipo)` | `l_rt_task_spawn(estado, tipo)` | Registra la tarea en la cola de listas y devuelve su handle |
| `TaskReady(h)` | `l_rt_task_ready(registro)` | `1` si ya terminó; si no, anota la tarea en curso como su esperador |
| `TaskState(h)` | `l_rt_task_state(registro)` | Estado de la tarea, para tomar su resultado |
| Destruir un handle | `l_rt_task_cancel(registro)` | Cancela: libera el estado (en cascada) y el registro |
| `RunTasks` | `l_rt_run()` | El planificador, hasta que no quede ninguna tarea lista |

## 3. El planificador cooperativo

Un hilo, una **cola FIFO** de tareas listas (round-robin cooperativo) y una
cuenta de tareas suspendidas. `l_rt_run()`:

```text
bucle:
  t = sacar de la cabeza de la cola
  si no hay ninguna:
      si suspendidas > 0 -> informar interbloqueo y abortar
      si no -> volver
  t.en_cola = 0
  actual = t
  st = poll(t.tipo, t.estado)         // despacho por tipo de future
  actual = 0
  si st == 1:                         // terminada
      t.situación = terminada
      notificar a t.esperador (si coordina un grupo, decrementar su contador)
  si no:                              // suspendida
      suspends += 1
      si t.en_cola (se notificó a sí misma) -> continuar
      si no -> t.situación = suspendida; suspendidas += 1
```

**Política de planificación: FIFO / round-robin cooperativo.** Una tarea que
cede el turno (`yieldNow`) vuelve al final de la cola, así que todas las listas
avanzan un paso antes de que cualquiera dé el segundo. Es lo que comprueban las
pruebas de traza: con tres tareas de tres pasos la salida es `1 0, 2 0, 3 0,
1 1, 2 1, …`, no una tarea tras otra. No hay robo de trabajo ni prioridades.

Reglas que el planificador garantiza:

1. Una tarea lista siempre acaba sondeándose: la cola es FIFO y nada la adelanta
   indefinidamente.
2. Una tarea suspendida **no se sondea sin notificación**. No hay busy waiting:
   el bucle no gira sobre tareas pendientes, solo saca de la cola de listas.
3. Una tarea terminada no se vuelve a ejecutar (`situación = terminada`, y su
   estado se libera en cuanto se toma el resultado).
4. Una tarea cancelada no se reanuda ni queda en el planificador: si estaba en
   la cola, sale de ella al cancelarse (la cola es doblemente enlazada, así que
   cuesta O(1)) y su registro se libera ahí mismo. La cola nunca guarda un
   puntero inválido y una tarea cancelada no ocupa memoria hasta el siguiente
   turno del planificador.
5. Mientras una tarea está suspendida, las demás progresan: ahí está la
   concurrencia.

### Notificaciones

- `l_rt_wake(t)` hace lista a `t` y la encola al final. Es **idempotente**: una
  notificación a una tarea ya encolada, terminada o cancelada no hace nada, así
  que ni se pierde una notificación ni se encola dos veces el mismo registro.
- `yieldNow()` notifica a la tarea en curso y devuelve `Pending`: una suspensión
  real que pide ser reanudada después, no una espera.
- `await handle` anota la tarea en curso como `esperador` del registro; al
  terminar, la tarea notifica a su esperador. `join` aplica la misma consulta
  a dos registros antes de decidir si devuelve Pending. Es la única notificación entre
  tareas.
- Si no quedan tareas listas, el ejecutor comprueba los plazos
  registrados. Declara interbloqueo únicamente si quedan tareas
  suspendidas y ninguna fuente puede producir una notificación.

### Cancelación iterativa

Destruir el estado de una tarea destruye los handles que poseía, lo que cancela
sus tareas, y así en cascada. Hacerlo recursivamente costaba una trama de pila
por nivel y desbordaba la pila con árboles profundos (comprobado con 60 000
niveles). Por eso `l_rt_task_cancel` mantiene una bandera de cancelación en
curso y una lista de registros pendientes de destruir: la primera llamada
procesa el suyo y luego vacía la lista en bucle, y las llamadas anidadas solo
añaden a la lista. El coste de pila es constante a cualquier profundidad.

## 4. Punto de entrada de `async fn main()`

El punto de entrada es una función de la LIR de bloques generada por el
compilador (`main$ejecutor`), no código escrito a mano en el runtime:

```text
f = main()                       // construye el estado de la tarea raíz
t = TaskSpawn(f)                 // el planificador pasa a poseer el estado
RunTasks                         // planifica hasta que no quede nada listo
drop(t)                          // destruye el handle de la raíz
return ()
```

La tarea de `main` no es especial: es la primera de la cola. No se crea ningún
hilo del sistema operativo; las tareas y el planificador comparten el hilo
principal.

El despacho `poll(tipo, estado)` lo genera el backend (`Gen::dispatch`) cuando ya
conoce las funciones de cada tipo de future, de modo que el planificador no
guarda punteros a función en los registros y todas sus llamadas son directas.

## 5. Planificador del backend de referencia (rustc)

El backend rustc transpila a Rust y **reutiliza los futures de Rust**, cuya
semántica es la misma que la de L (perezosos, basados en `poll`, cooperativos):
`async fn` emite `async fn`, `await` emite `.await`. El prelude generado
(`backend/async_runtime.inc.rs`) aporta el equivalente del runtime nativo:

- `LTask<T>`: el equivalente de `TaskHandle<T>`: un future que produce el
  resultado de la tarea y cuyo `Drop` la cancela.
- `l_spawn(future)`: registra la tarea en la cola de listas y devuelve su handle.
- `LYield`: un future que devuelve `Pending` una vez, notificando antes.
- `l_run()`: el mismo bucle FIFO, con las mismas reglas de notificación,
  cancelación iterativa e informe de interbloqueo.
- `l_run_main(future)`: registra la tarea raíz, planifica y destruye su handle.

Así las dos implementaciones son comparables en pruebas diferenciales: misma
salida, mismo stderr y mismo estado de salida. La máquina de estados propia (la
del backend nativo) es la implementación de referencia **del lenguaje**; el
backend rustc es el espejo con el que se verifica.

## 6. Instrumentación

`--trace-alloc` añade al informe de salida un contador de suspensiones reales:

```text
l-alloc: allocs=4 reallocs=0 frees=4 region_allocs=0 region_bytes=0 region_retired=0 suspends=2 heap_ok=1
```

- `suspends` cuenta los sondeos que devolvieron `Pending`. Es la prueba de que
  la suspensión es real y no un cuerpo ejecutado de corrido: las pruebas lo
  comprueban (`suspends == 0` sin `yieldNow`, `== 2` en el ejemplo de `spawn`,
  `== 10` en el intercalado de tres tareas de tres pasos, …).
- `allocs`/`frees` incluyen el estado y el registro de cada tarea; las pruebas
  exigen `allocs == frees` y `heap_ok=1`, con validación de cada liberación,
  también en las rutas de cancelación.
- `--alloc-fail-after N` hace fallar la reserva `N + 1`, lo que permite probar la
  ruta de memoria insuficiente al construir una tarea: la salida previa se
  conserva y el programa termina con el panic limpio de siempre.

Contadores equilibrados son evidencia de las rutas que ejercitan los programas de
prueba, no una demostración de ausencia de fugas en general.

## 7. Costes medidos

- `async_{create,ready,suspend}_1m.l`: construir y destruir futures sin
  sondearlos, construir y consumir futures listos al primer sondeo, y
  suspender/reanudar, un millón de veces cada uno.
- `spawn_cancel_1m.l`: `spawn` más cancelación antes de empezar (coste de
  registrar y destruir una tarea).
- `spawn_await_1m.l`: ciclo de vida completo de un millón de tareas: `spawn`,
  planificación, suspensión, notificación, reanudación, resultado y liberación.
- `spawn_interleave_100k.l`: 100 000 tareas vivas a la vez, intercaladas por la
  cola de listas.

Resultados reproducibles en [../bench/results.md](../bench/results.md)
(`bench/run.ps1`), con reservas por tarea y suspensiones por programa.

## 8. Pendiente

- Esperar N handles con una colección propietaria de ámbito (`joinAll`),
  y una política distinta de FIFO si
  alguna carga lo justifica.
- Notificación desde fuera de las tareas (E/S, temporizadores): hoy las únicas
  fuentes son `yieldNow()` y el fin de una tarea esperada.
- Futures en pila cuando el compilador pueda demostrar que no escapan.
- Multihilo, robo de trabajo y cualquier forma de paralelismo (fuera de alcance).


## Propietarios y cancelación

El planificador conserva el protocolo iterativo de destrucción. En una
tarea sin sondear, el destructor puede encontrar parámetros propietarios
instalados por el constructor. En una tarea pendiente también puede
encontrar locales ocupados. Cada etiqueta vacía omite la carga. Cuando la
etiqueta está ocupada, se reutiliza el destructor normal del tipo. Un
struct libera sus campos restantes y un enum usa su discriminante. Un
array recorre sus elementos y una lista libera sus elementos vivos y su
buffer. Los subárboles movidos tienen el patrón vacío para el destructor.
Una tarea cancelada sale de la cola y no se vuelve a sondear.


## Join y registro de esperadores

Cada hija sigue teniendo un único esperador porque un handle tiene un
único dueño. El mismo padre puede figurar en dos registros. Una hija
lista responde a la consulta sin volver a sondearse. Una hija pendiente
registra al padre. Al completar, se borra el esperador y se intenta
despertarlo. Dos notificaciones antes del siguiente sondeo comparten una
sola entrada FIFO. La comprobación conjunta y la suspensión se ejecutan
en el mismo turno del planificador.

El padre conserva ambos handles durante Pending y mueve ambos resultados
solo cuando estén listos. La destrucción del estado pasa los handles a
la cancelación existente. La purga iterativa elimina los esperadores y
desenlaza los registros listos antes de continuar el planificador, por
lo que las hijas de una coordinación cancelada no pueden volver a
ejecutarse. La coordinación binaria usa el mismo registro que los grupos dinámicos.


## Grupos y contador de pendientes

El registro nativo agrega un contador de ocho bytes. `GroupRegister`
recorre el buffer de handles una vez en el turno del padre, omite
hijas listas y registra al padre en cada hija pendiente. El contador
se instala antes de devolver Pending. Cada finalización retira su
esperador y decrementa el contador del padre si está coordinando
un grupo. Solo la transición de uno a cero encola al padre. Un
`GroupPending` al reanudar lee el contador en O(1). Los grupos
mantienen una única espera activa por tarea, igual que los demás
puntos de suspensión. La inscripción y la recolección son O(n)
y cada notificación cuesta O(1).

Los resultados listos permanecen inicializados en los estados de las
hijas. El padre extrae la lista de su ranura etiquetada cuando el
contador llega a cero. Reserva la salida, mueve cada resultado y
vacía su origen. La longitud de salida delimita el prefijo
inicializado. Después se libera la lista de handles. Durante
cancelación, la lista puede poseer una mezcla de hijas pendientes
y listas y su destructor usa la purga iterativa existente.

La reutilización de identificadores sigue confinada al planificador.
En Cranelift los registros son estables mientras un handle los posee.
En rustc los huecos se devuelven a la lista libre. La purga retira los
esperadores de las hijas antes de que el planificador vuelva a sondear
o se pueda crear otra tarea. Durante la purga solo se ejecutan
destructores generados y cancelaciones. La estrategia depende de
ese turno indivisible y de que no existan wakers externos.

## Fuente de notificación de temporizadores

El scheduler procesa expiraciones entre sondeos. Cuando la cola FIFO
está vacía y hay un deadline, espera una señal del temporizador del
sistema. El heap indexado conserva las tareas temporizadas y la purga
retira cada entrada antes de liberar el registro. Véase
[TIMER_RUNTIME.md](TIMER_RUNTIME.md) para la ABI, efectos y mediciones.
