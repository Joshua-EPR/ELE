# Proyecto L — Especificación de diseño v1.0

**Estado:** contrato de diseño congelado para implementación incremental; **no** afirma que exista un compilador funcional.
**Fecha:** 2026-11-07.
**Nombre:** «Proyecto L» provisional. **Extensión:** `.l`. **CLI:** `l`. **Manifiesto:** `l.toml`.
**Lengua:** sintaxis inspirada en TypeScript + Rust; español aquí solo para la especificación, palabras clave en inglés.

## 0. Visión, alcance y decisiones normativas

Proyecto L aspira a ser **un único lenguaje de propósito general**: backend, frontend (Wasm), desktop, Android/iOS, sistemas, embebidos e IA. **Universalidad del diseño ≠ disponibilidad inmediata de todas las plataformas.** La primera implementación ejecutable se enfocará en código de consola nativo. Ninguna afirmación de rendimiento superior a Rust se considera demostrada sin mediciones comparables.

Palabras normativas: **DEBE**, **NO DEBE**, **PUEDE**. Si dos secciones discrepan, prevalece la sección «Correcciones y compatibilidad» y los ejemplos de prueba normativos.

Objetivos: legibilidad, rendimiento sin GC obligatorio, seguridad de memoria, inferencia de tipos local, compilación AOT, runtime modular, ABI e interoperabilidad, IDE/tooling y diagnósticos precisos. Evitar herencia de clases, `any` implícito, excepciones ocultas para errores recuperables y conversiones peligrosas silenciosas.

Estado de implementación:
- **CORE-1 (primer hito ejecutable)**: lexer, parser, AST, módulos mínimos, verificación de tipos para subset, IR, generación de código nativo, CLI, pruebas.
- **CORE-2**: structs/enums, funciones genéricas, borrowing, Option/Result, patrones, efectos básicos, tests.
- **CORE-3**: regiones, async, concurrencia, FFI, biblioteca modular y tooling completo.
- **TARGETS (posteriores)**: Wasm y WASI, desktop, Android, iOS, freestanding, GPU. API e interoperabilidad son trabajo explícito, no resultado automático de tener un compilador.

## 1. Sintaxis léxica

- Archivo fuente UTF-8. Identificadores sensibles a mayúsculas/minúsculas, estilo recomendado `camelCase` para funciones y variables, `PascalCase` para tipos y variantes, `UPPER_SNAKE_CASE` para constantes. Primera implementación admite identificadores ASCII `[A-Za-z_][A-Za-z0-9_]*`; se reservará soporte Unicode normalizado para versión posterior, sin alterar las palabras clave.
- Comentarios `// ...` hasta final de línea y `/* ... */`, estos últimos anidables.
- Cadenas con comillas dobles, escapes `\\n`, `\\t`, `\\r`, `\\"`, `\\\\`, `\\u{HEX}`; interpolación `{expresion}` con llaves literales `{{` y `}}`.
- Carácter `'a'`; scalar Unicode, no byte; `Byte` 0..255.
- Literales numéricos: decimales, `_` separador, `0x`, `0b`, `0o`, decimales con parte fraccionaria/exponente; sufijos opcionales `i32`, `u64`, `f32` (p.ej. `10u32`). `1..10` se tokeniza `1`, `..`, `10`, no `1.`.
- Terminadores: nueva línea o `;`. Dentro de `(...)`, `[...]`, después de `,`, operador binario o `.` pendiente, una línea nueva no termina la expresión. En los bloques `{}` se respetan separadores de sentencias. Al final de bloque `}` la última expresión sin `;` puede ser su valor. No es la inserción automática de punto y coma de JavaScript.
- `fn`, `let`, `var`, `const`, `struct`, `impl`, `trait`, `enum`, `module`, `import`, `pub`, `return`, `if`, `else`, `match`, `for`, `in`, `while`, `loop`, `break`, `continue`, `async`, `await`, `spawn`, `mut`, `static`, `unsafe`, `region`, `extern`, `as`, `true`, `false`, `None` y `move` son palabras reservadas. `Some`, `Ok`, `Err` son constructores predefinidos, no palabras reservadas.
- Bloques con llaves obligatorias, no indentación significativa.

## 2. Declaraciones, inmutabilidad y scope

```l
let nombre = "Ana"        // binding y acceso inmutables
var edad = 25             // binding y acceso mutables
const LIMITE: Int = 5     // evaluación en compilación
edad += 1
```

