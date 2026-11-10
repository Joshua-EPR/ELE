# Backends, LIR y runtime

## 1. Pipeline

```text
fuente .l + prelude.l
  → lexer → parser (AST) → sema (tipos, structs/enums, match, inferencia)
  → LIR estructurada (lir.rs)            ← ownership.rs comprueba movimientos y
                                            decide el modo de los bindings de match
  → LIR de bloques (cfg.rs): lowering con Drop en cada salida de scope
  → elaboración de drops (drops.rs): estados de inicialización + drop flags
  → verificador (cfg.rs + drops::verify)   ← SIEMPRE, con cualquier backend
       │                                    (lib::lower_to_cfg; error interno L0007)
       ├─ backend rustc (backend.rs):  LIR estructurada → Rust → rustc → exe
       └─ backend cranelift (native.rs): LIR de bloques → Cranelift IR → .obj
                                          → link.exe (linker.rs) → exe
```

Hay dos niveles de LIR a propósito:

- **LIR estructurada** (`lir.rs`): árbol tipado con if/while/for/loop/match. Es la
  salida de `sema` y la entrada de `ownership.rs`. El backend rustc la necesita porque
  Rust no tiene `goto`: traducir un grafo arbitrario a Rust exigiría una máquina de
  estados. Se mantiene mientras exista ese backend (pruebas diferenciales).
- **LIR de bloques** (`cfg.rs`): funciones con bloques básicos y terminadores
  explícitos. Es la representación de entrada de los backends nativos. Se deriva de la
  estructurada después de toda la comprobación semántica, así que nunca re-implementa
  reglas del lenguaje; solo explicita el control de flujo y las operaciones de memoria.

## 2. LIR de bloques (`cfg.rs`)

- `Module { structs, enums, funcs, main }`. Structs y enums son los mismos tipos
  concretos (monomorfizados) de la LIR estructurada.
- `Func { name, params, vars, result, blocks }`. `blocks[0]` es la entrada. Los
  parámetros son variables; el receptor de un método va primero.
- **Variables tipadas, no SSA.** `VarTy::Value(T)` o `VarTy::Ref(T)` (préstamo: `self`
  y bindings de match que prestan). Una variable puede asignarse en varios bloques; el
  backend construye SSA (Cranelift lo hace con `def_var`/`use_var`).
- `Operand = Var | Const(Int|Float(bits)|Bool|Unit|Text)`.
- `Place { var, proj }` con `Proj::Field(i)` y `Proj::Payload(variante, i)`; un lugar
  cuya raíz es `Ref` desreferencia implícitamente.
- Instrucciones (`Inst { kind, span }`): `Assign(var, Rvalue)`, `Store(place, op)`,
  `Append(texto, arg)` (formatea y añade, para interpolación), `Print(arg)`,
  `Drop(var, flag?)` (destruye lo que posee la variable; con flag, solo si el Bool es
  verdadero) y `Moved(var)` (marcador sin efecto en ejecución: la propiedad de su
  contenido salió por partes).
- Operaciones de memoria: *Allocate* = `TextBuffer` (y `Struct`/`Variant` como valores);
  *Load* = `Read(place)`; *Store* = `Store`/`Assign`; *Move* = uso por valor de una
  variable propietaria (`Use`, argumento, retorno, campo); *Borrow* = `Ref(place)` y
  `Arg::Ref`; *Drop* = `Drop`; la copia controlada es `Read` de un tipo Copy.
- `Rvalue`: `Use`, `Unary(Neg|Not)`, `Binary(Add..Ge)`, `Call(f, args)`,
  `Struct(id, campos)`, `Variant(enum, variante, datos)`, `Read(place)`, `Ref(place)`,
  `Discriminant(place)`, `TextEq(place, literal)`, `TextBuffer(capacidad)`.
  `Arg = Value(op) | Ref(place, exclusivo)`.
- Aritmética entera: `Add/Sub/Mul/Div/Rem/Neg` sobre Int **tienen semántica de panic**
  (overflow, división o resto por cero, `MIN / -1`) en el `span` de la instrucción.
  Float sigue IEEE-754.
- Terminadores: `Jump`, `Branch(cond Bool, sí, no)`, `Return(op)`, `Unreachable`.

Lowering (resumen):
- `&&`/`||` → ramas (cortocircuito real). `if` → Branch + bloque de unión.
- `while` → cabecera con la condición; `continue` salta a la cabecera.
- `for i in a..b`/`a..=b` → contador y límite evaluados una vez; cabecera `i < fin`
  (`<=`); bloque *latch* donde salta `continue`; en `..=` el latch sale si `i == fin`
  antes de incrementar, así el incremento nunca desborda (`..=i64::MAX` termina).
- `loop` → cabecera = destino de `continue`; bloque de salida solo alcanzable por `break`.
- `return`/`break`/`continue` terminan el bloque; el código posterior va a un bloque
  sin predecesores (inalcanzable), lo que mantiene el lowering uniforme.
