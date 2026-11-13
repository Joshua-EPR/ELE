# NEXO v0.2 — núcleo, verificador, oráculo y fuzzer (Etapa 2, fases 1–3)

Crate aislado `crates/nexo` (`ele-nexo`, sin dependencias). No toca Stage 1,
`compiler-l/`, ELE-LIR ni los backends. La integración detrás de
`--memory-model=nexo` es la Etapa 4.

```
cargo test -p ele-nexo -- --test-threads=1
cargo run -p ele-nexo --release --bin nexo-fuzz -- --semilla 1 --casos 100000 --exhaustivo 3 --pool 500 --efectos 3000
```

> **Alcance de la evidencia.** Las pruebas y campañas de este documento son
> evidencia finita sobre el modelo abstracto. No demuestran la seguridad
> general de NEXO: eso exige un argumento formal (por ejemplo, progreso y
> preservación de NEXO-Core respecto de la semántica del oráculo), que no
> existe todavía.

## 1. Arquitectura

| Módulo | Contenido |
| --- | --- |
| `ir` | NEXO-Core: clases, tipos (`Dueno`, `Prestamo` view/edit, `Enlace`, `Hueco`, `Sello`, `Funcion`), sentencias |
| `diag` | `Regla` (R1–R9, C1–C6), `Diagnostico` con función y ruta (`cuerpo[3].cuerpo[1]`) |
| `verif::tipos` | R1–R5 |
| `verif::huecos` | `destruir` + `crear` del mismo pool en el mismo bloque básico → `hueco<P,s>` + `reusar_hueco` |
| `verif::lineal` | R8/R9 y elaboración (destrucciones implícitas, *drop flags*, `liberar_hueco`) |
| `verif::efectos` | efectos por pool (punto fijo) + validez de enlaces; **recalcula** todas las anotaciones |
| `verif::prestamos` | R6, R7 (por *liveness*), C1–C6 |
| `rt::pool` | pool Bi-Slab simulado + comprobador de invariantes |
| `rt::maquina` | intérprete; oráculo de memoria, permisos, efectos y carreras |
| `fuzz`, `bin/nexo-fuzz` | generador por flujo de elecciones, propiedades P1–P8, reducción |
| `pretty` | impresión de NEXO-Core |

**Principio**: la IR verificada no es confiable por definición. El verificador
ignora las anotaciones de entrada (`nivel`, `invalida_epoca`) y las recalcula;
la máquina no consulta tipos ni reglas: comprueba cada acceso con información
de ejecución y verifica sin contarlas las revalidaciones `Estatico`/`Congelado`.

## 2. Especificación congelada de las reglas

Notación: `P` pool, `x` dueño, `b` préstamo, `l` enlace, `B` cuerpo protegido.
*Raíz* de un préstamo: `Var(x)` (dueño local), `Param(b)` (préstamo recibido)
o `Ligado(P)` (objetos de `P` alcanzados por enlaces). `Ligado(P)` solapa con
cualquier `Var(x)`/`Param(b)` ubicado en `P` y consigo mismo. *Vida* de un
préstamo = puntos donde está vivo por *liveness* hacia atrás.

### R1 — Tipos, ámbitos, definición única y permisos
* **Definición**: cada sentencia está bien tipada; cada variable tiene una
  única definición y se usa solo en su ámbito (desde su definición hasta el fin
  de su bloque); las operaciones mutantes sobre `P` exigen permiso `edit`/dueño.
* **Precondiciones**: clases y pools existentes; parámetros pool `view`/`edit`,
  locales `dueño`.
* **Permitido**: `crear`/`destruir`/`revalidar edit`/`reestructurar`/`dividir`
  con `edit`; lectura y `revalidar view` con cualquier permiso; enlace nulo
  `Const(0)` en campos `Enlace`.
* **Rechazado**: uso antes de definir o fuera de ámbito, doble definición,
  tipos incompatibles (incluidas firmas de función con distinta opacidad),
  `dueño`/`edit` de un objeto de un pool visto como `view`, `retornar` dentro
  de un cuerpo concurrente.
* **Invariante**: ningún valor se usa con un tipo o permiso que no tiene.
* **Diagnóstico**: `error[R1] (tipos, ámbitos y permisos) en `f` @ ruta: …`
* **Pruebas**: `r1_*`, `n19_*` (firma opaca), `n25_sello_de_otro_pool_se_rechaza`.