- Toda declaración local debe tener inicializador, salvo variables que se inicialicen definitivamente antes de usar en una futura extensión; **v1 las exige siempre**.
- `let` prohíbe reasignación y mutación por medio de este binding. `var` habilita mutación en propiedad y préstamos mutables válidos. `const` se evalúa en compilación, sin IO, heap dinámico o valores dependientes del runtime.
- No hay variables globales mutables sin una API explícita de sincronización. Top-level: imports, módulos, tipos, funciones y constantes.
- Nombres repetidos en el mismo scope = error. Se permite shadowing en bloques anidados, no en el mismo.
- Los parámetros no son reasignables, salvo self en `mut fn` que da acceso mutable al objeto, o una variable local `var` que copie/mueva el parámetro.

## 3. Tipos y layout

Escalares: `Bool`, `Char` (scalar Unicode), `Byte` (alias `u8`), `i8/i16/i32/i64`, `u8/u16/u32/u64`, `f32/f64`, `usize/isize`, `()` (unit), `Never` (sin retorno normal). Alias: `Int = i64`, `Float = f64` **en todas las arquitecturas**; `usize` depende de la dirección del target.

Contenedores: `[T; N]` array de longitud fija, `[T]` slice no propietario (solo detrás de referencia, p.ej. `&[Int]`), `List<T>` lista dinámica, `(A,B)` tupla, `Option<T>` (azúcar `T?`), `Result<T,E>`, `Text` (texto UTF-8 poseído, inmutable como valor), `&T`, `&mut T`, `Box<T>`, `Shared<T>`, `Weak<T>`.

- `"texto"` se tipa como `Text` en contexto normal; la representación de literales estáticos es inmutable y puede apuntar a datos embebidos, sin asignación dinámica. La construcción de texto en runtime puede asignar memoria. `Text` **no** es `Copy`: moverlo invalida su origen. `Text` puede copiarse explícitamente con `.clone()`; el compilador puede optimizar copias sin cambiar semántica. No se promete que `clone()` no asigne.
- Las cadenas se almacenan en UTF-8; `Text` no admite indexación arbitraria por número entero como carácter. `text.byteLength` cuenta bytes; `text.chars()` itera caracteres Unicode; segmentación de grafemas requiere biblioteca adicional.
- `List[1,2,3]` crea `List<Int>`; `[1,2,3]` crea `[Int;3]`. Una lista se puede prestar como slice. `[T;N]` es `Copy` si T lo es, con política de tamaño optimizable; `List<T>` nunca es `Copy`.
- `f32/f64` siguen semántica IEEE 754; sin `fast-math` de forma predeterminada; los métodos matemáticos y conversiones se documentan individualmente.
- Conversiones numéricas sin pérdida desde literales por tipo contextual, con verificación de rango. NO hay coerción implícita general `Int`↔`Float`, `Bool`↔`Int`, ni entero de distinto signo/anchura si pudiera ser peligroso. `Float(x)` efectúa conversión explícita y puede redondear.
- Overflow de enteros normales = fallo `panic` definido para todo build. Acceso a arrays fuera de rango = `panic`. Métodos `wrappingAdd`, `checkedAdd` y `.get()` permiten alternativas. División entera por cero = `panic`; flotantes siguen IEEE 754. `panic` termina por abort, sin unwinding, en v1; no garantiza ejecutar destructores durante abort.
- Layout físico no garantizado para `struct` ordinarios. El futuro atributo `@repr(C)` fija compatibilidad C donde esté validada; solo formas seguras para FFI. `@repr(C)` **no** se implementa en CORE-1.

## 4. Funciones, valores y control

```l
fn sumar(a: Int, b: Int) -> Int = a + b
fn cuadrado(x: Int) -> Int { x * x }

fn main() {
    let etiqueta = if true { "sí" } else { "no" }
    var s = 0
    for n in 1..=5 { s += n }
    while s < 20 { s += 1 }
    match etiqueta {
        "sí" => print("correcto"),
        _ => print("otro"),
    }
}
```

