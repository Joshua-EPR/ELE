# Protocolo LIR de ELE, versión 1

Formato textual con el que Stage 1 entrega la LIR al backend provisional.
Lo escribe `sema-l archivo.l --emit-lir` (código ELE) y lo leen
`l build-lir` / `l run-lir` (`crates/l/src/lir_protocol.rs`). Sustituye
la propuesta anterior de serializar el CFG de Stage 0: el contenido es la
LIR de bloques que ya compila Cranelift, escrita por Stage 1.

## Reglas generales

- UTF-8, un registro por línea y campos separados por un único espacio.
  No se admiten espacios iniciales, finales ni dobles.
- Tamaño máximo de 64 MiB. Cada tabla (structs, campos, funciones,
  variables, bloques, instrucciones, argumentos) admite hasta 2^20
  elementos. Un nombre o un texto admite hasta 1 MiB.
- Los identificadores llevan prefijo: `s` (struct), `f` (función), `v`
  (variable) y `p` (lugar). Siempre se comprueba que estén dentro de rango.
- Los enteros son decimales sin signo `+`. `ci` acepta los valores de i64;
  un desbordamiento es un error.
- Un nombre o un texto se escribe `<longitud>:<byte>,<byte>,...` con los
  bytes UTF-8 en decimal. La longitud debe coincidir, cada byte debe ser
  0..255 y el resultado debe ser UTF-8 válido. No hace falta escapar nada.
- La deserialización construye estructuras Rust validadas. No se
  reinterpreta memoria cruda ni se depende del layout del compilador.

## Estructura

```text
ELE-LIR 1
module structs <S> funcs <F> main f<k>
struct s<k> <nombre> fields <N>          (S veces, en orden)
field <nombre> <tipo>                    (N veces)
func f<k> <nombre> params <P> result <tipo> <ref 0|1> <mut 0|1> vars <V> blocks <B>
var v<i> val|ref <tipo>                  (V veces, en orden; las P primeras son parámetros)
block <b> <n>                            (B veces, en orden)
i ... [@<línea>:<col>]                   (n instrucciones)
t ... [@<línea>:<col>]                   (un terminador)
endfunc
end
```

Una versión distinta de `ELE-LIR 1` se rechaza. No puede haber contenido
después de `end`.

**Tipos.** `i` (Int), `f` (Float), `b` (Bool), `t` (Text), `u` (Unit) y
`s<k>` (struct `k`). Una variable `ref` contiene una referencia a un valor
de ese tipo.

**Resultado prestado.** `ref 1` declara que la función devuelve una
referencia que toma prestado de sus parámetros referencia; `mut 1`
indica que es exclusiva.

## Operandos, lugares y argumentos

| Forma | Significado |
| --- | --- |
| `v<i>` | variable |
| `ci<n>`, `cb0`, `cb1`, `cu`, `ct<texto>` | constantes Int, Bool, Unit y Text |
| `p<i>(.<campo>)*` | lugar: variable (el referente si es `ref`) y proyecciones de campo; cada campo se valida contra el struct |
| `val <operando>` | argumento por valor (mueve un valor propio) |
| `ref <lugar> <0\|1>` | argumento por referencia compartida o exclusiva |

## Instrucciones

| Registro | Block LIR (Stage 0) |
| --- | --- |
| `i use v<d> <op>` | `Assign(d, Use(op))` |
| `i unary v<d> neg\|not <op>` | `Assign(d, Unary)` |
| `i binary v<d> <add\|sub\|mul\|div\|rem\|eq\|ne\|lt\|le\|gt\|ge> <op> <op>` | `Assign(d, Binary)` |
| `i call v<d> f<k> <n> <arg>...` | `Assign(d, Call(k, args))` |
| `i struct v<d> s<k> <n> <op>...` | `Assign(d, Struct)`; `n` debe ser el número de campos |
| `i read v<d> <lugar>` | `Assign(d, Read(lugar))` |
| `i loan v<d> <lugar> <0\|1>` | `Assign(d, Loan(lugar, mut, tipo de d))` |
| `i textbuf v<d> <capacidad>` | `Assign(d, TextBuffer)` |
| `i append v<d> <arg>` | `Append(d, arg)` |
| `i store <lugar> <op>` | `Store(lugar, op)` |
| `i print <arg>` | `Print(arg)` |
| `i drop v<d> v<flag>\|-` | `Drop(d, flag)` |
| `i dropfield <lugar> v<flag>\|-` | `DropField(lugar, flag)`; exige al menos un campo |

## Terminadores

`t jump <b>`, `t branch <op> <b_verdadero> <b_falso>`, `t return <op>`,
`t returnref v<i>` y `t unreachable`. El sufijo opcional
`@<línea>:<col>` es la posición de origen que usan los diagnósticos de
ejecución, como el overflow o la división entre cero.

