# ELE — compilador experimental

## Nombre

El lenguaje se llama oficialmente **ELE**; antes se llamaba «Proyecto L».
Los archivos fuente conservan la extensión `.l`. Por compatibilidad no
cambian los nombres internos: el paquete `project-l`, la biblioteca
`project_l`, el ejecutable `l`, los drivers `lexer-l`, `parser-l` y
`sema-l` y el directorio `compiler-l`. Los documentos y commits
anteriores conservan el nombre histórico.

Compilador en Rust estable, sin GC. Única dependencia externa: Cranelift (backend
nativo). Implementa un subconjunto de la especificación v1.0, no el lenguaje completo.

**Dos backends.** `--backend rustc` (predeterminado, provisional): LIR → fuente Rust →
rustc; cubre todo lo implementado. `--backend cranelift`: LIR de bloques → Cranelift →
objeto COFF → `link.exe`, sin rustc y sin runtime de Rust ni de C (el runtime lo genera
el propio compilador y solo llama a kernel32); cubre por ahora Int, Bool, Text (literal
y dinámico, con liberación determinista por drops), interpolación, control de flujo,
match sobre Int/Bool/Text, funciones y print, y rechaza el resto con un error claro. Ambos
producen ejecutables nativos autónomos; solo Windows x86-64/MSVC está probado.

## Nueva sintaxis canónica de ELE (migración v2)

La sintaxis pública de ELE ya no se diseña como un clon de Rust. Se ha comenzado a
implementar una gramática propia con `flow`, `shape`, `extend`, `choice`,
`choose`, `hold`, `change`, `give`, `=>`, y llamadas `objeto@metodo()`
(los campos siguen siendo `objeto.campo`). La forma `choose` usa
`Patron: { ... }` en vez de `match Patron => ...`. Stage 0 también reconoce
los préstamos `view` y `edit`.

**Importante:** este cambio está en migración; los antiguos keywords siguen
siendo entendidos temporalmente para compilar Stage 1, el prelude y ejemplos
existentes. El subconjunto de Stage 1 no admite aún todas las construcciones
de Stage 0. Las funciones no se hacen más rápidas por cambiar su ortografía,
ni esto elimina la dependencia de Rust/Cranelift para bootstrap.

Ver la [especificación y estado exacto de ELE v2](docs/ELE_SYNTAX_V2.md)
y el [ejemplo de código nuevo](examples/ele_original_syntax.l).

## Ejecutar en este equipo

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo build
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo run -- run examples/arithmetic.l
cargo run -- run examples/constants.l
cargo run -- run examples/text.l
cargo run -- run examples/fibonacci.l
cargo run -- run examples/interpolation.l
cargo run -- run examples/contador.l
cargo run -- run examples/structs.l
cargo run -- run examples/enums.l
cargo run -- run ejemplos/cuenta.l
cargo run -- run examples/arithmetic.l --backend cranelift
cargo run -- check examples/loops.l --emit-cfg
cargo run -- run ejemplos/hola.l
cargo run -- check examples/text.l --emit-ast --emit-ir
cargo run -- build examples/text.l
```

Rust instalado y verificado: 1.99.1. rust-toolchain.toml fija esa versión; el override
anterior reutiliza el canal local que contiene exactamente esa versión.
Instalación nueva: `rustup toolchain install 1.99.1 --profile minimal --component rustfmt --component clippy`.
Windows necesita Visual Studio Build Tools, herramientas C++ MSVC y Windows SDK.
check funciona sin rustc ni enlazador. build/run requieren ambos.

## Implementado y probado

- Int=i64, Bool, Float=f64, unit y Text de literales UTF-8; anotaciones e inferencia local.
- let inmutable, var mutable, const locales/globales con evaluación en compilación.
- Constantes con dependencias adelantadas, diagnóstico de ciclos, operaciones
  comprobadas y cortocircuito; sin llamadas a funciones ni valores runtime en const.
- Funciones tipadas, recursión, llamadas anidadas, retorno y expresión final;
  tipo de retorno inferido si se omite `-> T` (error claro en recursión sin anotar).
- Scopes/shadowing, if/else-if/else, while/loop/break/continue, `for x in a..b`/`a..=b`
  sobre Int, operadores y precedencia. `loop` sin break cuenta como divergente.
- `enum` (simples, con datos y genéricos monomorfizados), `match` exhaustivo como
  sentencia o expresión con patrones anidados, detección de patrones inalcanzables,
  `Option<T>`/`T?`, `Result<T, E>`, `??`, `?` y `pub`. `ejemplos/cuenta.l` funciona.
- `struct` con campos tipados y defaults constantes, construcción `Tipo(campo: v)`,
  acceso/asignación de campos, `impl` con `fn` (self compartido), `mut fn` (self
  exclusivo, receptor var) y `static fn` (`Tipo.m()`). Structs no Copy, con movimientos
  comprobados y sin movimientos parciales. `examples/contador.l` imprime `Valor: 2`.
- Text no Copy: movimientos comprobados antes del backend; print consulta sin consumir.
- Escapes Unicode y llaves literales; print de Text/Int/Float/Bool.
- Interpolación Text como expresión: variables, operaciones, llamadas y cadenas
  anidadas; conversión de Int/Float/Bool/Text, en orden y una sola vez. Puede
  guardarse, retornarse y pasarse a funciones; no depende de print.
- Overflow/división/resto enteros inválidos abortan en runtime; en const son errores
  de compilación. No se confía en el diagnóstico de overflow de rustc para semántica L.
- CLI check/build/run, help/version, AST/LIR; diagnósticos con ruta, línea, columna,
  código y categoría. No se ejecutan binarios tras un error de comprobación o build.

Text usa un contenedor no Copy con datos estáticos UTF-8 o String propietario.
Literales e interpolaciones constantes plegadas no asignan en runtime. Interpolación
dinámica construye un buffer propio; formatea cada expresión directamente, sin
cadenas temporales por conversión. print usa std y puede asignar/bloquear/fallar.
No se afirma noalloc. No hay operador de concatenación, clone, referencias ni
borrow checker completo. Movimientos conservadores en ramas y bucles.

Pendientes: enteros con tamaño y conversiones, if como inicializador, evaluación
const de funciones, frontend con recuperación multierror, arrays, guardas/tuplas,
funciones genéricas/traits, préstamos, efectos, manifiestos, backend directo
y otros targets. `ejemplos/cuenta.l` compila y funciona (imprime 50).
`ejemplos/hola.l` y `ejemplos/aritmetica.l` ahora funcionan.

## Arquitectura y resultados

```text
crates/l/src/
  lib.rs         API y diagnósticos
  lexer.rs       tokens UTF-8 y spans
  parser.rs      AST, Pratt, declaraciones
  sema.rs        nombres, tipos y lowering
  consteval.rs   evaluación de LIR constante
  lir.rs         tipos/IR independientes
  ownership.rs   movimientos (Text, structs, enums) y modo de bindings de match
  exhaustive.rs  exhaustividad y alcanzabilidad de patrones
  prelude.l      Option y Result escritos en L
  cfg.rs         LIR de bloques básicos, lowering y verificador
  backend.rs     backend rustc (predeterminado): LIR → Rust, enteros checked
  drops.rs       elaboración de drops (flags) y verificación de propiedad
  native.rs      backend cranelift: LIR de bloques → objeto nativo
  native/runtime.rs  runtime propio en Cranelift IR: E/S, heap, Text
  linker.rs      localiza link.exe/kernel32.lib y enlaza sin CRT
  main.rs        CLI, construcción y ejecución