- Las funciones declaran parámetros tipados. El tipo de retorno puede inferirse para funciones no públicas; las funciones públicas deben declarar el retorno (si no devuelven valor se permite `-> ()` omitido, equivalencia con `()`); se recomienda declararlo para toda API publicada.
- `fn f(...) = expresión` devuelve la expresión. Un bloque devuelve la última expresión sin `;`, o `()` si termina con una sentencia o bloque vacío. `return expr` retorna inmediatamente. `return` sin expresión devuelve `()`.
- `if` es expresión con `else` obligatorio si se usa donde se requiere valor; ramas del mismo tipo. `if` como sentencia puede omitir `else`. No se permite condición no-`Bool`.
- `match` es expresión o sentencia; los patrones deben ser exhaustivos; `_` comodín. En v1: literales, nombres, variantes y tuplas. `match` en `Float` no se permitirá en el primer núcleo hasta definir exhaustividad.
- `for in` itera usando un protocolo `IntoIterator`. Iterar un contenedor propietario por valor lo consume si no es `Copy`; usar `&lista` para consultar sin mover y `&mut lista` para modificar. Para arrays y slices de números copiables, los iteradores de lectura dan valores `Copy`. Así el bucle `for n in datos` donde `datos: &[Float]` permite `s += n`. El compilador no puede alterar silenciosamente la semántica del movimiento.
- `loop` es ciclo infinito hasta `break`; `continue` avanza a la siguiente iteración. `break valor` como valor de `loop` se difiere para implementación posterior; CORE-1 permite `break` y `continue` sin valor.
- Operadores definidos por el núcleo: `+ - * / %`, `== !=`, `< <= > >=`, `&& ||`, `!`, `??`, `.. ..=`, `&`, `&mut`, `?`, llamadas `()`, acceso `.` y `?.`, índice `[]`; sin sobrecarga arbitraria de operadores en v1.
- `&&` y `||` cortocircuitan; `??` evalúa el lado derecho solo cuando falta el izquierdo; `?.` produce opcionalidad. Evaluación de argumentos de izquierda a derecha.

## 5. Struct, impl, traits y enum

```l
struct Usuario {
    pub nombre: Text
    edad: Int
    activo: Bool = true
}

impl Usuario {
    fn presentar() -> Text { "Hola, soy {self.nombre}" }
    mut fn cumplirAnios() { self.edad += 1 }
    static fn invitado() -> Usuario { Usuario(nombre: "Invitado", edad: 0) }
}

enum Estado { Pendiente, Completado, Error(Text) }

trait Presentable {
    fn presentar() -> Text
}

impl Presentable for Usuario {
    fn presentar() -> Text { "{self.nombre}" }
}
```

- Los campos sin `pub` son accesibles solamente desde el módulo que define el `struct`; `pub` expone el campo a importadores. Métodos privados por defecto y públicos con `pub` si se llaman desde otros módulos.
- Construcción `Usuario(nombre: "...", edad: 10)`; se requieren campos sin default, defaults evaluados en el constructor, inicialmente expresiones constantes sin efectos (p.ej. `true`, `0`). Las modificaciones de defaults son incompatibilidades de API si afectan binarios publicados.
- `fn` en `impl` ofrece `self: &Self` implícito; `mut fn` ofrece `self: &mut Self`; `static fn` no recibe `self`. Los métodos con `self` pueden invocarse como `obj.f()` con autopréstamo; el autopréstamo mutable solo ocurre en receptores de métodos `mut fn` y exige binding modificable, no en parámetros explícitos.
- Traits para polimorfismo estático con `impl Trait for T`; sin herencia de clases; sin `dyn`/despacho dinámico en CORE-1. Una `impl` debe cubrir todos los miembros obligatorios. Coherencia: cada combinación `(Trait, Tipo)` tiene como máximo una implementación aplicable por paquete. Regla huérfana: el paquete debe definir el trait o el tipo.
- Genéricos `fn identidad<T>(v:T)->T`, `fn f<T: Presentable>(v:&T)`. No usar `any`; sin borrado dinámico de tipos implícito. Inicialmente monomorfización, con control posterior del tamaño de código.
- `enum` es tagged union. Los patrones deben verificar exhaustividad; no se pueden asumir valores de discriminante para FFI sin `@repr` explícito.

## 6. Semántica de memoria (Adaptive Ownership)

**Nombre de diseño**, no nueva demostración de una teoría de seguridad. Basado en recursos de propiedad única, movimiento, copy selectivo, préstamos con exclusión de mutación y comprobación estática de vida útil.

- Todo valor no `Copy` pertenece a un lugar. Asignación por valor o argumento por valor transfiere propiedad; el origen queda inutilizable hasta reinitialización válida. No hay duplicaciones profundas implícitas.
- Tipos `Copy`: escalares numéricos, `Bool`, `Char`, unit, referencias compartidas `&T`, tuplas/arrays cuando todos sus elementos son `Copy`; referencias `&mut T` no son `Copy`.
- `&T`: múltiples referencias de lectura. `&mut T`: préstamo exclusivo; no se permite ninguna referencia de acceso incompatible al mismo objeto durante dicho préstamo. Comprobación con liveness/último uso, preferentemente NLL.
- Único azúcar implícito: si parámetro conocido de función es `&T`, una llamada `f(valor)` puede autoprestar un lvalue; `f(&valor)` es equivalente. Para `&mut T` es obligatorio `f(&mut valor)`, salvo receptor de un método `mut fn`.
- Las referencias nunca sobreviven su objeto. En `fn nombre(u:&Usuario)->&Text`, se infiere vínculo del retorno con `u`. Si varios parámetros prestados permiten origen ambiguo, se requiere lifetime nombrado:

