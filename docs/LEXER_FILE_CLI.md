# Driver autónomo del lexer

El programa L recibe una ruta real, abre y valida el archivo, llama
a `lexSource(&Text)` y escribe tokens en stdout. El proceso puede
ejecutarse directamente después del build. El script de compilación
ensambla los fuentes L de lexer, emisión y CLI en una unidad porque
Stage 0 aún carece de imports entre archivos. La ruta y el contenido
del programa analizado se obtienen en ejecución.

```powershell
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
cargo build --bin l
$lexer = & ./compiler-l/build-lexer.ps1
& $lexer 'C:\fuentes\código con espacios.l'
$LASTEXITCODE
```

El script también acepta `-Backend rustc` para construir la referencia.
Use `-TraceAlloc` con Cranelift para habilitar los contadores.

Cada línea de stdout tiene formato `tipo:inicio:fin`, con rangos de
bytes semiabiertos en el archivo original. EOF tiene rango vacío.
Se omite un BOM UTF-8 inicial sin alterar los offsets. Se preserva
CRLF y solo LF produce token de salto. Los errores léxicos llevan
ruta, línea y columna de escalares Unicode a partir de uno y offset
de byte a partir de cero. El BOM no suma una columna. La paridad
probada con Stage 0 cubre palabras, enteros, símbolos y comentarios,
incluidos comentarios con Unicode. Stage 0 no omite el BOM en su
lexer. Strings, interpolación, Float y espacios Unicode siguen
fuera del subconjunto del lexer L.

| Estado | Significado |
| ---: | --- |
| 0 | Tokens emitidos |
| 2 | Argumentos incorrectos o ruta inválida |
| 3 | Archivo inexistente |
| 4 | Error de apertura o lectura |
| 5 | UTF-8 inválido |
| 6 | Error léxico |
| 7 | Archivo mayor de 16 MiB |

## Servicios públicos

| Firma | Semántica | Efectos propios |
| --- | --- | --- |
| `processArgCount() -> Int` | Cuenta argumentos sin el nombre del ejecutable. `-1` si falla la consulta nativa. | `io, alloc` |
| `processArg(index: Int) -> Result<Text, Int>` | Devuelve un `Text` propietario, admite argumentos vacíos. Errores 1 por índice, 2 por UTF-16 inválido y 3 por fallo al consultar argumentos nativos. | `io, alloc, panic` |
| `readText(path, maxBytes: Int) -> Result<Text, Int>` | Presta el argumento `Text` de ruta durante la llamada. Devuelve contenido propietario UTF-8 sin convertir CRLF ni retirar BOM. | `io, alloc, block, panic` |
| `printError(text)` | Presta el argumento `Text` y escribe una línea en stderr. | `io, block` |
| `fn main() -> Int` | Punto de entrada síncrono con tipo explícito. Los drops de main preceden a la salida. Códigos 0–255 se devuelven tal cual y los demás se convierten en 255. | Efectos del cuerpo |

`readText` admite límites inclusivos de 0 a 64 MiB. Devuelve error
1 por ruta o límite inválido, 2 si no encuentra el archivo, 3 por
I/O, 4 por UTF-8 inválido y 5 si encuentra datos por encima del
límite. Exige una ruta no vacía, sin NUL y fuera de los espacios
de nombres de dispositivos. La longitud admisible también está
sujeta a la configuración de rutas largas de Windows. Las reservas
del buffer crecen hasta el máximo solicitado. Si se llena, una
sonda de un byte distingue EOF exacto de exceso de tamaño. El
runtime procesa lecturas cortas sin interpretarlas como EOF.

Los errores normales regresan por `Result`, con limpieza de buffers
y handles. Un fallo de reserva mantiene la política de panic del
runtime. El cierre en ese caso depende de la terminación del
proceso por el sistema. Este incremento no expone buffers binarios
propietarios ni handles al código L.

## Plataforma y ABI

El build de Stage 0 genera un objeto Win64 a partir de
`crates/l/src/native/platform_object.rs`, escrito en Rust `no_std`.
El CLI lo enlaza únicamente en programas Cranelift que consultan
argumentos o leen archivos. Se usa el allocator instrumentado de
L y las bibliotecas de importación del SDK. Construir un programa
con el Stage 0 existente y ejecutar el PE no inicia `rustc`. En
este camino, el objeto auxiliar incluye código compilado desde Rust
y no enlaza la biblioteca estándar ni la CRT. La referencia usa
Rust std en el código generado y sigue invocando `rustc` al construir.
Se compiló y ejecutó el driver con `PATH` vacío sobre una ruta con
espacios, acentos y emoji. `dumpbin /dependents` confirmó
`KERNEL32.dll` y `SHELL32.dll` como sus dos dependencias directas.

