#!/usr/bin/env python3
"""
ELE Stage 3.4 - Benchmark Comparison Table Formatter
Generates clean Markdown tables from benchmark JSON records for documentation and CI.
"""

import json
from pathlib import Path


def load_json(path: Path):
    if not path.exists():
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    root = Path(__file__).resolve().parent.parent.parent
    results_dir = root / "benchmarks/results"

    print("# ELE Benchmark Performance Summary Tables\n")

    # 1. Compilation
    comp = load_json(results_dir / "compilation_benchmarks_windows.json")
    if comp:
        print("## Compilation Benchmarks (Windows x86-64 PE32+)")
        print("| Workload | Source Lines | Source Size | Median Compile Time | Peak RSS | Binary Size | Status |")
        print("|---|---|---|---|---|---|---|")
        for r in comp:
            bid = r["benchmark_id"].replace("compilation_", "")
            lines = f"{r['source_lines']:,}" if r.get("source_lines") else "N/A"
            src_bytes = f"{r['source_bytes']:,} B" if r.get("source_bytes") else "N/A"
            med_ms = f"{r['median_compile_ms']:.1f} ms" if r.get("median_compile_ms") < 1000 else f"{r['median_compile_ms']/1000.0:.2f} s"
            rss = f"{r['peak_rss_mib']:.2f} MiB" if r.get("peak_rss_mib") else "N/A"
            bsize = f"{r['binary_size_bytes']:,} B" if r.get("binary_size_bytes") else "N/A"
            print(f"| `{bid}` | {lines} | {src_bytes} | **{med_ms}** | {rss} | {bsize} | {r['status']} |")
        print("")

    # 2. Comparison Windows
    comp_win = load_json(results_dir / "external_comparison_windows.json")
    if comp_win:
        print("## External Compiler Comparison: ELE vs Rust (Windows x86-64)")
        print("| Benchmark | Language | Compiler / Flags | Median Compile Time | Median Runtime | Binary Size |")
        print("|---|---|---|---|---|---|")
        for r in comp_win:
            bid = r["benchmark_id"].replace("comparison_", "")
            c_time = f"{r['median_compile_ms']:.1f} ms" if r.get("median_compile_ms") else "N/A"
            r_time = f"{r['median_runtime_ms']:.2f} ms" if r.get("median_runtime_ms") else "N/A"
            bsize = f"{r['binary_size_bytes']:,} B" if r.get("binary_size_bytes") else "N/A"
            print(f"| `{bid}` | {r['language']} | `{r['optimization']}` | {c_time} | **{r_time}** | {bsize} |")
        print("")

    # 3. Comparison Linux
    comp_lin = load_json(results_dir / "external_comparison_linux.json")
    if comp_lin:
        print("## External Compiler Comparison: ELE vs GCC (Linux x86-64 / WSL2)")
        print("| Benchmark | Language | Compiler / Flags | Median Compile Time | Median Runtime | Binary Size |")
        print("|---|---|---|---|---|---|")
        for r in comp_lin:
            bid = r["benchmark_id"].replace("comparison_", "")
            c_time = f"{r['median_compile_ms']:.1f} ms" if r.get("median_compile_ms") else "N/A"
            r_time = f"{r['median_runtime_ms']:.2f} ms" if r.get("median_runtime_ms") else "N/A"
            bsize = f"{r['binary_size_bytes']:,} B" if r.get("binary_size_bytes") else "N/A"
            print(f"| `{bid}` | {r['language']} | `{r['optimization']}` | {c_time} | **{r_time}** | {bsize} |")
        print("")


if __name__ == "__main__":
    main()