### R2 — Enlazabilidad
* **Definición**: solo clases `enlazar` viven en pools; una clase con campos
  `Enlace` es `enlazar` y no vive en la pila; slot ≤ 4096 B.
* **Precondiciones**: ninguna.
* **Permitido**: objetos no enlazables en la pila de datos.
* **Rechazado**: pool de clase no enlazable, `enlazar` un objeto de pila,
  clase con enlaces en la pila, slot > 4 KiB.
* **Invariante**: todo enlace apunta a un slot con cabecera generacional.
* **Diagnóstico**: `error[R2] (enlazabilidad) …`
* **Pruebas**: `r2_*`, `bislab::tamanos_invalidos_*`.

### R3 — Acceso por enlace solo tras revalidar
* **Definición**: un `Enlace` no es un objeto; el `ligado` de `revalidar`
  existe solo en el cuerpo.
* **Precondiciones**: ninguna.
* **Permitido**: `leer`/`escribir`/`prestar` sobre el ligado dentro de `B`.
* **Rechazado**: acceso directo por enlace; usar el ligado en `Ausente` o
  fuera de `B` (también en lotes con validación parcial).
* **Invariante**: todo acceso por enlace va precedido de una validación de
  generación (comprobada o probada).
* **Diagnóstico**: `error[R3] (acceso por enlace solo tras revalidar) …`
* **Pruebas**: `r3_*`, `n11_enlace_obsoleto`, `n26_validacion_parcial_no_expone_ligados`.
* **Oráculo**: enlace usado como objeto → `PermisoInventado`; ligado no
  expuesto → `UsoTrasConsumo`.

### R4 — Un `Enlace<P>` no sobrevive a `P`
* **Definición**: los campos `Enlace` apuntan al pool del propio objeto; ningún
  valor atado a un pool local escapa de su función.
* **Precondiciones**: ninguna.
* **Permitido**: copiar y guardar enlaces libremente dentro de su pool
  (ciclos incluidos).
* **Rechazado**: retornar/recibir valores atados a un pool local; guardar un
  enlace de `Q` en un objeto de `P`.
* **Invariante**: un enlace solo se revalida mientras su pool existe.
* **Diagnóstico**: `error[R4] (un enlace no sobrevive a su pool) …`
* **Pruebas**: `r4_*`, `n13_enlace_que_sobrevive_a_su_pool` (+ oráculo `PoolInexistente`).

### R5 — No-escape de préstamos
* **Definición**: un préstamo no se almacena en objetos, no se devuelve, no
  sale de su ámbito ni se captura en `transferir_pool`.
* **Precondiciones**: ninguna.
* **Permitido**: pasar préstamos a llamadas y a hilos estructurados.
* **Rechazado**: los cuatro escapes anteriores.
* **Invariante**: la vida de un préstamo está contenida en la de su raíz.
* **Diagnóstico**: `error[R5] (no-escape de préstamos) …`
* **Pruebas**: `r5_*`, `n08_prestamo_que_escapa`.

### R6 — Sin `destruye(P)` dentro de `revalidar` / `si_sellado`
* **Definición**: en `B = revalidar l en P` ninguna sentencia (incluidas las
  destrucciones implícitas y las llamadas, por su efecto inferido o asumido)
  libera slots de `P`, salvo con `diferir`; ninguna reestructura `P` (no
  diferible). En `si_sellado(P)` además se prohíbe guardar enlaces no probados.
* **Precondiciones**: efectos inferidos por punto fijo.
* **Permitido**: `crece(P)`, lecturas, `destruir` diferido (la cola se vacía al
  salir de `B`, también con `retornar`).
* **Rechazado**: destruir (aunque sea otro objeto), llamadas `destruye(P)` u
  opacas, `reestructurar`, `transferir_pool(P)`.
* **Invariante**: los préstamos derivados de enlaces de `P` y la época sellada
  siguen siendo válidos durante `B`.
* **Diagnóstico**: `error[R6] (sin destruye(P) dentro de revalidar/sellado) … use \`revalidar … diferir\`…`
* **Pruebas**: `r6_*`, `n17_*`, `n18_*`, `n19_*`, `n20_*`, `n25_destruir_dentro_de_si_sellado_viola_r6`.

