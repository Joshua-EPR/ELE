# Fase 8.7.6 — Text propio y convención de llamada por pila en el backend ELE

Estado: **implementado y ejecutado en Linux x86-64** (2026-11-11). No cierra
el compilador.

## Qué cambia

Ruta: `programa.l` → Stage 1 → ELE-LIR 1 → `codegen/native_cfg_*.l` →
x86-64 → ELF64. Los programas declaran y usan `Text` con normalidad; el
backend genera solo el código de reserva, crecimiento y liberación.

| Elemento | Antes | Ahora |
|---|---|---|
| Tipo `t`, literales `ct<n>:…` | rechazado | variable, parámetro, resultado y literal |
| `i textbuf`, `i append`, `i drop` | rechazado | buffer propio con `mmap`/`mremap`/`munmap` |
| `i print` de Text (`val` o `ref p<N> 0`) | rechazado | escrito completo, con reintento de escrituras parciales |
| Argumentos de llamada | 2, en RDI/RSI | hasta 16, en la pila |
| Límites por módulo | 16 funciones, 32 bloques, 64 variables | 256 funciones, 1024 bloques, 256 variables (512 palabras) |

## Representación y runtime (`codegen/native_rt.l`)

Un Text son tres palabras: dirección, longitud en bytes y capacidad.
Capacidad 0 marca un literal guardado en la imagen, que ni se libera ni
crece. Los buffers propios se piden en páginas completas; al crecer la
capacidad al menos se duplica. Rutinas: `write_all`, `print_int`,
`print_bool`, `print_text`, `text_new`, `text_append`, `append_int`,
`append_bool`, `text_drop`. Todas son código máquina emitido con el
codificador x86-64 de ELE y solo se incluyen si el programa las necesita.

Estados de salida nuevos: 121 añadir a un literal, 123 fallo de reserva,
124 fallo de liberación.

## Convención de llamada

Los argumentos se apilan desde la última palabra del último argumento; la
función los copia a sus variables desde `RBP+16`. Resultados: RAX (Int,
Bool) o RAX, RDX, RCX (Text). Quien llama retira los argumentos.

## Verificación estática (`native_cfg_verify.l`)

Text es de movimiento único. El verificador rechaza: uso tras mover o
liberar (57), doble liberación (57), Text vivo al retornar (59),
sobrescribir un Text vivo (59) y añadir un buffer a sí mismo (93). Un
`drop` con bandera deja el valor como no disponible en adelante.

## Límites reales

- Sin parámetros por referencia (`view`/`edit`), sin Text dentro de
  structs o enums, sin `append` de un Text por valor, sin comparación ni
  operaciones de Text (`byteLength`, `byteAt`), sin `List`.
- Cada Text propio ocupa al menos una página y cuesta llamadas al sistema;
  falta un asignador con clases de tamaño.
- Los literales repetidos se guardan una vez por aparición.
- Solo Linux ELF64. No existe backend PE64.

## Pruebas

`crates/l/tests/native_print_l.rs` (7 pruebas). Los ejemplos oficiales
`fibonacci.l`, `text.l` e `interpolation.l` y `examples/native_text_stage1.l`
(400 concatenaciones con crecimiento) producen la misma salida que Stage 0.
Medido con `strace` en ese ejemplo: 403 `mmap`, 403 `munmap`, 317 `mremap`.
Rechazos: `examples/native_cfg_text_*.lir` y `native_cfg_call_ref_arg.lir`.

Suite completa en Linux: 256 aprobadas, 242 fallidas (todas requieren
Cranelift/MSVC); 39 pruebas Python de contrato aprobadas.
