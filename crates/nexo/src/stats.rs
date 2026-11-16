//! Módulo de análisis estadístico numéricamente estable y reproducible para benchmarks de NEXO.
//!
//! Implementa el algoritmo de Welford para el cálculo en una pasada de media y varianza,
//! diferenciando formalmente entre:
//! - Muestras por lote (`batch_stats`, ej. 700 lotes de 200 ops).
//! - Muestras por corrida interna (`run_stats`, ej. 7 medias de corrida).
//! - Muestras entre procesos independientes del SO (`process_stats`, ej. 5 procesos del SO).
//!
//! Distingue explícitamente entre la desviación estándar muestral (denominador $N - 1$)
//! y la poblacional (denominador $N$), y comprueba la consistencia matemática de las cotas
//! extremas mediante la desigualdad de Samuelson ($x_{\max} - \bar{x} \le s \sqrt{N - 1}$).

use std::fmt;

/// Errores durante el cálculo y validación estadística.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatsError {
    /// La serie de datos está vacía.
    Empty,
    /// Se encontró un valor no finito (`NaN`, `+inf` o `-inf`).
    NonFiniteValue,
    /// Violación de invariante matemático (ej. incoherencia entre extremo, media y dispersión).
    MathematicalInconsistency(String),
}

impl fmt::Display for StatsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => write!(f, "el conjunto de datos está vacío"),
            Self::NonFiniteValue => write!(f, "se detectó un valor no finito (NaN o infinito)"),
            Self::MathematicalInconsistency(msg) => write!(f, "inconsistencia matemática: {msg}"),
        }
    }
}

impl std::error::Error for StatsError {}

/// Acumulador incremental numéricamente estable según el algoritmo de Welford (1962).
#[derive(Debug, Clone, Default)]
pub struct WelfordAccumulator {
    count: usize,
    mean: f64,
    m2: f64,
    min: f64,
    max: f64,
}

impl WelfordAccumulator {
    pub const fn new() -> Self {
        Self {
            count: 0,
            mean: 0.0,
            m2: 0.0,
            min: f64::INFINITY,
            max: f64::NEG_INFINITY,
        }
    }

    /// Agrega una muestra comprobando que sea finita.
    pub fn update(&mut self, x: f64) -> Result<(), StatsError> {
        if !x.is_finite() {
            return Err(StatsError::NonFiniteValue);
        }
        self.count += 1;
        let delta = x - self.mean;
        self.mean += delta / (self.count as f64);
        let delta2 = x - self.mean;
        self.m2 += delta * delta2;

        if x < self.min {
            self.min = x;
        }
        if x > self.max {
            self.max = x;
        }
        Ok(())
    }

    #[inline]
    pub fn count(&self) -> usize {
        self.count
    }

    #[inline]
    pub fn mean(&self) -> f64 {
        self.mean
    }

    #[inline]
    pub fn min(&self) -> f64 {
        self.min
    }

    #[inline]
    pub fn max(&self) -> f64 {
        self.max
    }

    /// Varianza muestral insesgada con denominador $N - 1$.
    pub fn variance_sample(&self) -> f64 {
        if self.count < 2 {
            0.0
        } else {
            self.m2 / ((self.count - 1) as f64)
        }
    }

    /// Varianza poblacional con denominador $N$.
    pub fn variance_pop(&self) -> f64 {
        if self.count == 0 {
            0.0
        } else {
            self.m2 / (self.count as f64)
        }
    }

    /// Desviación estándar muestral ($s$).
    pub fn std_dev_sample(&self) -> f64 {
        self.variance_sample().sqrt()
    }

    /// Desviación estándar poblacional ($\sigma$).
    pub fn std_dev_pop(&self) -> f64 {
        self.variance_pop().sqrt()
    }

    /// Coeficiente de variación muestral ($s / \bar{x} \times 100\%$).
    pub fn cv_sample(&self) -> f64 {
        if self.mean.abs() < f64::EPSILON {
            0.0
        } else {
            (self.std_dev_sample() / self.mean) * 100.0
        }
    }

