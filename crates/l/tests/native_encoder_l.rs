//! The x86-64 instruction encoder and ELF64 writer are implemented in ELE,
//! not in Rust. This differential test builds the real `.l` fixture through
//! Stage 0 and inspects its produced bytes. Stage 0 is only bootstrap here.
mod stage1_support;

use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn lir_exe() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("native_lir_demo", false))
}

fn fixture_hex(entry: &str, prefix: &str) -> Vec<u8> {
    let exe = stage1_support::build(entry, false);
    let output = Command::new(exe).output().expect("run ELE codegen fixture");
    assert!(
        output.status.success(),
        "{}: {}",
        entry,
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).expect("fixture UTF-8 output");
    let value = stdout
        .lines()
        .find_map(|line| line.strip_prefix(prefix))
        .expect("hex fixture line missing");
    assert!(value.len() % 2 == 0, "hex string must contain byte pairs");
    value
        .as_bytes()
        .as_chunks::<2>()
    .0
    .iter()
        .map(|pair| {
            let s = std::str::from_utf8(pair).unwrap();
            u8::from_str_radix(s, 16).expect("valid hex byte")
        })
        .collect()
}

#[test]
fn ele_x86_64_encoder_emits_correct_bytes_for_extended_registers() {
    let bytes = fixture_hex("native_encoder_cases", "ELE_CODE_HEX:");
    assert_eq!(
        bytes,
        [
            0x49, 0xb8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // mov r8,-1
            0x4d, 0x89, 0xc1, // mov r9,r8
            0x4d, 0x01, 0xc1, // add r9,r8
            0x4d, 0x29, 0xc1, // sub r9,r8
            0x4d, 0x39, 0xc1, // cmp r9,r8
            0x4d, 0x0f, 0xaf, 0xc8, // imul r9,r8
            0xe9, 0x01, 0, 0, 0,    // jmp after ret
            0xc3, // ret
        ]
    );
}

#[test]
fn ele_elf64_writer_emits_loadable_syscall_image() {
    let elf = fixture_hex("native_elf_demo", "ELE_ELF_HEX:");
    assert_eq!(&elf[0..7], b"\x7fELF\x02\x01\x01");
    assert_eq!(u16::from_le_bytes(elf[16..18].try_into().unwrap()), 2); // ET_EXEC
    assert_eq!(u16::from_le_bytes(elf[18..20].try_into().unwrap()), 62); // x86-64
    assert_eq!(
        u64::from_le_bytes(elf[24..32].try_into().unwrap()),
        0x401000
    );
    assert_eq!(u64::from_le_bytes(elf[32..40].try_into().unwrap()), 64);
    assert_eq!(u16::from_le_bytes(elf[54..56].try_into().unwrap()), 56);
    assert_eq!(u16::from_le_bytes(elf[56..58].try_into().unwrap()), 1);
    assert_eq!(u32::from_le_bytes(elf[64..68].try_into().unwrap()), 1); // PT_LOAD
    assert_eq!(u32::from_le_bytes(elf[68..72].try_into().unwrap()), 5); // R-X
    assert_eq!(
        u64::from_le_bytes(elf[96..104].try_into().unwrap()),
        elf.len() as u64
    );
    assert_eq!(
        &elf[4096..],
        &[
            0x48, 0xb8, 60, 0, 0, 0, 0, 0, 0, 0, // mov rax,60
            0x48, 0xbf, 42, 0, 0, 0, 0, 0, 0, 0, // mov rdi,42
            0x0f, 0x05, // syscall
        ]
    );
}

#[test]
fn ele_x86_64_encoder_patches_negative_conditional_and_unconditional_jumps() {
    let bytes = fixture_hex("native_encoder_branches", "ELE_BRANCH_HEX:");
    assert_eq!(
        bytes,
        [
            0xc3, // RET at offset 0
            0x0f, 0x84, 0xf9, 0xff, 0xff, 0xff, // JE to offset 0
            0xe9, 0xf4, 0xff, 0xff, 0xff, // JMP to offset 0
        ]
    );
}

