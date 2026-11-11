# Migración ELE v2 del núcleo CFG nativo

Estado: **implementación parcial, PR #33 en validación**.

## Alcance

Se migraron cinco fuentes reales del backend nativo escrito en ELE:

- `compiler-l/src/codegen/native_cfg_verify.l`
- `compiler-l/src/codegen/native_cfg_emit.l`
- `compiler-l/src/codegen/native_cfg_ir.l`
- `compiler-l/src/codegen/native_cfg_inst.l`
- `compiler-l/src/codegen/native_cfg_types.l`

Se reemplazó la sintaxis Rust-like en el código ejecutable de esos
módulos: `import` por `take`, `pub fn` por `expose flow`,
`fn` por `flow`, `let/var` por `hold/change`,
`if/else/for/while/return` por
`when/otherwise/each…among/during/give`, `&mut/&` por
`edit/view`, `->` por `=>`, métodos con `@` y
`List<T>` por `List of[T]`.

Los literales de texto y comentarios mantienen su contenido, en
particular las palabras del protocolo `ELE-LIR 1`. El motor Stage 0
en Rust no fue modificado.

## Evidencia y seguridad de integración

- La primera ejecución de CI identificó una transformación incorrecta
  de `&&` en `&view`, que fue corregida.
- Las pruebas de contrato Python que antes buscaban literalmente la
  sintaxis antigua se actualizaron para exigir **las mismas rutas de
  implementación** expresadas en la sintaxis nueva.
- `crates/l/tests/examples_ele_v2.rs` verifica ahora la superficie
  canónica de esos cinco archivos y evita reintroducir aliases.
- Las suites native_* y el workflow Ubuntu/Windows siguen siendo los
  criterios para confirmar que el compilador, sus verificadores de
  propiedad y los ELF64 conservan el comportamiento.

**No considerar concluida esta fase hasta ver CI completo verde
en el último commit y, para liberar, ejecución cruzada de ELF64.**

## Pendiente

Esta PR no migra todavía el resto de `compiler-l/src`, ni elimina
el parser de compatibilidad; tampoco implementa `List.pop()`,
`dropfield` mediante referencias, opciones genéricas nativas, Stage 2,
Stage 3 o PE64.

El siguiente bloque de compilación deberá diseñar la representación
de `Option<T>` en ELE-LIR antes de integrar `i listpop`; los drops y
préstamos deben seguir comprobándose, sin atajos que expongan memoria.

La migración de otras fuentes se realizará en incrementos compilables,
siempre desde `main` y sin sobrescribir una rama de trabajo ajena.
