# Gramática del subset de fase 2

No declara conformidad completa v1.0. Parser ejecutable: crates/l/src/parser.rs.

```ebnf
program = { module_header | print_import | ["pub"], (constant | function | struct | enum | trait) | impl } ;
constant = "const", identifier, [":", type], "=", expression ;
function = [attribute], "fn", identifier, [type_params], "(", [parameters], ")", ["->", type], [effects_annotation],
           ("=", expression, terminator | block) ;
attribute = "@noalloc" ;
effects_annotation = "!{", [effect, {",", effect}], "}" ;
effect = "alloc" | "io" | "panic" | "block" ;
type_params = "<", identifier, [":", TypeName], {",", identifier, [":", TypeName]}, ">" ;
trait = "trait", TypeName, "{", { trait_method }, "}" ;
trait_method = "fn", identifier, "(", [parameters], ")", ["->", type], [effects_annotation], (terminator | block) ;
parameters = identifier, ":", type, {",", identifier, ":", type}, [","] ;
type = type_atom, { "?" } ;                       (* T? = Option<T>; ?? = dos *)
type_atom = "Int" | "Float" | "Bool" | "Text" | "(", ")" | "Self"
          | TypeName, ["<", type, {",", type}, ">"] ;
struct = "struct", TypeName, "{", { field, (NEWLINE | ",") }, "}" ;
field = ["pub"], identifier, ":", type, ["=", expression] ;
enum = "enum", TypeName, ["<", identifier, {",", identifier}, ">"],
       "{", { variant, (NEWLINE | ",") }, "}" ;
variant = (identifier | "None"), ["(", [type, {",", type}], ")"] ;
impl = "impl", TypeName, "{", { ["pub"], ["mut" | "static"], function }, "}" ;
match = "match", expression, "{", { pattern, "=>", arm_body, ["," | NEWLINE] }, "}" ;
arm_body = block | "return", [expression] | "break" | "continue" | expression ;
pattern = "_" | ["-"], literal | name | [TypeName, "."], variant_name,
          ["(", [pattern, {",", pattern}], ")"] ;
block = "{", {statement, terminator}, [statement], "}" ;
statement = ("let" | "var"), identifier, [":", type], "=", expression
          | constant | place, assignment_op, expression
          | "return", [expression] | conditional | "while", expression, block
          | "for", identifier, "in", expression, (".." | "..="), expression, block
          | "loop", block | "break" | "continue" | block | expression ;
place = (identifier | "self"), { ".", identifier } ;
conditional = "if", expression, block, ["else", (block | conditional)] ;
assignment_op = "=" | "+=" | "-=" | "*=" | "/=" | "%=" ;
expression = literal | interpolated_text | identifier | "self"
           | identifier, "(", [arguments], ")" | "(", [expression], ")"
           | expression, ".", identifier, ["(", [arguments], ")"] | expression, "?"
           | match | "None" | unary | binary ;
arguments = argument, {",", argument}, [","] ;
argument = [identifier, ":"], expression ;   (* con nombre solo en constructores *)
terminator = NEWLINE | ";" ;
interpolated_text = '"', { text_chunk | "{", expression, "}" }, '"' ;
```

Pratt de menor a mayor: ?? (derecha), ||, &&, == !=, < <= > >=, + -, * / %, unarios - !,
postfijo `.campo` / `.metodo(...)` / `?` (el más fuerte). `match` al inicio de una
sentencia no exige terminador tras su `}`; dentro de sus llaves los saltos de línea
separan brazos aunque el match esté entre paréntesis. `..` y `..=` solo aparecen en la
cabecera de `for`; los rangos todavía no son valores. Un nombre de tipo empieza por
mayúscula ASCII (`TypeName`). Se rechazan como no implementados en este hito: guardas `if` en match.
`self` es palabra reservada para bindings y solo se usa como expresión.
Binarios asociativos a izquierda; comparaciones encadenadas prohibidas. Llamadas
solo a nombres directos. Asignación solo sentencia. Newline dentro de paréntesis
o después de operador/coma continúa expresión. Tras bloques de control no se exige
terminador. Última expresión sin ; es tail aunque siga newline; ; descarta el valor.

Identificadores ASCII y keywords reservadas; comentarios // y /* */ anidables.
Números decimales, separadores _, Float fracción/exponente. Int mínimo directo
-9223372036854775808 soportado; magnitud positiva aislada rechazada. Pendientes:
validación estricta de _, otras bases/sufijos, caracteres, arrays y referencias.

Text literal UTF-8 con escapes n/t/r/comillas/backslash y u{HEX} de 1–6 dígitos,
validando scalar Unicode. {{ y }} representan llaves literales. {expresión} se
tokeniza con delimitadores propios y tokens normales del lenguaje. Usa el mismo
Pratt parser y admite llamadas, comentarios y textos interpolados anidados.
Dentro de {} las nuevas líneas son espacio; el segmento literal no admite newline
sin escape. Las posiciones siempre corresponden a la fuente original. Los accesos
a campos y métodos funcionan también dentro de interpolación: `"{c.obtener()}"`.

Límites: 4096 tokens totales, incluidos segmentos internos, y 64 niveles de strings
anidados en lexer; parser/semántica mantienen límite de profundidad 128.