- `match` → el scrutinee se evalúa una vez (si es un lugar se examina en su sitio, si
  no se guarda en un temporal); cada brazo es una cadena de comprobaciones
  (`Discriminant` + comparación, literales, `TextEq`) que salta al brazo siguiente si
  falla; luego se enlazan los bindings (`Read` = copia/movimiento, `Ref` = préstamo,
  según `Function::by_value_bindings`), se ejecuta el cuerpo y se salta al bloque de
  unión. Tras el último brazo: `Unreachable` (exhaustividad ya probada por sema).
- Llamadas a métodos: argumentos primero, luego `Arg::Ref(receptor)`.

**Drops** (`drops.rs`): el lowering emite `Drop(v)` para cada variable propietaria al
salir de su región (sentencia para temporales, bloque para locales y parámetros, más
`return`/`break`/`continue`, que abandonan las regiones interiores); `return` mueve
primero el resultado a una variable sin dueño. La **elaboración** calcula con un
análisis hacia delante el estado de cada variable propietaria (Init/Uninit/Maybe):
borra los drops de valores sin valor, deja los seguros e introduce un flag Bool donde
el estado es Maybe (puesto a verdadero al asignar y a falso al mover o liberar);
antes de reasignar una variable que puede poseer valor inserta su drop, después de
evaluar el valor nuevo.

**Verificador** (`cfg::verify`): bloques sin terminador; saltos a bloques
inexistentes; variables inexistentes; tipos de cada asignación, operación,
proyección, llamada (número y tipo de argumentos, préstamos), `Store`, `Append`,
`Print`, condición de salto y valor de retorno; y **asignación definida**: un análisis
de flujo de datos hacia delante comprueba que toda variable leída se asignó en todas
las rutas alcanzables. Además `drops::verify` demuestra los invariantes de propiedad
(sin uso tras movimiento, sin doble liberación, sin sobrescritura ni fuga al
retornar). Un fallo es un error interno (`L0007 [lir]`), nunca del usuario.

## 3. Backend cranelift (`native.rs`)

- Cranelift **0.137.1** (`cranelift-codegen`, `-frontend`, `-module`, `-object`,
  `-native`) y `target-lexicon 0.13.5`, versiones fijadas con `=` en
  `crates/l/Cargo.toml` y registradas en `Cargo.lock`. 0.137.1 es la última versión
  estable cuyo MSRV (1.97) es compatible con el Rust 1.99.1 del proyecto.
- ISA del host (`cranelift_native`), `opt_level=speed`, verificador de Cranelift
  activado, *stack probes* en línea (no se necesita `__chkstk`).
- Representación: Int → `i64`; Bool → `i8` (0/1); () → ningún valor; **Text → tres
  `i64` `(ptr, len, cap)`**: `len` es la longitud en bytes UTF-8; `cap == 0` indica
  almacenamiento estático (literal: nunca se libera); `cap > 0` indica un buffer de
  heap de `cap` bytes con un único dueño. Un préstamo (`VarTy::Ref`) usa la misma
  representación que el valor (alias de solo lectura que nunca se libera). Cada
  variable de la LIR se convierte en 0, 1 o 3 `Variable` de `cranelift_frontend`.
- Las funciones que devuelven Text reciben un puntero oculto de retorno (*sret*) a una
  ranura de 24 bytes del llamador: la convención de Windows x64 no devuelve tres
  valores en registros, y así no se depende de ella.
- Overflow: `sadd_overflow`/`ssub_overflow`/`smul_overflow` + salto a un bloque de
  panic; división/resto: comprobación de 0 y de `MIN / -1` antes de `sdiv`/`srem`
  (que de otro modo provocarían una excepción del procesador); negación: `x == MIN`.
- Literales Text: datos de solo lectura deduplicados en el objeto.
- Interpolación: `TextBuffer(capacidad)` reserva `max(pista, 16)` bytes (la pista suma
  los literales y el máximo de Int = 20 y Bool = 5 bytes); cada parte se añade con
  `text_push*`; `Drop` llama a `text_drop` (libera solo si `cap != 0`).
- `match` sobre Int/Bool/Text funciona en nativo (incluidos literales Text y bindings
  prestados); sobre enums no.
- Métodos con receptor `self` (`fn` receptor compartido, `mut fn` receptor exclusivo, `static fn` sin receptor):
  plenamente implementados en Cranelift. Las variables prestadas locales se ubican en `StackSlot`
  con el tamaño y alineación exactos del layout. Las llamadas a métodos mutables pasan `Arg::Ref`
  como punteros de máquina `I64` (`place_addr`), permitiendo mutación in-place sin copias.
  En el cuerpo del método, `VarTy::Ref` se desreferencia por offset exacto de memoria.
- `check_supported` rechaza antes de generar código, con `L0008 [backend]` y la
  indicación `use --backend rustc`: características no soportadas aún en el backend nativo. `l check --backend cranelift` ya informa del rechazo.
- Salida: objeto COFF en `target/cranelift/<triple>/<nombre>.obj`, ejecutable junto a él.

## 4. Runtime propio (generado en Cranelift IR)

El ejecutable no contiene Rust ni la biblioteca C. El backend genera, en el mismo
objeto (`native/runtime.rs`), estas funciones; solo usan kernel32: `GetStdHandle`,
`WriteFile`, `ExitProcess`, `GetProcessHeap`, `HeapAlloc`, `HeapReAlloc`, `HeapFree` y
`HeapValidate`. No hay allocator propio: se usa el heap del proceso de Windows.

