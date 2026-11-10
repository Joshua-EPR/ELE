# Auditoría de Fuentes de Stage 1 y Matriz de Autocobertura

La primera matriz fue recuperada del trabajo interrumpido de Antigravity. Sus ocurrencias son un inventario léxico orientativo, no resultados de parser ni pruebas por característica. La verificación reproducible del 10 de noviembre de 2026 está al final de este documento y prevalece sobre las estimaciones iniciales.

## 1. Inventario General

Antigravity auditó **38 archivos `.l`**. Hay **40** actualmente: añadió `modules_l.l` y la recuperación separó `sema_collection_ops.l` para respetar el límite CORE-1.

| Característica | Ocurrencias | Archivos | Estado Stage 0 | Estado Stage 1 | Soporte LIR v1 | Backend Prov. | Bloqueo | Prioridad |
|---|---|---|---|---|---|---|---|---|
| **Acceso a campos (`.campo`)** | 3.916 | 38 | Completo | Structs OK; falla en colecciones/enums | Proyección `p<i>.campo` | Completo | Impide acceder a `.length`, `.byteLength` y variantes enum | **P0** |
| **Préstamos mutables (`&mut`)** | 1.101 | 35 | Completo | Completo (NLL / borrow checker) | `ref <lugar> 1` | Completo | Ninguno (verificado en Stage 1) | Resuelto |
| **Indexación (`col[i]`)** | 620 | 35 | Completo | Ausente en sema (`L0016`) | No emitido por Stage 1 | Completo en Cranelift | Impide acceder a tokens, AST y tablas indexadas | **P0** |
| **Préstamos compartidos (`&`)** | 545 | 38 | Completo | Completo (NLL / borrow checker) | `ref <lugar> 0` | Completo | Ninguno (verificado en Stage 1) | Resuelto |
| **Declaraciones de funciones (`fn`)** | 300 | 38 | Completo | Completo en ámbito único | `func f<k> ...` | Completo | Faltan imports para visibilidad inter-módulo | **P0** |
| **Llamadas a métodos (`.metodo()`)** | 256 | 30 | Completo | Rechazado en sema (`L0016`) | No emitido por Stage 1 | Completo en Cranelift | Impide `.push()`, `.byteAt()`, `.pop()`, `.reserve()` | **P0** |
| **Tipo `List<T>`** | 215 | 29 | Completo | Resuelto en anotaciones; métodos bloqueados | No emitido por Stage 1 | Completo en Cranelift | Impide operar sobre colecciones dinámicas | **P0** |
| **Sentencia `import`** | 205 | 31 | Completo (`modules.rs`) | Solo `import std.io.print` | Módulos consolidados | Completo | Bloquea 31 de 38 archivos del compilador | **P0** |
| **Tipo `Text`** | 169 | 30 | Completo | Literales y variables OK; `.byteAt` bloqueado | `ct<text>`, `textbuf`, `append` | Completo | Bloquea análisis léxico y manipulación de texto | **P0** |
| **Bucles `for` (`for i in a..b`)** | 128 | 30 | Completo | Completo con bloque de incremento | `jump`, `branch` | Completo | For-each (`for x in list`) no desazucarado | **P1** |
| **Expresión `match`** | 113 | 30 | Completo | Rechazado en sema (`L0016`) | No emitido por Stage 1 | Completo en Cranelift | Bloquea AST inspection, parsing y `pop()` | **P1** |
| **Bucles `while`** | 97 | 21 | Completo | Completo en sema y CFG | `jump`, `branch` | Completo | Ninguno | Resuelto |
| **Declaraciones `struct`** | 44 | 15 | Completo | Completo en sema | `struct s<k>` | Completo | Ninguno | Resuelto |
| **`printError`** | 34 | 3 | Completo | Built-in CLI | Runtime call | Completo | Ninguno | Resuelto |
| **`Err(...)` constructor** | 28 | 4 | Completo | Rechazado como genérico | No emitido | Completo | Bloquea reporte de errores en `lexer.l` | **P1** |
| **`Ok(...)` constructor** | 15 | 4 | Completo | Rechazado como genérico | No emitido | Completo | Bloquea retornos de `lexer.l` y CLI | **P1** |
| **Declaraciones `enum`** | 9 | 4 | Completo | Recolectadas; variantes bloqueadas | No emitido | Completo | Bloquea evaluación de `Enum.Variante` | **P0** |
| **`print`** | 9 | 4 | Completo | Completo | `i print <arg>` | Completo | Ninguno | Resuelto |
| **`Some(...)` / `None`** | 9 | 6 | Completo | Rechazado en sema (`L0016`) | No emitido | Completo | Bloquea inspección de `list.pop()` | **P1** |
| **`processArg`** | 7 | 3 | Completo | Built-in CLI | Runtime call | Completo | Ninguno | Resuelto |
| **Tipo `Result<T, E>`** | 3 | 2 | Completo | Rechazado como genérico (`L0016`) | No emitido | Completo | Bloquea firmas de `lexer.l` | **P1** |
| **`readText`** | 3 | 3 | Completo | Built-in CLI | Runtime call | Completo | Ninguno | Resuelto |
| **Tipo `Option<T>`** | 1 | 1 | Completo | Rechazado como genérico (`L0016`) | No emitido | Completo | Bloquea firmas auxiliares | **P1** |
| **Operador `?` (Try)** | 0 | 0 | Completo | No usado en código fuente de Stage 1 | No requerido | Completo | No bloquea el compilador | No crítico |

