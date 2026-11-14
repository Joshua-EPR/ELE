# NEXO v0.3 — medición física reproducible

Estado: medición exploratoria, no promesa de rendimiento. El binario es
`cargo run -p ele-nexo --release --bin nexo-physical-bench`.

## Condiciones ejecutadas

- Windows x86-64, una hebra, build `--release`.
- Calentamiento: 2.000 iteraciones por escenario.
- Medición: 20.000 iteraciones por escenario.
- Fecha de la corrida: 2026-11-13.
- Cada cifra mide el ciclo completo indicado; no se sustrajo el coste del
  bucle ni se seleccionó el mejor de varias corridas.

| Escenario | ns/op observados |
|---|---:|
| NEXO físico, asignar/liberar caliente | 815,16 |
| NEXO físico, destruir/reusar hueco | 667,12 |
| NEXO físico, commit/reclaim | 5.815,52 |
| Modelo abstracto, asignar/liberar | 81,08 |
| `Box<[u8; 64]>` global de Rust | 188,63 |

NEXO físico fue 4,3 veces más lento que el `Box` en el caso caliente y 30,8
veces más lento cuando cada operación fuerza commit y reclaim. La escritura de
la cabecera física completa (4.095 bytes) en cada transición y las llamadas al
SO explican gran parte de la diferencia. La comparación con `Box` no equipara
generaciones, detección de enlaces obsoletos, huecos ni reclaim; solo aporta una
referencia nativa honesta.

## Memoria observada

Para un pool de ocho superpáginas y un objeto vivo de 64 bytes:

- Reserva virtual: 524.288 bytes.
- Memoria comprometida contada por el backend: 8.192 bytes (cabecera + una
  subpágina de datos).
- Memoria útil: 64 bytes.
- Cabecera lógica usada: 4.095 de 4.096 bytes.
- Tamaño inmediato de `PhysicalPool`: 256 bytes, **solo cota inferior**.

Los metadatos auxiliares dinámicos incluyen dos vectores de estado por página
de la reserva, el vector de superpáginas y, por superpágina inicializada, hasta
3.840 bytes de generaciones más bitmaps, ocupación y estados. Estos costes no
se ocultan en la cifra de 256 bytes. El prototipo todavía duplica la cabecera
normativa en Rust para búsquedas seguras; eliminar esa duplicación exige un
índice diferente, no un cambio cosmético.

RSS/working set, pico, fragmentación externa y escenarios de grafos/muchos
pools no se midieron de forma fiable en esta corrida. Quedan como obligaciones
de benchmark; no se infieren a partir de bytes comprometidos.

## Revalidación independiente (misma máquina, mismo binario sin cambios)

Dos corridas más de `nexo-physical-bench` el 2026-11-13, sin modificar los
escenarios. Las cifras **no reproducen** la tabla anterior: la máquina tenía
otra carga y no hay aislamiento de CPU, frecuencia fija ni percentiles.

| Escenario | Corrida 1 (ns/op) | Corrida 2 (ns/op) |
|---|---:|---:|
| NEXO físico, asignar/liberar caliente | 1.596,09 | 1.757,43 |
| NEXO físico, destruir/reusar hueco | 1.540,28 | 1.566,56 |
| NEXO físico, commit/reclaim | 12.614,18 | 10.751,73 |
| Modelo abstracto, asignar/liberar | 150,82 | 148,32 |
| `Box<[u8; 64]>` global de Rust | 287,32 | 233,83 |

Cocientes frente a `Box`: caliente 5,6× y 7,5×; commit/reclaim 43,9× y 46,0×
(la tabla original daba 4,3× y 30,8×). La conclusión cualitativa se mantiene y
empeora: NEXO físico es varias veces más lento que `Box` en la ruta caliente y
más de un orden de magnitud más lento cuando cada operación fuerza reclaim. La
dispersión entre corridas (hasta 2× en valores absolutos) impide usar
cualquiera de estas cifras como referencia estable.

## Diagnóstico: por qué NEXO físico es más lento que `Box`

Derivado de la lectura del código (`physical/pool.rs`, `address_space.rs`); no
se midió con un perfilador, así que el reparto exacto entre causas es una
hipótesis a verificar.