#[test]
fn ele_lir_subset_backend_compiles_real_protocol_to_native_elf() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let exe = lir_exe();
    let output = Command::new(exe)
        .arg(root.join("examples/native_int_subset.lir"))
        .output()
        .expect("run ELE-written LIR backend");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).expect("hex image");
    let hex = stdout
        .lines()
        .find_map(|line| line.strip_prefix("ELE_ELF_HEX:"))
        .expect("ELF image output");
    assert!(hex.len() % 2 == 0);
    let bytes: Vec<u8> = hex
        .as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap())
        .collect();
    assert_eq!(&bytes[0..4], b"\x7fELF");
    assert_eq!(
        u64::from_le_bytes(bytes[24..32].try_into().unwrap()),
        0x401000
    );
    // v0 = 40; v1 = v0 + 2; return v1 via Linux sys_exit.
    assert_eq!(&bytes[4096..4106], &[0x49, 0xb8, 40, 0, 0, 0, 0, 0, 0, 0]);
    // Exact bytes, including a JO rel32 patched to an overflow exit path.
    let expected: Vec<u8> = [
        "49b82800000000000000",
        "48b80200000000000000",
        "4d89c1",
        "4901c1",
        "0f800f000000",
        "4c89cf",
        "48b83c00000000000000",
        "0f05",
        "48bf7d00000000000000",
        "48b83c00000000000000",
        "0f05",
    ]
    .concat()
    .as_bytes()
    .as_chunks::<2>()
        .0
        .iter()
    .map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap())
    .collect();
    assert_eq!(&bytes[4096..], expected.as_slice());
}

#[test]
fn ele_lir_subset_backend_rejects_unsupported_instructions() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let exe = lir_exe();
    let output = Command::new(exe)
        .arg(root.join("examples/native_int_subset_invalid.lir"))
        .output()
        .expect("run ELE-written LIR backend");
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("rechazado"), "{stderr}");
}

#[test]
fn ele_lir_subset_backend_rejects_uninitialized_variable_reads() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let output = Command::new(lir_exe())
        .arg(root.join("examples/native_int_subset_invalid_uninit.lir"))
        .output()
        .expect("run ELE-written LIR backend");
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("rechazado"));
}

/// File output is performed by the ELE `writeBytes` builtin, not a Rust test
/// re-encoding hex. This is a Stage-0 bootstrap test: compile and execute the
/// .l fixture on Windows/MSVC to validate the native platform ABI.
fn unique_output(name: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("ele-{name}-{}-{nanos}.bin", std::process::id()))
}

#[test]
fn ele_write_bytes_persists_binary_values_without_utf8_conversion() {
    let exe = stage1_support::build("native_binary_io", false);
    let path = unique_output("bytes");
    let output = Command::new(exe).arg(&path).output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(std::fs::read(&path).unwrap(), [0, 127, 128, 255, 10]);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn ele_write_bytes_rejects_invalid_byte_before_creating_file() {
    let exe = stage1_support::build("native_binary_io", false);
    let path = unique_output("invalid-byte");
    let output = Command::new(exe)
        .arg(&path)
        .arg("invalid")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !path.exists(),
        "invalid bytes must not create or truncate a file"
    );
}

#[test]
fn ele_elf64_is_written_as_executable_bytes_by_ele_source() {
    let exe = stage1_support::build("native_elf_demo", false);
    let path = unique_output("elf64");
    let output = Command::new(exe).arg(&path).output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[0..4], b"\x7fELF");
    assert_eq!(
        u64::from_le_bytes(bytes[24..32].try_into().unwrap()),
        0x401000
    );
    assert_eq!(
        &bytes[4096..],
        &[
            0x48, 0xb8, 60, 0, 0, 0, 0, 0, 0, 0, 0x48, 0xbf, 42, 0, 0, 0, 0, 0, 0, 0, 0x0f, 0x05
        ]
    );
    std::fs::remove_file(path).unwrap();
}

#[test]
fn ele_lir_subset_can_write_elf64_directly() {
    let exe = lir_exe();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let path = unique_output("lir-elf64");
    let output = Command::new(exe)
        .arg(root.join("examples/native_int_subset.lir"))
        .arg(&path)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..4], b"\x7fELF");
    // The original LIR computes 40+2 and the encoder returns through Linux exit.
    assert_eq!(&bytes[4096..4106], &[0x49, 0xb8, 40, 0, 0, 0, 0, 0, 0, 0]);
    std::fs::remove_file(path).unwrap();
}

#[test]
fn ele_linear_backend_still_rejects_bool_operands() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let output = Command::new(lir_exe())
        .arg(root.join("examples/native_int_subset_invalid_bool.lir"))
        .output()
        .expect("run ELE-written Int-only LIR backend");
    assert!(!output.status.success(), "Bool must not be accepted as Int");
    assert!(String::from_utf8_lossy(&output.stderr).contains("rechazado"));
}
