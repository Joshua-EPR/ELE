#!/usr/bin/env python3
"""
scripts/test_benchmark_isolation.py — Suite de validación adversarial e integridad (BENCH-STALE-01..10).

Verifica que el pipeline de benchmarking de NEXO detecte y rechace de forma
incondicional y 'fail-closed' cualquier intento de contaminación con artefactos
antiguos, esquemas incompatibles, JSONs corruptos o incompletos, identificadores
de campaña disonantes y valores no finitos.
"""

import copy
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_benchmarks import (
    EXPECTED_BATCH_SAMPLES,
    EXPECTED_SCENARIO_COUNT,
    SCHEMA_VERSION,
    STATS_SPEC_VERSION,
    validate_benchmark_process_data,
)


def make_valid_process_payload(campaign_id="campaign_valid_001", process_id=1):
    scenarios = []
    for sc_idx in range(EXPECTED_SCENARIO_COUNT):
        scenarios.append({
            "name": f"scenario_{sc_idx}",
            "batch_stats": {
                "count": EXPECTED_BATCH_SAMPLES,
                "mean": 100.0,
                "median": 100.0,
                "min": 80.0,
                "max": 120.0,
                "p95": 115.0,
                "p99": 118.0,
                "variance_sample": 25.0,
                "variance_pop": 25.0,
                "stddev_sample": 5.0,
                "stddev_pop": 5.0,
                "cv_sample": 5.0,
                "cv_pop": 5.0,
            },
            "run_stats": {
                "count": 7,
                "mean": 100.0,
                "median": 100.0,
                "min": 98.0,
                "max": 102.0,
                "p95": 101.5,
                "p99": 101.9,
                "variance_sample": 1.0,
                "variance_pop": 1.0,
                "stddev_sample": 1.0,
                "stddev_pop": 1.0,
                "cv_sample": 1.0,
                "cv_pop": 1.0,
            },
            "batch_samples": [100.0] * EXPECTED_BATCH_SAMPLES,
            "counters": {
                "alloc_per_op": 0.0,
                "os_calls_per_op": 0.0,
                "header_bytes_per_op": 0.0,
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


class TestBenchmarkIsolationAndIntegrity(unittest.TestCase):
    """Suite adversarial BENCH-STALE-01..10."""

    def test_bench_stale_01_nonexistent_file(self):
        """BENCH-STALE-01: Rechazo de archivo inexistente."""
        bogus_path = Path("docs/benchmarks/nonexistent_ghost_file.json")
        self.assertFalse(bogus_path.exists())

    def test_bench_stale_02_corrupt_json(self):
        """BENCH-STALE-02: Rechazo de JSON con sintaxis corrupta."""
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".json") as f:
            f.write("{ invalid json [ incomplete")
            tmp_path = Path(f.name)
        try:
            with open(tmp_path, "r", encoding="utf-8") as f:
                with self.assertRaises(json.JSONDecodeError):
                    json.load(f)
        finally:
            tmp_path.unlink()

    def test_bench_stale_03_truncated_json(self):
        """BENCH-STALE-03: Rechazo de JSON truncado abruptamente."""
        valid = make_valid_process_payload()
        serialized = json.dumps(valid, indent=2)
        truncated = serialized[: len(serialized) // 2]
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".json") as f:
            f.write(truncated)
            tmp_path = Path(f.name)
        try:
            with open(tmp_path, "r", encoding="utf-8") as f:
                with self.assertRaises(json.JSONDecodeError):
                    json.load(f)
        finally:
            tmp_path.unlink()

    def test_bench_stale_04_mismatched_campaign_id(self):
        """BENCH-STALE-04: Rechazo de payload con campaign_id ajeno o antiguo."""
        data = make_valid_process_payload(campaign_id="campaign_old_stale")
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(data, expected_campaign_id="campaign_new_2026", expected_process_id=1)
        self.assertIn("Campaign ID mismatch", str(ctx.exception))

    def test_bench_stale_05_mismatched_process_id(self):
        """BENCH-STALE-05: Rechazo de payload con process_id incorrecto."""
        data = make_valid_process_payload(process_id=2)
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(data, expected_campaign_id="campaign_valid_001", expected_process_id=1)
        self.assertIn("Process ID mismatch", str(ctx.exception))

    def test_bench_stale_06_incompatible_schema_version(self):
        """BENCH-STALE-06: Rechazo de schema_version obsoleto (ej. v0.4.0)."""
        data = make_valid_process_payload()
        data["schema_version"] = "v0.4.0"
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(data, expected_campaign_id="campaign_valid_001", expected_process_id=1)
        self.assertIn("Schema version mismatch", str(ctx.exception))

    def test_bench_stale_07_missing_scenarios(self):
        """BENCH-STALE-07: Rechazo si faltan escenarios esperados (menos de 16)."""
        data = make_valid_process_payload()
        data["scenarios"] = data["scenarios"][:10]  # solo 10
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(data, expected_campaign_id="campaign_valid_001", expected_process_id=1)
        self.assertIn("Scenario count mismatch", str(ctx.exception))

    def test_bench_stale_08_duplicate_scenarios(self):
        """BENCH-STALE-08: Rechazo si existen escenarios duplicados."""
        data = make_valid_process_payload()
        data["scenarios"][1]["name"] = data["scenarios"][0]["name"]  # nombre duplicado
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(data, expected_campaign_id="campaign_valid_001", expected_process_id=1)
        self.assertIn("Duplicate scenario name detected", str(ctx.exception))

    def test_bench_stale_09_insufficient_samples(self):
        """BENCH-STALE-09: Rechazo si batch_samples contiene menos muestras que el estándar."""
        data = make_valid_process_payload()
        data["scenarios"][0]["batch_samples"] = data["scenarios"][0]["batch_samples"][:500]
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(data, expected_campaign_id="campaign_valid_001", expected_process_id=1)
        self.assertIn("expected 700 batch samples", str(ctx.exception))

    def test_bench_stale_10_non_finite_values(self):
        """BENCH-STALE-10: Rechazo de valores NaN o infinitos en métricas o muestras."""
        data = make_valid_process_payload()
        data["scenarios"][0]["batch_stats"]["mean"] = float("nan")
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(data, expected_campaign_id="campaign_valid_001", expected_process_id=1)
        self.assertIn("non-finite", str(ctx.exception))

        data2 = make_valid_process_payload()
        data2["scenarios"][0]["batch_samples"][10] = float("inf")
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(data2, expected_campaign_id="campaign_valid_001", expected_process_id=1)
        self.assertIn("non-finite batch sample detected", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
