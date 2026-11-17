#!/usr/bin/env python3
"""
scripts/run_benchmarks.py — Runner automatizado para microbenchmarks de NEXO v0.4.

Ejecuta 5 procesos de SO totalmente independientes (N=5) del ejecutable
`nexo-physical-bench --completo`, recolecta los datos brutos en formato JSON,
calcula estadísticas rigurosamente desagregadas (lotes N=700, corridas N=7, procesos N=5),
verifica las cotas matemáticas de Samuelson, audita la correspondencia muestra-estadística,
y gestiona la publicación transaccional en Fases A-E (aislamiento, ejecución, validación,
consolidación y publicación atómica con manifest y checksums).
"""

import argparse
import datetime
import hashlib
import json
import math
import os
import platform
import re
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSION = "v0.4.1"
STATS_SPEC_VERSION = "1.1.0"
EXPECTED_SCENARIO_COUNT = 16
EXPECTED_BATCH_SAMPLES = 700
FLOAT_TOLERANCE = 1e-3
FLOAT_REL_TOLERANCE = 1e-4


def is_stat_close(a: float, b: float, abs_tol: float = FLOAT_TOLERANCE, rel_tol: float = FLOAT_REL_TOLERANCE) -> bool:
    """Verifica paridad matemática permitiendo tolerancia absoluta y relativa en magnitudes elevadas."""
    return math.isclose(a, b, abs_tol=abs_tol, rel_tol=rel_tol)


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
    """Extrae metadatos precisos de Git (HEAD, branch, estado dirty, diff hash, untracked)."""
    git_head = "unknown"
    git_branch = "unknown"
    is_dirty = False
    git_error = False
    diff_bytes = b""
    diff_sha256 = None
    untracked_files = []

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
        git_error = True

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
        git_error = True

    try:
        res = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        status_lines = res.stdout.splitlines()
        for line in status_lines:
            line_str = line.strip()
            if line_str.startswith("??"):
                untracked_files.append(line_str[3:].strip())
                is_dirty = True
            elif len(line_str) > 0:
                is_dirty = True

        if len(status_lines) > 0:
            diff_res = subprocess.run(
                ["git", "diff", "HEAD"],
                cwd=repo_root,
                capture_output=True,
                check=True,
            )
            diff_bytes = diff_res.stdout
            if len(diff_bytes) > 0:
                is_dirty = True
                diff_sha256 = compute_bytes_sha256(diff_bytes)
    except Exception:
        git_error = True

    if len(untracked_files) > 0:
        is_dirty = True

    return {
        "git_head": git_head,
        "git_branch": git_branch,
        "git_dirty": is_dirty,
        "git_error": git_error,
        "git_diff_sha256": diff_sha256,
        "diff_bytes": diff_bytes,
        "untracked_files": untracked_files,
    }


def sanitize_campaign_id(raw_id: str, campaigns_dir: Path) -> str:
    """Valida y sanitiza estrictamente el identificador de campaña contra path traversal y colisiones."""
    if not raw_id or not isinstance(raw_id, str):
        raise ValueError("El identificador de campaña no puede estar vacío.")
    # Exclusivamente alfanuméricos, guiones y guiones bajos
    if not re.match(r"^[a-zA-Z0-9_-]+$", raw_id):
        raise ValueError(
            f"Identificador de campaña inválido '{raw_id}': solo se permiten caracteres [a-zA-Z0-9_-]."
        )
    candidate_path = (campaigns_dir / raw_id).resolve()
    resolved_campaigns = campaigns_dir.resolve()
    try:
        candidate_path.relative_to(resolved_campaigns)
    except ValueError:
        raise ValueError(
            f"Identificador de campaña inseguro '{raw_id}': intento de escape de directorio detectado."
        )
    if candidate_path.parent != resolved_campaigns:
        raise ValueError(
            f"Identificador de campaña inseguro '{raw_id}': no es hijo directo de {resolved_campaigns}."
        )
    if candidate_path.exists():
        raise ValueError(
            f"Conflicto de campaña: la carpeta '{raw_id}' ya existe en campaigns/. Debe ser única."
        )
    return raw_id


