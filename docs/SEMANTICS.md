# Semántica de fase 2

Int=i64, Float=f64, Bool, unit, Text y struct. Inferencia local y anotaciones verificadas;
sin coerción implícita Int/Float/Bool/Text ni truthiness. Firmas tipadas conocidas
antes de cuerpos permiten llamadas anidadas, forward calls y recursión.

Retorno inferido: si se omite `-> T`, el tipo es el de los `return expr` y de la
expresión final sin `;` (todas deben coincidir); sin ninguno es (). Se resuelve por punto
fijo: una función cuyo cuerpo llama a otra aún no inferida se reintenta después. Si no
hay progreso (recursión o ciclo sin anotación) es error L0006 [inferencia] pidiendo
`-> Tipo`. `main` debe resultar en (). Parámetros inmutables; scopes léxicos, shadowing
anidado permitido, duplicados en mismo scope rechazados. Un binding local oculta
el nombre de función y no es invocable. No hay valores función aún.

let inmutable, var reasignable, inicializador obligatorio. Retornos comprobados
con análisis conservador de todas las rutas. Un `loop` sin `break` propio (los de
bucles anidados no cuentan) diverge y satisface el análisis; while/for no.

`for x in a..b` / `a..=b`: a y b son Int, se evalúan una vez (a antes que b); x es un
Int inmutable nuevo en cada iteración y su scope es el cuerpo. `a..b` excluye b, `a..=b`
lo incluye; si no hay elementos no itera. El paso no desborda: `..=i64::MAX` termina.
break/continue afectan al bucle más interno.
Código inalcanzable también se analiza. &&/|| cortocircuitan y argumentos se evalúan
izquierda a derecha. Condiciones exigen Bool. ; descarta valor de expresión/bloque.

## Constantes

const global/local evalúa literales, nombres de otras constantes, operaciones
unarias/binarias y cortocircuito durante análisis semántico. Tipos y nombres de
ambos operandos se validan aunque una rama no se evalúe. No admite variables runtime,
llamadas (incluso puras), IO ni asignación dinámica. Las constantes globales permiten
referencias adelantadas; resolución topológica detecta ciclos y colisiones de nombre.
Locales respetan orden/scope y pueden ocultar globales. No se reasignan. Un valor
const se sustituye por un literal tipado en LIR: no hay instrucciones runtime de const.
Const Text genera un valor nuevo por uso de datos estáticos; no es un binding movible.

Overflow o división/resto enteros inválidos en const son diagnóstico de compilación.
En expresiones runtime, checked_add/sub/mul/div/rem/neg abortan en fallo. Float sigue
IEEE-754 estricto sin fast-math:
- Tipos de coma flotante: `Float` (alias de `f64`), `f64` (64 bits, doble precisión) y `f32` (32 bits, simple precisión).
- Literales flotantes (`10.5`, `0.15`) infieren `Float` (`f64`) por defecto, o `f32` si el contexto de tipo esperado es `f32`.
- División entre cero de flotantes: produce `inf`, `-inf` o `NaN` (`0.0 / 0.0`) sin atrapar ni abortar.
- Semántica IEEE-754 para comparaciones con `NaN`: `NaN == NaN` es `false`, `NaN != NaN` es `true`, y todas las comparaciones de orden (`<`, `<=`, `>`, `>=`) que involucran `NaN` evalúan a `false`.
- Ceros con signo: `-0.0 == 0.0` evalúa a `true`.
- Conversiones numéricas explícitas: `Float(x)`, `f64(x)`, `f32(x)`, `Int(x)`. No hay conversiones implícitas entre enteros y flotantes.
  - La conversión flotante a entero `Int(f)` utiliza saturación (`fcvt_to_sint_sat`): `NaN` satura a `0`, valores mayores a `i64::MAX` saturan a `i64::MAX`, y valores menores a `i64::MIN` saturan a `i64::MIN`.
- Const Float puede producir infinito/NaN y el backend conserva los bits IEEE.

## Text y movimientos

Literales estáticos UTF-8 y resultados interpolados propietarios, sin GC.
Text no Copy: asignar, retornar o pasar por valor
mueve e invalida origen. Una var movida puede reinicializarse antes del uso. print
consulta como préstamo compartido intrínseco temporal; no consume su argumento
Text. Una llamada dentro de print sí mueve sus propios argumentos por valor.

ownership.rs comprueba disponibilidad antes de codegen. Tras if o cortocircuito,
se exige disponibilidad en todas las rutas analizadas. En bucles se prohíbe mover
Text exterior, aunque un programa concreto pudiera ser seguro; se admite leerlo
con print y mover valores creados dentro de cada iteración. Las ramas que retornan
y el código inalcanzable no se excluyen del análisis de movimientos: puede rechazar
programas seguros. No es un borrow checker NLL ni un análisis de lifetimes.

Text aún no tiene operador de concatenación, comparaciones, clone, indexación
ni préstamos explícitos. Estas formas se rechazan, no se
simulan. Arrays, efectos, funciones genéricas, traits y FFI pendientes.

Interpolación produce Text en cualquier contexto de expresión. Convierte Int,
Float, Bool y Text; unit se rechaza. Evaluación/formato de cada parte de izquierda
a derecha exactamente una vez. Interpolar un Text local lo consulta sin moverlo;
las llamadas dentro de una parte siguen moviendo sus argumentos por valor. El
préstamo de cada parte acaba antes de evaluar la siguiente, así que consultar y
después mover un Text en la misma interpolación es válido; hacerlo al revés no.

