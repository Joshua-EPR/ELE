#!/usr/bin/env python3
"""
scripts/run_benchmarks.py — Runner automatizado para microbenchmarks de NEXO v0.4.

Ejecuta 5 procesos de SO totalmente independientes (N=5) del ejecutable
`nexo-physical-bench --completo`, recolecta los datos brutos en formato JSON,
calcula estadísticas rigurosamente desagregadas (lotes N=700, corridas N=7, procesos N=5),
verifica las cotas matemáticas de Samuelson y genera un informe consolidado en
`docs/benchmarks/campaigns/<campaign_id>/summary.json` y `docs/benchmarks/summary.json`.
"""

import datetime
import hashlib
import json
import math
import os
import platform
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSION = "v0.4.1"
STATS_SPEC_VERSION = "1.1.0"
EXPECTED_SCENARIO_COUNT = 16
EXPECTED_BATCH_SAMPLES = 700


def compute_file_sha256(path: Path) -> str:
    """Calcula el hash criptográfico SHA-256 de un archivo en disco."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest()


def compute_bytes_sha256(data: bytes) -> str:
    """Calcula el hash criptográfico SHA-256 de un buffer en memoria."""
    return hashlib.sha256(data).hexdigest()


def get_git_info(repo_root: Path) -> dict:
    """Extrae metadatos precisos de Git (HEAD, branch, estado dirty, diff hash)."""
    git_head = "unknown"
    git_branch = "unknown"
    is_dirty = False
    diff_sha256 = None

    try:
        res = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        git_head = res.stdout.strip()
    except Exception as e:
        git_head = f"unknown ({e})"

    try:
        res = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        git_branch = res.stdout.strip()
    except Exception:
        pass

    try:
        res = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        status_output = res.stdout.strip()
        is_dirty = len(status_output) > 0
        if is_dirty:
            diff_res = subprocess.run(
                ["git", "diff", "HEAD"],
                cwd=repo_root,
                capture_output=True,
                check=True,
            )
            diff_sha256 = compute_bytes_sha256(diff_res.stdout)
    except Exception:
        pass

    return {
        "git_head": git_head,
        "git_branch": git_branch,
        "git_dirty": is_dirty,
        "git_diff_sha256": diff_sha256,
    }


def get_rustc_info() -> dict:
    """Obtiene versión de rustc, cargo y arquitectura target host."""
    rustc_ver = "unknown"
    target_triple = "unknown"
    try:
        res = subprocess.run(
            ["rustc", "--version"],
            capture_output=True,
            text=True,
            check=True,
        )
        rustc_ver = res.stdout.strip()
    except Exception as e:
        rustc_ver = f"unknown ({e})"

    try:
        res = subprocess.run(
            ["rustc", "-vV"],
            capture_output=True,
            text=True,
            check=True,
        )
        for line in res.stdout.splitlines():
            if line.startswith("host:"):
                target_triple = line.split(":", 1)[1].strip()
    except Exception:
        pass

    cargo_ver = "unknown"
    try:
        res = subprocess.run(
            ["cargo", "--version"],
            capture_output=True,
            text=True,
            check=True,
        )
        cargo_ver = res.stdout.strip()
    except Exception as e:
        cargo_ver = f"unknown ({e})"

    return {
        "rustc_version": rustc_ver,
        "cargo_version": cargo_ver,
        "target_triple": target_triple,
    }


def percentile_sorted(sorted_samples: list[float], p: float) -> float:
    """Calcula percentil con interpolación lineal uniforme idéntica a Rust."""
    n = len(sorted_samples)
    if n == 0:
        return 0.0
    if n == 1 or p <= 0.0:
        return sorted_samples[0]
    if p >= 1.0:
        return sorted_samples[-1]

    r = (n - 1) * p
    lower = int(math.floor(r))
    upper = int(math.ceil(r))
    weight = r - lower

    if lower == upper or upper >= n:
        return sorted_samples[min(lower, n - 1)]
    return sorted_samples[lower] * (1.0 - weight) + sorted_samples[upper] * weight


def compute_distribution_stats(samples: list[float]) -> dict:
    """Calcula estadísticas numéricamente estables mediante el algoritmo de Welford."""
    n = len(samples)
    if n == 0:
        raise ValueError("Cannot compute stats on empty samples")

    for x in samples:
        if not math.isfinite(x):
            raise ValueError(f"Non-finite sample value detected: {x}")

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

    p50_val = percentile_sorted(sorted_samples, 0.50)
    p95_val = percentile_sorted(sorted_samples, 0.95)
    p99_val = percentile_sorted(sorted_samples, 0.99)

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
        "median": round(p50_val, 4),
        "min": round(min_val, 4),
        "max": round(max_val, 4),
        "p50": round(p50_val, 4),
        "p95": round(p95_val, 4),
        "p99": round(p99_val, 4),
        "variance_sample": round(var_sample, 4),
        "variance_pop": round(var_pop, 4),
        "stddev_sample": round(std_sample, 4),
        "stddev_pop": round(std_pop, 4),
        "cv_sample": round(cv_sample, 4),
        "cv_pop": round(cv_pop, 4),
    }


def validate_benchmark_process_data(
    data: dict, expected_campaign_id: str, expected_process_id: int
) -> None:
    """Valida estrictamente los datos generados por un proceso independiente."""
    if not isinstance(data, dict):
        raise ValueError("Root JSON content must be an object")

    schema_ver = data.get("schema_version")
    if schema_ver != SCHEMA_VERSION:
        raise ValueError(
            f"Schema version mismatch: expected '{SCHEMA_VERSION}', got '{schema_ver}'"
        )

    stats_ver = data.get("stats_spec_version")
    if stats_ver != STATS_SPEC_VERSION:
        raise ValueError(
            f"Stats spec version mismatch: expected '{STATS_SPEC_VERSION}', got '{stats_ver}'"
        )

    cid = data.get("campaign_id")
    if cid != expected_campaign_id:
        raise ValueError(
            f"Campaign ID mismatch: expected '{expected_campaign_id}', got '{cid}'"
        )

    pid = str(data.get("process_id"))
    if pid != str(expected_process_id):
        raise ValueError(
            f"Process ID mismatch: expected '{expected_process_id}', got '{pid}'"
        )

    scenarios = data.get("scenarios")
    if not isinstance(scenarios, list):
        raise ValueError("Missing or invalid 'scenarios' array")

    if len(scenarios) != EXPECTED_SCENARIO_COUNT:
        raise ValueError(
            f"Scenario count mismatch: expected {EXPECTED_SCENARIO_COUNT}, got {len(scenarios)}"
        )

    seen_names = set()
    for sc in scenarios:
        name = sc.get("name")
        if not name:
            raise ValueError("Scenario missing name")
        if name in seen_names:
            raise ValueError(f"Duplicate scenario name detected: '{name}'")
        seen_names.add(name)

        batch_stats = sc.get("batch_stats")
        run_stats = sc.get("run_stats")
        batch_samples = sc.get("batch_samples")
        counters = sc.get("counters")

        if not isinstance(batch_stats, dict) or not isinstance(run_stats, dict):
            raise ValueError(f"Scenario '{name}' missing stats structures")
        if not isinstance(batch_samples, list) or not isinstance(counters, dict):
            raise ValueError(f"Scenario '{name}' missing samples or counters")

        expected_samples = 336 if "ráfaga 960" in name else EXPECTED_BATCH_SAMPLES
        if len(batch_samples) != expected_samples:
            raise ValueError(
                f"Scenario '{name}' expected {expected_samples} batch samples, got {len(batch_samples)}"
            )

        if batch_stats.get("count") != expected_samples:
            raise ValueError(
                f"Scenario '{name}' batch_stats count mismatch: {batch_stats.get('count')} != {expected_samples}"
            )

        # Verificar valores numéricos finitos
        for key, val in batch_stats.items():
            if not isinstance(val, (int, float)) or not math.isfinite(val):
                raise ValueError(
                    f"Scenario '{name}' batch_stats non-finite field '{key}': {val}"
                )

        for key, val in run_stats.items():
            if not isinstance(val, (int, float)) or not math.isfinite(val):
                raise ValueError(
                    f"Scenario '{name}' run_stats non-finite field '{key}': {val}"
                )

        for s in batch_samples:
            if not isinstance(s, (int, float)) or not math.isfinite(s):
                raise ValueError(
                    f"Scenario '{name}' non-finite batch sample detected: {s}"
                )

        for key, val in counters.items():
            if not isinstance(val, (int, float)) or not math.isfinite(val):
                raise ValueError(
                    f"Scenario '{name}' non-finite counter field '{key}': {val}"
                )

        # Verificar cota de Samuelson en batch_stats y run_stats
        for stat_obj, label in [(batch_stats, "batch_stats"), (run_stats, "run_stats")]:
            cnt = stat_obj.get("count", 0)
            if cnt > 1:
                sd = stat_obj.get("stddev_sample", 0.0)
                mean = stat_obj.get("mean", 0.0)
                max_v = stat_obj.get("max", 0.0)
                min_v = stat_obj.get("min", 0.0)
                bound = sd * math.sqrt(cnt - 1) + 1e-4
                if abs(max_v - mean) > bound or abs(min_v - mean) > bound:
                    raise ValueError(
                        f"Scenario '{name}' {label} Samuelson violation: bound={bound:.4f}"
                    )


def atomic_write_json(target_path: Path, data: dict, indent: int = 2) -> None:
    """Escribe un archivo JSON de forma atómica usando reemplazo de archivo temporal."""
    target_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = target_path.with_name(f"{target_path.name}.tmp.{os.getpid()}")
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=indent)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, target_path)
    except Exception:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass
        raise


def main():
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    benchmarks_dir = repo_root / "docs" / "benchmarks"

    # Generar identificador único de campaña
    timestamp_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d_%H%M%S")
    random_hex = secrets.token_hex(4)
    campaign_id = f"campaign_{timestamp_str}_{random_hex}"

    campaign_dir = benchmarks_dir / "campaigns" / campaign_id
    campaign_raw_dir = campaign_dir / "raw"
    campaign_raw_dir.mkdir(parents=True, exist_ok=True)

    legacy_raw_dir = benchmarks_dir / "raw"
    legacy_raw_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 80)
    print("NEXO v0.4 — CAMPAÑA AUTOMATIZADA DE MICROBENCHMARKS MULTI-PROCESO")
    print(f"Campaña ID:       {campaign_id}")
    print("=" * 80)

    # 1. Metadatos de entorno y Git
    git_info = get_git_info(repo_root)
    rustc_info = get_rustc_info()

    env_meta = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "campaign_id": campaign_id,
        "schema_version": SCHEMA_VERSION,
        "stats_spec_version": STATS_SPEC_VERSION,
        "profile": "release",
        **git_info,
        **rustc_info,
        "os_name": platform.system(),
        "os_release": platform.release(),
        "os_version": platform.version(),
        "architecture": platform.machine(),
        "processor": platform.processor(),
        "cpu_logical_cores": os.cpu_count(),
    }

    print(f"Git HEAD:         {git_info['git_head']}")
    print(f"Git Branch:       {git_info['git_branch']}")
    print(f"Git Dirty:        {git_info['git_dirty']}")
    if git_info['git_diff_sha256']:
        print(f"Git Diff SHA-256: {git_info['git_diff_sha256']}")
    print(f"Rustc:            {rustc_info['rustc_version']}")
    print(f"Cargo:            {rustc_info['cargo_version']}")
    print(f"Target Triple:    {rustc_info['target_triple']}")
    print(f"SO:               {env_meta['os_name']} {env_meta['os_release']} ({env_meta['architecture']})")
    print(f"CPU cores:        {env_meta['cpu_logical_cores']}")

    # 2. Compilar binario release si no existe o para asegurar paridad
    print("\n[1/4] Compilando binario de benchmarks en release profile...")
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

    binary_sha256_pre = compute_file_sha256(bin_path)
    env_meta["binary_sha256_pre"] = binary_sha256_pre
    print(f"Binario ejecutable SHA-256 (pre): {binary_sha256_pre}")

    # 3. Ejecución de 5 procesos independientes de SO
    num_processes = 5
    print(f"\n[2/4] Ejecutando {num_processes} procesos independientes de SO (N={num_processes})...")
    processes_meta = []
    process_data = []

    for i in range(1, num_processes + 1):
        out_json_path = campaign_raw_dir / f"process_{i}.json"
        legacy_json_path = legacy_raw_dir / f"process_{i}.json"
        print(f"  -> Ejecutando Proceso {i}/{num_processes} -> {out_json_path.name}...")
        start_t = datetime.datetime.now()
        cmd = [
            str(bin_path),
            "--completo",
            "--json-out",
            str(out_json_path),
            "--campaign-id",
            campaign_id,
            "--process-id",
            str(i),
        ]
        proc = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
        elapsed = (datetime.datetime.now() - start_t).total_seconds()

        if proc.returncode != 0:
            print(f"Error en proceso {i} (código {proc.returncode}):\n{proc.stderr}")
            sys.exit(1)

        if not out_json_path.exists():
            print(f"Error: proceso {i} no generó {out_json_path}")
            sys.exit(1)

        # Verificar integridad del binario post-ejecución
        current_bin_sha = compute_file_sha256(bin_path)
        if current_bin_sha != binary_sha256_pre:
            print(f"Error crítico: el binario fue alterado durante la ejecución del proceso {i}")
            sys.exit(1)

        with open(out_json_path, "r", encoding="utf-8") as f:
            try:
                data = json.load(f)
            except Exception as e:
                print(f"Error parseando JSON de proceso {i}: {e}")
                sys.exit(1)

        # Validación exhaustiva de invariantes
        try:
            validate_benchmark_process_data(data, campaign_id, i)
        except Exception as e:
            print(f"Error validando datos de proceso {i}: {e}")
            sys.exit(1)

        # Copia para retrocompatibilidad
        shutil.copyfile(out_json_path, legacy_json_path)

        file_sha256 = compute_file_sha256(out_json_path)
        processes_meta.append({
            "process_id": i,
            "exit_code": proc.returncode,
            "wall_duration_seconds": round(elapsed, 3),
            "output_json": str(out_json_path.relative_to(repo_root)).replace("\\", "/"),
            "sha256": file_sha256,
        })
        process_data.append(data)
        print(f"     Proceso {i} terminado en {elapsed:.2f}s (SHA-256: {file_sha256[:12]}...).")

    binary_sha256_post = compute_file_sha256(bin_path)
    env_meta["binary_sha256_post"] = binary_sha256_post
    if binary_sha256_post != binary_sha256_pre:
        print("Error de paridad de binario: hash post-ejecución no coincide")
        sys.exit(1)

    # 4. Agregación y cálculo de estadísticas entre procesos (cross-process N=5)
    print("\n[3/4] Calculando estadísticas consolidadas y verificando cotas de Samuelson...")

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
            avg_counters[k] = round(
                sum(p["scenarios"][sc_idx]["counters"][k] for p in process_data) / num_processes,
                4,
            )

        consolidated_scenarios.append({
            "name": sc_name,
            "cross_process_stats": proc_stats,
            "proc_means": proc_means,
            "pooled_batch_stats": pooled_batch_stats,
            "avg_run_stddev": avg_run_stddev,
            "counters": avg_counters,
        })

    summary = {
        "schema_version": SCHEMA_VERSION,
        "stats_spec_version": STATS_SPEC_VERSION,
        "campaign_id": campaign_id,
        "metadata": env_meta,
        "processes": processes_meta,
        "scenarios": consolidated_scenarios,
    }

    # Escritura atómica de summary en carpeta de campaña y retrocompatibilidad
    campaign_summary_path = campaign_dir / "summary.json"
    atomic_write_json(campaign_summary_path, summary)

    legacy_summary_path = benchmarks_dir / "summary.json"
    atomic_write_json(legacy_summary_path, summary)

    # 5. Generación de checksums.sha256
    print("\n[4/4] Generando archivo de checksums SHA-256 de la campaña...")
    checksums_path = campaign_dir / "checksums.sha256"
    with open(checksums_path, "w", encoding="utf-8") as f:
        f.write(f"{compute_file_sha256(campaign_summary_path)}  summary.json\n")
        for i in range(1, num_processes + 1):
            p_path = campaign_raw_dir / f"process_{i}.json"
            f.write(f"{compute_file_sha256(p_path)}  raw/process_{i}.json\n")

    print(f"Campaña aislada guardada en: {campaign_dir.relative_to(repo_root)}")
    print(f"Resumen retrocompatible:     {legacy_summary_path.relative_to(repo_root)}")
    print(f"Checksums generados en:      {checksums_path.relative_to(repo_root)}")

    # 6. Visualización en tabla por consola
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
