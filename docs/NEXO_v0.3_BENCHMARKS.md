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