El ABI interno usa escalares Win64 y un `TextOut` de tres palabras
para puntero, longitud y capacidad. El codegen inicializa ese
espacio a cero y convierte el estado y el payload a
`Result<Text, Int>`. La ruta queda prestada hasta que vuelve la
llamada. Los temporales UTF-16 y los handles permanecen en el
auxiliar. Al devolver un resultado propietario, el buffer se
transfiere al mecanismo de drops existente. Esta frontera puede
mantenerse al trasladar la implementación a L. Aún no hay una
FFI pública.

Win64 obtiene argv con `CommandLineToArgvW` y libera su bloque con
`LocalFree`. Usa conversión UTF-16 estricta para los argumentos.
La validación de los archivos consulta `MultiByteToWideChar` con
`MB_ERR_INVALID_CHARS` y tamaño de salida cero. Así comprueba el
buffer UTF-8 sin crear una segunda copia del contenido. [Argumentos Win32](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-commandlinetoargvw) · [Conversión UTF-8](https://learn.microsoft.com/en-us/windows/win32/api/stringapiset/nf-stringapiset-multibytetowidechar) · [Apertura y lectura](https://learn.microsoft.com/en-us/windows/win32/fileio/opening-a-file-for-reading-or-writing)

## Pruebas y medición

```powershell
cargo test --test file_cli
cargo test
cargo fmt --check
cargo clippy --all-targets -- -D warnings
pwsh -NoProfile -File bench/lexer-file.ps1 -Runs 5
```

Las pruebas crean archivos reales y ejecutan ambos backends. Verifican
stdout, stderr, estado de salida y, para el nativo, reservas y
liberaciones, handles abiertos y cerrados e integridad del heap.
El benchmark registra lecturas cortas reales. No se inyectó un
fallo de Windows a mitad de un `ReadFile` ni se instrumentó el
código máquina generado con sanitizers.

El benchmark usa los mismos archivos ASCII con comentarios y
compara toda la salida de tokens. Stage 0 usa directamente la
biblioteca del lexer Rust en modo debug para admitir cargas mayores
de 256 KiB. La sonda Cranelift usa el lexer y emisor reales en L
con traza activa. Se ejecuta un calentamiento y se calcula la
mediana de cinco ejecuciones por carga. Apertura (incluida preparación
de ruta), lectura y UTF-8 se miden en el auxiliar Win64 con QPC.
Tokenización y emisión se estiman entre marcas observadas en el
stdout de la sonda. En Stage 0, las cinco fases se miden con
`Instant` dentro del proceso. El tiempo total y pico residente se
observan externamente. La caché del sistema no se vacía. Los tiempos
incluyen el coste de instrumentación y los dos métodos de medida
tienen diferente resolución. [Contador de rendimiento de Windows](https://learn.microsoft.com/en-us/windows/win32/api/profileapi/nf-profileapi-queryperformancecounter)

| Carga | Motor | Tokens | Apertura ms | Lectura ms | UTF-8 ms | Lexer ms | Emisión ms | Total ms | Pico KiB |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 KiB | Cranelift | 33 | 0,056 | 0,065 | 0,001 | 3,373 | 0,353 | 43,622 | 4 820 |
| 1 KiB | Stage 0 | 33 | 0,060 | 0,089 | 0,003 | 0,125 | 0,144 | 40,375 | — |
| 45 KiB | Cranelift | 1 441 | 0,079 | 0,151 | 0,009 | 3,209 | 66,683 | 103,540 | 4 676 |
| 45 KiB | Stage 0 | 1 441 | 0,066 | 0,135 | 0,007 | 2,864 | 60,282 | 99,627 | 3 436 |
| 1 MiB | Cranelift | 2 049 | 0,064 | 0,852 | 0,181 | 3,267 | 86,519 | 123,384 | 6 592 |
| 1 MiB | Stage 0 | 2 049 | 0,059 | 1,385 | 0,095 | 51,304 | 79,863 | 179,500 | 10 100 |
| 10 MiB | Cranelift | 2 049 | 0,055 | 9,982 | 1,573 | 20,325 | 70,996 | 142,514 | 21 984 |
| 10 MiB | Stage 0 | 2 049 | 0,052 | 10,072 | 0,939 | 537,811 | 71,389 | 664,938 | 61 316 |

La carga de 10 MiB registró 2 053 reservas, 21 redimensionamientos,
2 053 liberaciones, una lectura corta y un handle abierto y cerrado.
La carga de fase 1 de 45 000 bytes tenía 10 001 tokens y medía el
scanner en memoria. Estas cargas usan archivos con menor densidad
de tokens para mantener la comparación con el límite de Stage 0.
