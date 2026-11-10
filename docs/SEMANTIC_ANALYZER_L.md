# Analizador Semántico Autónomo en Proyecto L (`sema-l`)

## 1. Visión General

El analizador semántico de Proyecto L (`compiler-l/src/sema.l` y submódulos) constituye la Fase 5 del plan de auto-alojamiento (*self-hosting*). Consume el Árbol de Sintaxis Abstracta indexado (`AstTree`) producido por el parser autónomo de la Fase 4 y realiza la resolución jerárquica de nombres, la comprobación estática de tipos, la validación de firmas y el seguimiento del modelo de memoria *Adaptive Ownership*.

El componente está completamente implementado en Proyecto L y se compila a código nativo de 64 bits mediante Cranelift a través de `compiler-l/build-sema.ps1`.

---

## 2. Restricciones Arquitectónicas y Regla CORE-1

Para satisfacer el límite estricto `CORE-1` (máximo 4096 tokens por archivo fuente compilable por Stage 0), la lógica semántica se dividió en submódulos especializados dentro de un Grafo Acíclico Dirigido (DAG) sin ciclos de importación:

```
tokens.l ──► lexer.l ──► cursor.l ──► ast.l ──► parser.l
                                       │
                    ┌──────────────────┴──────────────────┐
                    ▼                                     ▼
              sema_types.l                           symbols.l
                    │                                     │
                    ▼                                     ▼
              sema_context.l ◄──────────────────────── scopes.l
                    │                                     │
                    ├──► ownership_l.l ───────────────────┤
                    │                                     │
                    ▼                                     ▼
               sema_expr.l ────────────────────────► sema_stmt.l
                    │                                     │
                    └──────────────────┬──────────────────┘
                                       ▼
                                    sema.l
                                       │
                                       ▼
                                  main_sema.l
```

### Inventario de Módulos y Presupuesto de Tokens

| Archivo | Líneas | Tamaño | Responsabilidad |
|---|---:|---:|---|
| `sema_types.l` | 284 | 8.8 KiB | Definición de tipos semánticos, constructores deduplicados, predicados y equivalencia estructural recursiva. |
| `symbols.l` | 99 | 2.5 KiB | Definición de símbolos, arena plana `SymbolTable`, comparación rápida de cadenas en fuente. |
| `scopes.l` | 62 | 1.7 KiB | Árbol jerárquico de ámbitos con enlaces padre, detección de duplicados locales y resolución con sombreado (*shadowing*). |
| `ownership_l.l` | — | — | Punto fijo y validación de eventos de ownership sobre `flow_cfg.l`. |
| `sema_context.l` | 81 | 2.5 KiB | Contexto de análisis `SemaContext`, acumulación de diagnósticos `SemaError` y resolución de `AstType` a `SemType`. |
| `sema_expr.l` | 198 | 9.1 KiB | Comprobador de expresiones: literales, variables, operadores aritméticos/lógicos/relacionales, llamadas y campos de structs. |
| `sema_stmt.l` | 136 | 6.3 KiB | Comprobador de sentencias: declaraciones `let`/`var`, reasignación con control de mutabilidad, retornos, `if`, `while`, `for` y bloques. |
| `sema.l` | 101 | 4.8 KiB | Orquestador en dos pasadas: recolección de declaraciones globales y comprobación de cuerpos de función. |
| `main_sema.l` | 170 | 5.6 KiB | Driver ejecutable `sema-l`, lectura acotada de archivo, pipeline léxico-sintáctico-semántico y reporte canónico. |

Todos los archivos se mantienen por debajo de las 300 líneas y los 10 KiB, muy por debajo de los 4096 tokens permitidos.

---

## 3. Análisis en Dos Pasadas

Para permitir referencias hacia adelante entre funciones, estructuras y enumeraciones de nivel superior, el análisis semántico se ejecuta en dos pasadas formales:

### Pasada 1: Recolección de Declaraciones Globales (`semaCollectDeclarations`)
1. Recorre `tree.declarations`.
2. Para cada función, estructura, enumeración o constante:
   - Comprueba colisión en el ámbito global usando `scopeLookupCurrent`. Si ya existe, emite `error[L0002]: declaración duplicada en el mismo ámbito`.
   - Registra el símbolo en `SymbolTable` asociándolo al `scope_id = 0` (global).
   - Para estructuras y enums, registra un nuevo tipo nominal en `TypeTable`.
   - Resuelve firmas preliminares (tipo de retorno de funciones, tipo de constantes).

### Pasada 2: Comprobación Exhaustiva de Cuerpos (`semaCheckDeclarations`)
1. Recorre nuevamente `tree.declarations`.
2. Para cada función:
   - Empuja un nuevo ámbito léxico hijo del global con `scopePush`.
   - Vincula los parámetros formales en la tabla de símbolos como `SymbolKind.Param` y emite su inicialización en el bloque de entrada.
   - Establece el tipo de retorno esperado en `ctx.current_fn_ret_type`.
   - Desciende recursivamente por las sentencias del cuerpo (`decl.g`) mediante `semaCheckStmt`.
   - Restaura el ámbito léxico previo con `scopePop`.

---

## 4. Resolución de Nombres y Ámbitos Jerárquicos

El sistema de ámbitos desacopla la pila de llamadas de la ubicación física de los símbolos:
- Cada `Symbol` almacena explícitamente su `scope_id`.
- Cada `Scope` almacena únicamente su `parent: Int` (-1 para el ámbito global raíz).
- **`scopeLookupCurrent`**: Inspecciona únicamente los símbolos con `sym.scope_id == cur`. Si se encuentra una coincidencia, se detecta un intento de redeclaración ilegal en el mismo bloque (`L0002`).
- **`scopeLookupAll`**: Inicia en `ctx.scopes.current_scope` e itera hacia arriba siguiendo los punteros `parent`. Retorna la primera coincidencia encontrada. Esto proporciona sombreado léxico (*lexical shadowing*) determinista sin requerir listas de símbolos contiguas que puedan desfasarse al anidar bloques.

---

## 5. Ownership sobre CFG

La fase 6 genera eventos de lectura, movimiento y escritura al comprobar
cada expresión y sentencia. Las uniones de ramas y los bucles se resuelven
por punto fijo sobre el CFG de la función. Los eventos reutilizan los IDs
de símbolos y campos y conservan los rangos de diagnóstico. Se comprueban
transferencias y movimientos parciales de structs. Las referencias se
rechazan hasta que el análisis de préstamos sea operativo.
[Representación, algoritmo y cobertura](STAGE1_CFG.md).

## 6. Códigos Canónicos de Diagnóstico Emitidos

| Código | Significado | Ejemplo |
|---|---|---|
| `L0001` | Identificador no declarado o no invocable | `return undeclaredVar` o `x()` sobre un tipo no función |
| `L0002` | Declaración duplicada en el mismo ámbito | `let x = 1; let x = 2` |
| `L0003` | Discrepancia de tipos estática | Asignar `Bool` a `Int`, retorno incompatible, o condición de `if` no booleana |
| `L0004` | Error en llamada a función | Aridad incorrecta o tipo de argumento incompatible con parámetro formal |
| `L0005` | Infracción de Adaptive Ownership | Uso de un identificador tras haber sido transferido por valor |
| `L0006` | Infracción de inmutabilidad | Reasignar a una variable declarada con `let` en vez de `var` |

---

## 7. Compilación Nativa y Ejecución CLI

El script de compilación `compiler-l/build-sema.ps1` invoca el compilador Stage 0 con backend Cranelift:

```powershell
powershell -ExecutionPolicy Bypass -File compiler-l/build-sema.ps1
```

Genera el ejecutable nativo en:
`target/compiler-l/target/cranelift/x86_64-pc-windows-gnu/main_sema.exe`

Para analizar un archivo fuente con el analizador autónomo:
```powershell
main_sema.exe mi_programa.l
```

Salida exitosa canónica:
```
SemaSummary symbols=7 scopes=5 types=9 errors=0
```

Salida diagnóstica en caso de error (con código de salida 1):
```
mi_programa.l:12:5: error[L0005]: uso de valor movido
```
