# Fase 8.7.10 — constructores amplios en el backend ELE

Estado: IMPLEMENTACIÓN PROPUESTA, PENDIENTE DE CI; no completa el compilador.

## Diseño

- Los operandos de i struct se almacenan en CfgProgram.struct_args,
  indexados por CfgInst.arg_first para instrucciones de clase 4.
- Los argumentos de llamada y tablas de préstamos quedan separados.
- cfgReadInst, comprobación de tipos, cfgMoves, cfgValidateInstruction,
  cfgPathUses y cfgEmitInstruction procesan todos los operandos en orden.
- Los movimientos propietarios se invalidan inmediatamente; se rechaza
  reutilizar una variable propia dos veces dentro de un constructor (57).
- Hasta 64 campos por shape. Se mantiene layout máximo de 512 bytes,
  por lo que 64 campos Int caben, pero 64 campos Text no.
- No se cambia el protocolo ELE-LIR 1.

## Pruebas nuevas

- native_wide_17_stage1.l: construcción, paso y retorno de 17 campos.
- native_wide_6_text_stage1.l: seis campos con dos Text propios.
- native_cfg_wide_64.lir: 64 campos Int, lee el último, estado 42.
- Rechazos: tipo 66, aridad 65, doble movimiento 57,
  campos fuera del límite 60, argumentos fuera del límite 64.
- native_wide_struct_l.rs ejecuta fuente .l -> Stage 1 -> backend ELE
  -> ELF64. CI compila en Windows/Ubuntu y ejecuta ELF en Linux.

## Límites

No están implementados List of[T] en backend nativo, préstamos locales,
payloads propios en choice, PE64 ni Stage 2/3. El verificador de
fugas de Text en joins de CFG todavía requiere mejoras.

## Validación

Comprobar tres trabajos CI, pruebas positivas y negativas, suite
completa Windows/MSVC y que no aumenten cinco fallas heredadas.
No afirmar éxito sin evidencia en GitHub Actions.
