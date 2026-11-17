//! Pruebas de integración de propagación de errores de E/S y escritura atómica (JSON-IO-01..10).
//!
//! Verifica que cualquier fallo en la creación de directorios, permisos o escritura
//! de resultados JSON resulte en un código de salida distinto de cero, reporte el error
//! a stderr, no emita mensajes espurios de éxito y no corrompa archivos existentes.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn get_bench_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_nexo-physical-bench"))
}

fn create_temp_test_dir(name: &str) -> PathBuf {
    let mut dir = std::env::temp_dir();
    dir.push(format!("nexo_bench_test_{}_{}", name, std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("Creación de directorio temporal de prueba");
    dir
}

#[test]
fn test_json_io_01_nonexistent_directory_created() {
    let base = create_temp_test_dir("io_01");
    let target = base.join("sub").join("nested").join("out.json");

    let status = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&target)
        .arg("--campaign-id")
        .arg("test_camp_01")
        .arg("--process-id")
        .arg("1")
        .status()
        .expect("Ejecución del binario");

    assert!(status.success(), "La ejecución debe tener éxito");
    assert!(target.exists(), "El archivo destino debió ser creado");
    let content = fs::read_to_string(&target).unwrap();
    assert!(content.contains("\"campaign_id\": \"test_camp_01\""));
    assert!(content.contains("\"process_id\": \"1\""));
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn test_json_io_02_and_04_invalid_path_fails_closed() {
    // Caracteres ilegales en Windows para forzar error determinista de ruta/creación
    #[cfg(target_os = "windows")]
    let invalid_target = "C:\\invalid_path_with_illegal_char_<>:\"|?*\\out.json";
    #[cfg(not(target_os = "windows"))]
    let invalid_target = "/proc/sys/fs/protected_nexo_invalid/out.json";

    let output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(invalid_target)
        .output()
        .expect("Ejecución de binario");

    assert!(
        !output.status.success(),
        "Debe retornar código de salida distinto de cero"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!stderr.is_empty(), "Debe informar la causa en stderr");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        !stdout.contains("JSON escrito exitosamente"),
        "No debe imprimir mensaje de éxito ante fallo"
    );
}

#[test]
fn test_json_io_03_path_is_existing_directory_fails() {
    let base = create_temp_test_dir("io_03");
    let dir_target = base.join("is_a_directory");
    fs::create_dir_all(&dir_target).unwrap();

    let output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&dir_target)
        .output()
        .expect("Ejecución de binario");

    assert!(
        !output.status.success(),
        "Debe fallar al intentar escribir en un directorio existente"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("directorio existente") || stderr.contains("Error"),
        "Stderr debe detallar que la ruta es un directorio: {stderr}"
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(!stdout.contains("JSON escrito exitosamente"));
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn test_json_io_06_preexisting_file_replaced_atomically() {
    let base = create_temp_test_dir("io_06");
    let target = base.join("existing.json");
    fs::write(&target, "OLD_CONTENT_PRIOR_TO_RUN").unwrap();

    let output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&target)
        .arg("--campaign-id")
        .arg("camp_replace")
        .arg("--process-id")
        .arg("2")
        .output()
        .expect("Ejecución de binario");

    assert!(output.status.success());
    let new_content = fs::read_to_string(&target).unwrap();
    assert!(!new_content.contains("OLD_CONTENT_PRIOR_TO_RUN"));
    assert!(new_content.contains("\"campaign_id\": \"camp_replace\""));
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn test_json_io_07_and_08_no_abandoned_tmp_and_no_truncated_file() {
    let base = create_temp_test_dir("io_07_08");
    // Crear un archivo previo válido
    let target = base.join("prev_valid.json");
    let original_valid = "{\"intact\": true}";
    fs::write(&target, original_valid).unwrap();

    // Ahora pasamos una ruta que colisiona con un directorio para forzar error
    let dir_collision = base.join("collision_dir");
    fs::create_dir_all(&dir_collision).unwrap();

    let output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&dir_collision)
        .output()
        .expect("Ejecución");

    assert!(!output.status.success());

    // Verificar que no quedan archivos temporales .tmp en el directorio base
    for entry in fs::read_dir(&base).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name().to_string_lossy().to_string();
        assert!(
            !name.contains(".tmp."),
            "No debe quedar archivo temporal abandonado: {name}"
        );
    }

    // El archivo previo no fue afectado
    assert_eq!(fs::read_to_string(&target).unwrap(), original_valid);
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn test_atomic_05_and_06_previous_file_preserved_on_failure_and_no_tmp_bak() {
    let base = create_temp_test_dir("atomic_05_06");
    let target = base.join("important_report.json");
    let original_valid = "{\"intact_previous_evidence\": true, \"data\": 12345}";
    fs::write(&target, original_valid).unwrap();

    // Invocar binario con parámetros contradictorios o destino que no pueda completarse
    // si target es bloqueado o si se intenta escribir sobre una ruta que falla
    let output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&base) // Pasar el directorio base para forzar error en write_atomic_json
        .output()
        .expect("Ejecución");

    assert!(!output.status.success());

    // El archivo previo debe permanecer intacto
    assert!(target.exists());
    assert_eq!(fs::read_to_string(&target).unwrap(), original_valid);

    // No debe existir ningún archivo .tmp.* ni .bak.* abandonado en el directorio
    for entry in fs::read_dir(&base).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name().to_string_lossy().to_string();
        assert!(!name.contains(".tmp."), "Archivo .tmp abandonado: {name}");
        assert!(!name.contains(".bak."), "Archivo .bak abandonado: {name}");
    }
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn test_json_io_09_and_10_nonzero_exit_code_and_subsequent_recovery() {
    let base = create_temp_test_dir("io_09_10");
    let dir_fail = base.join("dir_error");
    fs::create_dir_all(&dir_fail).unwrap();

    // 1. Ejecución fallida con código de salida distinto de cero
    let fail_output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&dir_fail)
        .output()
        .expect("Ejecución");
    assert_eq!(fail_output.status.code(), Some(1));

    // 2. Ejecución recuperada con ruta de archivo válida
    let valid_target = base.join("recovered.json");
    let ok_output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&valid_target)
        .arg("--campaign-id")
        .arg("recovered_campaign")
        .output()
        .expect("Ejecución");
    assert!(ok_output.status.success());
    assert!(valid_target.exists());
    let content = fs::read_to_string(&valid_target).unwrap();
    assert!(content.contains("\"campaign_id\": \"recovered_campaign\""));
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn test_json_io_11_rollback_verification_and_truthful_reporting() {
    let base = create_temp_test_dir("io_11");
    let target = base.join("prev_version.json");
    let initial_content = "{\"version\": \"initial_preserved_content\"}";
    fs::write(&target, initial_content).unwrap();

    // Invocar apuntando a un directorio para forzar fallo
    let output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&base)
        .output()
        .expect("Ejecución");

    assert!(!output.status.success());
    // El archivo previo no fue corrompido
    assert_eq!(fs::read_to_string(&target).unwrap(), initial_content);

    // No quedaron archivos .bak ni .tmp
    for entry in fs::read_dir(&base).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name().to_string_lossy().to_string();
        assert!(!name.contains(".bak."));
        assert!(!name.contains(".tmp."));
    }
    let _ = fs::remove_dir_all(&base);
}