```l
fn elegir<'a>(a: &'a Text, b: &'a Text, primero: Bool) -> &'a Text {
    if primero { a } else { b }
}
```

- Lifetime `'a` es una anotación de tipos de referencia, no un valor runtime. Al llamar, `'a` queda limitado por la intersección de las vidas útiles compatibles. No se infieren vínculos inseguros.
- `drop` ocurre al salir normalmente de ámbito cuando un valor propietario no ha sido movido. Tipos con recurso implementarán un contrato `Drop` con restricciones de efectos; no se permite usar recursos después de drop. Para CORE-1 solo tipos triviales; RAII completo viene con CORE-2.
- El optimizador decide registros, stack y heap cuando no cambia observables. `&T` no garantiza dirección estable salvo operaciones de pinning del futuro; se difieren direcciones y pinning de bajo nivel hasta la capa de sistemas.
- `region nombre { ... }`: bloque léxico que entrega asignador por región `nombre`. `nombre.bytes(n)` solicita reserva en esa región; las referencias y recursos dependientes de ella NO pueden escapar. La liberación de región es colectiva al salir normalmente, tras liberar recursos con limpieza individual cuando sea necesaria. Su uso puede tener efecto `alloc`; no se permite como garantía de `@noalloc` salvo implementación concreta demostrada sin reserva dinámica. **Característica posterior a CORE-1**.
- `Shared<T>` representa conteo de referencias explícito, `Weak<T>` no propietario. Puede haber fugas por ciclos fuertes; no se promete ausencia de leaks. `Mutex<T>`, atomics y canales resuelven sincronización. No se expone mutación concurrente sin sincronización.
- Código `unsafe` no suspende reglas de tipos de toda la función: delimita operaciones como desreferencia de puntero bruto o FFI no verificable. Su uso establece obligaciones documentadas para la biblioteca.

## 7. Errores, opciones, panic

- `None`, `Some(x)` de `Option<T>`; `T?` es azúcar de `Option<T>`; `??` provee valor de respaldo; `?.` accede de forma opcional.
- `Ok(v)`, `Err(e)` de `Result<T,E>`; `expr?` dentro de función que devuelve `Result` devuelve temprano `Err` del mismo tipo, o extrae `Ok`; sobre `Option`, devuelve temprano `None` o extrae `Some`. **No** hay conversión implícita entre `Option` y `Result`.
- Un fallo recuperable debe expresarse en `Result`, no en excepciones; un `panic` representa fallo de contrato (overflow, índice fuera de rango, `panic()` explícito). En v1 el panic aborta el proceso/entorno; no hay captura ni unwind. Un programa freestanding necesita un handler de panic suministrado por plataforma.
- Para IO: API de bajo nivel `write(...) -> Result<(), IOError>`; utilitario `print(...) -> ()` se considera con efectos permitidos `io`, `block`, `alloc`, `panic` debido a su comportamiento de conveniencia. `print` NO se puede llamar desde `!{}`.

## 8. Sistema de efectos

Firma opcional `fn f(...) -> T !{alloc, io, block, panic}`. `!{}` exige ausencia de todos los efectos rastreados. Efectos son **permisos máximos**, no efectos ejecutados necesariamente. Omisión = inferencia del conjunto real máximo, no pureza afirmada.

- `alloc`: podría solicitar memoria dinámica (incluye listas dinámicas y potencial interpolación de texto).
- `io`: interacción con entorno (archivos, red, stdout, reloj, hardware abstraído).
- `block`: podría bloquear hilo.
- `panic`: podría abortar por fallo de contrato o llamada a panic. Las operaciones con enteros checked o índices no demostrados dentro del rango tienen este efecto.
- `async` es una transformación del retorno a un futuro; los efectos declarados se ejecutan al hacer poll/await; crear el futuro puede necesitar almacenamiento, y el análisis deberá distinguir efectos de creación frente a efectos al ejecutar. En CORE-1 se rechaza código `async` antes que simular su implementación.
- `unsafe` es una capacidad sintáctica y una obligación de prueba adicional, NO un permiso de efecto. La función externa deberá declarar sus efectos con un contrato, o recibirá un conjunto conservador.
- Anotación `@noalloc` equivale a declarar ausencia de `alloc`, no ausencia de IO/block/panic. El compilador verifica transitivamente llamadas que puedan ejecutarse. Una función genérica `@noalloc` debe ser válida para todas las instanciaciones permitidas por sus constraints; de lo contrario se rechaza la instanciación.
- Los contratos de efectos de traits restringen implementaciones. Si no se declaran efectos en una firma de trait, se consideran potencialmente todos los efectos del universo en llamadas genéricas opacas. Las optimizaciones especializadas pueden refinar el conjunto para un tipo concreto. Las APIs públicas pueden omitir anotación, pero los efectos inferidos forman parte de metadatos de interfaces y cambios pueden requerir actualización de usuarios con políticas estrictas.

