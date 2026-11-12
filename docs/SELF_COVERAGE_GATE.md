# Stage 1: medidor JSON de autocobertura y puerta de regresiones

Este incremento corresponde al bloqueo **B10** del plan de autocobertura. No
cambia el frontend, verificador ni backend de ELE y **no acredita Stage 2**.

## Método y limitaciones

El script `tools/self_coverage_gate.py` invoca los binarios de Stage 1 que
generan los tests de integración con Stage 0 en Windows/MSVC:

1. `main_parser.exe archivo.l`;
2. `main_sema.exe archivo.l --check-ownership`;
3. `main_sema.exe archivo.l --emit-lir`;
4. `native_cfg_demo.exe archivo.lir archivo.elf`.

Solo avanza a la fase siguiente si la anterior pasa. Exige la cabecera
`ELE-LIR 1` y que el archivo nativo recién generado contenga una cabecera ELF,
para no contar como éxito una salida vacía o un artefacto obsoleto.

Cada fuente `.l` se ejecuta como **entrada independiente**: cuando llega a
semántica, el propio Stage 1 resuelve su clausura transitiva de imports mediante
`loadProgram`. Una fuente de biblioteca invocada como entrada puede fallar
aunque sea válida al importarla. El reporte incluye un **inventario estático**
del grafo alcanzable desde `main_sema.l`, producido por
`tools/ele_source_audit.py`; no sustituye los checks semánticos de ELE.

No hay ejecución de los ELF en esta medición, ni comprobación de paridad con
Stage 0, ni compilación de Stage 2. La generación del ELF se mide únicamente
cuando las fases previas pasan.

## Cómo ejecutar en Windows/MSVC

Primero construye los binarios Stage 1 con los tests del proyecto, por ejemplo:

```powershell
cargo test -p project-l --test modules_l --test self_hosting --test native_cfg_l -- --test-threads=1
```

Comprueba que existen los ejecutables en
`target/stage1-tests/{main_parser,main_sema,native_cfg_demo}/normal/` antes
de invocar el medidor. No todos los tests generan los tres binarios: en caso
de ausencia, el medidor **falla** en lugar de fabricar recuentos.

```powershell
python -m unittest discover -s tests/native_backend -p 'test_self_coverage_gate.py' -v
python tools/self_coverage_gate.py --baseline docs/SELF_COVERAGE_MATRIX_2026-11-11.md
```

La salida se guarda fuera del árbol versionado:

- `target/stage1-tests/self-coverage-gate/report.json`: resultado por fuente
  y fase, código de salida, código de error, mensaje y span cuando los emite.
- `target/stage1-tests/self-coverage-gate/report.md`: resumen legible.
- `target/stage1-tests/self-coverage-gate/generated/`: LIR y ELF producidos
  por el harness para diagnósticos posteriores.

La ejecución de GitHub Actions en Windows sube JSON y Markdown como artefactos
incluso si la puerta de regresiones falla. Para comparar con el reporte de una
ejecución anterior, también se puede usar `--baseline ruta/report.json`.

### Contrato de regresión

El Markdown histórico de 2026-11-11 se utiliza como **línea base de éxitos
previos**, no como medición actual. Cada fase anteriormente verde de cada fuente
debe permanecer verde. Las fases antes fallidas **pueden mejorar** y no se
exige conservar el texto de su error antiguo. Una fuente histórica que
desaparece del árbol provoca una regresión explícita.

La puerta devuelve códigos distintos:

- `0`: medición válida sin regresión frente a la referencia seleccionada.
- `1`: al menos un éxito histórico se perdió.
- `2`: el harness no pudo realizar una medición confiable.

No se han recalculado los valores 89/23/9/1 localmente en este cambio: su
origen es la matriz previa. Los nuevos recuentos deben tomarse exclusivamente
del artefacto de la ejecución CI.

## Siguiente incremento

B1 requiere ampliar la resolución real de módulos, no el inventario estático.
La siguiente medición deberá distinguir explícitamente el éxito del grafo
frontend completo y sus módulos críticos; no se debe proclamar autocobertura
del núcleo basándose solamente en el incremento de contadores aislados.