#[test]
#[cfg(target_os = "windows")]
fn test_json_io_12_windows_rollback_fault_injection_publish_failure_recovers_original() {
    let base = create_temp_test_dir("io_12");
    let target = base.join("data_to_preserve.json");
    let original_data = "{\"original_val\": 42, \"safe\": true}";
    fs::write(&target, original_data).unwrap();

    let output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&target)
        .env("NEXO_TEST_FAULT_ATOMIC_STAGE", "FAIL_PUBLISH")
        .output()
        .expect("Ejecución con fallo inyectado");

    assert!(!output.status.success(), "Debe fallar al publicar temporal");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("versión previa restaurada exitosamente"),
        "Debe reportar restauración verídica en stderr: {stderr}"
    );

    // Comprobar que el archivo original fue 100% restaurado y conservado
    assert!(target.exists());
    assert_eq!(fs::read_to_string(&target).unwrap(), original_data);

    // Comprobar que los temporales y backups fueron limpiados
    for entry in fs::read_dir(&base).unwrap() {
        let name = entry.unwrap().file_name().to_string_lossy().to_string();
        assert!(
            !name.contains(".tmp."),
            "Archivo temporal .tmp no eliminado: {name}"
        );
        assert!(
            !name.contains(".bak."),
            "Archivo backup .bak no eliminado: {name}"
        );
    }
    let _ = fs::remove_dir_all(&base);
}

#[test]
#[cfg(target_os = "windows")]
fn test_json_io_13_windows_rollback_fault_injection_restore_failure_preserves_backup() {
    let base = create_temp_test_dir("io_13");
    let target = base.join("critical_data.json");
    let original_data = "{\"critical_evidence\": 9999}";
    fs::write(&target, original_data).unwrap();

    let output = Command::new(get_bench_bin())
        .arg("--json-out")
        .arg(&target)
        .env("NEXO_TEST_FAULT_ATOMIC_STAGE", "FAIL_RESTORE")
        .output()
        .expect("Ejecución con fallo inyectado en restore");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("CRÍTICO:") && stderr.contains("El respaldo original se conserva"),
        "Debe emitir alarma crítica y advertir la conservación del respaldo: {stderr}"
    );

    // Comprobar que existe exactamente un archivo .bak.<pid> preservado y que contiene la evidencia original
    let mut found_backup = false;
    for entry in fs::read_dir(&base).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        if name.contains(".bak.") {
            found_backup = true;
            assert_eq!(fs::read_to_string(&path).unwrap(), original_data);
        }
        assert!(!name.contains(".tmp."), "Archivo .tmp no eliminado: {name}");
    }
    assert!(
        found_backup,
        "El archivo de respaldo debió preservarse en disco"
    );
    let _ = fs::remove_dir_all(&base);
}