---

## 2. Métodos Utilizados en Stage 1

El código de Stage 1 solo invoca **4 métodos** en toda su implementación:

1. `.push(item)`: 181 llamadas en 28 archivos (mutación de `List<T>`).
2. `.byteAt(index)`: 58 llamadas en 5 archivos (lectura de byte en `Text`).
3. `.pop()`: 14 llamadas en 7 archivos (extracción en `List<T>`).
4. `.reserve(cap)`: 3 llamadas en 2 archivos (reserva en `List<T>`).

Además de las propiedades:
- `.length`: 304 accesos en 30 archivos (`List<T>`).
- `.byteLength`: 71 accesos en 5 archivos (`Text`).

---

## 3. Matriz de Compatibilidad por Módulo

Al analizar cada módulo de `compiler-l/src/` con Stage 1 (`main_sema.exe`), el diagnóstico inicial fue:

| Módulo | Diagnóstico Inicial | Causa Raíz |
|---|---|---|
| `decl.l`, `expr.l`, `stmt.l`, `parser.l`, `sema.l`, etc. (26 archivos) | `error[L0016]: import fuera del subconjunto semántico de Stage 1` | `sema.l` solo aceptaba `import std.io.print`. |
| `ast.l` | `error[L0001]: campo desconocido o proyección no verificada` en línea 170 | `tree.extra.length`: `sema_ops.l` no resolvía `.length` en `List`. |
| `flow_cfg.l`, `lir_build.l` | `error[L0016]: la constante requiere un literal en este subconjunto` | Constante negativa `-1000000000` es `Unary("-")`. |
| `tokens.l`, `cursor.l` | `error[L0001]: tipo desconocido: LexKind / LexToken` | Tipos definidos en `lexer.l` sin resolución de import. |
| `lexer.l` | `error[L0016]: argumentos genéricos fuera del subconjunto` | Firma `Result<Int, LexError>` rechazada en `sema_context.l`. |
| `sema_types.l` | `error[L0016]: expresión fuera del subconjunto verificado` | `table.types.push(...)`: `MethodCall` no implementado en `sema_expr.l`. |

---

## 4. Plan de Desbloqueo Incremental

1. **Incremento 1: Desbloqueo Inmediato de Sema**
   - Constantes unarias negativas en `sema.l` (`semaConstantType`).
   - Propiedades `.length` y `.byteLength` en `sema_ops.l` (`semaFieldFinish`).
   - Resolución de variantes `Enum.Variante` como constantes en `sema_ops.l`.
   - Resolución de tipos `Result<T, E>` y `Option<T>` en `sema_context.l`.
   - Soporte semántico de `MethodCall` para `.push()`, `.pop()`, `.reserve()` y `.byteAt()`.
   - Soporte semántico de `Index` (`base[index]`).

2. **Incremento 2: Soporte de Módulos e Imports (Fase C)**
   - Carga multi-módulo / consolidación en Stage 1 para resolver imports entre archivos.

3. **Incremento 3: Lowering a LIR de Métodos, Indexación y Match (Fases D, E, F, G)**
   - Instrucciones LIR para `.push`, `.pop`, `.reserve`, `byteAt`, `Index` y `Match`.
   - Verificador de LIR y extensión del protocolo si corresponde.

4. **Incremento 4: Backend Provisional (Fase H)**
   - Soporte de nuevas instrucciones en `lir_protocol.rs` y codegen Cranelift.

5. **Incremento 5: Compilación de Módulos Reales y Bootstrap Inicial (Fases I, J)**
   - Compilación nativa de módulos mediante Stage 1 + backend provisional.

## 5. Verificación reproducible de fuentes reales (10-11-2026)

Comando: ejecutable MSVC recién construido de `main_sema.l`, invocado con `--check-ownership` sobre cada uno de los 40 archivos de `compiler-l/src`. El barrido terminó con **9 aceptados y 31 rechazados**. `parser_l::test_parse_all_compiler_sources_self_hosting` confirma que el parser de Stage 1 procesa las fuentes, pero eso no equivale a análisis semántico ni compilación propia.

