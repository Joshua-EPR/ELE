//! Stage-0-bootstrapped integration for a *genuine ELE-written* x86-64
//! backend. Struct definitions are consumed from ELE-LIR 1, not test layouts.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn compiler() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn temporary(name: &str, suffix: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "ele-struct-{name}-{}-{nanos}.{suffix}",
        std::process::id()
    ))
}

fn generate(input: &Path) -> (Vec<u8>, PathBuf) {
    let target = temporary("out", "elf");
    let output = Command::new(compiler())
        .arg(input)
        .arg(&target)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        input.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    let bytes = fs::read(&target).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    assert!(bytes.len() > 4100);
    (bytes, target)
}

#[test]
fn copy_only_structs_use_real_lir_layout_and_emit_memory_accesses() {
    let input = root().join("examples/native_cfg_struct_copy.lir");
    let (binary, file) = generate(&input);
    fs::remove_file(file).unwrap();
    // Direct field loads/stores. The native backend does not call Rust/C to emit.
    assert!(binary[4096..].windows(2).any(|b| b == [0x48, 0x8b]));
    assert!(binary[4096..].windows(2).any(|b| b == [0x48, 0x89]));
    assert!(binary[4096..].windows(3).any(|b| b == [0x48, 0x0f, 0xb6]));
}

#[test]
fn malformed_aggregate_lir_is_rejected_with_nonzero_status() {
    for name in [
        "native_cfg_struct_wrong_field.lir",
        "native_cfg_struct_wrong_type.lir",
        "native_cfg_struct_uninitialized.lir",
        "native_cfg_struct_bad_store.lir",
        "native_cfg_struct_bad_owner.lir",
        "native_cfg_struct_bad_call.lir",
    ] {
        let input = root().join("examples").join(name);
        let out = Command::new(compiler()).arg(&input).output().unwrap();
        assert!(!out.status.success(), "unexpected accept of {name}");
        assert!(String::from_utf8_lossy(&out.stderr).contains("rechazado"));
    }
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn exec_elf(file: &Path) -> i32 {
    use std::os::unix::fs::PermissionsExt;
    let mut perms = fs::metadata(file).unwrap().permissions();
    perms.set_mode(0o700);
    fs::set_permissions(file, perms).unwrap();
    let code = Command::new(file).status().unwrap().code().unwrap();
    fs::remove_file(file).unwrap();
    code
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
#[test]
fn ele_native_struct_elf_executes_without_external_runtime() {
    let (_, file) = generate(&root().join("examples/native_cfg_struct_copy.lir"));
    assert_eq!(exec_elf(&file), 42);
}

// The critical next integration: a *real source program* emits LIR from
// Stage 1. No handwritten LIR or Stage-0 frontend substitution is allowed.
#[test]
fn stage1_emitted_struct_lir_is_accepted_by_ele_native_backend() {
    let sema = stage1_support::build("main_sema", false);
    let source = root().join("examples/native_cfg_real_struct.l");
    let output = Command::new(sema)
        .arg(&source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "Stage1: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let lir = String::from_utf8(output.stdout).unwrap();
    assert!(lir.starts_with("ELE-LIR 1\n"));
    assert!(lir.contains("struct s0 "));
    let file = temporary("stage1", "lir");
    fs::write(&file, lir).unwrap();
    let generated = generate(&file);
    // Export the genuine Stage 1 .l -> LIR -> ELE ELF64 result to Linux CI.
    let artifact = root().join("target/stage1-tests/native-struct-source/struct.elf");
    fs::create_dir_all(artifact.parent().unwrap()).unwrap();
    fs::write(&artifact, &generated.0).unwrap();
    fs::remove_file(file).unwrap();
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    assert_eq!(exec_elf(&generated.1), 42);
    #[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
    fs::remove_file(generated.1).unwrap();
}
