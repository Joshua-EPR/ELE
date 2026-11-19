# Verificación de flags de drop en ELE-LIR (F1)

ELE-LIR trata los flags de drop como **datos no confiables**: una instrucción
`drop` o `dropfield` condicionada no puede confiar únicamente en que su
flag exista y tenga tipo `Bool`. Debe demostrar que el valor observado
representa el estado de propiedad del recurso al que protege.

## Invariantes

- **LIR_DROP:** el flag (`inst.a`) protege la variable destino (`inst.dst`).
- **LIR_DROPFIELD:** el flag (`inst.b`) protege la raíz del lugar
  `inst.a`; el lugar debe existir y tener un tipo que requiere drop.
- Cada flag que interviene en un drop condicional está asociado a una sola
  raíz; usar el mismo flag para raíces diferentes es inválido.
- Los flags se siguen por flujo abstracto con `Off`, `On` y `Unknown`;
  la propiedad se sigue con `Uninit`, `Init` y `Maybe`.
- En cada drop condicionado, el valor del flag debe coincidir con el estado
  de propiedad abstracto del recurso. Las salidas por salto y rama
  conservan la misma condición. Los joins divergentes son `Unknown/Maybe`.
- Una extracción propietaria de `Option`/`Result` consume la unión;
  un segundo uso, préstamo o drop sin un guard válido es rechazado.
- La verificación es **fail-closed**: una LIR manipulada no debe convertirse
  en código nativo si no se pueden justificar estas propiedades.

## Dos fronteras independientes

1. `crates/l/src/drops.rs`: lector/verificador Rust del protocolo LIR
   (bootstrap provisional).
2. `compiler-l/src/lir_verify.l`, `lir_verify_core.l` y
   `lir_verify_helpers.l`: verificador escrito en ELE.

Ambas fronteras deben conservar controles de tipos, inicialización,
proveniencia, estado abstracto y CFG, sin aceptar silenciosamente una
variante que la otra rechace.

## Regresiones reproducibles

La suite `crates/l/tests/stage1_owned_union_lir_l.rs` ejercita:

- Sustitución `cb0 -> cb1` después de mover un payload: riesgo de doble drop.
- Sustitución `cb1 -> cb0` conservando un payload: riesgo de fuga.
- Mutaciones equivalentes sobre `LIR_DROPFIELD` de campos `Text` y
  `List`, incluidos movimientos parciales.
- Fallos inyectados `--lir-fault=17` y `--lir-fault=18`:
  el verificador ELE debe emitir un error de Regla 6 sin escribir LIR válida.

La matriz de pruebas de compilación y ejecución debe mantenerse en Ubuntu y
Windows. Un resultado verde en la rama base de un PR apilado **no certifica**
automáticamente esta corrección de seguridad.

## Alcance

F1 endurece los verificadores de drop flags; **no** habilita por sí sola
la ejecución nativa de uniones propietarias en el backend ELE. Ese backend
continúa rechazando layouts/ABI no verificados (código 82) hasta integrar
la representación de payload activo y su drop glue.
