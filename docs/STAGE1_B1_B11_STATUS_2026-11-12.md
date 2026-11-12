# Estado de autocobertura Stage 1 — B1–B11 (post-PR #42)

**HEAD medido:** `main@187c33aaabee9980924a4edf9b51aa795f9774bb`, merge del PR #42 (2026-11-12).
**CI Windows/MSVC:** [run 43167407670](https://github.com/Joshua-EPR/ELE/actions/runs/43167407670), concluido **success**.
**Evidencia:** artefacto `stage1-self-coverage-43167407670-windows-latest`, `report.json` original (ID GitHub Actions `13920913668`).
**Baseline de comparación:** [PR #36, run 43152145819](https://github.com/Joshua-EPR/ELE/actions/runs/43152145819), artefacto `stage1-self-coverage-43152145819-windows-latest` (ID `13913974367`).

El repositorio no se ha recompilado localmente en Windows en esta revisión: estos
resultados proceden de los **archivos JSON realmente generados por MSVC en CI**.
La clasificación mide archivos `.l` como entradas independientes y sus imports
transitivos. No mide cobertura de funciones ni la ejecución de todos los ELF,
mucho menos Stage 2 o self-hosting.

## Baseline post-#42, sin inferencias

| Fase | Post-#36 (89 fuentes) | Post-#42 (91 fuentes) |
| --- | ---: | ---: |
| Parser | 89/89 | **91/91** |
| Semántica y ownership | 25/89 | **36/91** |
| ELE-LIR verificada | 10/89 | **10/91** |
| Backend ELE genera ELF64 | 1/89 | **1/91** |

La comparación por **archivo y fase anteriormente verde** entre el JSON de
#36 y este JSON arroja **cero regresiones**. El gate oficial también reporta
`regressions: []` frente a la matriz de 2026-11-11. Los dos archivos nuevos
son `lir_builtin_union.l` y `sema_builtin_union.l`.
No interpretar la adición de fuentes como pérdida de cobertura funcional.

### Primera fase fallida, post-#42

| Fase | Código/estado | Fuentes | Lugar principal |
| --- | --- | ---: | --- |
| Ownership | `L0012` | **49** | `loans_l.l:94` (27), `native_cfg_text.l:265` (8), `expr.l:26` (7), `native_heap_resize.l:32` (6), `types.l:26` (1) |
| Ownership | `L0001` | **6** | `native_binary_io.l`, `native_elf_demo.l`, `native_heap_cases.l`, `native_heap_dynamic_cases.l`, `native_lir_demo.l`, `native_stack_aggregate_demo.l` |
| LIR | `L0016` | **26** | `x86_64.l:16` (9), `native_cfg_defs.l:167` (6), `lexer.l:98` (5), `native_layout.l:23` (3), `lir_build.l:145` (2), `ownership_l.l:123` (1) |
| Backend | código de proceso `48` | **9** | Bibliotecas sin `main` (ver B4); el gate conserva la falla |

El conteo de 9 bibliotecas en B4 incluye **`scopes.l`**, que no aparecía en
la agrupación antigua de 8. No supone que todos los códigos 48 tengan una
única causa: consultar `lir_module` y `native_48_hint` por fila en el JSON.

### B2: evidencia inicial del siguiente incremento

El préstamo incompatible en `loans_l.l:94` ocurre al calcular
`flowField(edit graph, place, graph.paths[cursor].field)`: el receptor de
`edit` y la proyección prestada comparten `graph`. Se puede capturar el
índice `field` antes de `flowField` sin modificar la semántica del CFG ni
la definición del borrow checker. Esta falla es **la primera** en 27 fuentes
porque el loader procesa sus imports transitivos; eso no implica que después
de corregirla las 27 fuentes pasen ownership. Re-medición posterior obligatoria.

## Registro B1–B11

| ID | Estado antes (#35, archivo histórico) | Estado en `main@187c33aa` / siguiente cierre |
| --- | --- | --- |
| B1 | 40 L0001 entre tipos y funciones | **Parcial**. #35, #36 y #41 fusionados; quedan 6 L0001 de funciones/builtins. `ownership_l.l` y `lir_verify_core.l` pasan ownership en este JSON, pero fallan en **LIR L0016**, no pueden declararse completos |
| B2 | 20 L0012 primero (antigua matriz) | **Parcial**. #37 fusionado (23 call sites), siguen **49** L0012 primero; 27 provienen de `loans_l.l:94`. Mantener negativos de préstamos |
| B3 | 14 L0016 | **Pendiente**. 26 L0016 como primera falla, agrupadas por fuente y línea arriba; no ampliar el subconjunto sin prueba de LIR malformada |
| B4 | 8 código 48 | **Diagnóstico parcial**. #38 fusionado, ahora 9 bibliotecas sin `main` llegan a backend; no elevar límites ni quitar el entrypoint. `flow_self_harness.l` demuestra camino válido para `flow_cfg.l` |
| B5 | Listas/texto incompletos | **Parcial**. `List.pop` permanece L0016 hasta validar puente de Option-tag y drops |
| B6 | Option/Result parciales | **Parcial**. #42 fusionado: `Option/Result` primitivos Int/Bool; no habilita `Text`, listas, payloads propietarios, `?` ni `pop` |
| B7 | L0003 en `lexer.l:87` | **Resuelto en el alcance del CFG de retorno**. #39 fusionado, cero L0003 como primera falla y `lexer.l` supera ownership; su primera falla actual es LIR L0016 en `lexer.l:98`. Mantener negativo de match incompleto |
| B8 | Builtins pendientes | **Pendiente**. Seis L0001 de función no encontrada en drivers/demos. No contarlos como skips ni inventar firmas |
| B9 | Duplicación/scopes | **Parcial por verificar**. No hay L0002 como primera falla, pero pueden aparecer tras resolver imports/loans; no relajar la regla |
| B10 | Medidor JSON | **Cerrado como tooling**. #34 fusionado; salida, gate histórico y evidencia post-#42 reales, 0 regresiones |
| B11 | Gancho por realizar | **Parcial**. #40 fusionado: `flow_self_harness.l` → Stage 1 → LIR → backend ELE → ELF64; strace bloquea procesos hijos en Linux. No recompila `main_sema.l`, NO es Stage 2 |

## Integraciones confirmadas

Los PR **#33, #34, #35, #36, #37, #38, #39, #40, #41 y #42 están fusionados
en `main`** al HEAD indicado. La afirmación anterior de que #36 y #37
seguían en draft **queda reemplazada por esta medición de GitHub**.

## Reproducción y regresiones

En Windows/MSVC, tras construir Stage 1 con la suite completa:

```powershell
cargo test -p project-l --no-fail-fast -- --test-threads=1
python tools/self_coverage_gate.py --baseline docs/SELF_COVERAGE_MATRIX_2026-11-11.md
```

Guardar `target/stage1-tests/self-coverage-gate/report.json` con cada run
y conservar el artefacto de CI. Para comprobar también éxitos del POST-#42,
ejecutar `tools/self_coverage_gate.py --baseline <report-post42.json>` usando
ese archivo exacto; las fases antes rojas pueden mejorar. El CI comprueba
la referencia histórica; el cotejo adicional con post-#42 se debe hacer
antes de declarar un cierre nuevo.

No ejecutar `git reset --hard`, alterar ownership, préstamos, drops,
verificador ELE-LIR ni el requisito de `main` para hacer pasar el gate.
No declarar Stage 2, Stage 3 o self-hosting.
