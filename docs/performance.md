# ELE Compiler Performance & Benchmark Report

This document reports verifiable, reproducible performance benchmarks for the **ELE Programming Language**, covering compilation latency, compiler memory overhead (peak RSS), runtime throughput of compiled binaries, and fair external comparisons against Rust and GCC.

---

## 1. Executive Summary

| Metric | Measurement (Small/Medium Program) | Measurement (Large Compiler Source) |
|---|---|---|
| **Compilation Latency** | **31.4 ms – 54.7 ms** | 15.6 s (`main_sema.l`) / 31.3 s (`main_driver.l`) |
| **Compiler Memory (Peak RSS)** | **24.5 MiB – 40.6 MiB** | 525.1 MiB (`main_sema.l`) / 855.0 MiB (`main_driver.l`) |
| **Compiled Binary Footprint** | **4.6 KiB – 5.1 KiB** (PE32+) | 909 KiB (`main_sema.exe`) / 1.50 MiB (`ele_gen3.exe`) |
| **External Runtime Dependencies** | **0** (No CRT, no libc, no stdlib) | **0** |

---

## 2. Compilation Performance

All measurements reflect the median of 10 timed iterations following a 1-run untimed warmup on an Intel x86-64 host (Windows 10, AMD64).

![Compilation Time](../assets/benchmarks/compilation-time.svg)

### Compilation Benchmark Results Table

| Workload | Source Lines | Source Size | Median Compile Time | Peak RSS (Job Object) | Binary Size | Exit Status |
|---|---|---|---|---|---|---|
| `hello.l` | 5 | 94 B | **31.4 ms** | 24.50 MiB | 4,608 B | PASSED |
| `arithmetic.l` | 10 | 215 B | **36.1 ms** | 24.52 MiB | 5,120 B | PASSED |
| `fibonacci.l` | 13 | 297 B | **38.7 ms** | 24.52 MiB | 5,120 B | PASSED |
| `text_processing.l` | 10 | 235 B | **39.2 ms** | 24.52 MiB | 5,120 B | PASSED |
| `multimodule (main.l)` | 10 | 231 B | **54.7 ms** | 40.59 MiB | 5,120 B | PASSED |
| `main_sema.l` (Compiler) | 274 | 10,600 B | **15.64 s** | 525.11 MiB | 909,824 B | PASSED |
| `main_driver.l` (Self-Host) | 665 | 24,896 B | **31.30 s** | 855.04 MiB | 1,508,352 B | PASSED |

---

## 3. Compiler Memory Usage (Peak RSS)

Peak Resident Set Size (RSS) is measured continuously across the entire execution of the compiler process using the Windows Job Object API (`JOBOBJECT_EXTENDED_LIMIT_INFORMATION.PeakProcessMemoryUsed`).

![Peak Memory Usage](../assets/benchmarks/peak-memory.svg)

- **Standard programs (`hello`, `arithmetic`, `text`, `fibonacci`):** Consume a steady baseline of **~24.5 MiB**.
- **Multi-module compilation:** Increases memory to **40.6 MiB** due to AST caching and symbol resolution across file boundaries.
- **Full self-hosting driver (`main_driver.l`):** Generates more than 72,000 lines of ELE-LIR intermediate representation, peaking at **855.0 MiB** during monolithic semantic verification and basic block layout.

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
| **Fibonacci(25)** | **ELE** | `native-direct-emit` | **40.6 ms** | **28.37 ms** | **5,120 B** |
| Fibonacci(25) | Rust | Debug (`-O0`) | 657.6 ms | 20.72 ms | 5,086,801 B |
| Fibonacci(25) | Rust | Release (`-O3`) | 718.6 ms | 21.02 ms | 5,085,050 B |
| **Loop(10M)** | **ELE** | `native-direct-emit` | **48.9 ms** | **101.42 ms** | **5,120 B** |
| Loop(10M) | Rust | Debug (`-O0`) | 674.9 ms | 103.11 ms | 5,086,761 B |
| Loop(10M) | Rust | Release (`-O3`) | 692.6 ms | 21.40 ms | 5,084,972 B |

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