```l
@noalloc
fn producto(a: Float, b: Float) -> Float { a * b }

fn promedio(datos: &[Float]) -> Float? !{} {
    if datos.length == 0 { return None }
    var total = 0.0
    for n in datos { total += n }
    return Some(total / Float(datos.length))
}
```

`@noalloc` no garantiza tiempo constante ni ausencia de bloqueos. `!{}` para cómputos flotantes usa reglas IEEE estándar, salvo operaciones que por contrato puedan disparar panic.

## 9. Concurrencia, async y ejecución

- `async fn f()->T` genera futuro suspendible; dentro puede `await` otras operaciones. El futuro no ejecuta todo el cuerpo al invocar la función; necesita `await` o scheduling.
- `spawn future` (azúcar por definir completamente) entrega `JoinHandle<T>`; requerirá valores transferidos `'static` o explicitamente scoped, y `Send` para cruce entre hilos.
- Las APIs `std.async` proveerán ejecutores elegibles por plataforma, sin runtime global obligatorio. `async fn main()` solo es legal con un ejecutor configurado en el manifiesto y implementado para ese target; en CORE-1 solo `fn main()` síncrono.
- `Shared<T>` solo es transferible entre hilos si cumple las constraints equivalentes a `Send/Sync`. `Mutex<T>` aporta acceso mutable sincronizado. Atomics requieren orden de memoria explícito o un default documentado, nunca data races permitidas.
- `parallel` será biblioteca con datos y cuerpos certificados como transferibles. Paralelización automática solo cuando se pueda demostrar independencia y convenga según medición; nunca sin control sobre semántica numérica.
- La compilación freestanding no incluye networking, filesystem ni threads automáticamente. `core` sin OS; `alloc` con asignador suministrado; `std` solo cuando la plataforma proporcione adaptadores.

## 10. Módulos, paquetes, builds y visibilidad

`module paquete.ruta` opcional si la ruta del archivo define un módulo unívoco; explicitación recomendada para librerías. `import std.io.print` y `import app.usuarios.Usuario`; resolución absoluta de nombres, sin wildcards en v1. `pub` expone tipo, función, método o campo; sin `pub` privado al módulo.

`l.toml`:

```toml
[package]
name = "hola"
version = "0.1.0"
edition = "1"

[target]
kind = "bin"
platform = "native"
profile = "debug"
panic = "abort"

[dependencies]
```

- Edición `1` congela palabras clave y reglas sintácticas de esta especificación; revisiones de bugs no rompen deliberadamente programas válidos.
- CLI: `l new`, `l check`, `l build`, `l run`, `l test`, `l fmt`, `l bench`, `l --version`, `l --help`. En CORE-1, implementar primero `check`, `build`, `run`, `--help`, `--version`; comandos no listos deben informar claramente «no implementado» en vez de simular éxito.
- Artefactos por target y perfil en `target/<triple>/<profile>/`. Build determinista cuando fuentes/configuración/toolchain coinciden, excluidas salidas que incluyan timestamps no normalizados.
- `l.lock` de dependencias exactas futuro; versionado semántico de paquetes; registrador público, firma de paquetes y repositorios remotos quedan fuera del compilador inicial. El manifiesto válido sin dependencias externas no exige red.

## 11. Interoperabilidad, ABI y plataformas

- ABI interno de Proyecto L no se considerará estable entre versiones mayores sin especificación adicional. No se promete compatibilidad binaria por defecto entre diferentes compiladores.
- Para C, funciones `extern "C" fn ...` y tipos con layout C verificado, además de límites explícitos `unsafe`. Los callbacks, manejo de errores y propiedad a través de FFI deben tener contrato. No tratar `Text`, `List<T>` o `Option<T>` como layout C automáticamente.
- En Wasm, separar `core` y bindings externos vía Wasm/WASI y Component Model cuando sea apropiado; el acceso al DOM requiere bindings específicos. El Component Model ofrece un enfoque de interfaces entre componentes, pero su integración es un futuro backend/adaptador, no una consecuencia de LLVM/Cranelift.
- Android/iOS requieren integración con sus SDKs y toolchains; desktop requiere biblioteca de UI externa, render nativo o wrappers; GPU requiere backend y API de cómputo con restricciones de seguridad específicas.
- Sistemas operativos: usar target freestanding con `core`, entry point, linker script, allocator opcional, panic handler, `volatile`/atomic/memory-mapped IO mediante APIs de sistema seguras o `unsafe` auditado. No se ejecuta `fn main()` de consola en bare metal por defecto.
- IA: librerías de tensor y SIMD/BLAS/GPU, interop y backends especializados. Ninguna sintaxis fundamental específica de IA se impondrá al núcleo 1.0.

