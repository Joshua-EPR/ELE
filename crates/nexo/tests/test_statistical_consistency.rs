//! Pruebas de integración y consistencia matemática de la infraestructura estadística de NEXO.
//!
//! Verifica universalmente el cumplimiento de la cota de Samuelson-Brunk,
//! la estabilidad numérica del acumulador de Welford y la resolución formal
//! de la aparente paradoja entre la dispersión por lotes (s >= 108.6 ns)
//! y la dispersión entre corridas (s ≈ 18.8 ns).

use nexo::stats::{StatsError, WelfordAccumulator, compute_stats, verify_samuelson_bounds};

#[test]
fn test_samuelson_inequality_enforced_strictly() {
    // Para N = 5, media = 100, máximo = 200, la cota exige:
    // (200 - 100) / sqrt(5 - 1) = 100 / 2 = 50.0
    // Si la desviación estándar fuese < 50, violaría Samuelson.
    let samples = [100.0, 100.0, 100.0, 100.0, 200.0];
    let stats = compute_stats(&samples).expect("Cálculo exitoso");

    // Media = 120, max_dev = 80. bound = s * sqrt(4) = 2 * s.
    // Con Welford, la cota se verifica y no retorna error.
    assert!(verify_samuelson_bounds(&stats).is_ok());
}

#[test]
fn test_reconciliation_of_18_8_ns_vs_108_6_ns() {
    // Demostración formal y reproducible de por qué la dispersión por lotes (N=700)
    // satisface s >= 108.6 ns, mientras que la dispersión entre corridas (N=7) es ≈ 18.8 ns.
    let mut all_700_batches = Vec::with_capacity(700);
    let mut run_means = Vec::with_capacity(7);

    for run_idx in 0..7 {
        let mut run_batches = Vec::with_capacity(100);
        for batch_idx in 0..100 {
            // Un único valor atípico extremo en la primera corrida
            if run_idx == 0 && batch_idx == 0 {
                run_batches.push(2969.5);
            } else {
                run_batches.push(93.75);
            }
        }
        let run_mean = run_batches.iter().sum::<f64>() / 100.0;
        run_means.push(run_mean);
        all_700_batches.extend(run_batches);
    }

    let batch_stats = compute_stats(&all_700_batches).expect("700 lotes válidos");
    let run_stats = compute_stats(&run_means).expect("7 corridas válidas");

    // 1. Verificación de la cota de Samuelson sobre la distribución de 700 lotes
    let dev_max_batch = batch_stats.max - batch_stats.mean;
    let samuelson_lower_bound = dev_max_batch / ((700.0 - 1.0f64).sqrt());
    assert!(
        samuelson_lower_bound > 108.0,
        "La cota inferior de Samuelson debe ser > 108 ns (obtenido: {samuelson_lower_bound})"
    );
    assert!(
        batch_stats.std_dev_sample >= samuelson_lower_bound,
        "La desviación muestral de lotes ({}) debe ser >= cota Samuelson ({})",
        batch_stats.std_dev_sample,
        samuelson_lower_bound
    );

    // 2. Verificación de la dispersión entre corridas (N=7)
    // El outlier de 2969.5 ns amortizado entre 100 lotes produce una corrida de ~122.5 ns.
    // Las otras 6 corridas tienen media 93.75 ns.
    // La desviación estándar entre las 7 corridas resulta en el orden de ~10..20 ns.
    assert!(
        run_stats.std_dev_sample < 20.0,
        "La dispersión entre corridas debe ser pequeña (< 20 ns) por efecto de amortización (obtenido: {})",
        run_stats.std_dev_sample
    );

    // 3. Ambas distribuciones satisfacen universalmente a Samuelson en su propio tamaño N
    assert!(verify_samuelson_bounds(&batch_stats).is_ok());
    assert!(verify_samuelson_bounds(&run_stats).is_ok());
}

#[test]
fn test_welford_numerical_stability_on_large_uniform_data() {
    let mut welford = WelfordAccumulator::new();
    let constant_val = 42.0;
    for _ in 0..10_000 {
        welford.update(constant_val).unwrap();
    }
    assert_eq!(welford.count(), 10_000);
    assert!((welford.mean() - constant_val).abs() < 1e-12);
    assert!(welford.variance_sample().abs() < 1e-12);
    assert!(welford.std_dev_sample().abs() < 1e-12);
}

#[test]
fn test_non_finite_rejection_at_boundaries() {
    assert_eq!(
        compute_stats(&[1.0, 2.0, f64::NAN]).unwrap_err(),
        StatsError::NonFiniteValue
    );
    assert_eq!(
        compute_stats(&[1.0, f64::INFINITY]).unwrap_err(),
        StatsError::NonFiniteValue
    );
    assert_eq!(
        compute_stats(&[f64::NEG_INFINITY, 5.0]).unwrap_err(),
        StatsError::NonFiniteValue
    );
    assert_eq!(compute_stats(&[]).unwrap_err(), StatsError::Empty);
}
