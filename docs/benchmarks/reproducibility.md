# Benchmark Reproducibility Guide

This guide provides step-by-step instructions for replicating all benchmarks and regenerating the SVG charts published in the ELE documentation.

---

## 1. Prerequisites

- **Python 3.8+** installed on the host.
- **Git** with access to the ELE repository.
- Built compiler driver binary:
  - Windows: `bin/ele.exe`
  - Linux: `bin/ele.elf`

If the binary is not present in `bin/`, build it using Stage 0:
```powershell
cargo build -p project-l --bin l
cargo test -p project-l --test ele_build_driver_l driver_cli_help_flag
# Copy the resulting main_driver.exe to bin/ele.exe
```

---

## 2. Executing the Benchmark Suite

### Windows x86-64 Execution

```powershell
# 1. Run all compilation, memory, runtime, and comparison benchmarks
python benchmarks/scripts/run_benchmarks.py

# 2. Validate numerical integrity and schema compliance
python benchmarks/scripts/validate_results.py

# 3. Regenerate all 6 SVG charts in assets/benchmarks/
python benchmarks/scripts/generate_charts.py

# 4. Generate formatted Markdown summary tables
python benchmarks/scripts/compare_results.py
```

### Linux x86-64 Execution (Native or WSL2)

```bash
# Make driver executable
chmod +x bin/ele.elf

# Run benchmark validation
python3 benchmarks/scripts/validate_results.py
python3 benchmarks/scripts/generate_charts.py
```

---

## 3. Auditing the Raw Data

The output of each benchmark run is stored as versioned JSON records in `benchmarks/results/`:
- `compilation_benchmarks_windows.json`: Raw compile times and peak RSS.
- `runtime_benchmarks_windows.json`: Standalone binary execution durations.
- `external_comparison_windows.json`: ELE vs Rust debug and release.
- `external_comparison_linux.json`: ELE vs GCC unoptimized and `-O2`.
- `self_hosting_generations.json`: 3-generation SHA-256 fixpoint hashes.
- `native_coverage_evolution.json`: Pipeline stage coverage evolution.

Any auditor can inspect the individual iteration samples in the JSON files or re-run the runner to verify convergence within standard system variance.