| Símbolo | Contrato |
|---|---|
| `l_start` | Punto de entrada (`/ENTRY`): llama a `main`, sale con código 0 |
| `l_rt_alloc(n) -> p` / `l_rt_realloc(p, n) -> p` | Heap; si falla: panic «memoria insuficiente», nunca devuelve nulo |
| `l_rt_free(p)` | Libera un bloque exactamente una vez |
| `l_rt_text_reserve` | Asegura capacidad; un Text estático se copia a un buffer nuevo; crecimiento `max(necesario, 2·cap, 16)`; desbordamiento del tamaño → panic |
| `l_rt_text_push` / `_push_int` / `_push_bool` | Añaden bytes / forma decimal / `true`/`false` |
| `l_rt_text_drop(p, l, c)` | Libera si `c != 0` |
| `l_rt_text_eq` | Igualdad de bytes (patrones Text) |
| `l_rt_write`, `l_rt_write_int`, `l_rt_utoa` | Salida y conversión de enteros (incluido `i64::MIN`) |
| `l_rt_print_int` / `_bool` / `_text` | `print` con salto de línea `\n` |
| `l_rt_panic_arith`, `l_rt_fatal` | Mensaje en stderr y terminación anormal |

**Instrumentación para pruebas** (solo si se pide; no cambia la semántica):
`--trace-alloc` cuenta reservas, realocaciones y liberaciones, valida con
`HeapValidate` cada puntero antes de liberarlo (una doble liberación o un puntero
ajeno abortan con «liberación de memoria inválida») y todo el heap al salir, e
imprime `l-alloc: allocs=A reallocs=R frees=F heap_ok=1` en stderr.
`--alloc-fail-after N` hace fallar el intento de reserva N+1 para probar la ruta de
memoria insuficiente.

**Contrato de panic (ambos backends):** stderr recibe exactamente
`Proyecto L <línea>:<columna>: overflow entero o división/resto por cero\n` y el proceso
termina con el estado de un proceso abortado en Windows, `0xC0000409`. El backend rustc
se cambió para usar `eprintln!` + `std::process::abort()` en lugar del mensaje de panic
de Rust, de modo que el mensaje lo define L y ambos backends son comparables.

Enlazado (`linker.rs`): `link.exe /NODEFAULTLIB /ENTRY:l_start /SUBSYSTEM:CONSOLE
objeto kernel32.lib`. `link.exe` se localiza con `vswhere` (componente VC Tools x64) y
`kernel32.lib` en el Windows SDK; se pueden forzar con `L_LINKER` y `L_LIBPATH`. Un
ejecutable típico ocupa 3,5 KB e importa solo esas tres funciones (verificado con
`dumpbin /imports`).

Limitación conocida: `WriteFile` escribe bytes UTF-8 sin conversión; en una consola
cuya página de códigos no sea UTF-8 los caracteres no ASCII se verán mal (en tuberías
y archivos los bytes son exactos). El backend rustc usa `WriteConsoleW` en consolas.

## 5. Backend rustc (`backend.rs`, provisional, predeterminado)

Sin cambios de diseño: transpila la LIR estructurada a Rust y llama a `rustc`
(`opt-level=0`, `panic=abort`, enteros con `checked_*`). Structs → `struct S{id}`,
enums → `enum E{id}`, match → `match` de Rust con bindings `ref` o por valor según
ownership. Sigue siendo el backend predeterminado hasta que Cranelift cubra todo el
lenguaje.

## 6. Pruebas diferenciales y benchmarks

`crates/l/tests/differential.rs` compila cada programa de
`crates/l/tests/differential/*.l`, y cada ejemplo de `examples/` y `ejemplos/` que el
backend nativo admite, con **ambos** backends, ejecuta los dos binarios y exige stdout,
stderr y código de salida idénticos; incluye 8 casos de panic aritmético. Los programas
de `differential/unsupported/` deben ser rechazados por cranelift en check/build/run sin
generar artefactos, y seguir funcionando con rustc. Añadir un caso = añadir un `.l`.

`bench/run.ps1` mide tiempo de compilación, tamaño, mediana de ejecución y pico de
memoria para `bench/programs/*.l` con ambos backends y escribe `bench/results.md`
(ver IMPLEMENTATION_STATUS.md para los resultados y su alcance).

## 7. Structs nativos y layout (dev/native-aggregates)

`layout.rs` calcula el ABI interno Windows x64, sin promesa de ABI C: Bool ocupa
1 byte y alinea a 1; Int, punteros y palabras de Text alinean a 8; Text ocupa 24
bytes. Cada campo empieza en el siguiente offset alineado y el tamaño final incluye
padding hasta la alineación máxima. Los structs anidados aplican la misma regla.
Por ejemplo `{ Bool, Int, Text }`: offsets 0, 8, 16; tamaño 40, alineación 8.

Los locales y argumentos se descomponen en componentes escalares SSA; no se reserva
un objeto en heap por cada struct. `Read`/`Store` seleccionan componentes según la
ruta de campos. Retornar un struct usa un puntero oculto a una ranura de pila del
llamador; las cargas y stores respetan offsets y padding del layout. Los argumentos
por valor transfieren ownership, incluidos structs con Text. No hay copias profundas.

