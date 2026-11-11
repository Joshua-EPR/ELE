//! Regression tests for the *experimental native ELE backend* checked
//! primitive-payload load. Stage 0 is used only to build the .l backend.
//! This does not certify Stage 1 enum serialization, Option or Result.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn compiler() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}

fn temp_elf() -> PathBuf {
    let ns = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("ele-payload-{}-{ns}.elf", std::process::id()))
}

fn build_fixture(name: &str, expect_success: bool) -> Option<PathBuf> {
    let input = root().join("examples").join(name);
    let output = temp_elf();
    let built = Command::new(compiler())
        .arg(&input)
        .arg(&output)
        .output()
        .expect("build backend");
    assert_eq!(
        built.status.success(),
        expect_success,
        "{name}: {}",
        String::from_utf8_lossy(&built.stderr)
    );
    if !expect_success {
        assert!(
            !output.exists(),
            "{name}: no debe escribirse ELF al rechazar LIR"
        );
        return None;
    }
    let elf = fs::read(&output).unwrap();
    assert!(elf.len() > 4096, "{name}: ELF demasiado pequeño");
    assert_eq!(&elf[..7], b"\x7fELF\x02\x01\x01", "{name}");
    Some(output)
}

fn run_and_remove(path: PathBuf, expected: i32) {
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o700);
        fs::set_permissions(&path, perms).unwrap();
        let actual = Command::new(&path).output().expect("run native ELF");
        assert_eq!(
            actual.status.code(),
            Some(expected),
            "{}: {}",
            path.display(),
            String::from_utf8_lossy(&actual.stderr)
        );
    }
    #[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
    {
        let _ = expected;
    }
    fs::remove_file(path).unwrap();
}

#[test]
fn native_payload_loads_int_and_bool_after_variant_check() {
    for name in [
        "native_cfg_enum_payload_int.lir",
        "native_cfg_enum_payload_bool.lir",
        "native_cfg_enum_payload_branch.lir",
    ] {
        run_and_remove(build_fixture(name, true).unwrap(), 42);
    }
}

#[test]
fn native_payload_rejects_invalid_type_or_uninitialized_owner() {
    for name in [
        "native_cfg_enum_payload_wrong_enum.lir",
        "native_cfg_enum_payload_wrong_variant.lir",
        "native_cfg_enum_payload_unit_variant.lir",
        "native_cfg_enum_payload_type_mismatch.lir",
        "native_cfg_enum_payload_uninitialized.lir",
        "native_cfg_enum_payload_use_after_move.lir",
    ] {
        build_fixture(name, false);
    }
}

#[test]
fn native_payload_wrong_active_variant_exits_without_reading_payload() {
    let elf = build_fixture("native_cfg_enum_payload_wrong_active.lir", true).unwrap();
    run_and_remove(elf, 126);
}

#[test]
fn native_option_and_result_shape_lower_to_guarded_cfg() {
    for (name, expected) in [
        ("native_cfg_option_some.lir", 42),
        ("native_cfg_option_none.lir", 0),
        ("native_cfg_result_ok.lir", 42),
        ("native_cfg_result_err.lir", 7),
    ] {
        run_and_remove(build_fixture(name, true).unwrap(), expected);
    }
}
