# NEXO PFS: contrato de plataforma y modelo adversarial

Este documento delimita qué parte de PFS01--PFS12 procede de contratos
publicados y qué parte es una simulación conservadora. No afirma que las
pruebas provoquen un fallo parcial real del kernel. El backend PFS divide un
rango en páginas para explorar resultados adversariales reproducibles que la
API de producción debe contener sin exponer memoria ni recuperar capacidades.

Fuentes primarias consultadas el 13 de noviembre de 2026:

- Microsoft Learn: [`VirtualAlloc`](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualalloc),
  [`VirtualProtect`](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualprotect),
  [`VirtualFree`](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualfree)
  y [estados de página](https://learn.microsoft.com/en-us/windows/win32/memory/page-state).
- Linux man-pages: [`mmap`/`munmap`](https://man7.org/linux/man-pages/man2/mmap.2.html),
  [`mprotect`](https://man7.org/linux/man-pages/man2/mprotect.2.html) y
  [`madvise`](https://man7.org/linux/man-pages/man2/madvise.2.html).
- POSIX.1-2017, reproducido por Linux man-pages:
  [`mprotect(3p)`](https://man7.org/linux/man-pages/man3/mprotect.3p.html).

## Distinciones que debe conservar la API

| Resultado | Significado para NEXO | Acción permitida |
|---|---|---|
| Completado | La operación nativa informó éxito y el rango queda en el estado solicitado. | Publicar el nuevo estado. |
| Rechazado sin modificación conocida | El inyector detuvo la llamada antes de tocar páginas. Este resultado es del harness; no se infiere automáticamente de cualquier error nativo. | Conservar el estado anterior. |
| Completado con respuesta de error | El backend de prueba cambió todo el rango y devolvió error para comprobar que el código no confía solo en el valor de retorno. | Poner todo el rango en cuarentena hasta reconciliarlo. |
| Parcialmente aplicado | El backend cambió un subconjunto conocido de páginas y devolvió error. | Poner todo el rango afectado en cuarentena; no publicar el prefijo como utilizable. |
| Estado desconocido | No existe evidencia suficiente para reconstruir el estado físico página por página a partir de la respuesta. | Bloquear lectura, escritura, asignación y reutilización hasta reconciliar cada página. |

`Rechazado` no es sinónimo general de “la syscall devolvió error”. Solo puede
usarse cuando lo garantiza el inyector previo o un contrato de plataforma
aplicable a ese caso de error. La clasificación conservadora de cualquier otro
error es parcial o desconocida.

## Windows x86-64

### Reserva y compromiso

NEXO reserva con `VirtualAlloc(MEM_RESERVE, PAGE_NOACCESS)`. Microsoft define
una página reservada como inaccesible y sin almacenamiento físico asociado. Al
comprometer con `MEM_COMMIT`, el rango completo debe pertenecer a una reserva;
la documentación indica que si el estado del rango no es compatible, la llamada
falla y no asigna ninguna página. Volver a comprometer una página ya
comprometida está permitido. Un éxito garantiza contenido inicial cero cuando
la página se accede por primera vez.

Esa garantía de “ninguna página asignada” corresponde al caso de
incompatibilidad de estado documentado. El modelo PFS conserva
`CompletedWithError`, `Partial` y `Unknown` como pruebas de robustez y no los
presenta como comportamiento observado de `VirtualAlloc` en Windows.

### Protección

`VirtualProtect(PAGE_NOACCESS)` requiere que todas las páginas estén
comprometidas. Microsoft garantiza expresamente que, si alguna no lo está, la
función falla sin modificar la protección de ninguna página del rango. Ese
caso puede clasificarse como rechazo conocido. La página debe pertenecer a la
misma reserva y la operación afecta páginas completas.

La documentación no formula una garantía equivalente para cada causa posible
de fallo. Por eso NEXO no extrapola el caso de página no comprometida a un
teorema general de atomicidad de `VirtualProtect`; el backend parcial sigue
siendo una simulación adversarial.

### Descompromiso y liberación

`VirtualFree(MEM_DECOMMIT)` devuelve páginas comprometidas al estado reservado,
que es inaccesible, y acepta rangos que mezclan páginas comprometidas y ya
descomprometidas. `VirtualFree(MEM_RELEASE)` exige la base original, tamaño cero
y libera la reserva completa; también acepta la mezcla de páginas reservadas y
comprometidas. En éxito, `MEM_RELEASE` deja las páginas libres.

Microsoft documenta el estado posterior al éxito y los requisitos que producen
fallo, pero las páginas consultadas no ofrecen una afirmación general de
atomicidad ante toda causa de fallo. NEXO mantiene el dueño tras un error de
`release`, no marca la reserva como liberada y permite reintentar. El backend
PFS puede modelar incertidumbre, pero no afirma haber observado un
`MEM_DECOMMIT` o `MEM_RELEASE` parcial real.

## Linux x86-64

### Reserva

NEXO crea un mapping privado anónimo con `mmap(PROT_NONE)`, sin `MAP_FIXED`, y
recorta prefijo y sufijo con `munmap` para obtener alineación. `mmap` devuelve
una dirección en éxito o `MAP_FAILED` con `errno` en error. `PROT_NONE` impide
todo acceso conforme a POSIX.

La reserva alineada de NEXO consta de varias llamadas, por lo que su limpieza
ante un fallo de recorte es un protocolo de biblioteca y no una única operación
atómica del kernel. Cada mapping todavía vivo debe conservar un dueño hasta que
un `munmap` exitoso lo elimine.

### Compromiso, reconfirmación y protección

En Linux, “commit” y “recommit” de NEXO son
`mprotect(PROT_READ | PROT_WRITE)`; proteger es `mprotect(PROT_NONE)`. El
contrato POSIX es decisivo: si `mprotect` falla por una razón distinta de
`EINVAL`, **algunas páginas del rango pueden haber cambiado de protección**.
Linux además documenta errores `ENOMEM` por páginas no mapeadas o por no poder
crear las regiones de atributos necesarias.

Por tanto, en Linux no es correcto tratar todo `-1` de `mprotect` como rechazo
sin cambios. El rango completo debe quedar en cuarentena y reconciliarse por
página antes de exponerlo. La simulación “cuatro de ocho páginas” es una prueba
adversarial del permiso POSIX; no es una reproducción de un fallo real concreto.

### Descarte

NEXO descarta en dos pasos: primero `mprotect(PROT_NONE)` y después
`madvise(MADV_DONTNEED)`. El orden es obligatorio para su propiedad de
inaccesibilidad: tras un `MADV_DONTNEED` exitoso sobre un mapping privado
anónimo, un acceso posterior puede completarse con una página de ceros; el
consejo por sí solo no retira permisos.

Linux documenta además un resultado parcialmente aplicado: si algunas partes
del rango no están mapeadas, `madvise` las ignora, aplica la operación al resto
y devuelve `ENOMEM`. Aunque los rangos válidos producidos por NEXO no deberían
contener agujeros, este contrato impide inferir “sin cambios” de todo error. Un
fallo después de la protección conserva el rango inaccesible, pero el backing
puede ser conocido, descartado parcialmente o desconocido; la cuarentena debe
representar esa diferencia hasta `repair()`.

### Liberación

`munmap` devuelve cero en éxito y elimina todas las páginas que intersectan el
rango; los accesos posteriores son inválidos. Devuelve `-1` con `errno` en
fallo. La documentación Linux consultada no promete de forma general el estado
del mapping tras cualquier fallo. NEXO llama `munmap` con la base y longitud
exactas que conserva como dueño, no publica punteros crudos y solo marca la
reserva como liberada tras éxito.

Linux no considera error que el rango incluya páginas ya no mapeadas. Esto hace
que un reintento del rango completo sea una estrategia conservadora útil, pero
no convierte a `Drop` en una garantía: si el kernel rechaza persistentemente la
operación, Rust no dispone de un canal para devolver el error desde el
destructor. Después de un error real de liberación, NEXO marca la reserva
`ReleaseUncertain`: conserva el dueño para reintentar, pero bloquea commit,
protección, acceso, reparación y publicación de capacidades porque el mapping
podría no seguir íntegro.

## Consecuencias para PFS y `repair()`

1. Toda operación multipágina que informe un resultado parcial o ambiguo pone
   en cuarentena el rango completo, incluso cuando se conoce el prefijo que
   cambió.
2. `page_access` no basta para autorizar uso si existe una marca de cuarentena;
   lectura, escritura, asignación y reutilización deben rechazarla.
3. La reconciliación trabaja página por página. Una página accesible se protege;
   una página reservada, descartada o desconocida se reconfirma antes de
   protegerla. Solo después se puede intentar nuevamente el descarte.
4. Si la reconciliación vuelve a fallar, las páginas no verificadas siguen en
   cuarentena. El progreso parcial interno no devuelve permisos ni capacidades.
5. Ni una generación antigua, ni un `Handle`, ni un `HoleToken` consumido se
   recrean a partir del estado físico. La autoridad lógica permanece fuera del
   rango incierto.
6. Un cierre explícito exitoso puede eliminar una reserva con páginas en
   cuarentena porque no vuelve a exponerlas. Un error previo a la llamada
   conserva el estado; un resultado ambiguo de `release` conserva el dueño pero
   lo sella en `ReleaseUncertain`, observable y reintentable solo mediante
   cierre.

## Alcance de la evidencia

Las pruebas PFS validan la máquina de estados y la recuperación frente a un
backend adversarial determinista. Las pruebas Windows/MSVC ejercitan las APIs
reales en sus rutas normales y las transiciones PFS simuladas. Las pruebas
Linux ejecutadas dentro de WSL2 ejercitan un kernel Linux y glibc/musl según la
corrida, pero siguen compartiendo el host Windows y no sustituyen una ejecución
en un host Linux independiente.

Queda fuera de esta evidencia:

- haber provocado un fallo parcial real de `VirtualAlloc`, `VirtualProtect`,
  `VirtualFree`, `mprotect`, `madvise` o `munmap`;
- demostrar el comportamiento de kernels, arquitecturas o versiones no
  ejecutadas;
- demostrar que un kernel arbitrariamente defectuoso respeta su contrato;
- garantizar desde `Drop` la liberación ante un rechazo persistente del SO.

La cuota agotada de GitHub Actions no cambia estas conclusiones. Un job con
cero pasos ejecutados no aporta evidencia positiva ni negativa de compilación.