La elaboración produce `DropField(place, flag?)` por hoja propietaria. Evalúa el
valor nuevo antes de liberar el campo reemplazado. Extraer un campo de un temporal
deja drops para sus hermanos. El runtime de Text existente hace la liberación;
no se añadió GC, conteo de referencias ni dependencias.

## 8. Enums nativos y Match (dev/native-enums)

layout.rs calcula el layout de cada enum:
- Discriminante i64 en offset 0 (tamaño 8, alineación 8).
- Payloads de cada variante inician en offset 8 y sus campos se alinean según sus propios tipos.
- Tamaño total = máximo tamaño de variante redondeado a la alineación máxima (mínimo 8).
- Representación SSA: size / 8 palabras I64.

En native.rs:
- Las variables de tipo Type::Enum reservan un StackSlot del tamaño total del layout.
- Rvalue::Variant almacena el discriminante a offset 0 y los campos a sus respectivos offsets, cargando luego los escalares SSA correspondientes.
- Rvalue::Discriminant lee types::I64 a offset 0 desde la dirección del lugar.
- Proyecciones cfg::Proj::Payload(variant, field) resuelven el offset exacto mediante place_byte_offset.
- drop_in_place genera un switch de Cranelift sobre el discriminante: ejecuta las liberaciones dinámicas exclusivamente para la variante activa.
- Parámetros por valor y retornos sret (puntero oculto) funcionan idéntico a structs agregados.
- Option<T> y Result<T, E> se compilan directamente bajo esta misma infraestructura.

## 9. Sistema numérico de punto flotante nativo

El backend nativo soporta completamente `Float` (alias de `f64`), `f64` y `f32`:
- **Representación:** `types::F64` para `Float`/`f64`, `types::F32` para `f32`.
- **Layouts:** `Type::F32` tiene tamaño 4 y alineación 4; `Type::Float` tiene tamaño 8 y alineación 8.
- **Instrucciones:** `fadd`, `fsub`, `fmul`, `fdiv`, `fneg` (sin atrapar divisiones por cero ni desbordamientos, produciendo inf/-inf/NaN según IEEE-754).
- **Comparaciones:** `fcmp` con códigos `FloatCC` (`Equal`, `NotEqual`, `LessThan`, `LessThanOrEqual`, `GreaterThan`, `GreaterThanOrEqual`), respetando la semántica de `NaN` (incomparabilidad y falsedad de predicados ordenados).
- **Conversiones:** `fcvt_from_sint`, `fdemote`, `fpromote` y `fcvt_to_sint_sat` (saturación en flotante a entero, evitando traps).
- **Formateador independiente `l_rt_ftoa`:** Implementado íntegramente en Cranelift IR en `native/runtime.rs` sin CRT de C. Maneja `NaN`, `+/-inf`, `+/-0`, extracción de dígitos significativos con redondeo y poda de ceros finales, coincidiendo con la salida de referencia de Proyecto L.

## 10. Regiones nativas (dev/regions)

- `Region` = un `i64`: dirección de una cabecera de 24 bytes (`{bloque, offset,
  capacidad}`) en un stack slot del frame que abre la región (`RegionNew` la pone a
  cero; en bucles se reinicia en cada iteración tras el drop anterior).
- `Bytes` = `(ptr, len)`, layout 16 bytes; los parámetros `&Bytes` son punteros a ese
  par, como el resto de préstamos.
- `RegionBytes` → `l_rt_region_alloc(cabecera, n, línea, col)`: bump alineado a 8,
  bloques nuevos `max(n, 2·cap, 4096)` de `l_rt_alloc`, desbordamiento → memoria
  insuficiente, datos puestos a cero (`l_rt_zero`), contadores y comprobación de
  alineación en modo traza.
- `BytesGet`/`BytesSet`: comparación sin signo `i < len` (rechaza negativos) y
  `v <= 255`; fallo → `l_rt_panic_at(línea, col, mensaje)`.
- `Drop` de una región → `l_rt_region_free(cabecera)`: libera la cadena de bloques.
- Backend rustc: `LRegion(RefCell<Vec<Box<[u64]>>>)` y `LBytes(*mut u8, usize)`; mismos
  mensajes de panic. Las pruebas comparan ambos.

## 11. Colecciones nativas (dev/native-collections-complete)

- **Layout** (`layout.rs`, `windows_x64_with`): `[T; N]` = `N` elementos con paso
  `size_of(T)` (los tamaños ya son múltiplos de la alineación), alineación de `T`, y sus
  componentes escalares repetidos (límite `MAX_COMPONENTS = 4096`; un array mayor se
  rechaza con L0008 pidiendo `List<T>` o `--backend rustc`). `List<T>` = 24 bytes
  `(ptr, len, cap)`; slice = `(ptr, len)`.
- **Variables en memoria:** toda variable cuyo tipo contiene un array o una lista (por
  valor) tiene stack slot; los elementos se alcanzan con direcciones calculadas y se
  leen/escriben solo en memoria (las variables SSA de esas variables no se usan).