1. **Reescritura completa de la cabecera.** `sync_header` serializa las 960
   generaciones, 30 bitmaps y 15 contadores en un búfer de 4.095 B y lo copia a
   la página mapeada en **cada** asignación, destrucción, reuso o liberación de
   hueco: ≈ 8 KiB de tráfico por par asignar/liberar, cuando el cambio real es
   de ~13 B (una generación, una palabra de bitmap, un contador). Que el ciclo
   de hueco (sin búsqueda) cueste casi lo mismo que el caliente apunta a esta
   causa como dominante.
2. **Una asignación del heap global dentro del allocator.** `zero_slot` crea
   un `Vec<u8>` de `slot_size` bytes para poner a cero el slot: cada
   `allocate` de NEXO incluye una asignación y liberación del allocator global,
   es decir, al menos el coste de un `Box`.
3. **Búsqueda lineal de la subpágina más densa.** `densest_available` recorre
   todas las superpáginas × 15 subpáginas por asignación (120 entradas con 8
   superpáginas), frente a los buckets con `tzcnt` del modelo abstracto.
4. **Comprobaciones por acceso.** Cada lectura/escritura valida el handle
   (`locate` con división por un divisor no constante) y recorre los vectores
   `committed`/`accessible` de `AddressSpace` antes de copiar.
5. **Reclaim con dos llamadas al SO más fallo de página.** Al vaciarse una
   subpágina, `return_page` llama a `VirtualProtect(PAGE_NOACCESS)` y después a
   `VirtualFree(MEM_DECOMMIT)`; la siguiente asignación hace
   `VirtualAlloc(MEM_COMMIT)` y el primer acceso provoca un fallo de página con
   puesta a cero por el núcleo. En el escenario commit/reclaim esto ocurre en
   cada iteración y domina el coste (≈ 10–12 µs). En Windows,
   `MEM_DECOMMIT` ya deja la página inaccesible, así que la protección previa
   es redundante en esa plataforma.
6. **`Box` no paga nada equivalente.** El heap de Windows sirve un bloque de
   64 B desde una caché/lista libre por tamaño con un puñado de instrucciones;
   no mantiene generaciones, no escribe cabeceras, no devuelve páginas al SO y
   no detecta enlaces obsoletos. La diferencia mide en parte el coste de esas
   garantías y en parte ineficiencias del prototipo (1–3), que no son
   inherentes al diseño Bi-Slab.

Optimizaciones candidatas, **no aplicadas** en esta fase (primero validar):
escribir solo las palabras de cabecera modificadas; poner a cero con un búfer
fijo o directamente en la página; índice por densidad con buckets; fusionar
protección y decommit; histéresis en el reclaim para no confirmar/devolver la
misma subpágina en cada iteración. Cada una debe medirse por separado con
varias muestras y percentiles.

## Interpretación

La corrida demuestra que la reserva y el backing físico son medibles y que el
reclaim cuesta más que la ruta caliente. No demuestra superioridad frente al
allocator global ni estabilidad estadística entre máquinas. Para una decisión
de integración se necesitan múltiples muestras, percentiles, RSS por API del
SO y cargas de listas/grafos con vida útil representativa.

## Corrección y optimización (2026-11-13, posterior a PR #69 inicial)

Las tablas anteriores se conservan sin cambios. Las de esta sección se
midieron después de corregir la reclamación (estados explícitos, API lineal)
y de aplicar tres optimizaciones, cada una en su propio commit:

| Commit | Cambio |
|---|---|
| C1 `b675cf0` | Reclamación transaccional, API lineal (`Handle`/`ObjRef`), espejo de cabecera verificado. Sin optimizar: cabecera completa por transición, `Vec` para poner a cero, búsqueda lineal, dos llamadas al SO por reclaim en Windows |
| C3 `a66105e` | Espejo incremental (21 B en vez de 4.095 B) y puesta a cero sin heap (`AddressSpace::fill`) |
| C4 `f78a5b4` | Índice de densidad con `tzcnt` y `VirtualFree(MEM_DECOMMIT)` en un solo paso en Windows |

### Atribución: binarios intercalados en la misma sesión

Escenarios originales sin cambios de carga. 7 rondas; en cada ronda se
ejecutan en orden los binarios original (`cb16d5d`), C1, C3, C4 y final. Se
muestra la mediana (ns/op) y, entre corchetes, mínimo–máximo de las 7 rondas.

**Windows x86-64 (nativo)**

