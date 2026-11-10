# Temporizadores monotónicos

```l
async fn main() {
    print("Inicio")
    await sleepMs(1000)
    print("Un segundo después")
}
```

`sleepMs(Int) -> Future<()>` toma milisegundos. La especificación v1.0
carece de un tipo `Duration`. El plazo empieza en el primer sondeo.
Cero completa en el mismo sondeo y un futuro descartado sin sondear
carece de registro. El rango es de 0 a 922337203685477 ms. Una constante
fuera de rango produce `L0015`. Los valores dinámicos se validan al
construir el future y producen un panic localizado si son inválidos.
El deadline interno comprueba la multiplicación de unidades por el
límite del argumento y comprueba la suma antes de registrar la tarea.

## Reloj y espera en Windows

Cranelift usa `QueryUnbiasedInterruptTimePrecise` para leer ticks
monotónicos de 100 ns de tiempo activo del sistema. El reloj excluye
los estados de bajo consumo y los ajustes de hora de calendario.
Los programas nativos con temporizadores requieren Windows 10 o
Windows Server 2016 y la biblioteca de importación `mincore.lib`
del SDK. El resto de los programas conserva su enlace habitual.
[Microsoft Learn, reloj monotónico](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-queryunbiasedinterrupttimeprecise)

Cuando la cola FIFO queda vacía, el ejecutor arma un único temporizador
reutilizable de Windows con un plazo relativo y espera su señal mediante
`WaitForSingleObject`. Intenta crear un temporizador de alta resolución
y recurre al temporizador normal si esa opción falla. La espera relativa
de Windows moderno excluye los estados de bajo consumo. La unidad de
100 ns permite representar el plazo. La resolución del sistema y la
planificación determinan cuándo vuelve a ejecutarse el proceso.
El reloj se vuelve a comprobar tras la señal antes de despertar tareas.
[Microsoft Learn, creación](https://learn.microsoft.com/windows/win32/api/synchapi/nf-synchapi-createwaitabletimerexw), [plazo relativo](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-setwaitabletimer)

El backend de referencia usa `Instant`, `BTreeSet` y
`std::thread::sleep` únicamente cuando no hay trabajo listo. La
comparación diferencial cubre un sistema activo. El comportamiento
al suspender o hibernar el sistema anfitrión no forma parte de esas
pruebas.

## Registro, notificación y cancelación

El heap mínimo guarda punteros a registros de tarea estables. Cada
registro temporizado tiene un deadline y un índice inverso. El índice
cero significa que no está registrado. Insertar, vencer y retirar
un temporizador cuestan O(log n) y consultar el próximo cuesta O(1).
El heap conserva su buffer durante la ejecución y lo libera al
terminar el ejecutor. El registro nativo pasa de 72 a 88 bytes solo
en programas que usan temporizadores.

El ejecutor procesa vencimientos entre sondeos, incluso con tareas
listas. El proceso de vencimiento quita el registro antes de llamar
al wake idempotente. Cuando la cola FIFO tiene trabajo, el ejecutor
lo ejecuta sin aparcarse. Para deadlines exactamente iguales, el orden
entre las tareas que vencen a la vez queda sin especificar.

Cada tarea del scheduler puede tener un único temporizador activo.
La evaluación directa de futures es secuencial dentro de esa tarea.
`spawn` crea una tarea distinta. `join` y `joinAll` esperan esas tareas
hijas, cada una con su registro. Al cancelar, se retira el temporizador
antes de destruir el estado o reciclar el identificador. Si la tarea
ya estaba lista por vencimiento, la purga existente la desenlaza de
la cola. La referencia usa la misma barrera antes de liberar su ID.
El contador de temporizadores solo registra entradas activas.

## ABI y efectos

El frontend emite un builtin async perezoso. El CFG distingue la
validación de duración, el registro y la comprobación de pendiente.
Cranelift llama al ABI interno `l_rt_timer_*`. Las llamadas a Windows,
la cola de deadlines y su cancelación viven en
`crates/l/src/native/timers.rs`. El registro puede crecer y fallar,
por lo que se conservan los efectos `alloc` y `panic`. Aparcar el
ejecutor sin tareas listas no añade el efecto `block` al future.

La cola, su índice inverso y el despacho de vencimientos son candidatos
a migrarse a L. La capa de reloj y espera puede conservar el mismo
contrato ABI detrás de FFI. Una fuente de eventos posterior puede
notificar mediante la cola de listas sin reentrar en el sondeo.
El hito actual expone temporizadores del sistema. Quedan pendientes
los wakers externos concurrentes y una API pública de deadline o timeout.

## Reproducción

Ejecute `cargo test --test timers` para materializar las cargas de
cancelación y cola activa y comparar ambos backends. Después ejecute
`cargo build --bin l` y `pwsh -File bench/timers.ps1 -Runs 7`.
La traza registra altas, vencimientos, cancelaciones, esperas del
ejecutor y máximo de temporizadores simultáneos. Las muestras de
latencia son intervalos entre líneas de salida observadas desde el
proceso de medición. Incluyen despacho y salida de texto.

## Resultados medidos

Windows 10 (build 19044), siete ejecuciones por carga y backend. La
tabla muestra medianas. El tiempo de compilación corresponde a una
compilación por caso. La memoria es el pico de memoria residente
observado mientras el proceso estaba activo.

| Carga | Backend | Compilación (ms) | Tiempo real (ms) | CPU (ms) | Pico (KiB) |
| --- | --- | ---: | ---: | ---: | ---: |
| 11 110 temporizadores | Cranelift | 477,4 | 109,5 | 15,6 | 4 448 |
| 11 110 temporizadores | Referencia | 1 412,1 | 138,9 | 78,1 | 6 400 |
| 100 esperas de 5 ms | Cranelift | 329,9 | 657,2 | 0,0 | 2 272 |
| 100 esperas de 5 ms | Referencia | 844,7 | 646,9 | 15,6 | 3 020 |
| 10 000 cancelaciones | Cranelift | 345,8 | 74,0 | 15,6 | 5 364 |
| 10 000 cancelaciones | Referencia | 970,5 | 108,3 | 78,1 | 7 476 |
| Vencimiento con cola activa | Cranelift | 343,8 | 61,0 | 15,6 | 2 256 |
| Vencimiento con cola activa | Referencia | 886,0 | 70,4 | 31,3 | 3 324 |

En las 700 muestras por backend, los percentiles p50, p95 y p99 de
las esperas de 5 ms fueron 5,94, 8,81 y 14,56 ms en Cranelift y
5,84, 9,77 y 13,92 ms en referencia. Windows contabilizó una mediana
de 0,0 ms de CPU en la carga de espera nativa, con la granularidad de
su contador. La carga nativa procesó alrededor de 101 000 temporizadores
por segundo de extremo a extremo. Las mediciones incluyen arranque,
trabajo del scheduler y salida, y no aíslan el costo de registro,
notificación o cancelación.

En Cranelift, la carga registró y despertó 11 110 temporizadores, con
33 345 reservas y 33 345 liberaciones. En la cancelación masiva hubo
10 001 registros, 10 000 retiros y un vencimiento, con 40 009 reservas
y 40 009 liberaciones. La cola activa registró un vencimiento y cero
esperas del ejecutor. El heap terminó válido en los tres casos.
Estas comprobaciones usan la instrumentación interna. No se ejecutó
un sanitizador de memoria.
