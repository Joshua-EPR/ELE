# Concurrencia estructurada y TaskGroup en Proyecto L

Estado: implementado y probado en ambos backends (Cranelift nativo y rustc de referencia)
en la rama `dev/native-scoped-taskgroups`.

## 1. Visión general y garantías

Proyecto L adopta el modelo de **concurrencia estructurada** para la ejecución de tareas
asíncronas concurrentes. A diferencia del modelo de tareas huérfanas o *detached* (como
`go` en Go o `tokio::spawn` sin un `JoinSet` confinado), en Proyecto L:

1. **Jerarquía y pertenencia estricta**: Toda tarea hija pertenece a un grupo propietario
   (`TaskGroup`) o a un `TaskHandle<T>` unívoco.
2. **Ciclo de vida acotado al ámbito (Scope Confinement)**: Un `TaskGroup` queda
   estrictamente vinculado al ámbito léxico de la función `async` donde fue instanciado.
   Ninguna tarea puede sobrevivir al ámbito de su grupo.
3. **No duplicación de propiedad**: Ni `TaskHandle<T>` ni `TaskGroup<T>` implementan semántica
   `Copy`. Mover un grupo o handle invalida la variable origen (`L0005: uso de valor después de moverlo`).
4. **Cancelación iterativa y drop determinista**: Si el ámbito de un `TaskGroup` termina sin
   haber consumido el grupo con `await grupo.joinAll()` (por ejemplo, debido a un `return` anticipado,
   `break`, o salida de bloque), el destructor (*drop glue*) cancela iterativamente todas las tareas
   hijas vivas y libera el búfer dinámico sin fugas de memoria (`allocs == frees`, `heap_ok == 1`).
5. **Tipado homogéneo y seguro**: Las tareas agregadas a un grupo comparten el mismo tipo de retorno
   `T`, permitiendo recolectar los resultados en un `List<T>` fuertemente tipado.

---

## 2. Modelo formal: `TaskGroup<T, Scope>`

Conceptualmente, el sistema de tipos modela un grupo de tareas como:

```text
TaskGroup<T, Scope>
```

Donde:
- `T`: tipo del resultado producido por las tareas hijas del grupo.
- `Scope`: identidad estática del ámbito léxico (función o bloque async) donde fue creado el grupo.
  Esta identidad es inferida y verificada por el compilador en `sema.rs`, impidiendo falsificaciones
  o escapes.

### Invariantes del sistema de tipos (Sema y Ownership)

- **Creación exclusiva en contexto async**: `taskGroup<T>()` solo puede invocarse dentro de una
  función declarada `async` (código `L0015`).
- **Prohibición de paso como parámetro o retorno**: `TaskGroup` no puede figurar en la lista de
  parámetros ni en el tipo de retorno de ninguna función (`L0015`).
- **Prohibición de almacenamiento en agregados o colecciones**: `TaskGroup` no puede ser campo de
  `struct`, variante de `enum`, ni elemento de `List` o arrays (`L0015`).
- **Prohibición de préstamos**: No se permite crear referencias compartidas `&grupo` ni exclusivas
  `&mut grupo` (`L0012: TaskGroup no admite préstamos (& o &mut)`). El grupo se opera exclusivamente
  por valor o mediante mutación in-situ sobre la variable local declarada con `var`.
- **Confinamiento léxico (No-Escape)**: Asignar un `TaskGroup` creado en un sub-ámbito (por ejemplo,
  dentro de un `if` o bucle) a una variable de un ámbito exterior queda rechazado con `L0015`
  (*"el grupo de tareas no puede escapar a un ámbito más amplio"*).
- **Consumo único**: `await grupo.joinAll()` consume la propiedad del grupo. Reutilizar el grupo
  o volver a esperar produce `L0005` (*"uso de valor después de moverlo"*).

---

## 3. Sintaxis y API

### Creación de un grupo

```l
// Constructor canónico con tipo explícito
var grupo = taskGroup<Int>()

// Anotación opcional de tipo
var grupoTipado: TaskGroup<Text> = taskGroup<Text>()

// Constructor histórico con inferencia a partir de función async (retrocompatibilidad)
var grupoCompat = taskGroup(miFuncionAsync)
```

### Métodos del grupo

1. **`grupo.reserve(capacidad: Int)`**:
   Preasigna capacidad en el búfer interno de handles para evitar realocaciones intermedias
   durante lotes de gran escala.
2. **`grupo.spawn(llamadaAsync)`**:
   Registra y encola directamente la llamada asíncrona en el scheduler y almacena su handle en el grupo.
   Comprueba que el tipo de retorno coincida con `T`.
3. **`grupo.push(spawn llamadaAsync)`**:
   Permite insertar un `TaskHandle<T>` recién instanciado en el grupo.
4. **`await grupo.joinAll()`** (o `await joinAll(grupo)`):
   Suspende la tarea padre hasta que todas las tareas hijas del grupo hayan finalizado. Retorna un
   `List<T>` con los resultados en el orden exacto en que fueron insertados. Debe ser consumido
   obligatoriamente con `await`.

---

## 4. Representación física y backend nativo (Cranelift)

En la representación intermedia de bajo nivel (LIR y CFG):
- `Type::TaskGroup(usize)` indexa una definición en la tabla `program.task_groups`, registrando
  el tipo de elemento `elem` y el identificador de ámbito `scope`.
- **Layout en memoria**: comparte la representación de 24 bytes `(ptr, len, cap)` de `List` en Windows x86-64.
  Cada elemento del búfer contiene un puntero de 8 bytes a la estructura de 72 bytes de tarea del scheduler.
- **Drop Glue (`task_group_drop_glue`)**:
  En el backend Cranelift, la destrucción de un `TaskGroup` ejecuta una rutina especializada:
  1. Lee el puntero `ptr` y la longitud `len` del búfer.
  2. Si `ptr != 0`, itera `i` desde `0` hasta `len - 1`.
  3. Carga el puntero de la tarea `task = *(ptr + i * 8)`.
  4. Llama a `l_rt_task_cancel(task)` en el runtime nativo para cancelar la tarea y liberar sus recursos
     asociados si aún no había finalizado.
  5. Llama a `l_rt_free(ptr)` para liberar la memoria del búfer.

---

## 5. Pruebas y rendimiento verificado

La suite de integración en `crates/l/tests/spawn.rs` valida:
- Sintaxis canónica y métodos `spawn`, `push`, `reserve` y `joinAll`.
- Tipos compuestos como resultado: `TaskGroup<Punto>`, `TaskGroup<Text>`, `TaskGroup<Float>`, `TaskGroup<Option<Int>>`.
- Supervivencia de grupos a través de puntos de suspensión intermedia (`await yieldNow()`).
- Grupos anidados y composición jerárquica.
- Cancelación limpia y destrucción en retornos tempranos y salidas de ámbito (`allocs == frees`, `heap_ok == 1`).
- Escalabilidad masiva: ejecución de lotes de hasta 10 000 tareas en Cranelift nativo sin fugas de memoria.
- Matriz completa de diagnósticos negativos de rechazo de escape y de violación de ownership (`L0015`, `L0012`, `L0005`, `L0001`).

## Hijas temporizadas

Las hijas que esperan un `sleepMs` conservan las reglas de propiedad de
`TaskGroup`. Destruir el grupo quita los temporizadores pendientes antes
de liberar los registros. `joinAll` sobre hijas con resultados
propietarios conserva el orden de inserción. [Temporizadores](TIMER_RUNTIME.md).