    /// Coeficiente de variación poblacional ($\sigma / \bar{x} \times 100\%$).
    pub fn cv_pop(&self) -> f64 {
        if self.mean.abs() < f64::EPSILON {
            0.0
        } else {
            (self.std_dev_pop() / self.mean) * 100.0
        }
    }
}

/// Resumen estadístico completo e independiente de una distribución.
#[derive(Debug, Clone, PartialEq)]
pub struct DistributionStats {
    /// Número exacto de muestras en esta distribución.
    pub count: usize,
    /// Media aritmética.
    pub mean: f64,
    /// Mediana (percentil 50).
    pub median: f64,
    /// Mínimo observado.
    pub min: f64,
    /// Máximo observado.
    pub max: f64,
    /// Varianza muestral insesgada ($N - 1$).
    pub variance_sample: f64,
    /// Varianza poblacional ($N$).
    pub variance_pop: f64,
    /// Desviación estándar muestral ($N - 1$).
    pub std_dev_sample: f64,
    /// Desviación estándar poblacional ($N$).
    pub std_dev_pop: f64,
    /// Coeficiente de variación muestral en porcentaje.
    pub cv_sample: f64,
    /// Coeficiente de variación poblacional en porcentaje.
    pub cv_pop: f64,
    /// Percentil 50 (idéntico a la mediana).
    pub p50: f64,
    /// Percentil 95.
    pub p95: f64,
    /// Percentil 99.
    pub p99: f64,
}

/// Calcula estadísticas completas sobre un vector de observaciones.
pub fn compute_stats(samples: &[f64]) -> Result<DistributionStats, StatsError> {
    if samples.is_empty() {
        return Err(StatsError::Empty);
    }

    let mut welford = WelfordAccumulator::new();
    let mut sorted = Vec::with_capacity(samples.len());

    for &val in samples {
        welford.update(val)?;
        sorted.push(val);
    }

    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

    let count = samples.len();
    let p50 = percentile_sorted(&sorted, 0.50);
    let p95 = percentile_sorted(&sorted, 0.95);
    let p99 = percentile_sorted(&sorted, 0.99);

    let stats = DistributionStats {
        count,
        mean: welford.mean(),
        median: p50,
        min: welford.min(),
        max: welford.max(),
        variance_sample: welford.variance_sample(),
        variance_pop: welford.variance_pop(),
        std_dev_sample: welford.std_dev_sample(),
        std_dev_pop: welford.std_dev_pop(),
        cv_sample: welford.cv_sample(),
        cv_pop: welford.cv_pop(),
        p50,
        p95,
        p99,
    };

    // Validación de coherencia matemática de Samuelson
    verify_samuelson_bounds(&stats)?;

    Ok(stats)
}

