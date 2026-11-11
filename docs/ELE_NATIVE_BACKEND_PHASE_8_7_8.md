# Fase 8.7.8 — `shape` y `choice` por valor y movimientos parciales en el backend ELE

Estado: **implementado; verificado en Windows (aceptación, rechazo e imagen)
y ejecutado en Linux x86-64 (WSL) con salida idéntica a Stage 0**
(2026-11-11). Rama `feat/native-aggregate-abi`, apilada sobre
`fix/stage0-diagnostics-stacked`. No cierra el compilador.

| Elemento | Antes | Ahora |
|---|---|---|
| Parámetro `var vN val sK` / `val eK` | rechazado (45) | copiado palabra a palabra desde la pila |
| Argumento `val vN` de agregado | rechazado (37) | movido: se apilan todas sus palabras |
| `result sK` / `result eK` | rechazado (68) | escrito por puntero oculto |
| `i read vD pN.k` de un campo agregado propio | rechazado (73) | movimiento parcial con seguimiento por camino |

## ABI

- Un agregado ocupa `ceil(tamaño / 8)` palabras. El llamador las apila de
  la última a la primera, igual que los demás argumentos; el llamado las
  copia a su variable desde `RBP+16`.
- Si el resultado es un agregado, el llamador apila al final la dirección
  de su variable destino (puntero oculto). El llamado la encuentra en
  `RBP+16`, sus parámetros empiezan en `RBP+24` y `t return vX` copia el
  valor campo a campo (sin relleno) a través de ese puntero.
- `main` no puede devolver un agregado (50): su resultado es el estado de
  salida.

## Movimientos parciales (`codegen/native_cfg_paths.l`)

Cada campo y subcampo de tipo agregado de una variable `shape` propia tiene
un bit "inicializado" en el mismo análisis de flujo que las variables
(intersección en las uniones, iteración hasta punto fijo):

- leer un lugar agregado (`i read`) mata los bits dentro de él;
- `i store` a un lugar y un valor nuevo de la variable los restablecen;
- mover la variable entera los mata todos;
- usar un lugar, o el valor entero, exige sus bits y el del campo que lo
  contiene.

Los campos primitivos se copian y no tienen bit. A través de una referencia
la lectura es una copia, segura porque todos los agregados aceptados carecen
de recursos. Uso tras movimiento parcial: 57.

## Pruebas

`crates/l/tests/native_aggregates_l.rs` (3 pruebas):

- `examples/native_shape_abi_stage1.l` (parámetros, resultados anidados,
  `choice` con payload) y `native_shape_moves_stage1.l` (recursión que
  devuelve agregados, intercambio de campos por movimiento parcial,
  agregados con Text y `edit`, payload Bool): salida idéntica a Stage 0.
- `native_cfg_partial_move_ok.lir`: mueve campos y subcampos disjuntos,
  los restablece con `store` y usa el valor entero; sale con 135.
- 10 rechazos: uso entero, lectura del padre, doble movimiento,
  movimiento en una sola rama, retorno de un valor parcialmente movido,
  `main` agregado, tipo de argumento, uso tras pasar por valor y tipo de
  resultado.

## Límites reales

- Sin Text ni `List` dentro de agregados (los agregados siguen sin recursos).
- Mover un valor exterior dentro de un bucle lo rechaza la semántica de
  ELE (L0005), no el backend.
- Sin préstamos locales.