- **Lugares indexados** (`place_addr`): campos y payloads suman offsets constantes; un
  `Proj::Index` compara `i` sin signo con la longitud (constante en arrays, cargada de
  la cabecera en listas, segundo valor del parámetro en slices) y salta a
  `l_rt_panic_at(línea, columna, "índice fuera de rango")`; después `data + i·paso`.
  La posición es la de la instrucción CFG, que el lowering fija en el `[` del acceso
  (lectura, escritura, `print`), igual que el backend rustc.
- **Parámetros y resultados:** `&[T]`/`&mut [T]` ocupa dos argumentos `(ptr, len)`; el
  llamador los obtiene del array (dirección del slot, `N`), de la lista (cabecera) o
  de otro slice. Arrays y listas se devuelven por puntero oculto (sret), como structs.
- **Operaciones:** `ListLit` reserva `n·paso` bytes (ninguno si `n = 0`) y escribe los
  elementos; `ListPush` evalúa el elemento, llama a `l_rt_list_reserve(hdr, 1, paso, 4,
  l, c)` solo si `len == cap`, escribe en `ptr + len·paso` e incrementa `len`;
  `ListReserve` llama a la misma rutina con mínimo 0; `ListTakeLast` (tras la
  comprobación `len > 0` del CFG) decrementa `len` y carga el último elemento, que
  deja de pertenecer a la lista. `Store` en un lugar indexado libera primero el
  elemento anterior si su tipo lo requiere.
- **Runtime:** `l_rt_list_reserve(hdr, n, paso, mínimo, línea, columna)` aplica la
  política `max(len + n, 2·cap, mínimo)` con aritmética comprobada (`sadd/smul_overflow`),
  usa `l_rt_alloc` si `cap == 0` y `l_rt_realloc` si no, y solo actualiza la cabecera
  tras el éxito. Mensajes nuevos: `índice fuera de rango`, `reserve con tamaño
  negativo`, `capacidad de List desbordada`.
- **Drops:** un array libera sus elementos con un bucle; cada tipo de lista tiene su
  glue `l_list_drop{l}(ptr, len, cap)` como función propia (permite datos recursivos a
  través del heap, p. ej. un struct con `List` de sí mismo) que libera los `len`
  elementos y después el buffer si `cap != 0`. `DropField` sobre un campo que no es
  Text (p. ej. un `List` en un struct) usa la misma glue.
- **Drops elaborados:** un `Store` sobre un elemento no se elabora como drop del lugar
  (que colapsaría a la colección entera); el reemplazo del elemento lo hace el backend.

## 12. Pendiente para el backend nativo


2. Traits e interfaces dinámicas/polimórficas.
3. Iteración `&mut`; arrays de más de 4096 componentes.
4. Otras plataformas, ABI externo y optimizaciones medidas.

Las pruebas diferenciales conservan rustc como referencia. Admitir structs no cambia
el backend predeterminado ni demuestra superioridad de rendimiento.

El layout nativo limita la descomposición a 4096 componentes escalares por struct.
Una declaración pequeña con anidamiento duplicado puede crecer exponencialmente;
se rechaza con diagnóstico antes de agotar la memoria del compilador. Es un límite
del backend actual, no una promesa semántica del lenguaje.


## 13. Listas regionales

La cabecera nativa añade el puntero de región a `(ptr, len, cap)`. Las listas
ordinarias conservan sus tres palabras. `Rvalue::RegionList` referencia una región
tipada y genera una cabecera vacía. Los lugares indexados y los slices reutilizan
el layout y las comprobaciones de listas existentes.

La rutina de crecimiento recibe un puntero de región opcional. Con región
reserva mediante `l_rt_region_alloc`, que alinea a 8 bytes en Windows x64.
La política comprueba longitud y producto capacidad por stride antes de reservar.
Copia solo el prefijo vivo y publica la cabecera tras el éxito. El camino del
heap conserva su política de realocación. Los drops regionales recorren los
elementos vivos sin llamar a `free` sobre el buffer.

El backend rustc usa el allocator de referencia de `LRegion` y una cabecera
`LRegionList<'r, T>` que toma prestada la región. Las reservas quedan registradas
en la región para su liberación conjunta. Su estrategia física asigna por rango,
mientras que el allocator bump nativo agrupa rangos en bloques.


## 14. Préstamos locales

`BindRef` baja a `Loan(place, exclusive, type)` con lugar tipado y modo de
acceso. El pase de préstamos comprueba usos y alias antes de elegir backend.
Cranelift usa direcciones de slots alineados para locales cuyo lugar se toma
prestado, o calcula la proyección de un campo o elemento. Un slice lleva
dos palabras. El backend rustc emite un binding de referencia Rust con
desreferenciación en los accesos. En ambos, los índices se evalúan antes de
activar el préstamo y los argumentos por valor antes de prestar los lugares
de la llamada. Reemplazar un valor propietario a través de una referencia exclusiva
destruye el contenido anterior y conserva la dirección.


## 15. ABI de retornos prestados

La LIR registra el contrato de origen. El CFG tipa como `Ref(T)` la llamada
que devuelve una referencia y emite `ReturnRef` después de los drops.
Cranelift retorna una dirección en un registro, también cuando el referente
es Text o un agregado. Un slice retorna dirección y longitud en dos registros. Los retornos propietarios mantienen su ABI habitual.
El backend rustc nombra un lifetime común para los parámetros candidatos y
el resultado.
El análisis de procedencia y exclusividad se ejecuta antes de ambos backends.