/// Calcula el percentil $p \in [0.0, 1.0]$ sobre un slice previamente ordenado.
pub fn percentile_sorted(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    if sorted.len() == 1 || p <= 0.0 {
        return sorted[0];
    }
    if p >= 1.0 {
        return sorted[sorted.len() - 1];
    }

    let idx = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

/// Comprueba la desigualdad de Samuelson: para cualquier distribución de tamaño $N$,
/// el desvío máximo $|x - \bar{x}| \le s \sqrt{N - 1}$.
pub fn verify_samuelson_bounds(stats: &DistributionStats) -> Result<(), StatsError> {
    if stats.count <= 1 {
        return Ok(());
    }
    let factor = (stats.count as f64 - 1.0).sqrt();
    let max_allowed_deviation = stats.std_dev_sample * factor + 1e-6;

    let dev_max = (stats.max - stats.mean).abs();
    let dev_min = (stats.mean - stats.min).abs();

    if dev_max > max_allowed_deviation {
        return Err(StatsError::MathematicalInconsistency(format!(
            "máximo {} excede cota de Samuelson para media {} y sd {} (N={}): desvío {} > {}",
            stats.max,
            stats.mean,
            stats.std_dev_sample,
            stats.count,
            dev_max,
            max_allowed_deviation
        )));
    }
    if dev_min > max_allowed_deviation {
        return Err(StatsError::MathematicalInconsistency(format!(
            "mínimo {} excede cota de Samuelson para media {} y sd {} (N={}): desvío {} > {}",
            stats.min,
            stats.mean,
            stats.std_dev_sample,
            stats.count,
            dev_min,
            max_allowed_deviation
        )));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_identical_values_zero_deviation() {
        let data = vec![42.0; 100];
        let stats = compute_stats(&data).unwrap();
        assert_eq!(stats.count, 100);
        assert_eq!(stats.mean, 42.0);
        assert_eq!(stats.median, 42.0);
        assert_eq!(stats.min, 42.0);
        assert_eq!(stats.max, 42.0);
        assert!(stats.std_dev_sample < 1e-12);
        assert!(stats.std_dev_pop < 1e-12);
        assert!(stats.cv_sample < 1e-12);
    }

    #[test]
    fn test_small_uniform_distribution() {
        let data = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        let stats = compute_stats(&data).unwrap();
        assert_eq!(stats.count, 5);
        assert_eq!(stats.mean, 3.0);
        assert_eq!(stats.median, 3.0);
        assert_eq!(stats.min, 1.0);
        assert_eq!(stats.max, 5.0);
        // Varianza muestral = ((1-3)^2 + (2-3)^2 + (3-3)^2 + (4-3)^2 + (5-3)^2) / 4 = (4 + 1 + 0 + 1 + 4) / 4 = 10 / 4 = 2.5
        // std_dev_sample = sqrt(2.5) ≈ 1.5811388300841898
        assert!((stats.std_dev_sample - 2.5f64.sqrt()).abs() < 1e-12);
        // Varianza poblacional = 10 / 5 = 2.0
        // std_dev_pop = sqrt(2.0) ≈ 1.4142135623730951
        assert!((stats.std_dev_pop - 2.0f64.sqrt()).abs() < 1e-12);
    }

    #[test]
    fn test_single_extreme_outlier_samuelson_coherence() {
        // 9 muestras de 10.0 y 1 muestra de 110.0 (N=10)
        let mut data = vec![10.0; 9];
        data.push(110.0);
        let stats = compute_stats(&data).unwrap();
        assert_eq!(stats.count, 10);
        assert_eq!(stats.mean, 20.0);
        assert_eq!(stats.min, 10.0);
        assert_eq!(stats.max, 110.0);

        // Samuelson: max - mean = 110 - 20 = 90.0.
        // s * sqrt(9) = s * 3. Por Samuelson, s >= 90 / 3 = 30.0.
        assert!(stats.std_dev_sample >= 30.0);
        assert!(verify_samuelson_bounds(&stats).is_ok());
    }

    #[test]
    fn test_five_known_samples_analytical() {
        let data = vec![10.0, 20.0, 30.0, 40.0, 100.0];
        let stats = compute_stats(&data).unwrap();
        assert_eq!(stats.count, 5);
        assert_eq!(stats.mean, 40.0);
        assert_eq!(stats.median, 30.0);
        assert_eq!(stats.min, 10.0);
        assert_eq!(stats.max, 100.0);

        // m2 = (10-40)^2 + (20-40)^2 + (30-40)^2 + (40-40)^2 + (100-40)^2
        //    = 900 + 400 + 100 + 0 + 3600 = 5000.
        // var_sample = 5000 / 4 = 1250.
        // std_dev_sample = sqrt(1250) ≈ 35.355339
        assert!((stats.std_dev_sample - 1250.0f64.sqrt()).abs() < 1e-12);
        // var_pop = 5000 / 5 = 1000.
        // std_dev_pop = sqrt(1000) ≈ 31.6227766
        assert!((stats.std_dev_pop - 1000.0f64.sqrt()).abs() < 1e-12);
    }

    #[test]
    fn test_700_samples_with_controlled_outlier_demonstrates_samuelson_bound() {
        // 699 muestras de 90.0 y 1 muestra extrema de 2969.5
        let mut data = vec![90.0; 699];
        data.push(2969.5);
        let stats = compute_stats(&data).unwrap();
        assert_eq!(stats.count, 700);

        // Verificamos que la desviación estándar de lote (batch_stddev)
        // respeta la cota matemática obligatoria s >= (max - mean) / sqrt(N - 1)
        let min_required_sd = (stats.max - stats.mean) / (699.0f64).sqrt();
        assert!(
            stats.std_dev_sample >= min_required_sd,
            "Desviación muestral {} no puede ser inferior a cota de Samuelson {}",
            stats.std_dev_sample,
            min_required_sd
        );
        // La cota calculada para este conjunto es aproximadamente 108.6 ns
        assert!(stats.std_dev_sample > 108.0);
    }

    #[test]
    fn test_incremental_welford_matches_two_pass_reference() {
        let data = vec![12.4, 55.8, 92.1, 14.3, 88.0, 31.5, 7.2, 49.0];
        let n = data.len() as f64;
        let ref_mean = data.iter().sum::<f64>() / n;
        let ref_var_sample = data.iter().map(|x| (x - ref_mean).powi(2)).sum::<f64>() / (n - 1.0);
        let ref_sd_sample = ref_var_sample.sqrt();

        let stats = compute_stats(&data).unwrap();
        assert!((stats.mean - ref_mean).abs() < 1e-12);
        assert!((stats.std_dev_sample - ref_sd_sample).abs() < 1e-12);
    }

    #[test]
    fn test_rejection_of_non_finite_values() {
        assert_eq!(
            compute_stats(&[1.0, 2.0, f64::NAN]),
            Err(StatsError::NonFiniteValue)
        );
        assert_eq!(
            compute_stats(&[1.0, f64::INFINITY, 2.0]),
            Err(StatsError::NonFiniteValue)
        );
        assert_eq!(
            compute_stats(&[f64::NEG_INFINITY, 2.0]),
            Err(StatsError::NonFiniteValue)
        );
        assert_eq!(compute_stats(&[]), Err(StatsError::Empty));
    }

    #[test]
    fn test_differentiation_between_batch_and_run_distributions() {
        // 7 corridas, cada una compuesta de 100 lotes (700 lotes en total)
        // Las corridas tienen medias estables (ej. alrededor de 95 ns),
        // pero dentro de una corrida hay un lote con pico transitorio (outlier).
        let mut all_batches = Vec::with_capacity(700);
        let mut run_means = Vec::with_capacity(7);

        for run in 0..7 {
            let mut run_batches = Vec::with_capacity(100);
            for batch in 0..100 {
                if run == 3 && batch == 50 {
                    run_batches.push(2969.5); // Outlier transitorio
                } else {
                    run_batches.push(93.0 + ((run + batch) % 5) as f64);
                }
            }
            let r_mean = run_batches.iter().sum::<f64>() / 100.0;
            run_means.push(r_mean);
            all_batches.extend(run_batches);
        }

        let batch_stats = compute_stats(&all_batches).unwrap();
        let run_stats = compute_stats(&run_means).unwrap();

        // Demostración formal:
        // 1. Las medias coinciden
        assert!((batch_stats.mean - run_stats.mean).abs() < 1e-9);
        // 2. La desviación estándar por lote (batch_stats.std_dev_sample) es significativamente mayor
        //    debido a que captura la dispersión real de cada lote individual con el outlier (>= 108 ns)
        assert!(batch_stats.std_dev_sample > 100.0);
        // 3. La desviación estándar entre corridas (run_stats.std_dev_sample) es mucho menor
        //    porque el outlier queda amortizado en la media de 100 lotes (~10-20 ns)
        assert!(run_stats.std_dev_sample < 20.0);
        // 4. Las dos unidades de análisis son matemáticamente distintas
        assert_ne!(batch_stats.std_dev_sample, run_stats.std_dev_sample);
    }

    #[test]
    fn test_single_sample_handled_gracefully() {
        let data = vec![42.0];
        let stats = compute_stats(&data).unwrap();
        assert_eq!(stats.count, 1);
        assert_eq!(stats.mean, 42.0);
        assert_eq!(stats.median, 42.0);
        assert_eq!(stats.min, 42.0);
        assert_eq!(stats.max, 42.0);
        assert_eq!(stats.std_dev_sample, 0.0);
        assert_eq!(stats.std_dev_pop, 0.0);
        assert_eq!(stats.cv_sample, 0.0);
    }
}