## 12. Optimización, observabilidad y rendimiento

Pipeline: fuente → lexer → CST/AST con spans → resolución de nombres → inferencia de tipos → análisis de ownership → análisis de efectos → HIR tipada → MIR/LIR SSA → optimizaciones → backend objetivo → linker → artefacto.

LIR debe representar: valores tipados, bloques básicos, flujo, llamadas, ownership/drop, efectos relevantes, metadata de origen; el primer backend puede omitir optimizaciones complejas siempre que preserve semántica.

Prioridades: constant folding conservador, DCE, inlining medido, eliminación de comprobaciones demostrablemente redundantes, monomorfización, simplificación de ciclos, análisis de escape, regiones, vectorización respetando IEEE. No habilitar `fast-math` sin opt-in explícito. Evitar que optimizaciones cambien el comportamiento definido de overflow/panic.

Benchmark reproducible:
1. Comparar versión optimizada de Proyecto L con Rust optimizado de forma equivalente y **mismo algoritmo/datos**.
2. Mismo hardware, compiler versions, warm-up cuando aplique, repeticiones, intervalos de confianza/mediana, RAM pico, tiempo, p95/p99 y tamaño binario.
3. Benchmarks: numérico, parseo, IO, allocaciones, algoritmos, latencia y concurrencia. Separar compilación de ejecución.
4. Mostrar regresiones y casos donde Rust gane. Una mejora solo se anuncia con evidencia reproducible.

## 13. Errores del compilador y herramientas

- Mensajes con ruta, línea, columna y fragmento, código diagnóstico estable (`L0001`...), explicación breve y sugerencia útil; error del usuario jamás produce stacktrace ni crash del compilador.
- `l check` valida sintaxis y tipos sin ejecutar. `l fmt` formato consistente con reglas de bloques y saltos. `l test` ejecuta tests aislados en el futuro. Soporte LSP basado en frontend con recuperación de errores incremental después de CORE-1.
- Requisitos de seguridad de dependencias: pinning, auditoría, tests para entradas malformadas, límites de memoria, fuzzer del lexer/parser cuando exista. El compilador debe rechazar input inválido sin panics del host.
- Tests golden de tokens, AST, errores, tipos y salida; pruebas positivas y negativas; snapshots sin rutas absolutas o tiempos variables; CI Linux, luego Windows/macOS.

## 14. Gramática núcleo (EBNF orientativa, normativa donde no contradice la semántica)

Lexer debe distinguir nueva línea significativa, comentario, literales, palabras reservadas y operadores. Los espacios son insignificantes salvo terminación de instrucción. Gramática completa de todas las expresiones se implementará con Pratt parser y tabla de precedencia siguiente.

```ebnf
program         = [module_decl], { import_decl | top_decl } ;
module_decl     = "module", path, term ;
import_decl     = "import", path, term ;
path            = ident, { ".", ident } ;
top_decl        = ["pub"], (fn_decl | struct_decl | enum_decl | trait_decl | impl_decl | const_decl) ;
fn_decl         = { attribute }, ["async"], ["mut" | "static"], "fn", ident,
                  [generic_params], "(", [params], ")", ["->", type], [effects],
                  ("=", expr, term | block) ;
params          = param, { ",", param }, [","] ;
param           = ident, ":", type ;
generic_params  = "<", ident, { ",", ident }, ">" ;
effects         = "!", "{", [ident, { ",", ident }], "}" ;
attribute       = "@", ident ;
struct_decl     = "struct", ident, [generic_params], "{", { field }, "}" ;
field           = ["pub"], ident, ":", type, ["=", expr], [term] ;
enum_decl       = "enum", ident, [generic_params], "{", { variant }, "}" ;
variant         = ident, ["(", [type, { ",", type }], ")"], ["," | term] ;
trait_decl      = "trait", ident, [generic_params], "{", { fn_signature }, "}" ;
impl_decl       = "impl", type, ["for", type], "{", { ["pub"], fn_decl }, "}" ;
block           = "{", { statement, term }, [expr], "}" ;
statement       = local_decl | return_stmt | break_stmt | continue_stmt
                | if_stmt | for_stmt | while_stmt | loop_stmt | match_stmt
                | assignment | expr ;
local_decl      = ("let" | "var"), ident, [":", type], "=", expr ;
return_stmt     = "return", [expr] ;
if_stmt         = "if", expr, block, ["else", (block | if_stmt)] ;
for_stmt        = "for", ident, "in", expr, block ;
while_stmt      = "while", expr, block ;
loop_stmt       = "loop", block ;
match_stmt      = "match", expr, "{", { pattern, "=>", (expr | block), ["," | term] }, "}" ;
assignment      = place, ("=" | "+=" | "-=" | "*=" | "/=" | "%="), expr ;
type            = ["&", ["mut"]], type_atom, ["?"] ;
type_atom       = ident, ["<", type, {",", type}, ">"]
                | "[", type, ";", integer_literal, "]"
                | "[", type, "]"
                | "(", [type, {",", type}], ")" ;
pattern         = "_" | ident | literal | path, ["(", [pattern, {",", pattern}], ")"]
                | "(", pattern, {",", pattern}, ")" ;
term            = NEWLINE | ";" ;
```

