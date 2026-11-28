# Compilar con Stage 1 y comparación con el compilador de referencia en Rust

Esta guía reúne las comparaciones con el compilador escrito en Rust, para que las guías principales ([inicio](getting-started.md),
[self-hosting](self-hosting.md) y los README) describan solo el camino sin Rust. Versión en inglés: [building-with-stage1.md](building-with-stage1.md).
Verificado el 2026-11-27 sobre el commit `ec410984c8311f0e79e1a876932cff785f88ad13` (Windows 10 IoT Enterprise LTSC 2021, Intel Core i5-7300U, unos 8 GiB de RAM).

## Definiciones

- **Stage 0** es el compilador escrito en Rust (`crates/l`, binario `l`; `cargo build -p project-l --bin l`). Necesita la cadena de herramientas de Rust.
- **Stage 1** es el compilador escrito en ELE (`compiler-l/src/main_driver.l`, 743 líneas, 28.535 B), construido **sin Rust** desde la semilla fijada:
  `semilla -> Gen1' -> Gen2 -> Gen3`, con `Gen2 == Gen3` bit a bit (el punto fijo). `Gen2`/`Gen3` es lo que los instaladores publican como `ele.exe` / `ele.elf`.

Otros documentos numeran las etapas de otra forma. No son erróneos, pero describen otra cosa:

| Documento | Qué significa "Stage N" allí |
|---|---|
| [BOOTSTRAP_ARCHITECTURE.md](BOOTSTRAP_ARCHITECTURE.md) (líneas 50-66) | Plan: Stage 1 = Stage 0 compila un driver en L; Stage 2 = ese ejecutable reconstruye el compilador; Stage 3 = segunda reconstrucción |
| [STAGE0_FREE_BOOTSTRAP.md](STAGE0_FREE_BOOTSTRAP.md) | La cadena basada en semilla (semilla, Gen1', Gen2, Gen3), sin Stage 0 |
| [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) (línea 13 y las entradas de la fase 8.x hacia la línea 1474) | Registros históricos de fases: "no hay Stage 2 ni Stage 3" era cierto al escribirse y lo supera el punto fijo |
| "Stage 3.x" en [self-hosting.md](self-hosting.md) | Nombres de hitos de ingeniería del trabajo del punto fijo, no generaciones del compilador |

## Camino Stage 1 frente al camino con Rust

| | Stage 1 (sin Rust) | Stage 0 (Rust) |
|---|---|---|
| Construcción | `ele_seed_bootstrap.ps1` desde la semilla, unos 32 s | `cargo build --release -p project-l --bin l` |
| Requiere | PowerShell y Python (extraer la semilla) | Cadena de Rust `1.99.1` |
| Backend | Emisor nativo de ELE, PE32+ / ELF64 / kernel | Cranelift (`l build --backend cranelift`) |
| Fuente aceptado | `async`, `spawn` y regiones aún no se aceptan | más amplio (compilan todos los archivos de `bench/programs`) |

El camino con Rust está en [getting-started.md](getting-started.md) (Opción C). Sus pruebas del punto fijo:

```powershell
$env:ELE_TEST_WSL_DISTRO = "Ubuntu"   # ejecución Linux desde un host Windows
cargo test -p project-l --test ele_build_driver_l driver_builds_self_rebuild_windows_fixpoint
cargo test -p project-l --test ele_build_driver_l driver_builds_self_rebuild_linux_fixpoint
```

## Sobre los puntos fijos

- **Actual (Windows PE32+, commit `ec41098`, desde la semilla, sin Rust):** `cfcfa798f9b5680721184de780bbeed8566947962828e4cc49471407f063d218`, 2.438.656 B.
- **Históricos, con Gen 1 construido por Stage 0** (fuente anterior, cadena Stage 3.2/3.3): Windows `F0CE6F57427B5A60D51095975A85A56D5FD43F18DC4FA2F732DA0D02E0B5370D`
  (1.508.352 B) y Linux `4C952A75B28AEB5BE6770372BA426137A32E0C7B0C5A31E798B235E97CE4E9E9` (1.511.424 B). La cadena Linux no se repitió el 2026-11-27.
- `kernel/compilador/provenance.json` registra el mismo valor `cfcfa798...`, pero indica `commit 758270d..., tracked_files_dirty: true`. Un checkout **limpio** de `758270d`
  da otro punto fijo, `76ba727530350611dff52ba3fbea502ce1580752a0cfdd8e7a55d81e474b44bc` (2.436.096 B, misma semilla, ejecutado el 2026-11-27; provenance en
  [`provenance_758270d_clean.json`](benchmarks/campaign_20261127_stage1/bootstrap/provenance_758270d_clean.json)). El build del kernel salió de un árbol de trabajo que ya tenía los cambios
  del compilador que se commitearon después (`native_cfg_platform.l`, `x86_64.l`, `lir_build.l`, `sema_expr.l`, `sema_ops.l`, 31 líneas entre `758270d` y `ec41098`), y coincide byte a byte con `ec41098`.
- El script de bootstrap nunca ejecuta `cargo`, `rustc` ni `rustup`; con `-ForbidToolchainOnPath` falla si están en el `PATH`.

## Rendimiento: Stage 1 frente a Stage 0

Mediana de 5 ejecuciones medidas tras 1 de calentamiento (mín–máx entre paréntesis). Unidades: B = byte, KiB = 1.024 B, MiB = 2^20 B. Arrancar un proceso cuesta unos 24 ms en este PC: es el suelo de todo tiempo de ejecución.
Método completo, CSV brutos y los programas que Stage 1 no compila: [performance.md](performance.md#0-measurements-2026-11-27-stage-1) y
[campaign_20261127_stage1](benchmarks/campaign_20261127_stage1/README.md) (en inglés).

### Compilación

| Programa | Fuente (B) | Compilación Stage 1 (ms): mediana (mín–máx) | Pico Stage 1 (MiB) | Ejecutable Stage 1 (B / KiB) | Compilación Stage 0 (ms): mediana (mín–máx) | Pico Stage 0 (MiB) | Ejecutable Stage 0 (B / KiB) |
|---|---|---:|---:|---:|---:|---:|---:|
| `hello.l` | 87 | **34.8** (34.2–39.7) | 18.61 | 4,608 / 4.5 | **138.4** (130.8–301.5) | 7.79 | 9,216 / 9.0 |
| `fibonacci.l` | 219 | **38.6** (37.7–40.0) | 18.65 | 5,632 / 5.5 | **125.2** (124.4–140.0) | 7.98 | 9,728 / 9.5 |
| `loops.l` | 196 | **39.3** (36.8–45.7) | 18.61 | 5,632 / 5.5 | **135.2** (127.2–140.8) | 7.95 | 9,216 / 9.0 |
| `structs.l` | 1,414 | **65.0** (63.8–68.4) | 18.70 | 9,216 / 9.0 | **137.2** (133.6–201.0) | 8.26 | 11,776 / 11.5 |
| `text.l` | 296 | **36.3** (36.0–54.5) | 18.64 | 5,120 / 5.0 | **165.0** (152.7–172.8) | 8.02 | 9,216 / 9.0 |
| `native_text_stage1.l` | 728 | **43.9** (38.9–344.9) | 18.66 | 7,168 / 7.0 | **163.2** (148.7–239.8) | 7.99 | 10,752 / 10.5 |
| `arithmetic.l` | 225 | **36.2** (35.5–37.5) | 18.64 | 5,632 / 5.5 | **155.8** (146.4–159.7) | 7.95 | 9,216 / 9.0 |
| `text_processing.l` | 245 | **37.2** (36.2–38.6) | 18.64 | 5,120 / 5.0 | **150.4** (139.8–216.0) | 7.95 | 9,728 / 9.5 |
| `fib.l` | 197 | **35.9** (35.2–40.5) | 18.64 | 5,632 / 5.5 | **157.5** (154.3–191.2) | 7.94 | 9,728 / 9.5 |
| `list_search_1m.l` | 672 | **44.4** (42.1–48.7) | 18.66 | 6,656 / 6.5 | **156.2** (150.4–162.2) | 8.07 | 10,240 / 10.0 |

### El compilador compilándose a sí mismo (`main_driver.l`)

| Compilador | Tiempo: mediana (mín–máx) | Memoria pico | Salida |
|---|---|---|---|
| Stage 1 (`gen2.exe`) | 16,04 s (15,54–17,51 s) | 565,63 MiB | 2.438.656 B (2.381,5 KiB), idéntica a Gen2 |
| Stage 0 (`l.exe`, Cranelift) | 2,72 s (2,48–3,75 s) | 75,89 MiB | 1.437.696 B (1.404,0 KiB) |

### Tiempo de ejecución de los programas compilados

| Programa | Ejecución Stage 1 (ms): mediana (mín–máx) | Ejecución Stage 0 (ms): mediana (mín–máx) | Stage 1 / Stage 0 | Pico Stage 1 (MiB) | Pico Stage 0 (MiB) |
|---|---:|---:|---:|---:|---:|
| `fib.l` | **56.0** (55.2–59.0) | **52.7** (50.0–64.6) | 1.06x | 2.20 | 2.19 |
| `fibonacci_recursive.l` | **34.8** (30.6–67.4) | **32.1** (29.6–33.9) | 1.08x | 2.20 | 2.19 |
| `arithmetic_loop.l` | **73.5** (72.5–78.1) | **46.2** (44.9–47.2) | 1.59x | 2.20 | 2.19 |
| `collatz.l` | **2,801.2** (2,784.3–2,841.5) | **540.8** (508.3–580.0) | 5.18x | 2.20 | 2.19 |
| `sum_loop.l` | **4,313.2** (4,168.8–4,356.9) | **912.9** (907.3–1,059.0) | 4.72x | 2.20 | 2.19 |
| `list_index_1m.l` | **119.9** (119.2–121.1) | **86.4** (85.2–92.7) | 1.39x | 9.84 | 9.82 |
| `list_iter_1m.l` | **124.2** (119.5–145.0) | **87.2** (84.2–87.8) | 1.42x | 9.84 | 9.82 |
| `list_search_1m.l` | **172.5** (139.7–186.2) | **92.8** (90.4–94.0) | 1.86x | 10.19 | 11.23 |
| `list_release_100k.l` | **99.5** (93.0–116.4) | **61.8** (60.8–69.5) | 1.61x | 3.19 | 4.00 |
| `list_push_1m.l` | **37.8** (36.9–38.8) | **37.8** (36.8–38.1) | 1.00x | 10.19 | 11.22 |
| `list_text_100k.l` | **424.1** (416.6–445.3) | **58.3** (54.0–109.8) | 7.27x | 395.16 | 9.34 |
| `text_build.l` | **4,362.0** (4,287.1–5,267.8) | **306.5** (268.8–342.3) | 14.23x | 2.22 | 2.20 |

"Stage 1 / Stage 0" es el cociente de medianas (por encima de 1, el ejecutable de Stage 1 es más lento). La salida fue idéntica entre ambos compiladores en los 20 programas.

En resumen: Stage 1 compila los programas pequeños entre 2,1 y 4,4 veces más rápido y emite ejecutables más pequeños; el código que genera está a un 6–8 % en código con muchas llamadas,
4,7 a 5,2 veces más lento en bucles aritméticos cerrados y 14 veces más lento construyendo texto; compilar el compilador tarda unas 6 veces más y usa 7,5 veces más memoria.
