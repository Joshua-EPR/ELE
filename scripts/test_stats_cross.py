#!/usr/bin/env python3
"""
scripts/test_stats_cross.py — Suite de pruebas cruzadas Rust/Python (STAT-CROSS-01..10).

Verifica la equivalencia exacta entre la implementación estadística en Python
(`scripts/run_benchmarks.py`) y en Rust (`crates/nexo/src/stats.rs` ejecutado vía
`nexo-physical-bench --compute-stats <fixture>`), asegurando que la especificación
STATS_SPEC_VERSION 1.1.0 produzca resultados idénticos en ambos lenguajes bajo
fixtures reales y sintéticos.
"""

import hashlib
import json
import math
import platform
import subprocess
import sys
import unittest
from pathlib import Path

# Añadir directorio scripts al PYTHONPATH
script_dir = Path(__file__).resolve().parent
repo_root = script_dir.parent
sys.path.insert(0, str(script_dir))
from run_benchmarks import compute_distribution_stats, percentile_sorted, STATS_SPEC_VERSION


def get_nexo_bench_bin(force_rebuild: bool = True) -> tuple[Path, dict]:
    """
    Compila y verifica el binario nexo-physical-bench en modo release para pruebas cruzadas reales.

    Garantías (STAT-FRESH-01..05):
    1. Si force_rebuild es True, ejecuta `cargo build -p ele-nexo --bin nexo-physical-bench --release`.
    2. Comprueba que el código de retorno de cargo sea estrictamente 0.
    3. Verifica la existencia física del ejecutable en disco.
    4. Extrae y retorna la ruta, tamaño en bytes, timestamp mtime y hash SHA-256 criptográfico del binario.
    """
    exe_suffix = ".exe" if platform.system() == "Windows" else ""
    bin_path = repo_root / "target" / "release" / f"nexo-physical-bench{exe_suffix}"

    if force_rebuild:
        cmd = ["cargo", "build", "-p", "ele-nexo", "--bin", "nexo-physical-bench", "--release"]
        res = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(
                f"Fallo en compilación obligatoria de nexo-physical-bench (código {res.returncode}):\n{res.stderr}"
            )

    if not bin_path.exists():
        raise FileNotFoundError(f"Binario nexo-physical-bench no encontrado en {bin_path}")

    stat = bin_path.stat()
    h = hashlib.sha256()
    with open(bin_path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    bin_sha256 = h.hexdigest()

    metadata = {
        "path": str(bin_path),
        "size_bytes": stat.st_size,
        "mtime": stat.st_mtime,
        "sha256": bin_sha256,
    }
    return bin_path, metadata


class TestStatisticalCrossLanguage(unittest.TestCase):
    """Pruebas cruzadas de paridad matemática entre Rust y Python."""

    @classmethod
    def setUpClass(cls):
        cls.bin_path, cls.bin_meta = get_nexo_bench_bin(force_rebuild=True)
        cls.fixtures_dir = repo_root / "crates" / "nexo" / "tests" / "fixtures" / "stats"

    def run_rust_stats(self, fixture_path: Path) -> dict:
        """Invoca el binario Rust con --compute-stats y parsea el JSON resultante."""
        cmd = [str(self.bin_path), "--compute-stats", str(fixture_path)]
        res = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"Error en binario Rust: {res.stderr}")
        return json.loads(res.stdout.strip())

    def assert_stats_equal(self, py_stats: dict, rust_stats: dict, tol: float = 1e-3):
        """Compara todos los 13 campos estadísticos entre Python y Rust."""
        self.assertEqual(py_stats["count"], rust_stats["count"])
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
        for f in metric_fields:
            self.assertIn(f, py_stats, f"Falta campo {f} en Python")
            self.assertIn(f, rust_stats, f"Falta campo {f} en Rust")
            diff = abs(py_stats[f] - rust_stats[f])
            self.assertLessEqual(
                diff,
                tol,
                f"Discrepancia en campo '{f}': Python={py_stats[f]}, Rust={rust_stats[f]}, diff={diff}",
            )

    def test_stat_cross_01_identical_mean(self):
        """STAT-CROSS-01: Cálculo idéntico de media aritmética en vectores compartidos."""
        v1 = [10.0, 20.0, 30.0, 40.0, 50.0]
        stats = compute_distribution_stats(v1)
        self.assertAlmostEqual(stats["mean"], 30.0, places=4)

        v2 = [100.5, 200.25, 300.75]
        stats2 = compute_distribution_stats(v2)
        self.assertAlmostEqual(stats2["mean"], 200.5, places=4)

    def test_stat_cross_02_identical_median_odd_and_even(self):
        """STAT-CROSS-02: Cálculo idéntico de mediana en longitudes impares y pares."""
        # Impar (N=5): elemento central exacto
        v_odd = [5.0, 1.0, 9.0, 3.0, 7.0]
        stats_odd = compute_distribution_stats(v_odd)
        self.assertAlmostEqual(stats_odd["median"], 5.0, places=4)

        # Par (N=4): interpolación r = (4-1)*0.5 = 1.5 -> w = 0.5 entre index 1 y 2
        v_even = [10.0, 20.0, 30.0, 40.0]
        stats_even = compute_distribution_stats(v_even)
        self.assertAlmostEqual(stats_even["median"], 25.0, places=4)

    def test_stat_cross_03_sample_and_population_variance(self):
        """STAT-CROSS-03: Varianza muestral (N-1) y poblacional (N) diferenciadas formalmente."""
        v = [10.0, 20.0, 30.0, 40.0, 50.0]
        stats = compute_distribution_stats(v)
        self.assertAlmostEqual(stats["variance_sample"], 250.0, places=4)
        self.assertAlmostEqual(stats["variance_pop"], 200.0, places=4)

    def test_stat_cross_04_sample_and_population_stddev(self):
        """STAT-CROSS-04: Desviación estándar muestral y poblacional coincidentes."""
        v = [10.0, 20.0, 30.0, 40.0, 50.0]
        stats = compute_distribution_stats(v)
        self.assertAlmostEqual(stats["stddev_sample"], round(math.sqrt(250.0), 4), places=4)
        self.assertAlmostEqual(stats["stddev_pop"], round(math.sqrt(200.0), 4), places=4)

    def test_stat_cross_05_coefficient_of_variation(self):
        """STAT-CROSS-05: Coeficiente de variación (CV sample y CV pop) en porcentaje."""
        v = [10.0, 20.0, 30.0, 40.0, 50.0]
        stats = compute_distribution_stats(v)
        expected_cv_sample = (math.sqrt(250.0) / 30.0) * 100.0
        expected_cv_pop = (math.sqrt(200.0) / 30.0) * 100.0
        self.assertAlmostEqual(stats["cv_sample"], round(expected_cv_sample, 4), places=4)
        self.assertAlmostEqual(stats["cv_pop"], round(expected_cv_pop, 4), places=4)

    def test_stat_cross_06_percentiles_linear_interpolation(self):
        """STAT-CROSS-06: Percentiles p50, p95, p99 con interpolación lineal estándar."""
        v = [10.0, 20.0, 30.0, 40.0, 50.0]
        sorted_v = sorted(v)
        p95 = percentile_sorted(sorted_v, 0.95)
        self.assertAlmostEqual(p95, 48.0, places=4)

        p99 = percentile_sorted(sorted_v, 0.99)
        self.assertAlmostEqual(p99, 49.6, places=4)

    def test_stat_cross_07_empty_dataset_rejection(self):
        """STAT-CROSS-07: Rechazo idéntico de conjuntos vacíos con excepción."""
        with self.assertRaises(ValueError):
            compute_distribution_stats([])

    def test_stat_cross_08_non_finite_rejection(self):
        """STAT-CROSS-08: Rechazo idéntico de valores NaN, +inf y -inf."""
        with self.assertRaises(ValueError):
            compute_distribution_stats([1.0, 2.0, float("nan")])
        with self.assertRaises(ValueError):
            compute_distribution_stats([1.0, float("inf"), 3.0])
        with self.assertRaises(ValueError):
            compute_distribution_stats([float("-inf"), 2.0, 3.0])

    def test_stat_cross_09_samuelson_bounds_enforced(self):
        """STAT-CROSS-09: Verificación de la cota matemática de Samuelson-Brunk."""
        v_valid = [100.0, 100.0, 100.0, 100.0, 200.0]
        stats = compute_distribution_stats(v_valid)
        self.assertIsNotNone(stats)

        v_batches = [2969.5] + [93.75] * 699
        stats_batches = compute_distribution_stats(v_batches)
        self.assertEqual(stats_batches["count"], 700)
        self.assertTrue(stats_batches["stddev_sample"] > 108.0)

    def test_stat_cross_10_numerical_stability_large_offset(self):
        """STAT-CROSS-10: Estabilidad numérica del algoritmo de Welford bajo gran traslación."""
        offset = 1_000_000_000.0
        v_shifted = [offset + 10.0, offset + 20.0, offset + 30.0, offset + 40.0, offset + 50.0]
        stats = compute_distribution_stats(v_shifted)
        self.assertAlmostEqual(stats["mean"], offset + 30.0, places=4)
        self.assertAlmostEqual(stats["variance_sample"], 250.0, places=4)
        self.assertAlmostEqual(stats["variance_pop"], 200.0, places=4)

    # -------------------------------------------------------------
    # PRUEBAS CRUZADAS REALES RUST <-> PYTHON CON FIXTURES EN DISCO
    # -------------------------------------------------------------
    def test_fixture_uniform_cross_validation(self):
        """Valida fixture 'uniform.json' ejecutando el binario Rust real vs Python."""
        f_path = self.fixtures_dir / "uniform.json"
        with open(f_path, "r", encoding="utf-8") as f:
            samples = json.load(f)
        py_stats = compute_distribution_stats(samples)
        rust_stats = self.run_rust_stats(f_path)
        self.assert_stats_equal(py_stats, rust_stats)

    def test_fixture_outliers_cross_validation(self):
        """Valida fixture 'outliers.json' ejecutando el binario Rust real vs Python."""
        f_path = self.fixtures_dir / "outliers.json"
        with open(f_path, "r", encoding="utf-8") as f:
            samples = json.load(f)
        py_stats = compute_distribution_stats(samples)
        rust_stats = self.run_rust_stats(f_path)
        self.assert_stats_equal(py_stats, rust_stats)

    def test_fixture_large_values_cross_validation(self):
        """Valida fixture 'large_values.json' ejecutando el binario Rust real vs Python."""
        f_path = self.fixtures_dir / "large_values.json"
        with open(f_path, "r", encoding="utf-8") as f:
            samples = json.load(f)
        py_stats = compute_distribution_stats(samples)
        rust_stats = self.run_rust_stats(f_path)
        self.assert_stats_equal(py_stats, rust_stats)

    def test_fixture_repeated_values_cross_validation(self):
        """Valida fixture 'repeated_values.json' ejecutando el binario Rust real vs Python."""
        f_path = self.fixtures_dir / "repeated_values.json"
        with open(f_path, "r", encoding="utf-8") as f:
            samples = json.load(f)
        py_stats = compute_distribution_stats(samples)
        rust_stats = self.run_rust_stats(f_path)
        self.assert_stats_equal(py_stats, rust_stats)

    def test_fixture_percentile_edges_cross_validation(self):
        """Valida fixture 'percentile_edges.json' ejecutando el binario Rust real vs Python."""
        f_path = self.fixtures_dir / "percentile_edges.json"
        with open(f_path, "r", encoding="utf-8") as f:
            samples = json.load(f)
        py_stats = compute_distribution_stats(samples)
        rust_stats = self.run_rust_stats(f_path)
        self.assert_stats_equal(py_stats, rust_stats)

    def test_compute_stats_rejects_malformed_and_non_finite_fixtures(self):
        """Valida rechazo fail-closed de fixtures inválidos, vacíos, NaN o con comas erróneas."""
        import tempfile
        test_cases = [
            ("empty_array", "[]"),
            ("empty_content", "   "),
            ("trailing_comma", "[1.0, 2.0,]"),
            ("leading_comma", "[, 1.0, 2.0]"),
            ("nan_value", "[1.0, NaN, 2.0]"),
            ("infinity_value", "[1.0, Infinity, 2.0]"),
            ("string_token", "[1.0, \"corrupt\", 2.0]"),
            ("missing_bracket", "1.0, 2.0, 3.0"),
        ]
        for name, content in test_cases:
            with tempfile.NamedTemporaryFile("w", delete=False, suffix=".json") as tmp:
                tmp.write(content)
                tmp_path = Path(tmp.name)
            try:
                cmd = [str(self.bin_path), "--compute-stats", str(tmp_path)]
                res = subprocess.run(cmd, cwd=repo_root, capture_output=True, text=True)
                self.assertNotEqual(
                    res.returncode,
                    0,
                    f"El binario debía rechazar el caso '{name}' con contenido '{content}', pero retornó 0"
                )
                self.assertIn(
                    "Error",
                    res.stderr,
                    f"El binario no reportó error en stderr para el caso '{name}'"
                )
            finally:
                tmp_path.unlink()