def determine_execution_mode(
    git_info: dict, force_official: bool = False, force_experimental: bool = False
) -> str:
    """
    Determina de forma fail-closed el modo de ejecución ('official' o 'experimental').

    Condiciones estrictas para 'official' (OFFICIAL-01..10):
    1. Ausencia de errores de Git (git_error == False).
    2. Commit HEAD válido (cadena hexadecimal de 40 caracteres correspondiente a un commit real).
    3. Worktree completamente limpio (git_dirty == False).
    4. Cero archivos sin seguimiento (untracked_files == []).

    Si force_official es True y alguna condición no se cumple, lanza ValueError.
    Si force_experimental es True, retorna 'experimental'.
    Por defecto, si todas las condiciones se cumplen retorna 'official', de lo contrario 'experimental'.
    """
    if force_official and force_experimental:
        raise ValueError("No se puede forzar simultáneamente el modo official y experimental.")

    reasons = []
    if git_info.get("git_error", False):
        reasons.append("Error en inspección de Git")

    git_head = git_info.get("git_head", "")
    if not isinstance(git_head, str) or not re.match(r"^[0-9a-f]{40}$", git_head):
        reasons.append(f"HEAD inválido o desconocido: '{git_head}'")

    if git_info.get("git_dirty", False):
        reasons.append("Worktree sucio (modificaciones locales detectadas)")

    untracked = git_info.get("untracked_files", [])
    if untracked:
        reasons.append(f"{len(untracked)} archivos no rastreados (untracked) presentes")

    is_clean = len(reasons) == 0

    if force_official:
        if not is_clean:
            raise ValueError(f"Fallo de requisitos para modo oficial: {'; '.join(reasons)}")
        return "official"

    if force_experimental:
        return "experimental"

    return "official" if is_clean else "experimental"


