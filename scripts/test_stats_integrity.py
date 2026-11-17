#!/usr/bin/env python3
"""
scripts/test_stats_integrity.py — Suite de pruebas de integridad estadística (STATS-INTEGRITY-01..10).

Verifica que el validador en `scripts/run_benchmarks.py` detecte e impida cualquier
inconsistencia matemática entre las muestras en bruto (batch_samples, run_means)
y las estructuras estadísticas agregadas (batch_stats, run_stats, summary.json).
"""

import copy
import math
import sys
import unittest
from pathlib import Path

script_dir = Path(__file__).resolve().parent
repo_root = script_dir.parent
sys.path.insert(0, str(script_dir))

from run_benchmarks import (
    EXPECTED_BATCH_SAMPLES,
    EXPECTED_SCENARIO_COUNT,
    SCHEMA_VERSION,
    STATS_SPEC_VERSION,
    compute_distribution_stats,
    validate_benchmark_process_data,
    validate_summary_against_processes,
)


def make_valid_process_payload(campaign_id="campaign_valid_001", process_id=1):
    """Construye un payload 100% consistente y matemáticamente verificado."""
    scenarios = []
    for sc_idx in range(EXPECTED_SCENARIO_COUNT):
        is_burst = sc_idx >= 14
        n_samples = 336 if is_burst else EXPECTED_BATCH_SAMPLES
        name = f"scenario_{sc_idx}" if not is_burst else f"ráfaga 960 op scenario_{sc_idx}"

        # 7 corridas con medias idénticas a 100.0 (o ligeramente distribuidas)
        run_means = [100.0] * 7
        run_stats = compute_distribution_stats(run_means)

        # Muestras de lotes que promedian exactamente 100.0
        # Simular variación suave
        batch_samples = [95.0, 105.0] * (n_samples // 2)
        if len(batch_samples) < n_samples:
            batch_samples.append(100.0)
        batch_stats = compute_distribution_stats(batch_samples)

        scenarios.append({
            "name": name,
            "batch_stats": batch_stats,
            "run_stats": run_stats,
            "run_means": run_means,
            "batch_samples": batch_samples,
            "counters": {
                "total_ops": 20000.0,
                "alloc_per_op": 1.0,
                "os_calls_per_op": 0.0,
                "header_bytes_per_op": 64.0,
                "commits_per_op": 0.0,
                "returns_per_op": 0.0,
                "hole_reuses_per_op": 0.0,
            },
        })

    return {
        "version": "v0.4",
        "schema_version": SCHEMA_VERSION,
        "stats_spec_version": STATS_SPEC_VERSION,
        "campaign_id": campaign_id,
        "process_id": str(process_id),
        "os": "windows",
        "arch": "x86_64",
        "profile": "release",
        "warmup": 500,
        "iterations": 20000,
        "runs": 7,
        "batch_size": 200,
        "scenarios": scenarios,
    }


def make_valid_campaign_data(campaign_id="campaign_valid_001"):
    """Construye 5 procesos válidos y su resumen agregado coherente."""
    process_data = [make_valid_process_payload(campaign_id, pid) for pid in range(1, 6)]
    num_scenarios = len(process_data[0]["scenarios"])
    consolidated_scenarios = []

    for sc_idx in range(num_scenarios):
        sc_name = process_data[0]["scenarios"][sc_idx]["name"]
        proc_means = [p["scenarios"][sc_idx]["batch_stats"]["mean"] for p in process_data]
        proc_stats = compute_distribution_stats(proc_means)

        pooled = []
        for p in process_data:
            pooled.extend(p["scenarios"][sc_idx]["batch_samples"])
        pooled_batch_stats = compute_distribution_stats(pooled)

        run_sds = [p["scenarios"][sc_idx]["run_stats"]["stddev_sample"] for p in process_data]
        avg_run_sd = round(sum(run_sds) / len(run_sds), 4)

        c_tmpl = process_data[0]["scenarios"][sc_idx]["counters"]
        avg_c = {}
        for k in c_tmpl:
            avg_c[k] = round(sum(p["scenarios"][sc_idx]["counters"][k] for p in process_data) / 5.0, 4)

        consolidated_scenarios.append({
            "name": sc_name,
            "cross_process_stats": proc_stats,
            "proc_means": proc_means,
            "pooled_batch_stats": pooled_batch_stats,
            "avg_run_stddev": avg_run_sd,
            "counters": avg_c,
        })

    summary = {
        "schema_version": SCHEMA_VERSION,
        "stats_spec_version": STATS_SPEC_VERSION,
        "campaign_id": campaign_id,
        "mode": "official",
        "metadata": {},
        "processes": [{"process_id": i} for i in range(1, 6)],
        "scenarios": consolidated_scenarios,
    }
    return process_data, summary


class TestStatisticalIntegrity(unittest.TestCase):
    """Verificación adversarial de STATS-INTEGRITY-01..10."""

    def test_stats_integrity_01_count_mismatch(self):
        """STATS-INTEGRITY-01: Rechazo si batch_stats['count'] no coincide con len(batch_samples)."""
        payload = make_valid_process_payload()
        payload["scenarios"][0]["batch_stats"]["count"] = 999
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(payload, "campaign_valid_001", 1)
        self.assertIn("count mismatch", str(ctx.exception))

    def test_stats_integrity_02_mean_tampered(self):
        """STATS-INTEGRITY-02: Rechazo si batch_stats['mean'] fue manipulado artificialmente."""
        payload = make_valid_process_payload()
        payload["scenarios"][0]["batch_stats"]["mean"] += 5.0
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(payload, "campaign_valid_001", 1)
        self.assertIn("field 'mean' mismatch", str(ctx.exception))

    def test_stats_integrity_03_median_tampered(self):
        """STATS-INTEGRITY-03: Rechazo si batch_stats['median'] o p50 no coinciden con la muestra."""
        payload = make_valid_process_payload()
        payload["scenarios"][0]["batch_stats"]["median"] = 120.0
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(payload, "campaign_valid_001", 1)
        self.assertIn("field 'median' mismatch", str(ctx.exception))

    def test_stats_integrity_04_min_max_tampered(self):
        """STATS-INTEGRITY-04: Rechazo si min o max en batch_stats no coinciden con extremos de muestra."""
        payload = make_valid_process_payload()
        payload["scenarios"][0]["batch_stats"]["max"] += 50.0
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(payload, "campaign_valid_001", 1)
        self.assertIn("field 'max' mismatch", str(ctx.exception))

    def test_stats_integrity_05_variance_tampered(self):
        """STATS-INTEGRITY-05: Rechazo si varianza muestral o poblacional difiere del recálculo."""
        payload = make_valid_process_payload()
        payload["scenarios"][0]["batch_stats"]["variance_sample"] = 0.0
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(payload, "campaign_valid_001", 1)
        self.assertIn("field 'variance_sample' mismatch", str(ctx.exception))

    def test_stats_integrity_06_stddev_tampered(self):
        """STATS-INTEGRITY-06: Rechazo si stddev_sample no coincide con la raíz de varianza de muestra."""
        payload = make_valid_process_payload()
        payload["scenarios"][0]["batch_stats"]["stddev_sample"] = 99.9
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(payload, "campaign_valid_001", 1)
        self.assertIn("field 'stddev_sample' mismatch", str(ctx.exception))

    def test_stats_integrity_07_cv_tampered(self):
        """STATS-INTEGRITY-07: Rechazo si coeficiente de variación (CV) no coincide con fórmula."""
        payload = make_valid_process_payload()
        payload["scenarios"][0]["batch_stats"]["cv_sample"] = 0.01
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(payload, "campaign_valid_001", 1)
        self.assertIn("field 'cv_sample' mismatch", str(ctx.exception))

    def test_stats_integrity_08_percentiles_tampered(self):
        """STATS-INTEGRITY-08: Rechazo si percentiles p95 o p99 difieren de la interpolación lineal."""
        payload = make_valid_process_payload()
        payload["scenarios"][0]["batch_stats"]["p95"] = 999.0
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(payload, "campaign_valid_001", 1)
        self.assertIn("field 'p95' mismatch", str(ctx.exception))

    def test_stats_integrity_09_run_means_and_run_stats_audit(self):
        """STATS-INTEGRITY-09: Rechazo si run_means tiene longitud incorrecta o run_stats no coincide."""
        payload = make_valid_process_payload()
        # Caso a: longitud distinta de 7
        p_len = copy.deepcopy(payload)
        p_len["scenarios"][0]["run_means"] = [100.0] * 5
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(p_len, "campaign_valid_001", 1)
        self.assertIn("expected 7 run_means", str(ctx.exception))

        # Caso b: run_stats manipulado
        p_stat = copy.deepcopy(payload)
        p_stat["scenarios"][0]["run_stats"]["mean"] = 500.0
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(p_stat, "campaign_valid_001", 1)
        self.assertIn("run_stats field 'mean' mismatch", str(ctx.exception))

        # Caso c: divergencia entre promedio de run_means y media de batch_samples
        p_div = copy.deepcopy(payload)
        p_div["scenarios"][0]["run_means"] = [120.0] * 7
        p_div["scenarios"][0]["run_stats"] = compute_distribution_stats([120.0] * 7)
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(p_div, "campaign_valid_001", 1)
        self.assertIn("does not match batch_samples mean", str(ctx.exception))

    def test_stats_integrity_10_summary_against_processes(self):
        """STATS-INTEGRITY-10: Rechazo si summary.json difiere matemáticamente de la agregación de procesos."""
        procs, summary = make_valid_campaign_data()
        # Validación normal pasa
        validate_summary_against_processes(summary, procs)

        # Alteración de proc_means en summary
        s_bad = copy.deepcopy(summary)
        s_bad["scenarios"][0]["proc_means"][0] += 10.0
        with self.assertRaises(ValueError):
            validate_summary_against_processes(s_bad, procs)

        # Alteración de pooled_batch_stats en summary
        s_pooled = copy.deepcopy(summary)
        s_pooled["scenarios"][0]["pooled_batch_stats"]["mean"] += 15.0
        with self.assertRaises(ValueError):
            validate_summary_against_processes(s_pooled, procs)


if __name__ == "__main__":
    unittest.main()