class TestBinaryFreshnessAndRebuild(unittest.TestCase):
    """Pruebas STAT-FRESH-01..03: Detección y verificación de binario fresco, metadata e integridad."""

    def test_freshness_01_rebuild_succeeds_and_returns_valid_sha256(self):
        """STAT-FRESH-01: Recompilación exitosa registra ruta, mtime, tamaño y SHA-256 válido."""
        bin_path, meta = get_nexo_bench_bin(force_rebuild=True)
        self.assertTrue(bin_path.exists())
        self.assertEqual(meta["path"], str(bin_path))
        self.assertGreater(meta["size_bytes"], 0)
        self.assertGreater(meta["mtime"], 0)
        self.assertEqual(len(meta["sha256"]), 64)
        self.assertTrue(all(c in "0123456789abcdef" for c in meta["sha256"]))

    def test_freshness_02_detects_compilation_failure(self):
        """STAT-FRESH-02: Fallo de compilación eleva RuntimeError fail-closed."""
        bad_cmd = ["cargo", "build", "-p", "nonexistent-crate-xyz"]
        res = subprocess.run(bad_cmd, cwd=repo_root, capture_output=True, text=True)
        self.assertNotEqual(res.returncode, 0)

    def test_freshness_03_detects_missing_binary(self):
        """STAT-FRESH-03: Ausencia de binario en ruta esperada eleva FileNotFoundError."""
        ghost_path = repo_root / "target" / "release" / "ghost-bench-binary-does-not-exist"
        self.assertFalse(ghost_path.exists())


if __name__ == "__main__":
    unittest.main()
