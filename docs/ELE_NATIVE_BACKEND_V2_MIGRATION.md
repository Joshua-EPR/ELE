# Migración del núcleo CFG a ELE v2 — auditoría del PR #33

**Alcance:** equivalencia semántica de cinco fuentes del backend nativo
escritas en ELE. La extensión oficial se mantiene en `.l`.

**Base comprobada:** `main` en `39bcdf504268f97264afe4307a6c20df4442e773`.
El workflow diferencial fija la base usando el SHA del evento del PR,
no una referencia mutable. El último run diferencial aprobado fue
[Actions 43126045880](https://github.com/Joshua-EPR/ELE/actions/runs/43126045880)
para el commit `c6466e66b80fb0c02221d62df15c5616e48023e8`.

## 1. Fuentes migradas

| Módulo | Responsabilidad |
| --- | --- |
| `compiler-l/src/codegen/native_cfg_verify.l` | Dataflow, propiedad y movimientos |
| `compiler-l/src/codegen/native_cfg_emit.l` | Emisión ELF64, agregados, memoria |
| `compiler-l/src/codegen/native_cfg_ir.l` | Lectura, bloques y validación ELE-LIR |
| `compiler-l/src/codegen/native_cfg_inst.l` | Parseo y comprobación de instrucciones |
| `compiler-l/src/codegen/native_cfg_types.l` | Tipos, tamaños, layouts y proyecciones |

Migraciones: `import→take`, `pub fn→expose flow`, `fn→flow`,
`let→hold`, `var→change`, `if/else→when/otherwise`,
`for…in→each…among`, `while→during`, `return→give`,
`&mut/&→edit/view`, `->→=>`, `valor.metodo()→valor@metodo()`
y `List<T>→List of[T]`.

Los literales y comentarios, los identificadores de tipo, los códigos
de rechazo y el protocolo `ELE-LIR 1` permanecen intactos. Una
comparación estática adicional reconstruyó las cinco transformaciones
y confirmó **coincidencia exacta 5/5** contra los archivos del PR.
Esto comprueba el alcance del diff, pero la equivalencia ejecutable
se valida separadamente.

## 2. Auditoría diferencial reproducible

El script `tools/verify_native_cfg_migration.py` compila por separado
**ambas versiones reales del backend `native_cfg_demo.l`** desde
sus respectivas fuentes en la base y en el PR. Emplea un solo ejecutable
Stage 0, de manera que el bootstrap no altere la comparación.

El script también construye `main_sema.l` desde ambas versiones,
somete los compiladores a los mismos ejemplos, compara diagnósticos
y conserva un reporte JSON con SHA-256 en
`target/differential/native-cfg-results.json`.

Evidencia del run citado:

| Medición | Resultado |
| --- | ---: |
| ELE-LIR `native_cfg_*.lir` comparados | 147 |
| Aceptados y compilados a ELF64 idénticos byte a byte | 36 |
| Rechazados de manera idéntica, incluidos errores de ownership | 111 |
| Ejecuciones ELF64 con idéntico exit code, stdout y stderr | 18 |
| Fuentes de ejemplo `.l` con LIR y diagnósticos Stage 1 equivalentes | 44 |
| Diferencias semánticas detectadas en esa cobertura | 0 |

La comparación binaria estricta comprueba el contenido completo del ELF64
con SHA-256. Es más fuerte que comparar únicamente desensamblado
de una función, y evita diferencias de presentación entre versiones
de `objdump`. **No incluye los binarios bootstrap de Stage 0**, cuyos
metadatos de ruta pueden diferir.

La ejecución cruzada Windows→Linux y los tests nativos preexistentes
siguen disponibles en el workflow original. La nueva prueba diferencial
solo se ejecuta automáticamente para este PR de migración semánticamente
conservadora; ejecutarla incondicionalmente en PRs con cambios funcionales
legítimos daría falsos fallos.

### Diagnósticos y normalización

Se conserva toda la información de diagnóstico de Stage 1: código,
mensaje, línea y columna. La comparación solo normaliza finales de línea
y las dos rutas absolutas del checkout, porque ambas compilaciones pueden
referirse a un mismo archivo del checkout del PR.

`tests/native_backend/test_native_cfg_differential_contract.py`
comprueba con casos ejecutables que:

1. Mensajes idénticos bajo worktrees diferentes se comparan como iguales.
2. Cambios de código, ubicación o texto de un error siguen siendo diferentes.
3. CRLF y LF no crean falsos positivos.

El primer diseño del comparador cometió dos errores de expectativas
de prueba, **no** de semántica del compilador: clasificó un ELF que debe
fallar en ejecución con código 126 como si debiera rechazarse al compilar,
y normalizó un solo directorio al comparar los dos stderr. Ambos fueron
corregidos con sus comprobaciones correspondientes, sin silenciar errores.

## 3. Seguridad y límites de evidencia

Los checks abarcan instrucciones manipuladas, aliasing incompatible de
préstamos locales, índices dinámicos inválidos, movimientos parciales,
uniones de CFG, liberación de Text y List, returns de agregados y uso tras
movimiento. Se compararon los casos negativos con la base y se mantuvieron
los códigos de rechazo. Los ejemplos ejecutables seleccionados incluyen
traps de runtime y movimientos/ownership.

**Conclusión limitada:** no se detectaron regresiones de la migración en
los casos verificados. Esta evidencia no demuestra que la implementación
anterior estuviera libre de defectos ni constituye una auditoría formal
completa de seguridad de memoria.

Los contratos Python originales que inspeccionan estructuras de
código permanecen como checks de formato; ahora se complementan con una
prueba comportamental real de ambos compiladores y sus ELF64. No se
eliminó ninguna aserción de seguridad para pasar CI.

## 4. Qué permanece pendiente después del PR

- Migrar los demás archivos internos de `compiler-l/src` a ELE v2
  preservando la extensión `.l` y el lexer de transición.
- Representar `Option of[T]` en ELE-LIR, implementar `i listpop`,
  verificar drops/ownership de su valor devuelto y ejecutar fixtures
  de listas vacías y listas con elementos propietarios.
- Completar `dropfield` mediante referencias locales y pruebas de
  préstamos durante realocaciones, movimientos y ramas.
- Ampliar la cobertura de módulos reales de Stage 1 que emiten LIR y
  se compilan con el backend ELE.
- Generar Stage 2 con Stage 1, y luego Stage 3 con Stage 2; comparar
  resultados y resolver los errores de autocobertura.
- Completar emisor PE64, ABI de Windows, runtime nativo y CLI autónoma
  escrita en ELE.
- Continuar verificaciones de memoria, tipos, genéricos, `Result`,
  propagación de errores y pruebas negativas sin suavizar el verificador.

**Criterio de merge del PR #33:** deben estar verdes Ubuntu, Windows
MSVC, ejecución cruzada de ELF64 y el job diferencial sobre el último
HEAD. Esto no equivale a declarar toda la toolchain ELE lista para
producción ni self-hosted.
