//! Integration tests for the initial stack-only aggregate lowering in ELE.
//! This is NOT heap ownership or general struct LIR lowering.
mod stage1_support;

use std::{fs, path::PathBuf, process::Command};

fn temp_elf() -> PathBuf {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("ele-stack-{}-{stamp}.elf", std::process::id()))
}

#[test]
fn ele_stack_aggregate_emits_elf_with_byte_and_qword_load_store() {
    let exe = stage1_support::build("native_stack_aggregate_demo", false);
    let path = temp_elf();
    let out = Command::new(exe).arg(&path).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let data = fs::read(&path).expect("ELF from ELE-written emitter");
    fs::remove_file(&path).unwrap();
    assert!(data.len() > 4096);
    assert_eq!(&data[0..4], b"\x7fELF");
    assert_eq!(u64::from_le_bytes(data[24..32].try_into().unwrap()), 0x401000);
    let instructions = &data[4096..];
    assert!(instructions.contains(&0x88), "byte store instruction");
    assert!(instructions.windows(2).any(|w| w == [0x0f, 0xb6]), "byte zero-extend");
    assert!(instructions.windows(2).any(|w| w == [0x0f, 0x05]), "sys_exit");
}

#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
#[test]
fn ele_stack_aggregate_executes_and_returns_42() {
    use std::os::unix::fs::PermissionsExt;
    let exe = stage1_support::build("native_stack_aggregate_demo", false);
    let path = temp_elf();
    let out = Command::new(exe).arg(&path).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let mut perms = fs::metadata(&path).unwrap().permissions();
    perms.set_mode(0o700);
    fs::set_permissions(&path, perms).unwrap();
    let result = Command::new(&path).status().unwrap();
    fs::remove_file(path).unwrap();
    assert_eq!(result.code(), Some(42));
}
