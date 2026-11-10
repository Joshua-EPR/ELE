# Fase 8.3: listas y primera autocobertura nativa parcial

Fecha: 10-11-2026. Rama: `dev/ele-self-hosting-bootstrap`. HEAD inicial: `6bbc374f5fc051606e81b6813a79634d60fbe81d`. Los commits previos `fd93da1` y `6bbc374` se conservaron. La línea base, con `RUSTC` y `RUSTDOC` MSVC explícitos, fue 393 pruebas aprobadas, 0 fallos, 3 ignoradas y 0 doctests.

Validación final: **398 aprobadas, 0 fallos, 3 ignoradas y 0 doctests** en 32 grupos, `cargo test --target x86_64-pc-windows-msvc` con salida 0. `cargo fmt --all --check` y `cargo clippy --target x86_64-pc-windows-msvc --all-targets -- -D warnings` pasan. Registro: `target/phase83-final-test.log` (artefacto local no versionado).

## List<T> de extremo a extremo

| Operación | Stage 1 semántica y ownership | LIR y verificador | Backend provisional |
| --- | --- | --- | --- |
| `List[]` con anotación `List<T>` | Sí | `listlit` | Sí |
| `List[a, b]` con inferencia homogénea | Sí | `listlit` | Sí |
| `push`, `reserve` sobre variable mutable | Sí, evento `FLOW_MUTATE` | `listpush`, `listreserve` | Sí |
| `.length`, `.capacity` | Sí | `len`, `cap` | Sí |
| `xs[i]` y escritura de elemento copiable | Sí | lugar indexado, `read`, `store` | Sí |
| `for x in xs` con elemento copiable | Sí | CFG, índice y `len` | Sí |
| paso y retorno de listas, campo de struct | Sí | tipos `lN`, `call`, `struct`, drops | Sí |
| `pop`, mover elemento propietario, reemplazar elemento propietario | Parcial o rechazado | Sin ruta vertical comprobada | No se declara completo |

`List<T>` se identifica por el tipo de elemento resuelto; `List<Int>`, `List<Bool>`, `List<Text>` y `List<FlowBlock>` son distintos. La equivalencia de structs conserva su identidad nominal. El literal vacío obtiene `T` de una anotación directa. Sin ella, no se inventa un tipo de elemento. La sintaxis del tipo es `List<T>`; la del literal es `List[]` o `List[valor, ...]`.

El ABI nativo existente de Stage 0 es una cabecera de 24 bytes `(data*, length, capacity)` con desplazamientos 0, 8 y 16. El backend provisional reutiliza el layout, las comprobaciones de índice y overflow, crecimiento y drop glue de Cranelift/runtime. La LIR de Stage 1 entrega los tipos parametrizados y las operaciones; Stage 0 solo construye Stage 1 y sirve de referencia diferencial. El protocolo sigue en `ELE-LIR 1` como extensión provisional: `list lN <tipo>`, `i listlit`, `i listpush`, `i listreserve`, `i len`, `i cap` y lugares indexados. El parser Rust rechaza versiones desconocidas, líneas malformadas y operaciones desconocidas; la validación de LIR y drops precede al codegen.

`FLOW_MUTATE` exige propietario vivo y acceso exclusivo para modificar la colección in situ sin ejecutar el drop de reemplazo de la lista completa. Los préstamos compartidos activos impiden crecimiento incompatible. El drop de listas y elementos propietarios usa el plan de Stage 1 y el glue del backend. Los ensayos instrumentados exigen `allocs == frees` y `heap_ok=1`; eso verifica esos recorridos, no seguridad universal de memoria. No se ejecutaron sanitizers.

## Funciones propias ejecutadas

`compiler-l/src/flow_self_harness.l` importa `flow_cfg.l` y llama a las implementaciones originales `flowNew` y `flowBlock`. `flowNew` crea diez listas tipadas, incluida `List<FlowBlock>`, y `flowBlock` inserta un bloque y devuelve el índice previo. El harness observa longitud inicial 1, índice devuelto 1 y longitud final 2. Stage 1 analizó semántica, ownership, CFG, préstamos y drops; emitió LIR con **116 bloques, 219 instrucciones, 30 drops, 0 flags**. El parser y verificador de protocolo aceptaron la LIR; `l build-lir` produjo un ejecutable Cranelift. El ejecutable devolvió **2**, igual que Stage 0 compilando el mismo harness y la misma fuente original. La prueba `compiles_real_flow_cfg_functions_natively` automatiza esta ruta con `--trace-alloc` y comprueba trazas equilibradas.

El cargador de imports concatena fuentes y no implementa identidad de módulo, visibilidad ni spans por archivo. Por eso este resultado es **autocobertura nativa parcial**, no Stage 2 ni self-hosting completo. El backend y el bootstrap aún dependen de Rust/Cranelift. La siguiente prioridad es resolver imports con identidad y visibilidad, y después `Option`/`Result`, `pop`, enums y `match` donde los módulos propios los requieran.

## Validación

`crates/l/tests/lir_l.rs` compara ocho programas de listas (Int, Bool, Text, vacía, literal, push, reserve/capacity, índice, escritura copiable, iteración, retorno y struct) con Stage 0; verifica salidas, código de retorno y trazas de heap. También cubre siete diagnósticos negativos (incluido crecimiento durante préstamo), índice fuera de rango en ejecución y cuatro corrupciones del protocolo. El caso de `flow_cfg.l` usa el archivo original, no una copia del algoritmo.

Comando MSVC:

```powershell
$tool = 'C:\Users\Usuario\.rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
$env:PATH = "$tool;$env:PATH"
$env:RUSTC = "$tool\rustc.exe"
$env:RUSTDOC = "$tool\rustdoc.exe"
& "$tool\cargo.exe" test --target x86_64-pc-windows-msvc
```

Benchmarks: `bench/stage1-loans.ps1`, `bench/stage1-drops.ps1`, `bench/stage1-lir.ps1` y el nuevo `bench/stage1-lists.ps1`, todos con `-Runs 1 -Compiler target/x86_64-pc-windows-msvc/debug/l.exe`. Cada punto tiene una medida tras calentamiento; la variación del reloj supera algunos deltas de fase y no permite atribuirlos al cambio.

| Carga grande | Base fase 8.2 | Fase 8.3 | Pico 8.3 | Reservas / liberaciones 8.3 |
| --- | ---: | ---: | ---: | ---: |
| Loans, 10 001 préstamos | 980,02 ms | 1 029,38 ms | 15 808 KiB | 31 107 / 31 107 |
| Drops, 10 000 variables | 1 649,40 ms | 2 126,24 ms | 36 616 KiB | 102 684 / 102 684 |
| LIR, 10 000 instrucciones objetivo | 5 571,04 ms | 7 923,07 ms | 19 180 KiB | 326 318 / 326 318 |

El benchmark nuevo de 1 000 `push` midió 14,60 ms para `--check-ownership`, 22,97 ms para `--emit-lir` (delta 8,37 ms), 2 016,86 ms de backend y 5,44 ms de ejecución. Pico: 5 720 KiB en emisión y 24 060 KiB en backend. La LIR ocupa 27 284 bytes y el ejecutable 96 256 bytes. Stage 1 registró 8 258 reservas y 8 258 liberaciones, con 2 235 redimensionamientos; el ejecutable registró 1 reserva y 1 liberación. Son tiempos de compilación y ejecución separados, no una comparación con Rust optimizado. El análisis CFG aún puede crecer proporcionalmente a bloques × rutas.
