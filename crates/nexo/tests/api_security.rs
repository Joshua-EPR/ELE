//! Pruebas de seguridad de la API pública y encapsulación de capacidades lineales.
//!
//! Verifica que:
//! 1. `Handle` y `HoleToken` son capacidades lineales sin constructores públicos.
//! 2. Sus campos internos (`pool`, `slot`, `generation`) son privados e inaccesibles
//!    desde crates externos.
//! 3. Ningún helper adversarial (`__test_*`) está expuesto a consumidores normales
//!    sin la feature interna `test-internals`.

use std::process::Command;

fn run_fixture_check(feature: &str) -> (bool, String) {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let fixture_dir = std::path::Path::new(manifest_dir)
        .join("tests")
        .join("fixtures")
        .join("external_consumer");

    let mut cmd = Command::new(env!("CARGO"));
    cmd.current_dir(&fixture_dir)
        .arg("check")
        .arg("--features")
        .arg(feature);

    let output = cmd
        .output()
        .expect("failed to execute cargo check on fixture");
    let success = output.status.success();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();
    (success, stderr)
}

#[test]
fn test_external_consumer_default_compiles() {
    let (success, stderr) = run_fixture_check("default");
    assert!(
        success,
        "El crate consumidor externo debió compilar limpiamente con configuración por defecto:\n{stderr}"
    );
}

#[test]
fn test_external_consumer_cannot_call_craft_handle() {
    let (success, stderr) = run_fixture_check("call-test-craft-handle");
    assert!(
        !success,
        "La compilación debió ser rechazada al intentar invocar __test_craft_handle"
    );
    assert!(
        stderr.contains("E0599") && stderr.contains("__test_craft_handle"),
        "Se esperaba error E0599 por método inexistente en API de producción, recibido:\n{stderr}"
    );
}

#[test]
fn test_external_consumer_cannot_call_craft_handle_for_test() {
    let (success, stderr) = run_fixture_check("call-craft-handle-for-test");
    assert!(
        !success,
        "La compilación debió ser rechazada al intentar invocar craft_handle_for_test"
    );
    assert!(
        stderr.contains("E0599") && stderr.contains("craft_handle_for_test"),
        "Se esperaba error E0599 por método inexistente/privado en API externa, recibido:\n{stderr}"
    );
}

#[test]
fn test_external_consumer_cannot_call_corrupt_live() {
    let (success, stderr) = run_fixture_check("call-test-corrupt-live");
    assert!(
        !success,
        "La compilación debió ser rechazada al intentar invocar __test_corrupt_live"
    );
    assert!(
        stderr.contains("E0599") && stderr.contains("__test_corrupt_live"),
        "Se esperaba error E0599 por método inexistente en API de producción, recibido:\n{stderr}"
    );
}

#[test]
fn test_external_consumer_cannot_call_corrupt_live_for_test() {
    let (success, stderr) = run_fixture_check("call-corrupt-live-for-test");
    assert!(
        !success,
        "La compilación debió ser rechazada al intentar invocar corrupt_live_for_test"
    );
    assert!(
        stderr.contains("E0599") && stderr.contains("corrupt_live_for_test"),
        "Se esperaba error E0599 por método inexistente/privado en API externa, recibido:\n{stderr}"
    );
}

#[test]
fn test_external_consumer_cannot_construct_handle_struct() {
    let (success, stderr) = run_fixture_check("construct-handle-struct");
    assert!(
        !success,
        "La compilación debió ser rechazada al intentar construir Handle directamente"
    );
    assert!(
        stderr.contains("E0451") && stderr.contains("Handle"),
        "Se esperaba error E0451 por campos privados de Handle, recibido:\n{stderr}"
    );
}

#[test]
fn test_external_consumer_cannot_construct_hole_token_struct() {
    let (success, stderr) = run_fixture_check("construct-hole-token");
    assert!(
        !success,
        "La compilación debió ser rechazada al intentar construir HoleToken directamente"
    );
    assert!(
        stderr.contains("E0451") && stderr.contains("HoleToken"),
        "Se esperaba error E0451 por campos privados de HoleToken, recibido:\n{stderr}"
    );
}
