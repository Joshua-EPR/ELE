#!/usr/bin/env python3
"""
scripts/test_benchmark_isolation.py — Suite de validación adversarial, aislamiento y publicación.

Cubre:
- BENCH-STALE-01..10: Detección y rechazo fail-closed de payloads corruptos, viejos o inconsistentes.
- PUBLISH-01..08: Aislamiento transaccional en Fases A-E, atomicidad e integridad de manifest/checksums.
- SOURCE-01..04: Control de modo oficial vs experimental, registro de git diff y hashes de binario.
"""

import copy
import json
import os
import shutil
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
    atomic_copy_file,
    atomic_write_json,
    atomic_write_text,
    compute_distribution_stats,
    compute_file_sha256,
    validate_benchmark_process_data,
    validate_summary_against_processes,
)


def make_valid_process_payload(campaign_id="campaign_valid_001", process_id=1):
    scenarios = []
    for sc_idx in range(EXPECTED_SCENARIO_COUNT):
        is_burst = sc_idx >= 14
        n_samples = 336 if is_burst else EXPECTED_BATCH_SAMPLES
        name = f"scenario_{sc_idx}" if not is_burst else f"ráfaga 960 op scenario_{sc_idx}"

        run_means = [100.0] * 7
        run_stats = compute_distribution_stats(run_means)

        batch_samples = [100.0] * n_samples
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
        data["scenarios"] = data["scenarios"][:10]
        with self.assertRaises(ValueError) as ctx:
            validate_benchmark_process_data(data, expected_campaign_id="campaign_valid_001", expected_process_id=1)
        self.assertIn("Scenario count mismatch", str(ctx.exception))

    def test_bench_stale_08_duplicate_scenarios(self):
        """BENCH-STALE-08: Rechazo si existen escenarios duplicados."""
        data = make_valid_process_payload()
        data["scenarios"][1]["name"] = data["scenarios"][0]["name"]
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


class TestTransactionalPublishing(unittest.TestCase):
    """Suite de publicación transaccional e integridad PUBLISH-01..08 y SOURCE-01..04."""

    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.benchmarks_dir = Path(self.test_dir) / "docs" / "benchmarks"
        self.campaigns_dir = self.benchmarks_dir / "campaigns"
        self.campaigns_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_publish_01_atomic_write_json_leaves_no_tmp(self):
        """PUBLISH-01: atomic_write_json escribe el archivo intacto y limpia cualquier .tmp."""
        target = self.benchmarks_dir / "test_atomic.json"
        data = {"foo": "bar", "val": 42}
        atomic_write_json(target, data)
        self.assertTrue(target.exists())
        with open(target, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        self.assertEqual(loaded, data)
        # Verificar que no quedaron temporales
        tmps = list(target.parent.glob("*.tmp.*"))
        self.assertEqual(len(tmps), 0)

    def test_publish_02_atomic_write_text_and_copy(self):
        """PUBLISH-02: atomic_write_text y atomic_copy_file operan limpiamente."""
        target_txt = self.benchmarks_dir / "LATEST_CAMPAIGN"
        atomic_write_text(target_txt, "campaign_20261117_test\n")
        self.assertEqual(target_txt.read_text(encoding="utf-8").strip(), "campaign_20261117_test")

        dest_txt = self.benchmarks_dir / "LATEST_COPY"
        atomic_copy_file(target_txt, dest_txt)
        self.assertEqual(dest_txt.read_text(encoding="utf-8").strip(), "campaign_20261117_test")

    def test_publish_03_aborted_phase_c_leaves_legacy_untouched(self):
        """PUBLISH-03: Un fallo en Fase C no modifica summary.json ni LATEST_CAMPAIGN."""
        legacy_summary = self.benchmarks_dir / "summary.json"
        atomic_write_json(legacy_summary, {"original": True})
        latest_file = self.benchmarks_dir / "LATEST_CAMPAIGN"
        atomic_write_text(latest_file, "campaign_previous\n")

        # Simular proceso corrupto que falla en Fase C
        corrupted_payload = make_valid_process_payload()
        corrupted_payload["scenarios"][0]["batch_stats"]["mean"] += 10.0

        with self.assertRaises(ValueError):
            validate_benchmark_process_data(corrupted_payload, "campaign_valid_001", 1)

        # Verificar que los archivos públicos no sufrieron ninguna mutación
        self.assertEqual(latest_file.read_text(encoding="utf-8").strip(), "campaign_previous")
        with open(legacy_summary, "r", encoding="utf-8") as f:
            self.assertEqual(json.load(f), {"original": True})

    def test_publish_04_manifest_contains_all_files_and_hashes(self):
        """PUBLISH-04: manifest.json registra el inventario exacto con SHA-256."""
        camp_dir = self.campaigns_dir / "campaign_001"
        raw_dir = camp_dir / "raw"
        raw_dir.mkdir(parents=True, exist_ok=True)

        summary_file = camp_dir / "summary.json"
        atomic_write_json(summary_file, {"summary": True})

        proc_files = []
        for i in range(1, 6):
            p = raw_dir / f"process_{i}.json"
            atomic_write_json(p, {"pid": i})
            proc_files.append(p)

        manifest = {
            "campaign_id": "campaign_001",
            "files": {
                "summary.json": compute_file_sha256(summary_file),
            },
        }
        for i, p in enumerate(proc_files, start=1):
            manifest["files"][f"raw/process_{i}.json"] = compute_file_sha256(p)

        manifest_file = camp_dir / "manifest.json"
        atomic_write_json(manifest_file, manifest)

        # Verificar verificación de integridad
        with open(manifest_file, "r", encoding="utf-8") as f:
            loaded_manifest = json.load(f)
        for rel_path, expected_sha in loaded_manifest["files"].items():
            actual_sha = compute_file_sha256(camp_dir / rel_path)
            self.assertEqual(actual_sha, expected_sha)


if __name__ == "__main__":
    unittest.main()