### R7 — Exclusividad
* **Definición**: un acceso de escritura choca con todo préstamo vivo con raíz
  solapada; uno de lectura, con los `edit`. Consumir (mover/destruir) un dueño
  choca solo con los préstamos de ese dueño; pasarlo por valor cuenta como
  escritura. Una llamada choca con préstamos vivos en `P` si su efecto sobre
  `P` incluye `edita`/`reestructura`, o `lee` frente a un `edit`. Los ligados
  hermanos de un `revalidar_lote edit` no chocan entre sí.
* **Precondiciones**: liveness y efectos.
* **Permitido**: varios `view`; préstamos secuenciales; représtamos.
* **Rechazado**: `edit`+`edit`, `edit`+`view`, escribir el dueño con préstamos
  vivos, revalidaciones anidadas que puedan alias (use `revalidar_lote`).
* **Invariante**: nunca hay dos caminos activos a un objeto si uno escribe.
* **Diagnóstico**: `error[R7] (exclusividad de edit) … mientras el préstamo \`b\` (edit) sigue vivo`
* **Pruebas**: `r7_*`, `n06`, `n07`, `n09`, `n16`, `n23_crece_que_edita_*`, `n26_lote_edit_*`.
* **Limitación conservadora**: los préstamos son de objeto completo; dos
  `edit` a campos disjuntos se rechazan (N07).

### R8 — Linealidad de `dueño`
* **Definición**: estado por camino `Vivo`/`Consumido`/`Quizás`. Usar o
  consumir algo que no está `Vivo` se rechaza. Al cerrar un ámbito: `Vivo` →
  destrucción implícita, `Quizás` → destrucción con *drop flag*.
* **Precondiciones**: R1.
* **Permitido**: consumo asimétrico (drop flags), salidas anticipadas.
* **Rechazado**: uso tras mover, doble destrucción, consumo en bucle de algo
  externo, consumo de un dueño externo dentro de un hilo.
* **Invariante**: cada recurso propietario se libera exactamente una vez por
  camino completo.
* **Diagnóstico**: `error[R8] (linealidad de dueño) … el dueño \`a\` ya fue consumido en este camino`
* **Pruebas**: `r8_*`, `n01`–`n05`.

### R9 — `hueco<P,s>`
* **Definición**: lineal, del pool que lo produjo, confinado a su bloque
  básico; si no se consume, se libera al cerrar el bloque.
* **Precondiciones**: R1.
* **Permitido**: `destruir … → hueco` + `reusar_hueco` en el mismo bloque.
* **Rechazado**: usarlo tras una sentencia compuesta, en otro pool, dos veces.
* **Invariante**: el slot reservado ni se pierde ni se duplica; `gen` +2.
* **Diagnóstico**: `error[R9] (hueco lineal confinado al bloque básico) …`
* **Pruebas**: `r9_*`, `n24_*`.

### C1 — Pools locales al hilo
* **Definición**: en `paralelo` (o `dividir` con ≥ 2 partes) un pool no
  congelado lo usa como mucho un hilo; el hilo destino de `transferir_pool`
  solo usa el pool transferido.
* **Rechazado**: dos hilos usan `P` sin `congelar`.
* **Invariante**: sin acceso concurrente a metadatos mutables de un pool.
* **Diagnóstico**: `error[C1] (pools locales al hilo) …`
* **Pruebas**: `c1_pool_compartido_sin_congelar`.

### C2 — Transferencia sin enlaces vivos
* **Definición**: solo un pool local se transfiere; tras ello no quedan
  enlaces ni préstamos hacia `P` vivos en el origen ni usos de `P`; no se
  transfiere dentro de un bucle o de un cuerpo replicado de `dividir`, ni se
  retransfiere desde el hilo que lo recibió. Los dueños vivos de `P` se mueven
  con él.
* **Invariante**: el pool tiene un único hilo propietario y se destruye una vez.
* **Diagnóstico**: `error[C2] (transferencia sin enlaces vivos) …`
* **Pruebas**: `c2_*`, `n13`, `n21`, `regresion_fuzz_transferir_dentro_de_dividir`, `regresion_fuzz_retransferir_*`.

