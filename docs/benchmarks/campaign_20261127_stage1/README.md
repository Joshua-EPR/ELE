# Campaign 2026-11-27: Stage 1 vs Stage 0 on Windows

Measurements of the ELE compiler built **without Rust** (Stage 1, see
[Stage definitions](../../building-with-stage1.md#definitions)) and of the Rust compiler
(Stage 0, `l build --backend cranelift`) on the same sources, plus `rustc` as an external reference.

## Environment

| Item | Value |
|---|---|
| Date | 2026-11-27 |
| Commit | `ec410984c8311f0e79e1a876932cff785f88ad13` (`origin/main`, PR #210), clean tree for tracked files |
| CPU | Intel Core i5-7300U @ 2.60 GHz (2 cores, 4 threads, Kaby Lake) |
| RAM | about 8 GiB (`systeminfo`: 8,050 MB, reported in MiB) |
| OS | Windows 10 IoT Enterprise LTSC 2021, build 10.0.19044 |
| Load | Interactive desktop session; no other build or benchmark was running; antivirus not changed. Not isolated: treat differences below about 5 % as noise. |
| Stage 1 | `gen2.exe` from `scripts/bootstrap/ele_seed_bootstrap.ps1` (SHA-256 `cfcfa798f9b5680721184de780bbeed8566947962828e4cc49471407f063d218`) |
| Stage 0 | `cargo build --release -p project-l --bin l` with `rustc 1.99.1 (58cf8f9c3 2026-10-13)`, toolchain `stable-x86_64-pc-windows-msvc`, separate `CARGO_TARGET_DIR` |
| External reference | `rustc 1.99.1 -C opt-level=3` (C was not measured: no `gcc` on this host) |

## Units

B = byte. KB = 1,000 B, MB = 10^6 B. KiB = 1,024 B, MiB = 2^20 B (1,048,576 B).
Executable sizes are in B and KiB, memory in MiB, times in ms or s.

## Method

- Script: [`benchmarks/scripts/stage1_campaign.ps1`](../../../benchmarks/scripts/stage1_campaign.ps1) (new; no existing script was modified).
- For every source: **1 untimed warm-up compile + 5 timed compiles**; the compiled executable is then run **1 warm-up + 5 timed runs**. Reported value: **median**, with min and max of the 5 timed runs. The warm-up row is kept in the raw CSV (`phase = compile_warmup` / `run_warmup`).
- Time: wall clock (`Stopwatch`) from `Process.Start` to `WaitForExit`, stdout and stderr captured asynchronously. For compiles it includes process start and file output; Stage 0 includes its in-process linking.
- Memory: `PeakWorkingSet64` read with `GetProcessMemoryInfo` on the process handle **after** the process exited (exact peak, not sampled). It covers only the measured process, not child processes. For Stage 0 with the Cranelift backend and for Stage 1 there are no child processes; for `rustc` the linker is a child and is **not** included.
- Run time includes process start. The smallest programs (`hello`) take about 24 ms on this PC, which is the floor of this method, not computation time.
- Every program's stdout is hashed per run (`out_sha256`); outputs were identical across the 5 runs and **identical between Stage 1 and Stage 0** for all 20 programs.
- Source sets: `examples/`, `benchmarks/sources/`, `benchmarks/sources/comparisons/`, `bench/programs/` (those that Stage 1 can compile) and `compiler-l/src/main_driver.l`.

## Files

| File | Content |
|---|---|
| `summary_stage1.csv`, `summary_stage0.csv`, `summary_rustc_O3.csv` | One row per program: compile and run median/min/max, peak memory, executable size and SHA-256 |
| `summary_stage1_selfcompile.csv`, `summary_stage0_selfcompile.csv` | `main_driver.l` compiled by Stage 1 (`gen2.exe`) and by Stage 0 |
| `raw_*.csv` | Every individual run (warm-ups included) |
| `bootstrap/provenance.json`, `bootstrap/SHA256SUMS` | Seed -> Gen1' -> Gen2 -> Gen3 run of this campaign |
| `bootstrap/provenance_758270d_clean.json` | The same bootstrap on a clean checkout of `758270d` (see the SHA-256 note in [self-hosting](../../self-hosting.md)) |

## Reproduce

```powershell
python tools/verify_seed_archive.py pe --output .\seed\ele-seed-pe.exe
.\scripts\bootstrap\ele_seed_bootstrap.ps1 -Seed .\seed\ele-seed-pe.exe `
    -SeedSha256 eb98a908ca5a36b5a4f29c9114a8232a6031f7d35c2c4298569adf67ebccc2f5 -Target pe -OutDir .\out\boot
.\benchmarks\scripts\stage1_campaign.ps1 -Compiler .\out\boot\gen2.exe -Kind stage1 `
    -Sources examples\hello.l,bench\programs\fib.l -OutDir .\out\data -Tag stage1 -Runs 5 -RunPrograms
# Stage 0 (needs Rust): -Compiler target\release\l.exe -Kind stage0
# Reference:            -Compiler (Get-Command rustc).Source -Kind rustc -Sources file.rs
```

## Results

### Compilation (Stage 1 vs Stage 0)

| Program | Source (B) | Stage 1 compile (ms): median (min–max) | Stage 1 peak (MiB) | Stage 1 exe (B / KiB) | Stage 0 compile (ms): median (min–max) | Stage 0 peak (MiB) | Stage 0 exe (B / KiB) |
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

### Run time of the compiled programs (Stage 1 vs Stage 0)

| Program | Stage 1 run (ms): median (min–max) | Stage 0 run (ms): median (min–max) | Stage 1 / Stage 0 | Stage 1 peak (MiB) | Stage 0 peak (MiB) |
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

"Stage 1 / Stage 0" is the ratio of medians (above 1 = the Stage 1 executable is slower).

### The compiler compiling itself (`compiler-l/src/main_driver.l`, 743 lines, 28,535 B)

| Compiler | Compile time: median (min–max) | Peak memory | Output |
|---|---|---|---|
| Stage 1 (`gen2.exe`) | **16.04 s** (15.54–17.51 s) | **565.63 MiB** | 2,438,656 B (2,381.5 KiB), SHA-256 `cfcfa798f9b5680721184de780bbeed8566947962828e4cc49471407f063d218` = Gen2 (fixpoint reproduced) |
| Stage 0 (`l.exe`, Cranelift) | **2.72 s** (2.48–3.75 s) | **75.89 MiB** | 1,437,696 B (1,404.0 KiB), SHA-256 `1835a8a321297083ca586db16bf6dde95533d76a40c0ad21a3dd90f3dc556296` |

During the bootstrap (single run each) the Stage 1 generations took 3.39 s (seed -> Gen1'), 13.33 s (Gen2) and 13.00 s (Gen3).

### `rustc` reference (`-C opt-level=3`, same algorithms as `benchmarks/sources/comparisons/*.l`)

| Program | Compile (ms): median (min–max) | Executable | Run (ms): median (min–max) |
|---|---|---|---|
| `fibonacci_recursive.rs` (fib 25) | 249.0 (237.5–255.0) | 131,072 B (128.0 KiB) | 29.8 (28.3–31.0) |
| `arithmetic_loop.rs` (10 M iterations) | 256.8 (236.2–261.8) | 131,072 B (128.0 KiB) | 30.1 (28.7–31.4) |

Both Rust runs are at the 24-30 ms process-start floor of this method; at `opt-level=3` the loop is probably folded by LLVM (not inspected), so these runs say nothing about loop throughput.

## Programs that Stage 1 does not compile (not measured)

| Program | Diagnostic from `gen2.exe` |
|---|---|
| `bench/programs/async_*.l`, `spawn_*.l` | `error[L0016]: async fuera del subconjunto de Stage 1` (the `async_taskgroup.l` and `async_timers.l` variants fail earlier with `error[PARSER]`) |
| `bench/programs/region_*.l` | `error[L0016]: sentencia fuera del subconjunto` |
| `bench/programs/primes.l` | `error[L0006]: no se puede reasignar ...` (11:9) |
| `bench/programs/lexer-file-phases.l` | `error[L0001]: función no ...` (5:27) |

`bench/run.ps1` compares the Stage 0 `rustc` and `cranelift` backends only; it does not know Stage 1, so it was not used (and `bench/results.md` was not touched).

## Limits

- One machine, one session; 5 timed runs per cell. Max values show occasional outliers (for example one 884 ms compile of `text_build.l`); the median is robust to them, the max is not.
- Windows only. Linux ELF output was only checked for correctness (hello compiled with `--target elf` and run under WSL), not timed.
- Peak memory of Stage 1 measures the whole compiler process. Note the large gap between 18.6 MiB for tiny sources and 565.6 MiB for the 28.5 KB driver source.

## Verificación independiente (revisión, 2026-11-27)
- `gen2.exe` del bootstrap: sha256 empieza por `cfcfa798f9b56807`, igual que la tabla.
- `hello.l` compilado con Stage 1: 4 608 B, igual que la tabla.
- Tiempo de compilación de `hello.l` con `Measure-Command` en PowerShell, 7 ejecuciones tras 1 de
  calentamiento: mediana 17,9 ms (mín. 16,6, máx. 29,3). Es más rápido que los 34,8 ms de la campaña: el
  tiempo de procesos tan cortos depende mucho de la carga del equipo. La cifra de la tabla es conservadora.
  Medido desde Git Bash sale ~57 ms, por el coste de lanzar procesos de MSYS: no uses Git Bash para medir.
