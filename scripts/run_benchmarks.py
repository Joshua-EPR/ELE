#!/usr/bin/env python3
"""
scripts/run_benchmarks.py — Runner automatizado para microbenchmarks de NEXO v0.4.

Ejecuta 5 procesos de SO totalmente independientes (N=5) del ejecutable
`nexo-physical-bench --completo`, recolecta los datos brutos en formato JSON,
calcula estadísticas rigurosamente desagregadas (lotes N=700, corridas N=7, procesos N=5),
verifica las cotas matemáticas de Samuelson y genera un informe consolidado en `docs/benchmarks/summary.json`.
"""

import datetime
import json
import math
import os
import platform
import subprocess
import sys
from pathlib import Path


def get_git_head(repo_root: Path) -> str:
    try:
        res = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        return res.stdout.strip()
    except Exception as e:
        return f"unknown ({e})"


def get_rustc_version() -> str:
    try:
        res = subprocess.run(
            ["rustc", "--version"],
            capture_output=True,
            text=True,
            check=True,
        )
        return res.stdout.strip()
    except Exception as e:
        return f"unknown ({e})"


def compute_distribution_stats(samples: list[float]) -> dict:
    n = len(samples)
    if n == 0:
        raise ValueError("Cannot compute stats on empty samples")

    # Algoritmo de Welford numéricamente estable
    mean = 0.0
    m2 = 0.0
    for i, x in enumerate(samples, start=1):
        delta = x - mean
        mean += delta / i
        delta2 = x - mean
        m2 += delta * delta2

    var_sample = (m2 / (n - 1)) if n > 1 else 0.0
    var_pop = m2 / n
    std_sample = math.sqrt(var_sample)
    std_pop = math.sqrt(var_pop)
    cv_sample = (std_sample / mean * 100.0) if abs(mean) > 1e-9 else 0.0
    cv_pop = (std_pop / mean * 100.0) if abs(mean) > 1e-9 else 0.0

    sorted_samples = sorted(samples)
    min_val = sorted_samples[0]
    max_val = sorted_samples[-1]

    def percentile(p: float) -> float:
        if n == 1:
            return sorted_samples[0]
        rank = (n - 1) * p
        lower = int(math.floor(rank))
        upper = int(math.ceil(rank))
        weight = rank - lower
        return sorted_samples[lower] * (1.0 - weight) + sorted_samples[upper] * weight

    median_val = percentile(0.50)
    p95_val = percentile(0.95)
    p99_val = percentile(0.99)

    # Verificación de cota de Samuelson: |max - mean| <= s * sqrt(n - 1)
    if n > 1:
        bound = std_sample * math.sqrt(n - 1) + 1e-6
        dev_max = abs(max_val - mean)
        dev_min = abs(min_val - mean)
        if dev_max > bound or dev_min > bound:
            raise ValueError(
                f"Violación de cota de Samuelson: max_dev={max(dev_max, dev_min):.4f} > bound={bound:.4f} (s={std_sample:.4f}, n={n})"
            )

    return {
        "count": n,
        "mean": round(mean, 4),
        "median": round(median_val, 4),
        "min": round(min_val, 4),
        "max": round(max_val, 4),
        "p95": round(p95_val, 4),
        "p99": round(p99_val, 4),
        "variance_sample": round(var_sample, 4),
        "variance_pop": round(var_pop, 4),
        "stddev_sample": round(std_sample, 4),
        "stddev_pop": round(std_pop, 4),
        "cv_sample": round(cv_sample, 4),
        "cv_pop": round(cv_pop, 4),
    }


