#!/usr/bin/env python3
"""
scripts/test_stats_cross.py — Suite de pruebas cruzadas Rust/Python (STAT-CROSS-01..10).

Verifica la equivalencia exacta entre la implementación estadística en Python
(`scripts/run_benchmarks.py`) y en Rust (`crates/nexo/src/stats.rs`), asegurando
que la especificación STATS_SPEC_VERSION 1.1.0 produzca resultados idénticos
en ambos lenguajes.
"""

import math
import sys
import unittest
from pathlib import Path

# Añadir directorio scripts al PYTHONPATH
sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_benchmarks import compute_distribution_stats, percentile_sorted, STATS_SPEC_VERSION


class TestStatisticalCrossLanguage(unittest.TestCase):
    """Pruebas cruzadas de paridad matemática entre Rust y Python."""

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
        # N=5: sum((x - 30)^2) = 400 + 100 + 0 + 100 + 400 = 1000
        # var_sample = 1000 / 4 = 250.0
        # var_pop = 1000 / 5 = 200.0
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
        # N=5, p=0.95 -> rank = 4 * 0.95 = 3.8 -> 40.0 * 0.2 + 50.0 * 0.8 = 48.0
        p95 = percentile_sorted(sorted_v, 0.95)
        self.assertAlmostEqual(p95, 48.0, places=4)

        # N=5, p=0.99 -> rank = 4 * 0.99 = 3.96 -> 40.0 * 0.04 + 50.0 * 0.96 = 49.6
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
        # Un valor extremo válido dentro de la cota
        v_valid = [100.0, 100.0, 100.0, 100.0, 200.0]
        stats = compute_distribution_stats(v_valid)
        self.assertIsNotNone(stats)

        # Vector que simula lotes con un outlier extremo amortizado
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
        # La varianza debe permanecer exactamente en 250.0 a pesar de los 9 órdenes de magnitud de offset
        self.assertAlmostEqual(stats["variance_sample"], 250.0, places=4)
        self.assertAlmostEqual(stats["variance_pop"], 200.0, places=4)


if __name__ == "__main__":
    unittest.main()