crates/l/tests/  conformance, phase2, interpolation, phase_a, structs y enums
examples/       positivos y negativos ejecutables
ejemplos/       fixtures originales conservados
docs/           contrato y documentos derivados
```

Pruebas: suite anterior conservada, nuevas comprobaciones de parser/tipos/const,
movimientos, UTF-8, stdout/stderr/códigos y ejecutable autónomo. El antiguo negativo
"Text no implementado" se sustituyó por "Text incompatible con Int", pues Text
ya forma parte del subset. No hay benchmarks ni afirmaciones de rendimiento.

Interpolación verificada: **Fibonacci: 55**, stdout exacto, stderr vacío, código 0.
Suite completa: **66 pruebas, 0 fallos** (fmt y clippy limpios), incluidas pruebas
diferenciales rustc vs cranelift y pruebas de seguridad de memoria instrumentadas
(`--trace-alloc`: cada reserva se libera exactamente una vez, heap íntegro). Modelo
de memoria: [semántica](docs/SEMANTICS.md). Ver [backend](docs/BACKEND.md). Véase [interpolación](docs/INTERPOLATION.md).

[Auditoría](docs/AUDIT_PHASE2.md), [resultados y estado](docs/IMPLEMENTATION_STATUS.md),
[decisiones](docs/DECISIONS.md), [gramática](docs/GRAMMAR.md),
[semántica](docs/SEMANTICS.md), [backend](docs/BACKEND.md).


## Backend alternativo sin Rust (experimental)

ELE incluye un backend **ELE-LIR 1 → C11 → ejecutable nativo** que no invoca
Rust ni Cranelift para su compilación. Se puede probar con:

```bash
python tools/ele_c_backend.py examples/native_without_rust.lir -o ele_demo
./ele_demo
python -m unittest discover -s tests/native_backend -v
```

Para compilar fuentes `.l` por esta ruta se necesita **un ejecutable Stage 1
precompilado**. El compilador ELE aún **no es self-hosted**: Stage 0 (Rust)
sigue siendo necesario para construir Stage 1 inicialmente. La nueva ruta
es un avance parcial, no la independencia completa. Detalles, soporte real,
limitaciones y siguiente plan: [backend sin Rust](docs/RUST_FREE_BACKEND.md).

## Backend de código máquina escrito en ELE (avance experimental)

Los archivos `compiler-l/src/codegen/x86_64.l` y
`compiler-l/src/codegen/elf64.l` constituyen la primera implementación de
**codificación de instrucciones x86-64 y encabezados ELF64 hecha en ELE**.
`compiler-l/src/native_elf_demo.l` construye en memoria un ejecutable Linux
que invoca `exit(42)` sin libc. La generación todavía depende del bootstrap
histórico para ejecutar el emisor y **emite hexadecimal a stdout, no un
archivo ejecutable**. No existe aún un parser ELE-LIR para este backend ni
un backend PE/COFF para Windows. No hay Stage 2 ni Stage 3.

También se añadió una **ruta de compilación ELE-LIR → x86-64 → ELF64
escrita en ELE** (`codegen/lir_tokens.l`, `codegen/lir_subset.l`,
`native_lir_demo.l`). Admite solo el subconjunto de un `main(): Int`
lineal con `use`, `add`, `sub`, `mul` y `return`; los casos válidos y no
soportados están en `examples/native_int_subset*.lir`. La ruta de
escritura binaria, la validación ELF emitida por el `.l` compilado y el
soporte de Stage 2 siguen pendientes.

Las seis pruebas Rust de integración `crates/l/tests/native_encoder_l.rs` están
preparadas, pero pendientes de ejecución MSVC:

```powershell
.\bench\verify-native-encoder.ps1
```

El historial y las limitaciones están documentados en
[`docs/ELE_NATIVE_BACKEND_PHASE_8_7.md`](docs/ELE_NATIVE_BACKEND_PHASE_8_7.md).

## 8.7.1 — escritura binaria desde ELE (bootstrap, pendiente de MSVC)

`native_lir_demo.l` admite ahora `programa.lir salida.elf`: mediante
`writeBytes(Text, List<Int>)` guarda el ELF64 directamente, sin convertir a
hexadecimal. El soporte inicial de I/O está conectado al bootstrap Win64
(Rust `no_std`, API del sistema operativo), por lo que **no demuestra aún
independencia de Rust**. El emisor de código máquina continúa escrito en ELE.

```powershell
.\bench\verify-native-encoder.ps1
.\bench\build-native-elf.ps1
```

Ver [informe y límites de la Fase 8.7.1](docs/ELE_NATIVE_BACKEND_PHASE_8_7_1.md).

### Backend nativo experimental escrito en ELE: fase 8.7.2

`compiler-l/src/native_cfg_demo.l` implementa una ruta restringida
`ELE-LIR 1 (Int/Bool, funciones/CFG) → x86-64 → ELF64` en archivos `.l`.
Para el bootstrap Windows/MSVC: `bench/verify-native-encoder.ps1`, seguido de
`bench/verify-native-cfg.ps1` y `bench/build-native-cfg.ps1`.
**Pendiente de compilar/probar el nuevo código ELE con Stage 0.** No existe
Stage 2 ni compilación autosuficiente. Consultar
[`docs/ELE_NATIVE_BACKEND_PHASE_8_7_2.md`](docs/ELE_NATIVE_BACKEND_PHASE_8_7_2.md).

### Fase 8.7.3 — Fundamentos de memoria nativa (experimental)

`compiler-l/src/codegen/native_layout.l` y `x86_64.l` incluyen un planificador
de layouts y cargas/stores de 8/64 bits. Hay un ejemplo ELE de stack agregado
que debe generar un ELF64 Linux con salida 42. **Pendiente de validar con
Stage 0/MSVC**; no equivale a soporte completo de structs y recursos en LIR.
Comandos: `bench/verify-native-memory.ps1` y `bench/build-native-stack.ps1`.
Ver `docs/ELE_NATIVE_BACKEND_PHASE_8_7_3.md`.

### Continuación experimental: structs move-only del backend ELE

La ruta `native_cfg_demo.l` ahora incluye un subconjunto de estructuras con
campos Int/Bool del protocolo ELE-LIR 1. Sigue siendo experimental y su
compilación con MSVC requiere verificación. Comandos y limitaciones:
[continuación 8.7.3 hacia 8.8](docs/ELE_8_7_3_8_8_CONTINUACION.md).


### Incremento 8.7.3 — structs anidadas move-only (sin compilar aún con Stage0)

`native_cfg_demo.l` ahora puede representar una struct move-only que contiene otra
struct move-only **ya declarada** en ELE-LIR 1; el emisor recorre los campos y
utiliza las cargas y stores correctos, sin copiar padding. El verificador invalida las variables movidas y
rechaza las extracciones parciales de structs; solo se leen campos Copy. Hay fixtures y
pruebas de integración para salida 42/0, rechazos nominales e integración
Stage1. **Las pruebas `.l` necesitan MSVC y siguen pendientes.**

Ejecutar `bench/verify-native-nested.ps1` en Windows con Rust/MSVC.
Consultar [informe de structs anidadas](docs/ELE_8_7_3_NESTED_MOVE.md).

### Incremento 8.7.4.2 (experimental)

Interop de `i payload` para los dos lectores LIR y emisión nominal de enums
unitarios desde Stage 1. **No verificado todavía con Stage 0/MSVC**, ni
representa soporte completo de `Option`, `Result` o `match`. Ejecuta
`bench/verify-enum-lir-interop.ps1` y consulta
`docs/ELE_NATIVE_BACKEND_PHASE_8_7_4_2.md`.
