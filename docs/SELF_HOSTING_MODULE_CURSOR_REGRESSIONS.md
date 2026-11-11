# Regresiones de módulos y cursor: línea base de self-hosting

**Estado:** corrección en revisión; validar los dos binarios de pruebas y
los tres trabajos de GitHub Actions antes de considerar esta fase cerrada.

## Reproducción

La suite `modules_l` (13 pruebas) y la suite `self_hosting` (8 pruebas)
estaban fuera del workflow de validación nativa y daban cinco fallos en la
suite completa Windows/MSVC. Se añadieron al CI con
`cargo test -p project-l --no-fail-fast --test modules_l --test self_hosting -- --test-threads=1`.

Evidencia del estado anterior: [GitHub Actions
43081018551](https://github.com/Joshua-EPR/ELE/actions/runs/43081018551).
Ubuntu pasa. Windows reproduce exactamente cuatro fallos de módulos y uno
de cursor.

## Correcciones propuestas

1. **Imports faltantes:** `loadModuleRecursive` ya no atribuye a
   `main.l` el error de archivo inexistente perteneciente a una dependencia.
   Emite `L0014` con la ruta de importación fallida, y el proceso termina
   con estado 1.
2. **Ciclos:** un error `L0014` de ciclo ya emitido no se vuelve a
   informar como «ruta o límite inválido» ni termina con código 2.
3. **Fixture nominal:** `Point { x: Int y: Int }` carecía del separador
   requerido por Stage 0; ahora contiene la coma y conserva el objetivo de
   resolver el tipo nominal importado.
4. **Privados homónimos:** Stage 1 ya admite dos funciones privadas
   `helper` en módulos distintos. Stage 0 conserva una limitación real:
   rechaza nombres privados duplicados por usar una tabla de símbolos global.
   La prueba verifica el ELF ejecutable producido desde Stage 1 LIR (42) en
   lugar de pedir a Stage 0 que acepte una semántica que aún no implementa.
   **La limitación de Stage 0 no se declara corregida.**
5. **Cursor:** `token_cursor_navigation_and_expectations` incluía
   `lexer.l` y `cursor.l` pero omitía `tokens.l`, que declara
   `tokenKindValue`; ahora compila el conjunto de dependencias real.

## Criterios de aceptación

- 13/13 en `modules_l`, 8/8 en `self_hosting`.
- CI Ubuntu, Windows y ELF64 cruzado verde.
- Ninguna prueba desactivada o ignorada adicionalmente.
- `cargo fmt --all --check` y
  `cargo clippy --workspace --all-targets -- -D warnings` verdes.
- Sin afirmaciones sobre Stage 2, Stage 3, PE64 ni `List of[T]`
  nativa, que siguen pendientes.