## Validación en el backend

1. Análisis léxico y sintáctico del protocolo, con todos los límites y
   rangos anteriores. Un error produce `L0017 [lir-protocolo]` con la línea
   del archivo LIR.
2. `cfg::verify`: tipos de cada instrucción y terminador, firmas de
   llamada y bloques.
3. `drops::verify` por función: sin uso tras movimiento, sin doble
   liberación, sin fuga por sobrescritura y sin fuga al retornar.
4. `native::check_supported` y generación con Cranelift.

Ningún paso ejecuta el lexer, el parser, la semántica ni el lowering de
Stage 0.

## Capacidades de la versión 1

Funciones, structs, Int, Bool, Text, Unit, referencias y préstamos,
retornos prestados, interpolación, `print`, ramas, bucles y drops (con y
sin flag). Float no se produce todavía: Stage 1 no tiene literales
flotantes. Enums, listas, arrays, `Option`/`Result`, regiones y async no
formaban parte del subconjunto verificado de la fase 7; Stage 1 los rechazaba con `L0016` antes de emitir.

## Estado recuperado en fase 8.2

El parser Rust acepta ahora secciones opcionales `enums` y `lists`, tipos `eN` y `lN`, lugares indexados `[vN]` e instrucciones `len`, `listpush`, `listpop`, `listreserve`, `listlit`, `byteat`, `platform`, `variant` y `disc`. El encabezado sigue siendo `ELE-LIR 1`; este cambio es una extensión provisional del mismo protocolo y aún carece de cobertura vertical para listas, enums y `Option`/`Result`. No usar estas extensiones como prueba de soporte completo. El backend continúa aplicando `cfg::verify` y `drops::verify`.

## Extensión interoperable de payloads primitivos (8.7.4.2)

El registro `i payload vD pN eE V` solicita una lectura **Copy** del único
campo `Int` o `Bool` de la variante `V` del enum nominal `eE` en la variable
`pN`. Ambos lectores (Rust de bootstrap y backend ELE) deben verificar que el
lugar sea directo, corresponda a `eE`, que `V` exista y tenga exactamente un
campo de tipo idéntico al del destino. No se permiten referencias, campos
anidados ni payloads propietarios mediante esta instrucción.

La comprobación de variante activa es **dinámica** en ambos backends: si el
discriminante real no coincide con `V`, el lector no accede al payload. El
backend ELE experimental sale con código 126; el backend Cranelift provisional
informa un panic localizado. Esta protección no sustituye el análisis semántico
de la fuente. El protocolo sigue denominado `ELE-LIR 1`: es una extensión
aditiva, pero otros consumidores deben anunciar explícitamente su soporte.

Stage 1 comienza a representar enums **unitarios** mediante declaraciones
`enum eN`, tipos `eN`, `i variant` e `i disc` en lugar de convertirlos a `Int`.
La fase 8.7.4.3 introduce una **implementación de Stage 1 aún no compilada ni
verificada con Stage 0** para variantes de un único payload `Int`/`Bool` y
bindings de `match` sobre ese mismo subconjunto. La serialización utiliza
`i variant vD eE V 1 <op>` y `i payload vD pN eE V`. La proyección Copy
solamente se emite en el brazo de la variante correspondiente; ambos backends
conservan el chequeo dinámico del discriminante activo. Se valida cobertura
de variantes antes de tratar el último brazo como salto incondicional.

`Option<T>`, `Result<T,E>`, `?`, payloads propietarios, préstamos y
movimientos parciales de payload siguen rechazándose por Stage 1. La presencia
de estas instrucciones en el texto LIR no prueba compilación ni ejecución nativa.

`i len` baja a `Rvalue::Len` para `Text` y colecciones. La prueba `projected_text_length_uses_byte_length_in_backend` verifica un `Text` proyectado desde un struct, con LIR generado por Stage 1 y ejecución nativa equivalente a Stage 0. Antes de estabilizar otras instrucciones nuevas, especificar sus tipos, ownership y efectos, añadir casos válidos y malformados y decidir una versión nueva del protocolo si se rompen consumidores de la versión 1. Ver [autocobertura](STAGE1_SELF_COVERAGE.md).

## Ampliación provisional de listas en fase 8.3

`i cap vN <lugar>` baja a `Rvalue::Cap` y exige una lista. `list lN <elemento>`, `i listlit`, `i listpush`, `i listreserve` y los lugares indexados tienen pruebas verticales y de LIR malformada. Se conserva `ELE-LIR 1` provisionalmente. [Detalle](PHASE_8_3.md).