Esta EBNF no expresa ambigüedad contextual entre `statement`/última expresión, ni incorpora lifetime `'a` y todas las extensiones de tipos. El parser aplica reglas contextuales y una implementación Pratt; se debe completar gramática ejecutable en `docs/GRAMMAR.md` antes de declarar la implementación del núcleo como «conforme 1.0». No esconder este límite.

**Precedencia mayor → menor:** llamada/acceso/indexación/propagación `?`; unarios `!`, `-`, `&`, `&mut`, `await`; multiplicativos `* / %`; aditivos `+ -`; rangos `.. ..=`; comparaciones; igualdades; `&&`; `||`; `??`. Asignación es sentencia, no expresión. Asociatividad izquierda excepto `??` (derecha). Las comparaciones encadenadas (`a < b < c`) se rechazan.

## 15. Ejemplos de conformidad

### Hello world

```l
module hola.main
import std.io.print
fn main() { print("Hola desde L") }
```

### Operaciones con tipos

```l
fn doble(x: Int) -> Int = x * 2
fn main() {
    let n: Int = 21
    let r = doble(n)
    print(r) // 42
}
```

### Estructura y resultado

```l
struct Cuenta {
    pub titular: Text
    saldo: Float = 0.0
}
impl Cuenta {
    mut fn depositar(monto: Float) -> Result<(), Text> {
        if monto <= 0.0 { return Err("Monto inválido") }
        self.saldo += monto
        return Ok(())
    }
    fn consultar() -> Float = self.saldo
}
fn main() {
    var cuenta = Cuenta(titular: "Ana")
    match cuenta.depositar(50.0) {
        Ok(_) => print(cuenta.consultar()),
        Err(e) => print(e),
    }
}
```

### Error: borrow mutable inválido

```l
fn cambiar(u: &mut Usuario) { u.edad += 1 }
fn main() {
    let u = Usuario(nombre: "Ana", edad: 20)
    cambiar(&mut u) // error: binding inmutable
}
```

### Error: retorno de referencia local

```l
fn incorrecta() -> &Text {
    let x = "temporal"
    return &x // error: referencia escapa origen local
}
```

### Error: overflow potencial bajo !{}

```l
fn suma(a: Int, b: Int) -> Int !{} = a + b
// error: suma checked puede fallar por overflow -> efecto panic
```

### Error: la asignación dinámica viola @noalloc

```l
@noalloc
fn mal() {
    let x = List[1,2,3]
}
// error: potencial efecto alloc
```

## 16. Correcciones y compatibilidad respecto a v0.1–v0.4

1. `let` no significa «inmutable profundo» universal; significa que ese acceso no admite mutaciones: un tipo con sincronización interna puede cambiar estado a través de una API segura y explícita.
2. `"Ana"` se trata como `Text` de almacenamiento literal estático; mover un `Text` invalida el binding anterior si no es `Copy`. No se hacen copias profundas silenciosas. La construcción de texto en runtime puede asignar.
3. `List[...]` expresa contenedor dinámico; `[...]` array fijo. Arrays y slices son distintos.
4. `print` tiene efectos: **no** es compatible con `!{}` o garantías de pureza estricta.
5. La aritmética entera checked puede tener `panic`, así que `fn suma(a:Int,b:Int)->Int !{} = a+b` no pasa el checker sin prueba de ausencia de overflow.
6. `mut fn` requiere acceso mutable solo para mutar `self`; una función libre usa `fn f(x:&mut T)`.
7. Método `obj.mutMetodo()` puede tomar el préstamo mutable implícito; una función libre `f(&mut obj)` requiere anotación visible.
8. Los lifetimes omitidos solo se infieren cuando la relación es demostrable. De otro modo hay lifetime nombrado.
9. Regiones no garantizan `noalloc`; pueden ser más eficientes, pero sus costos y semántica son explícitos.
10. `@noalloc` comprueba asignaciones transitivas; `!{}` excluye los efectos rastreados; ninguno garantiza tiempo constante o tiempo real por sí solo.
11. `async`, GPU y frontend no están implementados por definir su sintaxis. Cada target tendrá adaptadores y pruebas.
12. La gramática semiforme v0.2/v0.4 queda sustituida por reglas y restricciones de este documento; un `grammar.md` formal y ejecutable se construirá junto al parser.

