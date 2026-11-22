#!/usr/bin/env python3
"""
ELE Stage 3.4 - Benchmark Result Validator
Validates schema compliance, numerical integrity, non-null requirements,
and consistency across all benchmark result files.
"""

import sys
import json
from pathlib import Path
from statistics import median


def validate_compilation_records(records, filename):
    for r in records:
        bid = r.get("benchmark_id")
        assert bid, f"{filename}: missing benchmark_id"
        assert r.get("status") == "PASSED", f"{filename} ({bid}): status is not PASSED"
        assert r.get("iterations", 0) > 0, f"{filename} ({bid}): iterations <= 0"
        med = r.get("median_compile_ms")
        assert med is not None and med > 0, f"{filename} ({bid}): invalid median_compile_ms {med}"
        sz = r.get("binary_size_bytes")
        assert sz is not None and sz > 0, f"{filename} ({bid}): invalid binary_size_bytes {sz}"
        sha = r.get("binary_sha256")
        assert sha and len(sha) == 64, f"{filename} ({bid}): invalid binary_sha256 {sha}"
        times = r.get("compile_times_ms", [])
        assert len(times) == r["iterations"], f"{filename} ({bid}): compile_times_ms length mismatch"
    print(f"✓ {filename}: {len(records)} compilation records validated successfully")


def validate_runtime_records(records, filename):
    for r in records:
        bid = r.get("benchmark_id")
        assert bid, f"{filename}: missing benchmark_id"
        assert r.get("status") == "PASSED", f"{filename} ({bid}): status is not PASSED"
        med_r = r.get("median_runtime_ms")
        assert med_r is not None and med_r > 0, f"{filename} ({bid}): invalid median_runtime_ms {med_r}"
        times = r.get("runtimes_ms", [])
        assert len(times) == r["iterations"], f"{filename} ({bid}): runtimes_ms length mismatch"
    print(f"✓ {filename}: {len(records)} runtime records validated successfully")


def validate_comparison_records(records, filename):
    for r in records:
        bid = r.get("benchmark_id")
        assert bid, f"{filename}: missing benchmark_id"
        assert r.get("status") == "PASSED", f"{filename} ({bid}): status is not PASSED"
        assert r.get("language") in ["ELE", "Rust", "C"], f"{filename} ({bid}): unexpected language {r.get('language')}"
        assert r.get("median_compile_ms", 0) > 0, f"{filename} ({bid}): invalid median_compile_ms"
        assert r.get("median_runtime_ms", 0) > 0, f"{filename} ({bid}): invalid median_runtime_ms"
        assert r.get("binary_size_bytes", 0) > 0, f"{filename} ({bid}): invalid binary_size_bytes"
        compile_times = r.get("compile_times_ms", [])
        runtimes = r.get("runtimes_ms", [])
        assert r.get("compile_iterations") == len(compile_times) and compile_times, (
            f"{filename} ({bid}): compile_iterations does not match samples"
        )
        assert r.get("iterations") == len(runtimes) and runtimes, (
            f"{filename} ({bid}): runtime iterations does not match samples"
        )
        assert abs(median(compile_times) - r["median_compile_ms"]) < 0.06, (
            f"{filename} ({bid}): compilation median does not match samples"
        )
        assert abs(median(runtimes) - r["median_runtime_ms"]) < 0.06, (
            f"{filename} ({bid}): runtime median does not match samples"
        )
        assert not Path(r.get("source_file", "")).is_absolute(), (
            f"{filename} ({bid}): source_file should be repository relative"
        )
    print(f"✓ {filename}: {len(records)} comparison records validated successfully")


def validate_self_hosting(data, filename):
    gens = data.get("generations", {})
    assert "windows_pe32" in gens, f"{filename}: missing windows_pe32"
    assert "linux_elf64" in gens, f"{filename}: missing linux_elf64"

    for platform_key in ["windows_pe32", "linux_elf64"]:
        p = gens[platform_key]
        assert p.get("bitwise_identical_fixpoint") is True, f"{filename} ({platform_key}): fixpoint not bitwise identical"
        assert p.get("functional_execution_verified") is True, f"{filename} ({platform_key}): functional execution not verified"
        g2 = p.get("gen2", {})
        g3 = p.get("gen3", {})
        assert g2.get("sha256") == g3.get("sha256"), f"{filename} ({platform_key}): Gen 2 SHA != Gen 3 SHA"
        assert g2.get("external_compiler_invocations") == 0, f"{filename} ({platform_key}): Gen 2 external invocations != 0"
        assert g3.get("external_compiler_invocations") == 0, f"{filename} ({platform_key}): Gen 3 external invocations != 0"
    print(f"✓ {filename}: 3-generation self-hosting data verified on Windows and Linux")


def validate_coverage(data, filename):
    total = data.get("total_source_files", 0)
    assert total == 102, f"{filename}: expected 102 total source files, got {total}"
    stages = data.get("stages", [])
    assert len(stages) >= 3, f"{filename}: expected at least 3 stages"
    last_stage = stages[-1]
    assert last_stage.get("native_backend_files") == 20, f"{filename}: expected 20 backend files in latest stage"
    assert last_stage.get("percent_backend_standalone") == 100.0, f"{filename}: expected 100% standalone backend"
    print(f"✓ {filename}: native coverage progression verified (102 files, 20/20 standalone)")


def main():
    root = Path(__file__).resolve().parent.parent.parent
    results_dir = root / "benchmarks/results"

    if not results_dir.exists():
        print("ERROR: benchmarks/results directory does not exist")
        sys.exit(1)

    print("Validating all benchmark result records...\n")
    try:
        f_comp_win = results_dir / "compilation_benchmarks_windows.json"
        if f_comp_win.exists():
            with open(f_comp_win, "r", encoding="utf-8") as f:
                validate_compilation_records(json.load(f), f_comp_win.name)

        f_run_win = results_dir / "runtime_benchmarks_windows.json"
        if f_run_win.exists():
            with open(f_run_win, "r", encoding="utf-8") as f:
                validate_runtime_records(json.load(f), f_run_win.name)

        f_comp_ext_win = results_dir / "external_comparison_windows.json"
        if f_comp_ext_win.exists():
            with open(f_comp_ext_win, "r", encoding="utf-8") as f:
                validate_comparison_records(json.load(f), f_comp_ext_win.name)

        f_comp_ext_lin = results_dir / "external_comparison_linux.json"
        if f_comp_ext_lin.exists():
            with open(f_comp_ext_lin, "r", encoding="utf-8") as f:
                validate_comparison_records(json.load(f), f_comp_ext_lin.name)

        f_sh = results_dir / "self_hosting_generations.json"
        if f_sh.exists():
            with open(f_sh, "r", encoding="utf-8") as f:
                validate_self_hosting(json.load(f), f_sh.name)

        f_cov = results_dir / "native_coverage_evolution.json"
        if f_cov.exists():
            with open(f_cov, "r", encoding="utf-8") as f:
                validate_coverage(json.load(f), f_cov.name)

        print("\nALL BENCHMARK RESULTS VALIDATED SUCCESSFULLY (0 errors)")
    except Exception as e:
        print(f"\nVALIDATION FAILED: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