| Escenario | Original | C1 | C3 | C4 | Final |
|---|---:|---:|---:|---:|---:|
| caliente asignar/liberar | 1.123,7 [667–1.560] | 1.324,9 [784–1.822] | 439,3 [251–562] | 399,1 [228–527] | 404,0 [243–466] |
| hueco destruir/reusar | 1.127,6 [612–1.285] | 1.014,2 [739–1.594] | 378,1 [207–448] | 354,2 [206–436] | 344,6 [205–443] |
| commit/reclaim | 4.971,9 [4.614–9.425] | 5.525,7 [4.807–8.451] | 5.242,0 [3.898–7.422] | 4.116,7 [3.398–6.045] | 4.321,3 [3.290–6.189] |
| modelo abstracto | 67,8 | 85,0 | 86,2 | 84,9 | 81,8 |
| `Box<[u8;64]>` | 111,2 [106–232] | 118,6 [105–196] | 121,2 [105–156] | 120,0 [105–211] | 114,2 [99–217] |

C4 y Final comparten biblioteca (solo cambia el binario de benchmark). La
corrección (C1) cuesta ≈ +18 % en la ruta caliente; el espejo incremental y la
puesta a cero sin heap (C3) la reducen ≈ −67 %; el índice de densidad y el
reclaim de un paso (C4), ≈ −9 % la caliente y ≈ −21 % el reclaim.

Cocientes frente a `Box` **en esta misma sesión**: caliente 10,1× (original) →
3,5× (final); commit/reclaim 44,7× → 37,8×. En esta sesión `Box` midió
≈ 111–121 ns/op; en las corridas de la sección anterior, 234–287 ns/op: los
cocientes solo son comparables dentro de una misma sesión.

**Linux x86-64 (WSL2, kernel 5.10.16; binarios `x86_64-unknown-linux-musl`)**

| Escenario | Original | Final |
|---|---:|---:|
| caliente asignar/liberar | 930,0 [839–2.459] | 265,1 [238–908] |
| hueco destruir/reusar | 835,5 [704–2.274] | 330,3 [225–877] |
| commit/reclaim | 12.419,6 [8.191–20.100] | 12.064,0 [7.313–19.128] |
| modelo abstracto | 95,7 | 101,0 |
| `Box<[u8;64]>` (malloc de **musl**) | 552,7 [338–1.067] | 399,2 [315–1.252] |

`Box` en este binario usa el allocator de musl, mucho más lento que el de
glibc: que NEXO quede por debajo de él **no** indica nada frente a un `Box`
de glibc, que no se midió. El reclaim en Linux sigue dominado por tres
llamadas al SO (`mprotect`, `madvise`, `mprotect` al reconfirmar) y el fallo de
página con puesta a cero del núcleo.

### Escenarios ampliados (`nexo-physical-bench --completo`, código final)

7 corridas × lotes de 200 ops. `alloc/op` cuenta llamadas al allocator global
durante la medición e incluye la preparación del escenario repartida.

**Windows**

| Escenario | media | mediana | p95 | p99 | cv% | alloc/op | SO/op | cabecera B/op |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| caliente (con ancla) | 491,6 | 471,0 | 555,0 | 1.249,5 | 6,8 | 0,004 | 0 | 42,0 |
| hueco destruir/reusar | 453,1 | 420,0 | 537,0 | 1.321,5 | 6,5 | 0,004 | 0 | 42,0 |
| commit/reclaim agresivo | 7.399,5 | 6.275,0 | 9.273,5 | 23.660,0 | 29,4 | 0,004 | 2 | 42,2 |
| commit/reclaim con protección previa | 13.983,8 | 8.955,0 | 36.552,5 | 85.539,5 | 21,7 | 0,004 | 3 | 42,2 |
| commit/reclaim diferido (keep=1) | 1.319,8 | 509,0 | 3.451,5 | 13.822,0 | 69,3 | 0,004 | 0 | 42,2 |
| ráfaga 960+960 (por op) | 358,7 | 289,0 | 530,0 | 1.997,5 | 23,6 | 0,008 | 0,016 | 21,4 |
| larga duración (900 vivos) | 944,7 | 477,5 | 2.149,5 | 12.029,5 | 37,3 | 0,004 | 0 | 42,0 |
| fragmentado (450 subpáginas a medias) | 565,5 | 492,0 | 558,5 | 1.812,0 | 9,2 | 0,005 | 0 | 42,0 |
| pool pequeño (1 superpágina) | 530,6 | 492,5 | 530,0 | 976,0 | 10,7 | 0,004 | 0 | 42,0 |
| pool grande (64 sp, 50.000 vivos) | 601,6 | 496,5 | 629,5 | 2.074,5 | 30,6 | 0,006 | 0 | 42,0 |
| revalidar enlace + leer | 81,6 | 77,5 | 89,0 | 186,0 | 3,9 | 0,004 | 0 | 0 |
| `Box` asignar+liberar | 228,9 | 204,5 | 252,0 | 770,0 | 12,2 | 1,000 | — | — |
| `Box` ráfaga 960+960 | 146,4 | 118,5 | 265,0 | 311,0 | 2,3 | 0,501 | — | — |

