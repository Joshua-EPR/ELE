//! ELE-written native backend enum slice; Stage 0 builds the .l backend.
//! The Stage 1 source emitter does not yet serialize variant/disc.
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
    std::env::temp_dir().join(format!("ele-enum-{}-{ns}.elf", std::process::id()))
}

#[test]
fn enum_unit_and_primitive_payload_emit_real_elf64_from_ele_backend() {
    for name in [
        "native_cfg_enum_unit.lir",
        "native_cfg_enum_positive.lir",
        "native_cfg_enum_bool.lir",
    ] {
        let input = root().join("examples").join(name);
        let output = temp_elf();
        let built = Command::new(compiler())
            .arg(&input)
            .arg(&output)
            .output()
            .unwrap();
        assert!(
            built.status.success(),
            "{name}: {}",
            String::from_utf8_lossy(&built.stderr)
        );
        let bytes = fs::read(&output).unwrap();
        assert!(bytes.len() > 4096, "{name}: ELF demasiado pequeño");
        assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");

        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&output).unwrap().permissions();
            perms.set_mode(0o700);
            fs::set_permissions(&output, perms).unwrap();
            let run = Command::new(&output).output().unwrap();
            let expected = if name.contains("unit") { 1 } else { 42 };
            assert_eq!(
                run.status.code(),
                Some(expected),
                "{name}: {}",
                String::from_utf8_lossy(&run.stderr)
            );
        }
        fs::remove_file(output).unwrap();
    }
}

#[test]
fn enum_rejects_wrong_variant_payload_and_moves() {
    for name in [
        "native_cfg_enum_wrong_payload.lir",
        "native_cfg_enum_wrong_variant.lir",
        "native_cfg_enum_wrong_arity.lir",
        "native_cfg_enum_use_after_move.lir",
        "native_cfg_enum_uninitialized_disc.lir",
        "native_cfg_enum_unknown_type.lir",
        "native_cfg_enum_bad_owned_payload.lir",
        "native_cfg_enum_move_join.lir",
    ] {
        let input = root().join("examples").join(name);
        let output = temp_elf();
        let built = Command::new(compiler())
            .arg(&input)
            .arg(&output)
            .output()
            .unwrap();
        assert!(!built.status.success(), "se aceptó LIR inválido: {name}");
        assert!(
            String::from_utf8_lossy(&built.stderr).contains("rechazado"),
            "{name}: {}",
            String::from_utf8_lossy(&built.stderr)
        );
        assert!(!output.exists(), "se creó un ELF para LIR inválido: {name}");
    }
}
