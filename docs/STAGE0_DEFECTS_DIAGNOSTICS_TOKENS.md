# Stage 0: diagnósticos por archivo y fin del límite de 4096 tokens

Estado: **implementado y probado en Windows/MSVC** (2026-11-11). Corrige los
dos defectos de Stage 0 documentados en la fase 8.7.6.

## Defecto 1 — diagnósticos de módulos importados con la ruta del archivo raíz

**Causa.** `Span` guardaba solo línea y columna. Los errores léxicos y
sintácticos se marcaban con su archivo en el cargador, pero todo error
posterior (semántica, lowering, verificación, soporte del backend) llegaba
al driver sin archivo y se imprimía con la ruta del archivo de entrada. Se
reprodujo en esta sesión: un error en `codegen/native_cfg_ref.l:121` se
informó como `native_cfg_demo.l:121:52`.

**Corrección.** `Span.file` identifica el archivo (0: fuente suelta o
prelude). `lexer::lex_file` lo asigna a cada token; el cargador numera los
módulos en orden de lectura (`modules::load_program_files`) y
`modules::attribute` nombra el archivo de un diagnóstico. La CLI y
`check_file` los aplican a cada fase. El archivo de entrada conserva la ruta
que dio el usuario; los demás se muestran canónicos sin `\?\`.

**Regresión.** `modules::semantic_errors_in_imported_modules_name_their_own_file`:
error en `sub/ayudante.l` importado transitivamente (`ayudante.l:6:12`),
error en el archivo de entrada (`main.l:5:11`) y la API `check_file`
(`intermedio.l`, 3:31).

## Defecto 2 — límite fijo de 4096 tokens por archivo

**Causa.** Lexer y parser rechazaban cualquier archivo con más de 4096
tokens ("CORE-1"), lo que obligaba a partir módulos del compilador. El
almacenamiento ya era dinámico (`Vec<Token>`); el límite solo acotaba la
entrada. Al quitarlo apareció lo que ocultaba: con el binario debug, una
cadena de **30** sumas ya desbordaba la pila de 1 MiB del hilo principal de
Windows (`main` también falla así), porque los marcos de la recursión
semántica son grandes sin optimizar. `conformance` abortaba por la misma
razón con 200 paréntesis anidados.

**Corrección.**

- Límite de recursos `lexer::MAX_TOKENS = 2^20` por archivo (≈64 MiB de
  tokens), con diagnóstico propio `L0002 … límite de recursos`. Ningún
  módulo real se acerca (todos tienen menos de 4096 tokens hoy).
- El compilador corre en un hilo con 256 MiB de pila reservada
  (`project_l::with_compiler_stack`) en la CLI, `check` y `check_file`. La
  profundidad sigue acotada: 128 niveles en el parser y en la semántica, que
  ahora se diagnostican en lugar de abortar.

**Regresiones.** `conformance::files_beyond_4096_tokens_compile_and_run`
(programa de >8192 tokens compilado y ejecutado con Cranelift y rustc, el
límite de recursos, cadena de 300 sumas y 200 paréntesis por la CLI);
`differential/unsupported/struct_too_large.l` (>10 000 tokens: un `struct`
de 5000 componentes que Cranelift rechaza con L0008 y rustc ejecuta).

## Pruebas heredadas que vuelven a pasar

- `conformance` (7/7): ya no aborta por la pila; `else_if` usaba `choose`,
  palabra reservada en ELE v2, como nombre de función (renombrada).
- `cfg` y `differential`: el directorio `differential/unsupported` ahora
  existe y contiene un caso real.
- `borrow_l::stage1_borrow_checker_scales_and_frees_its_memory`: afirmaba
  que Stage 0 rechazaba su fuente de más de 4096 tokens; ahora Stage 0 vuelve
  a ser la referencia y ambos la aceptan.
- `references` (7) y `regions` (1): sus fuentes usaban `view`, `choose` y
  `change` como identificadores, palabras reservadas en ELE v2; se
  renombraron a `vista`, `elegir` y `cambiar` sin cambiar lo verificado.

## Suite completa (Windows/MSVC)

| | `main` `f19ec01` | esta rama |
|---|---|---|
| Aprobadas | 479 | 497 |
| Fallidas | 15 | 5 |
| Binarios que abortan | `conformance` | ninguno |

Las 5 restantes son heredadas y ajenas a estos defectos: `modules_l` (4,
deriva de `modules_l.l` de Stage 1) y `self_hosting` (1, `tokenKindValue`
ya no existe en las fuentes de Stage 1).
