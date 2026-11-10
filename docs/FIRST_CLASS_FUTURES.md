# Futures de Primera Clase y Async Composable en Proyecto L

## 1. Visión General

Este hito convierte a `Future<T>` en una abstracción de primera clase en Proyecto L. Previamente, los futuros estaban estrictamente restringidos al sitio de llamada de una función async o a un operando inmediato de `await`/`spawn`. A partir de este incremento:

1. Los futuros pueden almacenarse en variables locales (`let fut: Future<T> = ...`).
2. Se pueden mover entre variables conservando la semántica de propiedad única (*Single Ownership* / *Adaptive Ownership*).
3. Se pueden pasar como parámetros a funciones sincrónicas y asincrónicas.
4. Se pueden retornar desde funciones sincrónicas con anotación de tipo explícita (`-> Future<T>`).
5. Se pueden componer de forma dinámica (e.g. selección condicional entre diferentes funciones async que devuelven el mismo tipo `T`).
6. Se pueden consumir mediante `await` o transferirse al planificador cooperativo mediante `spawn fut`.
7. Se integran limpiamente con `TaskGroup<T>` vía `tg.spawn(fut)` y `tg.push(spawn fut)`.
8. Si se descartan sin consumir (futuros abandonados o no sondeados), sus destructores limpian deterministamente los recursos capturados y liberan la memoria reservada sin fugas.

---

## 2. Layout Binario y Estabilidad de Offsets

Todo futuro en Proyecto L se representa en tiempo de ejecución como un puntero de 8 bytes a una estructura asignada en el heap que encapsula la máquina de estados generada para la función asíncrona.

Para permitir polimorfismo dinámico y despacho uniforme sin coste de monomorfización en los consumidores, todas las máquinas de estado de los futuros comparten un encabezado autocontenido y determinista:

| Campo | Offset | Tipo | Propósito |
|---|---|---|---|
| `tipo` (`KIND_FIELD`) | 0 | `Int` (i64) | Discriminante / índice en `module.futures` del tipo concreto de futuro |
| `reanudar` (`RESUME_FIELD`) | 8 | `Int` (i64) | Punto de suspensión actual (-1 al finalizar) |
| `resultado` (`RESULT_FIELD`) | 16 | `T` | Ranura donde la máquina de estados deposita el valor producido |
| Parámetros / Locales | 24+ | Variables | Estado capturado de la función async |

### Garantía de Estabilidad de Offset
Dado que los campos 0 y 1 son siempre enteros de 64 bits (8 bytes c/u, alineación 8), el campo 2 (`resultado`) comienza **exactamente en el byte 16** para cualquier futuro cuyo tipo de resultado sea `T`. Esto permite que una función que recibe un `Future<T>` abstracto pueda acceder al resultado en el offset 16 tras completarse el sondeo, sin importar qué función asíncrona concreta lo construyó.

---

## 3. Despacho Dinámico Universal en Cranelift

El compilador genera dos tablas de salto en código máquina en el backend nativo Cranelift:
1. `rt.poll_dispatch`: Recibe `(kind, state)` y salta a la función `poll` correspondiente al discriminante `kind`.
2. `rt.drop_dispatch`: Recibe `(kind, state)` y salta a la rutina de limpieza / destrucción correspondiente a `kind`.

### Operaciones Nativas:
- **`Rvalue::FuturePoll(place)`**:
  Carga el puntero `state = *place`, lee `kind = *(i64*)state` en el offset 0 e invoca `rt.poll_dispatch(kind, state)`. Devuelve `0` (Pending) o `1` (Ready).
- **Destrucción de `Type::Future`**:
  Carga el puntero `ptr = *place`. Si es distinto de nulo, lee `kind = *(i64*)ptr`, invoca `rt.drop_dispatch(kind, ptr)` para liberar los recursos vivos capturados y finalmente libera el bloque de estado con `l_rt_free(ptr)`.
- **`Rvalue::TaskSpawn(op, _)`**:
  Carga `state` del operando, lee `kind = *(i64*)state` e invoca `rt.task_spawn(state, kind)`, transfiriendo la propiedad de la máquina de estados al ejecutor cooperativo.

---

## 4. Backend de Referencia (`backend.rs`)

En el backend de referencia en Rust, `Future<T>` se proyecta a:
```rust
pub type LFuture<T> = std::pin::Pin<Box<dyn std::future::Future<Output = T>>>;
```
Las llamadas a funciones asíncronas son empaquetadas automáticamente en `Box::pin(f{id}(...))`, lo que permite que cualquier función que retorne o reciba `Future<T>` funcione transparentemente con la semántica de `.await` y `l_spawn` de Rust sin desajustes de tipos.

---

## 5. Reglas de Tipado, Ownership y Diagnósticos

1. **Single Ownership**:
   `Future<T>` es un tipo no-`Copy` sujeto a movimiento lineal.
   - Un segundo `await` sobre la misma variable se rechaza estáticamente con `L0005: valor movido`.
   - Un segundo `spawn` sobre la misma variable se rechaza con `L0005`.
   - El uso tras transferencia (`let f2 = f1; await f1;`) se rechaza con `L0005`.

2. **Incompatibilidad con Préstamos**:
   Los futuros poseen recursos exclusivos de ejecución y no admiten referencias compartidas ni mutables (`&f` o `&mut f`). Se rechaza con `L0012: Future no admite préstamos`.

3. **Restricción de Agregación**:
   Los futuros no pueden almacenarse en structs, enums, arrays ni listas dinámicas. Se rechaza con `L0015: Future no se puede almacenar en un agregado ni colecciones`.

4. **Retorno Explícito Requerido**:
   Para evitar fugas de tipos anónimos no nombrables en las interfaces de funciones, retornar un futuro desde una función requiere anotación de tipo explícita `-> Future<T>`. Retornar un futuro desde una función con tipo inferido se rechaza con `L0015`.

5. **Diferenciación con `TaskHandle<T>`**:
   `Future<T>` representa un cálculo diferido perezoso (iniciado solo al sondearse).
   `TaskHandle<T>` representa una tarea en segundo plano registrada y gestionada por el scheduler. `TaskHandle<T>` permanece confinado a su función creadora y no puede ser retornado ni almacenado arbitrariamente.

## Temporizadores como futures

`sleepMs(ms)` devuelve un `Future<()>` que puede moverse, retornarse con
una firma explícita, esperarse o transferirse a `spawn`. El registro
empieza al sondear. Descartar un futuro sin sondear libera su estado
sin registrar un plazo. [Temporizadores](TIMER_RUNTIME.md).