### C3 — `congelar(P)` es solo lectura
* **Definición**: dentro de `congelar(P)` no hay creación, destrucción
  (incluida la implícita), escritura, préstamo/revalidación `edit`,
  reestructuración, transferencia ni llamadas mutantes sobre `P`. El nivel
  `Congelado` exige prueba de validez **y** congelación.
* **Invariante**: los objetos alcanzados no cambian ni mueren durante las lecturas.
* **Diagnóstico**: `error[C3] (congelar(P) es solo lectura) …`
* **Pruebas**: `c3_*`, `n22_pool_congelado_compartido` (+ oráculo
  `MutacionCongelado`, y `NivelIncorrecto` si se forja `Congelado` sin congelar).

### C4 — Capturas de hilos sin alias mutable
* **Definición**: dos hilos de una región no acceden a la misma raíz si alguno
  la muta (o usa un `edit`); los hilos no consumen dueños externos.
* **Diagnóstico**: `error[C4] (capturas de hilos sin alias mutable) …`
* **Pruebas**: `c4_dos_hilos_escriben_el_mismo_dueno`, fuzzer.

### C5 — `dividir`: mutación solo en la partición propia
* **Definición**: un trabajador no muta variables externas; solo revalida en
  `edit` enlaces a objetos que él creó; no sella, no reestructura, no vuelve a
  dividir, congelar ni transferir el pool dividido; no llama a funciones con
  `edita`/`reestructura` sobre él. Los objetos preexistentes son inmutables
  durante `dividir` (base de N28-A).
* **Diagnóstico**: `error[C5] (dividir: mutación solo en la partición propia) …`
* **Pruebas**: `n28_*`, `n28b_*`, `regresion_fuzz_*`.

### C6 — `dividir(edit P, N)`
* **Definición**: `N ≥ 1`, permiso `edit`, `P` no congelado ni protegido, y
  ningún préstamo vivo hacia `P`.
* **Diagnóstico**: `error[C6] (dividir requiere edit exclusivo de P) …`
* **Pruebas**: `c6_*`.

## 3. Discrepancias con la especificación N01–N28 y su resolución

Ninguna se resolvió rebajando garantías.

| Caso | Discrepancia | Resolución |
| --- | --- | --- |
| N07 | Préstamos por campos disjuntos | No soportados: se **rechazan** (conservador) y se documenta |
| N17 | "Salvo demostración de disjunción" | No hay análisis de disjunción: se **rechaza** siempre |
| N18 | Destruir el propio objeto revalidado y seguir usándolo en `B` era imposible (R7 trataba la liberación como alias) | R7: el consumo solo choca con préstamos del mismo dueño; la seguridad la dan R6 + `diferir` (la memoria no se libera hasta salir de `B`) |
| N26 | `revalidar_lote edit` no permitía escribir por dos ligados | R7 exime a los ligados hermanos: el runtime garantiza slots distintos (alias → `Ausente`) |
| N28 | La versión v0.2 ("leen la otra partición") no prueba ausencia de carreras | Se separa en N28-A (lecturas solo de objetos preexistentes, inmutables por C5) y N28-B (lectura con escritura concurrente → C5 + carrera en el oráculo) |
| N05 | El modelo no tiene excepciones | "Ruta de error" = rama `Ausente` + `retornar` anticipado |
| N13 | "Destruir P" | Los pools son léxicos: mueren al salir de su función o al transferirse |
| N21 | Retransferir desde B | No expresable con destrucción única: rechazo C2 |
| N25 | "Igualdad de épocas no sustituye las garantías" | Ver §5: la igualdad es la comprobación en ejecución de un invariante sostenido por R6, la regla de almacenamiento y el barrido de `sellar` |
| N27 | Devolución real vs simulada | Es **simulada** (estado `Devuelta`, datos descartados); no hay `madvise`/`VirtualFree` |

## 4. Defectos encontrados y corregidos (fase 3)

**Verificador**
1. *(fuzzer)* `dividir Q { transferir Q }` se aceptaba → C5 + C2 (cuerpo replicado). Regresión `regresion_fuzz_transferir_dentro_de_dividir`.
2. *(fuzzer)* `transferir Q { transferir Q }` se aceptaba (doble destrucción del pool) → C2. Regresión `regresion_fuzz_retransferir_desde_el_hilo_destino`.
3. *(auditoría al corregir 1)* `dividir`/`congelar` del pool dividido desde un trabajador se aceptaba → C5.
4. *(auditoría)* Sobre-restricción: `revalidar_lote edit` inutilizable.
5. *(auditoría)* Sobre-restricción: N18 inexpresable.