def create_exclusive_campaign_dir(campaigns_dir: Path, campaign_id: str) -> Path:
    """
    Crea de forma atómica y exclusiva el directorio de una campaña.

    Si el directorio ya existe, falla inmediatamente con FileExistsError,
    impidiendo cualquier sobreescritura accidental o colisión concurrente (CAMPAIGN-RACE).
    Una vez asegurada la exclusividad del directorio de la campaña, crea
    idempotentemente las subcarpetas requeridas (p. ej. 'raw').
    """
    campaign_dir = campaigns_dir / campaign_id
    try:
        os.mkdir(campaign_dir)
    except FileExistsError:
        raise FileExistsError(
            f"Colisión de campaña: el directorio '{campaign_dir}' ya existe. "
            "La creación de campañas debe ser estrictamente exclusiva."
        )
    (campaign_dir / "raw").mkdir(parents=True, exist_ok=True)
    return campaign_dir


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
    """
    Valida estrictamente los datos generados por un proceso independiente.
    
    Verifica:
    1. Esquema, versión de spec, campaign_id y process_id.
    2. Conteo de 16 escenarios sin nombres duplicados.
    3. Finitud estricta en todos los valores numéricos.
    4. Conteo de batch_samples (336 para ráfagas 960, 700 para otros).
    5. Recálculo independiente de 13 métricas desde batch_samples vs batch_stats (tol <= 1e-3).
    6. Conteo exacto de 7 run_means y recálculo de run_stats (tol <= 1e-3).
    7. Coherencia matemática entre promedio de run_means y media de batch_samples.
    8. Cumplimiento de cotas de Samuelson-Brunk.
    """
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

    metric_fields = [
        "mean",
        "median",
        "min",
        "max",
        "p50",
        "p95",
        "p99",
        "variance_sample",
        "variance_pop",
        "stddev_sample",
        "stddev_pop",
        "cv_sample",
        "cv_pop",
    ]

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
        run_means = sc.get("run_means")
        counters = sc.get("counters")

        if not isinstance(batch_stats, dict) or not isinstance(run_stats, dict):
            raise ValueError(f"Scenario '{name}' missing stats structures")
        if not isinstance(batch_samples, list) or not isinstance(counters, dict):
            raise ValueError(f"Scenario '{name}' missing samples or counters")
        if not isinstance(run_means, list):
            raise ValueError(f"Scenario '{name}' missing run_means list")

        expected_samples = 336 if "ráfaga 960" in name else EXPECTED_BATCH_SAMPLES
        if len(batch_samples) != expected_samples:
            raise ValueError(
                f"Scenario '{name}' expected {expected_samples} batch samples, got {len(batch_samples)}"
            )

        if len(run_means) != 7:
            raise ValueError(
                f"Scenario '{name}' expected 7 run_means, got {len(run_means)}"
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

        for m in run_means:
            if not isinstance(m, (int, float)) or not math.isfinite(m):
                raise ValueError(
                    f"Scenario '{name}' non-finite run_mean detected: {m}"
                )

        for key, val in counters.items():
            if not isinstance(val, (int, float)) or not math.isfinite(val):
                raise ValueError(
                    f"Scenario '{name}' non-finite counter field '{key}': {val}"
                )

        # 1. Recálculo estricto de batch_stats desde batch_samples
        recalc_batch = compute_distribution_stats(batch_samples)
        if batch_stats.get("count") != recalc_batch["count"]:
            raise ValueError(
                f"Scenario '{name}' batch_stats count mismatch: {batch_stats.get('count')} != {recalc_batch['count']}"
            )
        for field in metric_fields:
            rust_val = batch_stats.get(field)
            if rust_val is None and field == "p50":
                rust_val = batch_stats.get("median")
            calc_val = recalc_batch.get(field)
            if rust_val is None:
                raise ValueError(f"Scenario '{name}' batch_stats missing field '{field}'")
            if not is_stat_close(rust_val, calc_val):
                raise ValueError(
                    f"Scenario '{name}' batch_stats field '{field}' mismatch: "
                    f"Rust={rust_val}, Recalculated={calc_val}, diff={abs(rust_val - calc_val):.6f}"
                )

        # 2. Recálculo estricto de run_stats desde run_means
        recalc_runs = compute_distribution_stats(run_means)
        if run_stats.get("count") != 7:
            raise ValueError(
                f"Scenario '{name}' run_stats count mismatch: {run_stats.get('count')} != 7"
            )
        for field in metric_fields:
            rust_val = run_stats.get(field)
            if rust_val is None and field == "p50":
                rust_val = run_stats.get("median")
            calc_val = recalc_runs.get(field)
            if rust_val is None:
                raise ValueError(f"Scenario '{name}' run_stats missing field '{field}'")
            if not is_stat_close(rust_val, calc_val):
                raise ValueError(
                    f"Scenario '{name}' run_stats field '{field}' mismatch: "
                    f"Rust={rust_val}, Recalculated={calc_val}, diff={abs(rust_val - calc_val):.6f}"
                )

        # 3. Coherencia matemática entre promedio de run_means y media de batch_samples
        run_mean_avg = sum(run_means) / len(run_means)
        if not is_stat_close(run_mean_avg, recalc_batch["mean"]):
            raise ValueError(
                f"Scenario '{name}' run_means average ({run_mean_avg:.4f}) does not match "
                f"batch_samples mean ({recalc_batch['mean']:.4f}) within tolerance"
            )

        # 4. Verificar cota de Samuelson en batch_stats y run_stats
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


def validate_summary_against_processes(
    summary: dict, process_data: list[dict]
) -> None:
    """Valida que el resumen consolidado corresponda exacta y matemáticamente a los procesos brutos."""
    if not isinstance(summary, dict):
        raise ValueError("Summary must be a dict")
    scenarios = summary.get("scenarios")
    if not isinstance(scenarios, list) or len(scenarios) != EXPECTED_SCENARIO_COUNT:
        raise ValueError(f"Summary must contain exactly {EXPECTED_SCENARIO_COUNT} scenarios")
    num_procs = len(process_data)
    if num_procs != 5:
        raise ValueError(f"Expected exactly 5 process payloads, got {num_procs}")

    for sc_idx, sc_sum in enumerate(scenarios):
        sc_name = sc_sum.get("name")
        # 1. proc_means debe coincidir con la media de cada proceso
        proc_means_actual = [p["scenarios"][sc_idx]["batch_stats"]["mean"] for p in process_data]
        proc_means_sum = sc_sum.get("proc_means", [])
        if len(proc_means_sum) != num_procs:
            raise ValueError(f"Scenario '{sc_name}' proc_means count mismatch in summary")
        for i in range(num_procs):
            if not is_stat_close(proc_means_sum[i], proc_means_actual[i]):
                raise ValueError(f"Scenario '{sc_name}' proc_means[{i}] mismatch")

        # 2. cross_process_stats debe coincidir con estadísticas de proc_means
        calc_proc_stats = compute_distribution_stats(proc_means_actual)
        cross_stats = sc_sum.get("cross_process_stats", {})
        for metric in ["mean", "median", "min", "max", "stddev_sample", "cv_sample"]:
            if not is_stat_close(cross_stats.get(metric, 0.0), calc_proc_stats[metric]):
                raise ValueError(f"Scenario '{sc_name}' cross_process_stats '{metric}' mismatch")

        # 3. pooled_batch_stats debe coincidir con estadísticas de lotes acumulados
        expected_samples_per_proc = 336 if "ráfaga 960" in sc_name else EXPECTED_BATCH_SAMPLES
        expected_pooled_count = expected_samples_per_proc * num_procs
        pooled = []
        for p in process_data:
            pooled.extend(p["scenarios"][sc_idx]["batch_samples"])
        if len(pooled) != expected_pooled_count:
            raise ValueError(f"Scenario '{sc_name}' pooled samples count mismatch")
        calc_pooled_stats = compute_distribution_stats(pooled)
        pooled_stats = sc_sum.get("pooled_batch_stats", {})
        for metric in ["count", "mean", "median", "min", "max", "stddev_sample", "cv_sample"]:
            if metric == "count":
                if pooled_stats.get("count") != calc_pooled_stats["count"]:
                    raise ValueError(f"Scenario '{sc_name}' pooled count mismatch")
            else:
                if not is_stat_close(pooled_stats.get(metric, 0.0), calc_pooled_stats[metric]):
                    raise ValueError(f"Scenario '{sc_name}' pooled_batch_stats '{metric}' mismatch")

        # 4. avg_run_stddev debe coincidir con el promedio de stddev_sample de corridas
        calc_avg_run_sd = round(
            sum(p["scenarios"][sc_idx]["run_stats"]["stddev_sample"] for p in process_data) / num_procs,
            4,
        )
        if not is_stat_close(sc_sum.get("avg_run_stddev", 0.0), calc_avg_run_sd):
            raise ValueError(f"Scenario '{sc_name}' avg_run_stddev mismatch")

        # 5. counters deben coincidir con el promedio aritmético de contadores
        c_template = process_data[0]["scenarios"][sc_idx]["counters"]
        sum_counters = sc_sum.get("counters", {})
        for k in c_template:
            calc_c = round(sum(p["scenarios"][sc_idx]["counters"][k] for p in process_data) / num_procs, 4)
            if not is_stat_close(sum_counters.get(k, 0.0), calc_c):
                raise ValueError(f"Scenario '{sc_name}' counter '{k}' mismatch")


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


def atomic_write_text(target_path: Path, content: str) -> None:
    """Escribe un archivo de texto de forma atómica."""
    target_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = target_path.with_name(f"{target_path.name}.tmp.{os.getpid()}")
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            f.write(content)
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


def atomic_copy_file(src: Path, dest: Path) -> None:
    """Copia un archivo atómicamente a su destino."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = dest.with_name(f"{dest.name}.tmp.{os.getpid()}")
    try:
        shutil.copyfile(src, tmp_path)
        os.replace(tmp_path, dest)
    except Exception:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass
        raise


def parse_args():
    parser = argparse.ArgumentParser(
        description="NEXO v0.4 Microbenchmark Campaign Runner & Evidence Validator"
    )
    parser.add_argument(
        "--official",
        action="store_true",
        help="Ejecuta en modo oficial estricto (exige worktree de git 100%% limpio).",
    )
    parser.add_argument(
        "--experimental",
        action="store_true",
        help="Fuerza modo experimental incluso si el worktree está limpio.",
    )
    parser.add_argument(
        "--processes",
        type=int,
        default=5,
        help="Número de procesos independientes de SO a ejecutar (defecto: 5).",
    )
    parser.add_argument(
        "--campaign-id",
        type=str,
        default=None,
        help="Identificador explícito de campaña (si se omite, se genera por timestamp y entropía).",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    benchmarks_dir = repo_root / "docs" / "benchmarks"

    # Git metadata
    git_info = get_git_info(repo_root)

    # Verificación de modo oficial vs experimental con clasificación fail-closed (OFFICIAL-01..10)
    try:
        execution_mode = determine_execution_mode(
            git_info,
            force_official=args.official,
            force_experimental=args.experimental,
        )
    except ValueError as e:
        print(f"ERROR CRÍTICO (OFFICIAL-VERIFY): {e}")
        sys.exit(1)

    campaigns_dir = benchmarks_dir / "campaigns"
    campaigns_dir.mkdir(parents=True, exist_ok=True)

    # Generar / sanitizar identificador único de campaña
    if args.campaign_id:
        try:
            campaign_id = sanitize_campaign_id(args.campaign_id, campaigns_dir)
        except ValueError as e:
            print(f"ERROR CRÍTICO (CAMPAIGN-SANITY): {e}")
            sys.exit(1)
    else:
        timestamp_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d_%H%M%S")
        random_hex = secrets.token_hex(4)
        campaign_id = f"campaign_{timestamp_str}_{random_hex}"

    print("=" * 80)
    print("NEXO v0.4 — CAMPAÑA DE MICROBENCHMARKS Y VALIDACIÓN DE EVIDENCIAS")
    print(f"Campaña ID:       {campaign_id}")
    print(f"Modo:             {execution_mode.upper()}")
    print("=" * 80)

    # -------------------------------------------------------------
    # FASE A: Preparación y Aislamiento Transaccional
    # -------------------------------------------------------------
    print("\n[FASE A] Preparando aislamiento transaccional en carpeta de campaña...")
    try:
        campaign_dir = create_exclusive_campaign_dir(campaigns_dir, campaign_id)
    except FileExistsError as e:
        print(f"ERROR CRÍTICO (CAMPAIGN-RACE): {e}")
        sys.exit(1)
    campaign_raw_dir = campaign_dir / "raw"

    # En modo experimental con cambios, guardar patch.diff y respaldar archivos untracked
    untracked_backed_up = []
    if git_info["git_dirty"]:
        patch_path = campaign_dir / "patch.diff"
        with open(patch_path, "wb") as f:
            f.write(git_info["diff_bytes"])
        print(f"  -> Diff local guardado en {patch_path.name} (SHA-256: {git_info['git_diff_sha256']})")

    if git_info["untracked_files"]:
        untracked_path = campaign_dir / "untracked_files.txt"
        with open(untracked_path, "w", encoding="utf-8") as f:
            for uf in git_info["untracked_files"]:
                f.write(f"{uf}\n")
        print(f"  -> {len(git_info['untracked_files'])} archivos untracked registrados en {untracked_path.name}")

        # P2-C: Empaquetar contenido real de archivos untracked para reproducibilidad experimental
        untracked_bundle_dir = campaign_dir / "untracked_bundle"
        for uf in git_info["untracked_files"]:
            src_file = repo_root / uf
            if src_file.is_file():
                dst_file = untracked_bundle_dir / uf
                dst_file.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src_file, dst_file)
                untracked_backed_up.append(uf)
        if untracked_backed_up:
            print(f"  -> {len(untracked_backed_up)} archivos untracked empaquetados en untracked_bundle/")

    rustc_info = get_rustc_info()
    env_meta = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "campaign_id": campaign_id,
        "mode": execution_mode,
        "schema_version": SCHEMA_VERSION,
        "stats_spec_version": STATS_SPEC_VERSION,
        "profile": "release",
        "git_head": git_info["git_head"],
        "git_branch": git_info["git_branch"],
        "git_dirty": git_info["git_dirty"],
        "git_diff_sha256": git_info["git_diff_sha256"],
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
    print(f"Target Triple:    {rustc_info['target_triple']}")
    print(f"SO:               {env_meta['os_name']} {env_meta['os_release']} ({env_meta['architecture']})")

    # Compilar binario release si no existe o para asegurar paridad
    print("\n[FASE A.2] Compilando binario de benchmarks en release profile...")
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
    env_meta["binary_sha256"] = binary_sha256_pre
    print(f"Binario ejecutable SHA-256 (pre): {binary_sha256_pre}")

    # -------------------------------------------------------------
    # FASE B: Ejecución Aislada de Procesos de SO
    # -------------------------------------------------------------
    num_processes = args.processes
    print(f"\n[FASE B] Ejecutando {num_processes} procesos independientes de SO (N={num_processes})...")
    processes_meta = []
    process_data = []

    for i in range(1, num_processes + 1):
        out_json_path = campaign_raw_dir / f"process_{i}.json"
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

        file_sha256 = compute_file_sha256(out_json_path)
        processes_meta.append({
            "process_id": i,
            "exit_code": proc.returncode,
            "wall_duration_seconds": round(elapsed, 3),
            "output_json": str(out_json_path.relative_to(repo_root)).replace("\\", "/"),
            "sha256": file_sha256,
        })
        process_data.append(data)
        print(f"     Proceso {i} completado en {elapsed:.2f}s (SHA-256: {file_sha256[:12]}...).")

    # -------------------------------------------------------------
    # FASE C: Validación Exhaustiva de Invariantes y Recálculo
    # -------------------------------------------------------------
    print("\n[FASE C] Validando estrictamente invariantes, muestras y recálculo estadístico...")
    for i, data in enumerate(process_data, start=1):
        try:
            validate_benchmark_process_data(data, campaign_id, i)
            print(f"  -> Proceso {i}: validación estructural, muestras N=700/336 y run_means N=7 verificados.")
        except Exception as e:
            print(f"ERROR CRÍTICO en validación de proceso {i}: {e}")
            sys.exit(1)

    # -------------------------------------------------------------
    # FASE D: Consolidación y Verificación Matemática
    # -------------------------------------------------------------
    print("\n[FASE D] Consolidando datos y verificando agregación multi-proceso...")
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
        "mode": execution_mode,
        "metadata": env_meta,
        "processes": processes_meta,
        "scenarios": consolidated_scenarios,
    }

    try:
        validate_summary_against_processes(summary, process_data)
        print("  -> Verificación matemática cruzada de summary.json contra procesos individuales: EXITOSA.")
    except Exception as e:
        print(f"ERROR CRÍTICO en agregación de summary: {e}")
        sys.exit(1)

    # -------------------------------------------------------------
    # FASE E: Publicación Transaccional, Manifiesto y Checksums
    # -------------------------------------------------------------
    print("\n[FASE E] Publicación transaccional: manifest, checksums y actualización atómica...")
    campaign_summary_path = campaign_dir / "summary.json"
    atomic_write_json(campaign_summary_path, summary)

    # Generar manifiesto de campaña (manifest.json)
    manifest = {
        "campaign_id": campaign_id,
        "mode": execution_mode,
        "schema_version": SCHEMA_VERSION,
        "stats_spec_version": STATS_SPEC_VERSION,
        "timestamp": env_meta["timestamp"],
        "binary_sha256": binary_sha256_pre,
        "git": {
            "head": git_info["git_head"],
            "branch": git_info["git_branch"],
            "dirty": git_info["git_dirty"],
            "diff_sha256": git_info["git_diff_sha256"],
        },
        "reproducibility": {
            "status": "official_clean" if execution_mode == "official" else (
                "experimental_bundled" if git_info["git_dirty"] and not git_info.get("git_error") else "unreproducible"
            ),
            "reproducible_from_artifacts": (execution_mode == "official") or (
                git_info["git_dirty"] and not git_info.get("git_error") and (len(git_info["untracked_files"]) == len(untracked_backed_up))
            ),
            "dirty": git_info["git_dirty"],
            "has_diff": len(git_info["diff_bytes"]) > 0,
            "untracked_count": len(git_info["untracked_files"]),
            "untracked_bundled_count": len(untracked_backed_up),
        },
        "files": {
            "summary.json": compute_file_sha256(campaign_summary_path),
        },
    }
    for i in range(1, num_processes + 1):
        p_path = campaign_raw_dir / f"process_{i}.json"
        manifest["files"][f"raw/process_{i}.json"] = compute_file_sha256(p_path)

    if git_info["git_dirty"] and (campaign_dir / "patch.diff").exists():
        manifest["files"]["patch.diff"] = compute_file_sha256(campaign_dir / "patch.diff")
    if git_info["untracked_files"] and (campaign_dir / "untracked_files.txt").exists():
        manifest["files"]["untracked_files.txt"] = compute_file_sha256(campaign_dir / "untracked_files.txt")
    for uf in untracked_backed_up:
        b_file = campaign_dir / "untracked_bundle" / uf
        if b_file.exists():
            rel_b = f"untracked_bundle/{uf}".replace("\\", "/")
            manifest["files"][rel_b] = compute_file_sha256(b_file)

    manifest_path = campaign_dir / "manifest.json"
    atomic_write_json(manifest_path, manifest)

    # Generar checksums.sha256 de la campaña
    checksums_path = campaign_dir / "checksums.sha256"
    checksum_lines = []
    for rel_name, sha in manifest["files"].items():
        checksum_lines.append(f"{sha}  {rel_name}\n")
    checksum_lines.append(f"{compute_file_sha256(manifest_path)}  manifest.json\n")
    atomic_write_text(checksums_path, "".join(checksum_lines))

    # P1-B: VERIFICACIÓN CRIPTOGRÁFICA DE INTEGRIDAD PREVIA A PUBLICACIÓN
    # Asegurar que todos los archivos en el manifest concuerdan con su hash calculado
    for rel_name, exp_sha in manifest["files"].items():
        act_sha = compute_file_sha256(campaign_dir / rel_name)
        if act_sha != exp_sha:
            raise ValueError(f"Fallo de integridad pre-publicación en '{rel_name}': {act_sha} != {exp_sha}")

    # P1-B: ACTUALIZACIÓN DE RUTAS DERIVADAS RETROCOMPATIBLES
    legacy_summary_path = benchmarks_dir / "summary.json"
    atomic_write_json(legacy_summary_path, summary)

    legacy_raw_dir = benchmarks_dir / "raw"
    legacy_raw_dir.mkdir(parents=True, exist_ok=True)
    for i in range(1, num_processes + 1):
        src_p = campaign_raw_dir / f"process_{i}.json"
        dst_p = legacy_raw_dir / f"process_{i}.json"
        atomic_copy_file(src_p, dst_p)

    # P1-B: SINGLE SOURCE OF TRUTH COMMIT POINT (LATEST_CAMPAIGN)
    # LATEST_CAMPAIGN se actualiza al final de forma atómica como único punto de confirmación
    latest_campaign_path = benchmarks_dir / "LATEST_CAMPAIGN"
    atomic_write_text(latest_campaign_path, f"{campaign_id}\n")

    print(f"  -> Campaña aislada completada: {campaign_dir.relative_to(repo_root)}")
    print(f"  -> Resumen público actualizado: {legacy_summary_path.relative_to(repo_root)}")
    print(f"  -> Manifiesto y Checksums generados y verificados.")
    print(f"  -> LATEST_CAMPAIGN comprometido atómicamente: {campaign_id}")

    # Visualización en tabla por consola
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