## 16. Punteros en vistas locales

`SharedField` describe un campo físico de 8 bytes alineado a 8 en Windows x64.
El constructor guarda la dirección de un `Loan`. `FieldLoan` carga el puntero
del campo y lo representa como `Ref(T)`. El movimiento conserva la procedencia
que reconstruye el verificador. Cranelift conserva el layout de los campos
propietarios y el ABI existente. Rust emite referencias compartidas y un
lifetime común para el struct. Los drops no recorren el referente.


## 17. Retorno de agregados con referencias (sret y desreferenciación)

- **Cranelift:** Las funciones que retornan structs con referencias utilizan el convenio de retorno por puntero oculto (`by_sret`, argumento oculto 0 en RCX en Windows x64). El llamador reserva el slot de stack y pasa el puntero; el callee almacena los campos del struct (incluyendo los punteros de 8 bytes de `SharedField`). En el llamador, la instrucción `FieldLoan` carga la dirección correspondiente desde el struct en stack y la proporciona como un `Ref(T)`.
- **Rustc:** El emisor transpila el struct con parámetro de lifetime `<'l>`. Las inicializaciones de referencias en la construcción de la vista devuelta se emiten preservando el tipo y permitiendo al compilador de referencia compilar mutaciones disjuntas válidas sin violar las comprobaciones estáticas completadas por Proyecto L.
- **Drops:** Los drops generados para agregados mixtos destruyen los campos propietarios en el llamador sin desreferenciar ni liberar los punteros prestados, verificado con `--trace-alloc` (`heap_ok=1`, `allocs == frees`).

## 18. Referencias mutables en agregados y reasignación de vistas

- **Layout e instrucciones:** `Type::MutField` tiene un layout idéntico a `Type::SharedField`: 8 bytes de tamaño y 8 de alineación en Windows x64 (un puntero crudo `*mut T`).
- **Desreferenciación y modificación (`FieldLoan`):** Cuando se asigna a un campo mutable (`vista.campo = valor`, `self.campo += 1`), el CFG emite un `FieldLoan` que carga el puntero del campo como `Ref(T)` y seguidamente ejecuta un `Store` sobre dicho puntero. En Cranelift nativo, la dirección cargada se desreferencia en memoria para escribir el valor. En el backend de referencia Rustc, se emite `(*vista.m0) = valor;`.
- **Reasignación (`vista = ...`):** Las reasignaciones a variables de vista completas reutilizan el identificador local en SSA sin forzar nuevas asignaciones desconectadas, permitiendo que Cranelift cree nodos phi naturales en puntos de unión de control de flujo.
- **Backend Rustc:** Emisión de `&'l mut T` en structs con `MutField`, lifetime `<'l>` en receptores de vista con métodos mutables, y moldeado seguro en inicializaciones con `&mut *({expr} as *mut _)`.

## 19. Referencias en enums, Option, Result y colecciones (Cranelift y Rustc)

- **Layout de variantes y colecciones:** Las cargas útiles de variantes y elementos de colecciones con `SharedField` y `MutField` tienen tamaño de 8 bytes y alineación de 8 bytes en Windows x64 (punteros crudos de 64 bits).
- **Cranelift nativo:**
  - En las variantes de enum, el discriminante ocupa la cabecera seguida por los slots de carga útil donde se almacenan los punteros directos.
  - En arrays y listas, los punteros se almacenan contiguos en memoria. Las lecturas por índice o desempaquetado de variantes cargan directamente la dirección o el valor escalar según el tipo requerido por la instrucción consumidora.
- **Backend de referencia Rustc:**
  - Cálculo inductivo de `lifetime_enums` y `lifetime_structs` para emitir el parámetro de lifetime genérico `<'l>` cuando cualquier variante o campo contenga referencias (`&'l T`, `&'l mut T`).
  - Omisión de doble desreferenciación en `ValueKind::Local`, `read_place`, `write_place` y `loan_place` cuando el tipo LIR del binding es `SharedField` o `MutField`.
  - Tratamiento adecuado de las colecciones regionales `LRegionList` conteniendo referencias para evitar nombres de lifetime no declarados en enlaces intermedios.
- **Drops e integridad:** La destrucción de una colección o variante con referencias emite código de liberación para las variantes propietarias o los búferes de asignación, pero nunca para los referentes apuntados por las referencias.

## 20. Asincronía nativa (dev/native-async-foundation)

Detalle del modelo en [ASYNC_MODEL.md](ASYNC_MODEL.md) y del runtime en
[FUTURE_RUNTIME.md](FUTURE_RUNTIME.md).

- **Lowering (cfg.rs).** Cada `async fn` produce tres funciones de la LIR de
  bloques: la que llaman los programas (reserva el estado, guarda los argumentos
  y devuelve el manejador, conservando el índice original para que las llamadas
  sigan siendo válidas), `f$poll(estado: &mut Estado) -> Int` y
  `f$drop(estado: &mut Estado)`. Las dos últimas se añaden al final del módulo en
  índices deterministas (`n_funciones + 2·i`, `+ 1`). Un `async fn main()` añade
  además `main$ejecutor`, que pasa a ser el punto de entrada del módulo.