## 17. Plan de implementación y criterios de salida

**Sprint 0 — Repo y pruebas**: workspace Rust, CLI con help/version, carpeta docs/examples/tests, especificación copiada, cargo fmt/clippy/test sin errores. Ninguna funcionalidad se anunciará sin prueba.

**Sprint 1 — Lexer/Parser**: tokens con spans, recovery en errores, AST y snapshots; literales, comentarios, operadores, declaraciones, funciones, llamadas, if, while, return, tipos, terminación por newline/semicolon. `l check` valida sintaxis.

**Sprint 2 — Semántica mínima**: scopes, símbolos, `Int/Float/Bool/()` tipados, expresiones, coerciones de literales, firmas de funciones, return, flujo, error diagnostics; negativos (uso sin definir, tipos incompatibles, mutación de let).

**Sprint 3 — IR + backend nativo**: generar un ejecutable real para `fn main`, enteros, bools, variables, operaciones, funciones, `if`, `while` y salida simple. Cranelift es un primer backend recomendado; si el host carece de linker/runtime, informar de forma honesta sin fingir binarios. `l run` ejecuta el archivo compilado.

**Sprint 4 — Composición**: `struct`, `enum`, `match`, arrays, slices y sistema de errores básico; ownership/borrowing sobre un subconjunto validable y pruebas negativas.

**Sprint 5 — Más garantías**: genéricos y traits, efectos, `Option/Result`, `?`, `@noalloc`, regiones, async, FFI, herramientas; incremental y test-driven.

**Sprint 6 — Calidad**: formato, empaquetado, docs de gramática completas, fuzzing básico, CI, benchmark vs Rust, WebAssembly experimental.

### Criterio mínimo de primer resultado de Codex

- Código fuente real en repo, workspace compilable y pruebas ejecutadas.
- `l --help`, `l --version`, `l check <archivo>` y (si hay linker/backend operativo) `l build <archivo>`, `l run <archivo>`.
- `l check` reconoce `fn main`, declaraciones `let/var`, valores numéricos, `+ - * /`, bloques/return, e informa línea/columna.
- Compilación y ejecución real de un programa que calcule `21 * 2` y retorne/imprima `42` (si salida no está soportada, usar código de salida verificable y documentarlo, sin llamarlo soporte completo de `print`).
- Casos negativos reales: `let x=1; x=2` falla, variable inexistente falla, incompatibilidad `Int/Bool` falla.
- `cargo test` y `cargo fmt --check` pasan. El README distingue lo que funciona de lo que está diseñado pero no implementado.

## 18. Limitaciones explícitas del diseño v1.0

- La especificación describe la dirección del lenguaje; aún requiere una gramática ejecutable sin ambigüedades, una semántica de préstamos probada, bibliotecas con contratos de efectos y un conjunto de tests de conformidad antes de llamarlo estándar implementado.
- El soporte de Unicode en identificadores, macros, metaprogramación, programación distribuida, GPU, GC opcional, despacho dinámico, características de UX de frontend, bindings de escritorio/móviles y compilación freestanding completa **no** se exigirán para CORE-1.
- La seguridad de memoria del diseño no está demostrada por escribir reglas; debe validarse por implementación, pruebas y auditoría.
- No existe prueba de superioridad general de rendimiento sobre Rust. Los informes de benchmarks deben incluir resultados adversos.

## 19. Próximo documento derivado (no bloquea primer compilador)

`docs/GRAMMAR.md`: precedencia, terminación de líneas, patrones, lifetimes y sintaxis completa para cada tipo de declaración. `docs/SEMANTICS.md`: reglas de inferencia, préstamos, efectos, overflow, drop, error handling. `docs/BACKEND.md`: lowering LIR/Cranelift, ABI y targets. Estos documentos deberán permanecer sincronizados con el código y los tests.
