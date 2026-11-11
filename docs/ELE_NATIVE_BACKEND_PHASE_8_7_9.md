# Fase 8.7.9 — Text dentro de `shape` en el backend ELE

Estado: **implementado; verificado en Windows (aceptación, rechazo e imagen)
y ejecutado en Linux x86-64 (WSL) con salida idéntica a Stage 0 y reservas
equilibradas medidas con `strace`** (2026-11-11). Rama
`feat/native-text-fields`, apilada sobre `feat/native-aggregate-abi`. No
cierra el compilador.

| Elemento | Antes | Ahora |
|---|---|---|
| `field <nombre> t` | rechazado (61) | campo de tres palabras (dirección, longitud, capacidad) |
| `i struct` con operando Text (variable o literal `ct…`) | rechazado | mueve el Text al campo |
| `i read vD pN.k` de un campo Text propio | rechazado | movimiento del campo |
| `i store pN.k <Text>` (propio o por `edit`) | rechazado | llena un campo movido o liberado |
| `i dropfield <lugar> v<flag>\|-` | rechazado | libera el Text del campo (con o sin bandera) |
| `i print`/`i append` con `ref pN.k[.j] 0` | rechazado | lee el Text del lugar proyectado |

## Propiedad (`codegen/native_cfg_paths.l`, `native_cfg_fields.l`)

Los caminos de movimiento de la fase 8.7.8 se amplían a los campos y
subcampos Text y a las raíces referencia de tipo `shape`:

- leer un campo Text de un `shape` propio lo mueve; `dropfield` lo libera;
  ambos exigen que siga vivo (si no, 57: uso tras mover o doble
  liberación);
- `store` de un Text sobre un campo vivo, o dar un valor nuevo a una
  variable que aún posee un Text en un campo, fugaría (59);
- al retornar, un campo Text vivo de una variable viva es una fuga (59);
- a través de `edit` se puede liberar y volver a llenar un campo, pero el
  referente debe quedar completo al retornar (95); leer o copiar un valor
  que posee Text a través de una referencia se rechaza (95); liberar o
  escribir a través de un parámetro lo hace exclusivo (98 si se pasa
  `view`);
- `cfgOwnsText` decide qué agregados poseen recursos: solo los que no
  poseen Text se copian bit a bit a través de referencias.

Un `dropfield` con bandera (movimiento condicional) libera solo si la
bandera es verdadera; después el campo cuenta como no disponible, igual que
un `drop` con bandera de una variable.

## Pruebas

`crates/l/tests/native_text_fields_l.rs` (3 pruebas):

- `examples/native_text_fields_stage1.l`, `native_text_fields_heap_stage1.l`
  (Text en el heap, reemplazo repetido con `edit`, `shape` anidados, 50
  fichas creadas y liberadas en un bucle) y
  `native_text_fields_flags_stage1.l` (movimiento condicional con bandera):
  salida idéntica a Stage 0. Con `strace`: 110 `mmap` / 110 `munmap` y
  4 / 4.
- `native_cfg_tfield_replace_ok.lir`: libera y rellena por `edit`; imprime
  42 y sale con 2 (2 / 2 reservas).
- 9 rechazos: fuga al retornar, `store` sobre un campo vivo, doble
  liberación, uso tras mover, uso entero tras liberar, `dropfield` de un
  Int, mover por referencia, referente no restaurado y reemplazo por `view`.

`native_cfg_text_in_struct.lir`, que la fase 8.7.6 rechazaba con 61, ahora
se acepta y se ejecuta.

## Límites reales

- Payload Text en `choice` sigue rechazado.
- `drop` de un `shape` entero no existe: Stage 1 emite `dropfield` por
  campo.
- La intersección en las uniones no detecta un Text vivo solo en una rama
  (fuga posible, no corrupción); Stage 1 inserta banderas en esos casos.
- Máximo 4 campos por `shape` y 4 operandos por constructor: las
  estructuras del propio compilador tienen más; es el siguiente bloqueo.
