# ELE Compiler Performance & Benchmark Report

This document reports verifiable, reproducible performance benchmarks for the **ELE Programming Language**, covering compilation latency, compiler memory overhead (peak RSS), runtime throughput of compiled binaries, and fair external comparisons against Rust and GCC.

---

## 0. Measurements 2026-11-27 (Stage 1)

These are fresh measurements of the current compiler, taken on **commit `ec410984c8311f0e79e1a876932cff785f88ad13`**
(`origin/main`, PR #210). They replace the figures of sections 1-5, which are kept below as historical data of commit `56f34fb`.
Stage 1 means the compiler written in ELE and built without Rust (`gen2.exe`); Stage 0 is the Rust compiler `l`
(`l build --backend cranelift`). Definitions and the exact commands: [self-hosting.md](self-hosting.md#0-terminology-stage-0-and-stage-1).
Raw data, scripts and method: [benchmarks/campaign_20261127_stage1/](benchmarks/campaign_20261127_stage1/README.md).

### Units

| Symbol | Meaning |
|---|---|
| B | byte |
| KB, MB | 1,000 B and 1,000,000 B (decimal) |
| KiB, MiB | 1,024 B and 1,048,576 B (binary) |

Executable sizes are given in B and KiB, memory in MiB, times in ms or s. Every time is the **median** of 5 timed runs after 1 warm-up run;
the range in parentheses is (min-max) of the same 5 runs.

### Hardware and method

| Item | Value |
|---|---|
| CPU / RAM | Intel Core i5-7300U @ 2.60 GHz (2 cores, 4 threads); about 8 GiB |
| OS | Windows 10 IoT Enterprise LTSC 2021 (10.0.19044) |
| Load | Interactive desktop session, no other build or benchmark running; not an isolated machine |
| Stage 1 | `gen2.exe`, SHA-256 `cfcfa798f9b5680721184de780bbeed8566947962828e4cc49471407f063d218` |
| Stage 0 | `l.exe` from `cargo build --release`, `rustc 1.99.1` MSVC toolchain |
| Time | wall clock, `Process.Start` to exit; compiles include process start and writing the executable; runs include process start |
| Memory | `PeakWorkingSet64` of the measured process, read after it exited (exact peak, not sampled); child processes are not included |

Process start costs about 24 ms on this PC: the `hello` executable "runs" in 24.4 ms. Run times of a few tens of ms are that floor, not computation.

### Compilation: Stage 1 vs Stage 0

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

Stage 1 compiles these programs in 35-65 ms (2.1 to 4.4 times faster than Stage 0, whose fixed cost is about 125-140 ms; `hello.l`: 4.0 times) and
needs 18.6-18.7 MiB of peak memory (Stage 0: 7.8-8.3 MiB). Its executables are 4,608-9,216 B (4.5-9.0 KiB), 50-80 % of the size of the Stage 0
ones (9,216-11,776 B).

### The compiler compiling itself

`compiler-l/src/main_driver.l` (743 lines, 28,535 B), compiled by each compiler (5 timed runs):

| Compiler | Time: median (min-max) | Peak memory | Output |
|---|---|---|---|
| Stage 1 (`gen2.exe`) | **16.04 s** (15.54-17.51 s) | **565.63 MiB** | 2,438,656 B (2,381.5 KiB), byte-identical to Gen2 |
| Stage 0 (`l.exe`, Cranelift) | **2.72 s** (2.48-3.75 s) | **75.89 MiB** | 1,437,696 B (1,404.0 KiB) |

During the bootstrap (one run each) Stage 1 took 13.3 s per generation (Gen2, Gen3). The Stage 1 self-compile is therefore about 6 times
slower and uses about 7.5 times more memory than Stage 0; the 565.63 MiB peak is the highest memory figure of the whole campaign and
the largest point of improvement. The Stage 0 output is a different (smaller) program: it is not the fixpoint binary.

### Run time of the compiled programs

Programs from `bench/programs/` and `benchmarks/sources/comparisons/` that Stage 1 can compile (async, spawn and region programs
are not supported by Stage 1 and were not measured). Output was identical between both compilers in all cases.

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

Reading the table:

- Function calls (`fib.l`, `fibonacci_recursive.l`) are within 6-8 % of Stage 0, which is about the noise of this setup.
- Tight loops with arithmetic (`collatz.l`, `sum_loop.l`) are 4.7-5.2 times slower with Stage 1: the Stage 1 backend emits machine code directly from CFG blocks
  without optimization passes (as the README states), while Cranelift optimizes; this is the likely cause, not confirmed by profiling. These are the largest slowdowns for numeric code.
- List workloads are 1.0-1.9 times slower; `list_push_1m.l` is equal.
- `text_build.l` is 14 times slower and `list_text_100k.l` 7.3 times slower; the latter also peaks at **395.16 MiB** against 9.34 MiB in
  Stage 0 for the same program (100,000 `Text` values), so Stage 1 text handling holds on to far more memory.
  The cause was not investigated here.
- Peak memory of the other programs is close in both compilers (2.2 MiB for programs that allocate nothing, 10-11 MiB for 1,000,000 `Int` in a list, within about 1 MiB of each other).

### External reference: Rust

`rustc 1.99.1 -C opt-level=3` on the same sources (`fibonacci_recursive.rs`, `arithmetic_loop.rs`): compile 249.0 ms and 256.8 ms (median),
executables of 131,072 B (128.0 KiB), run 29.8 ms and 30.1 ms. Both runs are at the process-start floor, so they only show that Rust
at `opt-level=3` is not slower than that floor (the loop may have been folded by LLVM; the generated code was not inspected).
ELE Stage 1 ran the same algorithms in 34.8 ms (fib 25) and 73.5 ms (10 M iterations). **C was not measured** (no C compiler on this host).
Compare compile times with care: `rustc` includes linking and its memory excludes the linker process.

### Comparison with the historical figures

| Metric | Historical (`56f34fb`, sections 1-5) | Now (`ec41098`, Stage 1) |
|---|---|---|
| `hello.l` compile time | 32.05 ms | 34.8 ms (34.2-39.7) |
| `hello.l` executable | 4,608 B | 4,608 B |
| Compiler peak memory, `hello.l` | 1.18 MiB | 18.61 MiB |
| `main_driver.l` compile time | 5.23 s (692 lines, 25,720 B) | 16.04 s (743 lines, 28,535 B) |
| `main_driver.l` peak memory | 87.53 MiB | 565.63 MiB |
| `main_driver.l` executable | 1,514,496 B | 2,438,656 B |

The historical memory figures were measured with a Windows Job Object and a different compiler build; the memory difference
(18.6 MiB vs 1.18 MiB for a hello world) is too large to be explained by the method alone and was not investigated. The self-compile got about 3 times slower
while its source grew about 11 %; the compiler also gained features (kernel target, intrinsics) since `56f34fb`.

### Commands to reproduce

```powershell
python tools/verify_seed_archive.py pe --output .\seed\ele-seed-pe.exe
.\scripts\bootstrap\ele_seed_bootstrap.ps1 -Seed .\seed\ele-seed-pe.exe -SeedSha256 eb98a908ca5a36b5a4f29c9114a8232a6031f7d35c2c4298569adf67ebccc2f5 -Target pe -OutDir .\out\boot
.\benchmarks\scripts\stage1_campaign.ps1 -Compiler .\out\boot\gen2.exe -Kind stage1 -Sources bench\programs\fib.l -OutDir .\out\data -Tag stage1 -Runs 5 -RunPrograms
```

---

## Historical figures (commit `56f34fb`, before 2026-11-27)

> Sections 1-5 below are **historical**: they were measured on commit `56f34fb437e20ca2b6b5613106f96ec153f36969` and were not repeated
> when section 0 was written. The Linux comparison with GCC was not re-run. Where they disagree with section 0, section 0 is current.

## 1. Executive Summary

The Windows results below were measured on **commit `56f34fb437e20ca2b6b5613106f96ec153f36969`**, prior to the Stage 3.5 merges. They are not post-merge benchmarks of the current `main`. The individual observations and provenance are preserved in `benchmarks/results/compilation_benchmarks_windows.json`, `runtime_benchmarks_windows.json` and `external_comparison_windows.json`.

| Metric | Small/medium workload (Windows dataset) | Large compiler source (Windows dataset) |
|---|---|---|
| **Compilation latency** | **32.05–35.75 ms** | 3.16 s (`main_sema.l`) / 5.23 s (`main_driver.l`) |
| **Compiler peak memory** | **1.18–1.22 MiB** (recorded) | 52.46 MiB (`main_sema.l`) / 87.53 MiB (`main_driver.l`) |
| **Compiled binary size** | **4,608–5,120 B** (PE32+) | 913,408 B (`main_sema.l`) / 1,514,496 B (`main_driver.l`) |
| **Runtime dependencies** | **No CRT** for the tested ELE executables | **No CRT** in the tested autonomous driver |

Reproduce these workloads on the integrated HEAD before claiming that the measurements represent its performance.

---

## 2. Compilation Performance

The compilation dataset uses 10 timed iterations for small programs and 5 for `main_sema.l` and `main_driver.l`, each after one warmup, on the documented Windows x86-64 host. Charts are generated from the versioned datasets; no new measurements were produced by this documentation edit.

![Compilation Time](../assets/benchmarks/compilation-time.svg)

### Compilation Benchmark Results Table

| Workload | Source Lines | Source Size | Median Compile Time | Peak RSS (Job Object) | Binary Size | Exit Status |
|---|---|---|---|---|---|---|
| `hello.l` | 5 | 99 B | **32.05 ms** | 1.18 MiB | 4,608 B | PASSED |
| `arithmetic.l` | 10 | 225 B | **32.90 ms** | 1.21 MiB | 5,120 B | PASSED |
| `fibonacci.l` | 13 | 310 B | **35.75 ms** | 1.21 MiB | 5,120 B | PASSED |
| `text_processing.l` | 10 | 245 B | **35.24 ms** | 1.20 MiB | 5,120 B | PASSED |
| `multimodule (main.l)` | 10 | 241 B | **33.36 ms** | 1.22 MiB | 5,120 B | PASSED |
| `main_sema.l` (Compiler) | 278 | 10,779 B | **3.16 s** | 52.46 MiB | 913,408 B | PASSED |
| `main_driver.l` (Self-Host) | 692 | 25,720 B | **5.23 s** | 87.53 MiB | 1,514,496 B | PASSED |

---

## 3. Compiler Memory Usage (Peak RSS)

Peak Resident Set Size (RSS) is measured continuously across the entire execution of the compiler process using the Windows Job Object API (`JOBOBJECT_EXTENDED_LIMIT_INFORMATION.PeakProcessMemoryUsed`).

![Peak Memory Usage](../assets/benchmarks/peak-memory.svg)

- **Small programs (`hello`, `arithmetic`, `text`, `fibonacci`):** The recorded peak range is **1.18–1.21 MiB**.
- **Multi-module compilation:** The dataset records **1.22 MiB** peak.
- **Compiler source (`main_sema.l`):** **52.46 MiB** peak.
- **Full compiler driver (`main_driver.l`):** **87.53 MiB** peak for the sampled revision. These are dataset values, not independent measurements of the current `main`.

---

## 4. Analysis of Stage 3.3 Driver Optimization (Radix-32 LIR Assembly)

In Stage 3.3, an optimization was deployed to address severe performance degradation during large file compilation:

### Problem Identified
The compiler driver assembled the emitted LIR lines using naive string concatenation in a loop:
```ele
each line among lines {
    lir = lir + line + "\n"
}
```
Because ELE strings are immutable, owned UTF-8 buffers on the heap, concatenating $N \approx 72,000$ lines produced $O(N^2)$ reallocations and copies, allocating over 50 GB cumulatively.

### Solution & Measured Speedup
Implemented a hierarchical radix-32 chunked accumulator (`assembleLir`), reducing complexity to $O(N \log_{32} N) \approx O(N)$:
- **Before Optimization:** 133,925 ms (133.9 s)
- **After Optimization:** 10,012 ms (10.0 s)
- **Measured Factor:** **13.3x speedup (92.5% reduction in compilation latency)**.

> [!NOTE]
> This 13.3x speedup applies specifically to the LIR buffer materialization phase in massive monolithic sources. It is not an assertion that the entire compiler is 13.3x faster for all workloads.

---

## 5. Runtime Performance & External Comparisons

### Methodology & Workloads
To ensure fairness:
1. **Recursive Fibonacci (n=25):** Tests function call overhead, stack frame construction, and integer arithmetic.
2. **Arithmetic Loop (10,000,000 iterations):** Tests loop condition branching and 64-bit integer addition.
3. **Equivalence:** All programs verify identical standard output (`75025` and `149999995000000`).

![Runtime Performance](../assets/benchmarks/runtime-performance.svg)

### Windows x86-64 Comparison: ELE vs Rust (`rustc 1.99.1`)

| Benchmark | Language | Mode / Flags | Compile Time (ms) | Runtime (ms) | Binary Size |
|---|---|---|---|---|---|
| **Fibonacci(25)** | **ELE** | `native-direct-emit` | 32.79 | 53.49 | 5,120 B |
| Fibonacci(25) | Rust | Debug (`-O0`) | 670.88 | 22.63 | 5,086,801 B |
| Fibonacci(25) | Rust | Release (`-O3`) | 716.37 | 24.92 | 5,085,050 B |
| **Loop(10M)** | **ELE** | `native-direct-emit` | 38.12 | 101.34 | 5,120 B |
| Loop(10M) | Rust | Debug (`-O0`) | 649.07 | 94.34 | 5,086,761 B |
| Loop(10M) | Rust | Release (`-O3`) | 690.35 | 21.47 | 5,084,972 B |

### Linux x86-64 Comparison: ELE vs GCC (`gcc 9.4.0` in WSL2 Ubuntu)

| Benchmark | Language | Mode / Flags | Compile Time (ms) | Runtime (ms) | Binary Size |
|---|---|---|---|---|---|
| **Fibonacci(25)** | **ELE** | `native-direct-emit` | **913.0 ms** | **34.05 ms** | **5,957 B** |
| Fibonacci(25) | C | Debug (`-O0`) | 1,118.5 ms | 47.17 ms | 16,744 B |
| Fibonacci(25) | C | Release (`-O2`) | 1,118.9 ms | 19.03 ms | 16,744 B |
| **Loop(10M)** | **ELE** | `native-direct-emit` | **393.0 ms** | **230.32 ms** | **5,978 B** |
| Loop(10M) | C | Debug (`-O0`) | 909.7 ms | 102.78 ms | 16,744 B |
| Loop(10M) | C | Release (`-O2`) | 1,166.9 ms | 33.75 ms | 16,744 B |

### Binary Size Comparison

![Binary Footprint](../assets/benchmarks/binary-size.svg)

- **ELE:** Produces minimal, zero-runtime images (~5.1 KiB on Windows PE32+, ~5.9 KiB on Linux ELF64).
- **C (GCC):** Produces dynamically linked binaries (~16.7 KiB) relying on external `glibc`.
- **Rust (`rustc`):** Statically bundles the Rust standard library and runtime panicking infrastructure (~5.08 MiB).
