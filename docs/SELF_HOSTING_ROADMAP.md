# Hoja de ruta de self-hosting de ELE

El lenguaje antes llamado «Proyecto L» se llama ELE; las secciones
anteriores conservan el nombre histórico.

La base de partida es `f0487fb` en `dev/native-async-timers`. Su árbol
estaba limpio y `48399cc` es ancestro. Se ejecutó la suite completa de
referencia con 326 aprobadas, cero fallos y tres pruebas manuales ignoradas
(`profile_local_loans`, `profile_reference_returns` y `profile_aggregate_views`).
El nuevo trabajo parte de esa base en `dev/self-hosting-foundation`.

El inventario y las restricciones están en
[SELF_HOSTING_GAP_ANALYSIS.md](SELF_HOSTING_GAP_ANALYSIS.md). La frontera
con Cranelift y las etapas están en
[BOOTSTRAP_ARCHITECTURE.md](BOOTSTRAP_ARCHITECTURE.md).

## Primer incremento

`Text.byteLength` implementa la propiedad de bytes de la especificación.
`Text.byteAt(index: Int) -> Int` es una extensión de biblioteca mínima.
Expone el byte UTF-8 como entero sin signo en el rango 0–255, hasta disponer
de `Byte`. Ambas operaciones leen el valor sin consumirlo ni copiarlo.
La propiedad carece de efectos propios. El método tiene efecto `panic` y
comprueba índices negativos y fuera de rango con el diagnóstico de límites
existente. El receptor se evalúa una vez antes del índice. Las operaciones no
asignan memoria por sí mismas.

`compiler-l/src/lexer.l` produce tokens con rangos de byte y EOF. Reconoce
palabras ASCII, literales de entero decimal como rangos, operadores,
separadores, saltos de línea, comentarios de línea y comentarios de bloque
anidados. Tolera UTF-8 en comentarios. Los errores informan clase y offset.
Quedan pendientes strings, interpolación, Float, espacios Unicode,
conversión numérica y límites de recursos propios del compilador completo.
El archivo implementa una función de biblioteca. En la fase 1, el harness
pasaba entradas UTF-8 construidas en el ejecutable. El scanner recorre los
bytes en L.

```powershell
cargo test --test self_hosting
cargo test
cargo fmt --check
cargo clippy --all-targets -- -D warnings
```

Las pruebas compilan con ambos backends y ejecutan los binarios. Incluyen
vacío, bytes UTF-8 multibyte y NUL, errores de rango, entrada inválida,
comentarios anidados y crecimiento de la lista de tokens. Comprueban
stdout, stderr, estado de terminación y la traza del heap nativo.

En la ejecución nativa de 45 000 bytes, el scanner emitió 10 001 tokens
incluido EOF. La traza registró una reserva, 12 redimensionamientos y
una liberación, con `heap_ok=1`. Se compiló y ejecutó también una
entrada corta con `PATH` vacío. No se usó un sanitizador del código
máquina generado.

Como control de la auditoría, el CLI Rust devolvió estado 1 y un
diagnóstico con ruta para un archivo inexistente, un archivo con bytes
UTF-8 inválidos y una ruta que era un directorio. También devolvió
estado 1 para un archivo vacío al exigir `fn main()`. El lexer L,
probado por separado, acepta texto vacío y entrega únicamente EOF.

## Segundo incremento

El [driver autónomo](LEXER_FILE_CLI.md) toma la ruta desde argv, lee
UTF-8 acotado y emite tokens o diagnósticos con estados de salida
explícitos. Usa el mismo lexer de biblioteca. Stage 0 compila el
driver, que luego procesa sus entradas sin harness. Se conservan
Cranelift y la referencia como oráculos de ejecución.

## Tercer incremento

La [paridad léxica](LEXER_PARITY.md) completa el soporte para strings,
secuencias de escape (`\n`, `\t`, `\r`, `\"`, `\\`, `\u{HEX}`), escalares
Unicode válidos, textos interpolados (`TextStart`, `InterpolationStart`,
tokens anidados, `InterpolationEnd`, `TextEnd`), llaves escapadas `{{` y `}}`,
y anidamiento recursivo de strings dentro de interpolaciones. Se añade la
API de navegación por tokens `TokenCursor` en `compiler-l/src/cursor.l`.

El [sistema de módulos](MODULE_SYSTEM.md) añade soporte en Stage 0 para
`import <ruta>` y `import <sub.modulo>` con canonicalización de rutas,
detección de ciclos con error explícito `L0014`, deduplicación determinista
en grafos diamante y combinación topológica de declaraciones en `Program`.
El ejecutable del lexer en L se compila modularmente sin concatenación de fuentes.

## Cuarto incremento

El [parser autónomo](PARSER_ARCHITECTURE.md) y [AST tipado en arenas](AST_LAYOUT.md)
implementan el análisis sintáctico completo en Proyecto L (`compiler-l/src/parser.l` y submódulos).
Soporta expresiones Pratt de 9 niveles de precedencia, declaraciones (`fn`, `pub fn`, `async fn`, `struct`,
`enum`, `import`, `const`), tipos primitivos/compuestos/genéricos, control de flujo (`if-else`, `while`,
`for`, `loop`, `break`, `continue`, `region`, `match`), recuperación ante errores con sincronización y
el driver CLI `parser-l` (`build-parser.ps1`) generando binarios nativos Cranelift libres de fugas.

## Quinto incremento

