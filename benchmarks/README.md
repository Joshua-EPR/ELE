# ELE Benchmark Suite & Reproducibility Infrastructure

This directory contains the automated, verifiable benchmarking infrastructure for the **ELE Programming Language**.

All metrics, graphs, and performance assertions in the ELE repository are generated directly from real executions using the scripts in this suite. **No metrics are fabricated, and no synthetic charts are committed.**

---

## Architecture of the Benchmark Suite

```text
benchmarks/
├── README.md                      # This specification and guide
├── schemas/
│   └── benchmark_schema.json      # JSON Schema for auditable benchmark outputs
├── sources/                       # Fixed benchmark workloads in ELE, Rust, and C
│   ├── hello.l                    # Minimal entry-point baseline
│   ├── arithmetic.l               # Checked arithmetic and function call overhead
│   ├── fibonacci.l                # Recursive function call and control flow
│   ├── text_processing.l         # Dynamic UTF-8 heap text, interpolation, drop elaboration
│   ├── multimodule/               # Multi-file compilation (`take` / `expose`)
│   └── comparisons/               # Equivalent workloads across ELE, Rust, and C
│       ├── fibonacci_recursive.*  # Recursive Fibonacci(25)
│       └── arithmetic_loop.*      # 10,000,000 iteration tight accumulator loop
├── scripts/
│   ├── run_benchmarks.py          # Benchmark runner (compilation, memory, runtime)
│   ├── validate_results.py        # Validates data integrity and schema compliance
│   ├── generate_charts.py         # Deterministic SVG chart generator (zero dependencies)
│   └── compare_results.py         # Markdown comparison table generator
└── results/                       # Versioned raw JSON execution results
    ├── compilation_benchmarks_windows.json
    ├── runtime_benchmarks_windows.json
    ├── external_comparison_windows.json
    ├── external_comparison_linux.json
    ├── self_hosting_generations.json
    ├── native_coverage_evolution.json
    └── summary.json
```

---

## Metrics Tracked

1. **Compilation Time (ms):**
   - High-resolution wall-clock duration (`time.perf_counter()`).
   - 1 initial untimed warmup run to populate OS disk caches.
   - 10 consecutive timed iterations (5 iterations for massive self-hosting sources).
   - Median, minimum, maximum, and standard deviation calculated.
2. **Compiler Peak Memory Usage (Peak RSS in MiB):**
   - **Windows:** Exact kernel tracking across the entire process lifetime using the Windows Job Object API (`JOBOBJECT_EXTENDED_LIMIT_INFORMATION.PeakProcessMemoryUsed`).
   - **Linux:** Process peak resident set size via kernel accounting (`getrusage(RUSAGE_CHILDREN)` / `/usr/bin/time -v`).
3. **Binary Size (bytes):**
   - Exact size of the generated executable image on disk (`.exe` on Windows, `.elf` on Linux).
4. **Binary SHA-256 Digest:**
   - Cryptographic hash ensuring reproducibility and bitwise fixpoint verification.
5. **Runtime Latency (ms):**
   - Execution time of the generated standalone binary across 10 timed iterations.
   - Strict stdout verification against mathematically expected results (e.g. `75025` for Fibonacci 25, `149999995000000` for 10M loop).

---

## Fair External Comparison Protocol

To ensure fairness, transparency, and scientific integrity:
1. **Algorithm Parity:** Algorithms across ELE, Rust, and C are identical in logic, variable count, data types (`Int`/`i64`/`int64_t`), and recursion depth.
2. **Mathematical Validation:** Every test verifies that all compilers produce the exact same standard output before accepting the timing.
3. **Optimization Disclosure:**
   - **ELE:** Direct native machine code generation (unoptimized linear LIR emit, no SSA or register allocator passes).
   - **Rust:** Tested in both Debug (`-O0`) and Release (`-O3`).
   - **C (GCC):** Tested in both Debug (`-O0`) and Release (`-O2`).
4. **Zero-Dependency Direct Emitter:**
   - ELE compiles standalone executables with zero runtime dependencies (no libc, no CRT, no Rust stdlib).
   - This results in binaries of ~5 KiB, whereas static standard libraries (e.g. Rust) produce ~5 MiB binaries.

---

## Running the Benchmarks Locally

### Requirements
- **Windows:** Python 3.8+ (no pip dependencies required; uses standard library `ctypes`).
- **Linux / WSL:** Python 3.8+ and GCC.
- **ELE Driver:** Self-hosted compiler driver located at `bin/ele.exe` (or `bin/ele.elf`).

### Commands

```powershell
# 1. Run all benchmarks (compilation, peak memory, runtime, comparisons)
python benchmarks/scripts/run_benchmarks.py

# 2. Validate that all results conform to schema and have non-null values
python benchmarks/scripts/validate_results.py

# 3. Generate the SVG charts in assets/benchmarks/
python benchmarks/scripts/generate_charts.py

# 4. Print markdown summary tables
python benchmarks/scripts/compare_results.py
```