def main():
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    benchmarks_dir = repo_root / "docs" / "benchmarks"
    raw_dir = benchmarks_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 80)
    print("NEXO v0.4 — CAMPAÑA AUTOMATIZADA DE MICROBENCHMARKS MULTI-PROCESO")
    print("=" * 80)

    # 1. Metadatos de entorno
    git_head = get_git_head(repo_root)
    rustc_ver = get_rustc_version()
    env_meta = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "git_head": git_head,
        "rustc_version": rustc_ver,
        "os_name": platform.system(),
        "os_release": platform.release(),
        "os_version": platform.version(),
        "architecture": platform.machine(),
        "processor": platform.processor(),
        "cpu_logical_cores": os.cpu_count(),
    }
    print(f"Git HEAD:         {git_head}")
    print(f"Rustc:            {rustc_ver}")
    print(f"SO:               {env_meta['os_name']} {env_meta['os_release']} ({env_meta['architecture']})")
    print(f"CPU cores:        {env_meta['cpu_logical_cores']}")

    # 2. Compilar binario release si no existe o para asegurar paridad
    print("\n[1/3] Compilando binario de benchmarks en release profile...")
    build_cmd = ["cargo", "build", "--bin", "nexo-physical-bench", "--release"]
    build_res = subprocess.run(build_cmd, cwd=repo_root, capture_output=True, text=True)
    if build_res.returncode != 0:
        print(f"Error compilando release binary:\n{build_res.stderr}")
        sys.exit(1)
    print("Compilación release completada con éxito.")

    exe_suffix = ".exe" if platform.system() == "Windows" else ""
    bin_path = repo_root / "target" / "release" / f"nexo-physical-bench{exe_suffix}"
    if not bin_path.exists():
        print(f"Error: no se encontró el ejecutable en {bin_path}")
        sys.exit(1)

    # 3. Ejecución de 5 procesos independientes de SO
    num_processes = 5
    print(f"\n[2/3] Ejecutando {num_processes} procesos independientes de SO (N={num_processes})...")
    processes_meta = []
    process_data = []

    for i in range(1, num_processes + 1):
        out_json_path = raw_dir / f"process_{i}.json"
        print(f"  -> Ejecutando Proceso {i}/{num_processes} -> {out_json_path.name}...")
        start_t = datetime.datetime.now()
        cmd = [str(bin_path), "--completo", "--json-out", str(out_json_path)]
        proc = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
        elapsed = (datetime.datetime.now() - start_t).total_seconds()

        if proc.returncode != 0:
            print(f"Error en proceso {i} (código {proc.returncode}):\n{proc.stderr}")
            sys.exit(1)

        if not out_json_path.exists():
            print(f"Error: proceso {i} no generó {out_json_path}")
            sys.exit(1)

        with open(out_json_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        processes_meta.append({
            "process_id": i,
            "exit_code": proc.returncode,
            "wall_duration_seconds": round(elapsed, 3),
            "output_json": str(out_json_path.relative_to(repo_root)).replace("\\", "/"),
        })
        process_data.append(data)
        print(f"     Proceso {i} terminado en {elapsed:.2f}s.")

    # 4. Agregación y cálculo de estadísticas entre procesos (cross-process N=5)
    print("\n[3/3] Calculando estadísticas consolidadas y verificando cotas de Samuelson...")

    num_scenarios = len(process_data[0]["scenarios"])
    consolidated_scenarios = []

    for sc_idx in range(num_scenarios):
        sc_name = process_data[0]["scenarios"][sc_idx]["name"]
        
        # Colección de medias por proceso (N=5)
        proc_means = [p["scenarios"][sc_idx]["batch_stats"]["mean"] for p in process_data]
        proc_stats = compute_distribution_stats(proc_means)

        # Colección de lotes acumulados de todos los procesos (5 * 700 = 3500 muestras)
        pooled_batches = []
        for p in process_data:
            pooled_batches.extend(p["scenarios"][sc_idx]["batch_samples"])
        pooled_batch_stats = compute_distribution_stats(pooled_batches)

        # Promedio de dispersión intrínseca por corrida (run_stddev)
        run_stddevs = [p["scenarios"][sc_idx]["run_stats"]["stddev_sample"] for p in process_data]
        avg_run_stddev = round(sum(run_stddevs) / len(run_stddevs), 4)

        # Promedio de contadores
        c_template = process_data[0]["scenarios"][sc_idx]["counters"]
        avg_counters = {}
        for k in c_template:
            avg_counters[k] = round(sum(p["scenarios"][sc_idx]["counters"][k] for p in process_data) / num_processes, 4)

        consolidated_scenarios.append({
            "name": sc_name,
            "cross_process_stats": proc_stats,
            "proc_means": proc_means,
            "pooled_batch_stats": pooled_batch_stats,
            "avg_run_stddev": avg_run_stddev,
            "counters": avg_counters,
        })

    summary = {
        "metadata": env_meta,
        "processes": processes_meta,
        "scenarios": consolidated_scenarios,
    }

    summary_path = benchmarks_dir / "summary.json"
    with open(summary_path, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    print(f"\nResumen consolidado generado exitosamente en: {summary_path.relative_to(repo_root)}")

    # 5. Visualización en tabla por consola
    print("\n" + "=" * 120)
    print(f"{'TABLA CONSOLIDADA MULTI-PROCESO (N=5 procesos, 7 corridas c/u, 700 lotes/proc)':^120}")
    print("=" * 120)
    header = (
        f"{'Escenario':<42} "
        f"{'Proc Mean':>10} {'Proc SD':>9} {'Proc CV%':>9} "
        f"{'Batch Mean':>11} {'Batch SD':>10} {'Run SD (avg)':>12} "
        f"{'SO/op':>8} {'Alloc/op':>9}"
    )
    print(header)
    print("-" * 120)

    for sc in consolidated_scenarios:
        name = sc["name"]
        if len(name) > 40:
            name = name[:37] + "..."
        p_stat = sc["cross_process_stats"]
        b_stat = sc["pooled_batch_stats"]
        run_sd = sc["avg_run_stddev"]
        so_op = sc["counters"]["os_calls_per_op"]
        alloc_op = sc["counters"]["alloc_per_op"]

        row = (
            f"{name:<42} "
            f"{p_stat['mean']:>10.1f} {p_stat['stddev_sample']:>9.2f} {p_stat['cv_sample']:>8.1f}% "
            f"{b_stat['mean']:>11.1f} {b_stat['stddev_sample']:>10.2f} {run_sd:>12.2f} "
            f"{so_op:>8.3f} {alloc_op:>9.3f}"
        )
        print(row)
    print("=" * 120)


if __name__ == "__main__":
    main()