**Linux (WSL2, musl)**

| Escenario | media | mediana | p95 | p99 | cv% | SO/op | cabecera B/op |
|---|---:|---:|---:|---:|---:|---:|---:|
| caliente (con ancla) | 398,7 | 430,5 | 550,0 | 628,5 | 16,5 | 0 | 42,0 |
| hueco destruir/reusar | 301,8 | 255,0 | 418,0 | 513,0 | 18,7 | 0 | 42,0 |
| commit/reclaim agresivo | 9.321,9 | 8.269,0 | 15.974,0 | 31.494,0 | 20,2 | 3 | 42,2 |
| commit/reclaim diferido (keep=1) | 395,3 | 442,5 | 538,5 | 780,5 | 21,5 | 0 | 42,2 |
| ráfaga 960+960 (por op) | 194,9 | 187,5 | 253,5 | 476,0 | 6,9 | 0,024 | 21,4 |
| pool grande (64 sp, 50.000 vivos) | 409,6 | 315,0 | 628,0 | 923,5 | 20,0 | 0 | 42,0 |
| revalidar enlace + leer | 63,9 | 59,5 | 60,0 | 133,0 | 14,9 | 0 | 0 |
| `Box` (musl) asignar+liberar | 183,7 | 150,0 | 280,5 | 357,0 | 30,1 | — | — |

Antes de C3, cada par asignar/liberar escribía ≈ 8.190 B de cabecera y hacía
una asignación del heap; ahora escribe 42 B y ninguna. La ruta caliente no
hace llamadas al SO; el reclaim agresivo hace 2 (Windows) o 3 (Linux) por
ciclo, y la política diferida, ninguna.

### Memoria (pool de 64 superpáginas, 50.000 objetos de 64 B)

Reserva virtual 4,0 MiB (**no es consumo de RAM**). Memoria útil:
50.000 × 64 B = 3,05 MiB. "Comprom." y "accesible" son del pool; Δ WS/RSS y Δ
privada son del proceso completo (incluyen el vector de 50.000 handles,
≈ 0,8 MiB, y el heap de metadatos).

| Estado | Comprom. | Windows Δ WS | Windows Δ privada | Linux Δ RSS | Linux Δ anón |
|---|---:|---:|---:|---:|---:|
| agresivo, 50.000 vivos | 3,26 MiB | +4,10 | +4,11 | +4,12 | +4,12 |
| agresivo, 25.000 intercalados | 3,26 MiB | +4,48 | +4,77 | +3,88 | +3,88 |
| agresivo, 0 vivos | 0,21 MiB | +1,42 | +1,71 | +0,45 | +0,45 |
| diferido keep=8, 0 vivos | 0,24 MiB | +0,75 | +1,05 | +0,48 | +0,48 |
| diferido, tras `reclaim_all` | 0,21 MiB | +0,72 | +1,02 | +0,45 | +0,45 |

Overhead comprometido con 50.000 vivos: 3,26 MiB para 3,05 MiB útiles
(+6,9 %: 53 cabeceras de 4 KiB). Con 25.000 objetos intercalados la memoria
comprometida no baja (ninguna subpágina se vacía): es fragmentación interna
real del diseño por subpáginas. Con 0 vivos quedan 0,21 MiB: las cabeceras de
las 53 superpáginas usadas nunca se devuelven. Los Δ de proceso incluyen ruido
del allocator de Windows y no deben leerse como coste exacto del pool.

### Cuellos de botella restantes

- Reclaim agresivo: 2–3 llamadas al SO + fallo de página por ciclo
  (≈ 4–12 µs). La política diferida lo evita con coste de RAM acotado
  (`keep_empty` subpáginas de 4 KiB).
- Validación por acceso (`locate` con división, comprobación de estado de
  página en `AddressSpace`) y metadatos duplicados (generaciones en Rust y en
  la cabecera física).
- Cabeceras que no se devuelven nunca (4 KiB por superpágina usada).
- No se usó perfilador: la atribución procede de commits aislados medidos
  intercalados, no de muestreo de CPU.