El [analizador semántico autónomo](SEMANTIC_ANALYZER_L.md) y [sistema de tipos](TYPE_SYSTEM_L.md)
implementan la resolución de nombres, chequeo de tipos estático y Adaptive Ownership en Proyecto L (`compiler-l/src/sema.l` y submódulos).
Soporta resolución jerárquica de símbolos con sombreado determinista (`scopes.l`), tabla de símbolos en arena (`symbols.l`),
árbol y equivalencia estructural recursiva de tipos (`sema_types.l`), tracking de ownership con unión conservadora en ramas (`ownership_l.l`),
comprobador de expresiones y sentencias desacoplado (`sema_expr.l`, `sema_stmt.l`, `sema_context.l`),
análisis en dos pasadas con reporte canónico de errores (`L0001` a `L0006`) y el driver CLI `sema-l` (`build-sema.ps1`) generando
ejecutables nativos Cranelift con balance perfecto y cero fugas de memoria (`allocs == frees`, `heap_ok=1`).

## Sexto incremento

El [CFG de Stage 1](STAGE1_CFG.md) reemplaza el seguimiento lineal
de ownership de fase 5. Verifica inicialización definitiva, movimientos
y campos de structs por punto fijo. El siguiente incremento añade
liveness y préstamos locales antes de inferir procedencia y drops.

## Secuencia y estimaciones

Los rangos indican incrementos verificables, no plazos de calendario.
Se revisarán al medir la paridad léxica y al validar la frontera de IR.

| Hito | Puerta de salida | Incrementos estimados |
| --- | --- | ---: |
| CLI del lexer | Argumentos, lectura UTF-8 acotada, estado explícito y diagnósticos de ruta probados en archivos reales. | Completado |
| Paridad léxica y módulos | Strings, interpolación, cursor de tokens, resolución de imports, detección de ciclos y orden topológico. | Completado |
| Parser y AST en L | Gramática recursiva/Pratt en L, nodos indexados por arenas de List, recuperación de errores. | Completado |
| Análisis semántico y tipos en L | Resolución de nombres y tipado del subconjunto con CFG, inicialización y movimientos. | Implementado para el subconjunto |
| Préstamos y drops de Stage 1 | Liveness local, exclusividad, procedencia de retornos, escapes y plan por arista. | Completado para el subconjunto |
| Stage 1 con backend provisional | LIR / CFG en L, serialización versionada, importación robusta y salida nativa. | Completado para el subconjunto (fase 7) |
| Stages 2–4 | Compilar el propio código, repetir generación y comparar equivalencia funcional. | 2–4 tras alcanzar la cobertura del código propio |
| Independencia completa | Sustituir backend y componentes críticos en Rust según resultados de ABI, rendimiento y pruebas. | Pendiente de diseño tras Stage 4 |

Préstamos, NLL, procedencia y plan de drops ya están en Stage 1. La
prioridad inmediata es la LIR de la fase 7.
Los riesgos dominantes son desajustes de tipos, privilegios de
layout al aceptar IR externa y cobertura insuficiente de ownership. Se
controlarán con pruebas diferenciales de AST, casos de IR inválida y la
suite de conformidad antes de migrar cada frontera.

## Incremento 6.2

El [borrow checker de Stage 1](STAGE1_BORROW_CHECKER.md) añade
préstamos, exclusividad, NLL, procedencia y retornos prestados sobre el
mismo CFG. El plan de drops es el último paso antes de la LIR.

## Incremento 6.3

La [elaboración de drops de Stage 1](STAGE1_DROP_ELABORATION.md) cierra
el análisis de ownership del subconjunto. La fase 7 baja el AST validado
a una LIR tipada consumiendo el CFG, los eventos y el `DropPlan`.

## Fase 7

La [LIR de ELE](STAGE1_LIR.md) cierra la cadena fuente → Stage 1 → LIR →
backend provisional → ejecutable nativo para el subconjunto actual.
Quedan dos frentes para la fase 8:

1. ampliar el subconjunto (enums, listas, métodos, `match`, imports
   entre módulos) hasta que Stage 1 analice sus propias fuentes;
2. compilarlas con la LIR (Stage 2) y comparar su comportamiento con
   Stage 1.

## Punto de control de fase 8.2

La recuperación de Antigravity preservó el trabajo no confirmado y cerró una regresión de pruebas. Stage 1 analiza nueve módulos propios aislados, pero ninguno de los probados emite LIR completa; no se ha producido Stage 2. El próximo hito verificable es compilar una función real de `flow_cfg.l` mediante un harness mínimo, tras implementar `List[]` y `List<T>` en parser, semántica, ownership, LIR y backend. Después, sustituir el cargador que concatena archivos por resolución de imports con identidad de módulo y visibilidad. Resultados: [STAGE1_SELF_COVERAGE.md](STAGE1_SELF_COVERAGE.md).

## Fase 8.3

`flow_cfg.l::flowNew` y `flowBlock` ya pasan por Stage 1, LIR y Cranelift y se ejecutan con paridad Stage 0. Persisten imports por concatenación, `Option`/`Result` y `match`. [Evidencia](PHASE_8_3.md).

### Estado intermedio 8.7.4.1

Primera operación **experimental** de lectura protegida de payload primitivo en el backend ELE; falta estandarizar el protocolo y conectar el serializador Stage 1, los generadores Rust/ELE y los invariantes de ownership/drops. `Option`/`Result` genéricos, `match`, `?`, runtime propietario y Stage 2 **no están completados**. No eliminar bootstrap.
