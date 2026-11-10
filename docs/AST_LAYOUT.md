# Disposición de Memoria del AST (AST Layout) en Proyecto L

## 1. Principio de Diseño: Arenas Continuas

En lugar de construir grafos de punteros dinámicos con asignaciones dispersas por cada nodo del AST (lo cual generaría sobrecarga de asignación y fragmentación de memoria), Proyecto L utiliza **arenas planas continuas** basadas en `List<T>`.

Cada tipo de nodo del AST se identifica por un índice entero (`Int`) de 32/64 bits que referencia directamente una posición en su respectiva arena:

```l
struct AstTree {
    expressions: List<AstExpr>
    statements: List<AstStmt>
    types: List<AstType>
    declarations: List<AstDecl>
    params: List<AstParam>
    fields: List<AstField>
    variants: List<AstVariant>
    extra: List<Int>
    errors: List<ParseError>
}
```

---

## 2. Definición y Campos de los Nodos

Todos los nodos principales tienen una estructura compacta y regular:

### 2.1 Expresiones (`AstExpr`)

```l
enum AstExprKind {
    IntLit, BoolLit, TextLit, Interpolate, Name, UnitLit,
    Call, GenericCall, MethodCall, GenericMethodCall,
    Field, Index, Try, Await, Spawn, Unary, Binary,
    ArrayLit, ListLit, Match, Named
}

struct AstExpr {
    kind: AstExprKind
    start: Int
    end: Int
    a: Int
    b: Int
    c: Int
    d: Int
}
```

Interpretación de los campos `(a, b, c, d)` según `kind`:
- **`IntLit`**: `a` = valor entero.
- **`BoolLit`**: `a` = `1` (true) o `0` (false).
- **`TextLit` / `Name`**: `a` = inicio del lexema en `source`, `b` = fin del lexema.
- **`Binary`**: `a` = subexpresión izquierda (`lhs`), `b` = subexpresión derecha (`rhs`), `c` = inicio operador, `d` = fin operador.
- **`Unary` / `Await` / `Spawn` / `Try`**: `a` = operando, `b` = inicio operador, `c` = fin operador.
- **`Call`**: `a` = inicio de nombre, `b` = fin de nombre, `c` = índice en `extra` con lista de argumentos, `d` = cantidad de argumentos.
- **`MethodCall`**: `a` = receptor, `b` = inicio nombre método, `c` = fin nombre método, `d` = índice en `extra` para argumentos.
- **`Named`** (argumento con nombre): `a` = inicio nombre campo, `b` = fin nombre campo, `c` = expresión del valor.
- **`Match`**: `a` = expresión analizada (scrutinee), `b` = índice inicial de brazos en `extra`, `c` = cantidad de brazos.

### 2.2 Sentencias (`AstStmt`)

```l
enum AstStmtKind {
    Let, Const, Assign, Expr, Return, If, While, For, ForEach, Loop, Break, Continue, Block, Region
}

struct AstStmt {
    kind: AstStmtKind
    start: Int
    end: Int
    a: Int
    b: Int
    c: Int
    d: Int
    e: Int
}
```

- **`Let`**: `a` = nombre inicio, `b` = nombre fin, `c` = bandera mutable (`0` o `1`), `d` = tipo anotado (`-1` si inferido), `e` = expresión inicializadora.
- **`Assign`**: `a` = expresión destino, `b` = inicio operador (`=`, `+=`), `c` = fin operador, `d` = expresión valor.
- **`If`**: `a` = condición, `b` = bloque `then`, `c` = sentencia o bloque `else` (`-1` si omitido).
- **`Block`**: `a` = índice inicial en `extra`, `b` = número de sentencias en el bloque.
- **`For`**: `a` = nombre variable inicio, `b` = nombre variable fin, `c` = expresión inicio, `d` = expresión fin, `e` = índice en `extra` (inclusive flag + body).

### 2.3 Tipos (`AstType`)

```l
enum AstTypeKind {
    Int, Float, F32, Bool, Text, Unit, Named, Ref, Array, Slice
}

struct AstType {
    kind: AstTypeKind
    start: Int
    end: Int
    a: Int
    b: Int
    c: Int
}
```

- **`Ref`**: `a` = tipo interno referenciado, `b` = es mutable (`1` o `0`).
- **`Array`**: `a` = tipo del elemento, `b` = tamaño fijo constante.
- **`Slice`**: `a` = tipo del elemento.
- **`Named`**: `a` = nombre inicio, `b` = nombre fin, `c` = índice en `extra` para parámetros de tipo genéricos.

### 2.4 Declaraciones (`AstDecl`)

```l
enum AstDeclKind {
    Function, Struct, Enum, Import, Const
}

struct AstDecl {
    kind: AstDeclKind
    start: Int
    end: Int
    is_public: Bool
    a: Int
    b: Int
    c: Int
    d: Int
    e: Int
}
```

- **`Function`**: `a` = nombre inicio, `b` = nombre fin, `c` = es async (`1` o `0`), `d` = índice en `params`, `e` = número de parámetros.
- **`Struct`**: `a` = nombre inicio, `b` = nombre fin, `c` = índice en `fields`, `d` = número de campos.
- **`Enum`**: `a` = nombre inicio, `b` = nombre fin, `c` = índice en `variants`, `d` = número de variantes.
- **`Import`**: `a` = ruta inicio, `b` = ruta fin.

---

## 3. Buffer Adicional (`tree.extra`)

Para secuencias de tamaño variable (argumentos de llamadas, sentencias en bloques, elementos de listas/arrays literales, parámetros de tipos genéricos y brazos de match), se utiliza la arena unidimensional `tree.extra: List<Int>`.

Esto evita anidar colecciones o listas dentro de structs de nodos, garantizando que todos los nodos en `AstTree` tengan tamaño constante en memoria y preserven localidad espacial óptima.
