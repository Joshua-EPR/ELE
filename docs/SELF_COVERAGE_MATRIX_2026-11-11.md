# Autocobertura de `compiler-l/src` — medición 2026-11-11

Resultado: 89/89 pasan parser, 23/89 semántica y ownership,
9/89 emiten LIR verificada y 1/89 pasa el backend ELE.
Estas fracciones corresponden a entradas independientes y son
recuentos de archivos, no porcentajes de funcionalidad cubierta.

Cada fila corresponde a una fuente `.l` real invocada como entrada
independiente. Parser: `main_parser.exe archivo`; semántica y ownership:
`main_sema.exe archivo --check-ownership`; LIR y su verificador:
`main_sema.exe archivo --emit-lir`; backend ELE: `native_cfg_demo.exe`
sobre el LIR emitido. Las fases posteriores se ejecutan solo cuando la
anterior pasa. Un archivo de biblioteca sin `main` puede fallar como
entrada independiente aunque sus funciones sean válidas al importarlo.
La compilación nativa solo acredita que se produjo un ELF64 en Windows;
esta matriz no demuestra su ejecución en Linux ni Stage 2/3.

| Fuente | Parser | Semántica y ownership | LIR y verificador | Backend ELE / ELF64 |
| --- | --- | --- | --- | --- |
| `ast.l` | Sí | Sí | Sí | No (ELE-LIR/CFG rechazado (código 48)) |
| `codegen/elf64.l` | Sí | Sí | Sí | No (ELE-LIR/CFG rechazado (código 48)) |
| `codegen/lir_subset.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/x86_64.l:16:27: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `codegen/lir_tokens.l` | Sí | Sí | Sí | No (ELE-LIR/CFG rechazado (código 48)) |
| `codegen/native_cfg_arith.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_rt.l:55:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 1353:27, uso vivo en 1353:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_cfg_defs.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen\native_cfg_defs.l:167:54: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `codegen/native_cfg_emit.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_rt.l:55:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 1511:27, uso vivo en 1511:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_cfg_fields.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_cfg_defs.l:167:54: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `codegen/native_cfg_inst.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_rt.l:55:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 1511:27, uso vivo en 1511:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_cfg_ir.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_rt.l:55:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 1511:27, uso vivo en 1511:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_cfg_list.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_cfg_defs.l:167:54: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `codegen/native_cfg_list_emit.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_rt_list.l:43:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 1416:27, uso vivo en 1416:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_cfg_loan.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_cfg_defs.l:167:54: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `codegen/native_cfg_paths.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_cfg_defs.l:167:54: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `codegen/native_cfg_ref.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_cfg_defs.l:167:54: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `codegen/native_cfg_text.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_rt.l:55:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 1353:27, uso vivo en 1353:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_cfg_types.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_layout.l:23:18: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `codegen/native_cfg_verify.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_rt.l:55:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 1511:27, uso vivo en 1511:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_heap.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen\native_heap.l:49:42: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 428:27, uso vivo en 428:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_heap_dynamic.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen\native_heap_dynamic.l:36:43: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 415:27, uso vivo en 415:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_heap_owner.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_heap_dynamic.l:36:43: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 415:27, uso vivo en 415:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_heap_resize.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_heap_dynamic.l:36:43: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 415:27, uso vivo en 415:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_layout.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen\native_layout.l:23:18: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `codegen/native_list_int.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen/native_heap_dynamic.l:36:43: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 415:27, uso vivo en 415:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_rt.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen\native_rt.l:55:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 434:27, uso vivo en 434:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/native_rt_list.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen\native_rt_list.l:43:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 422:27, uso vivo en 422:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `codegen/x86_64.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\codegen\x86_64.l:16:27: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `cursor.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\cursor.l:19:69: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `decl.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `drops_dump.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `drops_plan.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `drops_verify.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `expr.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `flow_cfg.l` | Sí | Sí | Sí | No (ELE-LIR/CFG rechazado (código 48)) |
| `flow_self_harness.l` | Sí | Sí | Sí | Sí |
| `lexer.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\lexer.l:87:4: error[L0003]: la función requiere retorno explícito en cada salida alcanzable) | No ejecutado | No ejecutado |
| `lir_build.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\lir_build.l:255:26: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `lir_emit.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `lir_finish.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `lir_module.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `lir_verify.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `lir_verify_core.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/lir_build.l:255:26: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `lir_verify_helpers.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `lir_write.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `loans_check.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `loans_l.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `main.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `main_parser.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `main_sema.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `module_graph_l.l` | Sí | Sí | Sí | No (ELE-LIR/CFG rechazado (código 48)) |
| `modules_l.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `native_binary_io.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\native_binary_io.l:9:26: error[L0001]: función no encontrada) | No ejecutado | No ejecutado |
| `native_cfg_demo.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/native_rt.l:55:37: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 1511:27, uso vivo en 1511:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `native_elf_demo.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\native_elf_demo.l:20:30: error[L0001]: función no encontrada) | No ejecutado | No ejecutado |
| `native_encoder_branches.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/x86_64.l:16:27: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `native_encoder_cases.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/x86_64.l:16:27: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `native_heap_cases.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/native_heap.l:49:42: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 535:27, uso vivo en 535:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `native_heap_dynamic_cases.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/native_heap_dynamic.l:36:43: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 522:27, uso vivo en 522:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `native_heap_owner_cases.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/native_heap_dynamic.l:36:43: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 522:27, uso vivo en 522:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `native_heap_resize_cases.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/native_heap_dynamic.l:36:43: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 522:27, uso vivo en 522:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `native_layout_cases.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/native_layout.l:23:18: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `native_lir_demo.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\native_lir_demo.l:27:47: error[L0001]: función no encontrada) | No ejecutado | No ejecutado |
| `native_list_cases.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/native_heap_dynamic.l:36:43: error[L0012]: préstamo incompatible con este acceso. Préstamo iniciado en 522:27, uso vivo en 522:5. Termine de usar la referencia antes de modificar, mover o volver a prestar el lugar.) | No ejecutado | No ejecutado |
| `native_memory_cases.l` | Sí | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/codegen/x86_64.l:16:27: error[L0016]: construcción fuera del subconjunto de la LIR v1 de ELE) | No ejecutado |
| `native_stack_aggregate_demo.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\native_stack_aggregate_demo.l:44:30: error[L0001]: función no encontrada) | No ejecutado | No ejecutado |
| `ownership_l.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\ownership_l.l:69:64: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `parse_util.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `parser.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `scopes.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\scopes.l:35:53: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_borrow.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_borrow_syntax.l` | Sí | Sí | Sí | No (ELE-LIR/CFG rechazado (código 48)) |
| `sema_collection_ops.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_context.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_drop.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_expr.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_expr_temp.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_loop_jump.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_lower.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_match_coverage.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_ops.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_stmt.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_stmt_values.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `sema_types.l` | Sí | Sí | Sí | No (ELE-LIR/CFG rechazado (código 48)) |
| `stmt.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `stmt_lower.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `symbols.l` | Sí | Sí | Sí | No (ELE-LIR/CFG rechazado (código 48)) |
| `tokens.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src\tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
| `types.l` | Sí | No (C:\Users\Usuario\Desktop\ELE\compiler-l\src/tokens.l:28:42: error[L0001]: tipo desconocido) | No ejecutado | No ejecutado |
