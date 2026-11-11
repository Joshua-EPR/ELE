# Migración de ejemplos de ELE a sintaxis v2

**Estado:** cambios implementados y verificados en la rama
`chore/examples-ele-v2-canonical`. GitHub Actions
[43072044595](https://github.com/Joshua-EPR/ELE/actions/runs/43072044595)
aprobó los tres trabajos configurados: Ubuntu, Windows y ejecución de
ELF64 generado en Windows sobre Linux.

## Alcance

- Se inspeccionaron 40 archivos fuente `.l` de `examples/`.
- Se migraron los 25 ejemplos que todavía conservaban sintaxis heredada.
- Se mantuvieron intactos los 15 ejemplos ya canónicos.
- Los 117 archivos `.lir` son fixtures de ELE-LIR 1 y **no** se modifican.
- Se incluyen los casos deliberadamente inválidos de `examples/invalid/`,
  que deben continuar produciendo errores, no compilar de forma exitosa.

## Sustituciones de superficie

| Convención histórica | Forma canónica ELE |
| --- | --- |
| `fn`, `struct`, `enum`, `impl` | `flow`, `shape`, `choice`, `extend` |
| `let`, `var`, `const` | `hold`, `change`, `fixed` |
| `return`, `->` | `give`, `=>` |
| `if/else`, `while`, `loop` | `when/otherwise`, `during`, `repeat` |
| `for … in`, `break`, `continue` | `each … among`, `leave`, `proceed` |
| `match` y sus brazos `=>` | `choose` y sus brazos `:` |
| `self`, `mut fn`, `static fn` | `this`, `exclusive flow`, `direct flow` |
| `valor.metodo()` | `valor@metodo()` |
| `Result<Float, Text>` | `Result of[Float, Text]` |

Los accesos a campos `objeto.campo` se conservan como tales. Los nombres de
tipos, el valor de los cálculos, los textos de salida y los casos de rechazo
también se conservan. Las cadenas y comentarios se tratan separadamente para
evitar reemplazos accidentales; las expresiones interpoladas con métodos se
actualizaron de forma explícita.

## Validación y limitaciones

La prueba `crates/l/tests/examples_ele_v2.rs` descubre todos los ejemplos
`.l`, verifica que no usan palabras clave históricas fuera de literales y
comentarios, valida los ejemplos positivos con Stage 0, confirma que los
negativos continúan rechazándose y ejecuta una selección de programas para
comparar su salida esperada.

GitHub Actions ejecuta esa prueba en Ubuntu y Windows. Las pruebas nativas
anteriores continúan verificando ejemplos Stage 1 y ELF64.

Esta fase migra exclusivamente los ejemplos. **No** elimina la compatibilidad
histórica de Stage 0/1, ni migra todavía todas las fuentes internas del
compilador en `compiler-l/src` y las cadenas de código incluidas en pruebas
históricas. No implica self-hosting.
