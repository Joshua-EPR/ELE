# NEXO v0.3 — preparación del port a ELE

NEXO físico sigue siendo una herramienta Rust de investigación. No está
conectado a Stage 0, Stage 1, ELE-LIR de producción, ABI, ownership ni drops de
programas ELE.

## Representación y layout

Un pool reserva un rango estable de `max_superpages × 64 KiB`, alineado a
64 KiB. Cada superpágina contiene:

| Offset | Tamaño | Contenido |
|---:|---:|---|
| 0 | 3.840 B | 960 generaciones `u32` little-endian |
| 3.840 | 120 B | 15 bitmaps libres `u64` |
| 3.960 | 120 B | 15 bitmaps de huecos `u64` |
| 4.080 | 15 B | ocupación por subpágina `u8` |
| 4.095 | 1 B | libre/reservado |
| 4.096 | 60 KiB | 15 subpáginas de datos de 4 KiB |

Los slots nunca cruzan una subpágina. Una celda física ocupa ocho bytes sin
tag: un `Int` son los bits little-endian de `i64`; un enlace es
`slot:u32 | generation:u32 << 32`. El esquema de clase determina cómo se
interpreta cada campo. El `enum Palabra` de Rust pertenece al oráculo y no es
la representación física.

Las generaciones pares son libres, las impares vivas y `0xFFFF_FFFE` retira el
slot para siempre. Un hueco es un bit reservado y una capacidad lineal; no es
sinónimo de slot libre.

## ABI nativa temporal

El port necesita primitivas internas, no sintaxis pública nueva:

- consultar tamaño de página y granularidad de reserva;
- reservar/liberar rango virtual alineado y estable;
- confirmar páginas como lectura/escritura;
- hacer páginas inaccesibles;
- devolver backing físico sin perder la reserva;
- obtener código de error del SO;
- aritmética de direcciones y tamaños con overflow comprobado;
- copiar ocho bytes hacia/desde memoria cuya capacidad haya sido validada.

Windows usa hoy `VirtualAlloc`, `VirtualProtect`, `VirtualFree` y
`GetSystemInfo`. Linux usa `mmap`, `mprotect`, `madvise`, `munmap` y `sysconf`.
No se usa `MAP_FIXED`. Linux sobre-reserva, alinea y libera prefijo/sufijo.

La reclamación es un protocolo por pasos con estado físico registrado tras
cada éxito (`Reserved/Accessible/Protected/Discarded`): Linux protege antes de
`madvise`; Windows desconfirma en un solo `VirtualFree(MEM_DECOMMIT)`. El port
debe conservar ese protocolo, el estado lógico `ReclaimPending` y la regla de
que un error solo puede devolverse antes de consumir una capacidad (y entonces
devuelve la capacidad).

## API de capacidades (v0.3 corregida)

| Rust | Papel | Equivalente ELE previsto |
|---|---|---|
| `Handle` | dueño; no `Copy`/`Clone`; `destroy` lo consume | `dueño<T>` lineal |
| `ObjRef` | acceso no propietario, validado por generación en cada uso | préstamo tras `revalidar` |
| `Link` | enlace copiable sin acceso | `Enlace<P,T>` |
| `HoleToken` | capacidad lineal de hueco | `hueco<P,s>` |
| `DestroyReport` / `ReleaseReport` | efecto lógico consumido + estado de reclaim y espejo | resultado de `destruir` en ELE-LIR |

La API Rust no expresa las reglas de préstamo de NEXO-Core (exclusividad,
no-escape): siguen siendo responsabilidad del verificador. El pool solo
garantiza dinámicamente que ningún acceso alcanza un objeto muerto ni memoria
no accesible.

## Dependencias Rust que deben desaparecer

- FFI y tipos de `std` para las llamadas anteriores.
- `Vec`, `Option` y arrays usados como índice auxiliar.
- `AtomicU64` usado como nonce temporal de pool.
- `Drop` como red de limpieza de la reserva.
- ejecutores de tests, fuzzer y benchmark de Cargo.

La futura implementación necesita capacidades ELE que expresen que una
reserva tiene un único dueño y que un token de hueco se consume exactamente
una vez. Ninguna referencia ELE debe sobrevivir a decommit/reclaim.

## Requisitos faltantes en ELE/ELE-LIR

Antes del port hacen falta, como operaciones internas verificadas:

1. enteros/direcciones nativos y conversiones sin pérdida;
2. operaciones checked de suma, producto y alineación;
3. carga/almacenamiento little-endian de `u8/u32/u64` con alineación conocida;
4. llamadas de sistema específicas de plataforma con errores controlados;
5. tipo opaco de reserva y prueba de pertenencia de un rango;
6. capacidades lineales para reserva, pool, handle vivo y hueco;
7. barrera que impida formar referencias a una página revocable;
8. cleanup en todas las salidas, incluido error;
9. selección condicional de plataforma en el runtime bootstrap;
10. harness capaz de ejecutar el mismo rastro contra oráculo y backend.

Añadir estas operaciones futuras no autoriza a relajar el verificador, los
drops ni el protocolo ELE-LIR 1. Su diseño y revisión son trabajo separado.

## Migración gradual

1. Congelar layout, relación de abstracción e invariantes I1–I11.
2. Mantener el oráculo Rust y portar primero solo el wrapper de memoria virtual
   a un módulo ELE aislado.
3. Ejecutar F01–F20 y rastros diferenciales cruzados contra ambas capas.
4. Portar cabecera, generaciones y bitmaps sin exponer punteros.
5. Portar huecos y reclaim; repetir fallos inyectados y fuzzing.
6. Sustituir el oráculo Rust por un ejecutable ELE independiente solo cuando
   la autocobertura necesaria exista.
7. Proponer integración al runtime real en otro cambio, con revisión de ABI,
   ownership, drops y ambos backends.

Este documento no declara self-hosting, Stage 2 ni integración de NEXO en
programas ELE reales.

## Límites comprobados

Windows x86-64 se ejecutó de forma nativa. Linux x86-64 se ejecutó en WSL2
(kernel 5.10.16, páginas de 4 KiB) con binarios compilados en Windows para
`x86_64-unknown-linux-musl` y enlazados con `rust-lld`: compilación cruzada,
ejecución real sobre el kernel Linux. No se probaron Linux nativo ni glibc. Una página del SO distinta de 4 KiB produce un error de
plataforma controlado; no se anuncia soporte adaptado para ella.
