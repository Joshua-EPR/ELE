# Estado de bloqueos de autocobertura Stage 1 (B1–B11)

**Fecha:** 2026-11-12. **Línea base remota verificada:** `main` en
`b61000b24e`, workflow
[43147786262](https://github.com/Joshua-EPR/ELE/actions/runs/43147786262).
Este documento conserva el alcance de
[SELF_COVERAGE_GATE.md](SELF_COVERAGE_GATE.md): cada fuente se invoca como
entrada independiente y Stage 1 carga sus imports. No mide cobertura por
funciones, ejecución ELF ni Stage 2.

## Baseline posterior a #35 (real; no inferido)

El `report.json` de `stage1-self-coverage-43147786262-windows-latest`
registra lo siguiente:

| Fase | Fuentes aprobadas |
| --- | ---: |
| Parser | 89 / 89 |
| Semántica + ownership | 23 / 89 |
| LIR + verificador | 9 / 89 |
| Backend nativo ELE (genera ELF) | 1 / 89 |

Los 88 archivos con fallo se agrupan por su **primera fase fallida**:

| Primera falla | Archivos | Causa diagnóstica |
| --- | ---: | --- |
| Ownership | 36 | L0001: tipo desconocido |
| Ownership | 4 | L0001: función no encontrada |
| Ownership | 20 | L0012: préstamo incompatible |
| Ownership | 6 | L0003: falta retorno en algún camino |
| LIR | 14 | L0016: forma fuera del subconjunto |
| Backend | 8 | código 48: módulo no aceptado |

Los seis L0003 apuntan en el JSON a la **misma función**
`compiler-l/src/lexer.l:87` (`lexScan`), no a seis
errores de función diferentes.

**Advertencia sobre B4:** los ocho archivos que llegan a código 48 son
bibliotecas sin `main` (`ast.l`, `flow_cfg.l`, `sema_types.l`,
`symbols.l`, `module_graph_l.l`, `sema_borrow_syntax.l`,
`codegen/elf64.l` y `codegen/lir_tokens.l`). En
`codegen/native_cfg_ir.l` el error 48 cubre, entre otras condiciones,
`main < 0` o un índice fuera del rango `funcs`, **además** de los
límites de tablas. No se ha aislado aún cuál predicado exacto falló
por cada LIR; no se debe elevar límites ni eliminar la exigencia de
`main` a ciegas. Los módulos de biblioteca deben probarse con harness
ejecutables reales, como ya hace `flow_self_harness.l`.

## Matriz de trabajo verificable

| Bloqueo | Estado actual | Evidencia y siguiente cierre necesario |
| --- | --- | --- |
| B1 imports semánticos | Parcial | #35 fusionado; PR #36 en draft exporta nominales y funciones de los módulos internos y agrega pruebas de import público/privado. Re-medir antes de darlo por cerrado |
| B2 préstamos L0012 | Parcial | PR #37 en draft acorta 23 expresiones de lectura+edición en cuatro módulos runtime, sin relajar ownership; falta re-medición de dependientes y negativos |
| B3 subconjunto LIR | Pendiente | 14 fuentes caen en L0016; inventariar formas y ampliar el verificador sin aceptar IR incorrecta |
| B4 código 48 | Diagnóstico parcial | Ocho bibliotecas sin `main`. Verificar cabeceras y distinguir límites frente a entrada inválida; crear harness de código nativo real |
| B5 métodos/listas/texto | Parcial | Capacidades de listas simples descritas en PHASE_8_3; faltan usos reales y `pop` en el conjunto completo |
| B6 Option/Result/listpop | Parcial | Hay soporte para subconjuntos, pero no autocobertura comprobada del lexer ni lowering total |
| B7 retorno total | Pendiente | L0003 en `lexer.l:87` afecta seis entradas; arreglar fuente o CFG con prueba negativa conservada |
| B8 builtins/plataforma | Pendiente | Cuatro entradas fallan por función no encontrada, sin exclusión del gate |
| B9 duplicación scopes | Por verificar | El JSON post-#35 no reporta L0002 como primera falla; falta re-medir tras B1 |
| B10 medidor JSON | Cerrado (tooling) | PR #34 fusionado y CI verde; gate preserva los éxitos históricos |
| B11 gancho Stage 2 | Pendiente | Requiere ruta directa Stage 1 a IR/artefacto y corpus diferencial, con prueba de ausencia de frontend Rust en dicha ruta |

Las ramas de PR #36 y #37 son **incrementos aún NO integrados en main**.
No se atribuyen nuevas cifras hasta recuperar sus propios `report.json`.

## Reproducción Windows/MSVC

Construir Stage 1 con los tests existentes (la suite completa garantiza la
creación de herramientas, aunque tarda más):

```powershell
cargo test -p project-l --no-fail-fast -- --test-threads=1
python -m unittest discover -s tests/native_backend -p 'test_self_coverage_gate.py' -v
python tools/self_coverage_gate.py --baseline docs/SELF_COVERAGE_MATRIX_2026-11-11.md
```

Confirmar que la construcción dejó los ejecutables
`main_parser.exe`, `main_sema.exe` y `native_cfg_demo.exe` bajo
`target/stage1-tests/<nombre>/normal/`. Si faltan, el gate falla
explícitamente; el informe no debe rellenarse con números inventados.

El reporte resultante está en
`target/stage1-tests/self-coverage-gate/report.json` y su Markdown
complementario. El CI los publica en la ejecución Windows bajo el artefacto
`stage1-self-coverage-<run_id>-windows-latest`.

## Para Stage 2 real

1. Corregir B1/B2/B7 que bloquean la autocobertura del núcleo.
2. Completar lowering B3, builtins B8 y verificación B4; usar un programa
   `main` que importe módulos de biblioteca para generar ELF ejecutable.
3. Comprobar que el compilador ELE Stage 1 compila fuentes ELE reales y
   emite el artefacto sin invocar el frontend de Rust durante esta etapa.
4. Diferenciar esta prueba (gancho B11) de recompilar la toolchain completa,
   que sigue pendiente. No declarar Stage 2 ni Stage 3 plenos.

La eliminación final de Rust del bootstrap y las plataformas PE64/Win32
siguen fuera de este incremento, sin renunciar al objetivo final del proyecto.