| Fuente y función representativa | Característica real | Parser | Semántica, ownership y CFG | LIR / backend | Primer bloqueo observado | Prioridad |
| --- | --- | --- | --- | --- | --- | --- |
| `ast.l`, `astAddExtra` | `List<Int>`, `.length`, `.push` | Sí | Aceptado | `--emit-lir` falla en línea 177 | Literal de lista sin lowering LIR y después regla 3 del verificador | P0 |
| `flow_cfg.l`, `flowNew` | Listas de structs y `.push` | Sí | Aceptado | Falla en línea 86 | `List[]` sin lowering LIR | P0 |
| `sema_types.l`, `typeTableNew` | `List<SemType>`, referencias, métodos | Sí | Aceptado | Falla en línea 34 | Literal de lista y regla 3 del verificador | P0 |
| `lexer.l`, `lexSource` | Imports, `Text.byteAt`, `Result`, listas | Sí | Aceptado mediante cargador provisional | Falla; el diagnóstico muestra línea 87 de la fuente combinada | LIR de listas/Result; localización por archivo incorrecta | P0 |
| `lir_build.l`, `lirFnNew` | Listas, structs, referencias | Sí | Aceptado | Falla al emitir | Listas y compatibilidad de tipos LIR | P0 |
| `main.l`, `parse_util.l`, `scopes.l`, `symbols.l` | Listas, `match`, tipos entre archivos | Sí | Aceptados | Todos fallan al emitir | Dependencias y construcciones sin LIR completo | P0 |
| `tokens.l`, `cursor.l` | Tipos definidos en otro archivo | Sí | Rechazados (`L0001`) | No ejecutado | Falta resolución real de símbolos y tipos importados | P0 |
| `decl.l`, `expr.l`, `parser.l`, `stmt.l`, `types.l`, `main_parser.l`, `main_sema.l`, `modules_l.l` | Imports transitivos, préstamos y AST | Sí | Rechazados (`L0012` en fuente combinada) | No ejecutado | Conflicto de préstamo; diagnóstico atribuido al archivo de entrada | P0 |
| `ownership_l.l` | Ámbitos y símbolos | Sí | Rechazado (`L0002`) | No ejecutado | Duplicación en ámbito tras carga | P1 |
| 20 módulos restantes (`lir_*`, `sema_*`, `drops_*`, `loans_*`, `stmt_lower.l`) | Tipos y funciones de otros módulos | Sí | Rechazados (`L0001`) | No ejecutado | Resolución de imports y tipos | P0 |

El cargador heredado `modules_l.l` carga dependencias recursivamente y concatena fuentes antes del análisis. Es provisional: no establece visibilidad, identidad nominal por módulo ni diagnósticos fieles por archivo. Por tanto, las nueve aceptaciones no validan imports entre módulos. El primer ciclo nativo adicional probado fue un programa de integración pequeño con `Text.byteLength` proyectado desde un struct (`lir_l::projected_text_length_uses_byte_length_in_backend`); **no** es un módulo de Stage 1.

El siguiente ciclo vertical es `flow_cfg.l::flowNew`: dar tipo contextual a `List[]`, emitir y verificar `listlit`, comprobar `push` y drops para `List<FlowBlock>`, después compilar un harness que invoque la función real. Antes de afirmar autocobertura entre archivos, reemplazar la concatenación por resolución de imports con identidad y visibilidad verificables.

## 6. Benchmarks MSVC de recuperación

Comandos: `bench/stage1-loans.ps1`, `stage1-drops.ps1` y `stage1-lir.ps1`, cada uno con `-Runs 1 -Compiler target/x86_64-pc-windows-msvc/debug/l.exe`. Una corrida de calentamiento y una medida por punto; cifras orientativas, no base suficiente para refactorizar rendimiento.

| Carga | 100 | 1 000 | 10 000 | Pico del punto mayor | Reservas / liberaciones del punto mayor |
| --- | ---: | ---: | ---: | ---: | ---: |
| Loans, tiempo total (ms) | 33,61 | 48,92 | 980,02 | 15 780 KiB | 31 107 / 31 107 |
| Drops, tiempo total (ms) | 33,17 | 106,97 | 1 649,40 | 36 112 KiB | 102 684 / 102 684 |
| LIR, `--emit-lir` (ms) | 35,62 | 633,71 | 5 571,04 | 19 424 KiB | 259 704 / 259 704 |

El punto LIR mayor generó 37 612 instrucciones, 7 426 bloques y 1 458 879 bytes de texto. `heap_ok=1` en las cargas medidas; no se ejecutaron sanitizers del código nativo generado. Las diferencias entre variantes de una única corrida incluyen ruido (por ejemplo, el punto LIR mayor midió `check` más lento que `emit`).

## 7. Avance verificado de fase 8.3

La matriz de §5 es línea base histórica. `flow_cfg.l::flowNew` y `flowBlock`, sin copiar sus cuerpos, ahora emiten LIR y se ejecutan nativamente mediante el harness que importa el archivo original. LIR: 116 bloques, 219 instrucciones, 30 drops; retorno 2 con paridad Stage 0. El cargador sigue concatenando archivos. [Cobertura y límites](PHASE_8_3.md).