Interpolaciones puras con valores conocidos y evaluación exitosa se pliegan a
literal. No se ejecutan llamadas ni se eliminan efectos. Errores de una expresión
runtime constante (p.ej. 1/0) siguen siendo runtime; en const son diagnóstico.
Const interpolada admite referencias adelantadas a otras const, con detección de
ciclos. Texto plegado tiene límite de 1 MiB para evitar expansión exponencial.

## Structs e impl

`struct` declara un tipo nominal con campos tipados (primitivos u otros structs; () y
contención recursiva por valor se rechazan). Un nombre no puede repetirse entre structs,
funciones, const ni los tipos predefinidos. Construcción `Tipo(campo: valor, ...)`:
solo argumentos con nombre, cada campo como mucho una vez, campos sin default
obligatorios. Los argumentos se evalúan en el orden escrito y luego se materializan los
defaults. Un default es una expresión constante (mismas reglas que const, sin llamadas
ni constructores) evaluada en compilación; un default Text crea un valor nuevo por uso.

`a.campo` lee un campo; `a.b.c = v` y `+=` etc. asignan si la raíz es `var` o es `self`
dentro de `mut fn`. Parámetros y `let` no permiten mutar campos. Structs no tienen
operadores (`==` incluido), print ni conversión a Text; se rechazan.

`impl Tipo { ... }` (varios bloques permitidos, nombres de método únicos por tipo):
- `fn m()`: `self` implícito como préstamo compartido; no puede asignar campos ni llamar
  a `mut fn` sobre self.
- `mut fn m()`: `self` como préstamo exclusivo. `obj.m()` exige que obj sea un lugar
  (`var`, campo de un `var`, o self en `mut fn`); sobre temporales se rechaza.
- `static fn m()`: sin self; se llama `Tipo.m()`. Llamar static sobre un valor o un
  método de instancia sobre el tipo es error. `Self` nombra al tipo del impl.

`self` no se puede reasignar entero ni mover (pasar por valor o retornar). Un método de
lectura puede invocarse sobre un temporal (`Tipo.nuevo().m()`). En `obj.m(args)` los
argumentos se evalúan antes de activar el préstamo del receptor (como two-phase borrow);
si un argumento mueve obj, es error de ownership.

Ownership de structs: no son Copy; asignar, retornar o pasar por valor mueve. Leer un
campo Copy no mueve. Mover un campo no Copy (Text o struct) consume ese subárbol:
los hermanos siguen disponibles; usar el agregado completo requiere todos sus campos.
Leer un campo con print/interpolación es un préstamo temporal.
Un campo de un temporal sí puede extraerse (`crear().nombre`). Asignar un campo de un
struct ya movido es error; reasignar el binding completo lo reinicializa. Mismas reglas
de ramas y bucles que Text.

## Vistas locales con campos prestados

```l
struct Vista {
    valor: &Int
}
fn main() {
    let numero = 42
    let vista = Vista(valor: &numero)
    let movida = vista
    print(movida.valor)
}
```

La vista guarda un préstamo compartido por campo y se mueve como un struct
ordinario. Leer un campo prestado desreferencia su puntero. Los escalares se
leen por valor y Text se puede imprimir o interpolar sin tomar su propiedad.
Cada uso mantiene activos todos los préstamos de la vista hasta el último
uso en el CFG. El origen de un campo puede ser una proyección, por lo que
mutar un campo independiente del propietario puede ser compatible.
[Modelo estructural](AGGREGATE_LIFETIMES.md).

## Referencias y Borrow Checking (Adaptive Ownership)