- **Estado.** Un struct sintético `f$estado` con `reanudar: Int` en el campo 0,
  el resultado en el campo 1 y después los parámetros, los locales guardados
  (solo tipos sin recursos), el contador/límite de cada `for` sobre rango y un
  campo por tipo de future esperado (reutilizable: el future se libera y el campo
  se limpia antes del siguiente `await`).
- **IR nueva.** `Rvalue::FutureNew(i)` (bloque de estado a cero),
  `Rvalue::FutureState(lugar)` (el manejador como `&mut Estado`),
  `InstKind::Clear(lugar)` (escribe ceros sin liberar: el lugar deja de poseer lo
  que ya se movió) y `InstKind::Wake`. Todo pasa por el verificador y por la
  elaboración de drops antes del codegen.
- **Cranelift.** `Type::Future(_)` son 8 bytes (un puntero). `FutureNew` reserva
  el tamaño del struct de estado y lo pone a cero con `l_rt_zero`; `FutureState`
  es el propio puntero; `Clear` pone a cero el tamaño del lugar; `Wake` y
  `Wake` llama a `l_rt_wake`. Liberar un manejador llama al
  `f$drop` de su tipo y después a `l_rt_free`, con comprobación de puntero nulo
  (un manejador a cero o limpiado no posee nada). Las variables que contienen un
  manejador viven en un stack slot, como las colecciones.
- **Elaboración de drops.** Un `DropField` sobre un lugar detrás de una
  referencia se conserva tal cual (la función no posee ese lugar y no hay estado
  de propiedad que consultar); antes se descartaba, lo que habría dejado sin
  liberar el estado de las tareas.
- **Backend rustc (referencia).** `async fn` emite `async fn` y `await` emite
  `.await`: los futures de Rust son perezosos y basados en `poll`, igual que los
  de L. El prelude (`backend/async_runtime.inc.rs`) añade `LYield` y el
  planificador equivalente. Las pruebas diferenciales comparan las dos
  implementaciones.
- **Instrumentación.** `--trace-alloc` informa `suspends`: los sondeos que
  devolvieron `Pending` y cuya tarea se reanudó. Distingue una suspensión real de
  un cuerpo ejecutado de corrido.

## 21. Tareas y planificador (dev/native-spawn-structured)

Modelo en [ASYNC_MODEL.md §7](ASYNC_MODEL.md) y runtime en
[FUTURE_RUNTIME.md §3](FUTURE_RUNTIME.md).

- **Lowering (cfg.rs).** `spawn f(args)` construye el future como una llamada
  normal y lo mueve al planificador con `Rvalue::TaskSpawn(operando, tipo)`,
  cuyo resultado es el handle. `await` sobre un handle genera la misma forma que
  `await` sobre un future, con `Rvalue::TaskReady` en lugar del sondeo directo:
  si la otra tarea no ha terminado, esta se suspende y el planificador la
  despierta; si ha terminado, se toma su resultado con `Rvalue::TaskState`, se
  limpia el campo y se destruye el handle. `main$ejecutor` pasa a ser
  `TaskSpawn` de la tarea raíz, `InstKind::RunTasks` y la destrucción del handle.
- **Locales en el estado.** Un local cuyo tipo debe sobrevivir a una suspensión
  (`TaskHandle<T>` en esta etapa; propietarios generales en §23) vive en el estado de la tarea en lugar de una variable
  de la función `poll`. Enlazarlo guarda en el campo,
  leerlo lee y limpia el campo (un movimiento), salir del scope destruye el
  campo sin condiciones, y la suspensión no toca nada (`drop_frames_keeping_state`
  libera solo lo que vive en el marco).
- **IR nueva.** `Rvalue::TaskSpawn`, `Rvalue::TaskReady`, `Rvalue::TaskState` e
  `InstKind::RunTasks` (sustituye a `TaskWait`), todas verificadas y con sus
  efectos de propiedad declarados (spawn mueve el future; las demás solo leen).
- **Cranelift.** `Type::Task(_)` son 8 bytes (puntero al registro de la tarea).
  `TaskSpawn`, `TaskReady`, `TaskState` y `RunTasks` llaman a `l_rt_task_spawn`,
  `l_rt_task_ready`, `l_rt_task_state` y `l_rt_run`; destruir un handle llama a
  `l_rt_task_cancel`, que tolera el puntero nulo (un handle movido vale cero) y
  saca el registro de la cola de listas antes de liberarlo.
  `Gen::dispatch` genera `l_task_poll(tipo, estado)` y `l_task_drop(tipo, estado)`
  cuando ya están declaradas las funciones de usuario, así que el planificador no
  guarda punteros a función y todas sus llamadas son directas.
- **Rechazos.** Un future o un handle solo puede ser el valor de un enlace, de
  una asignación a un local o de una sentencia por sí sola, o el operando de
  `await`/`spawn`; en cualquier otra posición (agregado, argumento, expresión
  compuesta, retorno) es `L0015`. La misma comprobación cerró ese hueco para los
  futures del incremento anterior.


## 22. Propiedad de Text en el estado async

