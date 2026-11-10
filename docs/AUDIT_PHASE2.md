# Auditoría de fase 2 — 2026-11-07

Se inspeccionaron especificación v1.0, prompt, todos los documentos derivados,
fuentes, Cargo/toolchain, ejemplos y pruebas. Contrato y ejemplos originales no
se modificaron. La suite de entrada pasó: 6 pruebas agrupadas, 0 fallos.

## Estado al comenzar

| Área | Estado comprobado |
|---|---|
| Lexer | Spans, ASCII identifiers, números, strings tokenizados y comentarios anidados |
| Parser/AST | Pratt, funciones, declaraciones, scopes y control estructurado; sin const |
| Semántica | Int/Float/Bool/unit, inferencia local, mutabilidad, firmas y retornos |
| LIR | Módulo independiente, tipos e IDs resueltos, control estructurado; no SSA |
| Backend | Emisión de fuente Rust y proceso rustc; enlaza un .exe real |
| CLI | check/build/run, dumps, help/version; check no necesita backend |
| Text | Rechazado en semántica; no había análisis de ownership |
| Constantes | No implementadas |
| Efectos y préstamos | No implementados |

La fase anterior sí transpila a Rust. No se encontró intérprete de programas L.
No se sustituye ese mecanismo en esta fase: el objetivo incremental es consolidar
semántica. La nueva prueba inspecciona MZ/PE, elimina sus fuentes L/Rust y ejecuta
el binario con PATH vacío. Esto demuestra autonomía del ejecutable, no backend
directo ni independencia de rustc durante la construcción.

## Hallazgos corregidos

- Faltaban constantes: ahora se resuelven y evalúan antes del backend.
- Faltaba Text semántico: ahora tiene representación estática no Copy y análisis
  de movimientos previo a codegen, sin GC.
- Un local que ocultaba una función no impedía llamar a la función exterior:
  ahora la llamada se rechaza como símbolo no invocable.
- El literal mínimo i64 se rechazaba: se admite la magnitud especial solo después
  de menos unario directo; valores positivos fuera de rango siguen rechazados.
- Overflow de literales runtime podía fallar en el compilador Rust en lugar de
  abortar el programa: se emiten checked_add/sub/mul/div/rem/neg explícitos.
- Todos los diagnósticos usaban L0001: ahora se distinguen léxico/sintaxis/semántica,
  const y ownership manteniendo archivo, línea y columna.

## Integración

La carpeta no tenía .git ni remoto. Se inicializó Git en la rama local
`dev/phase2-const-text`. No hay destino remoto para abrir PR; no se inventó uno.

## Brechas restantes

Frontend parcial (retornos inferidos, if valor, recovery, formatos numéricos),
IR sin CFG/SSA, runtime Text limitado, ownership conservador sin préstamos/vidas,
efectos no implementados y backend Rust provisional. No se han medido rendimiento,
memoria ni reproducibilidad. Solo Windows x86_64/MSVC está probado.
