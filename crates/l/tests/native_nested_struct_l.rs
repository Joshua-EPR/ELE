//! Regression checks for nested, Copy-only structs in ELE-LIR 1.
//! Runs the real ELE-written native backend via the Stage 0 bootstrap.
mod stage1_support;
use std::{fs, path::{Path, PathBuf}, process::Command, sync::OnceLock};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
fn compiler() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}
fn unique_file() -> PathBuf {
    let ns = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    std::env::temp_dir().join(format!("ele-nested-{}-{ns}.elf", std::process::id()))
}

#[test]
fn nested_copy_structs_emit_real_elf64_from_ele() {
    let input = root().join("examples/native_cfg_nested_copy.lir");
    let output = unique_file();
    let result = Command::new(compiler()).arg(&input).arg(&output).output().unwrap();
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stderr));
    let bytes = fs::read(&output).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    assert!(bytes[4096..].windows(2).any(|w| w == [0x48, 0x8b]));
    assert!(bytes[4096..].windows(2).any(|w| w == [0x48, 0x89]));
    assert!(bytes[4096..].windows(3).any(|w| w == [0x48, 0x0f, 0xb6]));
    #[cfg(all(target_os="linux", target_arch="x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&output).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&output, permissions).unwrap();
        assert_eq!(Command::new(&output).status().unwrap().code(), Some(42));
    }
    fs::remove_file(output).unwrap();
}

#[cfg(all(target_os="linux", target_arch="x86_64"))]
#[test]
fn nested_bool_field_controls_branch_correctly() {
    use std::os::unix::fs::PermissionsExt;
    let input = root().join("examples/native_cfg_nested_inactive.lir");
    let output = unique_file();
    let result = Command::new(compiler()).arg(&input).arg(&output).output().unwrap();
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stderr));
    let mut perms = fs::metadata(&output).unwrap().permissions();
    perms.set_mode(0o700);
    fs::set_permissions(&output, perms).unwrap();
    assert_eq!(Command::new(&output).status().unwrap().code(), Some(0));
    fs::remove_file(output).unwrap();
}

#[test]
fn nested_structs_reject_invalid_type_owner_and_initialization() {
    for name in [
        "native_cfg_nested_bad_forward.lir",
        "native_cfg_nested_bad_store_type.lir",
        "native_cfg_nested_bad_uninit.lir",
        "native_cfg_nested_bad_owner.lir",
        "native_cfg_nested_bad_read_struct.lir",
        "native_cfg_nested_use_after_move.lir",
        "native_cfg_nested_double_move.lir",
        "native_cfg_nested_move_join.lir",
    ] {
        let input = root().join("examples").join(name);
        let result = Command::new(compiler()).arg(&input).output().unwrap();
        assert!(!result.status.success(), "unexpected acceptance of {name}");
        assert!(String::from_utf8_lossy(&result.stderr).contains("rechazado"));
    }
}

// The actual source->Stage1->LIR->ELE native backend path. This test
// deliberately does not substitute handwritten LIR on a Stage1 failure.
#[test]
fn stage1_real_nested_copy_struct_to_native_elf() {
    let sema = stage1_support::build("main_sema", false);
    let source = root().join("examples/native_cfg_real_nested.l");
    let lir = Command::new(sema).arg(&source).arg("--emit-lir").output().unwrap();
    assert!(lir.status.success(), "Stage1: {}", String::from_utf8_lossy(&lir.stderr));
    let lir_text = String::from_utf8(lir.stdout).unwrap();
    assert!(lir_text.starts_with("ELE-LIR 1\n"));
    assert!(lir_text.contains("struct s0 "));
    assert!(lir_text.contains("struct s1 "));
    let temp_lir = unique_file().with_extension("lir");
    fs::write(&temp_lir, &lir_text).unwrap();
    let output = unique_file();
    let run = Command::new(compiler()).arg(&temp_lir).arg(&output).output().unwrap();
    fs::remove_file(&temp_lir).unwrap();
    assert!(run.status.success(), "Native backend: {}", String::from_utf8_lossy(&run.stderr));
    let bytes = fs::read(&output).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    #[cfg(all(target_os="linux", target_arch="x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&output).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&output, permissions).unwrap();
        assert_eq!(Command::new(&output).status().unwrap().code(), Some(42));
    }
    fs::remove_file(output).unwrap();
}
