//! Integration tests for the ELF/CFG backend written in ELE itself.
//! Stage 0 builds the ELE fixture; the backend's parser, verifier,
//! x86-64 encoder and ELF writer are all `.l` modules.
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

fn output_path(test: &str) -> PathBuf {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "ele-native-cfg-{}-{}-{}.elf",
        test,
        std::process::id(),
        nonce
    ))
}

fn generate(fixture: &str) -> Vec<u8> {
    let target = output_path(fixture);
    let out = Command::new(compiler())
        .arg(root().join("examples").join(fixture))
        .arg(&target)
        .output()
        .expect("run ELE native CFG compiler");
    assert!(
        out.status.success(),
        "{}: {}",
        fixture,
        String::from_utf8_lossy(&out.stderr)
    );
    let data = fs::read(&target).unwrap();
    fs::remove_file(&target).unwrap();
    assert!(data.len() > 4096);
    assert_eq!(&data[0..7], b"\x7fELF\x02\x01\x01");
    assert_eq!(
        u64::from_le_bytes(data[24..32].try_into().unwrap()),
        0x401000
    );
    data
}

#[test]
fn ele_cfg_backend_accepts_use_assignment_instruction() {
    // The `i use` parser must assign its internal opcode, and the backend
    // must lower that assignment instead of reporting an unknown instruction.
    let elf = generate("native_cfg_loop_call.lir");
    assert!(elf[4096..].len() > 25);
}

#[test]
fn ele_cfg_backend_emits_real_multifunction_loop_elf() {
    let elf = generate("native_cfg_loop_call.lir");
    let code = &elf[4096..];
    assert_eq!(code[0], 0xe8, "entry stub calls main");
    assert!(code.windows(2).any(|w| w == [0x0f, 0x85]), "JNE branch");
    assert!(code.contains(&0xe9), "unconditional jump");
    assert!(code.iter().filter(|&&b| b == 0xe8).count() >= 2);
    // Direct calls and branches are patched to non-zero rel32 displacements.
    assert_ne!(&code[1..5], &[0, 0, 0, 0]);
}

#[test]
fn ele_cfg_backend_compiles_boolean_comparison_and_branches() {
    let elf = generate("native_cfg_branch.lir");
    assert!(elf[4096..].windows(3).any(|b| b == [0x0f, 0x9c, 0xc0]));
}

#[test]
fn ele_cfg_backend_accepts_stage1_style_source_spans() {
    let elf = generate("native_cfg_branch_spans.lir");
    assert!(elf[4096..].windows(3).any(|b| b == [0x0f, 0x9c, 0xc0]));
}

#[test]
fn ele_cfg_backend_rejects_uninitialized_across_blocks() {
    let out = Command::new(compiler())
        .arg(root().join("examples/native_cfg_uninit.lir"))
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("rechazado"));
}

#[test]
fn ele_cfg_backend_rejects_call_argument_type_mismatch() {
    let out = Command::new(compiler())
        .arg(root().join("examples/native_cfg_bad_call.lir"))
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("rechazado"));
}

#[test]
fn ele_cfg_backend_rejects_nonexistent_branch_target() {
    let out = Command::new(compiler())
        .arg(root().join("examples/native_cfg_bad_branch.lir"))
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("rechazado"));
}

#[test]
fn ele_cfg_backend_supports_recursive_calls() {
    let elf = generate("native_cfg_recursive.lir");
    assert!(elf[4096..].contains(&0xe8), "recursive CALL present");
}

#[test]
fn ele_cfg_backend_rejects_join_with_partial_initialization() {
    let out = Command::new(compiler())
        .arg(root().join("examples/native_cfg_branch_uninit.lir"))
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("rechazado"));
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
#[test]
fn ele_cfg_generated_elf_executes_with_last_loop_value() {
    use std::os::unix::fs::PermissionsExt;
    let target = output_path("exec");
    let out = Command::new(compiler())
        .arg(root().join("examples/native_cfg_loop_call.lir"))
        .arg(&target)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let mut perm = fs::metadata(&target).unwrap().permissions();
    perm.set_mode(0o700);
    fs::set_permissions(&target, perm).unwrap();
    let status = Command::new(&target).status().unwrap();
    fs::remove_file(&target).unwrap();
    assert_eq!(status.code(), Some(8));
}