**Oráculo / runtime**
1. *(fuzzer)* Pánico por índice de partición fuera de rango con `dividir` anidado → aborto `PermisoInventado`/`ParticionAjena`.
2. *(fase 2)* Acceso a un slot recién liberado clasificado como doble liberación.
3. *(auditoría)* Faltaba oráculo de **permisos**: escribir por `view`, mutar un pool `view`, usar un enlace como objeto, transferir un pool prestado → `PermisoInventado`.
4. *(auditoría)* Faltaba oráculo de **efectos** (P4): cada llamada compara lo ejecutado (asignaciones, destrucciones, reestructuras, invalidaciones de época, revalidaciones view/edit) con el efecto inferido o asumido → `EfectoSubestimado`.
5. *(auditoría)* `Congelado` no comprobaba que el pool estuviera congelado → `NivelIncorrecto`.
6. *(auditoría)* `Pool::nuevo` entraba en pánico con tamaños inválidos; aritmética de generaciones con `wrapping_add` → comprobada, sin *wraparound*.
7. *(auditoría)* Enlace nulo: antes "gen 0 en cualquier slot", ahora exactamente `(0, 0)`.

**Fuzzer**: la reproducción por elecciones se desalineaba con elecciones de
rango 1; y el generador uniforme casi no producía `revalidar` aceptados
(9 de 20 000) → preludio + pesos.

## 5. Sellado y validación por época (N25)

La revalidación `Estatico` de enlaces leídos dentro de `si_sellado(sello)` se
apoya en:
1. `sellar(P)` comprueba **todos** los enlaces almacenados en objetos vivos de
   `P` (`lecturas_gen_sellado`) y solo si todos son válidos produce
   `Sello(P, epoca_destruccion)`;
2. toda liberación, reestructuración y almacenamiento de un enlace no probado
   incrementa `epoca_destruccion` (los almacenamientos probados no lo
   necesitan: el enlace era válido al guardarse y su muerte posterior
   incrementa la época);
3. dentro de `si_sellado` no hay `destruye(P)` ni almacenamientos no probados,
   también por llamadas transitivas (R6 con efectos inferidos);
4. el sello está tipado por pool (`Sello(P)`, R1) y la comparación en
   ejecución usa el pool del propio sello;
5. el oráculo comprueba igualmente cada revalidación `Estatico`: una prueba
   forjada (sustituir `si_sellado` por `si 1`) aborta con `NivelIncorrecto`.

## 6. Concurrencia

Fork-join estructurado sin sincronización interna. *Happens-before* = orden de
programa + fork + join; dos accesos de hilos distintos de una región nunca
están ordenados. El detector registra cada acceso (gen, datos, metadatos de
partición, época por partición, estructura, objetos de pila) con su hilo en
todas las regiones activas: un par en conflicto es una carrera **en cualquier
intercalación** (equivale a relojes vectoriales para esta forma). Los hilos se
ejecutan en orden directo, inverso y una permutación por semilla.

**No modelado** (y por tanto rechazado o inexpresable): barreras, cerrojos,
canales, hilos no estructurados, orden débil de memoria del hardware.

## 7. Fuzzer

```
cargo run -p ele-nexo --release --bin nexo-fuzz -- \
    [--semilla N] [--casos N] [--ops N] [--prof N] [--malformados] \
    [--segundos N] [--exhaustivo L] [--pool N] [--efectos N] [--reproducir a,b,…]
```

Cada caso registra semilla, elecciones (reproducción exacta con
`--reproducir`), programa reducido, veredicto, traza de las últimas 48
sentencias (con hilo), estado de los pools y orden de hilos. Los fallos P1 se
reducen automáticamente borrando tramos y poniendo elecciones a 0.

| Propiedad | Comprobación |
| --- | --- |
| P1 | aceptado ⇒ ejecución sin aborto en 3 órdenes de hilos, con invariantes Bi-Slab |
| P2 | sin fugas ni dobles liberaciones (oráculo + `comprobar_fugas`) |
| P3 | `fuzz_pool`: ningún `(slot, gen)` emitido dos veces; ningún par muerto vuelve a ser válido |
| P4 | oráculo de efectos en cada llamada |
| P5 | oráculo de niveles `Estatico`/`Congelado` |
| P6 | detector de carreras |
| P7 | accesos a subpáginas devueltas o slots muertos abortan |
| P8 | `fuzz_efectos`: punto fijo = cierre transitivo independiente, determinista |