`cfg.rs` sintetiza un enum interno por módulo con `Empty` y `Full(Text)` y
reserva una ranura por local `Text` explícito. Usa `Variant`, proyección
`Payload`, `Store`, `DropField` y `Clear` existentes. La elaboración inserta
el drop previo a la escritura. Cranelift usa el destructor de enum existente.

`Terminator::Suspend` devuelve `Pending` al planificador. El destino de
reanudación es una arista lógica que usa `async_state.rs` para verificar
la inicialización y el vaciado de las ranuras. El verificador contrasta
cada arista con el índice de reanudación guardado y su despacho real.
El análisis de asignación de temporales no sigue esas aristas. El backend
rustc sigue usando el estado generado por Rust y sirve de referencia en
las pruebas diferenciales.


## 23. Parámetros, agregados y colecciones en el estado async

`cfg.rs` comparte un enum interno de ranura por cada tipo propietario
admitido. La fábrica inicializa los parámetros antes de devolver el
`Future`. La proyección de carga se amplía con rutas de campos; un movimiento
parcial lee y limpia el subárbol. `async_state.rs` verifica la construcción,
la inicialización de subárboles, el despacho de reanudación y las
transiciones de movimiento, reemplazo y limpieza. El verificador exige una
prueba de discriminante para acceder a un payload persistente.

Un brazo de `match` que mueve payloads de un enum propietario toma el
discriminante y la carga en un temporal del brazo. Los payloads extraídos
se limpian en ese temporal para que su destructor pueda liberar los que
queden. El acceso a un elemento de una colección mantiene su estado de
propiedad y aplica los límites existentes. Cranelift usa las operaciones
de layout, copia, puesta a cero y destrucción ya implementadas. Rustc
conserva sus propios futures como referencia diferencial.


## 24. Coordinación de dos tareas

La LIR estructurada representa `await join(a, b)` con `ValueKind::Join`.
Sema sintetiza un struct por par de tipos. Ownership consume los dos
operandos y efectos analiza su evaluación. El lowering nativo comparte
la ruta de `await` de handles. Reserva ranuras por tipo de tarea y posición,
emite ambas consultas `TaskReady` antes de ramificar y ejecuta `TaskState`
solo en la continuación en que ambas están listas. Los slots se limpian
al transferir los resultados. La destrucción usa los drops de handles
que ya genera cada función async.

Cranelift conserva las operaciones existentes del runtime y el enlazado
nativo. Rustc emite una espera conjunta con `poll_fn`. Ambas consultas se
realizan antes de decidir Pending y cada resultado se toma una sola vez.


## 25. joinAll y grupos dinámicos

El grupo reutiliza el tipo y layout de `List` con handles propietarios.
Sema comprueba homogeneidad por tipo de resultado y limita las operaciones
que pueden observar un handle. El tipo del elemento en el CFG usa un
representante por resultado. Cranelift verifica que los estados con el
mismo tipo de resultado tengan el mismo offset de resultado, mientras
cada registro conserva el identificador real de sondeo y destrucción.

El lowering mueve el grupo a una ranura verificada del padre y usa
`GroupRegister` antes de suspender. La reanudación lee `GroupPending`
sin recorrer las hijas. Después mueve el grupo fuera de su ranura y
llena una lista de resultados en orden. Rustc usa `Vec<LTask<T>>` y
el mismo protocolo de registro y contador en su planificador.

## 26. Temporizadores

`sleepMs` se declara como builtin async al usarlo. La CFG valida su
argumento, registra una vez y comprueba el estado de espera al
reanudar. Cranelift llama al ABI de `native/timers.rs`, con reloj y
espera detrás de funciones independientes. Los objetos que contienen
el builtin enlazan con `mincore.lib` para el reloj. Rustc usa un
árbol ordenado e `Instant`. [ABI y mediciones](TIMER_RUNTIME.md).


## 27. Servicios de plataforma para herramientas L

Cranelift emite las llamadas Win64 de archivos y argumentos a un
objeto auxiliar opcional en Rust `no_std`, preparado por el build
de Stage 0. El CLI lo enlaza con `shell32.lib` y `kernel32.lib`.
El objeto usa el allocator de L y entrega un `TextOut` de tres
palabras. El codegen convierte ese resultado y su estado a la
representación verificada de `Result<Text, Int>`. El ejecutable
resultante no enlaza la CRT ni std de Rust.

La salida de errores reutiliza el escritor del runtime. El código de
salida explícito de main se pasa a Win32 después de drops y traza.
La referencia genera las operaciones equivalentes con Rust std.
[ABI y mediciones](LEXER_FILE_CLI.md).

## Backend provisional para Stage 1

`l build-lir archivo.lir [--trace-alloc]` y `l run-lir` compilan la LIR
que escribe Stage 1. Analizan el [protocolo](LIR_PROTOCOL.md) en
`cfg::Module` y la validan con `cfg::verify` y `drops::verify`. Después
reutilizan `native::check_supported`, `native::compile` y el enlazador.
Los drops llegan ya elaborados: el backend no ejecuta `drops::elaborate`.
Escribir a través de una raíz `ref` suelta el referente anterior dentro
del `Store`, como en Stage 0.
