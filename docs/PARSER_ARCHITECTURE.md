# Arquitectura del Parser Autónomo en Proyecto L (Fase 4 Self-Hosting)

## 1. Visión General

El parser autónomo (`compiler-l/src/parser.l`) es la implementación formal de análisis sintáctico de Proyecto L escrita completamente en el propio lenguaje Proyecto L y compilada a binario nativo mediante Cranelift.

Consume el flujo de tokens producido por el lexer autónomo (`TokenCursor` y `List<LexToken>`) y construye un Árbol de Sintaxis Abstracta (AST) respaldado por arenas continuas en memoria (`List<T>`).

```
                [Código Fuente L (*.l)]
                           │
                           ▼ (lexer.l)
                 [List<LexToken>]
                           │
                           ▼ (cursor.l)
                     [TokenCursor]
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
          (decl.l)      (stmt.l)     (expr.l / types.l)
              │            │            │
              └────────────┼────────────┘
                           ▼
                    [AstTree (ast.l)]
       (Arenas: expressions, statements, types, decls)
```

---

## 2. Organización Modular y Límite CORE-1

Para respetar estrictamente el límite arquitectónico de Stage 0 (**máximo 4096 tokens por archivo fuente**, regla `CORE-1`), el parser se divide en submódulos especializados e independientes:

| Archivo | Tokens Aprox. | Responsabilidad |
|---|---|---|
| `compiler-l/src/ast.l` | ~1100 | Definición de nodos de arena, identificadores enteros, tipos de nodos y volcadores canónicos. |
| `compiler-l/src/parse_util.l` | ~1350 | Utilidades de coincidencia léxica, lookahead (`parserAtWord`, `parserAtSymbol`), consumo (`parserTakeWord`, `parserTakeSymbol`), expectativa (`parserNeedWord`, `parserNeedSymbol`) y cálculo de precedencias. |
| `compiler-l/src/types.l` | ~1150 | Parser de tipos atómicos (`Int`, `Float`, `Bool`, `Text`, `Unit`), referencias (`&T`, `&mut T`), arrays fijos (`[T; N]`), vistas/slices (`[T]`) y tipos nombrados/genéricos (`List<T>`, `Option<T>`). |
| `compiler-l/src/expr.l` | ~3400 | Parser de expresiones de precedencia Pratt (`parseExpr`), asociatividad, expresiones primarias, llamadas, métodos, campos, constructores con argumentos nombrados (`Name(k: v)`), tuplas unitarias y literales. |
| `compiler-l/src/stmt.l` | ~2750 | Sentencias de bloque (`parseBlock`), declaraciones locales (`let`, `var`), constantes (`const`), asignaciones (`=`, `+=`, etc.), control de flujo (`if-else`, `while`, `for`, `loop`, `break`, `continue`, `region`) y coincidencia de patrones (`match`). |
| `compiler-l/src/decl.l` | ~1850 | Declaraciones de nivel superior (`parseDecl`): funciones (`fn`, `pub fn`, `async fn`), structs (`struct`), enums con variantes con o sin carga (`enum`), constantes de módulo e imports (`import a.b.c`). |
| `compiler-l/src/parser.l` | ~250 | Orquestación general (`parseProgram`) y sincronización ante errores sintácticos (`parserSynchronize`). |
| `compiler-l/src/main_parser.l` | ~550 | Punto de entrada CLI del ejecutable `parser-l`. |

---

## 3. Algoritmo de Pratt y Precedencia de Operadores

El análisis de expresiones en `compiler-l/src/expr.l` utiliza el algoritmo de Pratt con números de precedencia idénticos a los del compilador Stage 0 (`crates/l/src/parser.rs`):

| Nivel | Operadores | Asociatividad |
|---|---|---|
| **1** | `\|\|` (OR lógico corto-circuito) | Izquierda |
| **2** | `&&` (AND lógico corto-circuito) | Izquierda |
| **3** | `==`, `!=`, `<`, `<=`, `>`, `>=` | No encadenable |
| **4** | `+`, `-` (suma y resta binaria) | Izquierda |
| **5** | `*`, `/`, `%` (multiplicación, división, módulo) | Izquierda |
| **8** | Prefijo: `-`, `!`, `&`, `&mut`, `await`, `spawn` | Derecha |
| **9** | Postfijo: `.campo`, `.metodo(args)`, `?` (try), `[indice]` | Izquierda |

---

## 4. Recuperación de Errores y Sincronización

El parser autónomo implementa sincronización robusta para evitar bucles infinitos y reportar múltiples diagnósticos:

1. **Garantía de Progreso:** Dentro de bucles de sentencias y bloques, si `parseStmt` o `parseDecl` falla y no consume ningún token (`cursor.pos == before_pos`), el cursor avanza al menos un token (`cursor.pos += 1`).
2. **Sincronización de Nivel Superior (`parserSynchronize`):** Tras un error en una declaración, el parser descarta tokens hasta encontrar un delimitador natural de sentencia (`;`, `}`) o el inicio de una nueva declaración (`fn`, `struct`, `enum`, `let`, `var`, `import`, `const`).
3. **Acceso Seguro a Fin de Spans:** Las funciones `astExprEnd`, `astStmtEnd`, `astTypeEnd` y `cursorPrevEnd` resuelven los spans sin evaluar índices negativos ni causar accesos fuera de rango durante el reporte de errores.

---

## 5. Driver CLI: `parser-l`

El ejecutable nativo compilado con Cranelift (`target/compiler-l/target/cranelift/x86_64-pc-windows-gnu/main_parser.exe`) se invoca como:

```bash
parser-l <archivo.l>
```

Salida estándar ante éxito:
```text
Decl::Function span=3..551 pub=false a=3 b=12 c=0 d=0 e=1
...
AstSummary decls=2 stmts=30 exprs=35 types=6 errors=0
```

En caso de errores sintácticos, emite diagnósticos con ubicación precisa:
```text
archivo.l:7:27: error[PARSER]: se esperaba token: ',' (byte 122)
```
y finaliza con código de salida `1`.