### Resultados reales (2026-11-13, Windows/MSVC, release)

| Campaña | Programas | Aceptados | Ejecuciones | Fallos P1 |
| --- | --- | --- | --- | --- |
| Exhaustiva L=3 con preludio | 27 648 | 18 934 | 56 802 | 0 |
| Exhaustiva L=4 con preludio (364 s) | 663 552 | 362 540 | 1 087 620 | 0 |
| Exhaustiva L=4 sin preludio (generador previo) | 663 552 | 568 882 | 1 706 646 | 0 |
| Aleatoria, semillas 1, 2, 3 (100 000 c/u) | 300 000 | 161 421 | 484 263 | 0 |
| Aleatoria profunda `--ops 30 --prof 3`, semilla 0xBEEF | 50 000 | 23 422 | 70 266 | 0 |
| IR mal tipada `--malformados`, semilla 0xBAD | 50 000 | 24 983 | 74 949 | 0 |
| Pool directo `--pool 500` (semilla 9) | 1 000 000 ops | — | — | 0 (P3/P7) |
| Efectos `--efectos 3000` (semilla 9) | 3 000 grafos, 13 559 funciones | — | — | 0 (P8) |

Cobertura de sentencias en programas aceptados (semilla 1, 20 000 casos):
`revalidar` 3 512, `revalidar_lote` 1 291, `reusar_hueco` 781, `escribir`
2 295, `llamar` 2 560, `paralelo` 687, `dividir` 321, `si_sellado` 837.

Pool directo: 367 890 asignaciones, 279 715 liberaciones, 78 076 huecos,
45 871 slots retirados, 34 281 subpáginas devueltas, 1 750 944 sondeos de
pares obsoletos.

Semillas que reprodujeron defectos (antes de corregirlos), con la campaña de
`tests/fuzz.rs`: exhaustiva L=2 elecciones `[0, 2, 19, 0, 1, 20, 0]` y
`[0, 2, 20, 1, 20, 0]`; aleatoria semilla 1 (caso con elecciones
`[3, 3, 23, 0, 20, 4, 20, 0, 16, …]`). Con el generador actual esas
elecciones se interpretan con pesos y ya no producen el mismo programa: las
regresiones fijas están en `tests/verificador.rs`.

**Lectura de los rechazos.** La columna "rechazados que el oráculo confirma
inseguros" ejecuta la IR rechazada **sin elaborar**; casi todos abortan con
`Fuga` porque la IR cruda no lleva destrucciones implícitas. No es una medida
fiable del conservadurismo del verificador.

## 8. Bi-Slab: comprobaciones

`tests/bislab.rs` y `maquina.rs` verifican: cabecera de 4 095 B ≤ 4 KiB
(960 generaciones + 15 bitmaps de slots libres + 15 bitmaps de huecos reservados + 15 contadores, también como `const assert`);
superpágina = 4 KiB + 15 × 4 KiB; base alineada a 64 KiB y fija; para tamaños
64, 72, 96, 128, 200, 1000, 2048, 3000 y 4096 B: ≤ 960 slots por superpágina,
ningún slot cruza subpágina ni invade la cabecera, alineación 8 B, sin
solapamientos, direcciones fuera de la reserva → `None` (aritmética
comprobada); tamaños inválidos y generación inicial impar → error sin pánico;
reserva agotada → `AgotamientoVirtual` y pool consistente; agotamiento de
generación → `0xFFFF_FFFE` retirado, sin *wraparound*; bitmaps, buckets por
densidad y estados de subpágina coherentes tras cada operación
(`comprobar_invariantes`).

## 9. Límites del modelo abstracto frente al runtime físico

* La devolución de páginas es simulada; no hay `mmap`/`VirtualAlloc`/`madvise`.
* Los hilos se ejecutan secuencialmente con detector de carreras; no hay
  paralelismo real ni modelo de memoria débil. En hardware, la lectura de
  `gen[s]` en nivel `Comprobado` concurrente con escrituras de otro hilo
  necesitaría atómicos; el modelo lo evita porque C1/C3/C5 impiden esa
  concurrencia.