Las referencias locales se declaran con `let r = &lugar` o
`let r = &mut lugar`. El origen queda fijo. Leer `r` desreferencia implícitamente
como en los parámetros. Asignar a `r` cuando es mutable escribe el referente.
Un valor propietario no se puede mover a través de la referencia. En llamadas,
un lugar pasado a `&T` se presta implícitamente. Si algún préstamo de la llamada
es mutable, sus lugares deben ser disjuntos. El préstamo local permanece activo
por los caminos del CFG que alcanzan un uso, incluso a través de un représtamo.
[Modelo de memoria](MEMORY_MODEL.md#2-referencias-locales-y-de-llamada).

### Retornos prestados

`fn nombre(u: &Usuario) -> &Text { return &u.nombre }` vincula el retorno
a `u`. El conjunto de origen incluye los parámetros prestados compatibles,
contando el receptor implícito. Un retorno `&mut` solo admite orígenes `&mut`.
Un `return` explícito o una expresión final puede seleccionar un campo o
elemento, usar un représtamo local o reenviar un retorno prestado. Cada ruta
debe alcanzar un parámetro incluido en ese conjunto. Una llamada que retorna una
referencia se usa como inicializador de `let` o como retorno prestado.

El llamador conserva el préstamo de cada lugar pasado como posible origen
hasta el último uso del resultado. Si pasó un `&mut`, la exclusividad sigue
vigente aunque el resultado sea compartido. Se admiten elementos de arrays,
listas y listas regionales a través de parámetros slice. El propietario
regional permanece en el llamador y su alcance limita el préstamo.

Se rechazan orígenes ausentes, locales y temporales. El diagnóstico
L0013 señala el retorno o la firma y explica la restricción. Los conflictos
con un resultado vivo usan L0012, con el sitio de llamada y un uso vivo.

La propuesta futura es la de la especificación §6, p. ej.
`fn elegir<'a>(a: &'a Text, b: &'a Text, primero: Bool) -> &'a Text`.
La vida inferida del resultado ya queda acotada por todas las vidas
compatibles. La sintaxis explícita queda pendiente. El almacenamiento general en contenedores y payloads genéricos queda pendiente. [Análisis de escapes](ESCAPE_ANALYSIS.md).

Proyecto L soporta referencias seguras `&T` (inmutables / compartidas) y `&mut T` (mutables / exclusivas):
- **Creación de préstamos**: `&lugar` y `&mut lugar`. Prestar requiere un lugar de memoria
  válido e inicializado. Prestar mutablemente una variable `let` inmutable se rechaza en sema.
- **Invariantes de aliasing**:
  - Múltiples lectores simultáneos (`&T`).
  - Un único escritor exclusivo (`&mut T`).
  - Prohibido crear un préstamo mutable si ya existen otros préstamos activos (compartidos o exclusivos).
  - Prohibido leer un valor mientras exista un préstamo mutable activo.
  - Prohibido modificar mediante asignación o reasignar una variable mientras tenga préstamos de lectura activos.
  - Prohibido mover un valor mientras esté prestado.
  - Prohibido mover valores a través de referencias (las referencias no son propietarias del destino).
  - Prohibido devolver referencias a variables locales del stack frame actual ("no se puede devolver una referencia a una variable local que deja de existir").

Pendiente: Copy opt-in, destructores definidos por el usuario (Drop), pub/visibilidad,
genéricos completos, traits, structs en const, inicialización posicional.

## Enums y match

`enum Nombre[<T, ...>] { Variante, Variante(Tipo, ...) }` declara una tagged union
nominal. El discriminante de cada variante es su índice de declaración (detalle de
implementación, no ABI: spec §5 exige `@repr` para FFI). Los enums no son Copy. Un
enum que se contiene a sí mismo por valor (directamente o a través de structs, o de
forma genérica como `L<T> { Cons(T, L<T>) }`) se rechaza por tamaño infinito.

Construcción: `Enum.Variante` o `Enum.Variante(datos)`; las variantes de enums del
prelude se escriben sin calificar (`Some(x)`, `None`, `Ok(v)`, `Err(e)`). Los datos se
evalúan de izquierda a derecha. Para enums genéricos los argumentos de tipo salen del
tipo esperado si es una instancia del mismo enum (anotación, parámetro, retorno, campo,
asignación, brazo anterior o `??`) y si no, de los tipos de los datos. Si alguno queda
sin determinar es error (`let x = None` pide anotación). Cada instancia concreta
(`Option<Int>`, `Option<Text>`) es un enum distinto en LIR (monomorfización).

`impl` funciona sobre enums no genéricos declarados en el archivo, con las mismas
reglas que en structs. Un método no puede llamarse como una variante. Enums no tienen
operadores ni print/interpolación.

`match e { patrón => cuerpo, ... }`: e se evalúa exactamente una vez; se ejecuta el
primer brazo cuyo patrón coincide. El cuerpo es una expresión, un bloque, o
`return`/`break`/`continue`. Patrones: `_`, nombre (enlaza el valor), literales Int
(con `-`), Bool y Text, y variantes con subpatrones anidados. Float como patrón literal
se rechaza (spec §4). Un nombre de variante de usuario sin calificar es error (evita
enlazar por accidente). Los bindings son inmutables y su scope es el brazo; repetir un
nombre en un patrón es error.

Exhaustividad y alcanzabilidad: algoritmo de utilidad (Maranget 2007) en
`exhaustive.rs`. Bool y enums tienen conjuntos finitos de constructores; Int y Text son
infinitos y requieren `_` o un nombre. Un brazo que nunca puede coincidir es error
("patrón inalcanzable"); un match no exhaustivo informa un ejemplo de valor no cubierto.

Como expresión el tipo es el de los brazos que terminan normalmente (deben coincidir;
el tipo esperado guía `None` y similares). Los brazos que divergen no aportan tipo; si
todos divergen el match diverge. Como sentencia (no en posición final de valor) los
valores de los brazos se descartan y pueden diferir.

Ownership: con scrutinee temporal los bindings poseen sus datos. Con un local propio,
leer un binding no Copy es un préstamo y el local sigue disponible; moverlo mueve el
local entero (sin movimientos parciales). Con un campo, `self` u otro binding prestado,
los bindings solo se pueden leer. En un brazo con bindings no Copy, el lugar examinado
no puede usarse directamente (ni leerse, asignarse, moverse o recibir `mut fn`). Tras
el match solo cuentan los brazos que terminan normalmente.

## Option, Result, `??` y `?`

`Option<T>` (`T?` es azúcar) y `Result<T, E>` son enums genéricos del prelude
(`src/prelude.l`). `a ?? b` exige `a: Option<T>`, `b: T`; evalúa a, y solo si es None
evalúa b. Es asociativo a la derecha y de menor precedencia que `||`.
`e?` exige que la función tenga retorno conocido del mismo enum: sobre `Option<T>`
devuelve `None` temprano o produce T; sobre `Result<T, E>` devuelve `Err(e)` temprano
con el mismo E (sin conversión) o produce T. Option↔Result no se convierten. `?` se
desazucara a un match en LIR, así que hereda sus reglas de ownership.

## Visibilidad

`pub` se admite antes de fn, struct, enum, const, campos y métodos. Con un único
módulo no hay accesos que restringir; se registra para módulos futuros. Una `pub fn`
sin `-> T` devuelve () (no se infiere, spec §4).

## Modelo de memoria (Adaptive Ownership, primera implementación)

Categorías de valores y dónde viven:

1. **Valores locales Copy** (Int, Float, Bool, ()): en variables/registros; sin recursos.
2. **Valores en heap**: hoy solo el buffer de un Text construido en ejecución
   (interpolación). Lo reserva el runtime y pertenece a exactamente un dueño.
3. **Literales estáticos**: Text literal o plegado en compilación; datos de solo
   lectura del ejecutable. Nunca se liberan.
4. **Recursos que poseen memoria dinámica**: Text con buffer propio y los agregados
   que contienen Text (structs y enums; enums todavía no en nativo).
5. **Referencias prestadas**: `self` y los bindings de match que prestan; también el
   préstamo temporal de `print`, la interpolación y los receptores de métodos. Nunca
   liberan nada y no sobreviven al lugar prestado (el lugar queda congelado mientras
   tanto, ver match).
6. **Valores movidos**: tras un movimiento el antiguo dueño no posee nada; no puede
   usarse ni liberarse.

Reglas de liberación (determinista, sin GC, sin conteo de referencias):

- Cada valor propietario se libera **exactamente una vez**, cuando su dueño deja de
  existir sin haberlo movido: fin de la sentencia para temporales, fin del bloque
  para variables (incluidos parámetros por valor y bindings de match por valor),
  `return`, `break` y `continue` (que abandonan los bloques intermedios).
- Reasignar una variable `var` libera su valor anterior después de evaluar el nuevo.
- Un valor movido en algunas rutas y no en otras se libera mediante un *drop flag*.
- Pasar un valor por parámetro, devolverlo, guardarlo en un campo o variante, o
  asignarlo a otro binding lo **mueve**. `print`, la interpolación y los receptores
  de métodos solo lo **prestan**.
- `panic` termina el proceso por abort: **no** se ejecutan drops; el sistema
  operativo recupera la memoria del proceso.

Invariantes que el compilador demuestra en la LIR de bloques (`drops::verify`) antes
de generar código: no se usa ni se mueve un valor posiblemente movido; no hay drop
incondicional de algo sin valor (doble liberación); ninguna asignación sobrescribe
un valor propio (fuga); al retornar no queda nada propio (fuga). Junto con el
análisis de ownership de la fuente (que rechaza uso tras movimiento, movimientos en
bucles de valores exteriores y préstamos que podrían colgar),
esto descarta double-free, use-after-free y fugas en las rutas soportadas.

Los structs se rastrean por rutas jerárquicas (raíz + índices de campos). Cada hoja
propietaria tiene estado Init, Uninit o Maybe; Maybe requiere un drop flag. El drop
del agregado libera únicamente las hojas todavía propias, en orden inverso. Se
puede reinicializar un campo movido o reemplazar un subárbol completo. No se permite
escribir dentro de un padre movido ni mover campos de self/patrones prestados.
La inicialización parcial aquí significa reconstrucción después de un movimiento;
no se admiten declaraciones de structs sin inicializador. Los movimientos de campos
exteriores a un bucle siguen rechazados conservadoramente.

Enums nativos y drops condicionados por variante:
En Cranelift, los enums se representan como agregados etiquetados con un discriminante en
el offset 0 (i64, alineación 8) y el payload alineado según los campos de cada variante.
Cuando un valor de enum sale de scope o se destruye, la liberación es sensible a la variante:
se inspecciona el discriminante en tiempo de ejecución y se ejecutan exclusivamente los drops
de los campos dinámicos de la variante activa (como Text, structs anidados con Text o
enums anidados). Los payloads de variantes inactivas no se tocan.
El match evalúa el scrutinee una sola vez en un slot de pila dedicado, ramifica según el
discriminante y proyecta los campos mediante Proj::Payload(variante, índice).
El prelude (Option<T>, Result<T, E>, ??, ?) opera nativamente bajo estas reglas.
El verificador comprueba estados por campo; la correspondencia del valor de cada
flag con su ruta la mantiene la elaboración, no constituye una prueba formal
independiente de flags arbitrarios insertados por un tercero.

Preparado para crecer: la elaboración opera sobre cualquier tipo con `needs_drop`
(arrays/listas encajarán como nuevos tipos propietarios); un futuro análisis de
escape podrá sustituir reservas en heap por espacio de pila o de región sin cambiar
las reglas anteriores, porque los drops ya son explícitos en la LIR.

## Sistema de Efectos Estático y @noalloc

Proyecto L implementa un sistema de tipos y efectos estático con verificación interprocedimental sobre el grafo de llamadas:

1. **Anotaciones de efectos (`!{...}`) y Pureza (`!{}`):**
   - Una función sin anotación de efectos infiere sus efectos automáticamente en función de su cuerpo y de las funciones que invoca transitivamente.
   - Una función anotada explícitamente (`fn f(...) -> T !{alloc, panic}`) establece un contrato que limita los efectos permitidos. Si el cuerpo o sus llamadas transitivas exceden este conjunto, el compilador emite un error `L0010 [efectos]`.
   - `!{}` denota pureza estricta (conjunto vacío de efectos): la función no puede asignar en heap (`alloc`), no puede realizar I/O (`io`), no puede bloquear (`block`) y no puede entrar en pánico ni desbordar (`panic`).
   - Los cuatro efectos fundamentales son:
     - `alloc`: asignación dinámica de memoria en heap (interpolación no constante de texto, constructores dinámicos).
     - `io`: operaciones de entrada/salida (como la función intrínseca `print`).
     - `panic`: operaciones que pueden abortar el programa en tiempo de ejecución, notablemente aritmética entera con comprobación de desbordamiento (`+`, `-`, `*`, `/`, `%`, negación de `i64::MIN`), así como aserciones. Las operaciones de punto flotante (`Float`, `f32`, `f64`) bajo IEEE 754 no producen `panic` (generan `NaN` o `inf`).
     - `block`: operaciones bloqueantes o de sincronización (incluye `print`).

2. **Atributo `@noalloc`:**
   - La anotación `@noalloc fn f(...)` exige estáticamente que la función (y cualquier función invocada por ella) no realice asignaciones dinámicas en el heap (`alloc`).
   - El compilador garantiza esto en compilación. La memoria de pila (`StackSlot`), las variables locales, el paso de parámetros, los structs por valor y los literales estáticos (`Text` con `cap == 0`) están totalmente permitidos.

3. **Análisis Interprocedimental y Grafo de Llamadas:**
   - El compilador construye el grafo de llamadas y propaga los efectos transitivamente mediante un algoritmo de punto fijo.
   - Si una función `f` viola su contrato debido a una llamada profunda `f -> g -> h`, el diagnóstico visualiza la traza completa de llamadas para facilitar la depuración.
   - Los contratos de métodos en `trait` definen los efectos máximos permitidos; cualquier `impl Trait for Type` debe respetar o ser un subconjunto de los efectos contratados en la definición del trait.

## Regiones de memoria

`region nombre { ... }` abre una región léxica; `nombre.bytes(n)` reserva un buffer
`Bytes` de `n` bytes a cero, alineado a 8, que vive como mucho lo que la región.
`buffer.len()`, `buffer.get(i)` (0..=255) y `buffer.set(i, v)` (requiere `var` o
`&mut Bytes`) comprueban límites y rango con panic. Un buffer no puede devolverse,
guardarse en campos/enums/genéricos ni asignarse a una variable de otra región
(L0011); se pasa a funciones como `&Bytes`/`&mut Bytes`. La región se libera al
salir del bloque por cualquier ruta, después de sus otros locales. `bytes` tiene
efectos `alloc` y `panic`. Semántica formal en [MEMORY_MODEL.md](MEMORY_MODEL.md).

## Colecciones: arrays, slices y List (2026-11-08)

Tipos: `[T; N]` (array fijo, `N` literal entero), `&[T]`/`&mut [T]` (vista, solo como
tipo de parámetro, igual que las demás referencias) y `List<T>` (lista dinámica que
posee un buffer en el heap). Los tres admiten cualquier `T` del lenguaje (Int, Float,
Bool, Text, structs, enums, otras colecciones).

- **Construcción.** `[e1, …, en]` es un `[T; n]`; `List[e1, …, en]` es una `List<T>` con
  capacidad exactamente `n`. Los elementos deben tener el mismo tipo (con inferencia
  por el primero o por la anotación). `[]` y `List[]` exigen anotación
  (`let a: [Int; 0] = []`, `var l: List<Int> = List[]`); `List[]` no reserva memoria.
- **Longitud y capacidad.** `.length` (Int) en arrays, slices y listas; `.capacity` solo
  en listas.
- **Indexación.** `c[i]` con `i: Int`. Todo acceso se comprueba: fuera de `0..length`
  es un panic `Proyecto L l:c: índice fuera de rango` en la posición del `[` (ambos
  backends). Con índice constante sobre un array fijo el error es de compilación
  (`L0001`); un índice constante negativo siempre lo es.
- **Elementos y propiedad.** Leer `c[i]` por valor solo está permitido si el elemento es
  Copy (Int, Float, Bool). Un elemento con recursos (Text, struct con Text, lista…) se
  puede leer donde la lectura es un préstamo (`print`, interpolación, campos Copy
  como `personas[0].edad`, `for`), pero **no se puede mover fuera** (sin movimientos
  parciales; `L0005`). `c[i] = v` reemplaza el elemento: el anterior se libera.
- **Movimientos.** Arrays y listas se mueven siempre (también `[Int; N]`): no hay copias
  implícitas de colecciones. `let otros = nombres; print(nombres.length)` es `L0005`.
- **Métodos de List** (exigen `var` o `&mut`): `push(x)` mueve `x` al final;
  `pop()` devuelve `T?` (`Some` con el último elemento movido fuera, o `None`);
  `reserve(n)` garantiza `capacity - length >= n`. Funcionan también sobre listas
  dentro de elementos o campos: `filas[i].push(x)`, `b.items.push(x)`.
- **Política de capacidad** (idéntica en ambos backends, observable con `.capacity`):
  literal = longitud; `push` con la lista llena → `max(4, 2·cap)`; `reserve(n)` cuando
  falta espacio → `max(len + n, 2·cap)`. Todo cálculo se comprueba: `n` negativo →
  panic `reserve con tamaño negativo`; número de elementos o bytes por encima de
  `i64::MAX` → panic `capacidad de List desbordada`; heap agotado → panic
  `memoria insuficiente`. La cabecera solo cambia tras una reserva exitosa.
- **Iteración** `for x in c`: si el elemento es Copy, `x` es una copia; si no, `x` es un
  préstamo de solo lectura del elemento. La colección queda prestada durante todo el
  bucle: `push`, `pop`, `reserve`, `c[i] = …` o mover `c` dentro del cuerpo es `L0005`.
  Una colección temporal (`for x in List[…]`) vive hasta el final del bucle.
- **Slices.** Un parámetro `&[T]` acepta un array, una lista o otro slice del mismo
  `T`, con préstamo implícito (`sumar(numeros)`); `&mut [T]` exige `&mut c` y permite
  asignar elementos pero no cambiar la longitud. Un `let` anotado puede mantener
  una vista local hasta su último uso. Una función puede devolver el slice
  prestado con el mismo tipo de vista y un contrato de origen válido.
- **Efectos.** Un literal de array no reserva (vive en el marco). Indexar es `panic`
  salvo índice constante sobre array fijo. `List[…]`, `push` y `reserve` son
  `alloc` + `panic`; `pop`, `.length` y `.capacity` no tienen efectos. Por tanto
  `@noalloc fn crearLista() { let numeros = List[1, 2, 3] }` es `L0010`.
- **Liberación.** Una lista libera sus elementos vivos (en orden) y después su buffer
  al salir de su scope, en retornos anticipados, `break`/`continue` y al reemplazarla;
  un array libera sus elementos. Un elemento sacado con `pop` pasa a ser del receptor.

No implementado (rechazado con diagnóstico): igualdad o `print` de colecciones
completas, `for` con `&mut` sobre elementos, llamadas a métodos de usuario sobre
elementos (`personas[0].saludar()`), rangos como índices (`a[1..3]`), sintaxis de
repetición `[x; N]`.

### Listas regionales

`r.list<T>()` crea una lista vacía sin reservar almacenamiento para elementos.
Su tipo interno `RegionList(T, r)` conserva el identificador léxico de `r`.
Se mueve como una lista, con la misma sintaxis de índices, iteración, longitud,
capacidad, `push`, `pop` y `reserve`. Una reasignación exige el mismo tipo de
elemento y la misma región. La lista no se convierte a `List<T>` del heap, ni
se devuelve, ni se incorpora a agregados o instancias genéricas como valor.

Se puede prestar mediante un parámetro `&[T]` o `&mut [T]`. La vista termina al
retornar de la llamada. Se aplican las reglas existentes de aliasing y el préstamo
durante `for`. Los elementos que salen con `pop` son independientes de la región.

`push` y `reserve` conservan los efectos `alloc` y `panic` incluso si una reserva
lógica cabe en el bloque activo. Crear una cabecera vacía no asigna. El bloque
`region` conserva su clasificación conservadora de efectos.

### Retorno de agregados con referencias y contratos de lifetime

Las funciones y métodos pueden retornar structs que contengan referencias compartidas (`&T`).
- **Contratos de retorno:** La firma asocia cada campo prestado a sus parámetros formales y proyecciones válidas (`ViewReturn`, `FieldContract`).
- **Propagación interprocedimental:** Las llamadas que reenvían vistas o que acceden a sus campos conservan la cadena de procedencia hasta el parámetro raíz del llamador.
- **Préstamos disjuntos:** Prestar un campo de una estructura mediante una vista retornada permite que el llamador continúe leyendo o modificando otros campos demostrablemente disjuntos del propietario.
- **Rechazo de escapes:** Cualquier intento de retornar un agregado que contenga una referencia a un valor local, agregado local, temporal o elemento de lista/región local es rechazado en compilación con diagnóstico `L0014`.
- **Restricciones actuales:** Las vistas no pueden ser anidadas en otros tipos agregados ni almacenadas en colecciones. [Detalle](BORROWED_AGGREGATE_RETURNS.md).

### Referencias mutables en agregados y reasignación de vistas

Los structs pueden declarar campos con referencias mutables exclusivas `&mut T`.
- **Exclusividad mutable:** Un campo `&mut T` confiere acceso exclusivo al referente mientras la vista permanezca viva. No se permite crear vistas mutables superpuestas ni coexistir con préstamos compartidos sobre el mismo lugar (`L0012`).
- **Semántica Move:** Los structs con referencias mutables o compartidas no implementan `Copy`. Cualquier cesión o movimiento invalida el binding de origen (`L0005`).
- **Acceso y modificación:** El acceso a través de campos mutables (`vista.campo = valor`, `self.campo += 1`) desreferencia automáticamente el puntero subyacente. Los campos inmutables `&T` no admiten asignación.
- **Reasignación segura:** Se permite declarar variables de vista mutables (`var vista = Vista(...)`) y reasignarlas posteriormente (`vista = Vista(...)`). El compilador actualiza las relaciones de procedencia, terminando el préstamo anterior y activando el nuevo préstamo, incluso en presencia de bifurcaciones condicionales (`if/else`).

### Referencias en enums, Option, Result, arrays y colecciones

Los tipos compuestos y colecciones pueden almacenar referencias compartidas `&T` y mutables `&mut T`:
- **Enums y variantes (`Option<&T>`, `Result<&T, E>`, enums personalizados):** Soportan constructores con referencias (ej. `Option.Some(&x)`, `Result.Ok(&mut y)`, `Respuesta.Par(&a, &mut b)`). El desempaquetado mediante `match` extrae enlaces de referencia directos que pueden retornarse, reenviarse o utilizarse en expresiones.
- **Operador de intento `?`:** Propaga transparentemente la procedencia de referencias contenidas en `Result<&T, E>`, permitiendo reenvío de referencias en firmas interprocedimentales.
- **Colecciones con referencias:** Se permiten literales de arrays `[&a, &b]`, listas dinámicas `List[&a, &b]`, inserciones dinámicas `xs.push(&c)` y listas regionales `r.list<&Int>()`. La indexación `xs[i]` desreferencia el valor transparentemente para uso por valor, o preserva la referencia cuando se requiere un operando prestado.
- **Iteración `for x in coleccion`:** Itera sobre elementos prestados vinculando `x` como referencia y manteniendo bloqueada la colección durante el bucle.
- **Semántica de movimiento:** Las colecciones y variantes que contienen referencias no son `Copy`. La transferencia de la colección o variante mueve el contenedor e invalida el origen.
- **Escape checking:** Retornar una colección o variante que contenga referencias a variables locales, buffers regionales locales o temporales se rechaza con `L0014`/`L0013`.

## Asincronía: async, await, futures y tareas (2026-11-08)

Modelo completo en [ASYNC_MODEL.md](ASYNC_MODEL.md); runtime y ejecutor en
[FUTURE_RUNTIME.md](FUTURE_RUNTIME.md).

- `async fn f(params) -> T` declara una función asíncrona. **Llamarla no ejecuta
  su cuerpo**: construye una tarea y devuelve un `Future<T>`, un tipo opaco y
  propio de cada función async (no se puede nombrar en una anotación, almacenar
  en un agregado, devolver ni pasar como argumento).
- Sin `-> T` el resultado es `()`: una función async nunca lo infiere, porque
  quien la llama necesita su tipo future antes de comprobar ningún cuerpo.
- `await e` sondea el future hasta que esté listo y produce su resultado,
  suspendiendo la función async que espera mientras siga pendiente. Consume el
  future: un segundo `await` sobre el mismo valor es un uso tras movimiento.
- `await` solo dentro de una función async y solo como el valor completo de un
  `let`/`var`, de una asignación con `=`, de un `return` o como sentencia por sí
  sola. Cualquier otra posición es `L0015` (así ningún temporal a medio construir
  tiene que sobrevivir a la suspensión).
- `yieldNow()` es la primitiva integrada de suspensión: devuelve `Pending` una
  vez, notificando a la tarea de inmediato, y queda lista en el siguiente sondeo.
- `spawn f(args)` registra la llamada async como **tarea independiente** del
  planificador y devuelve un `TaskHandle<T>` que la posee: un tipo opaco y
  propio de cada función async, propietario y no copiable. Solo dentro de una
  función async. `await t` sobre un handle lo consume: suspende la tarea que
  espera hasta que la otra termine y produce su resultado.
- `await join(a, b)` consume dos handles del ámbito async y espera ambos
  resultados cooperativamente. El struct inferido tiene campos `first`
  y `second` con el tipo y orden de los argumentos. Un resultado temprano
  permanece en su tarea hasta que se entrega el par o se cancela al padre.
  La operación de espera usa el espacio del estado existente. Los efectos
  de las tareas hijas se atribuyen a `spawn`.
- `await joinAll(tareas)` consume un grupo local y devuelve una lista
  de resultados homogéneos en orden de inserción. Puede formarse por
  inferencia con `List[spawn f(...), ...]` o vacío con `taskGroup(f)`.
  El grupo admite movimiento, `push` y `reserve` dentro del cuerpo
  async. `joinAll` contempla `alloc` y `panic` al construir la salida.
  La suspensión cooperativa carece de efecto `block`.
- `async fn main()` es la tarea raíz del **planificador cooperativo** de un solo
  hilo: una cola FIFO de tareas listas (round-robin), notificaciones explícitas
  y nada más. Mientras una tarea está suspendida, las demás progresan. No se
  crea ningún hilo del sistema operativo y no hay espera activa; si no queda
  ninguna tarea lista y alguna sigue suspendida, no puede llegar notificación y
  se informa como interbloqueo.
- **Concurrencia estructurada**: una tarea pertenece al scope async que la creó.
  Los handles pueden integrarse en un grupo local. Pasarlos como argumentos,
  devolverlos o guardarlos en otros agregados produce `L0015`. Destruir un
  handle cancela la tarea; terminar el scope (fin, `return` anticipado, `break`)
  destruye los handles vivos y cancela sus tareas; destruir el estado de una
  tarea cancela en cascada las tareas cuyos handles poseía.
- **Qué puede cruzar una suspensión**. Escalares, handles y propietarios
  admitidos. `Text`, structs, enums (incluidos `Option` y `Result`), arrays
  y `List<T>` son propietarios admitidos cuando sus componentes también
  son admisibles. Una llamada async toma sus parámetros propietarios por
  valor antes del primer sondeo. Las reglas normales de movimiento y
  reasignación se aplican a parámetros, locales y campos tras reanudar.
  Los préstamos vivos tras la suspensión, los tipos ligados a regiones,
  las vistas y el recorrido prestado de una colección durante `await`
  siguen rechazados.
- **Destrucción y cancelación**: destruir un future pendiente (fin de scope,
  retorno anticipado, reasignación) libera lo que su tarea aún posee, en cascada
  sobre el future que estuviera esperando. Un future terminado y no consumido
  libera su resultado. Un future consumido ya no posee nada. No hay terminación
  forzosa de tareas.
- **Efectos**: crear un future es `alloc` + `panic` (reserva del estado de la
  tarea); `await` hereda los efectos de la función que sondea; `spawn` reserva el
  estado y el registro de la tarea y hereda además los efectos del cuerpo, porque
  registrarla compromete su ejecución; suspenderse no es `block` ni `alloc`. Por
  tanto `@noalloc` no puede crear futures ni lanzar tareas.

No implementado en este incremento: métodos y traits async, funciones async
genéricas, `await` anidado en expresiones o en `match`, futures y handles
almacenados fuera de grupos locales o devueltos, tareas desatendidas,
propietarios recursivos o valores prestados vivos a través de una suspensión,
E/S asíncrona, temporizadores y multihilo.

## Diagnósticos

L0001 semántica (tipos, nombres, firmas), L0002 léxico, L0003 sintaxis,
L0004 evaluación const, L0005 movimientos/ownership, L0006 inferencia de retorno,
L0007 LIR inválida (error interno: verificador o invariantes de propiedad), L0008
característica no soportada por el backend elegido, L0010 contratos o violaciones del sistema de efectos, L0011 escape o uso indebido de una región, L0012 préstamos incompatibles y L0013 origen o modo de retorno prestado inválido, y L0014 almacenamiento de referencias en agregados. Un ciclo de constantes se
reporta como error semántico. CLI añade archivo, línea y columna (contadas en
escalares Unicode, desde 1). Fail-fast, sin recuperación multierror todavía.

### sleepMs

`sleepMs(Int) -> Future<()>` mide una duración en milisegundos con un
reloj monotónico. El primer sondeo inicia la espera. Cero completa
inmediatamente y las duraciones inválidas se diagnostican o provocan
un panic localizado si se conocen en ejecución. El registro puede
reservar memoria y fallar. La suspensión es cooperativa.
[Semántica detallada](TIMER_RUNTIME.md).


## Argumentos, archivos y estado de salida

`processArgCount()` y `processArg(Int)` consultan argv sin el
nombre del ejecutable. `readText(path, maxBytes)` toma prestado
el `Text` de ruta y devuelve un `Result<Text, Int>` con contenido
propietario o error. La lectura es síncrona, con límite inclusivo
y validación UTF-8. `printError(Text)` escribe una línea en stderr
sin mover su argumento. `fn main() -> Int` explícito y síncrono
devuelve el estado de salida después de sus drops. El rango válido
es 0–255. Los demás valores se convierten en 255.
[Contratos y efectos](LEXER_FILE_CLI.md).


## Ownership en Stage 1

`sema-l` valida lecturas y transferencias por valor mediante un CFG
de la función. Una ruta de movimiento identifica la variable o un
campo de struct. Un campo hermano puede seguir disponible tras un
movimiento parcial. Para usar un agregado se requiere disponibilidad
de todos sus campos. [Alcance y diferencias con Stage 0](STAGE1_CFG.md).

## Préstamos en Stage 1

Stage 1 sigue las reglas de préstamo de Stage 0 para su subconjunto:
préstamos en `let`, argumentos de referencia y retornos prestados;
lecturas que desreferencian; escritura a través de `&mut`; un préstamo
vive hasta el último uso alcanzable de su binding o de un représtamo;
el resultado de una función que devuelve referencia retiene todos sus
argumentos de referencia. Las referencias en agregados se rechazan.
[Reglas y diferencias](STAGE1_BORROW_CHECKER.md).

## Drops en Stage 1

Un valor propio se destruye al salir de su ámbito, en cada salida real
(fin de bloque o iteración, `return`, `break`, `continue`): el ámbito más
interno primero y en orden inverso de declaración; los parámetros al final;
los campos en orden inverso. Los temporales se destruyen al final de su
sentencia. Un valor movido no se destruye. Un valor quizá movido se
destruye bajo un flag dinámico. Reasignar evalúa el valor nuevo, destruye
el anterior y escribe. [Reglas y pruebas](STAGE1_DROP_ELABORATION.md).

## Lowering de Stage 1

La LIR de ELE conserva la semántica del subconjunto:

- se evalúa de izquierda a derecha y cada expresión una sola vez;
- `&&` y `||` se cortocircuitan;
- en `for` el rango se evalúa una vez;
- en una asignación el valor nuevo se evalúa antes de soltar el anterior;
- un `Text` se imprime o interpola sin moverlo.

[Detalle](STAGE1_LIR.md#lowering).

## Subconjunto comprobado en fase 8.2

Stage 1 acepta constantes `-Int` solo cuando el operador es `-` y el operando es un literal representable; el parser rechaza literales mayores que `Int::MAX`. La indexación exige `Int`. Los métodos built-in `push`, `pop`, `reserve` y `byteAt` comprueban receptor, aridad y tipos; los tres mutantes exigen receptor mutable. Estas reglas están probadas en `sema_l.rs`, pero listas y `Option` aún no tienen una ruta LIR completa para las fuentes propias. [Matriz](STAGE1_SELF_COVERAGE.md).