Constantes globales requieren terminador (o EOF); locales siguen reglas de
sentencia. Se conserva texto y posición en AST. break/continue sin valor y dentro
de bucle. if/bloques como inicializador y recovery multierror aún pendientes.

Regiones (2026-11-08): `region`, identificador, bloque es una sentencia
(`statement |= "region", identifier, block`). Dentro, `identificador.bytes(expr)`
reserva un buffer. `identificador.list<T>()` construye una lista regional vacía.
Usa la producción de llamada a método con argumentos de tipo. Exige un tipo de
elemento y cero argumentos de valor. El tipo regional se infiere localmente.

Un préstamo se puede vincular con `let nombre = &lugar` o
`let nombre = &mut lugar`. Opcionalmente se anota como `let nombre: &T = &lugar`.
Las anotaciones de referencia se permiten en parámetros y en estas
declaraciones de préstamos. La anotación `&[T]` o `&mut [T]` convierte un array,
lista o slice compatible en una vista local. Un lugar puede incluir campos e
índices. Los préstamos en argumentos de llamada conservan su sintaxis anterior.

Una firma puede declarar `-> &T` o `-> &mut T` si tiene al menos un parámetro
prestado compatible, incluido `self`. Con varios parámetros compatibles,
se infiere un contrato conservador que los incluye a todos. El cuerpo puede retornar un lugar directamente,
un préstamo explícito o el resultado de otra llamada que retorna por referencia.
La llamada que devuelve una referencia también puede inicializar un `let`.
Los nombres de lifetimes en firmas todavía no forman parte de la gramática activa.

Colecciones (2026-11-08):

```ebnf
type_atom  |= "[", type, ";", INT_LITERAL, "]"          (* array fijo [T; N] *)
            | "List", "<", type, ">" ;
param_type  = ["&", ["mut"]], type | "&", ["mut"], "[", type, "]" ;   (* slice en parámetros y anotaciones de préstamos *)
expression |= "[", [expression, {",", expression}, [","]], "]"         (* literal de array *)
            | "List", "[", [expression, {",", expression}, [","]], "]" (* literal de List *)
            | expression, "[", expression, "]" ;                       (* indexación, postfija *)
statement  |= "for", identifier, "in", expression, block               (* sin .. ni ..= : for-each *)
            | place, assignment_op, expression ;
place       = (identifier | "self"), { ".", identifier | "[", expression, "]" } ;
```

La indexación es un operador postfijo con la misma precedencia que `.campo`. Un `for`
cuya cabecera no contiene `..`/`..=` recorre una colección. Dentro de `[...]` los saltos
de línea son espacio. `List` es un nombre de tipo del lenguaje, no una palabra
reservada nueva.


Los structs concretos pueden declarar campos compartidos como `valor: &Int`.
La vista se crea como inicializador de un `let`, con argumentos nombrados
`Vista(valor: &lugar)`. Su lectura usa el acceso normal `vista.valor`.
Las declaraciones con `&mut` almacenado, referencias en variantes o colecciones
y lifetimes estructurales explícitos se reservan para incrementos posteriores.

Asincronía (2026-11-08):

```ebnf
function   |= "async", "fn", identifier, "(", [parameters], ")", ["->", type],
              [effects_annotation], ("=", expression, terminator | block) ;
expression |= "await", expression ;        (* precedencia de operador unario *)
expression |= "spawn", expression ;        (* la expresión es una llamada async *)
```

`async` solo precede a `fn` en una declaración libre (no en `impl` ni en
`trait`). `await` se analiza con la precedencia de un operador unario, de modo
que `await f() + 1` espera la llamada; la semántica restringe después dónde puede
aparecer (solo como valor completo de `let`/`var`, de una asignación con `=`, de
un `return` o como sentencia). `spawn` se analiza con la misma
precedencia y su operando debe ser la llamada a una función async; la semántica
exige además que aparezca dentro de una función async. `async`, `await` y
`spawn` ya eran palabras
reservadas; antes `spawn` se rechazaba con un diagnóstico de característica no
implementada. `Future<T>` y `TaskHandle<T>` son tipos del sistema de tipos, no
nombres escribibles: no aparecen en la gramática de tipos.


### Llamada intrínseca join

`await join(a, b)` usa la producción existente de `await` aplicada a
una llamada. `join` es un nombre reservado para esa llamada directa y
requiere dos argumentos posicionales de tipo `TaskHandle`. La expresión
completa ocupa una posición válida de `await`. El resultado se infiere
como un struct con los miembros `first` y `second`.


### joinAll y grupos vacíos

`await joinAll(tareas)` y `taskGroup(funciónAsync)` usan la sintaxis
existente de llamadas. `joinAll` requiere un argumento y una posición
admitida para `await`. `taskGroup` recibe el nombre de una función
async y permite inferir el tipo de un grupo vacío. Los literales
`List[...]` de handles del mismo tipo de resultado infieren un grupo.
El nombre de la función dentro de `taskGroup` selecciona el tipo y
no ejecuta la función. El grupo carece de sintaxis de anotación.

### Temporizador sleepMs

`sleepMs(ms)` usa la producción de llamada ordinaria. Recibe un
`Int` y produce `Future<()>`. Se puede usar en las expresiones
generales de `await` y con el resto de operaciones sobre futures.