* Máximo 273 superpáginas por pool y 65 536 pools por ejecución (espacio
  virtual simulado de 4 GiB por pool).
* Objetos de campos de 8 B (`Int` o `Enlace`); sin buffers internos: la
  "reestructuración" solo modela su efecto de invalidación.
* Un trabajador que agota el rango de superpáginas de su partición aborta
  (`AgotamientoVirtual`); no hay reequilibrado.

## 10. Riesgos pendientes

* Sin primitivas de sincronización, los patrones que necesitan barreras
  (fases de escritura y lectura cruzada) no son expresables.
* Destrucciones diferidas en cuerpos concurrentes: la cola es por
  `revalidar`; no hay pruebas específicas de colas compartidas entre hilos
  (un hilo no puede destruir en un pool compartido por C1/C5).
* El análisis de validez es intraprocedural: los enlaces recibidos como
  parámetro siempre se comprueban (correcto pero menos estático).
* Préstamos por campo y disjunción de objetos: no implementados (rechazos
  conservadores).
* Falta un argumento formal de solidez.


## 11. Endurecimiento posterior a la fase 3 (revisión PR #66)

La API pública de Bi-Slab distinguía huecos reservados y slots libres solo
mediante la paridad de la generación. Ambos estados usan generaciones pares:
invocar `Pool::reusar_hueco` sobre un slot ordinariamente libre podía
consumir un permiso inexistente, restar de `self.huecos` y desincronizar
el bitmap/lista libre. `Pool::liberar_hueco` también permitía una segunda
liberación sin comprobar el permiso.

Corrección: se reservan 120 B adicionales en la cabecera por superpágina
para 15 bitmaps de *huecos lineales pendientes* (uno por subpágina).
El total máximo pasa de 3975 B a 4095 B, todavía dentro de 4096 B.
Destruir con `hueco=true` marca explícitamente el permiso; reutilizarlo o
liberarlo exige su presencia y lo consume exactamente una vez. Los errores
se devuelven como `Aborto` sin mutar la estructura. El invariante comprueba
la exclusión entre vivo/libre/retirado/hueco reservado.

Pruebas añadidas en `tests/bislab.rs`:
`un_slot_libre_no_otorga_permiso_de_hueco` y
`permisos_de_hueco_son_lineales_y_comprobados`.
También se propagan los errores de `liberar_hueco` desde el runtime y
el fuzzer directo de pools.

**Validación posterior al merge (2026-11-13, Windows/MSVC, `main@57b763c`):**
las 114 pruebas de `ele-nexo` pasaron, incluidas las dos regresiones de
huecos. Clippy con `-D warnings` pasó. El primer `cargo fmt --all --check`
detectó formato pendiente en `pool.rs`; se corrigió mecánicamente y el gate
de formato pasó después. La campaña acotada con semilla fija 11 ejecutó
5 000 programas, 200 000 operaciones directas de pool y 500 grafos de
efectos sin fallos P1/P3/P7/P8.


### Límite de particiones C6 y protección frente a IR hostil

`Dividir` tenía una cantidad de trabajadores `u32` sin límite superior:
una solicitud `u32::MAX` podía forzar una construcción desproporcionada
de índices de asignación antes de llegar a ninguna operación útil.
El verificador de NEXO-Core ahora rechaza cantidades fuera del rango
`1..=MAX_PARTICIONES_NEXO` (273); la API del pool también devuelve
`Aborto` sin mutar su estado y prohíbe dividir un pool ya dividido.

La constante 273 corresponde al máximo del índice Bi-Slab simulado
(64 palabras × 64 bits / 15 subpáginas por superpágina). Es un límite
del prototipo v0.2, no una garantía de que cualquier número inferior
pueda ejecutarse con los recursos disponibles. Las nuevas regresiones
comprueban la validación estática y la máquina ante límites extremos.

Las regresiones de C6 y de división repetida están incluidas en las 114
pruebas ejecutadas sobre `main@57b763c`. Esta validación acredita el modelo
abstracto y sus invariantes comprobadas; no acredita un allocator físico,
paralelismo real, un modelo de memoria débil ni una prueba formal de solidez.
